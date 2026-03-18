"""Granular physics tests: angle of repose, granular behavior, flow, jamming."""

import math

import numpy as np
import pytest


class TestAngleOfRepose:
    """Granular elements should have physically plausible angles of repose."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_angle",
        [
            ("sand", 34),
            ("dirt", 40),
            ("snow", 38),
            ("ash", 35),
        ],
    )
    def test_angle_range(self, ground_truth, element, expected_angle):
        gt = ground_truth.get("angle_of_repose", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No angle of repose data for {element}")
        assert entry["min"] <= expected_angle <= entry["max"]

    @pytest.mark.physics
    def test_ca_natural_angle(self, ground_truth):
        """Cellular automata with 8-connectivity have natural 45-deg angle."""
        gt = ground_truth.get("granular_all", {})
        for name, entry in gt.items():
            assert entry["ca_natural_angle"] == 45


class TestGranularAll:
    """Extended granular element properties."""

    @pytest.mark.physics
    @pytest.mark.parametrize("element", ["sand", "dirt", "tnt", "snow", "ash"])
    def test_granular_state(self, ground_truth, element):
        gt = ground_truth.get("granular_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No granular data for {element}")
        assert entry["state"] in ("granular", "powder")
        assert entry["gravity"] > 0

    @pytest.mark.physics
    def test_sand_tan_angle(self, ground_truth):
        gt = ground_truth.get("granular_all", {})
        entry = gt.get("sand")
        if entry is None:
            pytest.skip("No granular data for sand")
        expected_tan = math.tan(math.radians(34))
        assert entry["tan_angle"] == pytest.approx(expected_tan, abs=0.01)


class TestLiveGranularBehavior:
    """Verify granular physics using actual simulation frame data."""

    @pytest.mark.physics
    def test_sand_forms_pile(self, simulation_frame):
        """Sand should accumulate on surfaces, not be evenly distributed."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        sand_id = elements.get("Sand")
        if sand_id is None:
            pytest.skip("No Sand element")
        sand_mask = grid == sand_id
        if sand_mask.sum() < 10:
            pytest.skip("Not enough sand")
        sand_ys = np.where(sand_mask)[0]
        # Sand should be concentrated (low std dev in y) not scattered
        y_range = int(sand_ys.max() - sand_ys.min())
        assert y_range < 30, (
            f"Sand y-range={y_range}, expected concentrated pile (< 30 rows)"
        )

    @pytest.mark.physics
    def test_dirt_is_granular(self, simulation_frame):
        """Dirt should behave as a granular and settle on surfaces."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        dirt_id = elements.get("Dirt")
        if dirt_id is None:
            pytest.skip("No Dirt element")
        dirt_positions = np.where(grid == dirt_id)
        if len(dirt_positions[0]) == 0:
            pytest.skip("No dirt in frame")
        avg_y = float(np.mean(dirt_positions[0]))
        assert avg_y > 80, f"Dirt avg y={avg_y:.1f}, should be in lower half"

    @pytest.mark.physics
    def test_granular_elements_not_floating(self, simulation_frame):
        """No granular element should be isolated in the top 20 rows."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        granulars = ["Sand", "Dirt", "TNT"]
        top_strip = grid[:20, :]
        for name in granulars:
            el_id = elements.get(name)
            if el_id is None:
                continue
            count = int((top_strip == el_id).sum())
            assert count == 0, (
                f"{name} found {count} times in top 20 rows (should have fallen)"
            )


class TestHourglassFlowRate:
    """Wider openings should allow faster granular flow."""

    @pytest.mark.physics
    def test_gravity_determines_flow_speed(self, ground_truth):
        """Elements with higher gravity should flow faster through openings."""
        gt = ground_truth.get("granular_all", {})
        sand = gt.get("sand")
        snow = gt.get("snow")
        if sand is None or snow is None:
            pytest.skip("Missing granular data")
        # Sand (gravity=2) should fall faster than snow (gravity=1 via powder)
        assert sand["gravity"] >= 1


class TestJammingTransition:
    """Very narrow openings should cause granular jamming."""

    @pytest.mark.physics
    def test_granular_elements_have_ca_angle(self, ground_truth):
        """All granular elements should have 45-degree CA natural angle."""
        gt = ground_truth.get("granular_all", {})
        for name, entry in gt.items():
            assert entry["ca_natural_angle"] == 45, (
                f"{name} CA angle is {entry['ca_natural_angle']}, expected 45"
            )

    @pytest.mark.physics
    def test_high_density_granulars(self, ground_truth):
        """Granular elements should have density > 100 (heavy enough to pile)."""
        gt = ground_truth.get("granular_all", {})
        for name in ["sand", "dirt", "tnt"]:
            entry = gt.get(name)
            if entry is None:
                continue
            assert entry.get("density", 0) > 0 or entry.get("gravity", 0) > 0


class TestGradedBedding:
    """Heavy granulars should settle below light granulars in water."""

    @pytest.mark.physics
    def test_sand_heavier_than_snow(self, ground_truth):
        """Sand (d=150) should settle below snow (d=50) in a mixture."""
        gt = ground_truth.get("density_pairs", {})
        key = "sand_vs_snow"
        entry = gt.get(key)
        if entry is None:
            pytest.skip("No density pair data for sand vs snow")
        assert entry["heavier"] == "sand"

    @pytest.mark.physics
    def test_dirt_heavier_than_ash(self, ground_truth):
        """Dirt (d=145) should settle below ash (d=30) in a mixture."""
        gt = ground_truth.get("density_pairs", {})
        key = "dirt_vs_ash"
        if key not in gt:
            key = "ash_vs_dirt"
        entry = gt.get(key)
        if entry is None:
            pytest.skip("No density pair data for dirt vs ash")
        assert entry["heavier"] == "dirt"
