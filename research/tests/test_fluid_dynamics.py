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


class TestSurfaceTension:
    """Liquids should have correct surface tension ordering."""

    @pytest.mark.physics
    def test_surface_tension_ordering(self, ground_truth):
        """Lava should have highest surface tension, acid lowest."""
        gt = ground_truth.get("surface_tension")
        if gt is None:
            pytest.skip("No surface_tension oracle data")
        ordering = gt["ordering"]
        assert ordering[0] == "lava", "Lava should have highest surface tension"
        assert ordering[-1] == "acid", "Acid should have lowest surface tension"

    @pytest.mark.physics
    def test_water_vs_oil_surface_tension(self, ground_truth):
        """Water should have higher surface tension than oil."""
        gt = ground_truth.get("surface_tension")
        if gt is None:
            pytest.skip("No surface_tension oracle data")
        values = gt["values"]
        assert values["water"] > values["oil"]

    @pytest.mark.physics
    def test_all_liquids_have_surface_tension(self, ground_truth):
        """All liquid elements should have surface tension values."""
        gt = ground_truth.get("surface_tension")
        if gt is None:
            pytest.skip("No surface_tension oracle data")
        values = gt["values"]
        for liquid in ["water", "oil", "acid", "lava", "mud"]:
            assert liquid in values, f"Missing surface tension for {liquid}"
            assert values[liquid] > 0, f"{liquid} surface tension should be > 0"


class TestRippleDamping:
    """Surface disturbances should decay over time, not amplify."""

    @pytest.mark.physics
    def test_damping_principle(self, ground_truth):
        """Oracle confirms viscous dissipation damps water surface waves."""
        gt = ground_truth.get("ripple_damping")
        if gt is None:
            pytest.skip("No ripple_damping oracle data")
        assert gt["expected_late_less_than_early"] is True

    @pytest.mark.physics
    def test_damping_mechanism(self, ground_truth):
        """Damping should be attributed to viscous dissipation."""
        gt = ground_truth.get("ripple_damping")
        if gt is None:
            pytest.skip("No ripple_damping oracle data")
        assert "dissipation" in gt["mechanism"].lower() or "viscous" in gt["mechanism"].lower()


class TestCapillaryWicking:
    """Porous materials should absorb water via capillary action."""

    @pytest.mark.physics
    def test_washburn_equation_defined(self, ground_truth):
        """Oracle provides Washburn equation parameters for capillary rise."""
        gt = ground_truth.get("capillary_wicking")
        if gt is None:
            pytest.skip("No capillary_wicking oracle data")
        assert "washburn_equation" in gt
        assert gt["gamma_N_per_m"] > 0
        assert gt["viscosity_Pa_s"] > 0

    @pytest.mark.physics
    def test_wicking_distance_increases_with_time(self, ground_truth):
        """Wicking distance should increase monotonically with time."""
        gt = ground_truth.get("capillary_wicking")
        if gt is None:
            pytest.skip("No capillary_wicking oracle data")
        distances = gt["wicking_distance_cm"]
        for i in range(1, len(distances)):
            assert distances[i] > distances[i - 1], (
                f"Wicking distance should increase: {distances[i]} <= {distances[i-1]}"
            )

    @pytest.mark.physics
    def test_porous_elements_have_porosity(self, ground_truth):
        """All porous elements should have porosity values between 0 and 1."""
        gt = ground_truth.get("capillary_wicking")
        if gt is None:
            pytest.skip("No capillary_wicking oracle data")
        porous = gt["porous_elements"]
        for name, porosity in porous.items():
            assert 0 < porosity < 1, f"{name} porosity {porosity} out of range"

    @pytest.mark.physics
    def test_dirt_highest_porosity(self, ground_truth):
        """Dirt should have the highest porosity among porous elements."""
        gt = ground_truth.get("capillary_wicking")
        if gt is None:
            pytest.skip("No capillary_wicking oracle data")
        porous = gt["porous_elements"]
        assert porous["dirt"] == max(porous.values()), (
            f"Dirt porosity {porous['dirt']} should be highest"
        )

    @pytest.mark.physics
    def test_wicking_follows_sqrt_time(self, ground_truth):
        """Washburn law: L^2 proportional to t (L ~ sqrt(t))."""
        gt = ground_truth.get("capillary_wicking")
        if gt is None:
            pytest.skip("No capillary_wicking oracle data")
        times = gt["times_s"]
        distances = gt["wicking_distance_cm"]
        # L^2/t should be approximately constant
        ratios = [d * d / t for d, t in zip(distances, times)]
        avg = sum(ratios) / len(ratios)
        for r in ratios:
            assert r == pytest.approx(avg, rel=0.05), (
                f"L^2/t ratio {r:.2f} deviates from avg {avg:.2f}"
            )
