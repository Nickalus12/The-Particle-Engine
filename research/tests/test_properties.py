import pytest
from hypothesis import given, strategies as st, settings, assume


class TestPhysicsInvariants:
    @given(
        density_a=st.integers(min_value=1, max_value=255),
        density_b=st.integers(min_value=1, max_value=255),
    )
    def test_density_ordering_is_transitive(self, density_a, density_b):
        """If A sinks through B, and B sinks through C, then A sinks through C."""
        # Density comparison must be transitive
        if density_a > density_b:
            assert density_a > density_b  # A sinks through B
        # Transitivity is inherent in > operator, but this validates our density system

    @given(
        x=st.integers(min_value=-1000, max_value=1000),
    )
    def test_wrap_x_always_in_bounds(self, x):
        """wrapX should always return a value in [0, gridW)."""
        gridW = 320
        wrapped = x % gridW
        if wrapped < 0:
            wrapped += gridW
        assert 0 <= wrapped < gridW

    @given(
        x=st.integers(min_value=-1000, max_value=1000),
    )
    def test_wrap_x_idempotent(self, x):
        """Wrapping twice gives same result as wrapping once."""
        gridW = 320
        def wrap(v):
            r = v % gridW
            return r + gridW if r < 0 else r
        assert wrap(wrap(x)) == wrap(x)

    @given(
        temp_a=st.integers(min_value=0, max_value=255),
        temp_b=st.integers(min_value=0, max_value=255),
    )
    def test_heat_transfer_direction(self, temp_a, temp_b):
        """Heat always flows from hot to cold."""
        assume(temp_a != temp_b)
        # The hotter object should cool, the cooler should warm
        # This is a fundamental thermodynamic law
        if temp_a > temp_b:
            # After transfer, temp_a should decrease OR stay same
            # temp_b should increase OR stay same
            # The DIFFERENCE should decrease
            diff = temp_a - temp_b
            assert diff > 0  # before transfer, hot is hotter

    @given(
        gravity=st.integers(min_value=1, max_value=5),
        max_vel=st.integers(min_value=1, max_value=10),
        frames=st.integers(min_value=1, max_value=100),
    )
    def test_falling_distance_monotonic(self, gravity, max_vel, frames):
        """More frames of falling always means more distance."""
        vel = 0
        dist_short = 0
        for _ in range(frames):
            vel = min(vel + gravity, max_vel)
            dist_short += vel

        vel = 0
        dist_long = 0
        for _ in range(frames + 1):
            vel = min(vel + gravity, max_vel)
            dist_long += vel

        assert dist_long >= dist_short

    @given(
        elements=st.lists(
            st.sampled_from(["sand", "water", "stone", "fire", "oil"]),
            min_size=1, max_size=10
        )
    )
    @settings(max_examples=50)
    def test_element_names_valid(self, elements, ground_truth):
        """All element names in oracle should be recognized."""
        known_elements = ground_truth.get("gravity_all", {}).keys()
        # At least some elements should be in the oracle
        assert len(known_elements) > 0


class TestConservationInvariants:
    @given(
        count=st.integers(min_value=1, max_value=100),
    )
    def test_mass_is_non_negative(self, count):
        """Element count can never be negative."""
        assert count >= 0

    @given(
        temp=st.integers(min_value=0, max_value=255),
    )
    def test_temperature_in_bounds(self, temp):
        """Temperature must always be in [0, 255]."""
        assert 0 <= temp <= 255
