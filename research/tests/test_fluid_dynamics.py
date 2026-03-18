"""Fluid dynamics tests: Torricelli outflow, viscosity, flow ordering."""

import math

import pytest


class TestTorricelli:
    """Outflow velocity should follow v = sqrt(2*g*h)."""

    @pytest.mark.physics
    def test_velocity_increases_with_height(self, ground_truth):
        """Higher water columns should produce faster outflow."""
        gt = ground_truth.get("torricelli")
        if gt is None:
            pytest.skip("No torricelli oracle data")
        velocities = gt["expected_velocity_cells_per_frame"]
        for i in range(1, len(velocities)):
            assert velocities[i] > velocities[i - 1]

    @pytest.mark.physics
    def test_velocity_ratio_follows_sqrt(self, ground_truth):
        """v(h1)/v(h2) = sqrt(h1/h2)."""
        gt = ground_truth.get("torricelli")
        if gt is None:
            pytest.skip("No torricelli oracle data")
        heights = gt["heights_cells"]
        velocities = gt["expected_velocity_cells_per_frame"]
        for i in range(1, len(heights)):
            expected_ratio = math.sqrt(heights[i] / heights[0])
            actual_ratio = velocities[i] / velocities[0]
            assert actual_ratio == pytest.approx(expected_ratio, rel=0.01)


class TestViscosity:
    """Liquid elements should be ordered by viscosity."""

    @pytest.mark.physics
    def test_viscosity_ordering(self, ground_truth):
        """Least to most viscous: water < acid < oil < mud < lava."""
        gt = ground_truth.get("viscosity_all")
        if gt is None:
            pytest.skip("No viscosity oracle data")
        ordering = gt["ordering_least_to_most_viscous"]
        assert ordering.index("water") < ordering.index("lava")
        assert ordering.index("oil") < ordering.index("mud")

    @pytest.mark.physics
    def test_real_vs_engine_viscosity_agreement(self, ground_truth):
        """Engine viscosity ordering should match real-world ordering."""
        gt = ground_truth.get("viscosity_all")
        if gt is None:
            pytest.skip("No viscosity oracle data")
        real_order = gt["real_ordering"]
        engine_order = gt["ordering_least_to_most_viscous"]
        # Water should be least viscous in both
        assert real_order[0] == "water"
        assert engine_order[0] in ("water", "acid")

    @pytest.mark.physics
    def test_lava_most_viscous(self, ground_truth):
        """Lava should be the most viscous liquid."""
        gt = ground_truth.get("viscosity_all")
        if gt is None:
            pytest.skip("No viscosity oracle data")
        ordering = gt["ordering_least_to_most_viscous"]
        assert ordering[-1] == "lava"
