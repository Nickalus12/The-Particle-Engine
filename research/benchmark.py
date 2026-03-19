#!/usr/bin/env python3
"""The Particle Engine -- Unified Benchmark System.

A comprehensive analytics engine that runs ALL tests, computes rich metrics,
tracks trends, and produces beautiful terminal output with actionable
recommendations.

Usage:
    python research/benchmark.py              # Full run
    python research/benchmark.py --quick      # Skip slow tests (chaos, performance)
    python research/benchmark.py --physics-only
    python research/benchmark.py --visual-only
    python research/benchmark.py --json       # Machine-readable JSON output
    python research/benchmark.py --compare    # Compare to last saved run
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
RESEARCH_DIR = Path(__file__).resolve().parent
PROJECT_DIR = RESEARCH_DIR.parent
HISTORY_FILE = RESEARCH_DIR / "benchmark_history.jsonl"
TESTS_DIR = RESEARCH_DIR / "tests"

# ---------------------------------------------------------------------------
# Domain weights -- how much each category contributes to its domain score
# ---------------------------------------------------------------------------
DOMAIN_WEIGHTS: dict[str, dict[str, float]] = {
    "Physics": {
        "Kinematics": 0.12,
        "Fluid Dynamics": 0.10,
        "Fluid Statics": 0.08,
        "Thermodynamics": 0.10,
        "Phase Changes": 0.10,
        "Granular Physics": 0.08,
        "Combustion": 0.07,
        "Chemical Reactions": 0.10,
        "Structural Mechanics": 0.08,
        "Conservation Laws": 0.10,
        "Erosion & Weathering": 0.05,
        "Ecosystem": 0.02,
    },
    "Visuals": {
        "Visual: Color Science": 0.60,
        "Visual: Quality": 0.40,
    },
    "Infrastructure": {
        "Energy Budget": 0.20,
        "Property Invariants": 0.25,
        "Snapshot Regression": 0.15,
        "Chaos / Fuzz": 0.20,
        "Stability / Drift": 0.15,
        "Performance": 0.05,
    },
}

# ---------------------------------------------------------------------------
# Test file -> category mapping
# ---------------------------------------------------------------------------
FILE_TO_CATEGORY: dict[str, str] = {
    "test_kinematics.py": "Kinematics",
    "test_fluid_dynamics.py": "Fluid Dynamics",
    "test_fluid_statics.py": "Fluid Statics",
    "test_thermodynamics.py": "Thermodynamics",
    "test_phase_changes.py": "Phase Changes",
    "test_granular.py": "Granular Physics",
    "test_combustion.py": "Combustion",
    "test_reactions.py": "Chemical Reactions",
    "test_structural.py": "Structural Mechanics",
    "test_conservation.py": "Conservation Laws",
    "test_erosion.py": "Erosion & Weathering",
    "test_ecosystem.py": "Ecosystem",
    "test_visuals.py": "Visual: Color Science",
    "test_visual_quality.py": "Visual: Quality",
    "test_energy.py": "Energy Budget",
    "test_properties.py": "Property Invariants",
    "test_snapshots.py": "Snapshot Regression",
    "test_chaos.py": "Chaos / Fuzz",
    "test_stability.py": "Stability / Drift",
    "test_performance.py": "Performance",
    "test_benchmark.py": "Performance",
}

# Slow test files that --quick skips
SLOW_FILES = {"test_chaos.py", "test_performance.py", "test_benchmark.py", "test_stability.py"}


# ---------------------------------------------------------------------------
# Category -> domain lookup
# ---------------------------------------------------------------------------
def _category_to_domain(category: str) -> str:
    for domain, cats in DOMAIN_WEIGHTS.items():
        if category in cats:
            return domain
    return "Infrastructure"


def _get_category_weight(category: str) -> float:
    for cats in DOMAIN_WEIGHTS.values():
        if category in cats:
            return cats[category]
    return 0.05


# ---------------------------------------------------------------------------
# pytest plugin: collects results programmatically
# ---------------------------------------------------------------------------
class BenchmarkCollector:
    """Custom pytest plugin that collects results programmatically."""

    def __init__(self, show_progress: bool = True):
        self.results: dict[str, dict[str, Any]] = defaultdict(
            lambda: {
                "passed": 0,
                "failed": 0,
                "skipped": 0,
                "errors": 0,
                "failures": [],
                "durations": [],
            }
        )
        self.total_collected = 0
        self.total_run = 0
        self.show_progress = show_progress
        self._progress_line_len = 0

    def _categorize(self, nodeid: str) -> str:
        """Map a test node ID to its category."""
        # nodeid looks like: research/tests/test_kinematics.py::TestGravity::test_...
        # Extract the filename before ::
        path_part = nodeid.replace("\\", "/").split("::")[0]
        filename = path_part.rsplit("/", 1)[-1]
        return FILE_TO_CATEGORY.get(filename, "Uncategorized")

    def pytest_collection_modifyitems(self, items: list) -> None:
        self.total_collected = len(items)

    def pytest_runtest_logreport(self, report) -> None:
        if report.when == "call":
            category = self._categorize(report.nodeid)
            if report.passed:
                self.results[category]["passed"] += 1
            elif report.failed:
                self.results[category]["failed"] += 1
                longrepr = ""
                if report.longrepr:
                    longrepr = str(report.longrepr)
                    # Trim to last meaningful line for short display
                    lines = longrepr.strip().splitlines()
                    short = lines[-1] if lines else ""
                    if len(short) > 200:
                        short = short[:200] + "..."
                else:
                    short = ""
                self.results[category]["failures"].append({
                    "name": report.nodeid.split("::")[-1],
                    "nodeid": report.nodeid,
                    "message": short,
                    "duration": report.duration,
                })
            self.results[category]["durations"].append(report.duration)
            self.total_run += 1
            if self.show_progress and self.total_collected > 0:
                self._print_progress(report.nodeid)
        elif report.when == "setup" and report.skipped:
            category = self._categorize(report.nodeid)
            self.results[category]["skipped"] += 1
            self.total_run += 1
        elif report.when == "call" and report.skipped:
            category = self._categorize(report.nodeid)
            self.results[category]["skipped"] += 1

    def _print_progress(self, current: str) -> None:
        pct = int(self.total_run / max(self.total_collected, 1) * 100)
        bar_len = 30
        filled = int(bar_len * pct / 100)
        bar = "\u2588" * filled + "\u2591" * (bar_len - filled)
        # Short test name
        short_name = current.split("::")[-1][:50]
        line = f"\r  Running tests... {bar}  {pct:3d}% ({self.total_run}/{self.total_collected})  {short_name}"
        # Pad to overwrite previous line
        padded = line.ljust(self._progress_line_len)
        self._progress_line_len = max(len(line), self._progress_line_len)
        sys.stderr.write(padded)
        sys.stderr.flush()

    def finish_progress(self) -> None:
        if self.show_progress and self.total_collected > 0:
            sys.stderr.write("\r" + " " * (self._progress_line_len + 5) + "\r")
            sys.stderr.flush()


# ---------------------------------------------------------------------------
# Core benchmark runner
# ---------------------------------------------------------------------------
def run_benchmark(
    *,
    quick: bool = False,
    physics_only: bool = False,
    visual_only: bool = False,
    json_output: bool = False,
    compare: bool = False,
    show_progress: bool = True,
) -> dict[str, Any]:
    """Run the full benchmark suite and return results dict."""
    start_time = time.time()
    timestamp = datetime.datetime.now().isoformat(timespec="seconds")

    # Build base pytest args -- suppress all default output
    base_args = [
        "--no-header",
        "--tb=no",
        "-q",
        "--continue-on-collection-errors",
        f"--rootdir={PROJECT_DIR}",
        "--override-ini=addopts=",
        "-p", "no:benchmark",  # disable pytest-benchmark plugin to avoid interference
        "-p", "no:cacheprovider",
    ]

    # Determine which test files to run
    if physics_only:
        physics_files = [
            f for f, cat in FILE_TO_CATEGORY.items()
            if _category_to_domain(cat) == "Physics"
        ]
        test_paths = [str(TESTS_DIR / f) for f in physics_files if (TESTS_DIR / f).exists()]
    elif visual_only:
        visual_files = [
            f for f, cat in FILE_TO_CATEGORY.items()
            if _category_to_domain(cat) == "Visuals"
        ]
        test_paths = [str(TESTS_DIR / f) for f in visual_files if (TESTS_DIR / f).exists()]
    else:
        test_paths = [str(TESTS_DIR)]

    pytest_args = test_paths + base_args

    if quick:
        for slow_file in SLOW_FILES:
            pytest_args.extend(["--ignore", str(TESTS_DIR / slow_file)])

    # Create collector plugin
    collector = BenchmarkCollector(show_progress=show_progress and not json_output)

    # Suppress pytest's own stdout — we produce our own report
    import io as _io
    _devnull = open(os.devnull, "w")
    _old_stdout = sys.stdout
    sys.stdout = _devnull

    try:
        ret_code = pytest.main(pytest_args, plugins=[collector])
    finally:
        sys.stdout = _old_stdout
        _devnull.close()

    collector.finish_progress()

    elapsed = time.time() - start_time

    # Compute scores
    scores = compute_scores(collector.results)
    domain_scores = compute_domain_scores(scores)
    overall = compute_overall_score(domain_scores)

    # Load history for trends
    last_run = load_last_run()
    trends = compute_trends(scores, last_run)

    # Gather all failures
    all_failures = []
    for cat, data in collector.results.items():
        for f in data["failures"]:
            all_failures.append({"category": cat, **f})

    # Recommendations
    recommendations = compute_recommendations(scores)

    # Build result
    result = {
        "timestamp": timestamp,
        "duration_seconds": round(elapsed, 2),
        "duration_human": format_duration(elapsed),
        "overall_score": round(overall, 1),
        "total_passed": sum(d["passed"] for d in collector.results.values()),
        "total_failed": sum(d["failed"] for d in collector.results.values()),
        "total_skipped": sum(d["skipped"] for d in collector.results.values()),
        "total_tests": sum(
            d["passed"] + d["failed"] + d["skipped"]
            for d in collector.results.values()
        ),
        "domain_scores": domain_scores,
        "category_scores": scores,
        "trends": trends,
        "failures": all_failures,
        "recommendations": recommendations,
        "exit_code": ret_code,
    }

    # Save to history
    save_run(result)

    # Ensure stdout supports UTF-8 for box-drawing characters (Windows compat)
    import io as _io2
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    elif sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
        sys.stdout = _io2.TextIOWrapper(
            sys.stdout.buffer, encoding="utf-8", errors="replace", line_buffering=True,
        )

    # Output
    if json_output:
        print(json.dumps(result, indent=2, default=str))
    elif compare and last_run:
        print_comparison(result, last_run)
    else:
        print_report(result)

    return result


# ---------------------------------------------------------------------------
# Score computation
# ---------------------------------------------------------------------------
def compute_scores(results: dict[str, dict]) -> dict[str, dict]:
    """Compute per-category scores."""
    scores = {}
    for category, data in results.items():
        total = data["passed"] + data["failed"]
        pass_rate = (data["passed"] / total * 100) if total > 0 else 0.0
        avg_duration = (
            sum(data["durations"]) / len(data["durations"])
            if data["durations"]
            else 0.0
        )
        scores[category] = {
            "passed": data["passed"],
            "failed": data["failed"],
            "skipped": data["skipped"],
            "total": total,
            "pass_rate": round(pass_rate, 1),
            "avg_duration_ms": round(avg_duration * 1000, 1),
            "total_duration_s": round(sum(data["durations"]), 2),
            "failures": data["failures"],
            "domain": _category_to_domain(category),
            "weight": _get_category_weight(category),
        }
    return scores


def compute_domain_scores(scores: dict[str, dict]) -> dict[str, dict]:
    """Compute weighted domain scores."""
    domain_scores = {}
    for domain, weights in DOMAIN_WEIGHTS.items():
        weighted_sum = 0.0
        weight_sum = 0.0
        cat_scores = {}
        for category, weight in weights.items():
            if category in scores:
                weighted_sum += scores[category]["pass_rate"] * weight
                weight_sum += weight
                cat_scores[category] = scores[category]["pass_rate"]
            else:
                cat_scores[category] = None
        domain_score = (weighted_sum / weight_sum * 100 / 100) if weight_sum > 0 else 0.0
        domain_scores[domain] = {
            "score": round(domain_score, 1),
            "categories": cat_scores,
        }
    return domain_scores


def compute_overall_score(domain_scores: dict[str, dict]) -> float:
    """Weighted overall score: Physics 50%, Visuals 20%, Infrastructure 30%."""
    domain_weights = {"Physics": 0.50, "Visuals": 0.20, "Infrastructure": 0.30}
    total = 0.0
    for domain, weight in domain_weights.items():
        if domain in domain_scores:
            total += domain_scores[domain]["score"] * weight
    return total


# ---------------------------------------------------------------------------
# Trends
# ---------------------------------------------------------------------------
def compute_trends(
    current_scores: dict[str, dict], last_run: dict | None
) -> dict[str, dict]:
    """Compare current scores to last run."""
    if not last_run:
        return {cat: {"direction": "\u2192", "delta": 0.0} for cat in current_scores}

    last_scores = last_run.get("category_scores", {})
    trends = {}
    for cat, data in current_scores.items():
        curr_rate = data["pass_rate"]
        prev_data = last_scores.get(cat)
        if prev_data is None:
            trends[cat] = {"direction": "\u2605", "delta": 0.0, "note": "new"}
            continue
        prev_rate = prev_data.get("pass_rate", curr_rate)
        delta = curr_rate - prev_rate
        if delta > 1:
            direction = "\u2191"
        elif delta < -1:
            direction = "\u2193"
        else:
            direction = "\u2192"
        trends[cat] = {
            "direction": direction,
            "delta": round(delta, 1),
            "prev": prev_rate,
        }
    return trends


# ---------------------------------------------------------------------------
# Recommendations engine
# ---------------------------------------------------------------------------
def compute_recommendations(scores: dict[str, dict]) -> list[dict]:
    """Rank fixes by potential score impact."""
    recommendations = []
    for category, data in scores.items():
        if data["failed"] > 0:
            weight = data["weight"]
            potential = data["failed"] / max(data["total"], 1) * weight * 100
            # Generate suggestion from failure names
            failure_names = [f["name"] for f in data["failures"][:3]]
            suggestion = f"Fix {data['failed']} failing test(s)"
            if failure_names:
                suggestion += f": {', '.join(failure_names[:2])}"
                if len(failure_names) > 2:
                    suggestion += f" (+{len(failure_names) - 2} more)"
            recommendations.append({
                "category": category,
                "domain": data["domain"],
                "potential_improvement": round(potential, 2),
                "failed_count": data["failed"],
                "pass_rate": data["pass_rate"],
                "suggestion": suggestion,
            })
    return sorted(recommendations, key=lambda x: -x["potential_improvement"])


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------
def save_run(result: dict) -> None:
    """Append run to history file."""
    slim = {
        "timestamp": result["timestamp"],
        "duration_seconds": result["duration_seconds"],
        "overall_score": result["overall_score"],
        "total_passed": result["total_passed"],
        "total_failed": result["total_failed"],
        "total_skipped": result["total_skipped"],
        "total_tests": result["total_tests"],
        "domain_scores": {
            d: {"score": v["score"]} for d, v in result["domain_scores"].items()
        },
        "category_scores": {
            cat: {
                "pass_rate": v["pass_rate"],
                "passed": v["passed"],
                "failed": v["failed"],
                "skipped": v["skipped"],
                "total": v["total"],
            }
            for cat, v in result["category_scores"].items()
        },
    }
    with open(HISTORY_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(slim, default=str) + "\n")


def load_last_run() -> dict | None:
    """Load the most recent run from history."""
    if not HISTORY_FILE.exists():
        return None
    last_line = None
    with open(HISTORY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                last_line = line
    if last_line:
        try:
            return json.loads(last_line)
        except json.JSONDecodeError:
            return None
    return None


def load_history(n: int = 20) -> list[dict]:
    """Load last N runs from history."""
    if not HISTORY_FILE.exists():
        return []
    lines = []
    with open(HISTORY_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    lines.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return lines[-n:]


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
def format_duration(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    if m > 0:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def _bar(pct: float, width: int = 40) -> str:
    filled = int(width * pct / 100)
    return "\u2588" * filled + "\u2591" * (width - filled)


def _color(text: str, code: str) -> str:
    """ANSI color wrapper."""
    codes = {
        "green": "\033[32m",
        "red": "\033[31m",
        "yellow": "\033[33m",
        "cyan": "\033[36m",
        "bold": "\033[1m",
        "dim": "\033[2m",
        "reset": "\033[0m",
        "white": "\033[37m",
        "magenta": "\033[35m",
    }
    if not sys.stdout.isatty():
        return text
    return f"{codes.get(code, '')}{text}{codes.get('reset', '')}"


def _score_color(pct: float) -> str:
    if pct >= 95:
        return "green"
    elif pct >= 80:
        return "cyan"
    elif pct >= 60:
        return "yellow"
    return "red"


def _trend_color(direction: str) -> str:
    if direction == "\u2191":
        return "green"
    elif direction == "\u2193":
        return "red"
    return "dim"


# ---------------------------------------------------------------------------
# Terminal report
# ---------------------------------------------------------------------------
def print_report(result: dict) -> None:
    """Print beautiful terminal report."""
    W = 76

    # Header
    print()
    print(_color("\u2554" + "\u2550" * W + "\u2557", "bold"))
    title = "THE PARTICLE ENGINE \u2014 BENCHMARK REPORT"
    meta = f"{result['timestamp']}  \u2022  Duration: {result['duration_human']}"
    print(_color(f"\u2551{title:^{W}}\u2551", "bold"))
    print(_color(f"\u2551{meta:^{W}}\u2551", "dim"))
    print(_color("\u255a" + "\u2550" * W + "\u255d", "bold"))
    print()

    # Overall score
    overall = result["overall_score"]
    total_p = result["total_passed"]
    total_t = result["total_tests"]
    bar = _bar(overall, 42)
    score_line = f"  OVERALL SCORE: {overall:.1f}%  {bar}  ({total_p}/{total_t})"
    print(_color(score_line, _score_color(overall)))
    print()

    # Domain sections
    for domain, ddata in result["domain_scores"].items():
        dscore = ddata["score"]
        header = f"\u2500\u2500\u2500 {domain} ({dscore:.1f}%) "
        header = header.ljust(W - 2, "\u2500")
        print(f"  \u250c{header}\u2510")
        print(f"  \u2502{' ' * (W - 2)}\u2502")

        cats = ddata.get("categories", {})
        for cat, cat_pct in cats.items():
            if cat_pct is None:
                pct_str = "  --"
                bar_str = " " * 40
                trend_str = " "
            else:
                pct_str = f"{cat_pct:3.0f}%"
                bar_str = _bar(cat_pct, 40)
                trend_data = result.get("trends", {}).get(cat, {})
                trend_str = trend_data.get("direction", "\u2192")

            cat_name = f"{cat:22s}"
            line = f"  \u2502  {cat_name} {bar_str} {pct_str} {trend_str} \u2502"
            # Colorize
            if cat_pct is not None:
                col = _score_color(cat_pct)
                tcol = _trend_color(trend_str)
                cat_name_c = cat_name
                bar_c = _color(bar_str, col)
                pct_c = _color(pct_str, col)
                trend_c = _color(trend_str, tcol)
                line = f"  \u2502  {cat_name_c} {bar_c} {pct_c} {trend_c} \u2502"
            print(line)

        print(f"  \u2502{' ' * (W - 2)}\u2502")
        print(f"  \u2514" + "\u2500" * (W - 2) + "\u2518")
        print()

    # Failures
    failures = result.get("failures", [])
    if failures:
        print(f"  FAILURES ({len(failures)}):")
        for f in failures[:15]:
            cat = f["category"]
            name = f["name"]
            msg = f.get("message", "")
            if msg and len(msg) > 60:
                msg = msg[:60] + "..."
            print(_color(f"    \u2717 [{cat}] {name}", "red"))
            if msg:
                print(_color(f"      {msg}", "dim"))
        if len(failures) > 15:
            print(_color(f"    ... and {len(failures) - 15} more", "dim"))
        print()

    # Trends summary
    trends = result.get("trends", {})
    improved = [(c, t) for c, t in trends.items() if t["direction"] == "\u2191"]
    regressed = [(c, t) for c, t in trends.items() if t["direction"] == "\u2193"]
    stable = [(c, t) for c, t in trends.items() if t["direction"] == "\u2192"]

    if improved or regressed:
        print("  TRENDS (vs last run):")
        for cat, t in improved:
            prev = t.get("prev", 0)
            curr = result["category_scores"].get(cat, {}).get("pass_rate", 0)
            print(_color(f"    \u2191 {cat}: {prev:.0f}% \u2192 {curr:.0f}% (+{t['delta']:.0f}%)", "green"))
        for cat, t in regressed:
            prev = t.get("prev", 0)
            curr = result["category_scores"].get(cat, {}).get("pass_rate", 0)
            print(_color(f"    \u2193 {cat}: {prev:.0f}% \u2192 {curr:.0f}% ({t['delta']:.0f}%)", "red"))
        if stable:
            print(_color(f"    \u2192 {len(stable)} categories stable", "dim"))
        print()

    # Recommendations
    recs = result.get("recommendations", [])
    if recs:
        print("  RECOMMENDATIONS:")
        for i, rec in enumerate(recs[:5], 1):
            cat = rec["category"]
            sug = rec["suggestion"]
            pot = rec["potential_improvement"]
            print(f"    {i}. {sug} ({cat}, +{pot:.1f}% potential)")
        print()


# ---------------------------------------------------------------------------
# Comparison report
# ---------------------------------------------------------------------------
def print_comparison(current: dict, previous: dict) -> None:
    """Print side-by-side comparison."""
    print()
    print(_color("  BENCHMARK COMPARISON", "bold"))
    print(_color(f"  Previous: {previous.get('timestamp', '?')}", "dim"))
    print(_color(f"  Current:  {current['timestamp']}", "dim"))
    print()

    prev_overall = previous.get("overall_score", 0)
    curr_overall = current["overall_score"]
    delta = curr_overall - prev_overall
    delta_str = f"+{delta:.1f}" if delta >= 0 else f"{delta:.1f}"
    col = "green" if delta >= 0 else "red"
    print(f"  Overall: {prev_overall:.1f}% -> {curr_overall:.1f}%  ({_color(delta_str + '%', col)})")
    print()

    # Per-category comparison
    prev_cats = previous.get("category_scores", {})
    curr_cats = current.get("category_scores", {})
    all_cats = sorted(set(list(prev_cats.keys()) + list(curr_cats.keys())))

    fmt = "  {:<24s}  {:>6s}  {:>6s}  {:>8s}"
    print(fmt.format("Category", "Prev", "Curr", "Delta"))
    print("  " + "-" * 50)
    for cat in all_cats:
        p = prev_cats.get(cat, {}).get("pass_rate", 0)
        c = curr_cats.get(cat, {}).get("pass_rate", 0)
        d = c - p
        d_str = f"+{d:.1f}%" if d >= 0 else f"{d:.1f}%"
        col = "green" if d > 0 else ("red" if d < 0 else "dim")
        print(f"  {cat:<24s}  {p:5.1f}%  {c:5.1f}%  {_color(d_str, col):>8s}")
    print()

    # Print regular report too
    print_report(current)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(
        description="The Particle Engine -- Unified Benchmark",
    )
    parser.add_argument("--quick", action="store_true", help="Skip slow tests")
    parser.add_argument("--physics-only", action="store_true", help="Physics tests only")
    parser.add_argument("--visual-only", action="store_true", help="Visual tests only")
    parser.add_argument("--json", action="store_true", dest="json_output", help="JSON output")
    parser.add_argument("--compare", action="store_true", help="Compare to last run")
    args = parser.parse_args()

    result = run_benchmark(
        quick=args.quick,
        physics_only=args.physics_only,
        visual_only=args.visual_only,
        json_output=args.json_output,
        compare=args.compare,
    )

    # Exit 0 if score > 50%, else 1
    return 0 if result["overall_score"] >= 50 else 1


if __name__ == "__main__":
    sys.exit(main())
