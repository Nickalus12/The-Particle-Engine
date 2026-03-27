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

    base_attrs = {
        "run_id": run["run_id"],
        "git_sha": run.get("git_sha") or "unknown",
        "git_branch": run.get("git_branch") or "unknown",
        "profile": run.get("profile") or "pr",
        "soak_level": run.get("soak_level") or "quick",
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

    provider.force_flush()
    provider.shutdown()
    print(f"Exported OTLP metrics for run {run['run_id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
