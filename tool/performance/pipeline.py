"""Run performance suites and persist comparable metrics."""
from __future__ import annotations

import argparse
import json
import os
import platform
import sqlite3
import shutil
import socket
import subprocess
import sys
import uuid
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from storage import (
    DuckDBPerfStore,
    JsonlPerfStore,
    PostgresPerfStore,
    SQLitePerfStore,
    StorageConfig,
)


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SQLITE = ROOT / "research" / "telemetry" / "perf_history.sqlite"
DEFAULT_HISTORY_JSONL = ROOT / "research" / "telemetry" / "perf_history.jsonl"
DEFAULT_RUNS_DIR = ROOT / "reports" / "performance" / "runs"
EXPORT_OTLP_SCRIPT = ROOT / "tool" / "performance" / "export_otlp.py"
RUN_SCHEMA_VERSION = 3


PROFILE_DEFAULTS: dict[str, dict[str, Any]] = {
    "pr": {
        "include_soak": False,
        "soak_level": "quick",
        "timeout_seconds": 180,
        "required_suites": {"game_loop", "physics_integrity", "atmospherics"},
    },
    "nightly": {
        "include_soak": True,
        "soak_level": "nightly",
        "timeout_seconds": 600,
        "required_suites": {
            "game_loop",
            "physics_integrity",
            "physics_fuzz",
            "engine_soak",
            "visual_regression",
            "atmospherics",
        },
    },
    "investigative": {
        "include_soak": True,
        "soak_level": "quick",
        "timeout_seconds": 900,
        "required_suites": {
            "game_loop",
            "physics_integrity",
            "physics_fuzz",
            "visual_regression",
            "atmospherics",
        },
    },
}


@dataclass
class TestCaseResult:
    target: str
    name: str
    outcome: str
    duration_ms: float


@dataclass
class TargetRunResult:
    return_code: int
    tests: list[TestCaseResult]
    timed_out: bool
    elapsed_ms: float


@dataclass
class VisualArtifactResult:
    run_id: str
    scenario: str
    frame: int
    image_path: str
    diff_path: str
    ssim: float
    psnr: float
    diff_ratio: float
    passed: bool


@dataclass(frozen=True)
class TargetSpec:
    path: str
    extra_args: tuple[str, ...] = ()
    suite: str = "unknown"


def _resolve_flutter_cmd() -> str:
    env_cmd = os.environ.get("FLUTTER_CMD")
    if env_cmd and env_cmd.strip():
        return env_cmd

    for candidate in ("flutter", "flutter.bat"):
        path = shutil.which(candidate)
        if path is not None:
            return path

    raise RuntimeError(
        "Flutter executable not found. Set FLUTTER_CMD to the flutter binary path."
    )


def _git_value(args: list[str]) -> str | None:
    proc = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        return None
    value = proc.stdout.strip()
    return value or None


def _parse_machine_events(lines: Iterable[str], target: str) -> list[TestCaseResult]:
    starts: dict[int, tuple[str, int]] = {}
    results: list[TestCaseResult] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue

        event_type = event.get("type")
        if event_type == "testStart":
            test = event.get("test", {})
            test_id = test.get("id")
            name = test.get("name", "unknown")
            started_at = int(event.get("time", 0))
            if isinstance(test_id, int):
                starts[test_id] = (name, started_at)
        elif event_type == "testDone":
            test_id = event.get("testID")
            if not isinstance(test_id, int):
                continue
            name, started_at = starts.pop(test_id, ("unknown", int(event.get("time", 0))))
            done_at = int(event.get("time", started_at))
            hidden = bool(event.get("hidden", False))
            if hidden:
                continue
            outcome = "passed"
            if event.get("result") != "success":
                outcome = "failed"
            results.append(
                TestCaseResult(
                    target=target,
                    name=name,
                    outcome=outcome,
                    duration_ms=max(0.0, float(done_at - started_at)),
                )
            )
    return results


def _run_flutter_target(
    target: TargetSpec,
    *,
    flutter_cmd: str,
    perf_report_path: Path,
    soak_level: str,
    artifact_dir: Path,
    timeout_seconds: int,
    visual_report_path: Path,
) -> TargetRunResult:
    env = dict(os.environ)
    env["PERF_REPORT_PATH"] = str(perf_report_path)
    env["PERF_VISUAL_REPORT_PATH"] = str(visual_report_path)
    env["SOAK_LEVEL"] = soak_level

    cmd = [
        flutter_cmd,
        "test",
        "--machine",
        "--no-pub",
        target.path,
        *target.extra_args,
    ]

    stem = Path(target.path).stem
    raw_path = artifact_dir / f"{stem}.machine.jsonl"
    err_path = artifact_dir / f"{stem}.stderr.log"

    print(
        f"[{datetime.now(tz=UTC).isoformat()}] START target={target.path} "
        f"timeout={timeout_seconds}s args={list(target.extra_args)}"
    )

    timed_out = False
    duration_s = 0.0
    stdout_text = ""
    stderr_text = ""
    return_code = 1
    started = datetime.now(tz=UTC)
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        out, err = proc.communicate(timeout=timeout_seconds)
        stdout_text = out or ""
        stderr_text = err or ""
        return_code = proc.returncode if proc.returncode is not None else 1
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    text=True,
                    capture_output=True,
                    check=False,
                )
            else:
                proc.terminate()
        finally:
            proc.kill()
        out, err = proc.communicate(timeout=5)
        stdout_text = out or ""
        stderr_text = err or ""
        return_code = 124

    duration_s = (datetime.now(tz=UTC) - started).total_seconds()
    raw_path.write_text(stdout_text, encoding="utf-8")
    if stderr_text.strip():
        err_path.write_text(stderr_text, encoding="utf-8")

    test_done_count = stdout_text.count('"type":"testDone"')
    if test_done_count:
        print(
            f"[{datetime.now(tz=UTC).isoformat()}] EVENTS target={target.path} "
            f"test_done={test_done_count}"
        )
    if timed_out:
        print(
            f"[{datetime.now(tz=UTC).isoformat()}] TIMEOUT target={target.path} "
            f"elapsed={duration_s:.1f}s"
        )

    results = _parse_machine_events(stdout_text.splitlines(), target.path)
    print(
        f"[{datetime.now(tz=UTC).isoformat()}] END target={target.path} "
        f"return_code={return_code} tests={len(results)} elapsed={duration_s:.1f}s"
    )
    return TargetRunResult(
        return_code=return_code,
        tests=results,
        timed_out=timed_out,
        elapsed_ms=duration_s * 1000.0,
    )


def _load_scenario_metrics(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    scenarios: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            scenarios.append(payload)
    return scenarios


def _load_visual_artifacts(path: Path) -> list[VisualArtifactResult]:
    if not path.exists():
        return []
    artifacts: list[VisualArtifactResult] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        try:
            artifacts.append(
                VisualArtifactResult(
                    run_id=str(payload.get("run_id", "")),
                    scenario=str(payload.get("scenario", "unknown")),
                    frame=int(payload.get("frame", 0)),
                    image_path=str(payload.get("image_path", "")),
                    diff_path=str(payload.get("diff_path", "")),
                    ssim=float(payload.get("ssim", 0.0)),
                    psnr=float(payload.get("psnr", 0.0)),
                    diff_ratio=float(payload.get("diff_ratio", 1.0)),
                    passed=bool(payload.get("pass", False)),
                )
            )
        except (TypeError, ValueError):
            continue
    return artifacts


def _build_comparison(current: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    comparison: dict[str, Any] = {
        "current_run_id": current["run_id"],
        "previous_run_id": None if previous is None else previous["run_id"],
        "delta_duration_ms": None,
        "delta_failed_tests": None,
    }
    if previous is None:
        return comparison

    comparison["previous_run_id"] = previous["run_id"]
    comparison["delta_duration_ms"] = (
        current["summary"]["duration_ms"] - float(previous["duration_ms"])
    )
    comparison["delta_failed_tests"] = (
        current["summary"]["failed_tests"] - int(previous["failed_tests"])
    )
    return comparison


def _percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    rank = (len(sorted_vals) - 1) * p
    lo = int(rank)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = rank - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac


def _load_duration_baseline(
    sqlite_path: Path,
    profile: str,
    current_run_id: str,
    limit: int = 20,
) -> dict[str, Any]:
    if not sqlite_path.exists():
        return {
            "sample_size": 0,
            "median_duration_ms": None,
            "p95_duration_ms": None,
            "delta_vs_median_pct": None,
            "warning": False,
        }
    con = sqlite3.connect(str(sqlite_path))
    try:
        rows = con.execute(
            """
            SELECT duration_ms
            FROM perf_runs
            WHERE run_id != ? AND profile = ?
            ORDER BY timestamp_utc DESC
            LIMIT ?
            """,
            (current_run_id, profile, limit),
        ).fetchall()
    finally:
        con.close()
    durations = sorted(float(r[0]) for r in rows if r and r[0] is not None)
    if not durations:
        return {
            "sample_size": 0,
            "median_duration_ms": None,
            "p95_duration_ms": None,
            "delta_vs_median_pct": None,
            "warning": False,
        }
    median = _percentile(durations, 0.5)
    p95 = _percentile(durations, 0.95)
    return {
        "sample_size": len(durations),
        "median_duration_ms": median,
        "p95_duration_ms": p95,
        "delta_vs_median_pct": None,
        "warning": False,
    }


def _evaluate_baseline_gate(
    baseline: dict[str, Any],
    *,
    current_duration_ms: float,
    min_samples: int,
    max_delta_pct: float,
    max_p95_multiplier: float,
) -> tuple[bool, bool]:
    sample_size = int(baseline.get("sample_size", 0) or 0)
    gate_active = sample_size >= min_samples
    median = baseline.get("median_duration_ms")
    p95 = baseline.get("p95_duration_ms")
    delta_pct = None
    warning = False
    if median not in (None, 0.0):
        medf = float(median)
        delta_pct = ((current_duration_ms - medf) / medf) * 100.0
        if delta_pct > max_delta_pct:
            warning = True
    if p95 not in (None, 0.0):
        if current_duration_ms > float(p95) * max_p95_multiplier:
            warning = True
    baseline["delta_vs_median_pct"] = delta_pct
    baseline["warning"] = warning
    return gate_active, warning


def _evaluate_visual_gate(
    *,
    failed_visual_cases: int,
    max_failed_visual_cases: int,
) -> tuple[bool, bool]:
    gate_active = max_failed_visual_cases >= 0
    failed = failed_visual_cases > max_failed_visual_cases
    return gate_active, failed


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run performance suites and persist observability telemetry."
    )
    parser.add_argument(
        "--profile",
        default="pr",
        choices=["pr", "nightly", "investigative"],
        help="Execution profile for CI tiering and default thresholds.",
    )
    parser.add_argument(
        "--soak-level",
        default="",
        choices=["quick", "nightly"],
        help="Soak level passed into SOAK_LEVEL env.",
    )
    parser.add_argument(
        "--include-soak",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Include soak tests in this pipeline run. Defaults per profile.",
    )
    parser.add_argument(
        "--target-timeout-seconds",
        type=int,
        default=0,
        help="Max wall clock seconds per flutter test target (0=profile default).",
    )
    parser.add_argument(
        "--sqlite-path",
        default=str(DEFAULT_SQLITE),
        help="SQLite path for canonical local history.",
    )
    parser.add_argument(
        "--history-jsonl-path",
        default=str(DEFAULT_HISTORY_JSONL),
        help="Append-only JSONL run history path.",
    )
    parser.add_argument(
        "--duckdb-path",
        default="",
        help="Optional DuckDB path for analytics mirror.",
    )
    parser.add_argument(
        "--postgres-dsn",
        default="",
        help="Optional Postgres DSN for shared remote storage.",
    )
    parser.add_argument(
        "--artifact-dir",
        default="",
        help="Optional run artifact directory override.",
    )
    parser.add_argument(
        "--artifact-root",
        default="",
        help="Optional root directory for visual artifact image outputs.",
    )
    parser.add_argument(
        "--emit-visual-artifacts",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Collect and persist visual regression artifact metadata when present.",
    )
    parser.add_argument(
        "--export-otlp",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Export run metrics to OTLP endpoint (for LGTM/Grafana).",
    )
    parser.add_argument(
        "--otlp-service-name",
        default="particle-engine-tests",
        help="service.name used for OTLP metric export.",
    )
    parser.add_argument(
        "--require-telemetry-complete",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Fail the run when required telemetry suites are missing.",
    )
    parser.add_argument(
        "--warn-then-gate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enable baseline warmup warnings, then hard-gate once enough samples exist.",
    )
    parser.add_argument(
        "--baseline-min-samples",
        type=int,
        default=8,
        help="Minimum same-profile historical runs required before baseline warnings become hard gates.",
    )
    parser.add_argument(
        "--baseline-warning-delta-pct",
        type=float,
        default=25.0,
        help="Warn when current duration exceeds baseline median by this percentage.",
    )
    parser.add_argument(
        "--baseline-warning-vs-p95-multiplier",
        type=float,
        default=1.10,
        help="Warn when current duration exceeds baseline p95 multiplied by this factor.",
    )
    parser.add_argument(
        "--max-failed-visual-cases",
        type=int,
        default=0,
        help="Hard fail when failed visual cases exceed this threshold (set -1 to disable).",
    )
    return parser


def _export_otlp(run_json: Path, service_name: str) -> int:
    cmd = [
        sys.executable,
        str(EXPORT_OTLP_SCRIPT),
        "--run-json",
        str(run_json),
        "--service-name",
        service_name,
    ]
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.stdout.strip():
        print(proc.stdout.strip())
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)
    return proc.returncode


def _resolve_effective_options(args: argparse.Namespace) -> dict[str, Any]:
    defaults = PROFILE_DEFAULTS[args.profile]
    include_soak = defaults["include_soak"] if args.include_soak is None else args.include_soak
    soak_level = args.soak_level or defaults["soak_level"]
    timeout_seconds = args.target_timeout_seconds or defaults["timeout_seconds"]
    return {
        "include_soak": include_soak,
        "soak_level": soak_level,
        "timeout_seconds": timeout_seconds,
        "required_suites": set(defaults["required_suites"]),
    }


def _build_targets(profile: str, include_soak: bool, soak_level: str) -> list[TargetSpec]:
    targets: list[TargetSpec] = []
    if profile == "pr":
        # Keep PR profile bounded and deterministic: run the most stable budget test only.
        targets.append(
            TargetSpec(
                path="test/performance/game_loop/game_loop_smoke_performance_test.dart",
                suite="game_loop",
            )
        )
    else:
        targets.append(
            TargetSpec(
                path="test/performance/game_loop/game_loop_performance_test.dart",
                suite="game_loop",
            )
        )

    targets.append(
        TargetSpec(
            path="test/performance/simulation/physics_integrity_test.dart",
            suite="physics_integrity",
        )
    )
    targets.append(
        TargetSpec(
            path="test/performance/simulation/deterministic_replay_performance_test.dart",
            suite="physics_integrity",
        )
    )
    targets.append(
        TargetSpec(
            path="test/performance/simulation/metamorphic_interaction_test.dart",
            suite="physics_integrity",
        )
    )
    targets.append(
        TargetSpec(
            path="test/performance/simulation/atmospherics_quality_test.dart",
            suite="atmospherics",
        )
    )
    targets.append(
        TargetSpec(
            path="test/performance/simulation/dirty_chunk_integrity_test.dart",
            suite="physics_integrity",
        )
    )

    if profile in {"nightly", "investigative"}:
        targets.append(
            TargetSpec(
                path="test/performance/simulation/scenario_property_fuzz_test.dart",
                suite="physics_fuzz",
            )
        )
        targets.append(
            TargetSpec(
                path="test/performance/simulation/visual_regression_suite_test.dart",
                suite="visual_regression",
            )
        )

    if include_soak:
        if soak_level == "quick":
            targets.append(
                TargetSpec(
                    path="test/performance/simulation/engine_soak_test.dart",
                    extra_args=(
                        "--plain-name",
                        "Soak Determinism",
                    ),
                    suite="engine_soak",
                )
            )
        else:
            targets.append(
                TargetSpec(
                    path="test/performance/simulation/engine_soak_test.dart",
                    suite="engine_soak",
                )
            )
    return targets


def _assess_telemetry_completeness(
    scenarios: list[dict[str, Any]],
    required_suites: set[str],
) -> tuple[bool, list[str]]:
    suites_present = {
        str(scenario.get("suite", "")).strip()
        for scenario in scenarios
        if isinstance(scenario.get("metrics"), dict) and scenario.get("metrics")
    }
    missing = sorted(s for s in required_suites if s not in suites_present)
    return len(missing) == 0, missing


def main() -> int:
    args = _build_parser().parse_args()
    resolved = _resolve_effective_options(args)

    now = datetime.now(tz=UTC)
    run_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}_{uuid.uuid4().hex[:8]}"
    run_dir = (
        Path(args.artifact_dir)
        if args.artifact_dir
        else (DEFAULT_RUNS_DIR / run_id)
    )
    run_dir.mkdir(parents=True, exist_ok=True)
    scenario_metrics_path = run_dir / "scenario_metrics.jsonl"
    visual_metrics_path = run_dir / "visual_artifacts.jsonl"
    visual_root = Path(args.artifact_root) if args.artifact_root else (run_dir / "visual")
    visual_root.mkdir(parents=True, exist_ok=True)

    targets = _build_targets(
        profile=args.profile,
        include_soak=resolved["include_soak"],
        soak_level=resolved["soak_level"],
    )
    flutter_cmd = _resolve_flutter_cmd()
    all_cases: list[TestCaseResult] = []
    return_code = 0
    target_failures = 0
    target_timeouts = 0
    harness_duration_ms = 0.0

    for target in targets:
        target_result = _run_flutter_target(
            target,
            flutter_cmd=flutter_cmd,
            perf_report_path=scenario_metrics_path,
            soak_level=resolved["soak_level"],
            artifact_dir=run_dir,
            timeout_seconds=resolved["timeout_seconds"],
            visual_report_path=visual_metrics_path,
        )
        all_cases.extend(target_result.tests)
        harness_duration_ms += target_result.elapsed_ms
        if target_result.return_code != 0:
            target_failures += 1
            return_code = target_result.return_code
        if target_result.timed_out:
            target_timeouts += 1

    scenarios = _load_scenario_metrics(scenario_metrics_path)
    visual_artifacts = _load_visual_artifacts(visual_metrics_path) if args.emit_visual_artifacts else []
    telemetry_complete, missing_suites = _assess_telemetry_completeness(
        scenarios,
        resolved["required_suites"],
    )
    failed_cases = sum(1 for case in all_cases if case.outcome != "passed")
    failed_visual_cases = sum(1 for case in visual_artifacts if not case.passed)
    failed = failed_cases + target_failures
    duration_ms = harness_duration_ms if harness_duration_ms > 0 else sum(
        case.duration_ms for case in all_cases
    )

    run_payload: dict[str, Any] = {
        "schema_version": RUN_SCHEMA_VERSION,
        "run_id": run_id,
        "timestamp_utc": now.isoformat(),
        "git_sha": _git_value(["rev-parse", "HEAD"]),
        "git_branch": _git_value(["rev-parse", "--abbrev-ref", "HEAD"]),
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "profile": args.profile,
        "soak_level": resolved["soak_level"],
        "summary": {
            "total_tests": len(all_cases),
            "failed_tests": failed,
            "failed_cases": failed_cases,
            "failed_targets": target_failures,
            "timed_out_targets": target_timeouts,
            "telemetry_complete": telemetry_complete,
            "total_visual_cases": len(visual_artifacts),
            "failed_visual_cases": failed_visual_cases,
            "duration_ms": duration_ms,
        },
        "telemetry": {
            "required_suites": sorted(resolved["required_suites"]),
            "missing_suites": missing_suites,
        },
        "test_cases": [
            {
                "target": case.target,
                "name": case.name,
                "outcome": case.outcome,
                "duration_ms": round(case.duration_ms, 3),
            }
            for case in all_cases
        ],
        "scenarios": scenarios,
        "visual_artifacts": [
            {
                "run_id": art.run_id,
                "scenario": art.scenario,
                "frame": art.frame,
                "image_path": art.image_path,
                "diff_path": art.diff_path,
                "ssim": art.ssim,
                "psnr": art.psnr,
                "diff_ratio": art.diff_ratio,
                "pass": art.passed,
            }
            for art in visual_artifacts
        ],
        "visual_artifact_root": str(visual_root),
    }

    run_json = run_dir / "run.json"
    run_json.write_text(json.dumps(run_payload, indent=2, sort_keys=True), encoding="utf-8")

    if args.require_telemetry_complete and not telemetry_complete:
        print(
            f"Telemetry incomplete; missing required suites: {missing_suites}",
            file=sys.stderr,
        )
        return_code = return_code or 3

    config = StorageConfig(
        sqlite_path=Path(args.sqlite_path),
        history_jsonl_path=Path(args.history_jsonl_path),
        duckdb_path=Path(args.duckdb_path) if args.duckdb_path else None,
        postgres_dsn=args.postgres_dsn or None,
    )

    sqlite_store = SQLitePerfStore(config.sqlite_path)
    jsonl_store = JsonlPerfStore(config.history_jsonl_path)
    duckdb_store = None
    postgres_store = None
    try:
        sqlite_store.insert_run(run_payload)
        jsonl_store.append_run(run_payload)

        if config.duckdb_path is not None:
            duckdb_store = DuckDBPerfStore(config.duckdb_path)
            duckdb_store.insert_run(run_payload)
        if config.postgres_dsn is not None:
            postgres_store = PostgresPerfStore(config.postgres_dsn)
            postgres_store.insert_run(run_payload)

        previous = sqlite_store.get_previous_run(run_id)
        comparison = _build_comparison(run_payload, previous)
        baseline = _load_duration_baseline(Path(args.sqlite_path), args.profile, run_id)
        current_duration = float(run_payload["summary"]["duration_ms"])
        gate_active, warning = _evaluate_baseline_gate(
            baseline,
            current_duration_ms=current_duration,
            min_samples=max(1, args.baseline_min_samples),
            max_delta_pct=args.baseline_warning_delta_pct,
            max_p95_multiplier=args.baseline_warning_vs_p95_multiplier,
        )
        comparison["duration_baseline"] = baseline
        comparison["baseline_gate_active"] = gate_active
        comparison["baseline_warning"] = warning
        comparison_path = run_dir / "comparison.json"
        comparison_path.write_text(
            json.dumps(comparison, indent=2, sort_keys=True), encoding="utf-8"
        )
    finally:
        sqlite_store.close()
        if duckdb_store is not None:
            duckdb_store.close()
        if postgres_store is not None:
            postgres_store.close()

    baseline_gate_active = bool(comparison.get("baseline_gate_active", False))
    baseline_warning = bool(comparison.get("baseline_warning", False))
    visual_gate_active, visual_gate_failed = _evaluate_visual_gate(
        failed_visual_cases=failed_visual_cases,
        max_failed_visual_cases=args.max_failed_visual_cases,
    )
    run_payload["summary"]["baseline_gate_active"] = baseline_gate_active
    run_payload["summary"]["baseline_warning"] = baseline_warning
    run_payload["summary"]["visual_gate_active"] = visual_gate_active
    run_payload["summary"]["visual_gate_failed"] = visual_gate_failed
    run_json.write_text(json.dumps(run_payload, indent=2, sort_keys=True), encoding="utf-8")

    if args.warn_then_gate and baseline_gate_active and baseline_warning:
        print(
            "Baseline performance regression warning reached hard-gate threshold.",
            file=sys.stderr,
        )
        return_code = return_code or 5

    if visual_gate_active and visual_gate_failed:
        print(
            "Visual regression gate failed: failed visual cases exceed threshold.",
            file=sys.stderr,
        )
        return_code = return_code or 6

    if args.export_otlp:
        print(f"[{datetime.now(tz=UTC).isoformat()}] EXPORT_OTLP run_id={run_id}")
        export_code = _export_otlp(run_json, args.otlp_service_name)
        if export_code != 0:
            print(
                f"OTLP export failed with exit code {export_code}.",
                file=sys.stderr,
            )
            return_code = return_code or export_code

    print(f"run_id={run_id}")
    print(f"artifact_dir={run_dir}")
    print(f"total_tests={len(all_cases)} failed_tests={failed}")
    print(f"profile={args.profile} telemetry_complete={telemetry_complete}")
    if "duration_baseline" in comparison:
        b = comparison["duration_baseline"]
        if b.get("sample_size", 0):
            print(
                "duration_baseline="
                f"n={b['sample_size']} median_ms={float(b['median_duration_ms']):.1f} "
                f"p95_ms={float(b['p95_duration_ms']):.1f} "
                f"delta_pct={float(b['delta_vs_median_pct']):.1f} warning={bool(b['warning'])}"
            )
            if args.warn_then_gate and not comparison.get("baseline_gate_active", False) and b.get("warning", False):
                print(
                    "baseline_warning=active_but_warmup (warning emitted, not failing until min samples reached)"
                )
    if return_code != 0:
        print("One or more flutter test targets failed.", file=sys.stderr)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
