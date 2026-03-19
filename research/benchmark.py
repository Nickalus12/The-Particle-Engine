#!/usr/bin/env python3
"""
The Particle Engine — Unified Benchmark Runner
================================================

Single entry point that runs ALL pytest tests, aggregates results by
category, computes accuracy scores, and prints a dashboard.

Usage:
    python research/benchmark.py              # Full dashboard
    python research/benchmark.py --json       # Machine-readable JSON output
    python research/benchmark.py --save       # Save results to benchmark_history.jsonl
    python research/benchmark.py --quick      # Skip slow tests (benchmark, chaos)
"""

import json
import subprocess
import sys
import os
import re
from datetime import datetime
from pathlib import Path
from collections import defaultdict

RESEARCH_DIR = Path(__file__).parent
PROJECT_DIR = RESEARCH_DIR.parent

# Map test files to human-readable categories
CATEGORIES = {
    "test_kinematics": "Kinematics",
    "test_fluid_dynamics": "Fluid Dynamics",
    "test_fluid_statics": "Fluid Statics",
    "test_thermodynamics": "Thermodynamics",
    "test_phase_changes": "Phase Changes",
    "test_granular": "Granular Physics",
    "test_combustion": "Combustion",
    "test_reactions": "Chemical Reactions",
    "test_structural": "Structural Mechanics",
    "test_conservation": "Conservation Laws",
    "test_erosion": "Erosion & Weathering",
    "test_ecosystem": "Ecosystem",
    "test_visuals": "Visual: Color Science",
    "test_visual_quality": "Visual: Quality",
    "test_energy": "Energy Budget",
    "test_chaos": "Chaos / Fuzz",
    "test_properties": "Property Invariants",
    "test_snapshots": "Snapshot Regression",
    "test_stability": "Stability / Drift",
    "test_performance": "Performance",
    "test_benchmark": "Benchmarks",
}


def run_pytest(quick=False):
    """Run pytest and capture structured output."""
    cmd = [
        sys.executable, "-m", "pytest",
        str(RESEARCH_DIR / "tests"),
        "-v", "--tb=no", "--no-header", "-q",
    ]
    if quick:
        cmd.extend(["-m", "not slow and not benchmark"])

    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"

    result = subprocess.run(
        cmd, capture_output=True, text=True, timeout=900,
        cwd=str(PROJECT_DIR), env=env
    )
    return result.stdout, result.stderr, result.returncode


def parse_results(stdout):
    """Parse pytest verbose output into per-test results."""
    results = defaultdict(lambda: {"passed": 0, "failed": 0, "skipped": 0, "tests": []})

    for line in stdout.splitlines():
        # Match lines like: research\tests\test_kinematics.py::TestGravity::test_sand_falls PASSED
        match = re.match(
            r'research[/\\]tests[/\\](test_\w+)\.py::(\S+)\s+(PASSED|FAILED|SKIPPED|ERROR)',
            line
        )
        if match:
            file_key = match.group(1)
            test_name = match.group(2)
            status = match.group(3)

            category = CATEGORIES.get(file_key, file_key)

            if status == "PASSED":
                results[category]["passed"] += 1
            elif status in ("FAILED", "ERROR"):
                results[category]["failed"] += 1
                results[category]["tests"].append(test_name)
            elif status == "SKIPPED":
                results[category]["skipped"] += 1

    # Also parse the summary line
    summary_match = re.search(
        r'(\d+) passed(?:, (\d+) failed)?(?:, (\d+) skipped)?',
        stdout
    )
    total_passed = int(summary_match.group(1)) if summary_match else 0
    total_failed = int(summary_match.group(2) or 0) if summary_match else 0
    total_skipped = int(summary_match.group(3) or 0) if summary_match else 0

    return dict(results), total_passed, total_failed, total_skipped


def compute_scores(results):
    """Compute per-category and overall scores."""
    scores = {}
    total_passed = 0
    total_tests = 0

    for category, data in sorted(results.items()):
        passed = data["passed"]
        failed = data["failed"]
        skipped = data["skipped"]
        total = passed + failed

        if total > 0:
            score = passed / total * 100
        else:
            score = 100.0  # all skipped = no failures

        scores[category] = {
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "total": total,
            "score": round(score, 1),
            "failed_tests": data["tests"],
        }
        total_passed += passed
        total_tests += total

    overall = round(total_passed / max(total_tests, 1) * 100, 1)

    return scores, overall, total_passed, total_tests


def print_dashboard(scores, overall, total_passed, total_tests, elapsed_sec):
    """Print a beautiful ASCII dashboard."""
    print()
    print("╔══════════════════════════════════════════════════════════════════════╗")
    print("║         THE PARTICLE ENGINE — UNIFIED BENCHMARK DASHBOARD          ║")
    print("╚══════════════════════════════════════════════════════════════════════╝")
    print()
    print(f"  Timestamp:  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Duration:   {elapsed_sec:.1f}s")
    print(f"  Total:      {total_passed}/{total_tests} tests passed")
    print()

    # Category breakdown
    print("  ┌────────────────────────────┬────────┬────────┬────────┬────────┐")
    print("  │ Category                   │ Passed │ Failed │ Skip   │ Score  │")
    print("  ├────────────────────────────┼────────┼────────┼────────┼────────┤")

    for category in sorted(scores.keys()):
        data = scores[category]
        name = category[:26].ljust(26)
        passed = str(data["passed"]).rjust(5)
        failed = str(data["failed"]).rjust(5)
        skipped = str(data["skipped"]).rjust(5)
        score = f"{data['score']}%".rjust(6)

        # Color indicator
        if data["score"] >= 98:
            indicator = "  │"
        elif data["score"] >= 90:
            indicator = " ~│"
        elif data["score"] >= 70:
            indicator = " !│"
        else:
            indicator = " X│"

        print(f"  │ {name} │{passed} │{failed} │{skipped} │{score}{indicator}")

    print("  ├────────────────────────────┼────────┼────────┼────────┼────────┤")
    total_failed = total_tests - total_passed
    print(f"  │ {'OVERALL'.ljust(26)} │{str(total_passed).rjust(5)} │{str(total_failed).rjust(5)} │{''.rjust(5)} │{f'{overall}%'.rjust(6)}  │")
    print("  └────────────────────────────┴────────┴────────┴────────┴────────┘")
    print()

    # Failed tests detail
    any_failures = False
    for category, data in sorted(scores.items()):
        if data["failed_tests"]:
            if not any_failures:
                print("  Failed Tests:")
                any_failures = True
            for test in data["failed_tests"][:5]:  # max 5 per category
                print(f"    ✗ [{category}] {test}")
            if len(data["failed_tests"]) > 5:
                print(f"      ... and {len(data['failed_tests']) - 5} more")

    if not any_failures:
        print("  ✓ All tests passing!")
    print()

    # Score summary by domain
    physics_cats = ["Kinematics", "Fluid Dynamics", "Fluid Statics", "Thermodynamics",
                    "Phase Changes", "Granular Physics", "Combustion", "Chemical Reactions",
                    "Structural Mechanics", "Conservation Laws", "Erosion & Weathering", "Ecosystem"]
    visual_cats = ["Visual: Color Science", "Visual: Quality"]
    infra_cats = ["Energy Budget", "Chaos / Fuzz", "Property Invariants",
                  "Snapshot Regression", "Stability / Drift", "Performance", "Benchmarks"]

    def domain_score(cats):
        p = sum(scores.get(c, {}).get("passed", 0) for c in cats)
        t = sum(scores.get(c, {}).get("total", 0) for c in cats)
        return round(p / max(t, 1) * 100, 1), p, t

    phys_score, phys_p, phys_t = domain_score(physics_cats)
    vis_score, vis_p, vis_t = domain_score(visual_cats)
    infra_score, infra_p, infra_t = domain_score(infra_cats)

    print("  Domain Scores:")
    print(f"    Physics:        {phys_score}%  ({phys_p}/{phys_t})")
    print(f"    Visuals:        {vis_score}%  ({vis_p}/{vis_t})")
    print(f"    Infrastructure: {infra_score}%  ({infra_p}/{infra_t})")
    print()


def save_results(scores, overall, total_passed, total_tests):
    """Append results to benchmark_history.jsonl."""
    entry = {
        "timestamp": datetime.now().isoformat(),
        "overall_score": overall,
        "total_passed": total_passed,
        "total_tests": total_tests,
        "categories": {k: {"passed": v["passed"], "failed": v["failed"],
                          "skipped": v["skipped"], "score": v["score"]}
                      for k, v in scores.items()},
    }

    history_path = RESEARCH_DIR / "benchmark_history.jsonl"
    with open(history_path, "a") as f:
        f.write(json.dumps(entry) + "\n")

    print(f"  Results saved to {history_path}")


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    save = "--save" in args
    quick = "--quick" in args

    if not as_json:
        print("\n  Running full test suite...")

    import time
    start = time.time()

    stdout, stderr, returncode = run_pytest(quick=quick)

    elapsed = time.time() - start

    results, total_p, total_f, total_s = parse_results(stdout)
    scores, overall, total_passed, total_tests = compute_scores(results)

    if as_json:
        output = {
            "timestamp": datetime.now().isoformat(),
            "overall": overall,
            "passed": total_passed,
            "failed": total_tests - total_passed,
            "skipped": total_s,
            "total": total_tests,
            "elapsed_seconds": round(elapsed, 1),
            "categories": scores,
        }
        print(json.dumps(output, indent=2))
    else:
        print_dashboard(scores, overall, total_passed, total_tests, elapsed)

    if save:
        save_results(scores, overall, total_passed, total_tests)

    # Exit with 0 if > 95% pass, 1 otherwise
    sys.exit(0 if overall >= 95.0 else 1)


if __name__ == "__main__":
    main()
