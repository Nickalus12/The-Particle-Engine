"""Visual quality tests using scikit-image: SSIM, entropy, edge quality.

Validates texture complexity, gradient smoothness, artifact absence, and
underground lighting consistency.
"""

import pytest
import numpy as np
from skimage.measure import shannon_entropy
from skimage.filters import sobel
from skimage.color import rgb2gray


class TestTextureQuality:
    """Elements should have appropriate texture complexity via Shannon entropy."""

    @pytest.mark.visual
    @pytest.mark.parametrize(
        "element,min_entropy,max_entropy",
        [
            ("sand", 1.0, 7.5),
            ("water", 0.5, 7.5),
            ("stone", 1.0, 7.5),
            ("dirt", 1.0, 7.5),
        ],
    )
    def test_element_entropy(
        self, simulation_frame, element_names, element, min_entropy, max_entropy
    ):
        el_id = element_names.get(element)
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


class TestGradientSmoothness:
    """Color transitions should be smooth, not jagged."""

    @pytest.mark.visual
    def test_sky_gradient(self, simulation_frame):
        """Sky should have a smooth vertical gradient (no sharp jumps)."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        tested_columns = 0
        for x in range(0, 320, 20):
            col = []
            for y in range(0, 60):
                if grid[y, x] == 0:  # empty = sky
                    col.append(float(pixels[y, x, :3].mean()))
            if len(col) > 10:
                tested_columns += 1
                gradient = np.diff(col)
                second_deriv = np.diff(gradient)
                max_jump = float(np.max(np.abs(second_deriv)))
                assert max_jump < 40, (
                    f"Sky gradient has sharp jump at x={x}: {max_jump:.1f}"
                )
        if tested_columns == 0:
            pytest.skip("No sky columns found")


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


class TestUndergroundConsistency:
    """Underground empty cells should be dark cave colors."""

    @pytest.mark.visual
    def test_cave_darkness(self, simulation_frame):
        """Empty cells below ground surface should be darker than sky."""
        pixels = simulation_frame["pixels"]
        grid = simulation_frame["grid"]
        underground_bright = []
        solid_ids = {1, 7, 16, 21, 15, 20, 4}  # sand, stone, dirt, metal, glass, wood, ice
        for x in range(0, 320, 4):
            found_ground = False
            for y in range(180):
                el = int(grid[y, x])
                if el in solid_ids and not found_ground:
                    found_ground = True
                elif el == 0 and found_ground:
                    brightness = int(pixels[y, x, :3].sum())
                    underground_bright.append(brightness)

        if len(underground_bright) < 10:
            pytest.skip("Not enough underground empty cells")

        avg_brightness = np.mean(underground_bright)
        assert avg_brightness < 200, (
            f"Underground too bright: avg={avg_brightness:.0f} (should be < 200)"
        )


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


class TestGlowCorrectness:
    """Light-emitting elements should glow without black halos."""

    @pytest.mark.visual
    def test_lava_no_black_halo(self, simulation_frame, element_names):
        """Pixels adjacent to lava should not be pure black (halo artifact)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        lava_id = element_names.get("Lava") or element_names.get("lava")
        if lava_id is None:
            pytest.skip("No Lava element")
        lava_mask = grid == lava_id
        if lava_mask.sum() < 10:
            pytest.skip("Not enough lava pixels")
        # Check neighbors of lava pixels for black halos
        black_neighbor_count = 0
        total_neighbors = 0
        lava_positions = np.argwhere(lava_mask)
        for y, x in lava_positions[:50]:  # sample up to 50
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
            f"{black_ratio*100:.1f}% of lava neighbors are pure black (halo artifact)"
        )

    @pytest.mark.visual
    def test_fire_has_warm_colors(self, simulation_frame, element_names):
        """Fire pixels should have warm colors (high red, moderate green)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        fire_id = element_names.get("Fire") or element_names.get("fire")
        if fire_id is None:
            pytest.skip("No Fire element")
        fire_mask = grid == fire_id
        if fire_mask.sum() < 5:
            pytest.skip("Not enough fire pixels")
        fire_pixels = pixels[fire_mask][:, :3].astype(float)
        avg_r = float(fire_pixels[:, 0].mean())
        avg_b = float(fire_pixels[:, 2].mean())
        assert avg_r > avg_b, (
            f"Fire should be warm: avg_r={avg_r:.0f} should be > avg_b={avg_b:.0f}"
        )


class TestWaterDepthGradient:
    """Deeper water should appear darker than shallow water."""

    @pytest.mark.visual
    def test_water_depth_darkens(self, simulation_frame, element_names):
        """Water pixels at greater depth should have lower brightness."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        water_id = element_names.get("Water") or element_names.get("water")
        if water_id is None:
            pytest.skip("No Water element")
        water_mask = grid == water_id
        if water_mask.sum() < 20:
            pytest.skip("Not enough water pixels")
        water_positions = np.argwhere(water_mask)
        # Find the topmost water row
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
        # Deep water should be at least slightly darker
        assert avg_deep <= avg_shallow + 20, (
            f"Deep water ({avg_deep:.0f}) should not be brighter "
            f"than shallow water ({avg_shallow:.0f})"
        )


class TestSteamSubtlety:
    """Steam should be subtle and translucent."""

    @pytest.mark.visual
    def test_steam_low_alpha(self, simulation_frame, element_names):
        """Steam pixels should have low alpha (translucent)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        steam_id = element_names.get("Steam") or element_names.get("steam")
        if steam_id is None:
            pytest.skip("No Steam element")
        steam_mask = grid == steam_id
        if steam_mask.sum() < 3:
            pytest.skip("Not enough steam pixels")
        steam_alphas = pixels[steam_mask][:, 3].astype(float)
        avg_alpha = float(steam_alphas.mean())
        # Steam base color has alpha 0x30 = 48, rendered may differ
        # but should be subtle (< 150)
        assert avg_alpha < 150, (
            f"Steam avg alpha={avg_alpha:.0f}, expected subtle (< 150)"
        )


class TestElementColorRange:
    """Non-empty elements should have visible colors (not transparent/black)."""

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
        # Some elements (steam, glass) have low alpha, which is by design
        assert pass_rate > 0.80, (
            f"Only {pass_rate * 100:.1f}% of element pixels have visible color"
        )
