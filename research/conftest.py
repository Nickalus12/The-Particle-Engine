"""Shared fixtures for The Particle Engine test suite.

Provides:
  - ground_truth: scipy-computed physics oracle data
  - simulation_frame: rendered pixel buffer + grid from Dart simulation
  - element_names: mapping of element name -> ID
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

RESEARCH_DIR = Path(__file__).parent
PROJECT_DIR = RESEARCH_DIR.parent


@pytest.fixture(scope="session")
def ground_truth():
    """Load scipy-computed ground truth from physics_oracle.py."""
    gt_path = RESEARCH_DIR / "ground_truth.json"
    if not gt_path.exists():
        subprocess.run(
            [sys.executable, str(RESEARCH_DIR / "physics_oracle.py")],
            check=True,
        )
    with open(gt_path) as f:
        return json.load(f)


@pytest.fixture(scope="session")
def simulation_frame():
    """Run Dart simulation and export pixel buffer + grid.

    Returns dict with keys: pixels (H,W,4 uint8), grid (H,W uint8), meta.
    """
    rgba_path = RESEARCH_DIR / "frame.rgba"
    grid_path = RESEARCH_DIR / "grid.bin"
    meta_path = RESEARCH_DIR / "frame_meta.json"

    # Only run Dart export if output files are missing
    if not (rgba_path.exists() and grid_path.exists() and meta_path.exists()):
        dart_exe = shutil.which("dart")
        if dart_exe is None:
            pytest.skip(
                "Dart not found. Run 'dart run research/export_frame.dart 100' "
                "manually before running visual tests."
            )
        subprocess.run(
            [dart_exe, "run", str(RESEARCH_DIR / "export_frame.dart"), "100"],
            cwd=str(PROJECT_DIR),
            check=True,
        )

    width, height = 320, 180

    pixels_raw = rgba_path.read_bytes()
    pixels = np.frombuffer(pixels_raw, dtype=np.uint8).reshape(height, width, 4)

    grid_raw = (RESEARCH_DIR / "grid.bin").read_bytes()
    grid = np.frombuffer(grid_raw, dtype=np.uint8).reshape(height, width)

    with open(RESEARCH_DIR / "frame_meta.json") as f:
        meta = json.load(f)

    return {"pixels": pixels.copy(), "grid": grid.copy(), "meta": meta}


@pytest.fixture(scope="session")
def element_names(simulation_frame):
    """Map element names (capitalized) to IDs from simulation metadata.

    Also supports case-insensitive lookup via __getitem__ fallback.
    """
    raw = simulation_frame["meta"]["elements"]
    # Provide a dict that supports case-insensitive .get()
    return _CaseInsensitiveDict(raw)


class _CaseInsensitiveDict(dict):
    """Dict with case-insensitive get/contains, preserving original keys."""

    def __init__(self, data):
        super().__init__(data)
        self._lower = {k.lower(): v for k, v in data.items()}

    def get(self, key, default=None):
        result = super().get(key, None)
        if result is not None:
            return result
        return self._lower.get(key.lower(), default)

    def __contains__(self, key):
        return super().__contains__(key) or key.lower() in self._lower


@pytest.fixture(scope="session")
def element_ids_to_names(element_names):
    """Reverse map: element ID -> name."""
    return {v: k for k, v in element_names.items()}


@pytest.fixture(scope="session")
def visual_truth():
    """Load visual ground truth from visual_oracle.py output."""
    vgt_path = RESEARCH_DIR / "visual_ground_truth.json"
    if not vgt_path.exists():
        subprocess.run(
            [sys.executable, str(RESEARCH_DIR / "visual_oracle.py")],
            check=True,
        )
    with open(vgt_path) as f:
        return json.load(f)
