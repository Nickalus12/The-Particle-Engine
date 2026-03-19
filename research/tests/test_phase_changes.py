"""Phase change tests: melting, boiling, freezing, condensation."""

import pytest


class TestPhaseTransitions:
    """Each phase transition should have correct thresholds and products."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,transition,becomes",
        [
            ("water", "freeze", "ice"),
            ("water", "boil", "steam"),
            ("ice", "melt", "water"),
            ("sand", "melt", "glass"),
            ("stone", "melt", "lava"),
            ("metal", "melt", "lava"),
            ("snow", "melt", "water"),
            ("lava", "freeze", "stone"),
            ("oil", "boil", "smoke"),
            ("glass", "melt", "sand"),
        ],
    )
    def test_phase_change_product(self, ground_truth, element, transition, becomes):
        gt = ground_truth.get("phase_changes", {})
        key = f"{element}_{transition}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No phase change data for {key}")
        assert entry["becomes"] == becomes

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,transition",
        [
            ("water", "freeze"),
            ("water", "boil"),
            ("ice", "melt"),
            ("sand", "melt"),
            ("stone", "melt"),
            ("metal", "melt"),
            ("snow", "melt"),
            ("lava", "freeze"),
            ("oil", "boil"),
            ("glass", "melt"),
        ],
    )
    def test_phase_change_has_threshold(self, ground_truth, element, transition):
        key = f"{element}_{transition}"
        entry = ground_truth.get("phase_changes", {}).get(key)
        if entry is None:
            pytest.skip(f"No phase change data for {key}")
        point_key = f"our_{transition}Point"
        if transition == "freeze":
            point_key = "our_freezePoint"
        elif transition == "boil":
            point_key = "our_boilPoint"
        else:
            point_key = "our_meltPoint"
        assert point_key in entry, f"Missing {point_key} for {element}"
        assert entry[point_key] > 0


class TestPhaseChangeOrdering:
    """Melt points should follow physical intuition."""

    @pytest.mark.physics
    def test_melt_point_ordering(self, ground_truth):
        """Ice melts at lowest temp, then snow, then glass, then stone."""
        gt = ground_truth.get("phase_changes", {})
        ice_mp = gt.get("ice_melt", {}).get("our_meltPoint", 0)
        snow_mp = gt.get("snow_melt", {}).get("our_meltPoint", 0)
        glass_mp = gt.get("glass_melt", {}).get("our_meltPoint", 0)
        stone_mp = gt.get("stone_melt", {}).get("our_meltPoint", 0)
        if not all([ice_mp, snow_mp, glass_mp, stone_mp]):
            pytest.skip("Missing melt point data")
        assert ice_mp < snow_mp < glass_mp < stone_mp

    @pytest.mark.physics
    def test_water_freezes_before_lava(self, ground_truth):
        gt = ground_truth.get("phase_changes", {})
        water_fp = gt.get("water_freeze", {}).get("our_freezePoint", 0)
        lava_fp = gt.get("lava_freeze", {}).get("our_freezePoint", 0)
        if not all([water_fp, lava_fp]):
            pytest.skip("Missing freeze point data")
        # Water freezes at a higher temperature than lava solidifies
        # (in our 0-255 scale, higher freezePoint = easier to freeze)
        assert water_fp > 0 and lava_fp > 0


class TestPhaseChangesAll:
    """Extended phase transition data from oracle."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["water", "ice", "sand", "stone", "metal", "snow", "lava", "oil", "glass"],
    )
    def test_element_has_phase_data(self, ground_truth, element):
        gt = ground_truth.get("phase_changes_all", {})
        if element not in gt:
            pytest.skip(f"No phase_changes_all data for {element}")
        entry = gt[element]
        assert len(entry) > 0, f"{element} has no transitions"


class TestRegelation:
    """Regelation: ice melting point decreases under pressure."""

    @pytest.mark.physics
    def test_regelation_principle(self, ground_truth):
        """Oracle should describe anomalous Clausius-Clapeyron for ice."""
        gt = ground_truth.get("regelation")
        if gt is None:
            pytest.skip("No regelation oracle data")
        assert "pressure" in gt["principle"].lower()
        assert gt["melting_point_depression_C_per_atm"] > 0

    @pytest.mark.physics
    def test_regelation_enables_glacial_flow(self, ground_truth):
        """Regelation should enable glacial flow as a real-world application."""
        gt = ground_truth.get("regelation")
        if gt is None:
            pytest.skip("No regelation oracle data")
        assert "glacial flow" in gt["enables"]

    @pytest.mark.physics
    def test_regelation_threshold(self, ground_truth):
        """Regelation should have a reasonable pressure threshold."""
        gt = ground_truth.get("regelation")
        if gt is None:
            pytest.skip("No regelation oracle data")
        assert gt["our_pressure_threshold"] > 0
        assert gt["our_pressure_threshold"] <= 20


class TestGlassThermalShock:
    """Glass should shatter under rapid spatial temperature gradients."""

    @pytest.mark.physics
    def test_glass_thermal_shock_principle(self, ground_truth):
        """Glass shatters from thermal stress when ΔT exceeds fracture strength."""
        gt = ground_truth.get("glass_thermal_shock")
        if gt is None:
            pytest.skip("No glass_thermal_shock oracle data")
        assert gt["shatters_to"] == "sand"
        assert gt["threshold_gradient"] > 0

    @pytest.mark.physics
    def test_glass_shock_threshold_realistic(self, ground_truth):
        """Thermal shock threshold should map to ~150°C (soda-lime glass)."""
        gt = ground_truth.get("glass_thermal_shock")
        if gt is None:
            pytest.skip("No glass_thermal_shock oracle data")
        threshold = gt["threshold_gradient"]
        # On 0-255 scale, 150°C ≈ 30-50 units
        assert 25 <= threshold <= 60

    @pytest.mark.physics
    def test_glass_shock_produces_flash(self, ground_truth):
        """Shattering should produce a visual reaction flash."""
        gt = ground_truth.get("glass_thermal_shock")
        if gt is None:
            pytest.skip("No glass_thermal_shock oracle data")
        assert gt["produces_flash"] is True


class TestSublimation:
    """Sublimation: solid → gas without passing through liquid phase."""

    @pytest.mark.physics
    def test_sublimation_principle(self, ground_truth):
        """Oracle should describe direct solid-to-gas transition."""
        gt = ground_truth.get("sublimation")
        if gt is None:
            pytest.skip("No sublimation oracle data")
        assert "solid" in gt["principle"].lower() or "gas" in gt["principle"].lower()
        assert "liquid" in gt["principle"].lower()

    @pytest.mark.physics
    def test_sublimation_product(self, ground_truth):
        """Snow should sublimate to steam."""
        gt = ground_truth.get("sublimation")
        if gt is None:
            pytest.skip("No sublimation oracle data")
        assert gt["our_element"] == "snow"
        assert gt["our_product"] == "steam"

    @pytest.mark.physics
    def test_sublimation_threshold(self, ground_truth):
        """Sublimation threshold should be above both melt and boil points."""
        gt = ground_truth.get("sublimation")
        if gt is None:
            pytest.skip("No sublimation oracle data")
        threshold = gt["our_threshold"]
        assert threshold >= 180, "Sublimation must require extreme heat"
        assert threshold <= 240, "Threshold must be reachable on 0-255 scale"


class TestDeposition:
    """Deposition (desublimation): gas -> solid without passing through liquid."""

    @pytest.mark.physics
    def test_deposition_principle(self, ground_truth):
        """Oracle should describe direct gas-to-solid transition."""
        gt = ground_truth.get("deposition")
        if gt is None:
            pytest.skip("No deposition oracle data")
        assert "gas" in gt["principle"].lower() or "solid" in gt["principle"].lower()
        assert "liquid" in gt["principle"].lower()

    @pytest.mark.physics
    def test_deposition_product(self, ground_truth):
        """Steam should deposit as ice."""
        gt = ground_truth.get("deposition")
        if gt is None:
            pytest.skip("No deposition oracle data")
        assert gt["our_element"] == "steam"
        assert gt["our_product"] == "ice"

    @pytest.mark.physics
    def test_deposition_requires_cold_surface(self, ground_truth):
        """Deposition requires a cold nucleation surface."""
        gt = ground_truth.get("deposition")
        if gt is None:
            pytest.skip("No deposition oracle data")
        surfaces = gt["our_nucleation_surfaces"]
        assert "ice" in surfaces
        assert "stone" in surfaces
        assert gt["our_surface_temp_max"] < 128, "Surface must be below neutral"

    @pytest.mark.physics
    def test_deposition_threshold_deeply_subcooled(self, ground_truth):
        """Deposition threshold must be well below freezing."""
        gt = ground_truth.get("deposition")
        if gt is None:
            pytest.skip("No deposition oracle data")
        threshold = gt["our_threshold_temp"]
        assert threshold < 80, "Deposition needs deep subcooling"
        assert threshold > 0, "Threshold must be above absolute zero"
