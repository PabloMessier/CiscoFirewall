#!/usr/bin/env python3
"""
stress_test.py — Stress test the workload ASG through the NLB.

Generates HTTP traffic in cycles: stress → rest → repeat.
Designed to trigger ASG CPU-based auto scaling.

Usage:
  python3 scripts/stress_test.py
  python3 scripts/stress_test.py --workers 200 --stress 300 --rest 300
  python3 scripts/stress_test.py --cycles 3

Press Ctrl+C to stop (press twice to force exit).
"""

import argparse
import json
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError

# ── Config ────────────────────────────────────────────────────────
_SCRIPT_DIR = Path(__file__).resolve().parent
_cfg = json.loads((_SCRIPT_DIR / "defaults.json").read_text())

DEFAULT_URL     = _cfg["DEFAULT_URL"]
DEFAULT_WORKERS = _cfg["DEFAULT_WORKERS"]
DEFAULT_STRESS  = _cfg["DEFAULT_STRESS_SECS"]
DEFAULT_REST    = _cfg["DEFAULT_REST_SECS"]
DEFAULT_TIMEOUT = _cfg["DEFAULT_TIMEOUT"]
REPORT_INTERVAL = _cfg["REPORT_INTERVAL"]

# ── Signal handling ───────────────────────────────────────────────
stop = threading.Event()

def _on_signal(sig, frame):
    print("\n>>> Stopping...")
    stop.set()
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(1))

signal.signal(signal.SIGINT, _on_signal)
signal.signal(signal.SIGTERM, _on_signal)


# ── HTTP worker ───────────────────────────────────────────────────
def _request(url: str, timeout: int) -> tuple[int, float]:
    """GET url → (status, latency_ms). Status 0 = error."""
    t0 = time.monotonic()
    try:
        with urlopen(Request(url, headers={"Connection": "close"}),
                     timeout=timeout) as r:
            r.read()
            return r.status, (time.monotonic() - t0) * 1000
    except HTTPError as e:
        return e.code, (time.monotonic() - t0) * 1000
    except (URLError, OSError, TimeoutError):
        return 0, (time.monotonic() - t0) * 1000


# ── Stress phase ──────────────────────────────────────────────────
def _stress(url: str, workers: int, duration: int,
            timeout: int) -> tuple[Counter, list[float]]:
    deadline = time.monotonic() + duration
    lock = threading.Lock()
    totals: Counter = Counter()
    latencies: list[float] = []

    def run():
        local_s, local_l = Counter(), []
        while time.monotonic() < deadline and not stop.is_set():
            code, lat = _request(url, timeout)
            local_s[code] += 1
            local_l.append(lat)
        with lock:
            totals.update(local_s)
            latencies.extend(local_l)

    threads = [threading.Thread(target=run, daemon=True)
               for _ in range(workers)]
    for t in threads:
        t.start()

    start = time.monotonic()
    while time.monotonic() < deadline and not stop.is_set():
        time.sleep(REPORT_INTERVAL)
        elapsed = time.monotonic() - start
        with lock:
            total = sum(totals.values())
            ok = totals.get(200, 0)
            errs = total - ok
            rps = total / elapsed if elapsed else 0
            avg = sum(latencies) / len(latencies) if latencies else 0
        left = max(0, deadline - time.monotonic())
        print(f"  [{left:>4.0f}s]  {total:>7,} reqs | "
              f"{rps:>6.0f} req/s | avg {avg:>5.0f}ms | "
              f"ok={ok:,} err={errs:,}")

    end = time.monotonic() + 10
    for t in threads:
        t.join(timeout=max(0.1, end - time.monotonic()))
        if stop.is_set():
            break

    return totals, latencies


# ── Summary ───────────────────────────────────────────────────────
def _summary(cycle: int, statuses: Counter, latencies: list[float]):
    total = sum(statuses.values())
    if not latencies:
        print(f"  Cycle {cycle}: no requests completed\n")
        return

    latencies.sort()
    n = len(latencies)
    ok = statuses.get(200, 0)

    print(f"\n{'=' * 60}")
    print(f"  Cycle {cycle}")
    print(f"{'=' * 60}")
    print(f"  Requests : {total:,}  (ok={ok:,}  err={total - ok:,})")
    print(f"  Success  : {ok / total * 100:.1f}%")
    print(f"  Latency  : avg={sum(latencies)/n:.0f}  "
          f"p50={latencies[n//2]:.0f}  "
          f"p95={latencies[int(n*0.95)]:.0f}  "
          f"p99={latencies[int(n*0.99)]:.0f} ms")
    print(f"{'=' * 60}\n")


# ── Rest phase ────────────────────────────────────────────────────
def _rest(duration: int):
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline and not stop.is_set():
        left = deadline - time.monotonic()
        m, s = divmod(int(left), 60)
        print(f"  Resting... {m}m {s:02d}s   ", end="\r")
        time.sleep(min(REPORT_INTERVAL, left))
    print()


# ── ASG status ────────────────────────────────────────────────────
def _asg_status():
    try:
        r = subprocess.run(
            ["aws", "autoscaling", "describe-auto-scaling-groups",
             "--auto-scaling-group-names", "workload-asg",
             "--region", "us-east-2",
             "--query",
             "AutoScalingGroups[0].{d:DesiredCapacity,"
             "r:Instances[?LifecycleState=='InService']|length(@)}",
             "--output", "json"],
            capture_output=True, text=True, timeout=10)
        info = json.loads(r.stdout) if r.returncode == 0 else {}
        print(f"  ASG: {info.get('d','?')} desired / "
              f"{info.get('r','?')} running")
    except Exception:
        print("  ASG: (unavailable)")


# ── Main ──────────────────────────────────────────────────────────
def main():
    p = argparse.ArgumentParser(description="Stress test workload ASG")
    p.add_argument("--url",     default=DEFAULT_URL)
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    p.add_argument("--stress",  type=int, default=DEFAULT_STRESS)
    p.add_argument("--rest",    type=int, default=DEFAULT_REST)
    p.add_argument("--cycles",  type=int, default=0, help="0 = infinite")
    p.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    a = p.parse_args()

    print(f"\n{'-' * 60}")
    print(f"  ASG Stress Test")
    print(f"{'-' * 60}")
    print(f"  URL     : {a.url}")
    print(f"  Workers : {a.workers}")
    print(f"  Cycle   : {a.stress}s stress / {a.rest}s rest")
    print(f"  Cycles  : {'inf' if a.cycles == 0 else a.cycles}")
    print(f"{'-' * 60}\n")
    _asg_status()
    print()

    cycle = 0
    while not stop.is_set():
        cycle += 1
        if a.cycles and cycle > a.cycles:
            break

        print(f">>> Cycle {cycle} — STRESS ({a.stress}s) "
              f"@ {datetime.now():%H:%M:%S}")
        statuses, lats = _stress(a.url, a.workers, a.stress, a.timeout)
        _summary(cycle, statuses, lats)
        _asg_status()

        if stop.is_set() or (a.cycles and cycle >= a.cycles):
            break

        print(f">>> Cycle {cycle} — REST ({a.rest}s) "
              f"@ {datetime.now():%H:%M:%S}")
        _rest(a.rest)
        _asg_status()
        print()

    print(">>> Done.")


if __name__ == "__main__":
    main()
