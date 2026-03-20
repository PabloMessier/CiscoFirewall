#!/usr/bin/env python3
"""
stress_test.py — Stress test the workload ASG through the ALB.

Generates high-volume HTTP traffic in cycles:
  5 minutes of sustained load → 5 minutes rest → repeat

Designed to trigger ASG Auto Scaling (ALB request count + CPU)
scaling from 2 → 4 → 6 instances.

Usage:
  python3 scripts/stress_test.py
  python3 scripts/stress_test.py --workers 200 --stress 300 --rest 300
  python3 scripts/stress_test.py --cycles 3   # stop after 3 cycles

Press Ctrl+C to stop gracefully at any time.
"""

import argparse
import signal
import sys
import threading
import time
import subprocess
import json
import logging
from collections import Counter
from datetime import datetime
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError

# ── Logging ───────────────────────────────────────────────────────
# Console handler — INFO and WARNING to stdout
logging.basicConfig(
    format='[%(asctime)s] %(levelname)s: %(message)s',
    level=logging.INFO,
    datefmt='%H:%M:%S'
)
logging.getLogger().setLevel(logging.WARNING)

# File handler — ERROR+ dumped to a .log file after each run
_SCRIPT_DIR = Path(__file__).resolve().parent
_LOG_FILE = _SCRIPT_DIR / f"stress_test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
_file_handler = logging.FileHandler(_LOG_FILE, mode='w')
_file_handler.setLevel(logging.ERROR)
_file_handler.setFormatter(logging.Formatter(
    '[%(asctime)s] %(levelname)s: %(message)s', datefmt='%Y-%m-%d %H:%M:%S'
))
logging.getLogger().addHandler(_file_handler)

logger = logging.getLogger(__name__)

# ── Defaults (loaded from defaults.json) ──────────────────────────
_DEFAULTS_PATH = _SCRIPT_DIR / "defaults.json"
try:
    with open(_DEFAULTS_PATH) as _f:
        _cfg = json.load(_f)
except (FileNotFoundError, json.JSONDecodeError) as exc:
    logger.error("Failed to load %s: %s", _DEFAULTS_PATH, exc)
    sys.exit(1)

DEFAULT_URL         = _cfg["DEFAULT_URL"]
DEFAULT_WORKERS     = _cfg["DEFAULT_WORKERS"]
DEFAULT_STRESS_SECS = _cfg["DEFAULT_STRESS_SECS"]
DEFAULT_REST_SECS   = _cfg["DEFAULT_REST_SECS"]
DEFAULT_TIMEOUT     = _cfg["DEFAULT_TIMEOUT"]
REPORT_INTERVAL     = _cfg["REPORT_INTERVAL"]

# ── Globals ───────────────────────────────────────────────────────
stop_event = threading.Event()


def _handle_signal(sig, frame):
    print("\n>>> Ctrl+C — stopping after current phase...")
    stop_event.set()


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


# ── HTTP worker ───────────────────────────────────────────────────
def _send_request(url: str, timeout: int) -> tuple[int, float]:
    """Send one GET request. Returns (status_code, latency_ms).
    status_code 0 means connection/timeout error."""
    t0 = time.monotonic()
    try:
        req = Request(url, headers={"Connection": "close"})
        with urlopen(req, timeout=timeout) as resp:
            resp.read()  # consume body
            return resp.status, (time.monotonic() - t0) * 1000
    except HTTPError as exc:
        return exc.code, (time.monotonic() - t0) * 1000
    except (URLError, OSError, TimeoutError) as exc:
        logger.error("Request to %s failed: %s", url, exc)
        return 0, (time.monotonic() - t0) * 1000


# ── Stress phase ──────────────────────────────────────────────────
def _stress_phase(url: str, workers: int, duration: int,
                  timeout: int) -> tuple[Counter, list[float]]:
    """Hammer the URL for *duration* seconds with *workers* threads."""
    deadline = time.monotonic() + duration
    lock = threading.Lock()
    status_totals: Counter = Counter()
    all_latencies: list[float] = []

    def worker():
        local_status: Counter = Counter()
        local_lat: list[float] = []
        while time.monotonic() < deadline and not stop_event.is_set():
            code, lat = _send_request(url, timeout)
            local_status[code] += 1
            local_lat.append(lat)
        with lock:
            status_totals.update(local_status)
            all_latencies.extend(local_lat)

    # Launch workers
    threads = [threading.Thread(target=worker, daemon=True)
               for _ in range(workers)]
    for t in threads:
        t.start()

    # Progress reporting
    phase_start = time.monotonic()
    while time.monotonic() < deadline and not stop_event.is_set():
        time.sleep(REPORT_INTERVAL)
        elapsed = time.monotonic() - phase_start
        with lock:
            total = sum(status_totals.values())
            rps = total / elapsed if elapsed > 0 else 0
            ok = status_totals.get(200, 0)
            errs = total - ok
            avg = (sum(all_latencies) / len(all_latencies)
                   if all_latencies else 0)
        remaining = max(0, deadline - time.monotonic())
        print(f"  [{remaining:>4.0f}s left]  {total:>7,} reqs "
              f"| {rps:>7.1f} req/s | avg {avg:>6.0f}ms "
              f"| ok={ok:,} err={errs:,}")

    for t in threads:
        t.join(timeout=5)

    return status_totals, all_latencies


# ── Summary printer ───────────────────────────────────────────────
def _print_summary(cycle: int, statuses: Counter,
                   latencies: list[float]) -> None:
    total = sum(statuses.values())
    if not latencies:
        print(f"  Cycle {cycle}: no requests completed\n")
        return

    latencies.sort()
    n = len(latencies)
    avg = sum(latencies) / n
    p50 = latencies[n // 2]
    p95 = latencies[int(n * 0.95)]
    p99 = latencies[int(n * 0.99)]
    ok = statuses.get(200, 0)

    print(f"\n{'═' * 62}")
    print(f"  Cycle {cycle} Summary")
    print(f"{'═' * 62}")
    print(f"  Total requests  : {total:,}")
    print(f"  Success (200)   : {ok:,}  ({ok / total * 100:.1f}%)")
    print(f"  Status codes    : {dict(statuses)}")
    print(f"  Latency (ms)    : avg={avg:.0f}  p50={p50:.0f}"
          f"  p95={p95:.0f}  p99={p99:.0f}")
    print(f"  Throughput      : {total / (n and (latencies[-1] / 1000) or 1):.1f} effective req/s")
    print(f"{'═' * 62}\n")


# ── Rest phase ────────────────────────────────────────────────────
def _rest_phase(duration: int) -> None:
    """Sleep with a countdown, checking stop_event."""
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline and not stop_event.is_set():
        remaining = deadline - time.monotonic()
        mins, secs = divmod(int(remaining), 60)
        print(f"  Resting... {mins}m {secs:02d}s remaining   ", end="\r")
        time.sleep(min(REPORT_INTERVAL, remaining))
    print()  # clear the \r line


# ── ASG monitor (best-effort) ─────────────────────────────────────
def _print_scaling_status() -> None:
    """Try to print current ASG instance counts."""
    try:
        asg = subprocess.run(
            ["aws", "autoscaling", "describe-auto-scaling-groups",
             "--auto-scaling-group-names", "workload-asg",
             "--region", "us-east-2",
             "--query", "AutoScalingGroups[0].{desired:DesiredCapacity,running:Instances[?LifecycleState=='InService']|length(@)}",
             "--output", "json"],
            capture_output=True, text=True, timeout=10
        )
        asg_info = json.loads(asg.stdout) if asg.returncode == 0 else {}

        print(f"  📊 ASG instances: {asg_info.get('desired', '?')} desired / "
              f"{asg_info.get('running', '?')} running")
    except Exception as exc:
        logger.error("Failed to fetch scaling status: %s", exc)


# ── Main ──────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Stress test workload ASG via ALB")
    parser.add_argument("--url", default=DEFAULT_URL,
                        help="ALB endpoint URL")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help="Concurrent request threads")
    parser.add_argument("--stress", type=int, default=DEFAULT_STRESS_SECS,
                        help="Stress phase duration in seconds")
    parser.add_argument("--rest", type=int, default=DEFAULT_REST_SECS,
                        help="Rest phase duration in seconds")
    parser.add_argument("--cycles", type=int, default=0,
                        help="Number of cycles (0 = infinite)")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                        help="Per-request timeout in seconds")
    args = parser.parse_args()

    print(f"\n{'─' * 62}")
    print(f"  ASG Stress Test")
    print(f"{'─' * 62}")
    print(f"  URL      : {args.url}")
    print(f"  Workers  : {args.workers}")
    print(f"  Cycle    : {args.stress}s stress / {args.rest}s rest")
    print(f"  Cycles   : {'∞' if args.cycles == 0 else args.cycles}")
    print(f"{'─' * 62}\n")

    _print_scaling_status()
    print()

    cycle = 0
    while not stop_event.is_set():
        cycle += 1
        if args.cycles > 0 and cycle > args.cycles:
            break

        ts = datetime.now().strftime("%H:%M:%S")
        print(f">>> Cycle {cycle} — STRESS ({args.stress}s) "
              f"started at {ts}")

        statuses, latencies = _stress_phase(
            args.url, args.workers, args.stress, args.timeout)
        _print_summary(cycle, statuses, latencies)
        _print_scaling_status()

        if stop_event.is_set():
            break
        if args.cycles > 0 and cycle >= args.cycles:
            break

        ts = datetime.now().strftime("%H:%M:%S")
        print(f">>> Cycle {cycle} — REST ({args.rest}s) "
              f"started at {ts}")
        _rest_phase(args.rest)
        _print_scaling_status()
        print()

    print(">>> Stress test finished.")

    # Report log file
    if _LOG_FILE.exists() and _LOG_FILE.stat().st_size > 0:
        print(f"\n⚠  Errors were logged to: {_LOG_FILE}")
    else:
        # No errors — clean up the empty log file
        _LOG_FILE.unlink(missing_ok=True)
        print("\n✔  No errors logged.")


if __name__ == "__main__":
    main()
