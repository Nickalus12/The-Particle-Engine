"""Structural tests: hardness, structural scores, solid element properties, live sim."""

import numpy as np
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


class TestLiveStructuralBehavior:
    """Verify structural behavior in actual simulation frame."""

    @pytest.mark.physics
    def test_supported_stone_holds(self, simulation_frame):
        """Stone at ground level should remain in place (supported)."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        stone_id = elements.get("Stone")
        if stone_id is None:
            pytest.skip("No Stone element")
        stone_count = int((grid == stone_id).sum())
        assert stone_count > 100, (
            f"Only {stone_count} stone cells, expected ground base to be intact"
        )

    @pytest.mark.physics
    def test_metal_beam_intact(self, simulation_frame):
        """Metal beam placed in test world should still be present."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        metal_id = elements.get("Metal")
        if metal_id is None:
            pytest.skip("No Metal element")
        metal_count = int((grid == metal_id).sum())
        assert metal_count > 0, "Metal beam should still be present"

    @pytest.mark.physics
    def test_wood_trees_present(self, simulation_frame):
        """Wood (trees) placed in test world should still be standing."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        wood_id = elements.get("Wood")
        if wood_id is None:
            pytest.skip("No Wood element")
        wood_count = int((grid == wood_id).sum())
        assert wood_count > 0, "Wood structures should still be present"

    @pytest.mark.physics
    def test_glass_present(self, simulation_frame):
        """Glass placed in test world should still be present (solid, doesn't fall)."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        glass_id = elements.get("Glass")
        if glass_id is None:
            pytest.skip("No Glass element")
        glass_count = int((grid == glass_id).sum())
        assert glass_count > 0, "Glass should still be present"

    @pytest.mark.physics
    def test_solids_below_midline(self, simulation_frame):
        """Solid structural elements should be in the lower half (ground area)."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        solid_names = ["Stone", "Metal", "Glass", "Ice", "Wood"]
        for name in solid_names:
            el_id = elements.get(name)
            if el_id is None:
                continue
            positions = np.where(grid == el_id)
            if len(positions[0]) == 0:
                continue
            avg_y = float(np.mean(positions[0]))
            assert avg_y > 60, (
                f"{name} avg_y={avg_y:.1f}, expected in lower portion (>60)"
            )


class TestStructuralIntegrity:
    """Structural elements should maintain integrity under simulation."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,min_hardness",
        [
            ("metal", 90),
            ("stone", 70),
            ("glass", 60),
            ("wood", 40),
            ("ice", 30),
        ],
    )
    def test_hardness_minimum(self, ground_truth, element, min_hardness):
        """Each structural element should meet minimum hardness threshold."""
        gt = ground_truth.get("structural_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No structural data for {element}")
        assert entry["hardness"] >= min_hardness, (
            f"{element} hardness {entry['hardness']} below minimum {min_hardness}"
        )

    @pytest.mark.physics
    def test_corrosion_resistance_ordering(self, ground_truth):
        """Metal > Stone > Glass > Ice > Wood in corrosion resistance."""
        gt = ground_truth.get("structural_all", {})
        order = ["metal", "stone", "glass", "ice", "wood"]
        values = []
        for el in order:
            entry = gt.get(el)
            if entry is None:
                pytest.skip(f"No structural data for {el}")
            values.append(entry["corrosion_resistance"])
        for i in range(len(values) - 1):
            assert values[i] >= values[i + 1], (
                f"{order[i]} corrosion_resistance ({values[i]}) should be >= "
                f"{order[i+1]} ({values[i+1]})"
            )
