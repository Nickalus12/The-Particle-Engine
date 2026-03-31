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
RUN_SCHEMA_VERSION = 7


PROFILE_DEFAULTS: dict[str, dict[str, Any]] = {
    "pr": {
        "include_soak": False,
        "soak_level": "quick",
        "timeout_seconds": 180,
        "required_suites": {"game_loop", "physics_integrity", "atmospherics", "creature_performance"},
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
            "creature_performance",
            "creature_investigative",
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
            "creature_performance",
            "creature_investigative",
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
        "delta_quality_score_total": None,
        "delta_component_scores": {},
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
    current_quality = float(current["summary"].get("quality_score_total", 0.0))
    previous_quality = float(previous.get("quality_score_total", 0.0) or 0.0)
    comparison["delta_quality_score_total"] = current_quality - previous_quality
    current_components = current["summary"].get("component_scores", {})
    if isinstance(current_components, dict):
        comparison["delta_component_scores"] = {
            str(k): float(v)
            for k, v in current_components.items()
            if isinstance(v, (int, float))
        }
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


def _sanitize_optuna_metadata(metadata: Any) -> dict[str, Any]:
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
    cleaned: dict[str, Any] = {}
    for key in allowed_scalar_keys:
        value = metadata.get(key)
        if isinstance(value, (str, int, float, bool)) or value is None:
            if value not in ("", None):
                cleaned[key] = value
    search_groups = metadata.get("search_groups")
    if isinstance(search_groups, list):
        cleaned["search_groups"] = [str(item)[:40] for item in search_groups[:8]]
    return cleaned


def _load_optuna_metadata(metadata_path: str = "") -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    candidate_path = metadata_path or os.environ.get("OPTUNA_METADATA_JSON", "")
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

    env_map = {
        "profile": "OPTUNA_PROFILE",
        "source_label": "OPTUNA_SOURCE_LABEL",
        "execution_mode": "OPTUNA_EXECUTION_MODE",
        "param_count": "OPTUNA_PARAM_COUNT",
        "runtime_mutable_count": "OPTUNA_RUNTIME_MUTABLE_COUNT",
        "runtime_mutable_only": "OPTUNA_RUNTIME_MUTABLE_ONLY",
    }
    for key, env_name in env_map.items():
        if key in metadata:
            continue
        raw = os.environ.get(env_name)
        if raw in (None, ""):
            continue
        if key.endswith("_count"):
            try:
                metadata[key] = int(raw)
            except ValueError:
                metadata[key] = raw
        elif key == "runtime_mutable_only":
            metadata[key] = raw.lower() in {"1", "true", "yes", "on"}
        else:
            metadata[key] = raw

    if "search_groups" not in metadata:
        raw_groups = os.environ.get("OPTUNA_SEARCH_GROUPS", "")
        if raw_groups:
            metadata["search_groups"] = [
                item.strip() for item in raw_groups.split(",") if item.strip()
            ]
    return _sanitize_optuna_metadata(metadata)


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
        "--optuna-metadata-json",
        default=os.environ.get("OPTUNA_METADATA_JSON", ""),
        help="Optional path to Optuna metadata or trial_config.json for run attribution.",
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
    targets.append(
        TargetSpec(
            path="test/performance/simulation/creature_performance_test.dart",
            suite="creature_performance",
        )
    )

    if profile in {"nightly", "investigative"}:
        targets.append(
            TargetSpec(
                path="test/performance/simulation/creature_species_investigative_test.dart",
                suite="creature_investigative",
            )
        )
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


def _collect_creature_runtime_snapshot(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    snapshot: dict[str, Any] = {
        "creature_population_alive": 0.0,
        "creature_spawn_success_rate": 0.0,
        "creature_tick_ms_p50": 0.0,
        "creature_tick_ms_p95": 0.0,
        "creature_render_ms_p50": 0.0,
        "creature_render_ms_p95": 0.0,
        "creature_queen_alive_ratio": 0.0,
        "creature_visibility_failures": 0.0,
        "species": "ant",
        "device_class": "desktop",
    }
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        if str(scenario.get("suite", "")).strip() != "creature_performance":
            continue
        metrics = scenario.get("metrics", {})
        if not isinstance(metrics, dict):
            continue
        for key in (
            "creature_population_alive",
            "creature_spawn_success_rate",
            "creature_tick_ms_p50",
            "creature_tick_ms_p95",
            "creature_render_ms_p50",
            "creature_render_ms_p95",
            "creature_queen_alive_ratio",
            "creature_visibility_failures",
        ):
            if key in metrics:
                snapshot[key] = float(metrics[key])
        tags = scenario.get("tags", {})
        if isinstance(tags, dict):
            if "species" in tags:
                snapshot["species"] = str(tags["species"])
            if "device_class" in tags:
                snapshot["device_class"] = str(tags["device_class"])
    return snapshot


def _collect_physics_runtime_snapshot(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    snapshot: dict[str, Any] = {
        "phase_samples": [],
        "dirty_chunk_amplification_ratio": 0.0,
        "profile": "unknown",
        "device_class": "desktop",
    }
    phase_metric_map = {
        "movement_gravity": "physics_phase_duration_ms_movement_gravity",
        "chemistry_phase_change": "physics_phase_duration_ms_chemistry_phase_change",
        "electricity_light_moisture": "physics_phase_duration_ms_electricity_light_moisture",
        "structural_stress": "physics_phase_duration_ms_structural_stress",
        "entity_creature_effects": "physics_phase_duration_ms_entity_creature_effects",
    }
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        metrics = scenario.get("metrics", {})
        if not isinstance(metrics, dict):
            continue
        tags = scenario.get("tags", {})
        if isinstance(tags, dict) and "device_class" in tags:
            snapshot["device_class"] = str(tags["device_class"])
        for phase, metric_key in phase_metric_map.items():
            if metric_key in metrics:
                snapshot["phase_samples"].append(
                    {
                        "key": phase,
                        "group": phase,
                        "ran": True,
                        "duration_ms": float(metrics[metric_key]),
                        "cells_visited": int(float(metrics.get(f"{metric_key}_cells_visited", 0.0))),
                        "cells_changed": int(float(metrics.get(f"{metric_key}_cells_changed", 0.0))),
                        "dirty_chunks_visited": int(float(metrics.get(f"{metric_key}_dirty_chunks_visited", 0.0))),
                        "dirty_chunks_skipped": int(float(metrics.get(f"{metric_key}_dirty_chunks_skipped", 0.0))),
                    }
                )
        if "dirty_chunk_amplification_ratio" in metrics:
            snapshot["dirty_chunk_amplification_ratio"] = float(metrics["dirty_chunk_amplification_ratio"])
    return snapshot


def _collect_worldgen_stage_summary(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "preset": "unknown",
        "stages": [],
        "topology": {},
        "validation": {},
    }
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        metrics = scenario.get("metrics", {})
        if not isinstance(metrics, dict):
            continue
        tags = scenario.get("tags", {})
        if isinstance(tags, dict) and "preset" in tags:
            summary["preset"] = str(tags["preset"])
        for key, value in metrics.items():
            if key.startswith("worldgen_stage_duration_ms_"):
                stage_name = key.removeprefix("worldgen_stage_duration_ms_")
                summary["stages"].append(
                    {
                        "stage_name": stage_name,
                        "duration_ms": float(value),
                        "writes": int(float(metrics.get(f"worldgen_stage_writes_{stage_name}", 0.0))),
                        "overwrites": int(float(metrics.get(f"worldgen_stage_overwrites_{stage_name}", 0.0))),
                        "validation_failures": int(float(metrics.get(f"worldgen_stage_validation_failures_{stage_name}", 0.0))),
                    }
                )
        for metric_key in (
            "water_coverage_ratio",
            "cave_air_ratio",
            "surface_roughness",
            "hazard_density",
            "atmosphere_coverage_ratio",
            "colony_count",
        ):
            if metric_key in metrics:
                summary["topology"][metric_key] = float(metrics[metric_key])
        for metric_key in (
            "unsupported_floating_liquids",
            "thermal_anomalies",
            "invalid_colony_placements",
            "atmosphere_conflicts",
        ):
            if metric_key in metrics:
                summary["validation"][metric_key] = int(float(metrics[metric_key]))
    return summary


def _collect_render_runtime_snapshot(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    snapshot: dict[str, Any] = {
        "quality_profile": "unknown",
        "quality_tier": "unknown",
        "post_process_tier": "unknown",
        "render_pixel_passes": 0.0,
        "image_build_passes": 0.0,
        "post_process_passes": 0.0,
        "render_skipped_frames": 0.0,
        "wrap_copies_last_frame": 0.0,
        "frame_budget_skips": 0.0,
        "creature_batch_passes": 0.0,
        "creature_direct_passes": 0.0,
        "device_class": "desktop",
        "interaction": "unknown",
        "stage_samples": [],
        "dirty_region_summary": {
            "active_dirty_chunks": 0.0,
            "total_chunks": 0.0,
            "dirty_coverage_ratio": 0.0,
            "full_rebuilds": 0.0,
            "incremental_rebuilds": 0.0,
            "cache_invalidations": 0.0,
            "atmosphere_cache_refreshes": 0.0,
        },
    }
    render_metric_keys = (
        "render_pixel_passes",
        "image_build_passes",
        "post_process_passes",
        "render_skipped_frames",
        "wrap_copies_last_frame",
        "frame_budget_skips",
        "creature_batch_passes",
        "creature_direct_passes",
    )
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        metrics = scenario.get("metrics", {})
        if not isinstance(metrics, dict):
            continue
        matching_keys = [key for key in render_metric_keys if key in metrics]
        if not matching_keys:
            continue
        for key in matching_keys:
            snapshot[key] = float(metrics[key])
        tags = scenario.get("tags", {})
        if isinstance(tags, dict):
            if "device_class" in tags:
                snapshot["device_class"] = str(tags["device_class"])
            if "interaction" in tags:
                snapshot["interaction"] = str(tags["interaction"])
            if "quality_profile" in tags:
                snapshot["quality_profile"] = str(tags["quality_profile"])
            if "quality_tier" in tags:
                snapshot["quality_tier"] = str(tags["quality_tier"])
            if "post_process_tier" in tags:
                snapshot["post_process_tier"] = str(tags["post_process_tier"])
        for stage_key, value in metrics.items():
            if not stage_key.startswith("render_stage_duration_ms_"):
                continue
            stage_name = stage_key.removeprefix("render_stage_duration_ms_")
            snapshot["stage_samples"].append(
                {
                    "stage": stage_name,
                    "duration_ms": float(value),
                    "ran": float(value) > 0.0,
                }
            )
        dirty_map = {
            "dirty_active_chunks": "active_dirty_chunks",
            "dirty_total_chunks": "total_chunks",
            "dirty_coverage_ratio": "dirty_coverage_ratio",
            "full_rebuilds": "full_rebuilds",
            "incremental_rebuilds": "incremental_rebuilds",
            "cache_invalidations": "cache_invalidations",
            "atmosphere_cache_refreshes": "atmosphere_cache_refreshes",
        }
        for metric_key, snapshot_key in dirty_map.items():
            if metric_key in metrics:
                snapshot["dirty_region_summary"][snapshot_key] = float(metrics[metric_key])
    return snapshot


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
    creature_runtime_snapshot = _collect_creature_runtime_snapshot(scenarios)
    physics_runtime_snapshot = _collect_physics_runtime_snapshot(scenarios)
    worldgen_stage_summary = _collect_worldgen_stage_summary(scenarios)
    render_runtime_snapshot = _collect_render_runtime_snapshot(scenarios)
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
    optuna_metadata = _load_optuna_metadata(args.optuna_metadata_json)

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
            "quality_score_total": 0.0,
            "quality_grade": "F",
            "quality_gate_failed": False,
            "quality_gate_reason": "not_computed_by_performance_pipeline",
            "quality_threshold": 0.0,
            "component_scores": {},
            "component_weights": {},
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
        "creature_runtime_snapshot": creature_runtime_snapshot,
        "physics_runtime_snapshot": physics_runtime_snapshot,
        "worldgen_stage_summary": worldgen_stage_summary,
        "render_runtime_snapshot": render_runtime_snapshot,
        "quality_components": [],
        "optuna": optuna_metadata,
    }

    run_json = run_dir / "run.json"
    run_json.write_text(json.dumps(run_payload, indent=2, sort_keys=True), encoding="utf-8")
    creature_snapshot_json = run_dir / "creature_runtime_snapshot.json"
    creature_snapshot_json.write_text(
        json.dumps(creature_runtime_snapshot, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (run_dir / "physics_runtime_snapshot.json").write_text(
        json.dumps(physics_runtime_snapshot, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (run_dir / "worldgen_stage_summary.json").write_text(
        json.dumps(worldgen_stage_summary, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (run_dir / "render_runtime_snapshot.json").write_text(
        json.dumps(render_runtime_snapshot, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (run_dir / "render_stage_summary.json").write_text(
        json.dumps(render_runtime_snapshot.get("stage_samples", []), indent=2, sort_keys=True),
        encoding="utf-8",
    )

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
