from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tool" / "performance"))

import pipeline  # type: ignore  # noqa: E402


class PipelineContractTests(unittest.TestCase):
    def test_profile_defaults_have_required_keys(self) -> None:
        for profile in ("pr", "nightly", "investigative"):
            defaults = pipeline.PROFILE_DEFAULTS[profile]
            self.assertIn("include_soak", defaults)
            self.assertIn("soak_level", defaults)
            self.assertIn("timeout_seconds", defaults)
            self.assertIn("required_suites", defaults)
            self.assertIn("atmospherics", defaults["required_suites"])

    def test_telemetry_completeness_detects_missing_suite(self) -> None:
        scenarios = [
            {"suite": "game_loop", "metrics": {"mean_ms": 10}},
            {"suite": "physics_integrity", "metrics": {"max_lava_cells": 100}},
        ]
        ok, missing = pipeline._assess_telemetry_completeness(  # noqa: SLF001
            scenarios,
            {"game_loop", "physics_integrity", "engine_soak"},
        )
        self.assertFalse(ok)
        self.assertEqual(missing, ["engine_soak"])

    def test_telemetry_completeness_accepts_all_suites_present(self) -> None:
        scenarios = [
            {"suite": "game_loop", "metrics": {"mean_ms": 10}},
            {"suite": "physics_integrity", "metrics": {"hydro_abs_delta_total": 5}},
            {"suite": "engine_soak", "metrics": {"steps": 180}},
        ]
        ok, missing = pipeline._assess_telemetry_completeness(  # noqa: SLF001
            scenarios,
            {"game_loop", "physics_integrity", "engine_soak"},
        )
        self.assertTrue(ok)
        self.assertEqual(missing, [])

    def test_pr_profile_target_selection_is_bounded(self) -> None:
        targets = pipeline._build_targets("pr", include_soak=False, soak_level="quick")  # noqa: SLF001
        self.assertEqual(len(targets), 6)
        self.assertEqual(targets[0].suite, "game_loop")
        self.assertEqual(
            targets[0].path,
            "test/performance/game_loop/game_loop_smoke_performance_test.dart",
        )
        self.assertEqual(targets[1].suite, "physics_integrity")
        self.assertEqual(targets[2].suite, "physics_integrity")
        self.assertEqual(targets[3].suite, "physics_integrity")
        self.assertEqual(targets[4].suite, "atmospherics")
        self.assertEqual(targets[5].suite, "physics_integrity")

    def test_nightly_profile_includes_soak(self) -> None:
        targets = pipeline._build_targets("nightly", include_soak=True, soak_level="nightly")  # noqa: SLF001
        suites = [t.suite for t in targets]
        self.assertIn("engine_soak", suites)
        self.assertIn("physics_fuzz", suites)
        self.assertIn("visual_regression", suites)

    def test_parser_supports_visual_artifact_flags(self) -> None:
        parser = pipeline._build_parser()  # noqa: SLF001
        parsed = parser.parse_args(
            [
                "--profile",
                "pr",
                "--emit-visual-artifacts",
                "--artifact-root",
                "build/perf/visual",
                "--warn-then-gate",
                "--baseline-min-samples",
                "12",
                "--max-failed-visual-cases",
                "2",
            ]
        )
        self.assertTrue(parsed.emit_visual_artifacts)
        self.assertEqual(parsed.artifact_root, "build/perf/visual")
        self.assertTrue(parsed.warn_then_gate)
        self.assertEqual(parsed.baseline_min_samples, 12)
        self.assertEqual(parsed.max_failed_visual_cases, 2)

    def test_load_visual_artifacts_parses_jsonl(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "visual.jsonl"
            row = {
                "run_id": "r1",
                "scenario": "cloud",
                "frame": 120,
                "image_path": "a.ppm",
                "diff_path": "d.ppm",
                "ssim": 0.99,
                "psnr": 41.2,
                "diff_ratio": 0.01,
                "pass": True,
            }
            p.write_text(f"{json.dumps(row)}\n", encoding="utf-8")
            artifacts = pipeline._load_visual_artifacts(p)  # noqa: SLF001
            self.assertEqual(len(artifacts), 1)
            self.assertEqual(artifacts[0].scenario, "cloud")
            self.assertTrue(artifacts[0].passed)

    def test_percentile_interpolates(self) -> None:
        vals = [10.0, 20.0, 30.0, 40.0]
        p50 = pipeline._percentile(vals, 0.5)  # noqa: SLF001
        p95 = pipeline._percentile(vals, 0.95)  # noqa: SLF001
        self.assertAlmostEqual(p50, 25.0)
        self.assertGreater(p95, 35.0)

    def test_load_duration_baseline_reads_profile_runs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "perf.sqlite"
            con = sqlite3.connect(db)
            con.execute(
                """
                CREATE TABLE perf_runs (
                  run_id TEXT PRIMARY KEY,
                  timestamp_utc TEXT,
                  profile TEXT,
                  duration_ms REAL
                )
                """
            )
            con.execute(
                "INSERT INTO perf_runs(run_id,timestamp_utc,profile,duration_ms) VALUES('a','2026-01-01T00:00:00Z','pr',1000)"
            )
            con.execute(
                "INSERT INTO perf_runs(run_id,timestamp_utc,profile,duration_ms) VALUES('b','2026-01-02T00:00:00Z','pr',1200)"
            )
            con.execute(
                "INSERT INTO perf_runs(run_id,timestamp_utc,profile,duration_ms) VALUES('c','2026-01-03T00:00:00Z','nightly',3000)"
            )
            con.commit()
            con.close()

            baseline = pipeline._load_duration_baseline(db, "pr", "z", limit=10)  # noqa: SLF001
            self.assertEqual(baseline["sample_size"], 2)
            self.assertGreater(baseline["median_duration_ms"], 1000.0)

    def test_evaluate_baseline_gate(self) -> None:
        baseline = {
            "sample_size": 10,
            "median_duration_ms": 1000.0,
            "p95_duration_ms": 1200.0,
        }
        active, warning = pipeline._evaluate_baseline_gate(  # noqa: SLF001
            baseline,
            current_duration_ms=1400.0,
            min_samples=8,
            max_delta_pct=20.0,
            max_p95_multiplier=1.10,
        )
        self.assertTrue(active)
        self.assertTrue(warning)
        self.assertGreater(baseline["delta_vs_median_pct"], 20.0)

    def test_evaluate_visual_gate(self) -> None:
        active, failed = pipeline._evaluate_visual_gate(  # noqa: SLF001
            failed_visual_cases=3,
            max_failed_visual_cases=2,
        )
        self.assertTrue(active)
        self.assertTrue(failed)

    def test_build_comparison_with_previous_run(self) -> None:
        current = {
            "run_id": "new",
            "summary": {
                "duration_ms": 1800.0,
                "failed_tests": 2,
            },
        }
        previous = {
            "run_id": "old",
            "duration_ms": 1500.0,
            "failed_tests": 1,
        }
        comparison = pipeline._build_comparison(current, previous)  # noqa: SLF001
        self.assertEqual(comparison["previous_run_id"], "old")
        self.assertEqual(comparison["delta_duration_ms"], 300.0)
        self.assertEqual(comparison["delta_failed_tests"], 1)


if __name__ == "__main__":
    unittest.main()
