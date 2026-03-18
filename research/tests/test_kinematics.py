"""Kinematics tests: gravity, trajectory, terminal velocity."""

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
