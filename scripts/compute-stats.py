#!/usr/bin/env python3
"""compute-stats.py — Compute latency statistics from benchmark output files.

Reads /tmp/<function>_latencies.txt files (one latency value in ms per line),
computes P50, P95, P99, mean, stddev, min, max for each function, and prints
a summary table suitable for inclusion in the execution log.

Usage: python3 compute-stats.py [functions...]
Example: python3 compute-stats.py image-resize db-query log-filter
         python3 compute-stats.py  # defaults to all 6 functions
"""

import sys
import os

DEFAULT_FUNCTIONS = [
    "image-resize", "image-resize-oc",
    "db-query", "db-query-oc",
    "log-filter", "log-filter-oc",
]


def compute_stats(values):
    """Compute descriptive statistics for a list of integer latency values."""
    vals = sorted(values)
    n = len(vals)
    mean = sum(vals) / n
    variance = sum((x - mean) ** 2 for x in vals) / n
    stddev = variance ** 0.5

    def percentile(p):
        idx = int(p * n)
        if idx >= n:
            idx = n - 1
        return vals[idx]

    return {
        "count": n,
        "min": vals[0],
        "max": vals[-1],
        "mean": round(mean, 1),
        "stddev": round(stddev, 1),
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
    }


def main():
    functions = sys.argv[1:] if len(sys.argv) > 1 else DEFAULT_FUNCTIONS

    print(f"{'Function':<20} {'Count':>5} {'Min':>6} {'P50':>6} {'P95':>6} {'P99':>6} {'Max':>6} {'Mean':>8} {'StdDev':>8}")
    print("-" * 85)

    for func in functions:
        filepath = f"/tmp/{func}_latencies.txt"
        if not os.path.exists(filepath):
            print(f"{func:<20} — file not found: {filepath}")
            continue

        with open(filepath) as f:
            values = [int(line.strip()) for line in f if line.strip()]

        if not values:
            print(f"{func:<20} — empty file")
            continue

        s = compute_stats(values)
        print(f"{func:<20} {s['count']:>5} {s['min']:>5}ms {s['p50']:>5}ms {s['p95']:>5}ms {s['p99']:>5}ms {s['max']:>5}ms {s['mean']:>7}ms {s['stddev']:>7}ms")

    print("-" * 85)
    print("\nSLO Thresholds (Non-OC P95 values):")
    for func in ["image-resize", "db-query", "log-filter"]:
        filepath = f"/tmp/{func}_latencies.txt"
        if os.path.exists(filepath):
            with open(filepath) as f:
                values = sorted([int(line.strip()) for line in f if line.strip()])
            p95 = values[int(0.95 * len(values))]
            print(f"  SLO_{func.replace('-', '_')} = {p95} ms")


if __name__ == "__main__":
    main()
