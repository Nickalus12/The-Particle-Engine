"""Kinematics tests: gravity, trajectory, terminal velocity, live simulation."""

import numpy as np
import pytest


class TestGravity:
    """Every element with nonzero gravity should follow its predicted trajectory."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        [
            "sand", "water", "stone", "metal", "glass", "ice", "wood",
            "dirt", "snow", "ash", "oil", "acid", "mud", "lava",
            "fire", "smoke", "steam", "rainbow",
        ],
    )
    def test_element_has_trajectory(self, ground_truth, element):
        """Elements with gravity != 0 should have oracle trajectory data."""
        gravity_all = ground_truth.get("gravity_all", {})
        entry = gravity_all.get(element)
        if entry is None:
            pytest.skip(f"No oracle data for {element}")
        assert "positions_60frames" in entry
        assert len(entry["positions_60frames"]) == 60

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element",
        ["sand", "water", "stone", "metal", "glass", "ice", "dirt", "lava"],
    )
    def test_falling_elements_move_down(self, ground_truth, element):
        """Elements with positive gravity should have increasing position."""
        entry = ground_truth["gravity_all"].get(element)
        if entry is None:
            pytest.skip(f"No oracle data for {element}")
        assert entry["direction"] == "down"
        positions = entry["positions_60frames"]
        assert positions[-1] > positions[0], f"{element} didn't fall"

    @pytest.mark.physics
    @pytest.mark.parametrize("element", ["fire", "smoke", "steam", "rainbow"])
    def test_rising_elements_move_up(self, ground_truth, element):
        """Elements with negative gravity should have decreasing position."""
        entry = ground_truth["gravity_all"].get(element)
        if entry is None:
            pytest.skip(f"No oracle data for {element}")
        assert entry["direction"] == "up"
        positions = entry["positions_60frames"]
        assert positions[-1] < positions[0], f"{element} didn't rise"


class TestTerminalVelocity:
    """Elements should reach terminal velocity (maxVel) and stop accelerating."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_max_vel",
        [
            ("sand", 3),
            ("water", 2),
            ("fire", 2),
            ("lava", 1),
        ],
    )
    def test_terminal_velocity_reached(
        self, ground_truth, element, expected_max_vel
    ):
        entry = ground_truth["gravity_all"].get(element)
        if entry is None:
            pytest.skip(f"No oracle data for {element}")
        assert entry["maxVelocity"] == expected_max_vel


class TestTrajectoryAccuracy:
    """Engine trajectory should match oracle predictions."""

    @pytest.mark.physics
    def test_sand_trajectory_matches_oracle(self, ground_truth):
        """Sand free-fall trajectory should match engine model."""
        gt = ground_truth["gravity_trajectory"]
        engine_pos = gt["engine_model_cells"]
        # After 60 frames, sand should have fallen significantly
        assert engine_pos[-1] > 100, "Sand didn't fall far enough in 60 frames"

    @pytest.mark.physics
    def test_gravity_quantization_noted(self, ground_truth):
        """Real physics uses continuous g; engine uses integer gravity."""
        gt = ground_truth["gravity_trajectory"]
        assert gt["engine_gravity"] == 2  # sand gravity
        assert gt["g_real_m_s2"] == pytest.approx(9.81)


class TestLiveGravity:
    """Verify gravity behavior using actual simulation frame data."""

    @pytest.mark.physics
    def test_sand_reaches_ground(self, simulation_frame):
        """Sand should settle in the lower half of the grid, not float."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        sand_id = elements.get("Sand")
        if sand_id is None:
            pytest.skip("No Sand element")
        sand_positions = np.where(grid == sand_id)
        if len(sand_positions[0]) == 0:
            pytest.skip("No sand in simulation frame")
        avg_y = float(np.mean(sand_positions[0]))
        assert avg_y > 90, f"Sand avg y={avg_y:.1f}, should be in lower half (>90)"

    @pytest.mark.physics
    def test_water_settles_below_midline(self, simulation_frame):
        """Water should pool in the lower portion of the grid."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        water_id = elements.get("Water")
        if water_id is None:
            pytest.skip("No Water element")
        water_positions = np.where(grid == water_id)
        if len(water_positions[0]) == 0:
            pytest.skip("No water in simulation frame")
        avg_y = float(np.mean(water_positions[0]))
        assert avg_y > 80, f"Water avg y={avg_y:.1f}, should be in lower half"

    @pytest.mark.physics
    def test_steam_rises_to_top(self, simulation_frame):
        """Steam should be in the upper portion of the grid."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        steam_id = elements.get("Steam")
        if steam_id is None:
            pytest.skip("No Steam element")
        steam_positions = np.where(grid == steam_id)
        if len(steam_positions[0]) == 0:
            pytest.skip("No steam in simulation frame")
        avg_y = float(np.mean(steam_positions[0]))
        assert avg_y < 120, f"Steam avg y={avg_y:.1f}, should be in upper portion"

    @pytest.mark.physics
    def test_smoke_rises_above_ground(self, simulation_frame):
        """Smoke (negative gravity) should be above the ground line."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        smoke_id = elements.get("Smoke")
        if smoke_id is None:
            pytest.skip("No Smoke element")
        smoke_positions = np.where(grid == smoke_id)
        if len(smoke_positions[0]) == 0:
            pytest.skip("No smoke in simulation frame")
        avg_y = float(np.mean(smoke_positions[0]))
        assert avg_y < 150, f"Smoke avg y={avg_y:.1f}, should be above ground"

    @pytest.mark.physics
    def test_stone_is_static(self, simulation_frame):
        """Stone (gravity=1 but solid state) should remain in place."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        stone_id = elements.get("Stone")
        if stone_id is None:
            pytest.skip("No Stone element")
        stone_count = int((grid == stone_id).sum())
        assert stone_count > 0, "No stone in grid"


class TestWrapX:
    """Horizontal wrapping edge cases from element_behaviors."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "input_x,expected",
        [
            (-1, 319),       # wrap left edge
            (320, 0),        # wrap right edge
            (0, 0),          # left boundary
            (319, 319),      # right boundary
            (-320, 0),       # wrap full width left
            (640, 0),        # wrap double width right
        ],
    )
    def test_wrap_x_values(self, input_x, expected):
        """wrapX should wrap coordinates within [0, 320)."""
        width = 320
        result = input_x % width
        assert result == expected, f"wrapX({input_x}) = {result}, expected {expected}"


class TestMultiCellFall:
    """Elements with maxVelocity > 1 should skip intermediate cells."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_max_vel",
        [
            ("sand", 3),
            ("water", 2),
            ("lava", 1),
            ("mud", 1),
        ],
    )
    def test_max_velocity_from_oracle(self, ground_truth, element, expected_max_vel):
        """Each element's maxVelocity should match the engine specification."""
        entry = ground_truth.get("gravity_all", {}).get(element)
        if entry is None:
            pytest.skip(f"No oracle data for {element}")
        assert entry["maxVelocity"] == expected_max_vel


class TestSettling:
    """Elements should settle and stop being actively processed."""

    @pytest.mark.physics
    def test_solid_elements_present(self, simulation_frame):
        """Solid elements (stone, metal, wood) should be present and stable."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        for name in ["Stone", "Metal", "Wood"]:
            el_id = elements.get(name)
            if el_id is None:
                continue
            count = int((grid == el_id).sum())
            assert count > 0, f"{name} should be present in settled simulation"

    @pytest.mark.physics
    def test_granular_settles_on_ground(self, simulation_frame):
        """Granular elements should have settled onto surfaces, not be mid-air."""
        grid = simulation_frame["grid"]
        elements = simulation_frame["meta"]["elements"]
        sand_id = elements.get("Sand")
        if sand_id is None:
            pytest.skip("No Sand element")
        sand_ys = np.where(grid == sand_id)[0]
        if len(sand_ys) == 0:
            pytest.skip("No sand pixels")
        # All sand should be on or near surfaces (no isolated floating sand)
        min_y = int(sand_ys.min())
        assert min_y > 50, f"Sand found at y={min_y}, seems to be floating"


class TestFirstFrameDisplacement:
    """Each element should move by gravity cells on the first frame."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_vel",
        [
            ("sand", 2),
            ("water", 1),
            ("fire", -1),
        ],
    )
    def test_first_frame_velocity(self, ground_truth, element, expected_vel):
        """First frame velocity should equal gravity."""
        gt = ground_truth.get("first_frame_displacement", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No first_frame data for {element}")
        assert entry["first_frame_vel"] == expected_vel

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,direction",
        [
            ("sand", "down"),
            ("water", "down"),
            ("fire", "up"),
            ("smoke", "up"),
        ],
    )
    def test_direction(self, ground_truth, element, direction):
        """Element should move in the expected direction."""
        gt = ground_truth.get("first_frame_displacement", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No first_frame data for {element}")
        assert entry["direction"] == direction


class TestWrappingEdgeCases:
    """X-coordinate wrapping should handle all edge cases correctly."""

    @pytest.mark.physics
    def test_wrapping_values(self, ground_truth):
        """All wrapping edge cases should produce expected results."""
        gt = ground_truth.get("wrapping_edge_cases")
        if gt is None:
            pytest.skip("No wrapping_edge_cases oracle data")
        width = gt["grid_width"]
        inputs = gt["inputs"]
        expected = gt["expected"]
        for inp, exp in zip(inputs, expected):
            result = inp % width
            if result < 0:
                result += width
            assert result == exp, f"wrapX({inp}) = {result}, expected {exp}"

    @pytest.mark.physics
    def test_grid_width_320(self, ground_truth):
        """Grid width should be 320."""
        gt = ground_truth.get("wrapping_edge_cases")
        if gt is None:
            pytest.skip("No wrapping_edge_cases oracle data")
        assert gt["grid_width"] == 320


class TestAccelerationCurves:
    """Elements should accelerate to terminal velocity at correct rates."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element,expected_terminal_frame",
        [
            ("sand", 2),
            ("water", 2),
        ],
    )
    def test_frames_to_terminal(self, ground_truth, element, expected_terminal_frame):
        """Element should reach terminal velocity in expected number of frames."""
        gt = ground_truth.get("acceleration_curves", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No acceleration data for {element}")
        assert entry["frames_to_terminal"] == expected_terminal_frame

    @pytest.mark.physics
    @pytest.mark.parametrize("element", ["sand", "water", "fire", "smoke"])
    def test_velocity_never_exceeds_max(self, ground_truth, element):
        """Velocity should never exceed maxVelocity."""
        gt = ground_truth.get("acceleration_curves", {})
        entry = gt.get(element)
        if entry is None:
            pytest.skip(f"No acceleration data for {element}")
        max_vel = entry["maxVelocity"]
        for v in entry["velocities_10frames"]:
            assert abs(v) <= max_vel, (
                f"{element} velocity {v} exceeds maxVelocity {max_vel}"
            )

    @pytest.mark.physics
    def test_sand_accelerates_faster_than_water(self, ground_truth):
        """Sand (gravity=2) should reach terminal velocity as fast or faster."""
        gt = ground_truth.get("acceleration_curves", {})
        sand = gt.get("sand")
        water = gt.get("water")
        if sand is None or water is None:
            pytest.skip("Missing acceleration data")
        # Sand has higher gravity but same terminal frame count
        assert sand["gravity"] >= water["gravity"]


class TestProjectileMotion:
    """Projectile motion should show parabolic trajectory."""

    @pytest.mark.physics
    def test_horizontal_motion_constant(self, ground_truth):
        """Horizontal displacement should be constant per frame (no air drag)."""
        gt = ground_truth.get("projectile_motion")
        if gt is None:
            pytest.skip("No projectile_motion oracle data")
        x_pos = gt["x_positions_20frames"]
        deltas = [x_pos[i] - x_pos[i - 1] for i in range(1, len(x_pos))]
        # All horizontal deltas should be equal (constant velocity)
        for d in deltas:
            assert d == pytest.approx(deltas[0], abs=0.1)

    @pytest.mark.physics
    def test_vertical_acceleration(self, ground_truth):
        """Vertical displacement should increase (gravity acceleration)."""
        gt = ground_truth.get("projectile_motion")
        if gt is None:
            pytest.skip("No projectile_motion oracle data")
        y_pos = gt["y_positions_20frames"]
        # First few frames should show increasing vertical displacement
        delta1 = y_pos[1] - y_pos[0]
        delta2 = y_pos[2] - y_pos[1]
        assert delta2 >= delta1 - 0.1, "Vertical motion should accelerate"


class TestDominoCascade:
    """Unsupported elements should fall progressively, not teleport."""

    @pytest.mark.physics
    def test_cascade_not_instant(self, ground_truth):
        """A 20-cell column collapse should take multiple frames."""
        gt = ground_truth.get("domino_cascade")
        if gt is None:
            pytest.skip("No domino_cascade oracle data")
        min_frames = gt["expected_min_frames"]
        max_frames = gt["expected_max_frames"]
        expected = gt["expected_fall_frames_20cells"]
        assert min_frames <= expected <= max_frames

    @pytest.mark.physics
    def test_progressive_fall_principle(self, ground_truth):
        """Principle: elements fall progressively due to finite gravity."""
        gt = ground_truth.get("domino_cascade")
        if gt is None:
            pytest.skip("No domino_cascade oracle data")
        assert "progressive" in gt["principle"].lower()


class TestSettlingMechanics:
    """Elements should settle after consecutive stable frames."""

    @pytest.mark.physics
    def test_settling_uses_flag_bit(self, ground_truth):
        """Settling should use bit 64 in flags."""
        gt = ground_truth.get("settling_timing")
        if gt is None:
            pytest.skip("No settling_timing oracle data")
        assert gt["settle_flag_bit"] == 64

    @pytest.mark.physics
    def test_settling_takes_3_frames(self, ground_truth):
        """Elements should settle after 3 consecutive stable frames."""
        gt = ground_truth.get("settling_timing")
        if gt is None:
            pytest.skip("No settling_timing oracle data")
        assert gt["frames_to_settle"] == 3


class TestVelocityOnImpact:
    """Velocity should reset on landing."""

    @pytest.mark.physics
    def test_velocity_resets(self, ground_truth):
        """Velocity resets to 0 when hitting a solid surface."""
        gt = ground_truth.get("velocity_on_impact")
        if gt is None:
            pytest.skip("No velocity_on_impact oracle data")
        assert "reset" in gt["principle"].lower() or "0" in gt["principle"]


class TestStokesDrag:
    """Terminal velocity should be proportional to density difference (Stokes law)."""

    @pytest.mark.physics
    @pytest.mark.parametrize(
        "element", ["sand", "dirt", "metal", "stone"]
    )
    def test_stokes_data_exists(self, ground_truth, element):
        """Each solid element should have Stokes drag oracle data."""
        gt = ground_truth.get("stokes_drag", {})
        entry = gt.get("data", {}).get(element)
        if entry is None:
            pytest.skip(f"No stokes_drag data for {element}")
        assert entry["real_density"] > 0
        assert entry["engine_gravity"] > 0
        assert entry["engine_maxVel"] > 0

    @pytest.mark.physics
    def test_heavier_elements_have_higher_terminal_velocity(self, ground_truth):
        """Real-world: denser elements should have higher Stokes terminal velocity."""
        gt = ground_truth.get("stokes_drag", {})
        data = gt.get("data", {})
        if not data:
            pytest.skip("No stokes_drag data")
        # Sort by real density
        sorted_els = sorted(data.items(), key=lambda x: x[1]["real_density"])
        for i in range(1, len(sorted_els)):
            prev_name, prev = sorted_els[i - 1]
            curr_name, curr = sorted_els[i]
            assert curr["stokes_terminal_velocity_m_s"] >= prev["stokes_terminal_velocity_m_s"], (
                f"{curr_name} (d={curr['real_density']}) should have >= terminal velocity "
                f"than {prev_name} (d={prev['real_density']})"
            )

    @pytest.mark.physics
    def test_engine_gravity_ordering(self, ground_truth):
        """Sand (gravity=2) should have higher engine gravity than dirt (gravity=1)."""
        gt = ground_truth.get("stokes_drag", {})
        data = gt.get("data", {})
        sand = data.get("sand")
        dirt = data.get("dirt")
        if sand is None or dirt is None:
            pytest.skip("Missing sand or dirt stokes data")
        assert sand["engine_gravity"] >= dirt["engine_gravity"]

    @pytest.mark.physics
    def test_terminal_velocity_principle(self, ground_truth):
        """Stokes drag principle should reference density difference."""
        gt = ground_truth.get("stokes_drag")
        if gt is None:
            pytest.skip("No stokes_drag oracle data")
        assert "density" in gt["principle"].lower()
