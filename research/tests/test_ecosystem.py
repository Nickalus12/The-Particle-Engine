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
        dc = ground_truth.get("decay_chains", {})
        chain_data = dc.get(element)
        assert chain_data is not None, f"No decay chain for {element}"
        chain = chain_data["chain"]
        # The element should decay into the expected product (next in chain)
        assert len(chain) >= 2, f"{element} chain too short: {chain}"
        assert chain[1] == expected_decay, (
            f"{element} should decay to {expected_decay}, "
            f"got chain: {chain}"
        )


class TestWaterCycleReaction:
    """Water becomes steam when heated, steam rises and may condense."""

    @pytest.mark.physics
    def test_water_cycle_stages(self, ground_truth):
        gt = ground_truth.get("water_cycle_reaction")
        if gt is None:
            pytest.skip("No water_cycle_reaction oracle data")
        stages = gt["stages"]
        assert "water" in stages
        assert "steam" in stages

    @pytest.mark.physics
    def test_water_cycle_trigger(self, ground_truth):
        gt = ground_truth.get("water_cycle_reaction")
        if gt is None:
            pytest.skip("No water_cycle_reaction oracle data")
        assert "lava" in gt["trigger"].lower() or "fire" in gt["trigger"].lower()

    @pytest.mark.physics
    def test_water_cycle_max_frames(self, ground_truth):
        gt = ground_truth.get("water_cycle_reaction")
        if gt is None:
            pytest.skip("No water_cycle_reaction oracle data")
        assert gt["max_frames"] > 0
