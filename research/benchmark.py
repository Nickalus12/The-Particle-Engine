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
    python research/benchmark.py --history    # Show score history with sparklines
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Windows UTF-8 fix -- must happen before Rich creates any Console
# ---------------------------------------------------------------------------
if sys.platform == "win32":
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    if hasattr(sys.stderr, "reconfigure"):
        try:
            sys.stderr.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

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

OVERALL_DOMAIN_WEIGHT_PROFILES: dict[str, dict[str, float]] = {
    "balanced": {"Physics": 0.50, "Visuals": 0.20, "Infrastructure": 0.30},
    "mobile": {"Physics": 0.40, "Visuals": 0.15, "Infrastructure": 0.45},
    "exploratory": {"Physics": 0.55, "Visuals": 0.15, "Infrastructure": 0.30},
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


def _normalize_optuna_profile(profile: str | None) -> str:
    normalized = (profile or "balanced").strip().lower()
    if normalized in OVERALL_DOMAIN_WEIGHT_PROFILES:
        return normalized
    return "balanced"


def _sanitize_optuna_metadata(metadata: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(metadata, dict):
        return {}
    allowed_scalar_keys = {
        "profile",
        "source_label",
        "execution_mode",
        "param_count",
        "runtime_mutable_count",
        "runtime_mutable_only",
    }
    allowed_list_keys = {"search_groups"}
    cleaned: dict[str, Any] = {}
    for key in allowed_scalar_keys:
        if key not in metadata:
            continue
        value = metadata.get(key)
        if isinstance(value, (str, int, float, bool)) or value is None:
            cleaned[key] = value
    for key in allowed_list_keys:
        value = metadata.get(key)
        if isinstance(value, list):
            cleaned[key] = [str(item)[:40] for item in value[:8]]
    return cleaned


def _load_optuna_metadata(
    *,
    optuna_profile: str | None = None,
    source_label: str | None = None,
    metadata_path: str | None = None,
) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    candidate_path = metadata_path or os.environ.get("OPTUNA_METADATA_JSON")
    if candidate_path:
        try:
            payload = json.loads(Path(candidate_path).read_text(encoding="utf-8"))
            if isinstance(payload, dict):
                if isinstance(payload.get("optuna"), dict):
                    metadata.update(payload["optuna"])
                else:
                    metadata.update(payload)
        except (OSError, json.JSONDecodeError):
            pass

    env_keys = {
        "profile": "OPTUNA_PROFILE",
        "source_label": "OPTUNA_SOURCE_LABEL",
        "execution_mode": "OPTUNA_EXECUTION_MODE",
        "param_count": "OPTUNA_PARAM_COUNT",
        "runtime_mutable_count": "OPTUNA_RUNTIME_MUTABLE_COUNT",
    }
    for target_key, env_key in env_keys.items():
        raw = os.environ.get(env_key)
        if raw not in (None, "") and target_key not in metadata:
            if target_key.endswith("_count"):
                try:
                    metadata[target_key] = int(raw)
                except ValueError:
                    metadata[target_key] = raw
            else:
                metadata[target_key] = raw

    if "search_groups" not in metadata:
        raw_groups = os.environ.get("OPTUNA_SEARCH_GROUPS")
        if raw_groups:
            metadata["search_groups"] = [
                item.strip() for item in raw_groups.split(",") if item.strip()
            ]

    if optuna_profile:
        metadata["profile"] = optuna_profile
    if source_label:
        metadata["source_label"] = source_label

    metadata["profile"] = _normalize_optuna_profile(
        str(metadata.get("profile", "balanced"))
    )
    metadata.setdefault("source_label", "manual_benchmark")
    return _sanitize_optuna_metadata(metadata)


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
# Git helpers
# ---------------------------------------------------------------------------
def _get_git_hash() -> str:
    """Get short git hash of HEAD."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
            cwd=str(PROJECT_DIR),
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown"


def _get_git_dirty() -> bool:
    """Check if working tree has uncommitted changes."""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True, text=True, timeout=5,
            cwd=str(PROJECT_DIR),
        )
        if result.returncode == 0:
            return len(result.stdout.strip()) > 0
    except Exception:
        pass
    return False


# ---------------------------------------------------------------------------
# Sparklines
# ---------------------------------------------------------------------------
def sparkline(values: list[float]) -> str:
    """Generate a Unicode sparkline string from a list of values."""
    if not values:
        return ""
    blocks = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"
    mn, mx = min(values), max(values)
    if mn == mx:
        return blocks[4] * len(values)
    scale = (mx - mn) / (len(blocks) - 2)
    return "".join(
        blocks[min(len(blocks) - 1, max(1, int((v - mn) / scale) + 1))]
        for v in values
    )


# ---------------------------------------------------------------------------
# pytest plugin: collects results programmatically
# ---------------------------------------------------------------------------
class BenchmarkCollector:
    """Custom pytest plugin that collects results programmatically."""

    def __init__(self, progress=None, task_id=None):
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
        self._progress = progress
        self._task_id = task_id

    def _categorize(self, nodeid: str) -> str:
        """Map a test node ID to its category."""
        path_part = nodeid.replace("\\", "/").split("::")[0]
        filename = path_part.rsplit("/", 1)[-1]
        return FILE_TO_CATEGORY.get(filename, "Uncategorized")

    def pytest_collection_modifyitems(self, items: list) -> None:
        self.total_collected = len(items)
        if self._progress and self._task_id is not None:
            self._progress.update(self._task_id, total=self.total_collected)

    def pytest_runtest_logreport(self, report) -> None:
        if report.when == "call":
            category = self._categorize(report.nodeid)
            if report.passed:
                self.results[category]["passed"] += 1
            elif report.failed:
                self.results[category]["failed"] += 1
                short = ""
                if report.longrepr:
                    lines = str(report.longrepr).strip().splitlines()
                    short = lines[-1] if lines else ""
                    if len(short) > 200:
                        short = short[:200] + "..."
                self.results[category]["failures"].append({
                    "name": report.nodeid.split("::")[-1],
                    "nodeid": report.nodeid,
                    "message": short,
                    "duration": report.duration,
                })
            self.results[category]["durations"].append(report.duration)
            self.total_run += 1
            if self._progress and self._task_id is not None:
                self._progress.advance(self._task_id)
        elif report.when == "setup" and report.skipped:
            category = self._categorize(report.nodeid)
            self.results[category]["skipped"] += 1
            self.total_run += 1
            if self._progress and self._task_id is not None:
                self._progress.advance(self._task_id)
        elif report.when == "call" and report.skipped:
            category = self._categorize(report.nodeid)
            self.results[category]["skipped"] += 1


# ---------------------------------------------------------------------------
# Rich console setup
# ---------------------------------------------------------------------------
def _get_console(stderr: bool = False):
    """Get a Rich Console with UTF-8 forced on Windows."""
    try:
        from rich.console import Console
        return Console(force_terminal=True, stderr=stderr)
    except ImportError:
        return None


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
    optuna_profile: str = "balanced",
    optuna_source_label: str = "manual_benchmark",
    optuna_metadata_path: str = "",
) -> dict[str, Any]:
    """Run the full benchmark suite and return results dict."""
    start_time = time.time()
    timestamp = datetime.datetime.now().isoformat(timespec="seconds")
    git_hash = _get_git_hash()
    git_dirty = _get_git_dirty()

    # Build base pytest args -- suppress all default output
    base_args = [
        "--no-header",
        "--tb=no",
        "-q",
        "--continue-on-collection-errors",
        f"--rootdir={PROJECT_DIR}",
        "--override-ini=addopts=",
        "-p", "no:benchmark",
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

    # Try Rich progress bar (on stderr so stdout suppression doesn't kill it)
    progress_console = _get_console(stderr=True) if (show_progress and not json_output) else None
    progress_ctx = None
    collector = None

    if progress_console:
        try:
            from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn, TimeElapsedColumn
            progress_ctx = Progress(
                SpinnerColumn(),
                TextColumn("[bold blue]{task.description}"),
                BarColumn(bar_width=40),
                "[progress.percentage]{task.percentage:>3.0f}%",
                TextColumn("({task.completed}/{task.total})"),
                TimeElapsedColumn(),
                console=progress_console,
                transient=True,
            )
        except ImportError:
            pass

    # Suppress pytest's own stdout
    _devnull = open(os.devnull, "w")
    _old_stdout = sys.stdout
    sys.stdout = _devnull

    try:
        if progress_ctx:
            with progress_ctx as progress:
                task_id = progress.add_task("Running tests...", total=None)
                collector = BenchmarkCollector(progress=progress, task_id=task_id)
                ret_code = pytest.main(pytest_args, plugins=[collector])
        else:
            collector = BenchmarkCollector()
            ret_code = pytest.main(pytest_args, plugins=[collector])
    finally:
        sys.stdout = _old_stdout
        _devnull.close()

    elapsed = time.time() - start_time

    optuna_metadata = _load_optuna_metadata(
        optuna_profile=optuna_profile,
        source_label=optuna_source_label,
        metadata_path=optuna_metadata_path,
    )
    scoring_profile = _normalize_optuna_profile(optuna_metadata.get("profile"))

    # Compute scores
    scores = compute_scores(collector.results)
    domain_scores = compute_domain_scores(scores)
    overall = compute_overall_score(domain_scores, profile=scoring_profile)

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

    # History sparklines
    history = load_history(20)
    history_scores = [h.get("overall_score", 0) for h in history]

    # Build result
    result = {
        "timestamp": timestamp,
        "git_hash": git_hash,
        "git_dirty": git_dirty,
        "duration_seconds": round(elapsed, 2),
        "duration_human": format_duration(elapsed),
        "overall_score": round(overall, 1),
        "scoring_profile": scoring_profile,
        "domain_weight_profile": OVERALL_DOMAIN_WEIGHT_PROFILES[scoring_profile],
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
        "history_sparkline": sparkline(history_scores) if len(history_scores) > 1 else "",
        "exit_code": ret_code,
        "optuna": optuna_metadata,
    }

    # Save to history
    save_run(result)

    # Log to MLflow (optional)
    try:
        from research.mlflow_setup import log_benchmark_run

        log_benchmark_run(result, run_name=f"benchmark_{timestamp}")
    except ImportError:
        pass
    except Exception:
        pass  # MLflow logging is best-effort

    # Ensure stdout supports UTF-8 for box-drawing characters (Windows compat)
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    # Output
    if json_output:
        print(json.dumps(result, indent=2, default=str))
    elif compare and last_run:
        _print_comparison_rich(result, last_run)
    else:
        _print_report_rich(result)

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


def compute_overall_score(
    domain_scores: dict[str, dict], *, profile: str = "balanced"
) -> float:
    """Weighted overall score using a profile-aware domain emphasis."""
    domain_weights = OVERALL_DOMAIN_WEIGHT_PROFILES[
        _normalize_optuna_profile(profile)
    ]
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
        "git_hash": result.get("git_hash", "unknown"),
        "git_dirty": result.get("git_dirty", False),
        "duration_seconds": result["duration_seconds"],
        "overall_score": result["overall_score"],
        "scoring_profile": result.get("scoring_profile", "balanced"),
        "total_passed": result["total_passed"],
        "total_failed": result["total_failed"],
        "total_skipped": result["total_skipped"],
        "total_tests": result["total_tests"],
        "optuna": _sanitize_optuna_metadata(result.get("optuna")),
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


def _score_style(pct: float) -> str:
    """Rich style string for a given score percentage."""
    if pct >= 95:
        return "bold green"
    elif pct >= 80:
        return "cyan"
    elif pct >= 60:
        return "yellow"
    return "bold red"


def _trend_markup(direction: str, delta: float = 0.0) -> str:
    """Rich markup for a trend indicator."""
    if direction == "\u2191":
        return f"[green]{direction} +{delta:.0f}%[/]"
    elif direction == "\u2193":
        return f"[red]{direction} {delta:.0f}%[/]"
    elif direction == "\u2605":
        return f"[magenta]{direction} new[/]"
    return f"[dim]{direction}[/]"


def _bar_markup(pct: float, width: int = 30) -> str:
    """Rich markup progress bar."""
    filled = int(width * pct / 100)
    empty = width - filled
    style = _score_style(pct).split()[-1]  # just the color
    return f"[{style}]{'\u2588' * filled}[/][dim]{'\u2591' * empty}[/]"


# ---------------------------------------------------------------------------
# Rich terminal report
# ---------------------------------------------------------------------------
def _print_report_rich(result: dict) -> None:
    """Print report using Rich library."""
    console = _get_console()
    if console is None:
        _print_report_plain(result)
        return

    from rich.panel import Panel
    from rich.table import Table
    from rich.columns import Columns
    from rich.text import Text
    from rich import box

    # Header panel
    git_str = result.get("git_hash", "?")
    if result.get("git_dirty"):
        git_str += " (dirty)"
    header_text = (
        f"[dim]{result['timestamp']}  |  Duration: {result['duration_human']}"
        f"  |  git: {git_str}[/]"
    )
    console.print()
    console.print(Panel(
        header_text,
        title="[bold]THE PARTICLE ENGINE \u2014 BENCHMARK REPORT[/]",
        border_style="blue",
        padding=(0, 2),
    ))

    # Overall score with history sparkline
    overall = result["overall_score"]
    total_p = result["total_passed"]
    total_f = result["total_failed"]
    total_s = result["total_skipped"]
    total_t = result["total_tests"]
    bar = _bar_markup(overall, 40)
    spark = result.get("history_sparkline", "")

    score_text = Text()
    console.print()
    console.print(
        f"  [bold]OVERALL SCORE:[/] [{_score_style(overall)}]{overall:.1f}%[/]"
        f"  {bar}"
        f"  [dim]({total_p} passed, {total_f} failed, {total_s} skipped)[/]"
    )
    if spark:
        console.print(f"  [dim]History:[/] {spark}  [dim](last {len(result.get('history_sparkline', ''))} runs)[/]")

    # Summary cards
    summary_panels = []
    for domain, ddata in result["domain_scores"].items():
        dscore = ddata["score"]
        style = _score_style(dscore).split()[-1]
        summary_panels.append(
            Panel(f"[{_score_style(dscore)}]{dscore:.1f}%[/]", title=f"[bold]{domain}[/]", width=22, border_style=style)
        )
    console.print()
    console.print(Columns(summary_panels, padding=(0, 2)))

    # Domain detail tables
    for domain, ddata in result["domain_scores"].items():
        dscore = ddata["score"]
        cats = ddata.get("categories", {})

        table = Table(
            title=f"[bold]{domain}[/] ({dscore:.1f}%)",
            box=box.ROUNDED,
            border_style=_score_style(dscore).split()[-1],
            show_header=True,
            header_style="bold",
            padding=(0, 1),
        )
        table.add_column("Category", style="white", min_width=22)
        table.add_column("Score", justify="center", min_width=30)
        table.add_column("%", justify="right", min_width=5)
        table.add_column("P/F/S", justify="right", min_width=10)
        table.add_column("Trend", justify="center", min_width=8)

        for cat, cat_pct in cats.items():
            cat_data = result["category_scores"].get(cat, {})
            trend_data = result.get("trends", {}).get(cat, {})

            if cat_pct is None:
                table.add_row(
                    cat,
                    "[dim]---[/]",
                    "[dim]--[/]",
                    "[dim]--[/]",
                    "[dim]--[/]",
                )
            else:
                passed = cat_data.get("passed", 0)
                failed = cat_data.get("failed", 0)
                skipped = cat_data.get("skipped", 0)
                bar = _bar_markup(cat_pct, 25)
                pct_str = f"[{_score_style(cat_pct)}]{cat_pct:.0f}%[/]"
                pfs = f"[green]{passed}[/]/[red]{failed}[/]/[dim]{skipped}[/]"
                trend = _trend_markup(
                    trend_data.get("direction", "\u2192"),
                    trend_data.get("delta", 0.0),
                )
                table.add_row(cat, bar, pct_str, pfs, trend)

        console.print()
        console.print(table)

    # Failures
    failures = result.get("failures", [])
    if failures:
        console.print()
        fail_table = Table(
            title=f"[bold red]FAILURES ({len(failures)})[/]",
            box=box.SIMPLE,
            show_header=True,
            header_style="bold",
        )
        fail_table.add_column("Category", style="yellow", min_width=18)
        fail_table.add_column("Test", style="white")
        fail_table.add_column("Message", style="dim", max_width=55)

        for f in failures[:20]:
            msg = f.get("message", "")
            if len(msg) > 55:
                msg = msg[:52] + "..."
            fail_table.add_row(f["category"], f["name"], msg)

        if len(failures) > 20:
            fail_table.add_row("", f"[dim]... and {len(failures) - 20} more[/]", "")

        console.print(fail_table)

    # Trends summary
    trends = result.get("trends", {})
    improved = [(c, t) for c, t in trends.items() if t["direction"] == "\u2191"]
    regressed = [(c, t) for c, t in trends.items() if t["direction"] == "\u2193"]
    stable = [(c, t) for c, t in trends.items() if t["direction"] == "\u2192"]

    if improved or regressed:
        console.print()
        console.print("[bold]  TRENDS[/] (vs last run):")
        for cat, t in improved:
            prev = t.get("prev", 0)
            curr = result["category_scores"].get(cat, {}).get("pass_rate", 0)
            console.print(f"    [green]\u2191 {cat}: {prev:.0f}% \u2192 {curr:.0f}% (+{t['delta']:.0f}%)[/]")
        for cat, t in regressed:
            prev = t.get("prev", 0)
            curr = result["category_scores"].get(cat, {}).get("pass_rate", 0)
            console.print(f"    [red]\u2193 {cat}: {prev:.0f}% \u2192 {curr:.0f}% ({t['delta']:.0f}%)[/]")
        if stable:
            console.print(f"    [dim]\u2192 {len(stable)} categories stable[/]")

    # Recommendations
    recs = result.get("recommendations", [])
    if recs:
        console.print()
        rec_table = Table(
            title="[bold]RECOMMENDATIONS[/]",
            box=box.SIMPLE,
            show_header=True,
            header_style="bold",
        )
        rec_table.add_column("#", justify="right", style="bold", width=3)
        rec_table.add_column("Category", style="yellow", min_width=18)
        rec_table.add_column("Action", style="white")
        rec_table.add_column("Impact", justify="right", style="cyan")

        for i, rec in enumerate(recs[:5], 1):
            rec_table.add_row(
                str(i),
                rec["category"],
                rec["suggestion"],
                f"+{rec['potential_improvement']:.1f}%",
            )

        console.print(rec_table)

    console.print()


# ---------------------------------------------------------------------------
# Plain fallback report (no Rich)
# ---------------------------------------------------------------------------
def _print_report_plain(result: dict) -> None:
    """Plain text fallback when Rich is not available."""
    print()
    print("=" * 76)
    print(f"  THE PARTICLE ENGINE -- BENCHMARK REPORT")
    print(f"  {result['timestamp']}  |  Duration: {result['duration_human']}")
    git_str = result.get("git_hash", "?")
    if result.get("git_dirty"):
        git_str += " (dirty)"
    print(f"  git: {git_str}")
    print("=" * 76)
    print()

    overall = result["overall_score"]
    total_p = result["total_passed"]
    total_t = result["total_tests"]
    print(f"  OVERALL SCORE: {overall:.1f}%  ({total_p}/{total_t})")
    print()

    for domain, ddata in result["domain_scores"].items():
        dscore = ddata["score"]
        print(f"  --- {domain} ({dscore:.1f}%) ---")
        cats = ddata.get("categories", {})
        for cat, cat_pct in cats.items():
            if cat_pct is None:
                print(f"    {cat:<24s}  --")
            else:
                trend_data = result.get("trends", {}).get(cat, {})
                trend_str = trend_data.get("direction", "->")
                print(f"    {cat:<24s}  {cat_pct:5.1f}%  {trend_str}")
        print()

    failures = result.get("failures", [])
    if failures:
        print(f"  FAILURES ({len(failures)}):")
        for f in failures[:15]:
            print(f"    x [{f['category']}] {f['name']}")
            if f.get("message"):
                msg = f["message"][:60]
                print(f"      {msg}")
        if len(failures) > 15:
            print(f"    ... and {len(failures) - 15} more")
        print()

    recs = result.get("recommendations", [])
    if recs:
        print("  RECOMMENDATIONS:")
        for i, rec in enumerate(recs[:5], 1):
            print(f"    {i}. {rec['suggestion']} ({rec['category']}, +{rec['potential_improvement']:.1f}%)")
        print()


# ---------------------------------------------------------------------------
# Rich comparison report
# ---------------------------------------------------------------------------
def _print_comparison_rich(current: dict, previous: dict) -> None:
    """Print comparison using Rich."""
    console = _get_console()
    if console is None:
        _print_comparison_plain(current, previous)
        return

    from rich.table import Table
    from rich.panel import Panel
    from rich import box

    prev_overall = previous.get("overall_score", 0)
    curr_overall = current["overall_score"]
    delta = curr_overall - prev_overall
    delta_str = f"+{delta:.1f}%" if delta >= 0 else f"{delta:.1f}%"
    delta_style = "green" if delta >= 0 else "red"

    console.print()
    console.print(Panel(
        f"[dim]Previous:[/] {previous.get('timestamp', '?')} ({previous.get('git_hash', '?')})\n"
        f"[dim]Current:[/]  {current['timestamp']} ({current.get('git_hash', '?')})\n\n"
        f"Overall: [{_score_style(prev_overall)}]{prev_overall:.1f}%[/]"
        f" \u2192 [{_score_style(curr_overall)}]{curr_overall:.1f}%[/]"
        f"  [{delta_style}]({delta_str})[/]",
        title="[bold]BENCHMARK COMPARISON[/]",
        border_style="blue",
    ))

    # Category comparison table
    table = Table(
        title="[bold]Per-Category Comparison[/]",
        box=box.ROUNDED,
        show_header=True,
        header_style="bold",
    )
    table.add_column("Category", style="white", min_width=22)
    table.add_column("Previous", justify="right", min_width=8)
    table.add_column("Current", justify="right", min_width=8)
    table.add_column("Delta", justify="right", min_width=8)

    prev_cats = previous.get("category_scores", {})
    curr_cats = current.get("category_scores", {})
    all_cats = sorted(set(list(prev_cats.keys()) + list(curr_cats.keys())))

    for cat in all_cats:
        p = prev_cats.get(cat, {}).get("pass_rate", 0)
        c = curr_cats.get(cat, {}).get("pass_rate", 0)
        d = c - p
        d_str = f"+{d:.1f}%" if d >= 0 else f"{d:.1f}%"
        d_style = "green" if d > 0 else ("red" if d < 0 else "dim")
        table.add_row(
            cat,
            f"[{_score_style(p)}]{p:.1f}%[/]",
            f"[{_score_style(c)}]{c:.1f}%[/]",
            f"[{d_style}]{d_str}[/]",
        )

    console.print()
    console.print(table)

    # Also print the full report
    _print_report_rich(current)


def _print_comparison_plain(current: dict, previous: dict) -> None:
    """Plain text comparison fallback."""
    print()
    print("  BENCHMARK COMPARISON")
    print(f"  Previous: {previous.get('timestamp', '?')}")
    print(f"  Current:  {current['timestamp']}")
    print()

    prev_overall = previous.get("overall_score", 0)
    curr_overall = current["overall_score"]
    delta = curr_overall - prev_overall
    delta_str = f"+{delta:.1f}%" if delta >= 0 else f"{delta:.1f}%"
    print(f"  Overall: {prev_overall:.1f}% -> {curr_overall:.1f}%  ({delta_str})")
    print()

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
        print(f"  {cat:<24s}  {p:5.1f}%  {c:5.1f}%  {d_str:>8s}")
    print()

    _print_report_plain(current)


# ---------------------------------------------------------------------------
# History display
# ---------------------------------------------------------------------------
def print_history() -> None:
    """Print benchmark history with sparklines."""
    console = _get_console()
    history = load_history(30)

    if not history:
        print("No benchmark history found.")
        return

    # Ensure UTF-8
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    if console:
        from rich.table import Table
        from rich.panel import Panel
        from rich import box

        # Overall sparkline
        scores = [h.get("overall_score", 0) for h in history]
        spark = sparkline(scores)
        console.print()
        console.print(Panel(
            f"Score trend: {spark}\n"
            f"[dim]Range: {min(scores):.1f}% - {max(scores):.1f}%  |  Runs: {len(history)}[/]",
            title="[bold]BENCHMARK HISTORY[/]",
            border_style="blue",
        ))

        # History table
        table = Table(
            box=box.SIMPLE,
            show_header=True,
            header_style="bold",
        )
        table.add_column("#", justify="right", width=3)
        table.add_column("Timestamp", style="dim", min_width=19)
        table.add_column("Git", style="cyan", min_width=8)
        table.add_column("Score", justify="right", min_width=7)
        table.add_column("P/F/S", justify="right", min_width=12)
        table.add_column("Duration", justify="right", style="dim", min_width=6)
        table.add_column("Physics", justify="right", min_width=7)
        table.add_column("Visuals", justify="right", min_width=7)
        table.add_column("Infra", justify="right", min_width=7)

        for i, h in enumerate(reversed(history[-15:]), 1):
            ds = h.get("domain_scores", {})
            git = h.get("git_hash", "?")
            if h.get("git_dirty"):
                git += "*"
            overall = h.get("overall_score", 0)
            dur = format_duration(h.get("duration_seconds", 0))
            p = h.get("total_passed", 0)
            f = h.get("total_failed", 0)
            s = h.get("total_skipped", 0)
            phy = ds.get("Physics", {}).get("score", 0)
            vis = ds.get("Visuals", {}).get("score", 0)
            inf = ds.get("Infrastructure", {}).get("score", 0)
            table.add_row(
                str(i),
                h.get("timestamp", "?"),
                git,
                f"[{_score_style(overall)}]{overall:.1f}%[/]",
                f"[green]{p}[/]/[red]{f}[/]/[dim]{s}[/]",
                dur,
                f"[{_score_style(phy)}]{phy:.0f}%[/]",
                f"[{_score_style(vis)}]{vis:.0f}%[/]",
                f"[{_score_style(inf)}]{inf:.0f}%[/]",
            )

        console.print(table)

        # Per-domain sparklines
        console.print()
        for domain_name in ["Physics", "Visuals", "Infrastructure"]:
            domain_scores = [
                h.get("domain_scores", {}).get(domain_name, {}).get("score", 0)
                for h in history
            ]
            if domain_scores:
                ds = sparkline(domain_scores)
                latest = domain_scores[-1]
                console.print(
                    f"  {domain_name:<15s} {ds}"
                    f"  [{_score_style(latest)}]{latest:.1f}%[/]"
                )
        console.print()

    else:
        # Plain fallback
        print()
        print("  BENCHMARK HISTORY")
        print("  " + "-" * 60)
        for h in history[-15:]:
            ts = h.get("timestamp", "?")
            git = h.get("git_hash", "?")
            score = h.get("overall_score", 0)
            p = h.get("total_passed", 0)
            f = h.get("total_failed", 0)
            print(f"  {ts}  {git:8s}  {score:5.1f}%  ({p}p/{f}f)")
        scores = [h.get("overall_score", 0) for h in history]
        print()
        print(f"  Trend: {sparkline(scores)}")
        print()


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
    parser.add_argument("--history", action="store_true", help="Show score history")
    parser.add_argument(
        "--optuna-profile",
        default=os.environ.get("OPTUNA_PROFILE", "balanced"),
        choices=sorted(OVERALL_DOMAIN_WEIGHT_PROFILES.keys()),
        help="Profile-aware benchmark weighting for tuned or mobile-biased runs.",
    )
    parser.add_argument(
        "--optuna-source-label",
        default=os.environ.get("OPTUNA_SOURCE_LABEL", "manual_benchmark"),
        help="Source label persisted with benchmark history and JSON output.",
    )
    parser.add_argument(
        "--optuna-metadata-json",
        default=os.environ.get("OPTUNA_METADATA_JSON", ""),
        help="Optional path to Optuna metadata or trial_config.json for context.",
    )
    args = parser.parse_args()

    if args.history:
        print_history()
        return 0

    result = run_benchmark(
        quick=args.quick,
        physics_only=args.physics_only,
        visual_only=args.visual_only,
        json_output=args.json_output,
        compare=args.compare,
        optuna_profile=args.optuna_profile,
        optuna_source_label=args.optuna_source_label,
        optuna_metadata_path=args.optuna_metadata_json,
    )

    return 0 if result["overall_score"] >= 50 else 1


if __name__ == "__main__":
    sys.exit(main())
