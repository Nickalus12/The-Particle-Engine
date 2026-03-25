"""System-aware tuning helpers for large cloud GPU instances."""

from __future__ import annotations

import os


def detect_system_profile() -> dict[str, int | str | bool]:
    cpu_count = os.cpu_count() or 8
    profile: dict[str, int | str | bool] = {
        "cpu_count": cpu_count,
        "gpu_name": "",
        "gpu_mem_total_mib": 0,
        "gpu_mem_free_mib": 0,
        "is_h100": False,
        "is_a100": False,
    }

    try:
        import cupy as cp  # type: ignore

        props = cp.cuda.runtime.getDeviceProperties(0)
        name = props["name"].decode()
        free_bytes, total_bytes = cp.cuda.runtime.memGetInfo()
        profile["gpu_name"] = name
        profile["gpu_mem_total_mib"] = int(total_bytes // (1024 * 1024))
        profile["gpu_mem_free_mib"] = int(free_bytes // (1024 * 1024))
        profile["is_h100"] = "H100" in name
        profile["is_a100"] = "A100" in name
    except Exception:
        pass

    return profile


def profile_label(profile: dict[str, int | str | bool] | None = None) -> str:
    """Return a human-readable accelerator tier label."""
    profile = profile or detect_system_profile()
    if profile["is_h100"]:
        return "h100"
    if profile["is_a100"]:
        return "a100"
    if profile["gpu_name"]:
        return "gpu"
    return "cpu"


def resolve_worker_count(
    kind: str,
    requested: int | None = None,
) -> int:
    profile = detect_system_profile()
    cpu_count = int(profile["cpu_count"])
    if requested is not None and requested > 0:
        return requested

    if profile["is_h100"] or profile["is_a100"]:
        defaults = {
            # Keep one GPU owner for validation and only a small GPU-facing
            # worker set for Optuna-based GPU studies to avoid context thrash.
            "validation": 1,
            "staged": min(16, max(8, cpu_count - 4)),
            "chemistry": 2,
            "worldgen": 2,
            "fanova": min(12, max(6, cpu_count // 2)),
        }
    else:
        defaults = {
            "validation": min(2, max(1, cpu_count // 6)),
            "staged": min(12, max(6, cpu_count - 4)),
            "chemistry": min(4, max(2, cpu_count // 3)),
            "worldgen": min(4, max(2, cpu_count // 3)),
            "fanova": min(8, max(4, cpu_count // 2)),
        }
    return defaults.get(kind, min(8, max(4, cpu_count // 2)))


def resolve_validation_scenarios(requested: int | None = None) -> int:
    if requested is not None and requested > 0:
        return requested
    if _env_int("TPE_VALIDATION_SCENARIOS"):
        return _env_int("TPE_VALIDATION_SCENARIOS")

    profile = detect_system_profile()
    mode = os.environ.get("TPE_VALIDATION_MODE", "standard").lower()
    if profile["is_h100"] or profile["is_a100"]:
        return 300000 if mode == "heavy" else 120000
    return 100000


def resolve_electrical_circuits(requested: int | None = None) -> int:
    if requested is not None and requested > 0:
        return requested
    if _env_int("TPE_ELECTRICAL_CIRCUITS"):
        return _env_int("TPE_ELECTRICAL_CIRCUITS")

    profile = detect_system_profile()
    mode = os.environ.get("TPE_VALIDATION_MODE", "standard").lower()
    if profile["is_h100"] or profile["is_a100"]:
        return 18000 if mode == "heavy" else 8000
    return 5000


def resolve_conservation_batch(total_scenarios: int) -> int:
    env_value = _env_int("TPE_BATCH_CONSERVATION")
    if env_value:
        return env_value
    profile = detect_system_profile()
    if profile["is_h100"]:
        return max(40000, total_scenarios // 4)
    if profile["is_a100"]:
        return max(24000, total_scenarios // 5)
    return max(1000, total_scenarios // 6)


def resolve_electrical_batch(total_circuits: int) -> int:
    env_value = _env_int("TPE_BATCH_ELECTRICAL")
    if env_value:
        return env_value
    profile = detect_system_profile()
    if profile["is_h100"]:
        return max(2000, total_circuits // 6)
    if profile["is_a100"]:
        return max(1000, total_circuits // 7)
    return max(50, total_circuits // 9)


def resolve_chemistry_batches() -> dict[str, int]:
    profile = detect_system_profile()
    scale = 1
    if profile["is_h100"]:
        scale = 6
    elif profile["is_a100"]:
        scale = 4

    base = {
        "combustion": 200,
        "corrosion": 100,
        "acid": 100,
        "electrical": 100,
    }
    resolved = {
        key: _env_int(f"TPE_CHEM_BATCH_{key.upper()}") or value * scale
        for key, value in base.items()
    }
    return resolved


def summarize_profile() -> dict[str, int | str | bool]:
    profile = detect_system_profile()
    profile["profile_label"] = profile_label(profile)
    profile["workers_validation"] = resolve_worker_count("validation")
    profile["workers_staged"] = resolve_worker_count("staged")
    profile["workers_chemistry"] = resolve_worker_count("chemistry")
    profile["workers_worldgen"] = resolve_worker_count("worldgen")
    profile["validation_scenarios"] = resolve_validation_scenarios()
    profile["electrical_circuits"] = resolve_electrical_circuits()
    return profile


def _env_int(name: str) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return 0
    try:
        return int(raw)
    except ValueError:
        return 0
