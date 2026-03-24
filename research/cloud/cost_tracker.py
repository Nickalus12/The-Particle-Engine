#!/usr/bin/env python3
"""Track GPU cloud spending for The Particle Engine research pipeline.

Logs every session with timing, GPU type, mode, and cost. Provides running
totals, cost-per-deliverable breakdowns, and budget alerts.

Usage:
    # Log a session (called automatically by deploy_and_run.py)
    python research/cloud/cost_tracker.py log \
        --gpu a100xl --mode full --duration 7200 --note "Full pipeline run"

    # Show spending summary
    python research/cloud/cost_tracker.py summary

    # Show cost per deliverable
    python research/cloud/cost_tracker.py breakdown

    # Check if budget allows a run
    python research/cloud/cost_tracker.py check --gpu a100xl --hours 3 --budget 50.00
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

COST_LOG = Path(__file__).resolve().parent / ".cost_log.jsonl"

# ThunderCompute GPU pricing ($/hour) — update as needed
GPU_PRICING = {
    "a6000": 0.27,
    "a100": 0.78,
    "a100xl": 0.78,
    "h100": 1.99,
    "cpu": 0.00,
}

# What each pipeline mode produces
MODE_DELIVERABLES = {
    "full": ["physics_params", "trained_genomes", "shader_params", "chemistry_data",
             "dart_benchmark", "audio_files", "style_palettes", "worldgen_params",
             "regression_baselines", "texture_atlas"],
    "classic": ["physics_params", "trained_genomes", "shader_params", "chemistry_data", "dart_benchmark"],
    "v2": ["audio_files", "style_palettes", "worldgen_params", "regression_baselines", "texture_atlas"],
    "creatures": ["trained_genomes"],
    "physics": ["physics_params"],
    "shaders": ["shader_params"],
    "chemistry": ["chemistry_data"],
    "audio": ["audio_files"],
    "style": ["style_palettes"],
    "worldgen": ["worldgen_params"],
    "regression": ["regression_baselines"],
    "textures": ["texture_atlas"],
    "quick": ["physics_params", "trained_genomes", "shader_params", "worldgen_params",
              "regression_baselines", "audio_files", "texture_atlas"],
}


def log_session(gpu: str, mode: str, duration_s: int, note: str = "",
                success: bool = True) -> dict:
    """Log a completed session."""
    rate = GPU_PRICING.get(gpu, 0.0)
    cost = rate * duration_s / 3600.0

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "gpu": gpu,
        "mode": mode,
        "duration_s": duration_s,
        "rate_per_hr": rate,
        "cost_usd": round(cost, 4),
        "success": success,
        "note": note,
        "deliverables": MODE_DELIVERABLES.get(mode, []),
    }

    COST_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(COST_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

    print(f"Logged: {mode} on {gpu} for {duration_s // 60}m {duration_s % 60}s = ${cost:.4f}", flush=True)
    return entry


def load_sessions() -> list[dict]:
    """Load all logged sessions."""
    if not COST_LOG.exists():
        return []
    sessions = []
    for line in COST_LOG.read_text().strip().split("\n"):
        if line.strip():
            sessions.append(json.loads(line))
    return sessions


def show_summary():
    """Print spending summary."""
    sessions = load_sessions()
    if not sessions:
        print("No sessions logged yet.", flush=True)
        return

    total_cost = sum(s["cost_usd"] for s in sessions)
    total_time = sum(s["duration_s"] for s in sessions)
    successful = [s for s in sessions if s.get("success", True)]

    # By GPU type
    by_gpu: dict[str, float] = {}
    for s in sessions:
        by_gpu[s["gpu"]] = by_gpu.get(s["gpu"], 0.0) + s["cost_usd"]

    # By mode
    by_mode: dict[str, float] = {}
    for s in sessions:
        by_mode[s["mode"]] = by_mode.get(s["mode"], 0.0) + s["cost_usd"]

    print("\n" + "=" * 50, flush=True)
    print("  SPENDING SUMMARY", flush=True)
    print("=" * 50, flush=True)
    print(f"  Total sessions: {len(sessions)} ({len(successful)} successful)", flush=True)
    print(f"  Total time:     {total_time // 3600}h {(total_time % 3600) // 60}m", flush=True)
    print(f"  Total cost:     ${total_cost:.2f}", flush=True)
    print(flush=True)

    print("  By GPU:", flush=True)
    for gpu, cost in sorted(by_gpu.items(), key=lambda x: -x[1]):
        rate = GPU_PRICING.get(gpu, 0)
        print(f"    {gpu:<10} ${cost:.2f}  (${rate}/hr)", flush=True)

    print(flush=True)
    print("  By mode:", flush=True)
    for mode, cost in sorted(by_mode.items(), key=lambda x: -x[1]):
        count = sum(1 for s in sessions if s["mode"] == mode)
        print(f"    {mode:<12} ${cost:.2f}  ({count} runs)", flush=True)

    # Recent sessions
    print(flush=True)
    print("  Recent sessions:", flush=True)
    for s in sessions[-5:]:
        ts = s["timestamp"][:16].replace("T", " ")
        dur = f"{s['duration_s'] // 60}m"
        status = "OK" if s.get("success", True) else "FAIL"
        print(f"    {ts}  {s['gpu']:<8} {s['mode']:<10} {dur:<6} ${s['cost_usd']:.4f} [{status}]", flush=True)

    print("=" * 50, flush=True)


def show_breakdown():
    """Show cost per deliverable type."""
    sessions = load_sessions()
    if not sessions:
        print("No sessions logged yet.", flush=True)
        return

    deliverable_cost: dict[str, float] = {}
    deliverable_count: dict[str, int] = {}

    for s in sessions:
        if not s.get("success", True):
            continue
        delivs = s.get("deliverables", [])
        if not delivs:
            continue
        cost_per = s["cost_usd"] / len(delivs)
        for d in delivs:
            deliverable_cost[d] = deliverable_cost.get(d, 0.0) + cost_per
            deliverable_count[d] = deliverable_count.get(d, 0) + 1

    print("\n" + "=" * 50, flush=True)
    print("  COST PER DELIVERABLE", flush=True)
    print("=" * 50, flush=True)
    for d, cost in sorted(deliverable_cost.items(), key=lambda x: -x[1]):
        count = deliverable_count[d]
        avg = cost / count if count else 0
        print(f"  {d:<24} ${cost:.2f} total  ({count} runs, ${avg:.2f} avg)", flush=True)
    print("=" * 50, flush=True)


def check_budget(gpu: str, hours: float, budget: float):
    """Check if a planned run fits within budget."""
    sessions = load_sessions()
    spent = sum(s["cost_usd"] for s in sessions)
    rate = GPU_PRICING.get(gpu, 0.0)
    planned_cost = rate * hours
    remaining = budget - spent

    print(f"\nBudget check:", flush=True)
    print(f"  Total budget:   ${budget:.2f}", flush=True)
    print(f"  Already spent:  ${spent:.2f}", flush=True)
    print(f"  Remaining:      ${remaining:.2f}", flush=True)
    print(f"  Planned run:    {gpu} x {hours}h = ${planned_cost:.2f}", flush=True)

    if planned_cost > remaining:
        print(f"\n  OVER BUDGET by ${planned_cost - remaining:.2f}", flush=True)
        print(f"  Consider: a6000 x {hours}h = ${GPU_PRICING['a6000'] * hours:.2f}", flush=True)
        sys.exit(1)
    else:
        print(f"\n  OK — ${remaining - planned_cost:.2f} would remain after this run", flush=True)


def main():
    parser = argparse.ArgumentParser(description="GPU cost tracker")
    sub = parser.add_subparsers(dest="command")

    log_p = sub.add_parser("log", help="Log a session")
    log_p.add_argument("--gpu", required=True, help="GPU type")
    log_p.add_argument("--mode", required=True, help="Pipeline mode")
    log_p.add_argument("--duration", type=int, required=True, help="Duration in seconds")
    log_p.add_argument("--note", default="", help="Session note")
    log_p.add_argument("--failed", action="store_true", help="Mark as failed")

    sub.add_parser("summary", help="Show spending summary")
    sub.add_parser("breakdown", help="Show cost per deliverable")

    check_p = sub.add_parser("check", help="Check budget")
    check_p.add_argument("--gpu", required=True, help="GPU type")
    check_p.add_argument("--hours", type=float, required=True, help="Planned hours")
    check_p.add_argument("--budget", type=float, default=50.0, help="Total budget ($)")

    args = parser.parse_args()

    if args.command == "log":
        log_session(args.gpu, args.mode, args.duration,
                    note=args.note, success=not args.failed)
    elif args.command == "summary":
        show_summary()
    elif args.command == "breakdown":
        show_breakdown()
    elif args.command == "check":
        check_budget(args.gpu, args.hours, args.budget)
    else:
        parser.print_help()


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert callable(log_session)
        assert callable(load_sessions)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
