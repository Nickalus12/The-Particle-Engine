"""Visual color science tests using CIE 2000 Delta E.

Verifies that every element pair is perceptually distinguishable and that
element colors match expected hue families.
"""

import pytest
import numpy as np
from skimage.color import rgb2lab
import colour


class TestColorDistinctness:
    """Every element pair should be perceptually distinguishable (Delta E > 5)."""

    @pytest.fixture
    def element_avg_colors(self, simulation_frame, element_names):
        """Compute average Lab color for each element present in the frame."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        colors = {}
        for name, el_id in element_names.items():
            if el_id == 0:  # skip empty
                continue
            mask = grid == el_id
            count = mask.sum()
            if count < 10:
                continue
            rgb = pixels[mask][:, :3].astype(np.float64).mean(axis=0) / 255.0
            colors[name] = rgb
        return colors

    @pytest.mark.visual
    def test_all_pairs_distinguishable(self, element_avg_colors):
        """CIE 2000 Delta E between all element pairs should be > 5."""
        names = list(element_avg_colors.keys())
        if len(names) < 2:
            pytest.skip("Not enough elements with pixels for comparison")
        failures = []
        for i, name_a in enumerate(names):
            for name_b in names[i + 1:]:
                rgb_a = element_avg_colors[name_a].reshape(1, 1, 3)
                rgb_b = element_avg_colors[name_b].reshape(1, 1, 3)
                lab_a = rgb2lab(rgb_a)[0, 0]
                lab_b = rgb2lab(rgb_b)[0, 0]
                delta_e = colour.delta_E(lab_a, lab_b, method="CIE 2000")
                if delta_e < 5.0:
                    failures.append((name_a, name_b, float(delta_e)))
        assert len(failures) == 0, (
            f"Indistinguishable element pairs (Delta E < 5): "
            + ", ".join(f"{a} vs {b} ({de:.1f})" for a, b, de in failures)
        )

    @pytest.mark.visual
    def test_minimum_elements_rendered(self, element_avg_colors):
        """At least 5 distinct elements should have pixels in the test world."""
        assert len(element_avg_colors) >= 5, (
            f"Only {len(element_avg_colors)} elements rendered"
        )


class TestColorFamilies:
    """Elements should belong to expected color families."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element,expected_hue_range",
        [
            ("water", (180, 260)),    # blue
            ("sand", (20, 60)),       # warm gold/tan
            ("plant", (80, 160)),     # green
            ("lava", (0, 40)),        # red-orange
            ("ice", (180, 240)),      # blue-white
        ],
    )
    def test_element_hue(
        self, simulation_frame, element_names, element, expected_hue_range
    ):
        """Element average color should be in expected hue range."""
        el_id = element_names.get(element)
        if el_id is None:
            pytest.skip(f"Element {element} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 10:
            pytest.skip(f"Not enough {element} pixels")
        rgb = simulation_frame["pixels"][mask][:, :3].astype(np.float64)
        avg_rgb = rgb.mean(axis=0)
        # Convert to HSV-like hue
        r, g, b = avg_rgb / 255.0
        mx = max(r, g, b)
        mn = min(r, g, b)
        if mx == mn:
            pytest.skip(f"{element} is achromatic")
        diff = mx - mn
        if mx == r:
            hue = 60 * (((g - b) / diff) % 6)
        elif mx == g:
            hue = 60 * ((b - r) / diff + 2)
        else:
            hue = 60 * ((r - g) / diff + 4)
        lo, hi = expected_hue_range
        if lo <= hi:
            in_range = lo <= hue <= hi
        else:
            in_range = hue >= lo or hue <= hi
        assert in_range, (
            f"{element} hue {hue:.0f} not in [{lo}, {hi}]"
        )
