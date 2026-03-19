"""Erosion tests: acid reactions, hardness-based erosion resistance, live sim."""

import numpy as np
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


class TestPorosity:
    """Porous materials should absorb water at rates proportional to porosity."""

    @pytest.mark.physics
    def test_porous_elements_defined(self, ground_truth):
        gt = ground_truth.get("porosity")
        if gt is None:
            pytest.skip("No porosity oracle data")
        porous = gt["porous_elements"]
        assert "sand" in porous
        assert "dirt" in porous
        assert "mud" in porous

    @pytest.mark.physics
    def test_dirt_most_porous(self, ground_truth):
        """Dirt should have highest porosity (most water absorption)."""
        gt = ground_truth.get("porosity")
        if gt is None:
            pytest.skip("No porosity oracle data")
        ordering = gt["ordering"]
        assert ordering[0] == "dirt"

    @pytest.mark.physics
    def test_porosity_ordering(self, ground_truth):
        """Porosity ordering: dirt > mud > sand > wood > plant."""
        gt = ground_truth.get("porosity")
        if gt is None:
            pytest.skip("No porosity oracle data")
        porous = gt["porous_elements"]
        assert porous["dirt"] > porous["mud"]
        assert porous["mud"] > porous["sand"]
        assert porous["sand"] > porous["wood"]


class TestLiveErosion:
    """Verify erosion behavior in actual simulation frame."""

    @pytest.mark.physics
    def test_water_and_dirt_coexist(self, simulation_frame):
        """Water and dirt are both present in the test world for erosion potential."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        water_id = elements.get("Water")
        dirt_id = elements.get("Dirt")
        if water_id is None or dirt_id is None:
            pytest.skip("Missing Water or Dirt")
        water_count = int((grid == water_id).sum())
        dirt_count = int((grid == dirt_id).sum())
        assert water_count > 0, "Water should be present for erosion"
        assert dirt_count > 0, "Dirt should be present for erosion"

    @pytest.mark.physics
    def test_dirt_near_water_surface(self, simulation_frame):
        """Dirt and water should be in proximity (water pool meets dirt ground)."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        water_id = elements.get("Water")
        dirt_id = elements.get("Dirt")
        if water_id is None or dirt_id is None:
            pytest.skip("Missing Water or Dirt")
        water_ys = np.where(grid == water_id)[0]
        dirt_ys = np.where(grid == dirt_id)[0]
        if len(water_ys) == 0 or len(dirt_ys) == 0:
            pytest.skip("Not enough water or dirt")
        # Water and dirt should overlap in y-range (adjacent layers)
        water_max_y = int(water_ys.max())
        dirt_min_y = int(dirt_ys.min())
        gap = dirt_min_y - water_max_y
        assert gap < 10, (
            f"Water-dirt gap is {gap} rows; they should be adjacent for erosion"
        )


class TestErosionResistanceOrdering:
    """Erosion resistance should correlate with hardness."""

    @pytest.mark.physics
    def test_erosion_ordering(self, ground_truth):
        """Metal > stone > glass > wood > dirt in erosion resistance."""
        gt = ground_truth.get("erosion_all", {})
        order = ["metal", "stone", "glass", "wood", "dirt"]
        scores = []
        for el in order:
            entry = gt.get(el)
            if entry is None:
                pytest.skip(f"No erosion data for {el}")
            scores.append(entry["erosion_resistance_score"])
        for i in range(len(scores) - 1):
            assert scores[i] >= scores[i + 1], (
                f"{order[i]} erosion_resistance ({scores[i]}) should be >= "
                f"{order[i+1]} ({scores[i+1]})"
            )

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["stone", "metal", "glass", "wood", "dirt", "sand", "ice", "plant"],
    )
    def test_erosion_resistance_positive(self, ground_truth, element):
        """All erodable elements should have a positive erosion resistance score."""
        gt = ground_truth.get("erosion_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No erosion data for {element}")
        assert entry["erosion_resistance_score"] > 0


class TestSedimentDeposition:
    """Eroded material should deposit as sediment."""

    @pytest.mark.physics
    def test_mud_exists_in_world(self, simulation_frame):
        """Mud (sand+water product) may form where water meets sand."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        mud_id = elements.get("Mud")
        if mud_id is None:
            pytest.skip("No Mud element")
        # Mud can form from sand+water reaction; just verify the element exists
        # in the element registry
        assert mud_id > 0

    @pytest.mark.physics
    def test_acid_produces_empty(self, ground_truth):
        """Acid dissolving materials should produce empty cells (material removed)."""
        gt = ground_truth.get("erosion_all", {})
        for name in ["stone", "wood", "dirt"]:
            entry = gt.get(name)
            if entry is None or not entry.get("acid_reactive"):
                continue
            assert entry["acid_result"] == "empty", (
                f"Acid on {name} should produce empty, got {entry['acid_result']}"
            )


class TestFreezeThawWeathering:
    """Frost wedging: ice expansion fractures stone."""

    @pytest.mark.physics
    def test_freeze_thaw_principle(self, ground_truth):
        """Oracle should describe ice expansion fracturing rock."""
        gt = ground_truth.get("freeze_thaw_weathering")
        if gt is None:
            pytest.skip("No freeze_thaw_weathering oracle data")
        assert "expand" in gt["principle"].lower()
        assert gt["expansion_percent"] == pytest.approx(9.0, abs=1.0)

    @pytest.mark.physics
    def test_ice_pressure_exceeds_rock_strength(self, ground_truth):
        """Ice expansion pressure must exceed rock tensile strength."""
        gt = ground_truth.get("freeze_thaw_weathering")
        if gt is None:
            pytest.skip("No freeze_thaw_weathering oracle data")
        ice_pressure = gt["ice_expansion_pressure_MPa"]
        max_rock_strength = max(gt["rock_tensile_strength_MPa"].values())
        assert ice_pressure > max_rock_strength

    @pytest.mark.physics
    def test_products_are_granular(self, ground_truth):
        """Frost-shattered stone should become sand or dirt."""
        gt = ground_truth.get("freeze_thaw_weathering")
        if gt is None:
            pytest.skip("No freeze_thaw_weathering oracle data")
        products = gt["our_products"]
        assert "sand" in products
        assert "dirt" in products

    @pytest.mark.physics
    def test_faster_than_water_weathering(self, ground_truth):
        """Freeze-thaw should be faster than plain water weathering."""
        gt = ground_truth.get("freeze_thaw_weathering")
        if gt is None:
            pytest.skip("No freeze_thaw_weathering oracle data")
        assert gt["our_rate_vs_water"] >= 2
