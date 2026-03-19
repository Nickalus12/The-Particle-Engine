"""Fluid statics tests: Pascal's law, buoyancy, density ordering, density pairs."""

import itertools

import numpy as np
import pytest

# All elements with known densities (from element_registry.dart)
ELEMENT_DENSITIES = {
    "sand": 150, "water": 100, "fire": 5, "ice": 90, "seed": 130,
    "stone": 255, "tnt": 140, "rainbow": 8, "mud": 120, "steam": 3,
    "ant": 80, "oil": 80, "acid": 110, "glass": 220, "dirt": 145,
    "plant": 60, "lava": 200, "snow": 50, "wood": 85, "metal": 240,
    "smoke": 4, "bubble": 2, "ash": 30,
}


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


def _density_pairs():
    """Generate all element pairs where a has strictly greater density than b."""
    elements = sorted(ELEMENT_DENSITIES.keys())
    pairs = []
    for a, b in itertools.combinations(elements, 2):
        da, db = ELEMENT_DENSITIES[a], ELEMENT_DENSITIES[b]
        if da == db:
            continue
        if da > db:
            pairs.append((a, b))
        else:
            pairs.append((b, a))
    return pairs


class TestComprehensiveDensityPairs:
    """Every pair of elements with different densities should have correct ordering."""

    @pytest.mark.physics
    @pytest.mark.parametrize("heavier,lighter", _density_pairs())
    def test_density_pair(self, ground_truth, heavier, lighter):
        """Heavier element should sink below lighter in the oracle."""
        gt = ground_truth.get("density_pairs", {})
        key = f"{heavier}_vs_{lighter}"
        if key not in gt:
            key = f"{lighter}_vs_{heavier}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No density pair data for {heavier} vs {lighter}")
        assert entry["heavier"] == heavier, (
            f"Expected {heavier} (d={ELEMENT_DENSITIES[heavier]}) to be heavier "
            f"than {lighter} (d={ELEMENT_DENSITIES[lighter]}), "
            f"but oracle says {entry['heavier']}"
        )


class TestLiveDensityOrdering:
    """Verify density ordering in actual simulation frame."""

    @pytest.mark.physics
    def test_water_below_oil(self, simulation_frame):
        """Water (d=100) should be below oil (d=80) in the simulation."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        water_id = elements.get("Water")
        oil_id = elements.get("Oil")
        if water_id is None or oil_id is None:
            pytest.skip("Missing Water or Oil element")
        water_ys = np.where(grid == water_id)[0]
        oil_ys = np.where(grid == oil_id)[0]
        if len(water_ys) == 0 or len(oil_ys) == 0:
            pytest.skip("Not enough water or oil in frame")
        water_avg = float(np.mean(water_ys))
        oil_avg = float(np.mean(oil_ys))
        # Higher y = lower on screen. Water should have higher avg y (below oil).
        assert water_avg > oil_avg, (
            f"Water avg_y={water_avg:.1f} should be below oil avg_y={oil_avg:.1f}"
        )

    @pytest.mark.physics
    def test_lava_below_water(self, simulation_frame):
        """Lava (d=200) should be below water (d=100) in the simulation."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        water_id = elements.get("Water")
        lava_id = elements.get("Lava")
        if water_id is None or lava_id is None:
            pytest.skip("Missing Water or Lava element")
        water_ys = np.where(grid == water_id)[0]
        lava_ys = np.where(grid == lava_id)[0]
        if len(water_ys) == 0 or len(lava_ys) == 0:
            pytest.skip("Not enough water or lava in frame")
        water_avg = float(np.mean(water_ys))
        lava_avg = float(np.mean(lava_ys))
        assert lava_avg > water_avg, (
            f"Lava avg_y={lava_avg:.1f} should be below water avg_y={water_avg:.1f}"
        )


class TestHydrostaticParadox:
    """Pressure at the bottom depends only on height, not container shape."""

    @pytest.mark.physics
    def test_hydrostatic_paradox_principle(self, ground_truth):
        """Oracle: pressure difference between shapes should be ~0."""
        gt = ground_truth.get("hydrostatic_paradox")
        if gt is None:
            pytest.skip("No hydrostatic_paradox oracle data")
        assert gt["expected_pressure_difference"] == 0
        assert gt["tolerance"] <= 5

    @pytest.mark.physics
    def test_pressure_independent_of_width(self, ground_truth):
        """Pressure at a given depth is the same regardless of column width."""
        gt = ground_truth.get("pressure_depth")
        if gt is None:
            pytest.skip("No pressure_depth oracle data")
        depths = gt["depths_cells"]
        pressures = gt["expected_pressure"]
        # For any depth, pressure = depth (independent of container width)
        for d, p in zip(depths, pressures):
            assert abs(p - d) <= 1, (
                f"Pressure at depth {d} should be ~{d}, got {p}"
            )


class TestLoadDistribution:
    """Taller liquid columns exert more pressure at the base."""

    @pytest.mark.physics
    def test_pressure_ratio_matches_height_ratio(self, ground_truth):
        """P_tall / P_short should equal h_tall / h_short."""
        gt = ground_truth.get("load_distribution")
        if gt is None:
            pytest.skip("No load_distribution oracle data")
        expected_ratio = gt["expected_pressure_ratio"]
        tall = gt["tall_height"]
        short = gt["short_height"]
        assert expected_ratio == pytest.approx(tall / short, rel=0.01)

    @pytest.mark.physics
    def test_tall_column_exerts_more_pressure(self, ground_truth):
        """A column 3x taller should exert 3x the base pressure."""
        gt = ground_truth.get("load_distribution")
        if gt is None:
            pytest.skip("No load_distribution oracle data")
        assert gt["expected_pressure_ratio"] == pytest.approx(3.0, rel=0.01)
        assert gt["tall_height"] > gt["short_height"]

    @pytest.mark.physics
    def test_load_principle(self, ground_truth):
        """Principle: taller liquid column exerts more pressure at base."""
        gt = ground_truth.get("load_distribution")
        if gt is None:
            pytest.skip("No load_distribution oracle data")
        assert "pressure" in gt["principle"].lower()


class TestUTubeFluids:
    """In a U-tube, immiscible fluids balance by density ratio."""

    @pytest.mark.physics
    def test_oil_water_height_ratio(self, ground_truth):
        """h_oil / h_water = rho_water / rho_oil = 1.25."""
        gt = ground_truth.get("u_tube_fluids")
        if gt is None:
            pytest.skip("No u_tube_fluids oracle data")
        expected = gt["expected_oil_to_water_height_ratio"]
        assert expected == pytest.approx(1.25, rel=0.01)

    @pytest.mark.physics
    def test_engine_density_ratio_matches(self, ground_truth):
        """Engine density ratio should match real-world ratio."""
        gt = ground_truth.get("u_tube_fluids")
        if gt is None:
            pytest.skip("No u_tube_fluids oracle data")
        engine_ratio = gt["our_density_water"] / gt["our_density_oil"]
        assert engine_ratio == pytest.approx(gt["our_expected_ratio"], rel=0.01)

    @pytest.mark.physics
    def test_water_denser_than_oil(self, ground_truth):
        """Water density should be greater than oil density."""
        gt = ground_truth.get("u_tube_fluids")
        if gt is None:
            pytest.skip("No u_tube_fluids oracle data")
        assert gt["water_density"] > gt["oil_density"]


class TestBuoyancyDetailed:
    """Detailed buoyancy oracle: real densities and sink/float predictions."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,should_sink",
        [
            ("metal", True),
            ("stone", True),
            ("glass", True),
            ("wood", False),
            ("oil", False),
            ("ice", False),
        ],
    )
    def test_buoyancy_oracle(self, ground_truth, element, should_sink):
        gt = ground_truth.get("buoyancy", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No buoyancy data for {element}")
        assert entry["should_sink"] == should_sink

    @pytest.mark.physics
    def test_metal_densest_real(self, ground_truth):
        gt = ground_truth.get("buoyancy", {})
        if not gt:
            pytest.skip("No buoyancy data")
        densities = {k: v["real_density_kg_m3"] for k, v in gt.items()}
        assert max(densities, key=densities.get) == "metal"

    @pytest.mark.physics
    def test_all_reference_water_density(self, ground_truth):
        gt = ground_truth.get("buoyancy", {})
        if not gt:
            pytest.skip("No buoyancy data")
        for element, entry in gt.items():
            assert entry["water_density_kg_m3"] == 1000


class TestStackPressure:
    """A settled stack of elements should remain stable."""

    @pytest.mark.physics
    def test_stack_pressure_principle(self, ground_truth):
        gt = ground_truth.get("stack_pressure")
        if gt is None:
            pytest.skip("No stack_pressure oracle data")
        assert gt["test_element"] == "sand"
        assert gt["stack_height"] == 10

    @pytest.mark.physics
    def test_stack_stability(self, ground_truth):
        gt = ground_truth.get("stack_pressure")
        if gt is None:
            pytest.skip("No stack_pressure oracle data")
        assert "stable" in gt["principle"].lower() or "remain" in gt["principle"].lower()
