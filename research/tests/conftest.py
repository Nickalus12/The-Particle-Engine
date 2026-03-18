"""Test-specific fixtures and helpers."""

import numpy as np
import pytest


@pytest.fixture
def grid_element_mask(simulation_frame):
    """Factory fixture: returns a boolean mask for a given element ID."""

    def _mask(el_id):
        return simulation_frame["grid"] == el_id

    return _mask


@pytest.fixture
def element_pixel_sample(simulation_frame):
    """Factory fixture: returns RGB pixels for a given element ID.

    Returns (N, 3) array of RGB values, or None if fewer than min_count pixels.
    """

    def _sample(el_id, min_count=10):
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < min_count:
            return None
        return simulation_frame["pixels"][mask][:, :3]

    return _sample
