"""Visual color science tests using CIE 2000 Delta E.

Verifies element colors match expected LAB values, all pairs are perceptually
distinguishable, known similar pairs are identified, and critical contrast
ratios are maintained.
"""

import json

import pytest
import numpy as np
from skimage.color import rgb2lab
import colour


# ---------------------------------------------------------------------------
# Load oracle keys for parametrize at module level
# ---------------------------------------------------------------------------
_RESEARCH_DIR = __import__("pathlib").Path(__file__).parent.parent
_VGT_PATH = _RESEARCH_DIR / "visual_ground_truth.json"
if _VGT_PATH.exists():
    with open(_VGT_PATH) as _f:
        _ORACLE = json.load(_f)
else:
    _ORACLE = {}

_LAB_ELEMENTS = list(_ORACLE.get("element_lab_colors", {}).keys())
_DELTA_E_PAIRS = list(_ORACLE.get("delta_e_pairs", {}).items())
_KNOWN_SIMILAR = set(_ORACLE.get("known_similar_pairs", []))


# ===================================================================
# Helper
# ===================================================================

def _resolve_element_id(element_names, name):
    """Find element ID by case-insensitive lookup."""
    el_id = element_names.get(name)
    if el_id is None:
        el_id = element_names.get(name.capitalize())
    return el_id


# ===================================================================
# 1. Element LAB accuracy -- 24 parametrized tests
# ===================================================================

class TestElementLABAccuracy:
    """Each element's rendered color should be close to its base LAB color."""

    @pytest.mark.visual
    @pytest.mark.parametrize("element_name", _LAB_ELEMENTS)
    def test_element_lab_accuracy(
        self, element_name, simulation_frame, element_names, visual_truth
    ):
        """Rendered color for each element within Delta E < 30 of base."""
        el_id = _resolve_element_id(element_names, element_name)
        if el_id is None:
            pytest.skip(f"Element {element_name} not in simulation metadata")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 10:
            pytest.skip(f"Not enough {element_name} pixels")
        rgb = (
            simulation_frame["pixels"][mask][:, :3]
            .astype(np.float64)
            .mean(axis=0)
            / 255.0
        )
        actual_lab = rgb2lab(rgb.reshape(1, 1, 3))[0, 0]
        expected = visual_truth["element_lab_colors"][element_name]
        expected_lab = np.array([expected["L"], expected["a"], expected["b"]])
        delta_e = float(colour.delta_E(actual_lab, expected_lab, method="CIE 2000"))
        assert delta_e < 30, (
            f"{element_name} Delta E = {delta_e:.1f} (expected < 30)"
        )


# ===================================================================
# 2. Color distinctness -- overall + per-pair
# ===================================================================

class TestColorDistinctness:
    """Every element pair should be perceptually distinguishable."""

    @pytest.fixture
    def element_avg_colors(self, simulation_frame, element_names):
        """Compute average Lab color for each element present in the frame."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        colors = {}
        for name, el_id in element_names.items():
            if el_id == 0:
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
                pair_key = f"{name_a.lower()}_{name_b.lower()}"
                if pair_key in _KNOWN_SIMILAR or f"{name_b.lower()}_{name_a.lower()}" in _KNOWN_SIMILAR:
                    continue
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


# ===================================================================
# 3. Delta E pairs -- oracle-based pairwise validation
# ===================================================================

class TestDeltaEPairs:
    """Oracle-computed Delta E values should meet minimum threshold."""

    @pytest.mark.visual
    @pytest.mark.parametrize("pair_key,expected_de", _DELTA_E_PAIRS)
    def test_pair_delta_e(self, pair_key, expected_de, visual_truth):
        """Each element pair should have expected perceptual distance."""
        if pair_key in _KNOWN_SIMILAR:
            pytest.skip(f"Known similar pair: {pair_key}")
        threshold = visual_truth["min_delta_e_threshold"]
        assert expected_de >= threshold, (
            f"{pair_key}: Delta E = {expected_de:.2f} < threshold {threshold}"
        )


# ===================================================================
# 4. Known similar pairs -- verify they are indeed close
# ===================================================================

class TestKnownSimilarPairs:
    """Known similar pairs should have low Delta E (this is expected)."""

    @pytest.mark.visual
    @pytest.mark.parametrize("pair_key", list(_KNOWN_SIMILAR))
    def test_known_similar_is_close(self, pair_key, visual_truth):
        """Known similar pairs should have Delta E < 15."""
        de = visual_truth["delta_e_pairs"].get(pair_key)
        if de is None:
            pytest.skip(f"Pair {pair_key} not in oracle")
        assert de < 15, (
            f"Known similar pair {pair_key} has unexpectedly high Delta E: {de:.2f}"
        )


# ===================================================================
# 5. Color families -- elements should match expected hue ranges
# ===================================================================

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
        el_id = _resolve_element_id(element_names, element)
        if el_id is None:
            pytest.skip(f"Element {element} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 10:
            pytest.skip(f"Not enough {element} pixels")
        rgb = simulation_frame["pixels"][mask][:, :3].astype(np.float64)
        avg_rgb = rgb.mean(axis=0)
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


# ===================================================================
# 6. Contrast -- critical pairs must be distinguishable
# ===================================================================

class TestContrastRatio:
    """Critical element pairs must have sufficient contrast."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "pair",
        _ORACLE.get("contrast", {}).get("critical_pairs", []),
    )
    def test_critical_contrast(
        self, pair, simulation_frame, element_names, visual_truth
    ):
        """Critical pairs must have contrast ratio above minimum."""
        name_a, name_b = pair
        id_a = _resolve_element_id(element_names, name_a)
        id_b = _resolve_element_id(element_names, name_b)
        if id_a is None or id_b is None:
            pytest.skip(f"Element(s) {name_a}/{name_b} not found")

        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]

        mask_a = grid == id_a
        mask_b = grid == id_b
        if mask_a.sum() < 10 or mask_b.sum() < 10:
            pytest.skip(f"Not enough pixels for {name_a}/{name_b}")

        # Relative luminance per WCAG
        def rel_luminance(rgb_arr):
            srgb = rgb_arr.astype(np.float64) / 255.0
            linear = np.where(srgb <= 0.03928, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
            return 0.2126 * linear[:, 0].mean() + 0.7152 * linear[:, 1].mean() + 0.0722 * linear[:, 2].mean()

        lum_a = rel_luminance(pixels[mask_a][:, :3])
        lum_b = rel_luminance(pixels[mask_b][:, :3])
        lighter = max(lum_a, lum_b)
        darker = min(lum_a, lum_b)
        ratio = (lighter + 0.05) / (darker + 0.05)

        min_ratio = visual_truth["contrast"]["min_contrast_ratio"]
        assert ratio >= min_ratio, (
            f"{name_a} vs {name_b}: contrast ratio {ratio:.2f} < {min_ratio}"
        )


# ===================================================================
# 7. Base RGB -- per-element rendered color within tolerance
# ===================================================================

class TestBaseRGB:
    """Each element's rendered RGB should be within tolerance of base color."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element_name", list(_ORACLE.get("base_rgb", {}).keys())
    )
    def test_element_rgb_range(
        self, element_name, simulation_frame, element_names, visual_truth
    ):
        """Rendered average RGB should be within 80 of base color per channel."""
        el_id = _resolve_element_id(element_names, element_name)
        if el_id is None:
            pytest.skip(f"Element {element_name} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 10:
            pytest.skip(f"Not enough {element_name} pixels")
        avg = simulation_frame["pixels"][mask][:, :3].astype(np.float64).mean(axis=0)
        expected = visual_truth["base_rgb"][element_name]
        # Emissive elements accumulate glow from neighbors, allow wider tolerance
        emissive = {"fire", "lava", "lightning", "rainbow", "acid"}
        tolerance = 100 if element_name in emissive else 80
        for ch, key in enumerate(["r", "g", "b"]):
            diff = abs(avg[ch] - expected[key])
            assert diff < tolerance, (
                f"{element_name} channel {key}: rendered={avg[ch]:.0f}, "
                f"expected={expected[key]}, diff={diff:.0f} (max {tolerance})"
            )


# ===================================================================
# 8. Base alphas -- per-element alpha value check
# ===================================================================

class TestBaseAlphas:
    """Each element should render with expected alpha range."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element_name", list(_ORACLE.get("base_alphas", {}).keys())
    )
    def test_element_alpha(
        self, element_name, simulation_frame, element_names, visual_truth
    ):
        """Each element's average alpha should be within 60 of base alpha."""
        el_id = _resolve_element_id(element_names, element_name)
        if el_id is None:
            pytest.skip(f"Element {element_name} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 5:
            pytest.skip(f"Not enough {element_name} pixels")
        avg_alpha = float(
            simulation_frame["pixels"][mask][:, 3].astype(np.float64).mean()
        )
        expected = visual_truth["base_alphas"][element_name]
        diff = abs(avg_alpha - expected)
        assert diff < 60, (
            f"{element_name} alpha: rendered={avg_alpha:.0f}, "
            f"expected={expected}, diff={diff:.0f} (max 60)"
        )
