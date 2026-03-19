<<<<<<< HEAD
=======
"""Comprehensive pytest-benchmark performance tests.

Tracks every performance-critical path in The Particle Engine's research
pipeline: oracle generation, simulation export, data processing, scaling,
and regression detection.

Usage:
    pytest research/tests/test_benchmark.py --benchmark-autosave
    pytest research/tests/test_benchmark.py --benchmark-compare=0001
    pytest research/tests/test_benchmark.py --benchmark-compare-fail=mean:15%
"""

import json
>>>>>>> worktree-pytest-test-suite
import shutil
import subprocess
import sys
import tracemalloc
from pathlib import Path

import numpy as np
import pytest

RESEARCH_DIR = Path(__file__).parent.parent
PROJECT_DIR = RESEARCH_DIR.parent

<<<<<<< HEAD
class TestSimulationPerformance:
    def test_simulation_step_speed(self, benchmark):
        """Measure raw simulation step performance."""
        dart_exe = shutil.which("dart")
        if dart_exe is None:
            pytest.skip("Dart not found on PATH")
        result = benchmark(subprocess.run,
            [dart_exe, "run", "research/export_frame.dart", "100"],
            capture_output=True, timeout=30)
=======

def _dart_available():
    return shutil.which("dart") is not None


def _run_dart_export(frames: int, timeout: int = 30):
    dart_exe = shutil.which("dart")
    if dart_exe is None:
        pytest.skip("Dart not found on PATH")
    return subprocess.run(
        [dart_exe, "run", str(RESEARCH_DIR / "export_frame.dart"), str(frames)],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# =============================================================================
# Oracle Performance
# =============================================================================

class TestOraclePerformance:
    """Benchmark oracle generation speed."""

    @pytest.mark.benchmark(group="oracle")
    def test_physics_oracle_speed(self, benchmark):
        """Physics oracle generation should complete < 1s."""
        from research.physics_oracle import generate_ground_truth
        result = benchmark(generate_ground_truth)
        assert len(result) > 20

    @pytest.mark.benchmark(group="oracle")
    def test_visual_oracle_speed(self, benchmark):
        """Visual oracle generation should complete < 500ms."""
        from research.visual_oracle import generate_visual_truth
        result = benchmark(generate_visual_truth)
        assert len(result) > 10

    @pytest.mark.benchmark(group="oracle")
    def test_energy_oracle_speed(self, benchmark):
        """Energy oracle generation should complete quickly."""
        try:
            from research.energy_oracle import generate_energy_ground_truth
            result = benchmark(generate_energy_ground_truth)
            assert len(result) > 0
        except ImportError:
            pytest.skip("energy_oracle not available")

    @pytest.mark.benchmark(group="oracle-io")
    def test_ground_truth_json_load(self, benchmark):
        """Loading ground_truth.json should be fast."""
        gt_path = RESEARCH_DIR / "ground_truth.json"
        if not gt_path.exists():
            pytest.skip("ground_truth.json not found")

        def load():
            with open(gt_path) as f:
                return json.load(f)

        result = benchmark(load)
        assert len(result) > 0

    @pytest.mark.benchmark(group="oracle-io")
    def test_visual_truth_json_load(self, benchmark):
        """Loading visual_ground_truth.json should be fast."""
        vgt_path = RESEARCH_DIR / "visual_ground_truth.json"
        if not vgt_path.exists():
            pytest.skip("visual_ground_truth.json not found")

        def load():
            with open(vgt_path) as f:
                return json.load(f)

        result = benchmark(load)
        assert len(result) > 0

    @pytest.mark.benchmark(group="oracle-io")
    def test_frame_meta_json_load(self, benchmark):
        """Loading frame_meta.json should be nearly instant."""
        meta_path = RESEARCH_DIR / "frame_meta.json"
        if not meta_path.exists():
            pytest.skip("frame_meta.json not found")

        def load():
            with open(meta_path) as f:
                return json.load(f)

        result = benchmark(load)
        assert "elements" in result


# =============================================================================
# Simulation Export Performance
# =============================================================================

class TestSimulationExport:
    """Benchmark Dart simulation export at various frame counts."""

    @pytest.mark.benchmark(group="export")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_export_10_frames(self, benchmark):
        """Exporting 10 frames should be very fast."""
        result = benchmark.pedantic(
            _run_dart_export, args=(10,), kwargs={},
            rounds=3, warmup_rounds=1,
        )
>>>>>>> worktree-pytest-test-suite
        assert result.returncode == 0

    @pytest.mark.benchmark(group="export")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_export_100_frames(self, benchmark):
        """Exporting 100 frames should complete < 5s."""
        result = benchmark.pedantic(
            _run_dart_export, args=(100,), kwargs={},
            rounds=3, warmup_rounds=1,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="export")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_export_300_frames(self, benchmark):
        """Exporting 300 frames should complete < 15s."""
        result = benchmark.pedantic(
            _run_dart_export, args=(300,), kwargs={"timeout": 30},
            rounds=3, warmup_rounds=1,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="export")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_export_600_frames(self, benchmark):
        """Exporting 600 frames for sustained throughput."""
        result = benchmark.pedantic(
            _run_dart_export, args=(600,), kwargs={"timeout": 60},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="export")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_export_1000_frames(self, benchmark):
        """1000-frame stress test should complete without timeout."""
        result = benchmark.pedantic(
            _run_dart_export, args=(1000,), kwargs={"timeout": 120},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0


# =============================================================================
# Test Suite Performance
# =============================================================================

class TestTestSuitePerformance:
    """Benchmark how fast our own test suites run."""

    @pytest.mark.benchmark(group="suite")
    def test_physics_tests_speed(self, benchmark):
        """Physics test suite should complete < 30s."""
        result = benchmark.pedantic(
            subprocess.run,
            args=[[sys.executable, "-m", "pytest",
                   str(RESEARCH_DIR / "tests" / "test_kinematics.py"),
                   "-q", "--no-header", "-x"]],
            kwargs={"capture_output": True, "timeout": 60,
                    "cwd": str(PROJECT_DIR)},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="suite")
    def test_visual_tests_speed(self, benchmark):
        """Visual tests should complete < 10s."""
        result = benchmark.pedantic(
            subprocess.run,
            args=[[sys.executable, "-m", "pytest",
                   str(RESEARCH_DIR / "tests" / "test_visuals.py"),
                   "-q", "--no-header", "-x"]],
            kwargs={"capture_output": True, "timeout": 30,
                    "cwd": str(PROJECT_DIR)},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="suite")
    def test_properties_tests_speed(self, benchmark):
        """Property tests should complete < 10s."""
        result = benchmark.pedantic(
            subprocess.run,
            args=[[sys.executable, "-m", "pytest",
                   str(RESEARCH_DIR / "tests" / "test_properties.py"),
                   "-q", "--no-header", "-x"]],
            kwargs={"capture_output": True, "timeout": 30,
                    "cwd": str(PROJECT_DIR)},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0

    @pytest.mark.benchmark(group="suite")
    def test_thermodynamics_tests_speed(self, benchmark):
        """Thermodynamics tests should complete < 15s."""
        result = benchmark.pedantic(
            subprocess.run,
            args=[[sys.executable, "-m", "pytest",
                   str(RESEARCH_DIR / "tests" / "test_thermodynamics.py"),
                   "-q", "--no-header", "-x"]],
            kwargs={"capture_output": True, "timeout": 30,
                    "cwd": str(PROJECT_DIR)},
            rounds=2, warmup_rounds=0,
        )
        assert result.returncode == 0


# =============================================================================
# Data Processing Performance
# =============================================================================

class TestDataProcessing:
    """Benchmark numpy/image data processing operations."""

    @pytest.mark.benchmark(group="data")
    def test_numpy_frame_load(self, benchmark):
        """Loading pixel buffer into numpy should be fast."""
        rgba_path = RESEARCH_DIR / "frame.rgba"
        if not rgba_path.exists():
            pytest.skip("frame.rgba not found")
        data = rgba_path.read_bytes()

        result = benchmark(np.frombuffer, data, dtype=np.uint8)
        assert len(result) == 320 * 180 * 4

    @pytest.mark.benchmark(group="data")
    def test_numpy_frame_reshape(self, benchmark):
        """Reshaping pixel buffer to (H,W,4) should be fast."""
        rgba_path = RESEARCH_DIR / "frame.rgba"
        if not rgba_path.exists():
            pytest.skip("frame.rgba not found")
        data = rgba_path.read_bytes()
        flat = np.frombuffer(data, dtype=np.uint8)

        def reshape():
            return flat.reshape(180, 320, 4).copy()

        result = benchmark(reshape)
        assert result.shape == (180, 320, 4)

    @pytest.mark.benchmark(group="data")
    def test_grid_load(self, benchmark):
        """Loading grid binary should be fast."""
        grid_path = RESEARCH_DIR / "grid.bin"
        if not grid_path.exists():
            pytest.skip("grid.bin not found")
        data = grid_path.read_bytes()

        def load():
            return np.frombuffer(data, dtype=np.uint8).reshape(180, 320)

        result = benchmark(load)
        assert result.shape == (180, 320)

    @pytest.mark.benchmark(group="data")
    def test_grid_unique_elements(self, benchmark):
        """Counting unique elements in grid should be fast."""
        grid_path = RESEARCH_DIR / "grid.bin"
        if not grid_path.exists():
            pytest.skip("grid.bin not found")
        data = grid_path.read_bytes()
        grid = np.frombuffer(data, dtype=np.uint8).reshape(180, 320)

        result = benchmark(np.unique, grid)
        assert len(result) > 0

    @pytest.mark.benchmark(group="data")
    def test_lab_conversion(self, benchmark):
        """RGB to LAB conversion performance."""
        try:
            from skimage.color import rgb2lab
        except ImportError:
            pytest.skip("scikit-image not available")
        img = np.random.randint(0, 255, (180, 320, 3), dtype=np.uint8)
        result = benchmark(rgb2lab, img)
        assert result.shape == (180, 320, 3)

    @pytest.mark.benchmark(group="data")
    def test_delta_e_computation(self, benchmark):
        """CIE 2000 Delta E computation speed."""
        try:
            import colour
        except ImportError:
            pytest.skip("colour-science not available")
        lab1 = np.array([50.0, 20.0, -10.0])
        lab2 = np.array([55.0, 15.0, -5.0])
        result = benchmark(colour.delta_E, lab1, lab2, method='CIE 2000')
        assert result > 0

    @pytest.mark.benchmark(group="data")
    def test_entropy_computation(self, benchmark):
        """Shannon entropy computation speed."""
        try:
            from skimage.measure import shannon_entropy
        except ImportError:
            pytest.skip("scikit-image not available")
        img = np.random.randint(0, 255, (64, 64), dtype=np.uint8)
        result = benchmark(shannon_entropy, img)
        assert result > 0

    @pytest.mark.benchmark(group="data")
    def test_full_frame_entropy(self, benchmark):
        """Shannon entropy on full-size frame."""
        try:
            from skimage.measure import shannon_entropy
        except ImportError:
            pytest.skip("scikit-image not available")
        img = np.random.randint(0, 255, (180, 320), dtype=np.uint8)
        result = benchmark(shannon_entropy, img)
        assert result > 0


# =============================================================================
# Scaling Benchmarks
# =============================================================================

class TestScaling:
    """Benchmark how operations scale with input size."""

    @pytest.mark.benchmark(group="scale-grid")
    @pytest.mark.parametrize("grid_size", [32, 64, 128, 256])
    def test_unique_scales_with_grid(self, benchmark, grid_size):
        """np.unique should scale reasonably with grid size."""
        grid = np.random.randint(0, 25, (grid_size, grid_size), dtype=np.uint8)

        def process():
            return np.unique(grid)

        result = benchmark(process)
        assert len(result) > 0

    @pytest.mark.benchmark(group="scale-grid")
    @pytest.mark.parametrize("grid_size", [32, 64, 128, 256])
    def test_element_histogram(self, benchmark, grid_size):
        """np.bincount histogram should scale well."""
        grid = np.random.randint(0, 25, (grid_size, grid_size), dtype=np.uint8)
        flat = grid.ravel()

        def histogram():
            return np.bincount(flat, minlength=25)

        result = benchmark(histogram)
        assert result.sum() == grid_size * grid_size

    @pytest.mark.benchmark(group="scale-delta-e")
    @pytest.mark.parametrize("pair_count", [10, 50, 100, 276])
    def test_delta_e_batch_scaling(self, benchmark, pair_count):
        """Delta E computation should handle batch sizes efficiently."""
        try:
            import colour
        except ImportError:
            pytest.skip("colour-science not available")
        labs = np.random.rand(pair_count, 2, 3) * 100

        def compute_all():
            results = []
            for i in range(pair_count):
                de = colour.delta_E(labs[i, 0], labs[i, 1], method='CIE 2000')
                results.append(de)
            return results

        result = benchmark(compute_all)
        assert len(result) == pair_count

    @pytest.mark.benchmark(group="scale-lab")
    @pytest.mark.parametrize("size", [32, 64, 128, 256])
    def test_lab_conversion_scaling(self, benchmark, size):
        """RGB->LAB should scale with image size."""
        try:
            from skimage.color import rgb2lab
        except ImportError:
            pytest.skip("scikit-image not available")
        img = np.random.randint(0, 255, (size, size, 3), dtype=np.uint8)
        result = benchmark(rgb2lab, img)
        assert result.shape == (size, size, 3)


# =============================================================================
# Regression Detection
# =============================================================================

class TestPerformanceRegression:
    """Track key performance metrics for regression detection."""

    @pytest.mark.benchmark(group="regression")
    @pytest.mark.skipif(not _dart_available(), reason="Dart not on PATH")
    def test_frame_throughput(self, benchmark):
        """Track frames per second over time."""
        import time

        def run_and_measure():
            start = time.perf_counter()
            result = _run_dart_export(100, timeout=20)
            elapsed = time.perf_counter() - start
            return result, elapsed

        result, elapsed = benchmark.pedantic(
            run_and_measure, rounds=3, warmup_rounds=1,
        )
        fps = 100 / elapsed
        benchmark.extra_info['fps'] = round(fps, 1)
        assert fps > 10, f"FPS={fps:.1f}, expected > 10"

    @pytest.mark.benchmark(group="regression")
    def test_oracle_element_count(self, benchmark):
        """Track element coverage in oracle output."""
        from research.physics_oracle import generate_ground_truth

        result = benchmark(generate_ground_truth)
        element_count = len([k for k in result if not k.startswith("_")])
        benchmark.extra_info['element_count'] = element_count
        assert element_count >= 20

    @pytest.mark.benchmark(group="regression")
    def test_json_round_trip(self, benchmark):
        """JSON serialize + deserialize ground truth data."""
        gt_path = RESEARCH_DIR / "ground_truth.json"
        if not gt_path.exists():
            pytest.skip("ground_truth.json not found")
        with open(gt_path) as f:
            data = json.load(f)

        def round_trip():
            serialized = json.dumps(data)
            return json.loads(serialized)

        result = benchmark(round_trip)
        assert len(result) > 0

    @pytest.mark.benchmark(group="regression")
    def test_memory_per_frame(self, benchmark):
        """Track peak memory usage when processing a frame."""
        rgba_path = RESEARCH_DIR / "frame.rgba"
        if not rgba_path.exists():
            pytest.skip("frame.rgba not found")

        def process_frame():
            tracemalloc.start()
            raw = rgba_path.read_bytes()
            pixels = np.frombuffer(raw, dtype=np.uint8).reshape(180, 320, 4)
            _ = pixels[:, :, :3].mean(axis=2)  # grayscale conversion
            current, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
            return peak

        peak = benchmark(process_frame)
        peak_mb = peak / (1024 * 1024)
        benchmark.extra_info['peak_memory_mb'] = round(peak_mb, 2)
        assert peak_mb < 50, f"Peak memory {peak_mb:.1f}MB exceeds 50MB"

    @pytest.mark.benchmark(group="regression")
    def test_grid_processing_pipeline(self, benchmark):
        """Full grid load + analyze pipeline."""
        grid_path = RESEARCH_DIR / "grid.bin"
        if not grid_path.exists():
            pytest.skip("grid.bin not found")

        def pipeline():
            data = grid_path.read_bytes()
            grid = np.frombuffer(data, dtype=np.uint8).reshape(180, 320)
            unique = np.unique(grid)
            histogram = np.bincount(grid.ravel(), minlength=25)
            return {"elements": len(unique), "distribution": histogram.tolist()}

        result = benchmark(pipeline)
        assert result["elements"] > 0
        assert sum(result["distribution"]) == 180 * 320
