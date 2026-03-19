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


class TestElectricalConductivity:
    """Conductive elements should have correct ordering."""

    @pytest.mark.physics
    def test_metal_best_conductor(self, ground_truth):
        gt = ground_truth.get("electrical_conductivity")
        if gt is None:
            pytest.skip("No electrical_conductivity oracle data")
        ordering = gt["ordering"]
        assert ordering[0] == "metal"

    @pytest.mark.physics
    def test_water_conducts(self, ground_truth):
        gt = ground_truth.get("electrical_conductivity")
        if gt is None:
            pytest.skip("No electrical_conductivity oracle data")
        conductors = gt["conducting_elements"]
        assert "water" in conductors
        assert conductors["water"] > 0

    @pytest.mark.physics
    def test_non_conductors(self, ground_truth):
        """Non-metallic solids should not conduct electricity."""
        gt = ground_truth.get("electrical_conductivity")
        if gt is None:
            pytest.skip("No electrical_conductivity oracle data")
        non_cond = gt["non_conductors"]
        for el in ["stone", "wood", "glass", "sand"]:
            assert el in non_cond, f"{el} should be non-conductive"


class TestClockBit:
    """Clock-bit system prevents double simulation of elements per step."""

    @pytest.mark.physics
    def test_clock_bit_mask(self, ground_truth):
        """Clock bit should use bit 7 (mask 128)."""
        gt = ground_truth.get("clock_bit")
        if gt is None:
            pytest.skip("No clock_bit oracle data")
        assert gt["clock_mask"] == 128

    @pytest.mark.physics
    def test_clock_bit_principle(self, ground_truth):
        """Each element should be processed exactly once per step."""
        gt = ground_truth.get("clock_bit")
        if gt is None:
            pytest.skip("No clock_bit oracle data")
        assert "once" in gt["principle"].lower()


class TestMomentumSymmetry:
    """Symmetric initial conditions should produce symmetric results."""

    @pytest.mark.physics
    def test_symmetric_drop_principle(self, ground_truth):
        """Two identical elements at symmetric positions should land symmetrically."""
        gt = ground_truth.get("momentum_symmetry")
        if gt is None:
            pytest.skip("No momentum_symmetry oracle data")
        assert gt["max_allowed_asymmetry"] == 0
