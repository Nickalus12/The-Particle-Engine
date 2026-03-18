import json
import pytest


class TestOracleSnapshots:
    def test_gravity_oracle_stable(self, snapshot, ground_truth):
        """Gravity oracle data should not change unexpectedly."""
        gravity_data = ground_truth.get("gravity_all", {})
        # Only snapshot the keys and structure, not exact values
        structure = {k: list(v.keys()) for k, v in gravity_data.items()}
        assert structure == snapshot

    def test_density_ordering_stable(self, snapshot, ground_truth):
        """Density ordering should be stable across oracle regenerations."""
        ordering = ground_truth.get("density_ordering", {})
        our_order = ordering.get("our_order", [])
        assert our_order == snapshot

    def test_phase_change_products_stable(self, snapshot, ground_truth):
        """Phase change products should not change."""
        phases = ground_truth.get("phase_changes_all", {})
        products = {k: v.get("becomes", "") for k, v in phases.items()}
        assert products == snapshot

    def test_reaction_products_stable(self, snapshot, ground_truth):
        """Reaction products should not drift."""
        reactions = ground_truth.get("reactions_all", {})
        products = {}
        for name, data in reactions.items():
            products[name] = {
                "source_becomes": data.get("source_becomes"),
                "target_becomes": data.get("target_becomes"),
            }
        assert products == snapshot

    def test_element_count_stable(self, snapshot, ground_truth):
        """Number of elements in oracle should be stable."""
        gravity = ground_truth.get("gravity_all", {})
        assert len(gravity) == snapshot
