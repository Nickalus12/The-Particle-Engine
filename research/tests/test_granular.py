"""Granular physics tests: angle of repose, granular behavior."""

import math

import pytest


class TestAngleOfRepose:
    """Granular elements should have physically plausible angles of repose."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_angle",
        [
            ("sand", 34),
            ("dirt", 40),
            ("snow", 38),
            ("ash", 35),
        ],
    )
    def test_angle_range(self, ground_truth, element, expected_angle):
        gt = ground_truth.get("angle_of_repose", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No angle of repose data for {element}")
        assert entry["min"] <= expected_angle <= entry["max"]

    @pytest.mark.physics
    def test_ca_natural_angle(self, ground_truth):
        """Cellular automata with 8-connectivity have natural 45-deg angle."""
        gt = ground_truth.get("granular_all", {})
        for name, entry in gt.items():
            assert entry["ca_natural_angle"] == 45


class TestGranularAll:
    """Extended granular element properties."""

    @pytest.mark.physics
    @pytest.mark.parametrize("element", ["sand", "dirt", "tnt", "snow", "ash"])
    def test_granular_state(self, ground_truth, element):
        gt = ground_truth.get("granular_all", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No granular data for {element}")
        assert entry["state"] in ("granular", "powder")
        assert entry["gravity"] > 0

    @pytest.mark.physics
    def test_sand_tan_angle(self, ground_truth):
        gt = ground_truth.get("granular_all", {})
        entry = gt.get("sand")
        if entry is None:
            pytest.skip("No granular data for sand")
        expected_tan = math.tan(math.radians(34))
        assert entry["tan_angle"] == pytest.approx(expected_tan, abs=0.01)
