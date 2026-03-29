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


def build_trial_config(
    params: dict[str, Any],
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a canonical trial-config payload from flat optimizer params."""
    manifest = load_parameter_manifest()
    manifest_path = resolve_manifest_path()
    config: dict[str, Any] = {
        "contract_version": CONTRACT_VERSION,
        "manifest": str(manifest_path.name),
        "params": dict(params),
    }
    if metadata:
        config["optuna"] = dict(metadata)
        source_label = metadata.get("source_label")
        if source_label is not None:
            config["source_label"] = str(source_label)

    for canonical_path, meta in manifest.get("parameters", {}).items():
        legacy_flat = meta.get("legacy_flat")
        if legacy_flat is None or legacy_flat not in params:
            continue
        _set_nested(config, canonical_path.split("."), params[legacy_flat])

    return config


def write_trial_config(
    path: Path,
    params: dict[str, Any],
    metadata: dict[str, Any] | None = None,
) -> Path:
    """Write a manifest-backed trial config to disk."""
    config = build_trial_config(params, metadata=metadata)
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


def iter_manifest_parameters(
    *,
    stage_contains: str | tuple[str, ...] | None = None,
    runtime_mutable: bool | None = None,
) -> list[tuple[str, dict[str, Any]]]:
    """Return manifest parameters filtered by stage/runtime mutability."""
    manifest = load_parameter_manifest()
    filters = (
        (stage_contains,)
        if isinstance(stage_contains, str)
        else tuple(stage_contains or ())
    )
    entries: list[tuple[str, dict[str, Any]]] = []
    for canonical_path, raw_meta in manifest.get("parameters", {}).items():
        meta = dict(raw_meta)
        stage = str(meta.get("stage", ""))
        if filters and not any(token in stage for token in filters):
            continue
        if (
            runtime_mutable is not None
            and bool(meta.get("runtime_mutable")) != runtime_mutable
        ):
            continue
        entries.append((canonical_path, meta))
    return entries


def manifest_defaults(
    *,
    stage_contains: str | tuple[str, ...] | None = None,
    runtime_mutable: bool | None = None,
) -> dict[str, Any]:
    """Resolve manifest defaults into a flat optimizer-params dict."""
    defaults: dict[str, Any] = {}
    for _, meta in iter_manifest_parameters(
        stage_contains=stage_contains,
        runtime_mutable=runtime_mutable,
    ):
        legacy_flat = meta.get("legacy_flat")
        if legacy_flat is None:
            continue
        defaults[str(legacy_flat)] = meta.get("default")
    return defaults


def build_optuna_suggestion_spec(meta: dict[str, Any]) -> dict[str, Any] | None:
    """Normalize manifest metadata into an Optuna-friendly suggestion spec."""
    legacy_flat = meta.get("legacy_flat")
    minimum = meta.get("min")
    maximum = meta.get("max")
    if legacy_flat is None or minimum is None or maximum is None:
        return None

    spec: dict[str, Any] = {
        "name": str(legacy_flat),
        "type": str(meta.get("type", "int")),
        "low": minimum,
        "high": maximum,
    }
    if "step" in meta:
        spec["step"] = meta["step"]
    if "log" in meta:
        spec["log"] = bool(meta["log"])
    return spec


def select_optuna_manifest_parameters(
    *,
    profile: str = "balanced",
    runtime_mutable: bool | None = None,
) -> list[tuple[str, dict[str, Any]]]:
    """Resolve an Optuna manifest surface for a named optimization profile."""
    entries = iter_manifest_parameters(
        stage_contains="optuna",
        runtime_mutable=runtime_mutable,
    )
    if profile in ("balanced", "exploratory"):
        return entries

    if profile == "mobile":
        mobile_groups = {
            "element_transport",
            "sim_transport",
            "sim_scheduler",
            "sim_thresholds",
            "world_generation",
        }
        filtered: list[tuple[str, dict[str, Any]]] = []
        for canonical_path, meta in entries:
            profiles = meta.get("optuna_profiles")
            if isinstance(profiles, list) and profile not in profiles:
                continue
            if bool(meta.get("runtime_mutable")) or str(meta.get("group")) in mobile_groups:
                filtered.append((canonical_path, meta))
        return filtered

    return entries


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
