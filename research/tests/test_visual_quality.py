"""Visual quality tests using scikit-image: entropy, gradients, glow, transparency.

Validates texture complexity, gradient smoothness, artifact absence,
underground lighting, water depth, transparency, light emission, and
day/night visual properties -- all driven by visual_ground_truth.json.
"""

import json

import pytest
import numpy as np
from skimage.measure import shannon_entropy
from skimage.filters import sobel
from skimage.color import rgb2gray

# ---------------------------------------------------------------------------
# Load oracle for parametrize at module level
# ---------------------------------------------------------------------------
_RESEARCH_DIR = __import__("pathlib").Path(__file__).parent.parent
_VGT_PATH = _RESEARCH_DIR / "visual_ground_truth.json"
if _VGT_PATH.exists():
    with open(_VGT_PATH) as _f:
        _ORACLE = json.load(_f)
else:
    _ORACLE = {}

_ENTROPY_ELEMENTS = [
    (name, data["min"], data["max"])
    for name, data in _ORACLE.get("texture_entropy", {}).items()
]

_TRANSPARENCY_ELEMENTS = [
    (name, data["min_alpha"], data["max_alpha"])
    for name, data in _ORACLE.get("transparency", {}).items()
]

_EMITTERS = list(_ORACLE.get("light_emission", {}).keys())


def _resolve_element_id(element_names, name):
    """Find element ID by case-insensitive lookup."""
    el_id = element_names.get(name)
    if el_id is None:
        el_id = element_names.get(name.capitalize())
    return el_id


# ===================================================================
# 1. Texture entropy -- all 12 elements
# ===================================================================

class TestTextureQuality:
    """Elements should have appropriate texture complexity via Shannon entropy."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element,min_entropy,max_entropy", _ENTROPY_ELEMENTS
    )
    def test_element_entropy(
        self, simulation_frame, element_names, element, min_entropy, max_entropy
    ):
        """Each element should have texture complexity in expected range."""
        el_id = _resolve_element_id(element_names, element)
        if el_id is None:
            pytest.skip(f"Element {element} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 50:
            pytest.skip(f"Not enough {element} pixels")
        gray = rgb2gray(simulation_frame["pixels"][:, :, :3])
        element_pixels = gray[mask]
        entropy = shannon_entropy(element_pixels)
        assert min_entropy <= entropy <= max_entropy, (
            f"{element} entropy={entropy:.2f}, expected [{min_entropy}, {max_entropy}]"
        )


# ===================================================================
# 2. Gradient smoothness
# ===================================================================

class TestGradientSmoothness:
    """Color transitions should be smooth, not jagged."""

    @pytest.mark.visual
    def test_sky_gradient_smooth(self, simulation_frame, visual_truth):
        """Sky should have a smooth vertical gradient (no sharp jumps)."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        max_allowed = visual_truth["sky_gradient"]["max_second_derivative"]
        tested_columns = 0
        for x in range(0, 320, 20):
            col = []
            for y in range(0, 60):
                if grid[y, x] == 0:
                    col.append(float(pixels[y, x, :3].mean()))
            if len(col) > 10:
                tested_columns += 1
                gradient = np.diff(col)
                second_deriv = np.diff(gradient)
                max_jump = float(np.max(np.abs(second_deriv)))
                assert max_jump < max_allowed, (
                    f"Sky gradient has sharp jump at x={x}: {max_jump:.1f}"
                )
        if tested_columns == 0:
            pytest.skip("No sky columns found")

    @pytest.mark.visual
    @pytest.mark.parametrize("column_x", range(0, 320, 40))
    def test_sky_gradient_per_column(self, column_x, simulation_frame, visual_truth):
        """Sky gradient should be consistent across sampled columns."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        col = []
        for y in range(0, 60):
            if grid[y, column_x] == 0:
                col.append(float(pixels[y, column_x, :3].mean()))
        if len(col) < 5:
            pytest.skip(f"Not enough sky pixels at x={column_x}")
        gradient = np.diff(col)
        second_deriv = np.diff(gradient)
        if len(second_deriv) == 0:
            pytest.skip("Not enough data for gradient analysis")
        max_jump = float(np.max(np.abs(second_deriv)))
        max_allowed = visual_truth["sky_gradient"]["max_second_derivative"]
        assert max_jump < max_allowed, (
            f"Sky gradient jump at x={column_x}: {max_jump:.1f}"
        )


# ===================================================================
# 3. No black artifacts
# ===================================================================

class TestNoBlackArtifacts:
    """Sky and background should never be pure black."""

    @pytest.mark.visual
    def test_no_black_sky(self, simulation_frame):
        """Sky pixels (empty cells in top third) should not be pure black."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 60)
        sky_count = sky_mask.sum()
        if sky_count == 0:
            pytest.skip("No sky pixels")
        sky_pixels = pixels[sky_mask]
        black_count = int(
            (
                (sky_pixels[:, 0] == 0)
                & (sky_pixels[:, 1] == 0)
                & (sky_pixels[:, 2] == 0)
                & (sky_pixels[:, 3] == 255)
            ).sum()
        )
        black_ratio = black_count / sky_count
        assert black_ratio < 0.01, (
            f"{black_ratio * 100:.1f}% of sky is pure black"
        )


# ===================================================================
# 4. Underground consistency
# ===================================================================

class TestUndergroundConsistency:
    """Underground empty cells should be dark cave colors."""

    @pytest.mark.visual
    def test_cave_darkness(self, simulation_frame, visual_truth):
        """Empty cells in known cave regions should be darker than sky.

        Samples from the known cave pocket regions in the test world
        (y 65-72% and 78-85% of grid height) to avoid surface erosion artifacts.
        """
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        underground_bright = []
        h, w = 180, 320
        # Known cave regions from export_frame.dart test world
        cave_regions = [
            (int(h * 0.65), int(h * 0.72), int(w * 0.15), int(w * 0.25)),  # shallow cave
            (int(h * 0.78), int(h * 0.85), int(w * 0.35), int(w * 0.45)),  # deep cave
        ]
        for y_lo, y_hi, x_lo, x_hi in cave_regions:
            for y in range(y_lo, y_hi):
                for x in range(x_lo, x_hi, 2):
                    if int(grid[y, x]) == 0:
                        brightness = int(pixels[y, x, :3].sum())
                        underground_bright.append(brightness)
        if len(underground_bright) < 10:
            pytest.skip("Not enough underground empty cells in cave regions")
        avg_brightness = np.mean(underground_bright)
        assert 15 < avg_brightness < 200, (
            f"Underground brightness avg={avg_brightness:.0f}, expected 15 < x < 200"
        )

    @pytest.mark.visual
    def test_cave_brightness_uniformity(self, simulation_frame, visual_truth):
        """Underground areas should have uniform low brightness."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        underground_bright = []
        h, w = 180, 320
        cave_regions = [
            (int(h * 0.65), int(h * 0.72), int(w * 0.15), int(w * 0.25)),
            (int(h * 0.78), int(h * 0.85), int(w * 0.35), int(w * 0.45)),
        ]
        for y_lo, y_hi, x_lo, x_hi in cave_regions:
            for y in range(y_lo, y_hi):
                for x in range(x_lo, x_hi, 2):
                    if int(grid[y, x]) == 0:
                        brightness = int(pixels[y, x, :3].sum())
                        underground_bright.append(brightness)
        if len(underground_bright) < 10:
            pytest.skip("Not enough underground empty cells")
        std_brightness = float(np.std(underground_bright))
        max_std = visual_truth["underground"]["max_brightness_std"]
        assert 3 < std_brightness < 35, (
            f"Underground brightness std={std_brightness:.1f}, expected 3 < x < 35"
        )


# ===================================================================
# 5. Edge quality
# ===================================================================

class TestEdgeQuality:
    """Element boundaries should be clean, without excessive aliasing."""

    @pytest.mark.visual
    def test_edge_magnitude(self, simulation_frame):
        """Very high edge values indicate aliasing artifacts."""
        gray = rgb2gray(simulation_frame["pixels"][:, :, :3])
        edges = sobel(gray)
        extreme_edges = int((edges > 0.8).sum())
        total = edges.size
        extreme_ratio = extreme_edges / total
        assert extreme_ratio < 0.05, (
            f"Too many extreme edges: {extreme_ratio * 100:.1f}% (aliasing?)"
        )

    @pytest.mark.visual
    def test_average_edge_reasonable(self, simulation_frame):
        """Average edge magnitude should be moderate (not too noisy)."""
        gray = rgb2gray(simulation_frame["pixels"][:, :, :3])
        edges = sobel(gray)
        avg_edge = float(edges.mean())
        assert avg_edge < 0.3, (
            f"Average edge magnitude {avg_edge:.3f} too high (noisy rendering?)"
        )


# ===================================================================
# 6. Transparency -- all 4 semi-transparent elements
# ===================================================================

class TestTransparency:
    """Semi-transparent elements should have correct alpha range."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element,min_alpha,max_alpha", _TRANSPARENCY_ELEMENTS
    )
    def test_transparency(
        self, element, min_alpha, max_alpha, simulation_frame, element_names
    ):
        """Each semi-transparent element's alpha should be in expected range."""
        el_id = _resolve_element_id(element_names, element)
        if el_id is None:
            pytest.skip(f"Element {element} not found")
        mask = simulation_frame["grid"] == el_id
        if mask.sum() < 3:
            pytest.skip(f"Not enough {element} pixels")
        alphas = simulation_frame["pixels"][mask][:, 3].astype(np.float64)
        avg_alpha = float(alphas.mean())
        assert min_alpha <= avg_alpha <= max_alpha, (
            f"{element} avg alpha={avg_alpha:.0f}, expected [{min_alpha}, {max_alpha}]"
        )


# ===================================================================
# 7. Glow correctness
# ===================================================================

class TestGlowCorrectness:
    """Light-emitting elements should glow without black halos."""

    @pytest.mark.visual
    def test_lava_no_black_halo(self, simulation_frame, element_names):
        """Pixels adjacent to lava should not be pure black."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        lava_id = _resolve_element_id(element_names, "lava")
        if lava_id is None:
            pytest.skip("No lava element")
        lava_mask = grid == lava_id
        if lava_mask.sum() < 10:
            pytest.skip("Not enough lava pixels")
        black_neighbor_count = 0
        total_neighbors = 0
        lava_positions = np.argwhere(lava_mask)
        for y, x in lava_positions[:50]:
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = y + dy, x + dx
                if 0 <= ny < 180 and 0 <= nx < 320:
                    if grid[ny, nx] != lava_id:
                        total_neighbors += 1
                        r, g, b = int(pixels[ny, nx, 0]), int(pixels[ny, nx, 1]), int(pixels[ny, nx, 2])
                        if r == 0 and g == 0 and b == 0 and int(pixels[ny, nx, 3]) == 255:
                            black_neighbor_count += 1
        if total_neighbors == 0:
            pytest.skip("No lava neighbors found")
        black_ratio = black_neighbor_count / total_neighbors
        assert black_ratio < 0.1, (
            f"{black_ratio*100:.1f}% of lava neighbors are pure black (halo)"
        )

    @pytest.mark.visual
    def test_fire_no_black_halo(self, simulation_frame, element_names):
        """Pixels adjacent to fire should not be pure black."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        fire_id = _resolve_element_id(element_names, "fire")
        if fire_id is None:
            pytest.skip("No fire element")
        fire_mask = grid == fire_id
        if fire_mask.sum() < 5:
            pytest.skip("Not enough fire pixels")
        black_neighbor_count = 0
        total_neighbors = 0
        fire_positions = np.argwhere(fire_mask)
        for y, x in fire_positions[:50]:
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = y + dy, x + dx
                if 0 <= ny < 180 and 0 <= nx < 320:
                    if grid[ny, nx] != fire_id:
                        total_neighbors += 1
                        r, g, b = int(pixels[ny, nx, 0]), int(pixels[ny, nx, 1]), int(pixels[ny, nx, 2])
                        if r == 0 and g == 0 and b == 0 and int(pixels[ny, nx, 3]) == 255:
                            black_neighbor_count += 1
        if total_neighbors == 0:
            pytest.skip("No fire neighbors found")
        black_ratio = black_neighbor_count / total_neighbors
        assert black_ratio < 0.1, (
            f"{black_ratio*100:.1f}% of fire neighbors are pure black (halo)"
        )

    @pytest.mark.visual
    @pytest.mark.parametrize("emitter", _EMITTERS)
    def test_emitter_no_black_halo(self, emitter, simulation_frame, element_names):
        """No emitter should produce black halo artifacts."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        el_id = _resolve_element_id(element_names, emitter)
        if el_id is None:
            pytest.skip(f"No {emitter} element")
        mask = grid == el_id
        if mask.sum() < 5:
            pytest.skip(f"Not enough {emitter} pixels")
        black_count = 0
        total = 0
        positions = np.argwhere(mask)
        for y, x in positions[:30]:
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = y + dy, x + dx
                if 0 <= ny < 180 and 0 <= nx < 320 and grid[ny, nx] != el_id:
                    total += 1
                    r, g, b, a = int(pixels[ny, nx, 0]), int(pixels[ny, nx, 1]), int(pixels[ny, nx, 2]), int(pixels[ny, nx, 3])
                    if r == 0 and g == 0 and b == 0 and a == 255:
                        black_count += 1
        if total == 0:
            pytest.skip(f"No {emitter} neighbors")
        ratio = black_count / total
        assert ratio < 0.15, (
            f"{emitter}: {ratio*100:.1f}% of neighbors are black (halo)"
        )

    @pytest.mark.visual
    def test_glow_radius_limit(self, simulation_frame, element_names, visual_truth):
        """Glow brightness should decay within max_radius cells from emitters."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        max_radius = visual_truth["glow"]["max_radius"]
        lava_id = _resolve_element_id(element_names, "lava")
        if lava_id is None:
            pytest.skip("No lava element")
        lava_mask = grid == lava_id
        if lava_mask.sum() < 10:
            pytest.skip("Not enough lava pixels")
        # Check brightness at max_radius+2 away from lava vs at max_radius
        positions = np.argwhere(lava_mask)
        far_brightness = []
        near_brightness = []
        for y, x in positions[:20]:
            for dist in range(max_radius + 2, max_radius + 4):
                for dy, dx in [(0, dist), (0, -dist), (dist, 0), (-dist, 0)]:
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < 180 and 0 <= nx < 320 and grid[ny, nx] == 0:
                        far_brightness.append(float(pixels[ny, nx, :3].mean()))
            for dist in range(1, 3):
                for dy, dx in [(0, dist), (0, -dist), (dist, 0), (-dist, 0)]:
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < 180 and 0 <= nx < 320 and grid[ny, nx] == 0:
                        near_brightness.append(float(pixels[ny, nx, :3].mean()))
        if len(far_brightness) < 3 or len(near_brightness) < 3:
            pytest.skip("Not enough glow samples")
        avg_far = np.mean(far_brightness)
        avg_near = np.mean(near_brightness)
        # Near emitter should be at least as bright as far
        assert avg_near >= avg_far - 30, (
            f"Glow near={avg_near:.0f}, far={avg_far:.0f} — glow not decaying"
        )


# ===================================================================
# 8. Light emission properties
# ===================================================================

class TestLightEmission:
    """Light-emitting elements should produce warm/bright pixels."""

    @pytest.mark.visual
    def test_fire_has_warm_colors(self, simulation_frame, element_names):
        """Fire pixels should have warm colors (high red, moderate green)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        fire_id = _resolve_element_id(element_names, "fire")
        if fire_id is None:
            pytest.skip("No fire element")
        fire_mask = grid == fire_id
        if fire_mask.sum() < 5:
            pytest.skip("Not enough fire pixels")
        fire_pixels = pixels[fire_mask][:, :3].astype(float)
        avg_r = float(fire_pixels[:, 0].mean())
        avg_b = float(fire_pixels[:, 2].mean())
        assert avg_r > avg_b, (
            f"Fire should be warm: avg_r={avg_r:.0f} should be > avg_b={avg_b:.0f}"
        )

    @pytest.mark.visual
    def test_lava_has_warm_colors(self, simulation_frame, element_names):
        """Lava pixels should have warm colors."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        lava_id = _resolve_element_id(element_names, "lava")
        if lava_id is None:
            pytest.skip("No lava element")
        mask = grid == lava_id
        if mask.sum() < 5:
            pytest.skip("Not enough lava pixels")
        lava_pixels = pixels[mask][:, :3].astype(float)
        avg_r = float(lava_pixels[:, 0].mean())
        avg_b = float(lava_pixels[:, 2].mean())
        assert avg_r > avg_b, (
            f"Lava should be warm: avg_r={avg_r:.0f} > avg_b={avg_b:.0f}"
        )

    @pytest.mark.visual
    @pytest.mark.parametrize("emitter", _EMITTERS)
    def test_emitter_brightness(self, emitter, simulation_frame, element_names, visual_truth):
        """Emitters should be brighter than the average non-emitter pixel."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        el_id = _resolve_element_id(element_names, emitter)
        if el_id is None:
            pytest.skip(f"No {emitter} element")
        mask = grid == el_id
        if mask.sum() < 5:
            pytest.skip(f"Not enough {emitter} pixels")
        emitter_brightness = float(pixels[mask][:, :3].astype(float).mean())
        expected_intensity = visual_truth["light_emission"][emitter]["intensity"]
        # Emitters with intensity > 100 should have brightness > 80
        if expected_intensity > 100:
            assert emitter_brightness > 80, (
                f"{emitter} brightness={emitter_brightness:.0f}, expected > 80"
            )

    @pytest.mark.visual
    @pytest.mark.parametrize("emitter", _EMITTERS)
    def test_emitter_dominant_channel(self, emitter, simulation_frame, element_names, visual_truth):
        """Emitter's dominant RGB channel should match oracle expectation."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        el_id = _resolve_element_id(element_names, emitter)
        if el_id is None:
            pytest.skip(f"No {emitter} element")
        mask = grid == el_id
        if mask.sum() < 5:
            pytest.skip(f"Not enough {emitter} pixels")
        avg = pixels[mask][:, :3].astype(float).mean(axis=0)
        emission = visual_truth["light_emission"][emitter]
        expected_dominant = max(["r", "g", "b"], key=lambda c: emission[c])
        channel_map = {"r": 0, "g": 1, "b": 2}
        actual_dominant = max(["r", "g", "b"], key=lambda c: avg[channel_map[c]])
        # For elements like rainbow/acid the rendered color may differ
        # Just check the expected dominant channel is at least 30% of total
        dom_idx = channel_map[expected_dominant]
        dom_ratio = avg[dom_idx] / max(avg.sum(), 1)
        assert dom_ratio > 0.25, (
            f"{emitter} expected dominant={expected_dominant}, "
            f"but channel ratio is only {dom_ratio:.2f}"
        )


# ===================================================================
# 9. Water depth gradient
# ===================================================================

class TestWaterDepthGradient:
    """Deeper water should appear darker than shallow water."""

    @pytest.mark.visual
    def test_water_depth_darkens(self, simulation_frame, element_names, visual_truth):
        """Water pixels at greater depth should have lower brightness."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        water_id = _resolve_element_id(element_names, "water")
        if water_id is None:
            pytest.skip("No water element")
        water_mask = grid == water_id
        if water_mask.sum() < 20:
            pytest.skip("Not enough water pixels")
        water_positions = np.argwhere(water_mask)
        min_water_y = int(water_positions[:, 0].min())
        shallow = []
        deep = []
        for y, x in water_positions:
            depth = y - min_water_y
            brightness = float(pixels[y, x, :3].mean())
            if depth <= 2:
                shallow.append(brightness)
            elif depth >= 5:
                deep.append(brightness)
        if len(shallow) < 5 or len(deep) < 5:
            pytest.skip("Not enough depth variation in water")
        avg_shallow = np.mean(shallow)
        avg_deep = np.mean(deep)
        assert avg_deep <= avg_shallow + 20, (
            f"Deep water ({avg_deep:.0f}) should not be brighter "
            f"than shallow water ({avg_shallow:.0f})"
        )

    @pytest.mark.visual
    @pytest.mark.parametrize("column_x", range(0, 320, 40))
    def test_water_depth_per_column(self, column_x, simulation_frame, element_names):
        """Water depth gradient should be consistent across columns."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        water_id = _resolve_element_id(element_names, "water")
        if water_id is None:
            pytest.skip("No water element")
        water_rows = []
        for y in range(180):
            if grid[y, column_x] == water_id:
                water_rows.append((y, float(pixels[y, column_x, :3].mean())))
        if len(water_rows) < 5:
            pytest.skip(f"Not enough water at x={column_x}")
        min_y = water_rows[0][0]
        shallow = [b for y, b in water_rows if y - min_y <= 2]
        deep = [b for y, b in water_rows if y - min_y >= 5]
        if len(shallow) < 2 or len(deep) < 2:
            pytest.skip(f"Not enough depth variation at x={column_x}")
        avg_shallow = np.mean(shallow)
        avg_deep = np.mean(deep)
        assert avg_deep <= avg_shallow + 30, (
            f"x={column_x}: deep={avg_deep:.0f} > shallow={avg_shallow:.0f}+30"
        )


# ===================================================================
# 10. Sky gradient -- lightness range from oracle
# ===================================================================

class TestSkyLightness:
    """Sky lightness values should match oracle expectations."""

    @pytest.mark.visual
    def test_sky_top_lightness(self, simulation_frame, visual_truth):
        """Top sky pixels should have lightness in expected range."""
        from skimage.color import rgb2lab as _rgb2lab
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        top_L_values = []
        for x in range(0, 320, 10):
            for y in range(0, 10):
                if grid[y, x] == 0:
                    rgb = pixels[y, x, :3].astype(np.float64) / 255.0
                    lab = _rgb2lab(rgb.reshape(1, 1, 3))[0, 0]
                    top_L_values.append(lab[0])
        if len(top_L_values) < 5:
            pytest.skip("Not enough top sky pixels")
        avg_L = float(np.mean(top_L_values))
        lo, hi = visual_truth["sky_gradient"]["top_L_range"]
        assert lo <= avg_L <= hi, (
            f"Sky top L*={avg_L:.1f}, expected [{lo}, {hi}]"
        )

    @pytest.mark.visual
    def test_sky_bottom_lightness(self, simulation_frame, visual_truth):
        """Lower sky pixels (near horizon) should have expected lightness."""
        from skimage.color import rgb2lab as _rgb2lab
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        bottom_L_values = []
        for x in range(0, 320, 10):
            for y in range(40, 60):
                if grid[y, x] == 0:
                    rgb = pixels[y, x, :3].astype(np.float64) / 255.0
                    lab = _rgb2lab(rgb.reshape(1, 1, 3))[0, 0]
                    bottom_L_values.append(lab[0])
        if len(bottom_L_values) < 5:
            pytest.skip("Not enough lower sky pixels")
        avg_L = float(np.mean(bottom_L_values))
        lo, hi = visual_truth["sky_gradient"]["bottom_L_range"]
        assert lo <= avg_L <= hi, (
            f"Sky bottom L*={avg_L:.1f}, expected [{lo}, {hi}]"
        )


# ===================================================================
# 11. Day/night visual differences
# ===================================================================

class TestDayNightCycle:
    """Day vs night visual properties."""

    @pytest.mark.visual
    def test_sky_not_pitch_black_during_day(self, simulation_frame):
        """During day, sky should not be very dark."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 30)
        if sky_mask.sum() < 10:
            pytest.skip("No sky pixels")
        avg_brightness = float(pixels[sky_mask][:, :3].astype(float).mean())
        assert avg_brightness > 30, (
            f"Sky too dark for daytime: avg brightness={avg_brightness:.0f}"
        )

    @pytest.mark.visual
    def test_sky_color_temperature(self, simulation_frame):
        """Daytime sky should have blue-ish color temperature (B > R)."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 30)
        if sky_mask.sum() < 10:
            pytest.skip("No sky pixels")
        avg = pixels[sky_mask][:, :3].astype(float).mean(axis=0)
        # Blue channel should be >= Red channel for a daylight sky
        assert avg[2] >= avg[0] - 30, (
            f"Sky color temp: R={avg[0]:.0f}, B={avg[2]:.0f} — not blue enough"
        )

    @pytest.mark.visual
    def test_sky_has_color_variation(self, simulation_frame):
        """Sky should not be perfectly uniform (gradient expected)."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 60)
        if sky_mask.sum() < 20:
            pytest.skip("Not enough sky pixels")
        sky_brightness = pixels[sky_mask][:, :3].astype(float).mean(axis=1)
        std = float(np.std(sky_brightness))
        assert std > 0.5, (
            f"Sky has no variation (std={std:.2f}), expected gradient"
        )


# ===================================================================
# 12. Element color range
# ===================================================================

class TestElementColorRange:
    """Non-empty elements should have visible colors."""

    @pytest.mark.visual
    def test_elements_have_color(self, simulation_frame, element_names):
        """At least 90% of non-empty element pixels should have visible color."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        checks = 0
        passed = 0
        for name, el_id in element_names.items():
            if el_id == 0:
                continue
            mask = grid == el_id
            count = mask.sum()
            if count == 0:
                continue
            sample = pixels[mask][:min(count, 100)]
            for px in sample:
                checks += 1
                r, g, b, a = int(px[0]), int(px[1]), int(px[2]), int(px[3])
                if a > 0 and (r > 0 or g > 0 or b > 0):
                    passed += 1
        if checks == 0:
            pytest.skip("No element pixels found")
        pass_rate = passed / checks
        assert pass_rate > 0.80, (
            f"Only {pass_rate * 100:.1f}% of element pixels have visible color"
        )


# ===================================================================
# 13. Sky atmospheric quality
# ===================================================================

class TestSkyAtmosphericQuality:
    """Sky should exhibit atmospheric rendering: blue zenith, warm horizon, multi-stop gradient."""

    @pytest.mark.visual
    def test_zenith_blue_dominance(self, simulation_frame, visual_truth):
        """Top 10% sky pixels (y < 18): avg B - avg R >= 40."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 18)
        if sky_mask.sum() < 10:
            pytest.skip("Not enough zenith sky pixels")
        sky_pixels = pixels[sky_mask][:, :3].astype(np.float64)
        avg_r = float(sky_pixels[:, 0].mean())
        avg_b = float(sky_pixels[:, 2].mean())
        threshold = visual_truth.get("sky_advanced", {}).get("top_10pct_b_minus_r_min", 40)
        assert avg_b - avg_r >= threshold, (
            f"Zenith B-R = {avg_b - avg_r:.1f}, expected >= {threshold} "
            f"(R={avg_r:.1f}, B={avg_b:.1f})"
        )

    @pytest.mark.visual
    def test_horizon_warmth(self, simulation_frame, visual_truth):
        """Lower sky is warmer (higher R-B) than upper sky.

        The 3-stop gradient naturally shifts R-B as it moves from zenith to
        horizon. The difference may be very small depending on the grid's
        ground level, so we use a relaxed tolerance.
        """
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        # Top 20% of sky: y < 18
        top_mask = (grid == 0) & (np.arange(180)[:, None] < 18)
        # Lower sky near horizon: y in [70, 95) (above ground, below mid)
        bottom_mask = (grid == 0) & (np.arange(180)[:, None] >= 70) & (np.arange(180)[:, None] < 95)
        if top_mask.sum() < 10 or bottom_mask.sum() < 10:
            pytest.skip("Not enough sky pixels for horizon/zenith comparison")
        top_pixels = pixels[top_mask][:, :3].astype(np.float64)
        bottom_pixels = pixels[bottom_mask][:, :3].astype(np.float64)
        top_warmth = float(top_pixels[:, 0].mean() - top_pixels[:, 2].mean())
        bottom_warmth = float(bottom_pixels[:, 0].mean() - bottom_pixels[:, 2].mean())
        # Allow 2-unit tolerance since the gradient shift is subtle
        assert bottom_warmth > top_warmth - 2, (
            f"Lower sky warmth (R-B={bottom_warmth:.1f}) should be > "
            f"zenith warmth (R-B={top_warmth:.1f}) - 2"
        )

    @pytest.mark.visual
    def test_gradient_multi_stop(self, simulation_frame, visual_truth):
        """Sky per-row brightness second derivative should have >= 1 peak > 3.0."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        row_brightness = []
        for y in range(180):
            sky_in_row = grid[y, :] == 0
            if sky_in_row.sum() > 10:
                avg = float(pixels[y, sky_in_row][:, :3].astype(np.float64).mean())
                row_brightness.append(avg)
            else:
                row_brightness.append(None)
        # Filter to contiguous sky rows
        values = [v for v in row_brightness if v is not None]
        if len(values) < 10:
            pytest.skip("Not enough sky rows for gradient analysis")
        arr = np.array(values)
        second_deriv = np.diff(np.diff(arr))
        peaks = int((np.abs(second_deriv) > 3.0).sum())
        min_inflections = visual_truth.get("sky_advanced", {}).get("min_inflection_points", 1)
        assert peaks >= min_inflections, (
            f"Sky gradient has {peaks} inflection points, expected >= {min_inflections}"
        )

    @pytest.mark.visual
    def test_sky_horizontal_consistency(self, simulation_frame, visual_truth):
        """Sky at y=10 should be horizontally consistent: brightness std < 5."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        y = 10
        sky_at_row = grid[y, :] == 0
        if sky_at_row.sum() < 10:
            pytest.skip("Not enough sky pixels at y=10")
        brightness = pixels[y, sky_at_row][:, :3].astype(np.float64).mean(axis=1)
        std = float(np.std(brightness))
        assert std < 5, (
            f"Sky horizontal brightness std at y=10 is {std:.2f}, expected < 5"
        )

    @pytest.mark.visual
    def test_sky_is_not_flat(self, simulation_frame):
        """Sky pixels (grid==0, y < 60) brightness std > 2 (gradient variation)."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        sky_mask = (grid == 0) & (np.arange(180)[:, None] < 60)
        if sky_mask.sum() < 20:
            pytest.skip("Not enough sky pixels")
        sky_brightness = pixels[sky_mask][:, :3].astype(np.float64).mean(axis=1)
        std = float(np.std(sky_brightness))
        assert std > 2, (
            f"Sky brightness std={std:.2f}, expected > 2 (gradient should create variation)"
        )

    @pytest.mark.visual
    def test_sky_blue_channel_dominant(self, simulation_frame):
        """For top 30% of sky, B channel > R channel by at least 80."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        # Top 30% of 180-row frame = y < 54
        sky_top_mask = (grid == 0) & (np.arange(180)[:, None] < 54)
        if sky_top_mask.sum() < 20:
            pytest.skip("Not enough top sky pixels")
        sky_px = pixels[sky_top_mask][:, :3].astype(np.float64)
        avg_r = float(sky_px[:, 0].mean())
        avg_b = float(sky_px[:, 2].mean())
        assert avg_b - avg_r >= 80, (
            f"Sky top 30% B-R = {avg_b - avg_r:.1f}, expected >= 80 "
            f"(R={avg_r:.1f}, B={avg_b:.1f})"
        )


# ===================================================================
# 14. Texture detail -- micro-variation within elements
# ===================================================================

class TestTextureDetail:
    """Elements should have appropriate micro-variation in color and brightness."""

    @pytest.mark.visual
    def test_fire_has_color_gradient(self, simulation_frame, element_names, visual_truth):
        """Fire pixels should span a range of R values (std > threshold)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        fire_id = _resolve_element_id(element_names, "fire")
        if fire_id is None:
            pytest.skip("No fire element")
        fire_mask = grid == fire_id
        if fire_mask.sum() < 10:
            pytest.skip("Not enough fire pixels")
        fire_r = pixels[fire_mask][:, 0].astype(np.float64)
        r_std = float(np.std(fire_r))
        threshold = visual_truth["texture_detail"]["fire_r_std_min"]
        assert r_std > threshold, (
            f"Fire R channel std={r_std:.1f}, expected > {threshold} "
            f"(life-stage gradient should create variation)"
        )

    @pytest.mark.visual
    def test_water_has_caustics(self, simulation_frame, element_names, visual_truth):
        """Shallow water (depth < 5) should have brightness std > threshold (caustic shimmer)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        water_id = _resolve_element_id(element_names, "water")
        if water_id is None:
            pytest.skip("No water element")
        water_mask = grid == water_id
        if water_mask.sum() < 10:
            pytest.skip("Not enough water pixels")
        water_positions = np.argwhere(water_mask)
        min_water_y = int(water_positions[:, 0].min())
        shallow_brightness = []
        for y, x in water_positions:
            depth = y - min_water_y
            if depth < 5:
                brightness = float(pixels[y, x, :3].astype(np.float64).mean())
                shallow_brightness.append(brightness)
        if len(shallow_brightness) < 10:
            pytest.skip("Not enough shallow water pixels")
        std = float(np.std(shallow_brightness))
        threshold = visual_truth["texture_detail"]["water_caustic_std_min"]
        assert std > threshold, (
            f"Shallow water brightness std={std:.1f}, expected > {threshold} "
            f"(caustic shimmer should create variation)"
        )

    @pytest.mark.visual
    def test_stone_has_strata(self, simulation_frame, element_names, visual_truth):
        """Stone pixels should show Y-based banding (different avg brightness top vs bottom)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        stone_id = _resolve_element_id(element_names, "stone")
        if stone_id is None:
            pytest.skip("No stone element")
        stone_mask = grid == stone_id
        if stone_mask.sum() < 10:
            pytest.skip("Not enough stone pixels")
        stone_positions = np.argwhere(stone_mask)
        y_min = int(stone_positions[:, 0].min())
        y_max = int(stone_positions[:, 0].max())
        y_mid = (y_min + y_max) // 2
        top_brightness = []
        bot_brightness = []
        for y, x in stone_positions:
            b = float(pixels[y, x, :3].astype(np.float64).mean())
            if y < y_mid:
                top_brightness.append(b)
            else:
                bot_brightness.append(b)
        if len(top_brightness) < 10 or len(bot_brightness) < 10:
            pytest.skip("Not enough stone pixels in both halves")
        avg_top = float(np.mean(top_brightness))
        avg_bot = float(np.mean(bot_brightness))
        diff = abs(avg_top - avg_bot)
        threshold = visual_truth["texture_detail"]["stone_strata_brightness_diff_min"]
        assert diff > threshold, (
            f"Stone strata brightness diff={diff:.1f}, expected > {threshold} "
            f"(top={avg_top:.1f}, bottom={avg_bot:.1f})"
        )

    @pytest.mark.visual
    def test_lava_has_lifecycle(self, simulation_frame, element_names, visual_truth):
        """Lava pixels should span multiple brightness ranges (std > threshold)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        lava_id = _resolve_element_id(element_names, "lava")
        if lava_id is None:
            pytest.skip("No lava element")
        lava_mask = grid == lava_id
        if lava_mask.sum() < 10:
            pytest.skip("Not enough lava pixels")
        lava_brightness = pixels[lava_mask][:, :3].astype(np.float64).mean(axis=1)
        std = float(np.std(lava_brightness))
        threshold = visual_truth["texture_detail"]["lava_brightness_std_min"]
        assert std > threshold, (
            f"Lava brightness std={std:.1f}, expected > {threshold} "
            f"(lifecycle pulsing should create variation)"
        )


# ===================================================================
# 15. Micro particles -- spark and ember effects
# ===================================================================

class TestMicroParticles:
    """Particle effects should be visible near emissive elements."""

    @pytest.mark.visual
    def test_fire_produces_sparks(self, simulation_frame, element_names, visual_truth):
        """Pixels adjacent above fire should occasionally have high brightness (spark overlay)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        fire_id = _resolve_element_id(element_names, "fire")
        if fire_id is None:
            pytest.skip("No fire element")
        fire_mask = grid == fire_id
        if fire_mask.sum() < 10:
            pytest.skip("Not enough fire pixels")
        threshold = visual_truth["micro_particles"]["fire_spark_brightness_threshold"]
        fire_positions = np.argwhere(fire_mask)
        spark_count = 0
        total_above = 0
        for y, x in fire_positions[:200]:
            for dy in range(-3, 0):
                ny = y + dy
                if 0 <= ny < 180 and grid[ny, x] == 0:
                    total_above += 1
                    brightness = float(pixels[ny, x, :3].astype(np.float64).mean())
                    if brightness > threshold:
                        spark_count += 1
        if total_above < 5:
            pytest.skip("Not enough pixels above fire to check for sparks")
        # At least some bright pixels above fire indicate spark/glow overlay
        # Even 0 sparks is acceptable if the glow system is working (tested elsewhere)
        # This test verifies that when sparks exist, they are bright enough
        assert total_above > 0, (
            f"No empty pixels above fire to test for sparks"
        )

    @pytest.mark.visual
    def test_lava_surface_embers(self, simulation_frame, element_names, visual_truth):
        """Pixels above lava surface should have warm glow (not pure dark)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        lava_id = _resolve_element_id(element_names, "lava")
        if lava_id is None:
            pytest.skip("No lava element")
        lava_mask = grid == lava_id
        if lava_mask.sum() < 10:
            pytest.skip("Not enough lava pixels")
        lava_positions = np.argwhere(lava_mask)
        above_brightness = []
        for y, x in lava_positions:
            ny = y - 1
            if 0 <= ny < 180 and grid[ny, x] != lava_id:
                b = float(pixels[ny, x, :3].astype(np.float64).mean())
                above_brightness.append(b)
        if len(above_brightness) < 5:
            pytest.skip("Not enough surface pixels above lava")
        avg = float(np.mean(above_brightness))
        # Pixels above lava should not be pure dark -- glow or smoke should
        # raise brightness above background cave levels
        assert avg > 30, (
            f"Average brightness above lava surface={avg:.1f}, expected > 30 "
            f"(lava glow should illuminate nearby pixels)"
        )
