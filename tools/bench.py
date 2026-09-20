#!/usr/bin/env python3
"""Time the engine's four cache scenarios, with the per-stage breakdown.

`analyze` reports its own per-stage timings, so a slow run can be attributed
without a profiler. This script drives the four scenarios that matter and prints
the median of each, together with where the time went.

    scenario              what it models
    --------------------  --------------------------------------------------
    all cache hit         a repeated check: startup, wallpaper change, a nudge
    mask miss             dragging the threshold/feather sliders
    refined + mask miss   first analyze of a wallpaper the engine has seen
    cold (all miss)       first analyze after a fresh install or clear-cache

Usage:

    # --data-dir MUST be a scratch copy, see below
    cp -a ~/.local/share/depthscape /tmp/dsbench
    rm -f /tmp/dsbench/cache/masks/* /tmp/dsbench/cache/refined/* /tmp/dsbench/cache/depth/*
    python3 tools/bench.py --wallpaper ~/Pictures/wall.jpg --data-dir /tmp/dsbench

Why a scratch copy: the script **deletes cache entries** to force the cold
scenarios, so pointing it at the live data directory would throw away the masks
the running shell is using. It refuses to run against the default data directory
for that reason.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import subprocess
import sys
import time

STAGES = ["hashMs", "decodeMs", "depthMs", "refineMs", "maskMs", "pruneMs"]


def find_engine() -> str:
    """Same lookup order the plugin's StartupCheck uses."""
    override = os.environ.get("DEPTHSCAPE_ENGINE")
    if override:
        return override
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for profile in ("release", "debug"):
        candidate = os.path.join(here, "engine", "target", profile, "depthscape-engine")
        if os.path.isfile(candidate):
            return candidate
    from shutil import which

    found = which("depthscape-engine")
    if found:
        return found
    sys.exit("cannot find depthscape-engine; set $DEPTHSCAPE_ENGINE")


def default_data_dir() -> str:
    root = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(root, "depthscape")


def run(engine: str, data_dir: str, wallpaper: str, threshold: float, feather: float):
    started = time.perf_counter()
    proc = subprocess.run(
        [engine, "--data-dir", data_dir, "analyze",
         "--wallpaper", wallpaper,
         "--threshold", str(threshold), "--feather", str(feather)],
        capture_output=True, text=True,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    if proc.returncode != 0:
        sys.exit("engine failed:\n" + proc.stderr.strip())
    return elapsed_ms, json.loads(proc.stdout)


def clear(data_dir: str, tier: str) -> None:
    for path in glob.glob(os.path.join(data_dir, "cache", tier, "*")):
        os.remove(path)


def bench(engine, data_dir, wallpaper, label, prepare, threshold, feather, runs):
    samples, outcomes = [], []
    for _ in range(runs):
        prepare()
        elapsed_ms, outcome = run(engine, data_dir, wallpaper, threshold, feather)
        samples.append(elapsed_ms)
        outcomes.append(outcome)

    median = statistics.median(samples)
    last = outcomes[-1]
    print(f"{label:22s} median {median:7.1f} ms   min {min(samples):7.1f}   "
          f"max {max(samples):7.1f}   "
          f"[depth={last['depthCacheHit']} refined={last['refinedCacheHit']} "
          f"mask={last['maskCacheHit']}]")

    parts, total = [], 0.0
    for stage in STAGES:
        value = statistics.median([o["timings"][stage] for o in outcomes])
        total += value
        parts.append(f"{stage[:-2].lower()}={value:.0f}")
    print(f"{'':22s}   stages: {'  '.join(parts)}   "
          f"sum={total:.0f} ms   other={median - total:.0f} ms   "
          f"(wallpaper {last['width']}x{last['height']}, "
          f"mask {last['maskWidth']}x{last['maskHeight']})")
    return median


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wallpaper", required=True)
    parser.add_argument("--data-dir", required=True,
                        help="scratch copy of the engine data directory")
    parser.add_argument("--threshold", type=float, default=0.30)
    parser.add_argument("--feather", type=float, default=0.08)
    parser.add_argument("--runs", type=int, default=5,
                        help="timed runs per scenario; the cold scenario uses a third of them")
    args = parser.parse_args()

    data_dir = os.path.abspath(args.data_dir)
    if data_dir == os.path.abspath(default_data_dir()):
        sys.exit("refusing to benchmark the live data directory: this script deletes\n"
                 "cache entries. Copy it somewhere scratch first, e.g.\n"
                 f"  cp -a {data_dir} /tmp/dsbench")
    if not os.path.isfile(args.wallpaper):
        sys.exit(f"wallpaper not found: {args.wallpaper}")
    for tier in ("depth", "refined", "masks"):
        os.makedirs(os.path.join(data_dir, "cache", tier), exist_ok=True)

    engine = find_engine()
    print(f"engine    {engine}")
    print(f"data dir  {data_dir}")
    print(f"wallpaper {args.wallpaper}")
    print()

    # Warm once so every scenario starts from a known-populated cache.
    run(engine, data_dir, args.wallpaper, args.threshold, args.feather)

    cold_runs = max(2, args.runs // 3)
    bench(engine, data_dir, args.wallpaper, "all cache hit",
          lambda: None, args.threshold, args.feather, args.runs)
    bench(engine, data_dir, args.wallpaper, "mask miss (sliders)",
          lambda: clear(data_dir, "masks"), args.threshold, args.feather, args.runs)
    bench(engine, data_dir, args.wallpaper, "refined + mask miss",
          lambda: (clear(data_dir, "masks"), clear(data_dir, "refined")),
          args.threshold, args.feather, args.runs)
    bench(engine, data_dir, args.wallpaper, "cold (all miss)",
          lambda: (clear(data_dir, "masks"), clear(data_dir, "refined"),
                   clear(data_dir, "depth")),
          args.threshold, args.feather, cold_runs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
