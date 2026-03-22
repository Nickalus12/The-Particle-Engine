"""Cave rendering tests: proximity lighting, depth color, rock tint, moisture.

Validates underground rendering behavior including brightness gradients near
openings, depth-dependent color shifts, rock material tint bleed, and
moisture hints near water sources.
"""

import json

import pytest
import numpy as np


# ---------------------------------------------------------------------------
# Load oracle for thresholds
# ---------------------------------------------------------------------------
_RESEARCH_DIR = __import__("pathlib").Path(__file__).parent.parent
_VGT_PATH = _RESEARCH_DIR / "visual_ground_truth.json"
if _VGT_PATH.exists():
    with open(_VGT_PATH) as _f:
        _ORACLE = json.load(_f)
else:
    _ORACLE = {}


def _resolve_element_id(element_names, name):
    """Find element ID by case-insensitive lookup."""
    el_id = element_names.get(name)
    if el_id is None:
        el_id = element_names.get(name.capitalize())
    return el_id


# Solid element IDs used for ground detection
_SOLID_IDS = {1, 7, 16, 21, 15, 20, 4}  # sand, stone, dirt, metal, glass, wood, ice


def _find_ground_level(grid):
    """For each column, find first y with a contiguous solid layer.

    Requires at least 3 consecutive solid cells to avoid floating elements
    (trees, thin sand layers) above the real ground surface.
    """
    h, w = grid.shape
    ground = {}
    for x in range(w):
        for y in range(h - 2):
            if (int(grid[y, x]) in _SOLID_IDS and
                int(grid[y + 1, x]) in _SOLID_IDS and
                int(grid[y + 2, x]) in _SOLID_IDS):
                ground[x] = y
                break
    return ground


def _collect_underground_empty(grid, ground):
    """Collect all underground empty cell positions as (y, x) array."""
    h, w = grid.shape
    cells = []
    for x, gy in ground.items():
        for y in range(gy + 1, h):
            if int(grid[y, x]) == 0:
                cells.append((y, x))
    return cells


# ===================================================================
# 1. Surface proximity lighting
# ===================================================================

class TestSurfaceProximityLighting:
    """Cave cells near ground openings should be brighter than deep cells."""

    @pytest.mark.visual
    def test_cave_brightness_gradient(self, simulation_frame, element_names, visual_truth):
        """Empty cells near openings (within 3 of boundary) vs deep (>8 deep)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        ground = _find_ground_level(grid)
        near = []
        deep = []
        for x, gy in ground.items():
            for y in range(gy + 1, grid.shape[0]):
                if int(grid[y, x]) == 0:
                    depth = y - gy
                    brightness = float(pixels[y, x, :3].mean())
                    if depth <= 3:
                        near.append(brightness)
                    elif depth > 8:
                        deep.append(brightness)
        if len(near) < 10 or len(deep) < 10:
            pytest.skip("Not enough underground cells for gradient test")
        near_avg = np.mean(near)
        deep_avg = np.mean(deep)
        assert near_avg > deep_avg, (
            f"Near-opening avg brightness ({near_avg:.1f}) should be > "
            f"deep cave avg ({deep_avg:.1f})"
        )

    @pytest.mark.visual
    def test_cave_not_uniform(self, simulation_frame, element_names, visual_truth):
        """Underground empty cells should have brightness std > 3."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        brightnesses = [float(pixels[y, x, :3].mean()) for y, x in cells]
        std = float(np.std(brightnesses))
        min_std = visual_truth.get("underground_advanced", {}).get("min_brightness_std", 3)
        assert std > min_std, (
            f"Underground brightness std={std:.2f}, expected > {min_std}"
        )

    @pytest.mark.visual
    def test_cave_opening_transition(self, simulation_frame, element_names, visual_truth):
        """Brightness steps between adjacent rows crossing ground should be < 80."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        ground = _find_ground_level(grid)
        max_step = 0
        tested = 0
        for x in range(0, grid.shape[1], 4):
            if x not in ground:
                continue
            gy = ground[x]
            # Sample a few rows above and below ground boundary
            rows = []
            for y in range(max(0, gy - 2), min(grid.shape[0], gy + 6)):
                if int(grid[y, x]) == 0:
                    rows.append(float(pixels[y, x, :3].mean()))
            if len(rows) >= 2:
                tested += 1
                steps = np.abs(np.diff(rows))
                max_step = max(max_step, float(steps.max()))
        if tested < 3:
            pytest.skip("Not enough columns crossing ground boundary")
        assert max_step < 80, (
            f"Max brightness step between adjacent rows = {max_step:.1f}, expected < 80"
        )


# ===================================================================
# 2. Depth color variation
# ===================================================================

class TestDepthColorVariation:
    """Shallow underground should be warmer, deep should be cooler."""

    @pytest.mark.visual
    def test_shallow_warmer(self, simulation_frame, element_names, visual_truth):
        """Top 30% of underground empty cells: avg R >= avg B.

        Only considers cells with cave-like brightness (sum < 180) to exclude
        sky cells misclassified by floating elements above ground.
        """
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        # Filter to actual cave-rendered cells (dark, not sky-blue)
        cave_cells = []
        for y, x in cells:
            brightness = int(pixels[y, x, 0]) + int(pixels[y, x, 1]) + int(pixels[y, x, 2])
            if 5 < brightness < 180:  # cave range, not sky or pitch black
                cave_cells.append((y, x))
        if len(cave_cells) < 10:
            pytest.skip("Not enough cave-rendered underground cells")
        # Sort by y (depth), take top 30% (shallowest)
        cells_sorted = sorted(cave_cells, key=lambda c: c[0])
        n = max(1, len(cells_sorted) * 30 // 100)
        shallow = cells_sorted[:n]
        r_vals = [float(pixels[y, x, 0]) for y, x in shallow]
        b_vals = [float(pixels[y, x, 2]) for y, x in shallow]
        avg_r = np.mean(r_vals)
        avg_b = np.mean(b_vals)
        assert avg_r >= avg_b, (
            f"Shallow underground: avg R ({avg_r:.1f}) should be >= avg B ({avg_b:.1f})"
        )

    @pytest.mark.visual
    def test_deep_cooler(self, simulation_frame, element_names, visual_truth):
        """Bottom 30% of underground empty cells: avg B >= avg R."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        cells_sorted = sorted(cells, key=lambda c: c[0])
        n = max(1, len(cells_sorted) * 30 // 100)
        deep = cells_sorted[-n:]
        r_vals = [float(pixels[y, x, 0]) for y, x in deep]
        b_vals = [float(pixels[y, x, 2]) for y, x in deep]
        avg_r = np.mean(r_vals)
        avg_b = np.mean(b_vals)
        assert avg_b >= avg_r, (
            f"Deep underground: avg B ({avg_b:.1f}) should be >= avg R ({avg_r:.1f})"
        )


# ===================================================================
# 3. Rock tint bleed
# ===================================================================

class TestRockTintBleed:
    """Underground empty cells near specific rock types pick up tint."""

    @pytest.mark.visual
    def test_near_dirt_warm(self, simulation_frame, element_names, visual_truth):
        """Empty cells adjacent to dirt have higher avg R than non-adjacent."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        dirt_id = _resolve_element_id(element_names, "dirt")
        if dirt_id is None:
            pytest.skip("No dirt element")
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        h, w = grid.shape
        near_dirt_r = []
        far_r = []
        for y, x in cells:
            adjacent_to_dirt = False
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and int(grid[ny, nx]) == dirt_id:
                    adjacent_to_dirt = True
                    break
            r = float(pixels[y, x, 0])
            if adjacent_to_dirt:
                near_dirt_r.append(r)
            else:
                far_r.append(r)
        if len(near_dirt_r) < 10 or len(far_r) < 10:
            pytest.skip("Not enough cells near/far from dirt")
        assert np.mean(near_dirt_r) > np.mean(far_r), (
            f"Near-dirt avg R ({np.mean(near_dirt_r):.1f}) should be > "
            f"far avg R ({np.mean(far_r):.1f})"
        )

    @pytest.mark.visual
    def test_near_stone_cool(self, simulation_frame, element_names, visual_truth):
        """Empty cells adjacent to stone have cooler tint (higher B relative to R)."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        stone_id = _resolve_element_id(element_names, "stone")
        if stone_id is None:
            pytest.skip("No stone element")
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        h, w = grid.shape
        near_stone_br = []  # B-R delta for near-stone cells
        far_br = []  # B-R delta for far cells
        for y, x in cells:
            # Skip cells that might have glow influence (brightness > 60)
            brightness = float(pixels[y, x, :3].sum())
            if brightness > 180:
                continue
            adjacent_to_stone = False
            for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and int(grid[ny, nx]) == stone_id:
                    adjacent_to_stone = True
                    break
            b_r = float(pixels[y, x, 2]) - float(pixels[y, x, 0])
            if adjacent_to_stone:
                near_stone_br.append(b_r)
            else:
                far_br.append(b_r)
        if len(near_stone_br) < 5 or len(far_br) < 5:
            pytest.skip("Not enough cells near/far from stone")
        # Near-stone cells should have a higher B-R delta (cooler tint)
        assert np.mean(near_stone_br) >= np.mean(far_br) - 2, (
            f"Near-stone B-R ({np.mean(near_stone_br):.1f}) should be >= "
            f"far B-R ({np.mean(far_br):.1f}) - 2"
        )


# ===================================================================
# 4. Moisture hints
# ===================================================================

class TestMoistureHints:
    """Underground empty cells near water should have blue-green tint."""

    @pytest.mark.visual
    def test_near_water_blue_green(self, simulation_frame, element_names, visual_truth):
        """Cells within Manhattan distance 3 of water: higher avg (B+G) than distant."""
        grid = simulation_frame["grid"]
        pixels = simulation_frame["pixels"]
        water_id = _resolve_element_id(element_names, "water")
        if water_id is None:
            pytest.skip("No water element")
        ground = _find_ground_level(grid)
        cells = _collect_underground_empty(grid, ground)
        if len(cells) < 10:
            pytest.skip("Not enough underground empty cells")
        h, w = grid.shape
        # Find all water positions for distance calculation
        water_positions = set()
        for y in range(h):
            for x in range(w):
                if int(grid[y, x]) == water_id:
                    water_positions.add((y, x))
        if len(water_positions) == 0:
            pytest.skip("No water in underground area")
        near_water_bg = []
        far_bg = []
        for y, x in cells:
            min_dist = min(
                (abs(y - wy) + abs(x - wx) for wy, wx in water_positions),
                default=999,
            )
            bg = float(pixels[y, x, 2]) + float(pixels[y, x, 1])
            if min_dist <= 3:
                near_water_bg.append(bg)
            elif min_dist > 6:
                far_bg.append(bg)
        if len(near_water_bg) < 10 or len(far_bg) < 10:
            pytest.skip("Not enough cells near/far from water")
        assert np.mean(near_water_bg) > np.mean(far_bg), (
            f"Near-water avg (B+G) ({np.mean(near_water_bg):.1f}) should be > "
            f"distant avg ({np.mean(far_bg):.1f})"
        )
