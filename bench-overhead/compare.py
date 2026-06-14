#!/usr/bin/env python3
"""
Compare Rust vs Python benchmark client accuracy against ground truth.

Loads result JSONs (both clients use --save-detailed, same schema),
computes error metrics vs known mock-server timing, prints table.

Usage:
    python3 compare.py --results-dir ./results \
        --token-interval-ms 10 --first-token-delay-ms 50
"""

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np


def load_result(filepath: str) -> dict:
    """Load a benchmark result JSON (works for both Rust and Python/vllm)."""
    with open(filepath) as f:
        data = json.load(f)

    ttfts = np.array(data.get("ttfts", []))
    itls_nested = data.get("itls", [])  # list of lists
    all_itls = np.array([v for sub in itls_nested for v in sub])

    return {
        "completed": data.get("completed", 0),
        "failed": data.get("failed", 0),
        "duration": data.get("duration", 0),
        "ttfts": ttfts,
        "itls": all_itls,
    }


def compute_error_metrics(result: dict, truth_ttft_s: float, truth_itl_s: float) -> dict:
    """Compute accuracy error metrics against ground truth."""
    ttfts, itls = result["ttfts"], result["itls"]

    ttft_errors = np.abs(ttfts - truth_ttft_s) if len(ttfts) else np.array([])
    itl_errors = np.abs(itls - truth_itl_s) if len(itls) else np.array([])

    ms = 1000  # conversion factor
    return {
        "mean_ttft_ms": float(np.mean(ttfts) * ms) if len(ttfts) else 0,
        "ttft_mae_ms": float(np.mean(ttft_errors) * ms) if len(ttft_errors) else 0,
        "mean_itl_ms": float(np.mean(itls) * ms) if len(itls) else 0,
        "itl_mae_ms": float(np.mean(itl_errors) * ms) if len(itl_errors) else 0,
        "p99_itl_ms": float(np.percentile(itls, 99) * ms) if len(itls) else 0,
        "max_itl_ms": float(np.max(itls) * ms) if len(itls) else 0,
        "itl_std_ms": float(np.std(itls) * ms) if len(itls) else 0,
        "completed": result["completed"],
        "failed": result["failed"],
    }


def parse_concurrency(filename: str) -> int | None:
    """Extract concurrency from filename like 'python-c100.json' or 'rust-c100.json'."""
    m = re.search(r"-c(\d+)\.json$", filename)
    return int(m.group(1)) if m else None


def load_all_results(results_dir: str, truth_ttft_s: float, truth_itl_s: float) -> list[dict]:
    """Load all result files and compute error metrics."""
    rows = []
    for pattern, client in [("python-c*.json", "python"), ("rust-c*.json", "rust")]:
        for path in sorted(Path(results_dir).glob(pattern)):
            conc = parse_concurrency(path.name)
            if conc is None:
                print(f"Warning: cannot parse concurrency from {path.name}, skipping")
                continue
            data = load_result(str(path))
            metrics = compute_error_metrics(data, truth_ttft_s, truth_itl_s)
            metrics["concurrency"] = conc
            metrics["client"] = client
            rows.append(metrics)
    rows.sort(key=lambda r: (r["concurrency"], r["client"]))
    return rows


def print_table(rows: list[dict], truth_ttft_ms: float, truth_itl_ms: float):
    """Print formatted comparison table."""
    print(f"\nGround truth: TTFT = {truth_ttft_ms:.1f}ms, ITL = {truth_itl_ms:.1f}ms\n")

    header = (
        f"{'Conc':>5} | {'Client':>7} | {'Done':>5} | "
        f"{'TTFT':>8} | {'TTFT Err':>8} | "
        f"{'ITL Mean':>8} | {'ITL Err':>8} | {'ITL P99':>8} | {'ITL Max':>8} | "
        f"{'ITL Std':>8}"
    )
    print(header)
    print("-" * len(header))

    for r in rows:
        print(
            f"{r['concurrency']:>5} | {r['client']:>7} | {r['completed']:>5} | "
            f"{r['mean_ttft_ms']:>7.2f}ms | {r['ttft_mae_ms']:>7.2f}ms | "
            f"{r['mean_itl_ms']:>7.2f}ms | {r['itl_mae_ms']:>7.2f}ms | "
            f"{r['p99_itl_ms']:>7.2f}ms | {r['max_itl_ms']:>7.2f}ms | "
            f"{r['itl_std_ms']:>7.2f}ms"
        )
    print()


def main():
    parser = argparse.ArgumentParser(description="Compare Rust vs Python benchmark accuracy")
    parser.add_argument("--results-dir", default="./results")
    parser.add_argument("--token-interval-ms", type=float, default=10.0)
    parser.add_argument("--first-token-delay-ms", type=float, default=50.0)
    args = parser.parse_args()

    truth_ttft_s = args.first_token_delay_ms / 1000.0
    truth_itl_s = args.token_interval_ms / 1000.0

    rows = load_all_results(args.results_dir, truth_ttft_s, truth_itl_s)
    if not rows:
        print(f"No result files found in {args.results_dir}")
        sys.exit(1)

    print_table(rows, args.first_token_delay_ms, args.token_interval_ms)

    # Save comparison JSON
    output_path = Path(args.results_dir) / "comparison.json"
    with open(output_path, "w") as f:
        json.dump({
            "ground_truth": {"ttft_ms": args.first_token_delay_ms, "itl_ms": args.token_interval_ms},
            "results": rows,
        }, f, indent=2)
    print(f"Comparison saved to {output_path}")


if __name__ == "__main__":
    main()
