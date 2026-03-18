"""Erosion tests: acid reactions, hardness-based erosion resistance."""

import pytest


class TestErosionResistance:
    """Elements should resist erosion proportional to hardness + corrosion res."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["stone", "metal", "glass", "wood", "dirt", "sand", "ice", "plant"],
    )
    def test_erosion_score_exists(self, ground_truth, element):
        gt = ground_truth.get("erosion_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No erosion data for {element}")
        assert "erosion_resistance_score" in entry
        assert entry["erosion_resistance_score"] >= 0

    @pytest.mark.physics
    def test_metal_most_erosion_resistant(self, ground_truth):
        gt = ground_truth.get("erosion_all", {})
        metal = gt.get("metal")
        if metal is None:
            pytest.skip("No metal erosion data")
        assert metal["rank"] == 1


class TestAcidErosion:
    """Acid should dissolve specific materials."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "target,expected_result",
        [
            ("stone", "empty"),
            ("wood", "empty"),
            ("dirt", "empty"),
            ("glass", "empty"),
            ("plant", "empty"),
            ("ice", "water"),
        ],
    )
    def test_acid_dissolves(self, ground_truth, target, expected_result):
        gt = ground_truth.get("erosion_all", {})
        entry = gt.get(target)
        if entry is None:
            pytest.skip(f"No erosion data for {target}")
        if not entry.get("acid_reactive"):
            pytest.skip(f"{target} not acid-reactive in oracle")
        assert entry["acid_result"] == expected_result

    @pytest.mark.physics
    def test_acid_probability_reasonable(self, ground_truth):
        """Acid reaction probabilities should be between 0 and 1."""
        gt = ground_truth.get("erosion_all", {})
        for name, entry in gt.items():
            if entry.get("acid_reactive"):
                prob = entry["acid_probability"]
                assert 0 < prob <= 1.0, \
                    f"{name} acid probability {prob} out of range"
