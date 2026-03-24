"""Shared environment loading for local cloud-provider integrations."""

from __future__ import annotations

import os
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILES = (
    SCRIPT_DIR / ".thundercompute.env",
    SCRIPT_DIR / ".cloud.env",
)


def load_cloud_env() -> None:
    """Load local cloud env files into the current process environment."""
    for path in DEFAULT_ENV_FILES:
        if not path.exists():
            continue
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key and key not in os.environ:
                os.environ[key] = value
