"""Structural tests: hardness, structural scores, solid element properties."""

import pytest


class TestStructuralProperties:
    """Solid elements should have correct structural ranking."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["stone", "metal", "glass", "ice", "wood"],
    )
    def test_solid_has_structural_data(self, ground_truth, element):
        gt = ground_truth.get("structural_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No structural data for {element}")
        assert "hardness" in entry
        assert "structural_score" in entry
        assert entry["structural_score"] > 0

    @pytest.mark.physics
    def test_metal_strongest(self, ground_truth):
        """Metal should have the highest structural score."""
        gt = ground_truth.get("structural_all", {})
        if not gt:
            pytest.skip("No structural data")
        metal = gt.get("metal")
        if metal is None:
            pytest.skip("No metal structural data")
        assert metal["rank"] == 1

    @pytest.mark.physics
    def test_hardness_ordering(self, ground_truth):
        """Metal > stone > glass > wood > ice in hardness."""
        gt = ground_truth.get("structural_all", {})
        elements = ["metal", "stone", "glass", "wood", "ice"]
        hardnesses = []
        for el in elements:
            entry = gt.get(el)
            if entry is None:
                pytest.skip(f"No structural data for {el}")
            hardnesses.append(entry["hardness"])
        for i in range(len(hardnesses) - 1):
            assert hardnesses[i] >= hardnesses[i + 1], \
                f"{elements[i]} should be harder than {elements[i+1]}"


class TestCorrosionResistance:
    """Elements should have varying corrosion resistance."""

    @pytest.mark.physics
    def test_metal_most_corrosion_resistant(self, ground_truth):
        gt = ground_truth.get("structural_all", {})
        metal = gt.get("metal")
        if metal is None:
            pytest.skip("No metal data")
        assert metal["corrosion_resistance"] >= 80

    @pytest.mark.physics
    def test_wood_low_corrosion_resistance(self, ground_truth):
        gt = ground_truth.get("structural_all", {})
        wood = gt.get("wood")
        if wood is None:
            pytest.skip("No wood data")
        assert wood["corrosion_resistance"] <= 40
