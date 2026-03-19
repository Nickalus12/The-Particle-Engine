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


class TestThermalStratification:
    """Hot fluid should rise above cold fluid (convection)."""

    @pytest.mark.physics
    def test_stratification_principle(self, ground_truth):
        gt = ground_truth.get("thermal_stratification")
        if gt is None:
            pytest.skip("No thermal_stratification oracle data")
        assert gt["mechanism"] == "buoyancy-driven convection"
        assert "temperature decreases" in gt["expected_ordering"]


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


class TestHeatDiffusion:
    """Heat should diffuse from hot to cold following Fick's law."""

    @pytest.mark.physics
    def test_diffusion_coefficient_positive(self, ground_truth):
        """Diffusion coefficient D should be positive."""
        gt = ground_truth.get("diffusion")
        if gt is None:
            pytest.skip("No diffusion oracle data")
        assert gt["D_coefficient"] > 0

    @pytest.mark.physics
    def test_initial_profile_has_hot_spot(self, ground_truth):
        """Frame 0 should have a localized hot region (step function)."""
        gt = ground_truth.get("diffusion")
        if gt is None:
            pytest.skip("No diffusion oracle data")
        profile = gt["profiles"]["frame_0"]
        max_temp = max(profile)
        min_temp = min(profile)
        assert max_temp > min_temp, "Initial profile should have temperature variation"

    @pytest.mark.physics
    def test_diffusion_spreads_heat(self, ground_truth):
        """Later frames should have a wider, flatter temperature profile."""
        gt = ground_truth.get("diffusion")
        if gt is None:
            pytest.skip("No diffusion oracle data")
        profiles = gt["profiles"]
        keys = sorted(profiles.keys(), key=lambda k: int(k.split("_")[1]))
        if len(keys) < 2:
            pytest.skip("Need at least 2 profile snapshots")
        first = profiles[keys[0]]
        last = profiles[keys[-1]]
        # Standard deviation should decrease as heat spreads
        import numpy as np
        std_first = float(np.std(first))
        std_last = float(np.std(last))
        assert std_last <= std_first, (
            f"Heat should spread: std went from {std_first:.2f} to {std_last:.2f}"
        )

    @pytest.mark.physics
    def test_total_heat_conserved(self, ground_truth):
        """Total heat (sum of temperatures) should be approximately conserved."""
        gt = ground_truth.get("diffusion")
        if gt is None:
            pytest.skip("No diffusion oracle data")
        profiles = gt["profiles"]
        keys = sorted(profiles.keys(), key=lambda k: int(k.split("_")[1]))
        sums = [sum(profiles[k]) for k in keys]
        # All frame sums should be within 5% of each other
        avg_sum = sum(sums) / len(sums)
        for i, s in enumerate(sums):
            assert s == pytest.approx(avg_sum, rel=0.05), (
                f"Heat not conserved: frame {keys[i]} sum={s:.1f} vs avg={avg_sum:.1f}"
            )


class TestSpecificHeatCapacity:
    """Specific heat capacity: Q = mcΔT, different materials heat at different rates."""

    @pytest.mark.physics
    def test_water_highest_capacity(self, ground_truth):
        """Water should have the highest heat capacity (real: 4.18 J/g·K)."""
        gt = ground_truth.get("specific_heat_capacity")
        if gt is None:
            pytest.skip("No specific_heat_capacity oracle data")
        assert gt["water_highest"] is True
        caps = gt["our_1_to_10"]
        water_cap = caps["water"]
        for name, cap in caps.items():
            assert water_cap >= cap, f"water ({water_cap}) < {name} ({cap})"

    @pytest.mark.physics
    def test_metal_lowest_capacity(self, ground_truth):
        """Metal should have the lowest heat capacity (real: 0.45 J/g·K)."""
        gt = ground_truth.get("specific_heat_capacity")
        if gt is None:
            pytest.skip("No specific_heat_capacity oracle data")
        assert gt["metal_lowest"] is True
        caps = gt["our_1_to_10"]
        metal_cap = caps["metal"]
        for name, cap in caps.items():
            assert metal_cap <= cap, f"metal ({metal_cap}) > {name} ({cap})"

    @pytest.mark.physics
    def test_ordering_preserves_real_physics(self, ground_truth):
        """Our capacity ordering should broadly match real-world ordering."""
        gt = ground_truth.get("specific_heat_capacity")
        if gt is None:
            pytest.skip("No specific_heat_capacity oracle data")
        real = gt["real_ordering"]
        ours = gt["our_ordering"]
        # Water should be first in both
        assert real[0] == "water"
        assert ours[0] == "water"
        # Metal should be last in real ordering
        assert real[-1] == "metal"

    @pytest.mark.physics
    def test_liquids_higher_than_solids(self, ground_truth):
        """Liquids generally have higher heat capacity than solids."""
        gt = ground_truth.get("specific_heat_capacity")
        if gt is None:
            pytest.skip("No specific_heat_capacity oracle data")
        caps = gt["our_1_to_10"]
        # Water > stone, water > metal, water > sand
        assert caps["water"] > caps["stone"]
        assert caps["water"] > caps["metal"]
        assert caps["water"] > caps["sand"]

    @pytest.mark.physics
    def test_all_values_in_range(self, ground_truth):
        """All heat capacity values should be in [1, 10]."""
        gt = ground_truth.get("specific_heat_capacity")
        if gt is None:
            pytest.skip("No specific_heat_capacity oracle data")
        for name, cap in gt["our_1_to_10"].items():
            assert 1 <= cap <= 10, f"{name} capacity {cap} out of [1, 10]"


class TestPressureDependentBoiling:
    """Clausius-Clapeyron: boiling point should increase with pressure/depth."""

    @pytest.mark.physics
    def test_deep_water_resists_boiling(self, ground_truth):
        """Water under pressure should require higher temperature to boil."""
        gt = ground_truth.get("pressure_boiling")
        if gt is None:
            pytest.skip("No pressure_boiling oracle data")
        assert gt["deep_water_resists_boiling"] is True

    @pytest.mark.physics
    def test_surface_water_boils_normally(self, ground_truth):
        """Surface water (no pressure) should boil at normal threshold."""
        gt = ground_truth.get("pressure_boiling")
        if gt is None:
            pytest.skip("No pressure_boiling oracle data")
        assert gt["surface_water_boils_normally"] is True

    @pytest.mark.physics
    def test_real_bp_increases_with_pressure(self, ground_truth):
        """Real water boiling point should increase with atmospheric pressure."""
        gt = ground_truth.get("pressure_boiling")
        if gt is None:
            pytest.skip("No pressure_boiling oracle data")
        assert gt["water_bp_at_2atm_C"] > gt["water_bp_at_1atm_C"]
        assert gt["water_bp_at_5atm_C"] > gt["water_bp_at_2atm_C"]

    @pytest.mark.physics
    def test_clausius_clapeyron_principle(self, ground_truth):
        """Oracle should state the Clausius-Clapeyron equation."""
        gt = ground_truth.get("pressure_boiling")
        if gt is None:
            pytest.skip("No pressure_boiling oracle data")
        assert "Clausius-Clapeyron" in gt["principle"]


class TestLeidenfrostEffect:
    """Leidenfrost: water on very hot surfaces levitates on vapor cushion."""

    @pytest.mark.physics
    def test_leidenfrost_above_boiling(self, ground_truth):
        """Leidenfrost point should be above normal boiling point."""
        gt = ground_truth.get("leidenfrost_effect")
        if gt is None:
            pytest.skip("No leidenfrost_effect oracle data")
        assert gt["leidenfrost_point_C"] > gt["water_bp_C"]

    @pytest.mark.physics
    def test_vapor_cushion_mechanism(self, ground_truth):
        """The effect should involve a vapor film insulating the droplet."""
        gt = ground_truth.get("leidenfrost_effect")
        if gt is None:
            pytest.skip("No leidenfrost_effect oracle data")
        assert "vapor" in gt["mechanism"].lower() or "vapour" in gt["mechanism"].lower()

    @pytest.mark.physics
    def test_engine_threshold_reasonable(self, ground_truth):
        """Our engine threshold should be in the high temperature range."""
        gt = ground_truth.get("leidenfrost_effect")
        if gt is None:
            pytest.skip("No leidenfrost_effect oracle data")
        # Threshold should be > 200 (well above neutral 128)
        assert gt["our_temp_threshold"] > 200


class TestAnomalousExpansion:
    """Water density maximum at 4C: anomalous expansion below this temperature."""

    @pytest.mark.physics
    def test_anomalous_expansion_principle(self, ground_truth):
        """Oracle should describe water's density maximum."""
        gt = ground_truth.get("anomalous_expansion")
        if gt is None:
            pytest.skip("No anomalous_expansion oracle data")
        assert "density" in gt["principle"].lower()
        assert gt["density_max_temp_C"] == pytest.approx(3.98, abs=0.1)

    @pytest.mark.physics
    def test_density_inversion_below_4C(self, ground_truth):
        """Water at 0C should be less dense than water at 4C."""
        gt = ground_truth.get("anomalous_expansion")
        if gt is None:
            pytest.skip("No anomalous_expansion oracle data")
        assert gt["density_at_0C_kg_m3"] < gt["density_at_max_kg_m3"]

    @pytest.mark.physics
    def test_our_threshold_reasonable(self, ground_truth):
        """Our engine's density max temperature should be in cold range."""
        gt = ground_truth.get("anomalous_expansion")
        if gt is None:
            pytest.skip("No anomalous_expansion oracle data")
        threshold = gt["our_density_max_temp"]
        assert 20 <= threshold <= 60, "Threshold should map to cold range"

    @pytest.mark.physics
    def test_top_down_freezing_consequence(self, ground_truth):
        """Top-down freezing should be listed as a consequence."""
        gt = ground_truth.get("anomalous_expansion")
        if gt is None:
            pytest.skip("No anomalous_expansion oracle data")
        consequences = " ".join(gt["consequences"]).lower()
        assert "top" in consequences and "freeze" in consequences


class TestEvaporativeCooling:
    """Evaporation absorbs latent heat, cooling surroundings."""

    @pytest.mark.physics
    def test_evaporative_cooling_principle(self, ground_truth):
        """Oracle should describe latent heat absorption."""
        gt = ground_truth.get("evaporative_cooling")
        if gt is None:
            pytest.skip("No evaporative_cooling oracle data")
        assert "latent" in gt["principle"].lower() or "vaporization" in gt["principle"].lower()

    @pytest.mark.physics
    def test_water_latent_heat_value(self, ground_truth):
        """Water's latent heat should be approximately 2260 kJ/kg."""
        gt = ground_truth.get("evaporative_cooling")
        if gt is None:
            pytest.skip("No evaporative_cooling oracle data")
        assert gt["latent_heat_water_kJ_kg"] == pytest.approx(2260, rel=0.05)

    @pytest.mark.physics
    def test_water_cools_more_than_oil(self, ground_truth):
        """Water evaporation should cool more than oil evaporation."""
        gt = ground_truth.get("evaporative_cooling")
        if gt is None:
            pytest.skip("No evaporative_cooling oracle data")
        assert gt["our_cooling_amount_water"] > gt["our_cooling_amount_oil"]

    @pytest.mark.physics
    def test_wet_bulb_always_lower(self, ground_truth):
        """Wet-bulb temperature must always be <= dry-bulb."""
        gt = ground_truth.get("evaporative_cooling")
        if gt is None:
            pytest.skip("No evaporative_cooling oracle data")
        assert "Twb <= Tdb" in gt["wet_bulb_depression"]
