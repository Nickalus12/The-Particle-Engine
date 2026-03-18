"""Thermodynamics tests: Fourier conduction, Newton cooling, equilibrium."""

import math

import pytest


class TestNewtonCooling:
    """Cooling curves should follow exponential decay."""

    @pytest.mark.physics
    def test_cooling_curve_decays(self, ground_truth):
        gt = ground_truth.get("cooling_curve")
        if gt is None:
            pytest.skip("No cooling_curve oracle data")
        temps = gt["analytical_temps"]
        # Temperature should monotonically decrease
        for i in range(1, len(temps)):
            assert temps[i] <= temps[i - 1], \
                f"Temperature increased at frame {gt['frames'][i]}"

    @pytest.mark.physics
    def test_cooling_approaches_ambient(self, ground_truth):
        gt = ground_truth.get("cooling_curve")
        if gt is None:
            pytest.skip("No cooling_curve oracle data")
        t_ambient = gt["T_ambient"]
        final_temp = gt["analytical_temps"][-1]
        assert final_temp == pytest.approx(t_ambient, abs=10)

    @pytest.mark.physics
    def test_ode_matches_analytical(self, ground_truth):
        """ODE solution should match analytical solution closely."""
        gt = ground_truth.get("cooling_curve")
        if gt is None:
            pytest.skip("No cooling_curve oracle data")
        for a, o in zip(gt["analytical_temps"], gt["ode_temps"]):
            assert a == pytest.approx(o, abs=0.5)


class TestCoolingAllMaterials:
    """Every conductive material should have a valid cooling curve."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "material",
        ["stone", "water", "metal", "sand", "ice", "lava", "wood", "glass"],
    )
    def test_material_cooling_exists(self, ground_truth, material):
        gt = ground_truth.get("cooling_all", {})
        entry = gt.get(material)
        if entry is None:
            pytest.skip(f"No cooling data for {material}")
        assert entry["k"] > 0
        assert entry["half_life_frames"] > 0

    @pytest.mark.physics
    def test_metal_cools_faster_than_wood(self, ground_truth):
        gt = ground_truth.get("cooling_all", {})
        metal = gt.get("metal")
        wood = gt.get("wood")
        if metal is None or wood is None:
            pytest.skip("Missing cooling data")
        assert metal["k"] > wood["k"]


class TestThermalEquilibrium:
    """Two bodies should reach equilibrium at weighted average temperature."""

    @pytest.mark.physics
    def test_equal_mass_equilibrium(self, ground_truth):
        gt = ground_truth.get("equilibrium", {})
        entry = gt.get("water_equal")
        if entry is None:
            pytest.skip("No equilibrium data")
        expected = (entry["T_hot"] + entry["T_cold"]) / 2.0
        assert entry["expected_T_eq"] == pytest.approx(expected)

    @pytest.mark.physics
    def test_unequal_mass_equilibrium(self, ground_truth):
        gt = ground_truth.get("equilibrium", {})
        entry = gt.get("stone_stone")
        if entry is None:
            pytest.skip("No equilibrium data")
        expected = (
            entry["n_hot"] * entry["T_hot"] + entry["n_cold"] * entry["T_cold"]
        ) / (entry["n_hot"] + entry["n_cold"])
        assert entry["expected_T_eq"] == pytest.approx(expected, abs=1.0)


class TestFourierConduction:
    """Steady-state heat conduction should show linear temperature gradient."""

    @pytest.mark.physics
    def test_steady_state_monotonic(self, ground_truth):
        gt = ground_truth.get("heat_conduction")
        if gt is None:
            pytest.skip("No heat_conduction oracle data")
        temps = gt["steady_state_temps"]
        for i in range(1, len(temps)):
            assert temps[i] <= temps[i - 1], \
                "Steady-state gradient should be monotonically decreasing"

    @pytest.mark.physics
    def test_steady_state_endpoints(self, ground_truth):
        gt = ground_truth.get("heat_conduction")
        if gt is None:
            pytest.skip("No heat_conduction oracle data")
        assert gt["steady_state_temps"][0] == pytest.approx(gt["T_hot"], abs=1)
        assert gt["steady_state_temps"][-1] == pytest.approx(
            gt["T_ambient"], abs=5
        )


class TestThermalConductivityOrdering:
    """Conductivity ordering should match real-world ranking."""

    @pytest.mark.physics
    def test_metal_most_conductive(self, ground_truth):
        gt = ground_truth.get("conduction_all")
        if gt is None:
            pytest.skip("No conduction data")
        ordering = gt["ordering"]
        # Metal or lightning should be among the top conductors
        assert "metal" in ordering[:3] or "lightning" in ordering[:3]

    @pytest.mark.physics
    def test_wood_low_conductivity(self, ground_truth):
        gt = ground_truth.get("conduction_all")
        if gt is None:
            pytest.skip("No conduction data")
        ordering = gt["ordering"]
        wood_idx = ordering.index("wood") if "wood" in ordering else -1
        if wood_idx < 0:
            pytest.skip("Wood not in ordering")
        assert wood_idx > len(ordering) // 2, "Wood should be a poor conductor"
