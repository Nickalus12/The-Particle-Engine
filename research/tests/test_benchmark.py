import shutil
import subprocess
import pytest


class TestSimulationPerformance:
    def test_simulation_step_speed(self, benchmark):
        """Measure raw simulation step performance."""
        dart_exe = shutil.which("dart")
        if dart_exe is None:
            pytest.skip("Dart not found on PATH")
        result = benchmark(subprocess.run,
            [dart_exe, "run", "research/export_frame.dart", "100"],
            capture_output=True, timeout=30)
        assert result.returncode == 0

    def test_oracle_generation_speed(self, benchmark):
        """Oracle generation should complete quickly."""
        import research.physics_oracle as oracle
        result = benchmark(oracle.generate_ground_truth)
        assert len(result) > 20
