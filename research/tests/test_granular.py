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


class TestBeverlooFlow:
    """Hourglass flow rate should follow Beverloo equation."""

    @pytest.mark.physics
    def test_beverloo_zero_at_one_cell(self, ground_truth):
        """1-cell opening has zero Beverloo flow (CA always allows it)."""
        gt = ground_truth.get("beverloo")
        if gt is None:
            pytest.skip("No beverloo oracle data")
        assert gt["expected_relative_flow"][0] == 0

    @pytest.mark.physics
    def test_beverloo_flow_increases(self, ground_truth):
        """Wider openings should produce more flow."""
        gt = ground_truth.get("beverloo")
        if gt is None:
            pytest.skip("No beverloo oracle data")
        flows = gt["expected_relative_flow"]
        for i in range(2, len(flows)):
            assert flows[i] > flows[i - 1], \
                f"Flow should increase: opening {i} has {flows[i]} <= {flows[i-1]}"

    @pytest.mark.physics
    def test_beverloo_equation(self, ground_truth):
        """Flow rate should follow 5/2 power law."""
        gt = ground_truth.get("beverloo")
        if gt is None:
            pytest.skip("No beverloo oracle data")
        assert "5/2" in gt["equation"] or "^(5/2)" in gt["equation"]


class TestGradedBedding:
    """Denser particles should settle faster in fluid (Stokes' law)."""

    @pytest.mark.physics
    def test_grading_principle(self, ground_truth):
        """Oracle confirms denser particles settle faster."""
        gt = ground_truth.get("graded_bedding")
        if gt is None:
            pytest.skip("No graded_bedding oracle data")
        assert "denser" in gt["principle"].lower() or "stokes" in gt["principle"].lower()

    @pytest.mark.physics
    def test_sand_settles_faster_than_dirt(self, ground_truth):
        """Sand (d=1600) should have higher Stokes velocity than dirt (d=1500)."""
        gt = ground_truth.get("graded_bedding")
        if gt is None:
            pytest.skip("No graded_bedding oracle data")
        data = gt["settling_data"]
        sand_vt = data["sand"]["stokes_vt_m_s"]
        dirt_vt = data["dirt"]["stokes_vt_m_s"]
        assert sand_vt > dirt_vt, (
            f"Sand Stokes vt={sand_vt} should exceed dirt vt={dirt_vt}"
        )

    @pytest.mark.physics
    def test_density_determines_settling(self, ground_truth):
        """Higher real-world density → higher settling velocity."""
        gt = ground_truth.get("graded_bedding")
        if gt is None:
            pytest.skip("No graded_bedding oracle data")
        data = gt["settling_data"]
        # Only compare elements that sink (positive vt)
        sinkers = {k: v for k, v in data.items() if v["stokes_vt_m_s"] > 0}
        sorted_by_density = sorted(sinkers.items(),
                                   key=lambda x: x[1]["real_density_kg_m3"])
        for i in range(1, len(sorted_by_density)):
            prev = sorted_by_density[i - 1]
            curr = sorted_by_density[i]
            assert curr[1]["stokes_vt_m_s"] >= prev[1]["stokes_vt_m_s"], (
                f"{curr[0]} (d={curr[1]['real_density_kg_m3']}) should settle >= "
                f"{prev[0]} (d={prev[1]['real_density_kg_m3']})"
            )
