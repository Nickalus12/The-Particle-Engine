from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tool" / "performance"))

import run_quality_pipeline as quality  # type: ignore  # noqa: E402


class QualityPipelineContractTests(unittest.TestCase):
    def test_grade_mapping(self) -> None:
        self.assertEqual(quality._grade(95.0), "A")  # noqa: SLF001
        self.assertEqual(quality._grade(85.0), "B")  # noqa: SLF001
        self.assertEqual(quality._grade(75.0), "C")  # noqa: SLF001
        self.assertEqual(quality._grade(65.0), "D")  # noqa: SLF001
        self.assertEqual(quality._grade(50.0), "F")  # noqa: SLF001

    def test_gate_respects_pr_warmup(self) -> None:
        decision = quality._decide_gate(  # noqa: SLF001
            profile="pr",
            quality_score_total=60.0,
            telemetry_complete=True,
            timed_out_targets=0,
            mobile_hard_fail=False,
            creature_contract_failed=False,
            gate_start_date=datetime.now(tz=UTC),
            warmup_days=14,
            enforce_investigative_gate=False,
        )
        self.assertFalse(decision.failed)
        self.assertIn("warmup_override", decision.reason)

    def test_gate_hard_fails_on_telemetry_after_warmup(self) -> None:
        decision = quality._decide_gate(  # noqa: SLF001
            profile="pr",
            quality_score_total=95.0,
            telemetry_complete=False,
            timed_out_targets=0,
            mobile_hard_fail=False,
            creature_contract_failed=False,
            gate_start_date=datetime(2026, 1, 1, tzinfo=UTC),
            warmup_days=0,
            enforce_investigative_gate=False,
        )
        self.assertTrue(decision.failed)
        self.assertIn("telemetry_incomplete", decision.reason)

    def test_gate_hard_fails_on_creature_contract_failure(self) -> None:
        decision = quality._decide_gate(  # noqa: SLF001
            profile="nightly",
            quality_score_total=95.0,
            telemetry_complete=True,
            timed_out_targets=0,
            mobile_hard_fail=False,
            creature_contract_failed=True,
            gate_start_date=datetime(2026, 1, 1, tzinfo=UTC),
            warmup_days=0,
            enforce_investigative_gate=False,
        )
        self.assertTrue(decision.failed)
        self.assertIn("creature_contract_failed", decision.reason)

    def test_compute_scores_includes_creature_scores(self) -> None:
        lanes = {
            "unit": quality.LaneResult("unit", 10, 0, 0, 0.0, 0),
            "smoke": quality.LaneResult("smoke", 5, 0, 0, 0.0, 0),
            "integration": quality.LaneResult("integration", 2, 0, 0, 0.0, 0),
            "python": quality.LaneResult("python", 3, 0, 0, 0.0, 0),
        }
        perf_run = {
            "summary": {
                "total_tests": 20,
                "failed_tests": 0,
                "timed_out_targets": 0,
                "failed_targets": 0,
                "telemetry_complete": True,
                "total_visual_cases": 0,
                "failed_visual_cases": 0,
            },
            "scenarios": [],
            "visual_artifacts": [],
            "creature_runtime_snapshot": {
                "creature_population_alive": 8,
                "creature_spawn_success_rate": 0.8,
                "creature_tick_ms_p95": 2.0,
                "creature_render_ms_p95": 1.0,
                "creature_queen_alive_ratio": 1.0,
                "creature_visibility_failures": 0,
            },
        }
        _, _, _, _, creature_scores, creature_contract_failed, advisory_scores = quality._compute_scores(  # noqa: SLF001
            profile="pr",
            lanes=lanes,
            perf_run=perf_run,
            android_summary=None,
        )
        self.assertIn("creature_correctness_score", creature_scores)
        self.assertFalse(creature_contract_failed)
        self.assertIn("physics_correctness_score", advisory_scores)

    def test_extract_optuna_metadata_prefers_perf_run_then_trial_config(self) -> None:
        metadata = quality._extract_optuna_metadata(  # noqa: SLF001
            perf_run={"optuna": {"profile": "mobile", "source_label": "cloud_optuna"}},
            trial_config={"optuna": {"profile": "balanced", "source_label": "local_optuna"}},
        )
        self.assertEqual(metadata["profile"], "mobile")
        self.assertEqual(metadata["source_label"], "cloud_optuna")

    def test_extract_optuna_metadata_falls_back_to_trial_config(self) -> None:
        metadata = quality._extract_optuna_metadata(  # noqa: SLF001
            perf_run=None,
            trial_config={
                "optuna": {
                    "profile": "exploratory",
                    "source_label": "local_optuna",
                    "search_groups": ["scheduler"],
                }
            },
        )
        self.assertEqual(metadata["profile"], "exploratory")
        self.assertEqual(metadata["search_groups"], ["scheduler"])


if __name__ == "__main__":
    unittest.main()
