from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from research import benchmark


class BenchmarkContractUnitTests(unittest.TestCase):
    def test_compute_overall_score_uses_profile_weights(self) -> None:
        domain_scores = {
            "Physics": {"score": 80.0},
            "Visuals": {"score": 70.0},
            "Infrastructure": {"score": 60.0},
        }
        balanced = benchmark.compute_overall_score(domain_scores, profile="balanced")
        mobile = benchmark.compute_overall_score(domain_scores, profile="mobile")
        self.assertNotEqual(balanced, mobile)
        self.assertGreater(mobile, 0.0)

    def test_load_optuna_metadata_reads_trial_config_optuna_block(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            trial_path = Path(td) / "trial_config.json"
            trial_path.write_text(
                json.dumps(
                    {
                        "optuna": {
                            "profile": "mobile",
                            "source_label": "cloud_optuna",
                            "execution_mode": "extended",
                            "search_groups": ["scheduler", "worldgen"],
                        }
                    }
                ),
                encoding="utf-8",
            )
            metadata = benchmark._load_optuna_metadata(  # noqa: SLF001
                metadata_path=str(trial_path)
            )
        self.assertEqual(metadata["profile"], "mobile")
        self.assertEqual(metadata["source_label"], "cloud_optuna")
        self.assertEqual(metadata["execution_mode"], "extended")
        self.assertEqual(metadata["search_groups"], ["scheduler", "worldgen"])

    def test_save_run_persists_scoring_profile_and_optuna_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            history_path = Path(td) / "benchmark_history.jsonl"
            original = benchmark.HISTORY_FILE
            benchmark.HISTORY_FILE = history_path
            try:
                benchmark.save_run(
                    {
                        "timestamp": "2026-03-27T00:00:00",
                        "git_hash": "abc123",
                        "git_dirty": False,
                        "duration_seconds": 1.2,
                        "overall_score": 88.4,
                        "scoring_profile": "mobile",
                        "total_passed": 10,
                        "total_failed": 1,
                        "total_skipped": 0,
                        "total_tests": 11,
                        "domain_scores": {
                            "Physics": {"score": 90.0},
                            "Visuals": {"score": 70.0},
                            "Infrastructure": {"score": 85.0},
                        },
                        "category_scores": {},
                        "optuna": {
                            "profile": "mobile",
                            "source_label": "local_optuna",
                            "param_count": 12,
                        },
                    }
                )
            finally:
                benchmark.HISTORY_FILE = original

            saved = json.loads(history_path.read_text(encoding="utf-8").strip())
            self.assertEqual(saved["scoring_profile"], "mobile")
            self.assertEqual(saved["optuna"]["profile"], "mobile")
            self.assertEqual(saved["optuna"]["source_label"], "local_optuna")


if __name__ == "__main__":
    unittest.main()
