"""Unified quality-score pipeline for front-to-back game testing."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from storage import DuckDBPerfStore, JsonlPerfStore, PostgresPerfStore, SQLitePerfStore, StorageConfig


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SQLITE = ROOT / "research" / "telemetry" / "perf_history.sqlite"
DEFAULT_HISTORY_JSONL = ROOT / "research" / "telemetry" / "perf_history.jsonl"
DEFAULT_RUNS_DIR = ROOT / "reports" / "performance" / "runs"
EXPORT_OTLP_SCRIPT = ROOT / "tool" / "performance" / "export_otlp.py"

RUN_SCHEMA_VERSION = 6

COMPONENT_WEIGHTS = {
    "correctness_score": 35.0,
    "performance_score": 30.0,
    "reliability_score": 15.0,
    "visual_score": 10.0,
    "mobile_score": 10.0,
}

ADVISORY_COMPONENT_WEIGHTS = {
    "physics_correctness_score": 0.0,
    "physics_performance_score": 0.0,
    "worldgen_correctness_score": 0.0,
    "worldgen_performance_score": 0.0,
    "chemistry_coherence_score": 0.0,
    "render_correctness_score": 0.0,
    "render_performance_score": 0.0,
}


@dataclass
class LaneResult:
    lane: str
    total: int
    failed: int
    timed_out: int
    duration_ms: float
    return_code: int

    @property
    def pass_rate(self) -> float:
        if self.total <= 0:
            return 1.0
        return max(0.0, min(1.0, (self.total - self.failed) / self.total))


@dataclass
class QualityGateDecision:
    failed: bool
    reason: str
    threshold: float



def _clip(v: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, v))



def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if isinstance(value, bool):
            return 1.0 if value else 0.0
        return float(value)
    except (TypeError, ValueError):
        return default



def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default



def _parse_flutter_machine(path: Path, lane: str) -> LaneResult:
    total = 0
    failed = 0
    timed_out = 0
    return_code = 0
    if not path.exists():
        return LaneResult(lane=lane, total=0, failed=0, timed_out=0, duration_ms=0.0, return_code=1)

    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s:
            continue
        if "TIMEOUT" in s or "timed out" in s.lower():
            timed_out = max(timed_out, 1)
        try:
            event = json.loads(s)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "testDone":
            if bool(event.get("hidden", False)):
                continue
            total += 1
            if event.get("result") != "success":
                failed += 1
    if total == 0:
        return_code = 1
    elif failed > 0:
        return_code = 1
    return LaneResult(lane=lane, total=total, failed=failed, timed_out=timed_out, duration_ms=0.0, return_code=return_code)



def _parse_pytest_junit(path: Path, lane: str) -> LaneResult:
    if not path.exists():
        return LaneResult(lane=lane, total=0, failed=0, timed_out=0, duration_ms=0.0, return_code=1)
    try:
        tree = ET.parse(path)
    except ET.ParseError:
        return LaneResult(lane=lane, total=0, failed=0, timed_out=0, duration_ms=0.0, return_code=1)

    root = tree.getroot()
    total = 0
    failed = 0
    duration_s = 0.0

    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    for suite in suites:
        total += _safe_int(suite.attrib.get("tests", 0))
        failed += _safe_int(suite.attrib.get("failures", 0))
        failed += _safe_int(suite.attrib.get("errors", 0))
        duration_s += _safe_float(suite.attrib.get("time", 0.0))

    if total == 0:
        total = _safe_int(root.attrib.get("tests", 0))
    if failed == 0:
        failed = _safe_int(root.attrib.get("failures", 0)) + _safe_int(root.attrib.get("errors", 0))

    return LaneResult(
        lane=lane,
        total=total,
        failed=failed,
        timed_out=0,
        duration_ms=duration_s * 1000.0,
        return_code=0 if total > 0 and failed == 0 else 1,
    )



def _load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return payload if isinstance(payload, dict) else None



def _find_first(paths: list[Path], *patterns: str) -> Path | None:
    for base in paths:
        for pattern in patterns:
            hits = sorted(base.rglob(pattern))
            if hits:
                return hits[0]
    return None



def _find_perf_run(paths: list[Path]) -> Path | None:
    for base in paths:
        for candidate in sorted(base.rglob("run.json")):
            payload = _load_json(candidate)
            if not payload:
                continue
            if "summary" in payload and "test_cases" in payload:
                return candidate
    return None


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


def _extract_optuna_metadata(
    perf_run: dict[str, Any] | None, trial_config: dict[str, Any] | None
) -> dict[str, Any]:
    candidates: list[Any] = []
    if isinstance(perf_run, dict):
        candidates.extend(
            [
                perf_run.get("optuna"),
                perf_run.get("summary", {}).get("optuna"),
                perf_run.get("quality_context", {}).get("optuna"),
            ]
        )
    if isinstance(trial_config, dict):
        candidates.extend([trial_config.get("optuna"), trial_config])
    for candidate in candidates:
        cleaned = _sanitize_optuna_metadata(candidate)
        if cleaned:
            return cleaned
    return {}



def _grade(score: float) -> str:
    if score >= 90.0:
        return "A"
    if score >= 80.0:
        return "B"
    if score >= 70.0:
        return "C"
    if score >= 60.0:
        return "D"
    return "F"



def _component(
    key: str,
    score: float,
    weight: float,
    raw_pass_rate: float,
    status: str,
    details: dict[str, Any],
) -> dict[str, Any]:
    return {
        "component_key": key,
        "score": round(_clip(score), 3),
        "weight": weight,
        "raw_pass_rate": round(max(0.0, min(1.0, raw_pass_rate)), 6),
        "status": status,
        "details": details,
    }



def _compute_scores(
    *,
    profile: str,
    lanes: dict[str, LaneResult],
    perf_run: dict[str, Any] | None,
    android_summary: dict[str, Any] | None,
) -> tuple[
    dict[str, Any],
    list[dict[str, Any]],
    bool,
    bool,
    dict[str, float],
    bool,
    dict[str, float],
]:
    summary = perf_run.get("summary", {}) if isinstance(perf_run, dict) else {}

    correctness_lanes = [
        lanes.get("unit", LaneResult("unit", 0, 0, 0, 0.0, 1)),
        lanes.get("smoke", LaneResult("smoke", 0, 0, 0, 0.0, 1)),
        lanes.get("integration", LaneResult("integration", 0, 0, 0, 0.0, 1)),
        lanes.get("python", LaneResult("python", 0, 0, 0, 0.0, 1)),
    ]
    correctness_total = sum(max(0, lane.total) for lane in correctness_lanes)
    correctness_failed = sum(max(0, lane.failed) for lane in correctness_lanes)
    correctness_rate = 1.0 if correctness_total == 0 else max(0.0, (correctness_total - correctness_failed) / correctness_total)
    correctness_score = correctness_rate * 100.0

    perf_total = max(1, _safe_int(summary.get("total_tests", 0), 1))
    perf_failed = _safe_int(summary.get("failed_tests", 0), 0)
    perf_timeouts = _safe_int(summary.get("timed_out_targets", 0), 0)
    perf_fail_ratio = min(1.0, perf_failed / perf_total)
    timeout_ratio = min(1.0, perf_timeouts / max(1, _safe_int(summary.get("failed_targets", 0), 0) + 1))

    baseline_warning = bool(summary.get("baseline_warning", False))
    scenario_pass = 0
    scenario_total = 0
    for scenario in perf_run.get("scenarios", []) if isinstance(perf_run, dict) else []:
        metrics = scenario.get("metrics", {}) if isinstance(scenario, dict) else {}
        if not isinstance(metrics, dict):
            continue
        for key, raw in metrics.items():
            if not isinstance(key, str):
                continue
            lname = key.lower()
            if lname.endswith("_pass") or "within_budget" in lname or "budget_pass" in lname:
                scenario_total += 1
                if _safe_float(raw) >= 1.0:
                    scenario_pass += 1
    scenario_ratio = 1.0 if scenario_total == 0 else scenario_pass / scenario_total

    performance_score = _clip((scenario_ratio * 100.0) - (perf_fail_ratio * 45.0) - (timeout_ratio * 30.0) - (15.0 if baseline_warning else 0.0))

    telemetry_complete = bool(summary.get("telemetry_complete", False))
    failed_targets = _safe_int(summary.get("failed_targets", 0), 0)
    reliability_score = 100.0
    reliability_score -= min(40.0, perf_timeouts * 15.0)
    reliability_score -= min(35.0, failed_targets * 8.0)
    if not telemetry_complete:
        reliability_score -= 35.0
    reliability_score = _clip(reliability_score)

    total_visual = _safe_int(summary.get("total_visual_cases", 0), 0)
    failed_visual = _safe_int(summary.get("failed_visual_cases", 0), 0)
    visual_rate = 1.0
    avg_ssim = 1.0
    avg_diff = 0.0
    if total_visual > 0:
        visual_rate = max(0.0, (total_visual - failed_visual) / total_visual)
        ssims: list[float] = []
        diffs: list[float] = []
        for art in perf_run.get("visual_artifacts", []) if isinstance(perf_run, dict) else []:
            if not isinstance(art, dict):
                continue
            ssims.append(_safe_float(art.get("ssim", 1.0), 1.0))
            diffs.append(_safe_float(art.get("diff_ratio", 0.0), 0.0))
        if ssims:
            avg_ssim = sum(ssims) / len(ssims)
        if diffs:
            avg_diff = sum(diffs) / len(diffs)
    visual_quality = _clip((avg_ssim * 80.0) + ((1.0 - min(1.0, avg_diff)) * 20.0))
    visual_score = _clip((visual_rate * 60.0) + (visual_quality * 0.4))
    if total_visual == 0 and profile == "pr":
        visual_score = 90.0

    mobile_hard_fail = False
    if android_summary is not None:
        targets = android_summary.get("targets", [])
        if isinstance(targets, list) and targets:
            m_total = sum(_safe_int(t.get("tests_total", 0), 0) for t in targets if isinstance(t, dict))
            m_failed = sum(_safe_int(t.get("tests_failed", 0), 0) for t in targets if isinstance(t, dict))
            m_timeouts = sum(1 for t in targets if isinstance(t, dict) and bool(t.get("timed_out", False)))
            m_rate = 1.0 if m_total == 0 else max(0.0, (m_total - m_failed) / m_total)
            mobile_score = _clip((m_rate * 100.0) - (m_timeouts * 25.0))
            mobile_hard_fail = _safe_int(android_summary.get("android_runtime_return_code", 0), 0) != 0 or m_timeouts > 0
            mobile_raw_rate = m_rate
            mobile_status = "pass" if not mobile_hard_fail else "fail"
            mobile_details = {
                "tests_total": m_total,
                "tests_failed": m_failed,
                "timeouts": m_timeouts,
                "android_runtime_return_code": _safe_int(android_summary.get("android_runtime_return_code", 0), 0),
            }
        else:
            mobile_score = 0.0 if profile in {"nightly", "investigative"} else 100.0
            mobile_raw_rate = 0.0 if profile in {"nightly", "investigative"} else 1.0
            mobile_status = "missing"
            mobile_hard_fail = profile in {"nightly", "investigative"}
            mobile_details = {"reason": "android summary had no targets"}
    else:
        mobile_score = 0.0 if profile in {"nightly", "investigative"} else 100.0
        mobile_raw_rate = 0.0 if profile in {"nightly", "investigative"} else 1.0
        mobile_status = "missing"
        mobile_hard_fail = profile in {"nightly", "investigative"}
        mobile_details = {"reason": "android summary missing"}

    creature_snapshot = perf_run.get("creature_runtime_snapshot", {}) if isinstance(perf_run, dict) else {}
    creature_population_alive = _safe_float(creature_snapshot.get("creature_population_alive", 0.0), 0.0)
    creature_spawn_success_rate = _safe_float(creature_snapshot.get("creature_spawn_success_rate", 0.0), 0.0)
    creature_tick_p95 = _safe_float(creature_snapshot.get("creature_tick_ms_p95", 0.0), 0.0)
    creature_render_p95 = _safe_float(creature_snapshot.get("creature_render_ms_p95", 0.0), 0.0)
    creature_queen_alive_ratio = _safe_float(creature_snapshot.get("creature_queen_alive_ratio", 0.0), 0.0)
    creature_visibility_failures = _safe_int(creature_snapshot.get("creature_visibility_failures", 0), 0)
    visibility_contract_pass = (
        creature_population_alive > 0 and creature_visibility_failures == 0
    )

    creature_correctness_score = _clip(
        (creature_spawn_success_rate * 60.0)
        + (40.0 if visibility_contract_pass else 0.0)
        - min(40.0, creature_visibility_failures * 10.0)
    )
    creature_performance_score = _clip(
        100.0
        - max(0.0, (creature_tick_p95 - 8.0) * 8.0)
        - max(0.0, (creature_render_p95 - 5.0) * 10.0)
    )
    creature_reliability_score = _clip(
        (creature_queen_alive_ratio * 70.0)
        + (30.0 if creature_population_alive > 0 else 0.0)
        - min(40.0, creature_visibility_failures * 10.0)
    )
    creature_scores = {
        "creature_correctness_score": round(creature_correctness_score, 3),
        "creature_performance_score": round(creature_performance_score, 3),
        "creature_reliability_score": round(creature_reliability_score, 3),
    }
    creature_contract_failed = (
        creature_population_alive <= 0
        or creature_spawn_success_rate <= 0.0
        or creature_visibility_failures > 0
    )

    physics_snapshot = perf_run.get("physics_runtime_snapshot", {}) if isinstance(perf_run, dict) else {}
    phase_samples = physics_snapshot.get("phase_samples", []) if isinstance(physics_snapshot, dict) else []
    phase_count = len(phase_samples) if isinstance(phase_samples, list) else 0
    dirty_amplification = _safe_float(physics_snapshot.get("dirty_chunk_amplification_ratio", 0.0), 0.0)
    physics_correctness_score = _clip(65.0 + min(35.0, phase_count * 7.0))
    physics_performance_score = _clip(100.0 - max(0.0, dirty_amplification - 1.25) * 35.0)

    worldgen_summary = perf_run.get("worldgen_stage_summary", {}) if isinstance(perf_run, dict) else {}
    topology = worldgen_summary.get("topology", {}) if isinstance(worldgen_summary, dict) else {}
    validation = worldgen_summary.get("validation", {}) if isinstance(worldgen_summary, dict) else {}
    worldgen_failures = (
        _safe_int(validation.get("unsupported_floating_liquids", 0), 0)
        + _safe_int(validation.get("thermal_anomalies", 0), 0)
        + _safe_int(validation.get("invalid_colony_placements", 0), 0)
        + _safe_int(validation.get("atmosphere_conflicts", 0), 0)
    )
    surface_roughness = _safe_float(topology.get("surface_roughness", 0.0), 0.0)
    worldgen_correctness_score = _clip(100.0 - min(80.0, worldgen_failures * 8.0))
    worldgen_performance_score = _clip(100.0 - max(0.0, surface_roughness - 12.0) * 2.0)
    chemistry_coherence_score = _clip(
        70.0 + min(30.0, phase_count * 3.0) - min(20.0, worldgen_failures * 2.0)
    )
    render_snapshot = perf_run.get("render_runtime_snapshot", {}) if isinstance(perf_run, dict) else {}
    render_stages = render_snapshot.get("stage_samples", []) if isinstance(render_snapshot, dict) else []
    render_dirty = render_snapshot.get("dirty_region_summary", {}) if isinstance(render_snapshot, dict) else {}
    render_stage_count = len(render_stages) if isinstance(render_stages, list) else 0
    dirty_coverage = _safe_float(render_dirty.get("dirty_coverage_ratio", 0.0), 0.0)
    full_rebuilds = _safe_float(render_dirty.get("full_rebuilds", 0.0), 0.0)
    frame_budget_skips = _safe_float(render_snapshot.get("frame_budget_skips", 0.0), 0.0)
    quality_tier = str(render_snapshot.get("quality_tier", "unknown"))
    render_correctness_score = _clip(
        70.0
        + min(20.0, render_stage_count * 4.0)
        + (10.0 if quality_tier != "unknown" else 0.0)
        - min(20.0, full_rebuilds * 1.5)
    )
    render_performance_score = _clip(
        100.0
        - min(35.0, max(0.0, dirty_coverage - 0.35) * 70.0)
        - min(30.0, full_rebuilds * 1.5)
        - min(20.0, frame_budget_skips * 2.0)
    )
    advisory_scores = {
        "physics_correctness_score": round(physics_correctness_score, 3),
        "physics_performance_score": round(physics_performance_score, 3),
        "worldgen_correctness_score": round(worldgen_correctness_score, 3),
        "worldgen_performance_score": round(worldgen_performance_score, 3),
        "chemistry_coherence_score": round(chemistry_coherence_score, 3),
        "render_correctness_score": round(render_correctness_score, 3),
        "render_performance_score": round(render_performance_score, 3),
    }

    components = [
        _component(
            "correctness_score",
            correctness_score,
            COMPONENT_WEIGHTS["correctness_score"],
            correctness_rate,
            "pass" if correctness_rate >= 0.9 else "warn",
            {
                "total_tests": correctness_total,
                "failed_tests": correctness_failed,
            },
        ),
        _component(
            "performance_score",
            performance_score,
            COMPONENT_WEIGHTS["performance_score"],
            max(0.0, 1.0 - perf_fail_ratio),
            "pass" if performance_score >= 75.0 else "warn",
            {
                "scenario_budget_pass_ratio": round(scenario_ratio, 6),
                "failed_tests": perf_failed,
                "timed_out_targets": perf_timeouts,
                "baseline_warning": baseline_warning,
            },
        ),
        _component(
            "reliability_score",
            reliability_score,
            COMPONENT_WEIGHTS["reliability_score"],
            1.0 if telemetry_complete else 0.0,
            "pass" if reliability_score >= 80.0 else "warn",
            {
                "telemetry_complete": telemetry_complete,
                "failed_targets": failed_targets,
                "timed_out_targets": perf_timeouts,
            },
        ),
        _component(
            "visual_score",
            visual_score,
            COMPONENT_WEIGHTS["visual_score"],
            visual_rate,
            "pass" if visual_score >= 80.0 else "warn",
            {
                "total_visual_cases": total_visual,
                "failed_visual_cases": failed_visual,
                "avg_ssim": round(avg_ssim, 6),
                "avg_diff_ratio": round(avg_diff, 6),
            },
        ),
        _component(
            "mobile_score",
            mobile_score,
            COMPONENT_WEIGHTS["mobile_score"],
            mobile_raw_rate,
            mobile_status,
            mobile_details,
        ),
        _component(
            "creature_correctness_score",
            creature_correctness_score,
            0.0,
            creature_spawn_success_rate,
            "pass" if creature_correctness_score >= 75.0 else "warn",
            {
                "creature_population_alive": creature_population_alive,
                "creature_visibility_failures": creature_visibility_failures,
            },
        ),
        _component(
            "creature_performance_score",
            creature_performance_score,
            0.0,
            max(0.0, 1.0 - (max(creature_tick_p95 - 8.0, 0.0) / 20.0)),
            "pass" if creature_performance_score >= 75.0 else "warn",
            {
                "creature_tick_ms_p95": creature_tick_p95,
                "creature_render_ms_p95": creature_render_p95,
            },
        ),
        _component(
            "creature_reliability_score",
            creature_reliability_score,
            0.0,
            creature_queen_alive_ratio,
            "pass" if creature_reliability_score >= 75.0 else "warn",
            {
                "creature_queen_alive_ratio": creature_queen_alive_ratio,
                "creature_visibility_failures": creature_visibility_failures,
            },
        ),
        _component(
            "physics_correctness_score",
            physics_correctness_score,
            ADVISORY_COMPONENT_WEIGHTS["physics_correctness_score"],
            1.0 if phase_count > 0 else 0.0,
            "pass" if physics_correctness_score >= 75.0 else "warn",
            {
                "phase_sample_count": phase_count,
            },
        ),
        _component(
            "physics_performance_score",
            physics_performance_score,
            ADVISORY_COMPONENT_WEIGHTS["physics_performance_score"],
            max(0.0, 1.0 - max(0.0, dirty_amplification - 1.0)),
            "pass" if physics_performance_score >= 75.0 else "warn",
            {
                "dirty_chunk_amplification_ratio": round(dirty_amplification, 6),
            },
        ),
        _component(
            "worldgen_correctness_score",
            worldgen_correctness_score,
            ADVISORY_COMPONENT_WEIGHTS["worldgen_correctness_score"],
            1.0 if worldgen_failures == 0 else max(0.0, 1.0 - worldgen_failures / 10.0),
            "pass" if worldgen_correctness_score >= 75.0 else "warn",
            {
                "validation_failures": worldgen_failures,
            },
        ),
        _component(
            "worldgen_performance_score",
            worldgen_performance_score,
            ADVISORY_COMPONENT_WEIGHTS["worldgen_performance_score"],
            1.0,
            "pass" if worldgen_performance_score >= 75.0 else "warn",
            {
                "surface_roughness": round(surface_roughness, 6),
            },
        ),
        _component(
            "chemistry_coherence_score",
            chemistry_coherence_score,
            ADVISORY_COMPONENT_WEIGHTS["chemistry_coherence_score"],
            1.0 if phase_count > 0 else 0.0,
            "pass" if chemistry_coherence_score >= 75.0 else "warn",
            {
                "phase_sample_count": phase_count,
                "worldgen_failures": worldgen_failures,
            },
        ),
        _component(
            "render_correctness_score",
            render_correctness_score,
            ADVISORY_COMPONENT_WEIGHTS["render_correctness_score"],
            1.0 if render_stage_count > 0 else 0.0,
            "pass" if render_correctness_score >= 75.0 else "warn",
            {
                "render_stage_count": render_stage_count,
                "quality_tier": quality_tier,
                "full_rebuilds": round(full_rebuilds, 3),
            },
        ),
        _component(
            "render_performance_score",
            render_performance_score,
            ADVISORY_COMPONENT_WEIGHTS["render_performance_score"],
            max(0.0, 1.0 - dirty_coverage),
            "pass" if render_performance_score >= 75.0 else "warn",
            {
                "dirty_coverage_ratio": round(dirty_coverage, 6),
                "frame_budget_skips": round(frame_budget_skips, 3),
            },
        ),
    ]

    component_scores = {
        c["component_key"]: c["score"]
        for c in components
        if c["weight"] > 0
    }
    score_total = 0.0
    for c in components:
        score_total += c["score"] * (c["weight"] / 100.0)
    score_total = round(_clip(score_total), 3)

    return (
        component_scores,
        components,
        mobile_hard_fail,
        telemetry_complete,
        creature_scores,
        creature_contract_failed,
        advisory_scores,
    )



def _decide_gate(
    *,
    profile: str,
    quality_score_total: float,
    telemetry_complete: bool,
    timed_out_targets: int,
    mobile_hard_fail: bool,
    creature_contract_failed: bool,
    gate_start_date: datetime,
    warmup_days: int,
    enforce_investigative_gate: bool,
) -> QualityGateDecision:
    now = datetime.now(tz=UTC)
    threshold = 0.0
    should_enforce = True

    if profile == "pr":
        threshold = 75.0
        warmup_until = gate_start_date + timedelta(days=warmup_days)
        if now < warmup_until:
            should_enforce = False
    elif profile == "nightly":
        threshold = 85.0
    elif profile == "investigative":
        threshold = 85.0
        should_enforce = enforce_investigative_gate

    hard_fail_reasons: list[str] = []
    if timed_out_targets > 0:
        hard_fail_reasons.append("timed_out_targets")
    if not telemetry_complete:
        hard_fail_reasons.append("telemetry_incomplete")
    if profile in {"nightly", "investigative"} and mobile_hard_fail:
        hard_fail_reasons.append("mobile_lane_failed")
    if creature_contract_failed:
        hard_fail_reasons.append("creature_contract_failed")

    if hard_fail_reasons:
        if should_enforce:
            return QualityGateDecision(True, ",".join(hard_fail_reasons), threshold)
        return QualityGateDecision(False, f"warmup_override:{','.join(hard_fail_reasons)}", threshold)

    if quality_score_total < threshold:
        if should_enforce:
            return QualityGateDecision(True, f"score_below_threshold:{quality_score_total:.2f}<{threshold:.2f}", threshold)
        return QualityGateDecision(False, f"warmup_override:score_below_threshold:{quality_score_total:.2f}<{threshold:.2f}", threshold)

    return QualityGateDecision(False, "pass", threshold)



def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run/ingest front-to-back quality scoring pipeline.")
    parser.add_argument("--profile", default="pr", choices=["pr", "nightly", "investigative"])
    parser.add_argument("--mode", default="ingest", choices=["ingest", "run"]) 
    parser.add_argument("--artifact-root", default="", help="Root directory containing lane artifacts for ingest mode.")
    parser.add_argument("--artifact-dir", default="", help="Quality run artifact directory override.")
    parser.add_argument("--sqlite-path", default=str(DEFAULT_SQLITE))
    parser.add_argument("--history-jsonl-path", default=str(DEFAULT_HISTORY_JSONL))
    parser.add_argument("--duckdb-path", default="")
    parser.add_argument("--postgres-dsn", default="")
    parser.add_argument("--export-otlp", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--otlp-service-name", default="particle-engine-quality")
    parser.add_argument("--gate-start-date", default=os.environ.get("QUALITY_GATE_START_DATE", "2026-03-27"))
    parser.add_argument("--warmup-days", type=int, default=14)
    parser.add_argument("--enforce-investigative-gate", action=argparse.BooleanOptionalAction, default=False)
    return parser



def _run_cmd(cmd: list[str], output_file: Path) -> int:
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=False)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text((proc.stdout or "") + (proc.stderr or ""), encoding="utf-8")
    return proc.returncode



def _run_lanes(profile: str, run_dir: Path) -> dict[str, Path]:
    out: dict[str, Path] = {}
    machine_dir = run_dir / "lane_outputs"

    unit_machine = machine_dir / "unit.machine.jsonl"
    rc = _run_cmd(["flutter", "test", "--machine", "--no-pub", "test/unit"], unit_machine)
    if rc == 0:
        out["unit_machine"] = unit_machine

    smoke_machine = machine_dir / "smoke.machine.jsonl"
    rc = _run_cmd(["flutter", "test", "--machine", "--no-pub", "test/smoke"], smoke_machine)
    if rc == 0:
        out["smoke_machine"] = smoke_machine

    py_xml = machine_dir / "python.junit.xml"
    _run_cmd(
        [
            "python",
            "-m",
            "pytest",
            "research/tests/",
            "-q",
            "--tb=short",
            "--junitxml",
            str(py_xml),
        ],
        machine_dir / "python.log",
    )
    if py_xml.exists():
        out["python_junit"] = py_xml

    perf_cmd = [
        "python",
        "tool/performance/run_performance_pipeline.py",
        "--profile",
        profile,
        "--require-telemetry-complete",
    ]
    if profile in {"nightly", "investigative"}:
        perf_cmd += ["--include-soak", "--emit-visual-artifacts"]
    perf_log = machine_dir / "performance.log"
    _run_cmd(perf_cmd, perf_log)

    perf_run = _find_perf_run([run_dir, ROOT / "reports" / "performance" / "runs"])
    if perf_run:
        out["perf_run"] = perf_run

    if profile in {"nightly", "investigative"}:
        _run_cmd(
            ["python", "tool/performance/run_android_investigative_lane.py", "--target-timeout-seconds", "180"],
            machine_dir / "android_lane.log",
        )
        android_summary = _find_first([run_dir, ROOT / "reports" / "performance"], "android_lane_summary.json")
        if android_summary:
            out["android_summary"] = android_summary

    return out



def _export_otlp(run_json: Path, service_name: str) -> int:
    cmd = [
        sys.executable,
        str(EXPORT_OTLP_SCRIPT),
        "--run-json",
        str(run_json),
        "--service-name",
        service_name,
    ]
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=False)
    if proc.stdout.strip():
        print(proc.stdout.strip())
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)
    return proc.returncode



def main() -> int:
    args = _build_parser().parse_args()
    now = datetime.now(tz=UTC)
    run_id = f"quality_{now.strftime('%Y%m%dT%H%M%SZ')}"
    run_dir = Path(args.artifact_dir) if args.artifact_dir else (DEFAULT_RUNS_DIR / run_id)
    run_dir.mkdir(parents=True, exist_ok=True)

    search_roots = [run_dir]
    if args.artifact_root:
        search_roots.insert(0, Path(args.artifact_root))

    discovered: dict[str, Path] = {}
    if args.mode == "run":
        discovered = _run_lanes(args.profile, run_dir)
        trial_config = _find_first(search_roots, "trial_config.json")
        if trial_config:
            discovered["trial_config"] = trial_config
    else:
        unit_machine = _find_first(search_roots, "*unit*.machine.jsonl")
        smoke_machine = _find_first(search_roots, "*smoke*.machine.jsonl")
        py_junit = _find_first(search_roots, "*python*.xml", "*pytest*.xml")
        perf_run = _find_perf_run(search_roots)
        android_summary = _find_first(search_roots, "android_lane_summary.json")
        integration_junit = _find_first(search_roots, "*integration*.xml")
        trial_config = _find_first(search_roots, "trial_config.json")

        if unit_machine:
            discovered["unit_machine"] = unit_machine
        if smoke_machine:
            discovered["smoke_machine"] = smoke_machine
        if py_junit:
            discovered["python_junit"] = py_junit
        if perf_run:
            discovered["perf_run"] = perf_run
        if android_summary:
            discovered["android_summary"] = android_summary
        if integration_junit:
            discovered["integration_junit"] = integration_junit
        if trial_config:
            discovered["trial_config"] = trial_config

    lanes: dict[str, LaneResult] = {
        "unit": _parse_flutter_machine(discovered.get("unit_machine", Path("_missing")), "unit"),
        "smoke": _parse_flutter_machine(discovered.get("smoke_machine", Path("_missing")), "smoke"),
        "python": _parse_pytest_junit(discovered.get("python_junit", Path("_missing")), "python"),
        "integration": _parse_pytest_junit(discovered.get("integration_junit", Path("_missing")), "integration"),
    }

    perf_run = _load_json(discovered["perf_run"]) if "perf_run" in discovered else None
    android_summary = _load_json(discovered["android_summary"]) if "android_summary" in discovered else None
    trial_config = _load_json(discovered["trial_config"]) if "trial_config" in discovered else None

    if perf_run is None:
        perf_run = {
            "schema_version": RUN_SCHEMA_VERSION,
            "run_id": run_id,
            "timestamp_utc": now.isoformat(),
            "git_sha": None,
            "git_branch": None,
            "host": os.environ.get("HOSTNAME", "unknown"),
            "platform": sys.platform,
            "profile": args.profile,
            "soak_level": "quick",
            "summary": {
                "total_tests": 0,
                "failed_tests": 0,
                "failed_cases": 0,
                "failed_targets": 0,
                "timed_out_targets": 0,
                "telemetry_complete": False,
                "total_visual_cases": 0,
                "failed_visual_cases": 0,
                "duration_ms": 0.0,
            },
            "test_cases": [],
            "scenarios": [],
            "visual_artifacts": [],
        }

    optuna_metadata = _extract_optuna_metadata(perf_run, trial_config)

    (
        component_scores,
        components,
        mobile_hard_fail,
        telemetry_complete,
        creature_scores,
        creature_contract_failed,
        advisory_scores,
    ) = _compute_scores(
        profile=args.profile,
        lanes=lanes,
        perf_run=perf_run,
        android_summary=android_summary,
    )

    quality_total = 0.0
    for c in components:
        quality_total += c["score"] * (c["weight"] / 100.0)
    quality_total = round(_clip(quality_total), 3)

    try:
        gate_start = datetime.fromisoformat(args.gate_start_date).replace(tzinfo=UTC)
    except ValueError:
        gate_start = datetime(2026, 3, 27, tzinfo=UTC)

    gate = _decide_gate(
        profile=args.profile,
        quality_score_total=quality_total,
        telemetry_complete=telemetry_complete,
        timed_out_targets=_safe_int(perf_run.get("summary", {}).get("timed_out_targets", 0), 0),
        mobile_hard_fail=mobile_hard_fail,
        creature_contract_failed=creature_contract_failed,
        gate_start_date=gate_start,
        warmup_days=max(0, args.warmup_days),
        enforce_investigative_gate=args.enforce_investigative_gate,
    )

    perf_run["schema_version"] = RUN_SCHEMA_VERSION
    perf_run["profile"] = args.profile
    perf_run.setdefault("summary", {})
    perf_run["summary"]["quality_score_total"] = quality_total
    perf_run["summary"]["quality_grade"] = _grade(quality_total)
    perf_run["summary"]["quality_gate_failed"] = gate.failed
    perf_run["summary"]["quality_gate_reason"] = gate.reason
    perf_run["summary"]["quality_threshold"] = gate.threshold
    perf_run["summary"]["component_scores"] = component_scores
    perf_run["summary"]["component_weights"] = COMPONENT_WEIGHTS
    perf_run["summary"]["creature_scores"] = creature_scores
    perf_run["summary"]["physics_scores"] = {
        key: advisory_scores[key]
        for key in ("physics_correctness_score", "physics_performance_score")
    }
    perf_run["summary"]["worldgen_scores"] = {
        key: advisory_scores[key]
        for key in ("worldgen_correctness_score", "worldgen_performance_score")
    }
    perf_run["summary"]["chemistry_scores"] = {
        "chemistry_coherence_score": advisory_scores["chemistry_coherence_score"]
    }
    perf_run["summary"]["render_scores"] = {
        key: advisory_scores[key]
        for key in ("render_correctness_score", "render_performance_score")
    }
    perf_run["quality_components"] = components
    if optuna_metadata:
        perf_run["optuna"] = optuna_metadata

    quality_context = {
        "lanes": {
            lane: {
                "total": res.total,
                "failed": res.failed,
                "timed_out": res.timed_out,
                "duration_ms": round(res.duration_ms, 3),
                "return_code": res.return_code,
            }
            for lane, res in lanes.items()
        },
        "sources": {k: str(v) for k, v in discovered.items()},
        "profile": args.profile,
    }
    if optuna_metadata:
        quality_context["optuna"] = optuna_metadata
    perf_run["quality_context"] = quality_context

    run_json = run_dir / "run.json"
    run_json.write_text(json.dumps(perf_run, indent=2, sort_keys=True), encoding="utf-8")

    comparison = {
        "current_run_id": perf_run.get("run_id", run_id),
        "delta_quality_score_total": None,
        "delta_component_scores": {},
    }

    config = StorageConfig(
        sqlite_path=Path(args.sqlite_path),
        history_jsonl_path=Path(args.history_jsonl_path),
        duckdb_path=Path(args.duckdb_path) if args.duckdb_path else None,
        postgres_dsn=args.postgres_dsn or None,
    )
    sqlite_store = SQLitePerfStore(config.sqlite_path)
    jsonl_store = JsonlPerfStore(config.history_jsonl_path)
    duckdb_store = DuckDBPerfStore(config.duckdb_path) if config.duckdb_path else None
    postgres_store = PostgresPerfStore(config.postgres_dsn) if config.postgres_dsn else None

    try:
        previous = sqlite_store.get_previous_run(perf_run.get("run_id", run_id))
        if previous is not None:
            prev_quality = _safe_float(previous.get("quality_score_total", 0.0), 0.0)
            comparison["previous_run_id"] = previous.get("run_id")
            comparison["delta_quality_score_total"] = round(quality_total - prev_quality, 3)
            comparison["delta_component_scores"] = {
                key: round(value, 3) for key, value in component_scores.items()
            }

        sqlite_store.insert_run(perf_run)
        jsonl_store.append_run(perf_run)
        if duckdb_store:
            duckdb_store.insert_run(perf_run)
        if postgres_store:
            postgres_store.insert_run(perf_run)
    finally:
        sqlite_store.close()
        if duckdb_store:
            duckdb_store.close()
        if postgres_store:
            postgres_store.close()

    comparison_path = run_dir / "comparison.json"
    comparison_path.write_text(json.dumps(comparison, indent=2, sort_keys=True), encoding="utf-8")

    if args.export_otlp:
        export_code = _export_otlp(run_json, args.otlp_service_name)
        if export_code != 0:
            print(f"OTLP export failed code={export_code}", file=sys.stderr)
            return export_code

    print(f"run_id={perf_run.get('run_id', run_id)}")
    print(f"artifact_dir={run_dir}")
    print(f"quality_score_total={quality_total:.3f}")
    print(f"quality_grade={perf_run['summary']['quality_grade']}")
    print(f"quality_gate_failed={gate.failed}")
    print(f"quality_gate_reason={gate.reason}")

    return 7 if gate.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
