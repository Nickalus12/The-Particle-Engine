#!/usr/bin/env python3
"""Next-Gen SciPy Integration Benchmark.

Verifies that SCIPY_ARRAY_API=1 is working and demonstrates
GPU-accelerated filtering and transforms.
"""

import os
import time
import numpy as np
import cupy as cp
import scipy
from scipy.ndimage import generic_filter1d, distance_transform_edt
from scipy import signal

# Ensure environment is set (usually set by MegaRunner)
os.environ["SCIPY_ARRAY_API"] = "1"

def test_cupy_scipy_interop():
    print(f"--- SciPy Version: {scipy.__version__} ---")
    print(f"--- CuPy Version:  {cp.__version__} ---")
    
    # 1. Test Distance Transform EDT Acceleration
    print("\n[1] Testing Distance Transform EDT Acceleration:")
    size = 2048 # Bigger for better GPU saturation
    mask = np.random.random((size, size)) > 0.98
    
    # CPU
    start = time.time()
    dist_cpu = distance_transform_edt(~mask)
    cpu_time = time.time() - start
    print(f"    CPU EDT ({size}x{size}): {cpu_time:.4f}s")
    
    # GPU (using cupyx)
    from cupyx.scipy.ndimage import distance_transform_edt as gpu_edt
    mask_gpu = cp.array(~mask)
    # Warm-up
    gpu_edt(mask_gpu) 
    
    start = time.time()
    dist_gpu = gpu_edt(mask_gpu)
    cp.cuda.Stream.null.synchronize()
    gpu_time = time.time() - start
    print(f"    GPU EDT ({size}x{size}): {gpu_time:.4f}s ({cpu_time/gpu_time:.1f}x speedup)")

    # 2. Test generic_filter1d with CuPyX (Using a RawKernel for real power)
    print("\n[2] Testing generic_filter1d with CuPyX:")
    from cupyx.scipy.ndimage import generic_filter1d as gpu_filter1d

    # Simple CuPy kernel for generic_filter1d
    # Note: cupyx.ndimage.generic_filter1d usually expects a C++ snippet for efficiency
    # But we can also use cupyx.scipy.ndimage.convolve1d for similar results
    from cupyx.scipy.ndimage import convolve1d

    data_gpu = cp.random.random(1000000).astype(cp.float32)
    weights = cp.array([0.2, 0.2, 0.2, 0.2, 0.2], dtype=cp.float32)

    start = time.time()
    filtered = convolve1d(data_gpu, weights)
    cp.cuda.Stream.null.synchronize()
    print(f"    cupyx.convolve1d (1M elements): {time.time()-start:.4f}s")

    # 3. Test Signal Filtering with Array API (SciPy 1.11+)
    print("\n[3] Testing signal.filtfilt with Array API (GPU Backend):")
    # This specifically uses SciPy's Array API support
    t = cp.linspace(0, 1.0, 1000000) # 1M elements
    sig = cp.sin(2 * cp.pi * 5 * t) + cp.random.randn(1000000) * 0.1
    b, a = signal.butter(4, 0.1)

    # Warm-up (triggers JIT/Compilation if needed by backend)
    _ = signal.filtfilt(b, a, sig)

    start = time.time()
    # If SCIPY_ARRAY_API=1, sig being cupy will trigger the cupy backend inside SciPy
    filtered_sig = signal.filtfilt(b, a, sig)
    cp.cuda.Stream.null.synchronize()
    print(f"    scipy.signal.filtfilt (1M elements): {time.time()-start:.4f}s")
    print(f"    Output type: {type(filtered_sig)}")
    assert "cupy" in str(type(filtered_sig)).lower(), "Array API should have kept it on GPU!"
    print("    SUCCESS: Array API is active and preserving GPU memory!")


if __name__ == "__main__":
    test_cupy_scipy_interop()
