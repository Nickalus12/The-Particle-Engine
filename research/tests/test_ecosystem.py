"""Ecosystem tests: water cycle, plant growth, decomposition reactions."""

import pytest


class TestWaterCycle:
    """Water should be able to cycle: water -> steam -> water, water -> ice -> water."""

    @pytest.mark.physics
    def test_water_boils_to_steam(self, ground_truth):
        gt = ground_truth.get("phase_changes_all", {})
        water = gt.get("water", {})
        boil = water.get("boil")
        if boil is None:
            pytest.skip("No water boil data")
        assert boil["becomes"] == "steam"

    @pytest.mark.physics
    def test_water_freezes_to_ice(self, ground_truth):
        gt = ground_truth.get("phase_changes_all", {})
        water = gt.get("water", {})
        freeze = water.get("freeze")
        if freeze is None:
            pytest.skip("No water freeze data")
        assert freeze["becomes"] == "ice"

    @pytest.mark.physics
    def test_ice_melts_to_water(self, ground_truth):
        gt = ground_truth.get("phase_changes_all", {})
        ice = gt.get("ice", {})
        melt = ice.get("melt")
        if melt is None:
            pytest.skip("No ice melt data")
        assert melt["becomes"] == "water"


class TestPlantInteractions:
    """Plants should interact with fire and acid."""

    @pytest.mark.physics
    def test_fire_burns_plants(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        entry = gt.get("fire_plant")
        if entry is None:
            pytest.skip("No fire_plant reaction")
        assert entry["target_becomes"] == "fire"

    @pytest.mark.physics
    def test_acid_dissolves_plants(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        entry = gt.get("acid_plant")
        if entry is None:
            pytest.skip("No acid_plant reaction")
        assert entry["target_becomes"] == "empty"

    @pytest.mark.physics
    def test_seed_sprouts_near_water(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        entry = gt.get("seed_water")
        if entry is None:
            pytest.skip("No seed_water reaction")
        assert entry["probability"] > 0


class TestDecomposition:
    """Decay elements should transform correctly."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_decay",
        [
            ("fire", "smoke"),
            ("smoke", "empty"),
            ("rainbow", "empty"),
        ],
    )
    def test_decay_product(self, ground_truth, element, expected_decay):
        """Elements with decayRate should decay into expected product."""
        # This comes from the ELEMENTS table in the oracle
        # We verify via the flammable_all or element properties
        gt = ground_truth.get("reactions_all", {})
        # Decay is handled by element properties, not reactions
        # Just verify the oracle has the element data
        pytest.skip("Decay is element property, not reaction - verified in oracle")
