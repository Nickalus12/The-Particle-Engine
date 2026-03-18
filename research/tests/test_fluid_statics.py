"""Fluid statics tests: Pascal's law, buoyancy, density ordering."""

import pytest


class TestPascalPressure:
    """Pressure should increase linearly with depth."""

    @pytest.mark.physics
    def test_pressure_linear_with_depth(self, ground_truth):
        gt = ground_truth.get("pressure_depth")
        if gt is None:
            pytest.skip("No pressure_depth oracle data")
        depths = gt["depths_cells"]
        pressures = gt["expected_pressure"]
        for d, p in zip(depths, pressures):
            assert p == d, f"Pressure at depth {d} should be {d}, got {p}"

    @pytest.mark.physics
    def test_pressure_r_squared(self, ground_truth):
        gt = ground_truth.get("pressure_depth")
        if gt is None:
            pytest.skip("No pressure_depth oracle data")
        assert gt["linearity_r_squared"] == pytest.approx(1.0)


class TestBuoyancy:
    """Elements should float or sink correctly relative to water."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,should_sink",
        [
            ("metal", True),
            ("stone", True),
            ("sand", True),
            ("wood", False),
            ("oil", False),
            ("ice", False),
        ],
    )
    def test_buoyancy_direction(self, ground_truth, element, should_sink):
        gt = ground_truth.get("buoyancy_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No buoyancy data for {element}")
        if should_sink:
            assert entry["engine_should_sink"], f"{element} should sink"
        else:
            assert entry["engine_should_float"], f"{element} should float"

    @pytest.mark.physics
    def test_buoyancy_real_engine_agreement(self, ground_truth):
        """Engine buoyancy should match real-world physics for most elements."""
        gt = ground_truth.get("buoyancy_all", {})
        agreements = sum(1 for v in gt.values() if v.get("buoyancy_agreement"))
        total = len(gt)
        if total == 0:
            pytest.skip("No buoyancy data")
        ratio = agreements / total
        assert ratio >= 0.8, f"Only {ratio*100:.0f}% buoyancy agreement"


class TestDensityOrdering:
    """Engine density ordering should approximate real-world ordering."""

    @pytest.mark.physics
    def test_density_ordering_accuracy(self, ground_truth):
        gt = ground_truth.get("density_ordering")
        if gt is None:
            pytest.skip("No density_ordering oracle data")
        accuracy = gt["ordering_accuracy"]
        assert accuracy >= 0.8, f"Density ordering accuracy {accuracy:.2f} < 0.8"

    @pytest.mark.physics
    def test_densest_element(self, ground_truth):
        """Stone has highest engine density (255)."""
        gt = ground_truth.get("density_ordering")
        if gt is None:
            pytest.skip("No density_ordering oracle data")
        assert gt["our_order"][0] in ("stone", "metal")

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "heavier,lighter",
        [
            ("stone", "sand"),
            ("sand", "water"),
            ("water", "oil"),
            ("wood", "snow"),
        ],
    )
    def test_pairwise_density(self, ground_truth, heavier, lighter):
        gt = ground_truth.get("density_pairs", {})
        key = f"{heavier}_vs_{lighter}"
        if key not in gt:
            key = f"{lighter}_vs_{heavier}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No density pair data for {heavier} vs {lighter}")
        assert entry["heavier"] == heavier
