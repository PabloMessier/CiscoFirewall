#!/usr/bin/env python3
"""
stress_test.py — Stress test the workload ASG through the NLB.

Generates HTTP traffic in cycles: stress -> rest -> repeat.
Designed to trigger ASG CPU-based auto scaling.

Usage:
  python3 scripts/stress_test.py
  python3 scripts/stress_test.py --workers 200 --stress 300 --rest 300
  python3 scripts/stress_test.py --cycles 3
  python3 scripts/stress_test.py --output results.json

Press Ctrl+C to stop (press twice to force exit).
"""

import argparse
import json
import math
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen, Request

try:
    import urllib3

    _USE_URLLIB3 = True
except ImportError:
    _USE_URLLIB3 = False

# -- Config ----------------------------------------------------------------
_SCRIPT_DIR = Path(__file__).resolve().parent
_cfg = json.loads((_SCRIPT_DIR / "defaults.json").read_text())

DEFAULT_URL = _cfg["DEFAULT_URL"]
DEFAULT_WORKERS = _cfg["DEFAULT_WORKERS"]
DEFAULT_STRESS = _cfg["DEFAULT_STRESS_SECS"]
DEFAULT_REST = _cfg["DEFAULT_REST_SECS"]
DEFAULT_TIMEOUT = _cfg["DEFAULT_TIMEOUT"]
REPORT_INTERVAL = _cfg["REPORT_INTERVAL"]
DEFAULT_ASG_NAME = _cfg.get("DEFAULT_ASG_NAME", "workload-asg")
DEFAULT_REGION = _cfg.get("DEFAULT_REGION", "us-east-2")

# -- Signal handling -------------------------------------------------------
stop = threading.Event()

def _on_signal(sig, frame):
    stop.set()
    # Use os._exit to avoid reentrant calls to print/IO
    import os
    os._exit(1)

signal.signal(signal.SIGINT, _on_signal)
signal.signal(signal.SIGTERM, _on_signal)

# -- Streaming stats accumulator -------------------------------------------
class Stats:
    """O(1) memory stats with reservoir sampling for percentiles."""

    def __init__(self, reservoir_size: int = 10_000):
        self.count = 0
        self.total = 0.0
        self.min = float("inf")
        self.max = float("-inf")
        self._sum_sq = 0.0
        self._reservoir: list[float] = []
        self._reservoir_size = reservoir_size
        self._lock = threading.Lock()
        self.statuses: Counter = Counter()

    def record(self, status: int, latency_ms: float):
        with self._lock:
            self.count += 1
            self.total += latency_ms
            self._sum_sq += latency_ms * latency_ms
            if latency_ms < self.min:
                self.min = latency_ms
            if latency_ms > self.max:
                self.max = latency_ms
            self.statuses[status] += 1

            # Reservoir sampling (Algorithm R) for percentile estimation
            if len(self._reservoir) < self._reservoir_size:
                self._reservoir.append(latency_ms)
            else:
                import random

                j = random.randint(0, self.count - 1)
                if j < self._reservoir_size:
                    self._reservoir[j] = latency_ms

    def snapshot(self) -> dict:
        with self._lock:
            if self.count == 0:
                return {
                    "count": 0,
                    "ok": 0,
                    "errors": 0,
                    "avg_ms": 0,
                    "min_ms": 0,
                    "max_ms": 0,
                    "p50_ms": 0,
                    "p95_ms": 0,
                    "p99_ms": 0,
                    "stddev_ms": 0,
                    "statuses": dict(self.statuses),
                }
            avg = self.total / self.count
            variance = (self._sum_sq / self.count) - (avg * avg)
            stddev = math.sqrt(max(0, variance))
            ok = self.statuses.get(200, 0)

            reservoir = sorted(self._reservoir)
            n = len(reservoir)
            p50 = reservoir[n // 2] if n else 0
            p95 = reservoir[int(n * 0.95)] if n else 0
            p99 = reservoir[int(n * 0.99)] if n else 0

            return {
                "count": self.count,
                "ok": ok,
                "errors": self.count - ok,
                "avg_ms": round(avg, 1),
                "min_ms": round(self.min, 1),
                "max_ms": round(self.max, 1),
                "p50_ms": round(p50, 1),
                "p95_ms": round(p95, 1),
                "p99_ms": round(p99, 1),
                "stddev_ms": round(stddev, 1),
                "statuses": dict(self.statuses),
            }

# -- HTTP pool / request ---------------------------------------------------
_pool: "urllib3.PoolManager | None" = None

def _get_pool(timeout: int) -> "urllib3.PoolManager":
    global _pool
    if _pool is None:
        _pool = urllib3.PoolManager(
            num_pools=4,
            maxsize=50,
            retries=False,
            timeout=urllib3.Timeout(connect=timeout, read=timeout),
        )
    return _pool

def _request(url: str, timeout: int) -> tuple[int, float]:
    """GET url -> (status, latency_ms). Status 0 = network error."""
    t0 = time.monotonic()
    if _USE_URLLIB3:
        try:
            pool = _get_pool(timeout)
            r = pool.request("GET", url, preload_content=True)
            return r.status, (time.monotonic() - t0) * 1000
        except Exception:
            return 0, (time.monotonic() - t0) * 1000
    else:
        try:
            with urlopen(
                Request(url, headers={"Connection": "close"}), timeout=timeout
            ) as r:
                r.read()
                return r.status, (time.monotonic() - t0) * 1000
        except HTTPError as e:
            return e.code, (time.monotonic() - t0) * 1000
        except (URLError, OSError, TimeoutError):
            return 0, (time.monotonic() - t0) * 1000

# -- Preflight check -------------------------------------------------------
def _preflight(url: str, timeout: int) -> bool:
    """Single request to verify the target is reachable."""
    print(f"  Preflight check: {url} ...", end=" ", flush=True)
    code, lat = _request(url, timeout)
    if code == 0:
        print(f"FAILED (unreachable, {lat:.0f}ms)")
        return False
    print(f"OK (HTTP {code}, {lat:.0f}ms)")
    return True


# -- Stress phase ----------------------------------------------------------
def _stress(url: str, workers: int, duration: int, timeout: int) -> Stats:
    stats = Stats()
    deadline = time.monotonic() + duration

    def worker():
        while time.monotonic() < deadline and not stop.is_set():
            code, lat = _request(url, timeout)
            stats.record(code, lat)

    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="stress") as pool:
        futures = [pool.submit(worker) for _ in range(workers)]

        start = time.monotonic()
        while time.monotonic() < deadline and not stop.is_set():
            time.sleep(REPORT_INTERVAL)
            elapsed = time.monotonic() - start
            snap = stats.snapshot()
            rps = snap["count"] / elapsed if elapsed else 0
            left = max(0, deadline - time.monotonic())
            print(
                f"  [{left:>4.0f}s]  {snap['count']:>7,} reqs | "
                f"{rps:>6.0f} req/s | avg {snap['avg_ms']:>5.0f}ms | "
                f"ok={snap['ok']:,} err={snap['errors']:,}"
            )

        # Wait for clean shutdown
        stop_deadline = time.monotonic() + 15
        for f in futures:
            remaining = max(0.1, stop_deadline - time.monotonic())
            try:
                f.result(timeout=remaining)
            except Exception:
                pass

    return stats

# -- Summary ---------------------------------------------------------------
def _summary(cycle: int, snap: dict):
    if snap["count"] == 0:
        print(f"  Cycle {cycle}: no requests completed\n")
        return

    total = snap["count"]
    ok = snap["ok"]

    print(f"\n{'=' * 60}")
    print(f"  Cycle {cycle}")
    print(f"{'=' * 60}")
    print(f"  Requests : {total:,}  (ok={ok:,}  err={snap['errors']:,})")
    print(f"  Success  : {ok / total * 100:.1f}%")
    print(
        f"  Latency  : avg={snap['avg_ms']:.0f}  "
        f"p50={snap['p50_ms']:.0f}  "
        f"p95={snap['p95_ms']:.0f}  "
        f"p99={snap['p99_ms']:.0f} ms"
    )
    print(
        f"  Range    : min={snap['min_ms']:.0f}  "
        f"max={snap['max_ms']:.0f}  "
        f"stddev={snap['stddev_ms']:.0f} ms"
    )
    print(f"{'=' * 60}\n")

# -- Rest phase ------------------------------------------------------------
def _rest(duration: int):
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline and not stop.is_set():
        left = deadline - time.monotonic()
        m, s = divmod(int(left), 60)
        print(f"  Resting... {m}m {s:02d}s   ", end="\r")
        time.sleep(min(REPORT_INTERVAL, left))
    print()

# -- ASG status ------------------------------------------------------------
def _asg_status(asg_name: str, region: str):
    try:
        r = subprocess.run(
            [
                "aws",
                "autoscaling",
                "describe-auto-scaling-groups",
                "--auto-scaling-group-names",
                asg_name,
                "--region",
                region,
                "--query",
                "AutoScalingGroups[0].{d:DesiredCapacity,"
                "r:Instances[?LifecycleState=='InService']|length(@)}",
                "--output",
                "json",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        info = json.loads(r.stdout) if r.returncode == 0 else {}
        print(
            f"  ASG ({asg_name}): {info.get('d', '?')} desired / "
            f"{info.get('r', '?')} running"
        )
    except Exception:
        print(f"  ASG ({asg_name}): (unavailable)")


# -- Results export --------------------------------------------------------
def _export_results(path: str, results: list[dict]):
    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "cycles": results,
    }
    Path(path).write_text(json.dumps(output, indent=2))
    print(f">>> Results saved to {path}")


# -- Main ------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description="Stress test workload ASG")
    p.add_argument("--url", default=DEFAULT_URL)
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    p.add_argument("--stress", type=int, default=DEFAULT_STRESS)
    p.add_argument("--rest", type=int, default=DEFAULT_REST)
    p.add_argument("--cycles", type=int, default=0, help="0 = infinite")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    p.add_argument("--asg-name", default=DEFAULT_ASG_NAME)
    p.add_argument("--region", default=DEFAULT_REGION)
    p.add_argument("--output", default=None, help="Export results to JSON file")
    p.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Skip the preflight connectivity check",
    )
    a = p.parse_args()

    if not a.url:
        print("ERROR: No URL configured. Set DEFAULT_URL in defaults.json or pass --url")
        sys.exit(1)

    print(f"\n{'-' * 60}")
    print(f"  ASG Stress Test")
    print(f"{'-' * 60}")
    print(f"  URL     : {a.url}")
    print(f"  Workers : {a.workers}")
    print(f"  Cycle   : {a.stress}s stress / {a.rest}s rest")
    print(f"  Cycles  : {'inf' if a.cycles == 0 else a.cycles}")
    print(f"  Pool    : {'urllib3 (keep-alive)' if _USE_URLLIB3 else 'urllib (no keep-alive)'}")
    print(f"{'-' * 60}\n")

    # Preflight check
    if not a.skip_preflight:
        if not _preflight(a.url, a.timeout):
            print("ERROR: Preflight failed. Use --skip-preflight to bypass.")
            sys.exit(1)
        print()

    _asg_status(a.asg_name, a.region)
    print()

    cycle = 0
    all_results: list[dict] = []

    while not stop.is_set():
        cycle += 1
        if a.cycles and cycle > a.cycles:
            break

        print(
            f">>> Cycle {cycle} — STRESS ({a.stress}s) "
            f"@ {datetime.now():%H:%M:%S}"
        )
        cycle_stats = _stress(a.url, a.workers, a.stress, a.timeout)
        snap = cycle_stats.snapshot()
        _summary(cycle, snap)
        _asg_status(a.asg_name, a.region)

        all_results.append(
            {
                "cycle": cycle,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "duration_s": a.stress,
                "workers": a.workers,
                **snap,
            }
        )

        if stop.is_set() or (a.cycles and cycle >= a.cycles):
            break

        print(
            f">>> Cycle {cycle} — REST ({a.rest}s) "
            f"@ {datetime.now():%H:%M:%S}"
        )
        _rest(a.rest)
        _asg_status(a.asg_name, a.region)
        print()

    if a.output and all_results:
        _export_results(a.output, all_results)

    print(">>> Done.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n>>> Interrupted by user. Exiting...")