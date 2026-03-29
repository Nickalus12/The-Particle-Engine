"""Export a run artifact into OTLP metrics for LGTM/Grafana ingestion."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from collections.abc import Iterable
from typing import Any


def _load_run(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("run artifact must be a JSON object")
    return payload


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export run.json into OTLP metrics")
    parser.add_argument("--run-json", required=True, help="Path to run.json artifact")
    parser.add_argument(
        "--service-name",
        default="particle-engine-tests",
        help="OTEL service.name resource attribute",
    )
    return parser


def _safe_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _normalize_tag_attrs(tags: dict[str, Any]) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for key, raw_value in tags.items():
        k = str(key).strip()
        if not k:
            continue
        # Keep label cardinality bounded for stable Grafana dashboards.
        if len(attrs) >= 8:
            break
        attrs[f"tag_{k[:40]}"] = str(raw_value)[:80]
    return attrs


def _iter_scenario_metric_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[float, dict[str, Any]]]:
    for scenario in run.get("scenarios", []):
        tags = scenario.get("tags", {})
        tag_attrs = _normalize_tag_attrs(tags if isinstance(tags, dict) else {})
        for key, value in scenario.get("metrics", {}).items():
            numeric = _safe_float(value)
            if numeric is None:
                continue
            attrs = {
                **base_attrs,
                "suite": scenario.get("suite", "unknown"),
                "scenario": scenario.get("scenario", "unknown"),
                "metric_key": key,
                **tag_attrs,
            }
            yield numeric, attrs


def _iter_visual_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[float, float, bool, dict[str, Any]]]:
    for artifact in run.get("visual_artifacts", []):
        diff_ratio = _safe_float(artifact.get("diff_ratio", 1.0))
        ssim = _safe_float(artifact.get("ssim", 0.0))
        if diff_ratio is None or ssim is None:
            continue
        attrs = {
            **base_attrs,
            "scenario": str(artifact.get("scenario", "unknown")),
        }
        yield diff_ratio, ssim, not bool(artifact.get("pass", False)), attrs


def _iter_placement_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[str, float, dict[str, Any]]]:
    placement_keys = {
        "placement_stamps_total",
        "placement_cells_modified_total",
        "placement_cells_painted_total",
        "placement_cells_erased_total",
        "placement_line_segments_total",
        "placement_line_points_total",
        "placement_noop_stamps_total",
        "placement_cells_per_stamp",
    }
    for scenario in run.get("scenarios", []):
        tags = scenario.get("tags", {})
        scenario_tags = tags if isinstance(tags, dict) else {}
        tag_attrs = {
            "device_class": str(scenario_tags.get("device_class", "desktop"))[:20],
            "interaction": str(scenario_tags.get("interaction", "unknown"))[:24],
        }
        for key, value in scenario.get("metrics", {}).items():
            if key not in placement_keys:
                continue
            numeric = _safe_float(value)
            if numeric is None:
                continue
            attrs = {
                **base_attrs,
                "suite": scenario.get("suite", "unknown"),
                "scenario": scenario.get("scenario", "unknown"),
                **tag_attrs,
            }
            yield key, numeric, attrs


def _iter_physics_phase_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[float, dict[str, Any]]]:
    snapshot = run.get("physics_runtime_snapshot", {})
    if not isinstance(snapshot, dict):
        return
    for sample in snapshot.get("phase_samples", []):
        if not isinstance(sample, dict):
            continue
        duration_ms = _safe_float(sample.get("duration_ms"))
        if duration_ms is None:
            continue
        attrs = {
            **base_attrs,
            "phase": str(sample.get("key", "unknown"))[:40],
            "group": str(sample.get("group", "unknown"))[:40],
        }
        yield duration_ms, attrs


def _iter_worldgen_stage_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[float, dict[str, Any]]]:
    summary = run.get("worldgen_stage_summary", {})
    if not isinstance(summary, dict):
        return
    preset = str(summary.get("preset", "unknown"))[:24]
    for stage in summary.get("stages", []):
        if not isinstance(stage, dict):
            continue
        duration_ms = _safe_float(stage.get("duration_ms"))
        if duration_ms is None:
            continue
        attrs = {
            **base_attrs,
            "preset": preset,
            "stage_name": str(stage.get("stage_name", "unknown"))[:40],
        }
        yield duration_ms, attrs


def _iter_render_points(
    run: dict[str, Any], base_attrs: dict[str, Any]
) -> Iterable[tuple[str, float, dict[str, Any]]]:
    snapshot = run.get("render_runtime_snapshot", {})
    if not isinstance(snapshot, dict):
        return
    attrs = {
        **base_attrs,
        "device_class": str(snapshot.get("device_class", "desktop"))[:20],
        "interaction": str(snapshot.get("interaction", "unknown"))[:24],
    }
    for key in (
        "render_pixel_passes",
        "image_build_passes",
        "post_process_passes",
        "render_skipped_frames",
        "wrap_copies_last_frame",
        "frame_budget_skips",
    ):
        numeric = _safe_float(snapshot.get(key))
        if numeric is None:
            continue
        yield key, numeric, attrs


def _extract_optuna_attrs(run: dict[str, Any]) -> dict[str, str]:
    metadata = run.get("optuna", {})
    if not isinstance(metadata, dict):
        return {}
    attrs: dict[str, str] = {}
    profile = metadata.get("profile")
    if profile not in (None, ""):
        attrs["optuna_profile"] = str(profile)[:24]
    source_label = metadata.get("source_label")
    if source_label not in (None, ""):
        attrs["optuna_source"] = str(source_label)[:32]
    execution_mode = metadata.get("execution_mode")
    if execution_mode not in (None, ""):
        attrs["optuna_execution_mode"] = str(execution_mode)[:24]
    return attrs


def main() -> int:
    args = _build_parser().parse_args()
    run = _load_run(Path(args.run_json))

    try:
        from opentelemetry import metrics
        from opentelemetry.exporter.otlp.proto.http.metric_exporter import (
            OTLPMetricExporter,
        )
        from opentelemetry.sdk.metrics import MeterProvider
        from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
        from opentelemetry.sdk.resources import Resource
    except ImportError as exc:
        raise SystemExit(
            "Missing OTEL packages. Run: pip install opentelemetry-sdk "
            "opentelemetry-exporter-otlp"
        ) from exc

    resource = Resource.create(
        {
            "service.name": args.service_name,
            "service.namespace": "the-particle-engine",
        }
    )
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(), export_interval_millis=1000
    )
    provider = MeterProvider(metric_readers=[reader], resource=resource)
    metrics.set_meter_provider(provider)
    meter = metrics.get_meter("particle-engine.performance")

    total_tests = meter.create_counter(
        "particle_engine_tests_total",
        unit="{tests}",
        description="Number of tests in the run",
    )
    failed_tests = meter.create_counter(
        "particle_engine_tests_failed",
        unit="{tests}",
        description="Number of failed tests in the run",
    )
    failed_targets = meter.create_counter(
        "particle_engine_targets_failed_total",
        unit="{targets}",
        description="Number of failed test targets in the run",
    )
    timed_out_targets = meter.create_counter(
        "particle_engine_targets_timed_out_total",
        unit="{targets}",
        description="Number of timed out test targets in the run",
    )
    duration_ms_hist = meter.create_histogram(
        "particle_engine_test_duration_ms",
        unit="ms",
        description="Per-test duration distribution",
    )
    scenario_metric_value = meter.create_counter(
        "particle_engine_scenario_metric_value",
        description="Scenario metric values emitted by perf tests",
    )
    visual_diff_ratio = meter.create_histogram(
        "particle_engine_visual_diff_ratio",
        description="Visual regression diff ratio (lower is better)",
    )
    visual_ssim = meter.create_histogram(
        "particle_engine_visual_ssim",
        description="Visual regression SSIM (higher is better)",
    )
    visual_failed = meter.create_counter(
        "particle_engine_visual_failed_total",
        unit="{cases}",
        description="Number of visual regression cases that failed",
    )
    telemetry_complete = meter.create_counter(
        "particle_engine_telemetry_complete_total",
        unit="{runs}",
        description="1 when required telemetry suites were complete for a run",
    )
    quality_score = meter.create_histogram(
        "particle_engine_quality_score",
        description="Front-to-back quality score (0-100)",
    )
    quality_component_score = meter.create_histogram(
        "particle_engine_quality_component_score",
        description="Per-component quality score (0-100)",
    )
    quality_gate_failed = meter.create_counter(
        "particle_engine_quality_gate_failed_total",
        unit="{runs}",
        description="Count of runs where quality gate failed",
    )
    quality_grade_total = meter.create_counter(
        "particle_engine_quality_grade_total",
        unit="{runs}",
        description="Count of quality grades by profile",
    )
    creature_population = meter.create_histogram(
        "particle_engine_creature_population",
        unit="{creatures}",
        description="Creature population samples from runtime snapshots",
    )
    creature_spawn_success_ratio = meter.create_histogram(
        "particle_engine_creature_spawn_success_ratio",
        description="Creature spawn success ratio",
    )
    creature_tick_duration_ms = meter.create_histogram(
        "particle_engine_creature_tick_duration_ms",
        unit="ms",
        description="Creature tick duration distribution",
    )
    creature_render_duration_ms = meter.create_histogram(
        "particle_engine_creature_render_duration_ms",
        unit="ms",
        description="Creature render duration distribution",
    )
    creature_visibility_failures_total = meter.create_counter(
        "particle_engine_creature_visibility_failures_total",
        unit="{failures}",
        description="Total runtime visibility failures for creatures",
    )
    creature_queen_alive_ratio = meter.create_histogram(
        "particle_engine_creature_queen_alive_ratio",
        description="Queen alive ratio for colony runtime snapshots",
    )
    placement_stamps_total = meter.create_counter(
        "particle_engine_placement_stamps_total",
        unit="{stamps}",
        description="Total placement stamp calls across scenarios",
    )
    placement_cells_modified_total = meter.create_counter(
        "particle_engine_placement_cells_modified_total",
        unit="{cells}",
        description="Total grid cells modified by placement",
    )
    placement_cells_painted_total = meter.create_counter(
        "particle_engine_placement_cells_painted_total",
        unit="{cells}",
        description="Total grid cells painted by element placement",
    )
    placement_cells_erased_total = meter.create_counter(
        "particle_engine_placement_cells_erased_total",
        unit="{cells}",
        description="Total grid cells erased by element placement",
    )
    placement_line_segments_total = meter.create_counter(
        "particle_engine_placement_line_segments_total",
        unit="{segments}",
        description="Interpolated drag line segment count",
    )
    placement_line_points_total = meter.create_counter(
        "particle_engine_placement_line_points_total",
        unit="{points}",
        description="Interpolated line point count during placement",
    )
    placement_noop_stamps_total = meter.create_counter(
        "particle_engine_placement_noop_stamps_total",
        unit="{stamps}",
        description="Placement stamps that produced no grid modifications",
    )
    placement_cells_per_stamp = meter.create_histogram(
        "particle_engine_placement_cells_per_stamp",
        unit="{cells}",
        description="Distribution of modified cells per placement stamp",
    )
    physics_phase_duration_ms = meter.create_histogram(
        "particle_engine_physics_phase_duration_ms",
        unit="ms",
        description="Physics phase duration distribution",
    )
    dirty_chunk_efficiency = meter.create_histogram(
        "particle_engine_dirty_chunk_efficiency",
        description="Dirty chunk amplification ratio per run",
    )
    worldgen_stage_duration_ms = meter.create_histogram(
        "particle_engine_worldgen_stage_duration_ms",
        unit="ms",
        description="World generation stage duration distribution",
    )
    render_pixel_passes = meter.create_histogram(
        "particle_engine_render_pixel_passes",
        description="Pixel render pass count captured from runtime snapshots",
    )
    image_build_passes = meter.create_histogram(
        "particle_engine_render_image_build_passes",
        description="Image build pass count captured from runtime snapshots",
    )
    post_process_passes = meter.create_histogram(
        "particle_engine_render_post_process_passes",
        description="Post-process pass count captured from runtime snapshots",
    )
    render_skipped_frames = meter.create_histogram(
        "particle_engine_render_skipped_frames",
        description="Skipped frame count captured from runtime snapshots",
    )
    wrap_copies_last_frame = meter.create_histogram(
        "particle_engine_render_wrap_copies_last_frame",
        description="Rendered wrap-copy count from the last rendered frame",
    )
    frame_budget_skips = meter.create_histogram(
        "particle_engine_render_frame_budget_skips",
        description="Deferred image-build skips due to frame budget pressure",
    )
    determinism_mismatch_total = meter.create_counter(
        "particle_engine_determinism_mismatch_total",
        unit="{runs}",
        description="Count of runs with determinism mismatch indicators",
    )

    base_attrs = {
        "run_id": run["run_id"],
        "git_sha": run.get("git_sha") or "unknown",
        "git_branch": run.get("git_branch") or "unknown",
        "profile": run.get("profile") or "pr",
        "soak_level": run.get("soak_level") or "quick",
        **_extract_optuna_attrs(run),
    }

    summary = run["summary"]
    telemetry_complete_flag = bool(summary.get("telemetry_complete", False))
    total_tests.add(summary["total_tests"], attributes=base_attrs)
    failed_tests.add(summary["failed_tests"], attributes=base_attrs)
    failed_targets.add(summary.get("failed_targets", 0), attributes=base_attrs)
    timed_out_targets.add(summary.get("timed_out_targets", 0), attributes=base_attrs)
    telemetry_complete.add(
        1,
        attributes={
            **base_attrs,
            "telemetry_complete": "true" if telemetry_complete_flag else "false",
        },
    )
    quality_total = _safe_float(summary.get("quality_score_total"))
    if quality_total is not None:
        quality_score.record(
            quality_total,
            attributes={
                **base_attrs,
                "quality_grade": str(summary.get("quality_grade", "F")),
            },
        )
    if bool(summary.get("quality_gate_failed", False)):
        quality_gate_failed.add(
            1,
            attributes={
                **base_attrs,
                "reason": str(summary.get("quality_gate_reason", "unknown"))[:80],
            },
        )
    quality_grade_total.add(
        1,
        attributes={
            **base_attrs,
            "grade": str(summary.get("quality_grade", "F")),
        },
    )
    creature_snapshot = run.get("creature_runtime_snapshot", {})
    if isinstance(creature_snapshot, dict):
        creature_attrs = {
            **base_attrs,
            "species": str(creature_snapshot.get("species", "ant"))[:20],
            "device_class": str(creature_snapshot.get("device_class", "desktop"))[:20],
        }
        pop_alive = _safe_float(creature_snapshot.get("creature_population_alive"))
        if pop_alive is not None:
            creature_population.record(pop_alive, attributes=creature_attrs)
        spawn_ratio = _safe_float(creature_snapshot.get("creature_spawn_success_rate"))
        if spawn_ratio is not None:
            creature_spawn_success_ratio.record(spawn_ratio, attributes=creature_attrs)
        tick_p50 = _safe_float(creature_snapshot.get("creature_tick_ms_p50"))
        tick_p95 = _safe_float(creature_snapshot.get("creature_tick_ms_p95"))
        if tick_p50 is not None:
            creature_tick_duration_ms.record(tick_p50, attributes={**creature_attrs, "percentile": "p50"})
        if tick_p95 is not None:
            creature_tick_duration_ms.record(tick_p95, attributes={**creature_attrs, "percentile": "p95"})
        render_p50 = _safe_float(creature_snapshot.get("creature_render_ms_p50"))
        render_p95 = _safe_float(creature_snapshot.get("creature_render_ms_p95"))
        if render_p50 is not None:
            creature_render_duration_ms.record(render_p50, attributes={**creature_attrs, "percentile": "p50"})
        if render_p95 is not None:
            creature_render_duration_ms.record(render_p95, attributes={**creature_attrs, "percentile": "p95"})
        visibility_failures = _safe_float(creature_snapshot.get("creature_visibility_failures"))
        if visibility_failures is not None and visibility_failures > 0:
            creature_visibility_failures_total.add(int(visibility_failures), attributes=creature_attrs)
        queen_ratio = _safe_float(creature_snapshot.get("creature_queen_alive_ratio"))
        if queen_ratio is not None:
            creature_queen_alive_ratio.record(queen_ratio, attributes=creature_attrs)

    for component in run.get("quality_components", []):
        if not isinstance(component, dict):
            continue
        score_val = _safe_float(component.get("score"))
        if score_val is None:
            continue
        quality_component_score.record(
            score_val,
            attributes={
                **base_attrs,
                "component": str(component.get("component_key", "unknown")),
                "status": str(component.get("status", "unknown")),
            },
        )

    for case in run.get("test_cases", []):
        duration_ms = _safe_float(case.get("duration_ms", 0.0))
        if duration_ms is None:
            continue
        attrs = {
            **base_attrs,
            "target": case.get("target", "unknown"),
            "outcome": case.get("outcome", "unknown"),
        }
        duration_ms_hist.record(duration_ms, attributes=attrs)

    for metric_value, attrs in _iter_scenario_metric_points(run, base_attrs):
        scenario_metric_value.add(metric_value, attributes=attrs)

    for diff_ratio, ssim, failed_case, attrs in _iter_visual_points(run, base_attrs):
        visual_diff_ratio.record(diff_ratio, attributes=attrs)
        visual_ssim.record(ssim, attributes=attrs)
        if failed_case:
            visual_failed.add(1, attributes=attrs)

    for metric_key, metric_value, attrs in _iter_placement_points(run, base_attrs):
        if metric_key == "placement_stamps_total":
            placement_stamps_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_cells_modified_total":
            placement_cells_modified_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_cells_painted_total":
            placement_cells_painted_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_cells_erased_total":
            placement_cells_erased_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_line_segments_total":
            placement_line_segments_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_line_points_total":
            placement_line_points_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_noop_stamps_total":
            placement_noop_stamps_total.add(int(metric_value), attributes=attrs)
        elif metric_key == "placement_cells_per_stamp":
            placement_cells_per_stamp.record(metric_value, attributes=attrs)

    for duration_ms, attrs in _iter_physics_phase_points(run, base_attrs):
        physics_phase_duration_ms.record(duration_ms, attributes=attrs)

    physics_snapshot = run.get("physics_runtime_snapshot", {})
    if isinstance(physics_snapshot, dict):
        amplification = _safe_float(physics_snapshot.get("dirty_chunk_amplification_ratio"))
        if amplification is not None:
            dirty_chunk_efficiency.record(amplification, attributes=base_attrs)
        if amplification is not None and amplification > 2.5:
            determinism_mismatch_total.add(
                1,
                attributes={**base_attrs, "reason": "dirty_chunk_amplification_outlier"},
            )

    for duration_ms, attrs in _iter_worldgen_stage_points(run, base_attrs):
        worldgen_stage_duration_ms.record(duration_ms, attributes=attrs)

    for metric_key, metric_value, attrs in _iter_render_points(run, base_attrs):
        if metric_key == "render_pixel_passes":
            render_pixel_passes.record(metric_value, attributes=attrs)
        elif metric_key == "image_build_passes":
            image_build_passes.record(metric_value, attributes=attrs)
        elif metric_key == "post_process_passes":
            post_process_passes.record(metric_value, attributes=attrs)
        elif metric_key == "render_skipped_frames":
            render_skipped_frames.record(metric_value, attributes=attrs)
        elif metric_key == "wrap_copies_last_frame":
            wrap_copies_last_frame.record(metric_value, attributes=attrs)
        elif metric_key == "frame_budget_skips":
            frame_budget_skips.record(metric_value, attributes=attrs)

    provider.force_flush()
    provider.shutdown()
    print(f"Exported OTLP metrics for run {run['run_id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
