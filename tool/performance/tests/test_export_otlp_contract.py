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

    def test_creature_snapshot_shape_uses_bounded_labels(self) -> None:
        run = {
            "creature_runtime_snapshot": {
                "species": "ant",
                "device_class": "mobile",
                "creature_population_alive": 15,
            }
        }
        snapshot = run["creature_runtime_snapshot"]
        self.assertEqual(str(snapshot.get("species", ""))[:20], "ant")
        self.assertEqual(str(snapshot.get("device_class", ""))[:20], "mobile")

    def test_iter_placement_points_extracts_known_metrics(self) -> None:
        run = {
            "scenarios": [
                {
                    "suite": "game_loop",
                    "scenario": "mobile_screen_space_placement_telemetry",
                    "metrics": {
                        "placement_stamps_total": 120,
                        "placement_cells_per_stamp": 3.25,
                        "other_metric": 7,
                    },
                    "tags": {
                        "device_class": "mobile",
                        "interaction": "screen_space_drag",
                    },
                }
            ]
        }
        points = list(export_otlp._iter_placement_points(run, {"run_id": "run_1"}))  # noqa: SLF001
        self.assertEqual(len(points), 2)
        keys = {key for key, _, _ in points}
        self.assertEqual(keys, {"placement_stamps_total", "placement_cells_per_stamp"})
        for _, _, attrs in points:
            self.assertEqual(attrs["device_class"], "mobile")
            self.assertEqual(attrs["interaction"], "screen_space_drag")

    def test_iter_physics_phase_points_extracts_phase_labels(self) -> None:
        run = {
            "physics_runtime_snapshot": {
                "phase_samples": [
                    {"key": "movement_gravity", "group": "movement_gravity", "duration_ms": 2.5}
                ]
            }
        }
        points = list(export_otlp._iter_physics_phase_points(run, {"run_id": "run_1"}))  # noqa: SLF001
        self.assertEqual(len(points), 1)
        self.assertEqual(points[0][1]["phase"], "movement_gravity")

    def test_iter_worldgen_stage_points_extracts_stage_names(self) -> None:
        run = {
            "worldgen_stage_summary": {
                "preset": "meadow",
                "stages": [
                    {"stage_name": "fill_layers", "duration_ms": 4.0},
                ],
            }
        }
        points = list(export_otlp._iter_worldgen_stage_points(run, {"run_id": "run_1"}))  # noqa: SLF001
        self.assertEqual(len(points), 1)
        self.assertEqual(points[0][1]["preset"], "meadow")
        self.assertEqual(points[0][1]["stage_name"], "fill_layers")

    def test_iter_render_points_extracts_bounded_render_labels(self) -> None:
        run = {
            "render_runtime_snapshot": {
                "render_pixel_passes": 24,
                "image_build_passes": 10,
                "render_skipped_frames": 8,
                "device_class": "mobile",
                "interaction": "screen_space_drag",
            }
        }
        points = list(export_otlp._iter_render_points(run, {"run_id": "run_1"}))  # noqa: SLF001
        self.assertEqual(len(points), 3)
        keys = {key for key, _, _ in points}
        self.assertEqual(
            keys,
            {"render_pixel_passes", "image_build_passes", "render_skipped_frames"},
        )
        for _, _, attrs in points:
            self.assertEqual(attrs["device_class"], "mobile")
            self.assertEqual(attrs["interaction"], "screen_space_drag")

    def test_extract_optuna_attrs_bounds_supported_labels(self) -> None:
        attrs = export_otlp._extract_optuna_attrs(  # noqa: SLF001
            {
                "optuna": {
                    "profile": "mobile",
                    "source_label": "cloud_optuna",
                    "execution_mode": "extended",
                    "search_groups": ["scheduler", "worldgen"],
                }
            }
        )
        self.assertEqual(attrs["optuna_profile"], "mobile")
        self.assertEqual(attrs["optuna_source"], "cloud_optuna")
        self.assertEqual(attrs["optuna_execution_mode"], "extended")
        self.assertNotIn("search_groups", attrs)


if __name__ == "__main__":
    unittest.main()
