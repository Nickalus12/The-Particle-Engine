"""Combustion tests: fire triangle, spread, flash points, flammability."""

import pytest


class TestFlammability:
    """Only certain elements should be flammable."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_flammable",
        [
            ("oil", True),
            ("wood", True),
            ("plant", True),
            ("seed", True),
            ("tnt", True),
            ("ant", True),
            ("water", False),
            ("stone", False),
            ("metal", False),
            ("sand", False),
            ("ice", False),
        ],
    )
    def test_flammability(self, ground_truth, element, expected_flammable):
        gt = ground_truth.get("flammable_all", {})
        if expected_flammable:
            entry = gt.get(element)
            if entry is None:
                pytest.skip(f"No flammable data for {element}")
            assert entry["flammable"] is True
        else:
            assert element not in gt or not gt[element].get("flammable", False)


class TestIgnitionEase:
    """Softer materials should ignite more easily."""

    @pytest.mark.physics
    def test_oil_ignites_easier_than_wood(self, ground_truth):
        gt = ground_truth.get("flammable_all", {})
        oil = gt.get("oil")
        wood = gt.get("wood")
        if oil is None or wood is None:
            pytest.skip("Missing flammable data")
        assert oil["ignition_ease_relative"] > wood["ignition_ease_relative"]

    @pytest.mark.physics
    def test_fire_reaction_exists(self, ground_truth):
        """Flammable elements should have fire reactions registered."""
        gt = ground_truth.get("flammable_all", {})
        for name, entry in gt.items():
            if name in ("ant",):
                continue  # ant doesn't have a direct fire->ant reaction
            assert entry["has_fire_reaction"], \
                f"{name} is flammable but has no fire reaction"


class TestArrheniusOrdering:
    """Activation energies should produce correct ignition ordering."""

    @pytest.mark.physics
    def test_arrhenius_rates_exist(self, ground_truth):
        gt = ground_truth.get("flammable_all", {})
        elements_with_arrhenius = [
            name for name, e in gt.items() if "arrhenius_rate" in e
        ]
        assert len(elements_with_arrhenius) >= 4

    @pytest.mark.physics
    def test_oil_reacts_fastest(self, ground_truth):
        """Oil has lowest activation energy, so highest rate at flame temp."""
        gt = ground_truth.get("flammable_all", {})
        oil = gt.get("oil", {})
        wood = gt.get("wood", {})
        if "arrhenius_rate" not in oil or "arrhenius_rate" not in wood:
            pytest.skip("Missing Arrhenius data")
        assert oil["arrhenius_rate"] > wood["arrhenius_rate"]


class TestLightEmission:
    """Light-emitting elements should have correct intensity ordering."""

    @pytest.mark.physics
    def test_emitting_elements_exist(self, ground_truth):
        gt = ground_truth.get("light_emission")
        if gt is None:
            pytest.skip("No light_emission oracle data")
        emitters = gt["emitting_elements"]
        assert "fire" in emitters
        assert "lava" in emitters
        assert "lightning" in emitters

    @pytest.mark.physics
    def test_lightning_brightest(self, ground_truth):
        """Lightning should be the brightest emitter."""
        gt = ground_truth.get("light_emission")
        if gt is None:
            pytest.skip("No light_emission oracle data")
        ordering = gt["ordering_by_intensity"]
        assert ordering[0] == "lightning"

    @pytest.mark.physics
    def test_lava_brighter_than_fire(self, ground_truth):
        """Lava should emit more light than fire."""
        gt = ground_truth.get("light_emission")
        if gt is None:
            pytest.skip("No light_emission oracle data")
        emitters = gt["emitting_elements"]
        assert emitters["lava"]["intensity"] > emitters["fire"]["intensity"]


class TestFireTriangle:
    """Fire requires fuel, oxygen, and heat — remove any leg and fire dies."""

    @pytest.mark.physics
    def test_fire_triangle_requirements(self, ground_truth):
        """Oracle should define the three requirements for combustion."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        reqs = gt["requirements"]
        assert "fuel" in reqs
        assert "oxygen" in reqs
        assert "heat" in reqs

    @pytest.mark.physics
    def test_fire_without_fuel_extinguishes(self, ground_truth):
        """Fire without fuel should extinguish (decay to smoke/empty)."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        behavior = gt["expected_behaviors"]["fire_without_fuel"]
        assert "extinguish" in behavior.lower()

    @pytest.mark.physics
    def test_fire_with_stone_no_ignition(self, ground_truth):
        """Stone is non-flammable and should not ignite."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        assert "unchanged" in gt["expected_behaviors"]["fire_with_stone"].lower()

    @pytest.mark.physics
    def test_flammable_materials_list(self, ground_truth):
        """Oracle should list all flammable materials."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        flammable = gt["flammable_materials"]
        assert "wood" in flammable
        assert "oil" in flammable
        assert "plant" in flammable

    @pytest.mark.physics
    def test_non_flammable_materials(self, ground_truth):
        """Non-flammable elements should not catch fire."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        non_flammable = gt["non_flammable"]
        assert "stone" in non_flammable
        assert "metal" in non_flammable
        assert "glass" in non_flammable

    @pytest.mark.physics
    def test_oil_chain_ignition(self, ground_truth):
        """Fire touching oil should cause rapid chain ignition."""
        gt = ground_truth.get("fire_triangle")
        if gt is None:
            pytest.skip("No fire_triangle oracle data")
        behavior = gt["expected_behaviors"]["fire_with_oil"]
        assert "chain" in behavior.lower() or "rapid" in behavior.lower()


class TestFlashPointOrdering:
    """Materials should ignite in order of their flash points (activation energy)."""

    @pytest.mark.physics
    def test_flash_point_ordering(self, ground_truth):
        """Oil ignites before wood (lower activation energy)."""
        gt = ground_truth.get("flash_point")
        if gt is None:
            pytest.skip("No flash_point oracle data")
        ordering = gt["expected_ordering"]
        assert ordering.index("oil") < ordering.index("wood")

    @pytest.mark.physics
    def test_arrhenius_rate_ratio(self, ground_truth):
        """Oil Arrhenius rate should be much higher than wood."""
        gt = ground_truth.get("flash_point")
        if gt is None:
            pytest.skip("No flash_point oracle data")
        ratio = gt["rate_ratio_oil_to_wood"]
        assert ratio > 100, f"Oil/wood rate ratio {ratio} too low"

    @pytest.mark.physics
    def test_activation_energies(self, ground_truth):
        """Oil should have lower activation energy than wood."""
        gt = ground_truth.get("flash_point")
        if gt is None:
            pytest.skip("No flash_point oracle data")
        assert gt["Ea_oil_J_per_mol"] < gt["Ea_wood_J_per_mol"]


class TestFireCycle:
    """Fire should follow a predictable combustion cycle."""

    @pytest.mark.physics
    def test_fire_cycle_stages(self, ground_truth):
        gt = ground_truth.get("fire_cycle")
        if gt is None:
            pytest.skip("No fire_cycle oracle data")
        stages = gt["stages"]
        assert stages == ["wood", "fire", "smoke"]

    @pytest.mark.physics
    def test_fire_spread_consistency(self, ground_truth):
        """Fire should spread at roughly constant velocity in uniform fuel."""
        gt = ground_truth.get("fire_spread")
        if gt is None:
            pytest.skip("No fire_spread oracle data")
        assert gt["expected_cv_below"] <= 0.5


class TestDecayChains:
    """Elements should decay through predictable chains."""

    @pytest.mark.physics
    def test_fire_decay_chain(self, ground_truth):
        gt = ground_truth.get("decay_chains")
        if gt is None:
            pytest.skip("No decay_chains oracle data")
        fire = gt.get("fire")
        assert fire is not None
        assert fire["chain"] == ["fire", "smoke", "empty"]

    @pytest.mark.physics
    def test_steam_condenses_to_water(self, ground_truth):
        gt = ground_truth.get("decay_chains")
        if gt is None:
            pytest.skip("No decay_chains oracle data")
        steam = gt.get("steam")
        assert steam is not None
        assert steam["final_product"] == "water"

    @pytest.mark.physics
    def test_decay_rates_positive(self, ground_truth):
        gt = ground_truth.get("decay_chains")
        if gt is None:
            pytest.skip("No decay_chains oracle data")
        for name, chain in gt.items():
            assert chain["decay_rate_frames"] > 0, \
                f"{name} has non-positive decay rate"
            assert chain["half_life_frames"] > 0, \
                f"{name} has non-positive half life"


class TestExplosionFalloff:
    """Explosion energy should follow inverse square law."""

    @pytest.mark.physics
    def test_inverse_square_law(self, ground_truth):
        gt = ground_truth.get("explosion_falloff")
        if gt is None:
            pytest.skip("No explosion_falloff oracle data")
        distances = gt["distances"]
        ratios = gt["expected_energy_ratio"]
        for d, r in zip(distances, ratios):
            expected = 1.0 / (d * d)
            assert r == pytest.approx(expected, rel=0.01)

    @pytest.mark.physics
    def test_energy_decreases_with_distance(self, ground_truth):
        gt = ground_truth.get("explosion_falloff")
        if gt is None:
            pytest.skip("No explosion_falloff oracle data")
        ratios = gt["expected_energy_ratio"]
        for i in range(1, len(ratios)):
            assert ratios[i] < ratios[i - 1]


class TestSmokeBuoyancy:
    """Smoke rise rate should be modulated by thermal buoyancy."""

    @pytest.mark.physics
    def test_smoke_buoyancy_principle(self, ground_truth):
        """Oracle should describe Archimedes-driven smoke rise."""
        gt = ground_truth.get("smoke_buoyancy")
        if gt is None:
            pytest.skip("No smoke_buoyancy oracle data")
        assert "buoyancy" in gt["principle"].lower()
        assert "archimedes" in gt["archimedes_formula"].lower() or "rho" in gt["archimedes_formula"]

    @pytest.mark.physics
    def test_hot_smoke_rises_fast(self, ground_truth):
        """Hot smoke should have vigorous vertical rise."""
        gt = ground_truth.get("smoke_buoyancy")
        if gt is None:
            pytest.skip("No smoke_buoyancy oracle data")
        assert "vertical" in gt["behavior_hot"].lower()

    @pytest.mark.physics
    def test_cool_smoke_spreads(self, ground_truth):
        """Cool smoke should spread laterally."""
        gt = ground_truth.get("smoke_buoyancy")
        if gt is None:
            pytest.skip("No smoke_buoyancy oracle data")
        assert "lateral" in gt["behavior_cool"].lower() or "spread" in gt["behavior_cool"].lower()


class TestTNTDetonation:
    """TNT detonation: thermal auto-ignition and sympathetic detonation."""

    @pytest.mark.physics
    def test_tnt_detonation_principle(self, ground_truth):
        """Oracle should describe thermal and sympathetic detonation."""
        gt = ground_truth.get("tnt_detonation")
        if gt is None:
            pytest.skip("No tnt_detonation oracle data")
        assert "auto-ignition" in gt["principle"].lower() or "thermal" in gt["principle"].lower()
        assert "sympathetic" in gt["principle"].lower()

    @pytest.mark.physics
    def test_auto_ignition_temperature(self, ground_truth):
        """Auto-ignition threshold should be in high temperature range."""
        gt = ground_truth.get("tnt_detonation")
        if gt is None:
            pytest.skip("No tnt_detonation oracle data")
        threshold = gt["our_auto_ignition_temp"]
        assert 180 <= threshold <= 240

    @pytest.mark.physics
    def test_detonation_velocity_fast(self, ground_truth):
        """Real TNT detonation velocity should be very high."""
        gt = ground_truth.get("tnt_detonation")
        if gt is None:
            pytest.skip("No tnt_detonation oracle data")
        assert gt["detonation_velocity_m_s"] > 5000
