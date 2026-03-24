"""Shared parameter contract helpers for local and cloud optimization paths."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

RESEARCH_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST_PATH = RESEARCH_DIR / "parameter_manifest.json"
CONTRACT_VERSION = 1


def load_parameter_manifest() -> dict[str, Any]:
    with open(resolve_manifest_path(), encoding="utf-8") as f:
        return json.load(f)


def resolve_manifest_path() -> Path:
    override = os.environ.get("TPE_PARAMETER_MANIFEST")
    if override:
        return Path(override)
    return DEFAULT_MANIFEST_PATH


def build_trial_config(params: dict[str, Any]) -> dict[str, Any]:
    """Build a canonical trial-config payload from flat optimizer params."""
    manifest = load_parameter_manifest()
    manifest_path = resolve_manifest_path()
    config: dict[str, Any] = {
        "contract_version": CONTRACT_VERSION,
        "manifest": str(manifest_path.name),
        "params": dict(params),
    }

    for canonical_path, meta in manifest.get("parameters", {}).items():
        legacy_flat = meta.get("legacy_flat")
        if legacy_flat is None or legacy_flat not in params:
            continue
        _set_nested(config, canonical_path.split("."), params[legacy_flat])

    return config


def write_trial_config(path: Path, params: dict[str, Any]) -> Path:
    """Write a manifest-backed trial config to disk."""
    config = build_trial_config(params)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    return path


def normalize_trial_config(
    config: dict[str, Any],
    defaults: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Normalize a canonical config payload back to flat optimizer params."""
    manifest = load_parameter_manifest()
    params: dict[str, Any] = {}

    raw_params = config.get("params")
    if isinstance(raw_params, dict):
        for key, value in raw_params.items():
            params[str(key)] = value

    for canonical_path, meta in manifest.get("parameters", {}).items():
        legacy_flat = meta.get("legacy_flat")
        if not legacy_flat:
            continue
        resolved = _get_nested(config, canonical_path.split("."))
        if resolved is not None:
            params.setdefault(legacy_flat, resolved)

    worldgen = config.get("worldgen")
    if isinstance(worldgen, dict):
        for key, value in worldgen.items():
            params.setdefault(str(key), value)

    if defaults:
        for key, value in defaults.items():
            params.setdefault(key, value)

    return params


def canonical_overrides_from_flat_params(params: dict[str, Any]) -> dict[str, Any]:
    """Resolve flat optimizer params to canonical dotted-path overrides."""
    manifest = load_parameter_manifest()
    canonical: dict[str, Any] = {}
    for canonical_path, meta in manifest.get("parameters", {}).items():
        legacy_flat = meta.get("legacy_flat")
        if legacy_flat is None or legacy_flat not in params:
            continue
        canonical[canonical_path] = params[legacy_flat]
    return canonical


def _set_nested(target: dict[str, Any], path: list[str], value: Any) -> None:
    cursor = target
    for segment in path[:-1]:
        next_node = cursor.get(segment)
        if not isinstance(next_node, dict):
            next_node = {}
            cursor[segment] = next_node
        cursor = next_node
    cursor[path[-1]] = value


def _get_nested(source: dict[str, Any], path: list[str]) -> Any:
    cursor: Any = source
    for segment in path:
        if not isinstance(cursor, dict) or segment not in cursor:
            return None
        cursor = cursor[segment]
    return cursor
