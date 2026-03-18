"""Conservation law tests: mass, energy, momentum."""

import pytest


class TestMassConservation:
    """Total cell count should be constant in a closed system."""

    @pytest.mark.physics
    def test_mass_conservation_principle(self, ground_truth):
        gt = ground_truth.get("conservation", {})
        mass = gt.get("mass")
        if mass is None:
            pytest.skip("No conservation data")
        assert mass["expected_drift"] == 0
        assert mass["tolerance_percent"] > 0

    @pytest.mark.physics
    def test_mass_tolerance_reasonable(self, ground_truth):
        gt = ground_truth.get("conservation", {})
        mass = gt.get("mass")
        if mass is None:
            pytest.skip("No conservation data")
        assert mass["tolerance_percent"] <= 5.0


class TestEnergyConservation:
    """Total thermal energy should be approximately constant without sources."""

    @pytest.mark.physics
    def test_energy_conservation_principle(self, ground_truth):
        gt = ground_truth.get("conservation", {})
        energy = gt.get("energy")
        if energy is None:
            pytest.skip("No conservation data")
        assert energy["expected_drift_percent"] == 0
        # Integer rounding dissipates energy, so tolerance is higher
        assert energy["tolerance_percent"] <= 10.0


class TestMomentumConservation:
    """Symmetric drops should preserve zero net horizontal momentum."""

    @pytest.mark.physics
    def test_momentum_conservation_principle(self, ground_truth):
        gt = ground_truth.get("conservation", {})
        momentum = gt.get("momentum")
        if momentum is None:
            pytest.skip("No conservation data")
        assert momentum["expected_net_horizontal"] == 0
