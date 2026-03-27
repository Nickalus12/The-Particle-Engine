from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tool" / "performance"))

from storage import SQLitePerfStore  # type: ignore  # noqa: E402


def _sample_run() -> dict:
    return {
        "schema_version": 2,
        "run_id": "run_1",
        "timestamp_utc": "2026-03-27T00:00:00Z",
        "git_sha": "abc",
        "git_branch": "main",
        "host": "host",
        "platform": "platform",
        "profile": "pr",
        "soak_level": "quick",
        "summary": {
            "total_tests": 3,
            "failed_tests": 1,
            "failed_cases": 0,
            "failed_targets": 1,
            "timed_out_targets": 1,
            "telemetry_complete": False,
            "total_visual_cases": 2,
            "failed_visual_cases": 1,
            "duration_ms": 1234.5,
        },
        "test_cases": [
            {
                "target": "test/performance/simulation/physics_integrity_test.dart",
                "name": "water mass stays bounded",
                "outcome": "passed",
                "duration_ms": 44.5,
            }
        ],
        "scenarios": [
            {
                "suite": "physics_integrity",
                "scenario": "water_balance",
                "metrics": {"hydro_abs_delta_total": 4.0, "condensation_events": 2},
                "tags": {"seed": 42},
            }
        ],
        "visual_artifacts": [
            {
                "run_id": "run_1",
                "scenario": "cloud",
                "frame": 120,
                "image_path": "a.ppm",
                "diff_path": "d.ppm",
                "ssim": 0.99,
                "psnr": 40.2,
                "diff_ratio": 0.01,
                "pass": True,
            }
        ],
    }


class StorageContractTests(unittest.TestCase):
    def test_sqlite_schema_contains_required_columns(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "perf.sqlite"
            store = SQLitePerfStore(db)
            store.insert_run(_sample_run())
            store.close()

            conn = sqlite3.connect(db)
            cols = conn.execute("PRAGMA table_info(perf_runs)").fetchall()
            names = {row[1] for row in cols}
            required = {
                "schema_version",
                "profile",
                "failed_cases",
                "failed_targets",
                "timed_out_targets",
                "telemetry_complete",
                "total_visual_cases",
                "failed_visual_cases",
            }
            self.assertTrue(required.issubset(names))

            vcols = conn.execute("PRAGMA table_info(perf_visual_artifacts)").fetchall()
            vnames = {row[1] for row in vcols}
            self.assertIn("image_path", vnames)
            self.assertIn("ssim", vnames)
            case_count = conn.execute("SELECT COUNT(*) FROM perf_test_cases").fetchone()[0]
            scenario_count = conn.execute("SELECT COUNT(*) FROM perf_scenarios").fetchone()[0]
            visual_count = conn.execute("SELECT COUNT(*) FROM perf_visual_artifacts").fetchone()[0]
            self.assertEqual(case_count, 1)
            self.assertEqual(scenario_count, 2)
            self.assertEqual(visual_count, 1)
            conn.close()

    def test_get_previous_run_returns_latest_non_current(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "perf.sqlite"
            store = SQLitePerfStore(db)
            first = _sample_run()
            second = _sample_run() | {
                "run_id": "run_2",
                "timestamp_utc": "2026-03-27T00:01:00Z",
            }
            store.insert_run(first)
            store.insert_run(second)
            previous = store.get_previous_run("run_2")
            store.close()

            self.assertIsNotNone(previous)
            assert previous is not None
            self.assertEqual(previous["run_id"], "run_1")


if __name__ == "__main__":
    unittest.main()
