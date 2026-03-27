from __future__ import annotations

import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tool" / "performance"))

import export_otlp  # type: ignore  # noqa: E402


class ExportOtlpContractTests(unittest.TestCase):
    def test_safe_float_converts_numeric_like_values(self) -> None:
        self.assertEqual(export_otlp._safe_float(2), 2.0)  # noqa: SLF001
        self.assertEqual(export_otlp._safe_float("3.5"), 3.5)  # noqa: SLF001
        self.assertEqual(export_otlp._safe_float(True), 1.0)  # noqa: SLF001
        self.assertIsNone(export_otlp._safe_float("not-a-number"))  # noqa: SLF001

    def test_iter_scenario_metric_points_skips_non_numeric_values(self) -> None:
        run = {
            "scenarios": [
                {
                    "suite": "physics_integrity",
                    "scenario": "water_balance",
                    "metrics": {
                        "hydro_abs_delta_total": 5,
                        "label": "bad",
                        "ratio": "0.25",
                    },
                    "tags": {"profile": "ci", "seed": 7},
                }
            ]
        }
        points = list(
            export_otlp._iter_scenario_metric_points(  # noqa: SLF001
                run,
                {"run_id": "run_1"},
            )
        )
        self.assertEqual(len(points), 2)
        metric_keys = {attrs["metric_key"] for _, attrs in points}
        self.assertEqual(metric_keys, {"hydro_abs_delta_total", "ratio"})
        for _, attrs in points:
            self.assertIn("tag_profile", attrs)
            self.assertIn("tag_seed", attrs)

    def test_normalize_tag_attrs_bounds_cardinality(self) -> None:
        tags = {f"k{i}": i for i in range(20)}
        attrs = export_otlp._normalize_tag_attrs(tags)  # noqa: SLF001
        self.assertLessEqual(len(attrs), 8)
        self.assertTrue(all(key.startswith("tag_") for key in attrs))

    def test_iter_visual_points_yields_failed_flag(self) -> None:
        run = {
            "visual_artifacts": [
                {"scenario": "cloud", "diff_ratio": 0.05, "ssim": 0.98, "pass": True},
                {"scenario": "water", "diff_ratio": 0.15, "ssim": 0.93, "pass": False},
            ]
        }
        points = list(export_otlp._iter_visual_points(run, {"run_id": "run_1"}))  # noqa: SLF001
        self.assertEqual(len(points), 2)
        self.assertFalse(points[0][2])
        self.assertTrue(points[1][2])


if __name__ == "__main__":
    unittest.main()
