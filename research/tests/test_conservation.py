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


class TestConservationMass:
    """Standalone mass conservation oracle category."""

    @pytest.mark.physics
    def test_mass_drift_zero(self, ground_truth):
        gt = ground_truth.get("conservation_mass")
        if gt is None:
            pytest.skip("No conservation_mass oracle data")
        assert gt["expected_drift"] == 0

    @pytest.mark.physics
    def test_mass_tolerance(self, ground_truth):
        gt = ground_truth.get("conservation_mass")
        if gt is None:
            pytest.skip("No conservation_mass oracle data")
        assert gt["tolerance_percent"] <= 5.0


class TestConservationMomentum:
    """Standalone momentum conservation oracle category."""

    @pytest.mark.physics
    def test_momentum_symmetry(self, ground_truth):
        gt = ground_truth.get("conservation_momentum")
        if gt is None:
            pytest.skip("No conservation_momentum oracle data")
        assert gt["expected_net_horizontal_momentum"] == 0
        assert gt["tolerance"] >= 0


class TestConservationEnergy:
    """Standalone energy conservation oracle category."""

    @pytest.mark.physics
    def test_energy_drift_bounded(self, ground_truth):
        gt = ground_truth.get("conservation_energy")
        if gt is None:
            pytest.skip("No conservation_energy oracle data")
        assert gt["expected_drift_percent"] == 0
        assert gt["tolerance_percent"] <= 10.0


class TestNonReactivePairs:
    """Same-element pairs should not react with each other."""

    @pytest.mark.physics
    def test_non_reactive_pairs_defined(self, ground_truth):
        gt = ground_truth.get("non_reactive_pairs")
        if gt is None:
            pytest.skip("No non_reactive_pairs oracle data")
        pairs = gt["pairs"]
        assert len(pairs) >= 10  # at least 10 same-element + cross-element pairs

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["stone", "water", "sand", "metal", "dirt", "glass", "wood", "ice"],
    )
    def test_element_is_non_reactive_with_self(self, ground_truth, element):
        gt = ground_truth.get("non_reactive_pairs")
        if gt is None:
            pytest.skip("No non_reactive_pairs oracle data")
        pairs = gt["pairs"]
        assert [element, element] in pairs, (
            f"{element} should be non-reactive with itself"
        )

    @pytest.mark.physics
    def test_cross_element_non_reactive(self, ground_truth):
        """Some different elements should also be non-reactive (e.g. stone+metal)."""
        gt = ground_truth.get("non_reactive_pairs")
        if gt is None:
            pytest.skip("No non_reactive_pairs oracle data")
        pairs = gt["pairs"]
        cross_pairs = [p for p in pairs if p[0] != p[1]]
        assert len(cross_pairs) >= 3, (
            f"Expected at least 3 cross-element non-reactive pairs, got {len(cross_pairs)}"
        )
