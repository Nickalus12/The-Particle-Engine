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
