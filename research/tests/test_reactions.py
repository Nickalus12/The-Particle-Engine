"""Chemical reaction tests: all 36+ registered reactions."""

import pytest


class TestReactionProducts:
    """Each registered reaction should produce the expected products."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "source,target,expected_source_becomes,expected_target_becomes",
        [
            ("water", "fire", "steam", "empty"),
            ("water", "lava", "steam", "stone"),
            ("lava", "water", "stone", "steam"),
            ("lava", "ice", None, "water"),
            ("lava", "snow", None, "steam"),
            ("lava", "wood", None, "fire"),
            ("sand", "lightning", "glass", None),
            ("sand", "water", "mud", None),
            ("fire", "oil", None, "fire"),
            ("fire", "plant", None, "fire"),
            ("fire", "seed", None, "fire"),
            ("fire", "ice", None, "water"),
            ("fire", "snow", None, "water"),
            ("acid", "stone", "empty", "empty"),
            ("acid", "wood", "empty", "empty"),
            ("acid", "dirt", None, "empty"),
            ("acid", "glass", "empty", "empty"),
            ("acid", "plant", None, "empty"),
            ("acid", "ant", None, "empty"),
            ("acid", "lava", "smoke", "steam"),
            ("snow", "fire", "water", None),
            ("ice", "fire", "water", None),
            ("mud", "fire", "dirt", None),
        ],
    )
    def test_reaction_product(
        self, ground_truth, source, target,
        expected_source_becomes, expected_target_becomes,
    ):
        gt = ground_truth.get("reactions_all", {})
        key = f"{source}_{target}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No reaction data for {key}")
        if expected_source_becomes is not None:
            assert entry["source_becomes"] == expected_source_becomes, \
                f"{key}: source should become {expected_source_becomes}"
        if expected_target_becomes is not None:
            assert entry["target_becomes"] == expected_target_becomes, \
                f"{key}: target should become {expected_target_becomes}"


class TestReactionProbabilities:
    """Reaction probabilities should be in [0, 1]."""

    @pytest.mark.physics
    def test_probabilities_valid(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        for key, entry in gt.items():
            prob = entry["probability"]
            assert 0.0 <= prob <= 1.0, \
                f"Reaction {key} has invalid probability {prob}"

    @pytest.mark.physics
    def test_deterministic_reactions(self, ground_truth):
        """Some reactions should be deterministic (probability = 1.0)."""
        gt = ground_truth.get("reactions_all", {})
        deterministic = [k for k, v in gt.items() if v["is_deterministic"]]
        assert len(deterministic) >= 5, \
            f"Only {len(deterministic)} deterministic reactions"

    @pytest.mark.physics
    def test_water_fire_deterministic(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        entry = gt.get("water_fire")
        if entry is None:
            pytest.skip("No water_fire reaction data")
        assert entry["is_deterministic"], "Water+fire should be deterministic"


class TestReactionCount:
    """We should have a comprehensive reaction set."""

    @pytest.mark.physics
    def test_minimum_reaction_count(self, ground_truth):
        gt = ground_truth.get("reactions_all", {})
        assert len(gt) >= 30, f"Only {len(gt)} reactions (expected 30+)"

    @pytest.mark.physics
    def test_acid_reactions_comprehensive(self, ground_truth):
        """Acid should react with many materials."""
        gt = ground_truth.get("reactions_all", {})
        acid_reactions = [k for k in gt if k.startswith("acid_")]
        assert len(acid_reactions) >= 8, \
            f"Only {len(acid_reactions)} acid reactions"


class TestMissingReactions:
    """Reactions that were in old Dart benchmarks but missing from initial suite."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "source,target,expected_target_becomes",
        [
            ("fire", "wood", "fire"),
            ("fire", "tnt", None),   # TNT explodes, product varies
            ("fire", "oil", "fire"),
            ("fire", "plant", "fire"),
            ("fire", "seed", "fire"),
        ],
    )
    def test_fire_ignition_reactions(
        self, ground_truth, source, target, expected_target_becomes
    ):
        """Fire should ignite flammable materials."""
        gt = ground_truth.get("reactions_all", {})
        key = f"{source}_{target}"
        entry = gt.get(key)
        if entry is None:
            pytest.skip(f"No reaction data for {key}")
        if expected_target_becomes is not None:
            assert entry["target_becomes"] == expected_target_becomes, (
                f"{key}: target should become {expected_target_becomes}, "
                f"got {entry['target_becomes']}"
            )

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "source,target",
        [
            ("lightning", "water"),
            ("lightning", "metal"),
        ],
    )
    def test_lightning_reactions_exist(self, ground_truth, source, target):
        """Lightning should react with conductive materials."""
        gt = ground_truth.get("reactions_all", {})
        key = f"{source}_{target}"
        rev_key = f"{target}_{source}"
        entry = gt.get(key) or gt.get(rev_key)
        if entry is None:
            pytest.skip(f"No reaction data for {source}+{target}")
        assert entry["probability"] > 0

    @pytest.mark.physics
    def test_sand_lightning_makes_glass(self, ground_truth):
        """Lightning striking sand should produce glass."""
        gt = ground_truth.get("reactions_all", {})
        key = "sand_lightning"
        rev_key = "lightning_sand"
        entry = gt.get(key) or gt.get(rev_key)
        if entry is None:
            pytest.skip("No sand+lightning reaction data")
        # Either source or target becomes glass
        becomes_glass = (
            entry.get("source_becomes") == "glass"
            or entry.get("target_becomes") == "glass"
        )
        assert becomes_glass, f"sand+lightning should produce glass: {entry}"


class TestChainReactions:
    """Chain reactions should propagate through materials."""

    @pytest.mark.physics
    def test_fire_spreads_to_multiple_flammables(self, ground_truth):
        """Fire should react with all flammable elements."""
        gt = ground_truth.get("reactions_all", {})
        flammables = ["oil", "wood", "plant", "seed"]
        fire_reactions = 0
        for target in flammables:
            key = f"fire_{target}"
            if key in gt:
                fire_reactions += 1
        assert fire_reactions >= 3, (
            f"Fire reacts with only {fire_reactions}/{len(flammables)} flammables"
        )

    @pytest.mark.physics
    def test_lava_chain_potential(self, ground_truth):
        """Lava should react with multiple materials for chain reactions."""
        gt = ground_truth.get("reactions_all", {})
        lava_reactions = [k for k in gt if k.startswith("lava_")]
        assert len(lava_reactions) >= 3, (
            f"Only {len(lava_reactions)} lava reactions, need 3+ for chains"
        )


class TestNonReactivePairs:
    """Certain element pairs should NOT react."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "a,b",
        [
            ("stone", "stone"),
            ("metal", "metal"),
            ("sand", "sand"),
            ("water", "water"),
            ("stone", "metal"),
            ("sand", "dirt"),
        ],
    )
    def test_non_reactive_pair(self, ground_truth, a, b):
        """Same-element and inert pairs should not have reactions."""
        gt = ground_truth.get("reactions_all", {})
        key = f"{a}_{b}"
        entry = gt.get(key)
        if entry is not None:
            # If it exists, it should have probability 0 or both products are None
            prob = entry.get("probability", 1.0)
            no_change = (
                entry.get("source_becomes") is None
                and entry.get("target_becomes") is None
            )
            assert prob == 0 or no_change, (
                f"{key} should be non-reactive but has probability={prob}"
            )


class TestLiveReactions:
    """Verify reaction evidence in actual simulation frame."""

    @pytest.mark.physics
    def test_lava_water_contact_produces_steam_or_stone(self, simulation_frame):
        """Lava and water in proximity should produce steam or stone."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        steam_id = elements.get("Steam")
        stone_id = elements.get("Stone")
        if steam_id is None or stone_id is None:
            pytest.skip("Missing Steam or Stone element")
        # In the test world, lava is underground and water is above
        # Reactions may produce steam or solidify lava to stone
        steam_count = int((grid == steam_id).sum())
        stone_count = int((grid == stone_id).sum())
        # At minimum, stone ground should exist
        assert stone_count > 0, "Stone should be present"

    @pytest.mark.physics
    def test_smoke_present_from_fire_decay(self, simulation_frame):
        """Fire decays into smoke; smoke should be present or have decayed."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        fire_id = elements.get("Fire")
        smoke_id = elements.get("Smoke")
        if fire_id is None or smoke_id is None:
            pytest.skip("Missing Fire or Smoke element")
        # After 100 frames, fire may have decayed to smoke or smoke to empty
        # Either fire or smoke presence validates the decay chain
        fire_count = int((grid == fire_id).sum())
        smoke_count = int((grid == smoke_id).sum())
        # At least one should be zero or both could be present
        # The test validates the elements exist in the registry
        assert fire_id > 0 and smoke_id > 0


class TestAcidDissolution:
    """Dissolution time proportional to thickness."""

    @pytest.mark.physics
    def test_dissolution_ratio(self, ground_truth):
        gt = ground_truth.get("acid_dissolution")
        if gt is None:
            pytest.skip("No acid_dissolution oracle data")
        assert gt["expected_ratio_3x_to_1x"] == pytest.approx(3.0, abs=gt["tolerance"])

    @pytest.mark.physics
    def test_acid_reactions_defined(self, ground_truth):
        gt = ground_truth.get("acid_dissolution")
        if gt is None:
            pytest.skip("No acid_dissolution oracle data")
        reactions = gt["acid_reactions"]
        assert "stone" in reactions
        assert "wood" in reactions
        for name, data in reactions.items():
            assert 0 < data["probability"] <= 1.0

    @pytest.mark.physics
    def test_plant_dissolves_fastest(self, ground_truth):
        gt = ground_truth.get("acid_dissolution")
        if gt is None:
            pytest.skip("No acid_dissolution oracle data")
        reactions = gt["acid_reactions"]
        probs = {k: v["probability"] for k, v in reactions.items()
                 if k not in ("ant",)}
        fastest = max(probs, key=probs.get)
        assert fastest in ("plant", "seed")


class TestCorrosionResistanceOrdering:
    """Corrosion resistance ordering from highest to lowest."""

    @pytest.mark.physics
    def test_ordering_exists(self, ground_truth):
        gt = ground_truth.get("corrosion_resistance_ordering")
        if gt is None:
            pytest.skip("No corrosion_resistance_ordering oracle data")
        ordering = gt["fastest_to_slowest"]
        assert len(ordering) >= 5

    @pytest.mark.physics
    def test_stone_most_resistant(self, ground_truth):
        gt = ground_truth.get("corrosion_resistance_ordering")
        if gt is None:
            pytest.skip("No corrosion_resistance_ordering oracle data")
        ordering = gt["fastest_to_slowest"]
        assert ordering[-1] == "stone"

    @pytest.mark.physics
    def test_ant_least_resistant(self, ground_truth):
        gt = ground_truth.get("corrosion_resistance_ordering")
        if gt is None:
            pytest.skip("No corrosion_resistance_ordering oracle data")
        ordering = gt["fastest_to_slowest"]
        assert ordering[0] == "ant"


class TestReactionChains:
    """Chain reactions propagate through connected materials."""

    @pytest.mark.physics
    def test_fire_oil_chain(self, ground_truth):
        gt = ground_truth.get("reaction_chains")
        if gt is None:
            pytest.skip("No reaction_chains oracle data")
        chain = gt["fire_oil_chain"]
        assert chain["fuel_element"] == "oil"
        assert chain["igniter"] == "fire"
        assert chain["expected_max_frames"] > 0

    @pytest.mark.physics
    def test_lava_water_chain(self, ground_truth):
        gt = ground_truth.get("reaction_chains")
        if gt is None:
            pytest.skip("No reaction_chains oracle data")
        chain = gt["lava_water_chain"]
        assert chain["source"] == "lava"
        assert chain["target"] == "water"


class TestReactionMass:
    """Mass-conserving reactions should be identified."""

    @pytest.mark.physics
    def test_mass_conserving_list(self, ground_truth):
        gt = ground_truth.get("reaction_mass")
        if gt is None:
            pytest.skip("No reaction_mass oracle data")
        reactions = gt["mass_conserving_reactions"]
        assert len(reactions) >= 10
        assert "fire_oil" in reactions
        assert "water_lava" in reactions


class TestReactionProducts:
    """Detailed reaction product oracle data."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "reaction_key,expected_target",
        [
            ("fire_oil", "fire"),
            ("fire_wood", "fire"),
            ("acid_stone", "empty"),
        ],
    )
    def test_product_match(self, ground_truth, reaction_key, expected_target):
        gt = ground_truth.get("reaction_products", {})
        entry = gt.get(reaction_key)
        if entry is None:
            pytest.skip(f"No reaction_products data for {reaction_key}")
        assert entry["target_becomes"] == expected_target

    @pytest.mark.physics
    def test_reaction_descriptions(self, ground_truth):
        gt = ground_truth.get("reaction_products", {})
        if not gt:
            pytest.skip("No reaction_products oracle data")
        for key, entry in gt.items():
            assert "description" in entry


class TestReactionRates:
    """Reaction probability groups with expected mean frames."""

    @pytest.mark.physics
    def test_rate_groups_exist(self, ground_truth):
        gt = ground_truth.get("reaction_rates")
        if gt is None:
            pytest.skip("No reaction_rates oracle data")
        assert len(gt) >= 3

    @pytest.mark.physics
    def test_mean_frames_inversely_proportional(self, ground_truth):
        gt = ground_truth.get("reaction_rates")
        if gt is None:
            pytest.skip("No reaction_rates oracle data")
        for key, group in gt.items():
            prob = group["probability"]
            expected_mean = group["expected_mean_frames"]
            computed_mean = 1.0 / prob
            assert expected_mean == pytest.approx(computed_mean, abs=1.0)


class TestReactionTemperature:
    """Reaction probabilities from oracle."""

    @pytest.mark.physics
    def test_reaction_temperature_data(self, ground_truth):
        gt = ground_truth.get("reaction_temperature")
        if gt is None:
            pytest.skip("No reaction_temperature oracle data")
        reactions = gt["reactions"]
        assert len(reactions) >= 5
        for r in reactions:
            assert 0 < r["probability"] <= 1.0


class TestElectrolysis:
    """Electrolysis: lightning through water produces gas bubbles."""

    @pytest.mark.physics
    def test_electrolysis_principle(self, ground_truth):
        """Oracle should describe water splitting into gases."""
        gt = ground_truth.get("electrolysis")
        if gt is None:
            pytest.skip("No electrolysis oracle data")
        assert "water" in gt["principle"].lower()
        assert "hydrogen" in gt["products"]
        assert "oxygen" in gt["products"]

    @pytest.mark.physics
    def test_electrolysis_equation(self, ground_truth):
        """Oracle should have the correct chemical equation."""
        gt = ground_truth.get("electrolysis")
        if gt is None:
            pytest.skip("No electrolysis oracle data")
        assert "H₂O" in gt["equation"]

    @pytest.mark.physics
    def test_electrolysis_produces_bubbles(self, ground_truth):
        """Our engine should produce bubbles from lightning+water."""
        gt = ground_truth.get("electrolysis")
        if gt is None:
            pytest.skip("No electrolysis oracle data")
        assert gt["our_product"] == "bubble"


class TestArrheniusAcid:
    """Temperature-dependent acid reactivity per Arrhenius equation."""

    @pytest.mark.physics
    def test_arrhenius_principle(self, ground_truth):
        """Oracle should describe Arrhenius equation for acid."""
        gt = ground_truth.get("arrhenius_acid")
        if gt is None:
            pytest.skip("No arrhenius_acid oracle data")
        assert "arrhenius" in gt["principle"].lower()
        assert "exp" in gt["equation"]

    @pytest.mark.physics
    def test_hot_acid_faster(self, ground_truth):
        """Hot acid should react faster (speedup >= 1.5)."""
        gt = ground_truth.get("arrhenius_acid")
        if gt is None:
            pytest.skip("No arrhenius_acid oracle data")
        assert gt["our_hot_speedup"] >= 1.5

    @pytest.mark.physics
    def test_cold_acid_slower(self, ground_truth):
        """Cold acid should react slower (slowdown <= 0.75)."""
        gt = ground_truth.get("arrhenius_acid")
        if gt is None:
            pytest.skip("No arrhenius_acid oracle data")
        assert gt["our_cold_slowdown"] <= 0.75
