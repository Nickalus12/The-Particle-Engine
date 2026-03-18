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
