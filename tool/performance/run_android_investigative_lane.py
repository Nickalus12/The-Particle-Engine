"""Run investigative pipeline plus Android runtime smoke validation."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "tool" / "performance" / "run_performance_pipeline.py"
ANDROID_RUNTIME_TARGETS = (
    "test/smoke/ant_placement_regression_test.dart",
    "test/unit/simulation/ant_gravity_regression_test.dart",
)


@dataclass
class AndroidTargetResult:
    target: str
    return_code: int
    timed_out: bool
    elapsed_ms: float
    test_count: int
    failed_count: int


def _log(message: str) -> None:
    print(f"[{datetime.now(tz=UTC).isoformat()}] {message}")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run investigative perf pipeline and Android runtime smoke tests."
    )
    parser.add_argument("--device-id", default="", help="ADB device serial (optional).")
    parser.add_argument(
        "--target-timeout-seconds",
        type=int,
        default=180,
        help="Timeout for each command target in seconds.",
    )
    parser.add_argument(
        "--artifact-dir",
        default="",
        help="Optional existing run artifact directory. Defaults to pipeline-created run dir.",
    )
    parser.add_argument(
        "--export-otlp",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Export pipeline metrics to OTLP.",
    )
    parser.add_argument(
        "--require-telemetry-complete",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Fail pipeline when required telemetry suites are missing.",
    )
    return parser


def _resolve_adb_device(preferred: str) -> str:
    adb = shutil.which("adb")
    if adb is None:
        raise RuntimeError("adb not found in PATH.")
    proc = subprocess.run(
        [adb, "devices"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"adb devices failed: {proc.stderr.strip()}")
    devices: list[str] = []
    for line in proc.stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = re.split(r"\s+", line)
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(parts[0])
    if preferred:
        if preferred not in devices:
            raise RuntimeError(f"Requested device '{preferred}' is not connected: {devices}")
        return preferred
    if not devices:
        raise RuntimeError("No online adb devices found.")
    return devices[0]


def _run_cmd(
    cmd: list[str],
    *,
    timeout_seconds: int,
    log_path: Path,
    env: dict[str, str] | None = None,
) -> tuple[int, str]:
    _log(f"START {' '.join(cmd)} timeout={timeout_seconds}s")
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )
    try:
        stdout, _ = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                capture_output=True,
                text=True,
                check=False,
            )
        else:
            proc.kill()
        stdout, _ = proc.communicate(timeout=5)
        log_path.write_text(stdout or "", encoding="utf-8")
        _log("TIMEOUT")
        return 124, stdout or ""
    output = stdout or ""
    log_path.write_text(output, encoding="utf-8")
    _log(f"END return_code={proc.returncode}")
    return proc.returncode or 0, output


def _find_artifact_dir(pipeline_output: str, explicit: str) -> Path:
    if explicit:
        return Path(explicit)
    for line in pipeline_output.splitlines():
        if line.startswith("artifact_dir="):
            return Path(line.split("=", 1)[1].strip())
    raise RuntimeError("Unable to resolve artifact_dir from pipeline output.")


def _parse_machine_test_events(machine_output: str) -> tuple[int, int]:
    total = 0
    failed = 0
    for line in machine_output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") != "testDone":
            continue
        if bool(event.get("hidden", False)):
            continue
        total += 1
        if event.get("result") != "success":
            failed += 1
    return total, failed


def _run_android_target(target: str, *, device_id: str, timeout_seconds: int, artifact_dir: Path) -> AndroidTargetResult:
    log_stem = Path(target).stem
    machine_log = artifact_dir / f"android_{log_stem}.machine.jsonl"
    cmd = [
        "flutter",
        "test",
        "--machine",
        "--no-pub",
        "-d",
        device_id,
        target,
    ]
    started = time.perf_counter()
    rc, out = _run_cmd(cmd, timeout_seconds=timeout_seconds, log_path=machine_log)
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    timed_out = rc == 124
    test_count, failed_count = _parse_machine_test_events(out)
    return AndroidTargetResult(
        target=target,
        return_code=rc,
        timed_out=timed_out,
        elapsed_ms=elapsed_ms,
        test_count=test_count,
        failed_count=failed_count,
    )


def _append_metrics_to_run_json(run_json: Path, target_results: list[AndroidTargetResult]) -> None:
    if not run_json.exists() or not target_results:
        return
    payload = json.loads(run_json.read_text(encoding="utf-8"))
    scenarios = payload.get("scenarios", [])
    if not isinstance(scenarios, list):
        scenarios = []
    now = datetime.now(tz=UTC).isoformat()
    for result in target_results:
        scenarios.append(
            {
                "timestamp_utc": now,
                "suite": "runtime_smoke_android",
                "scenario": Path(result.target).stem,
                "metrics": {
                    "tests_total": result.test_count,
                    "tests_failed": result.failed_count,
                    "duration_ms": round(result.elapsed_ms, 3),
                    "timed_out": 1 if result.timed_out else 0,
                    "return_code": result.return_code,
                },
                "tags": {"target": "android_runtime"},
            }
        )
    payload["scenarios"] = scenarios
    run_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def main() -> int:
    args = _build_parser().parse_args()
    device_id = _resolve_adb_device(args.device_id)
    _log(f"Using device={device_id}")

    pipeline_cmd = [
        sys.executable,
        str(PIPELINE),
        "--profile",
        "investigative",
        "--target-timeout-seconds",
        str(max(30, args.target_timeout_seconds)),
    ]
    if args.require_telemetry_complete:
        pipeline_cmd.append("--require-telemetry-complete")
    else:
        pipeline_cmd.append("--no-require-telemetry-complete")
    if args.export_otlp:
        pipeline_cmd.append("--export-otlp")
    if args.artifact_dir:
        pipeline_cmd.extend(["--artifact-dir", args.artifact_dir])

    lane_tmp = ROOT / "reports" / "performance" / "android_lane"
    lane_tmp.mkdir(parents=True, exist_ok=True)
    pipeline_log = lane_tmp / "pipeline.log"
    pipeline_rc, pipeline_out = _run_cmd(
        pipeline_cmd,
        timeout_seconds=max(60, args.target_timeout_seconds * 2),
        log_path=pipeline_log,
    )
    artifact_dir = _find_artifact_dir(pipeline_out, args.artifact_dir)
    artifact_dir.mkdir(parents=True, exist_ok=True)

    android_results: list[AndroidTargetResult] = []
    android_rc = 0
    for target in ANDROID_RUNTIME_TARGETS:
        result = _run_android_target(
            target,
            device_id=device_id,
            timeout_seconds=max(30, args.target_timeout_seconds),
            artifact_dir=artifact_dir,
        )
        android_results.append(result)
        if result.return_code != 0 and android_rc == 0:
            android_rc = result.return_code

    metrics_jsonl = artifact_dir / "android_runtime_metrics.jsonl"
    with metrics_jsonl.open("w", encoding="utf-8") as fh:
        for result in android_results:
            row = {
                "run_id": f"android_{uuid.uuid4().hex[:8]}",
                "suite": "runtime_smoke_android",
                "scenario": Path(result.target).stem,
                "metrics": {
                    "tests_total": result.test_count,
                    "tests_failed": result.failed_count,
                    "duration_ms": round(result.elapsed_ms, 3),
                    "timed_out": 1 if result.timed_out else 0,
                    "return_code": result.return_code,
                },
                "tags": {"target": result.target, "device_id": device_id},
            }
            fh.write(f"{json.dumps(row, sort_keys=True)}\n")
    _append_metrics_to_run_json(artifact_dir / "run.json", android_results)

    summary = {
        "device_id": device_id,
        "pipeline_return_code": pipeline_rc,
        "android_runtime_return_code": android_rc,
        "targets": [
            {
                "target": result.target,
                "return_code": result.return_code,
                "timed_out": result.timed_out,
                "duration_ms": round(result.elapsed_ms, 3),
                "tests_total": result.test_count,
                "tests_failed": result.failed_count,
            }
            for result in android_results
        ],
        "metric_count": len(android_results),
        "artifact_dir": str(artifact_dir),
        "timestamp_utc": datetime.now(tz=UTC).isoformat(),
    }
    summary_path = artifact_dir / "android_lane_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    _log(f"summary_path={summary_path}")

    if pipeline_rc != 0 or android_rc != 0:
        return pipeline_rc or android_rc or 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
