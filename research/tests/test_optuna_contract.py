from __future__ import annotations

from pathlib import Path
import sys
import importlib.util

RESEARCH_DIR = Path(__file__).resolve().parent.parent
if str(RESEARCH_DIR) not in sys.path:
    sys.path.insert(0, str(RESEARCH_DIR))

from optimizer import DEFAULTS, suggest_params
from parameter_contract import (
    build_optuna_suggestion_spec,
    build_trial_config,
    manifest_defaults,
    select_optuna_manifest_parameters,
    iter_manifest_parameters,
)

_cloud_spec = importlib.util.spec_from_file_location(
    "cloud_run_optimizer_contract",
    RESEARCH_DIR / "cloud" / "run_optimizer.py",
)
assert _cloud_spec and _cloud_spec.loader
cloud_run_optimizer = importlib.util.module_from_spec(_cloud_spec)
_cloud_spec.loader.exec_module(cloud_run_optimizer)


class _FakeTrial:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, float, float, dict[str, object]]] = []

    def suggest_int(self, name: str, low: int, high: int, **kwargs) -> int:
        self.calls.append(("int", name, low, high, kwargs))
        return low

    def suggest_float(
        self,
        name: str,
        low: float,
        high: float,
        step=None,
        **kwargs,
    ) -> float:
        if step is not None:
            kwargs["step"] = step
        self.calls.append(("float", name, low, high, kwargs))
        return low


def test_manifest_defaults_feed_optimizer_defaults() -> None:
    manifest_optuna_defaults = manifest_defaults(stage_contains="optuna")
    assert DEFAULTS["phase_apply_wind_cadence"] == 2
    assert DEFAULTS["phase_wind_field_cadence"] == 30
    assert DEFAULTS["terrain_scale"] == manifest_optuna_defaults["terrain_scale"]
    assert DEFAULTS["water_pressure_push"] == manifest_optuna_defaults["water_pressure_push"]


def test_suggest_params_covers_manifest_optuna_surface() -> None:
    trial = _FakeTrial()
    params = suggest_params(trial)

    manifest_keys = {
        str(meta["legacy_flat"])
        for _, meta in iter_manifest_parameters(stage_contains="optuna")
        if meta.get("legacy_flat")
    }

    assert "phase_apply_wind_cadence" in params
    assert "phase_temperature_cadence" in params
    assert "terrain_scale" in params
    assert "water_level" in params
    assert manifest_keys.issubset(params.keys())


def test_manifest_suggestion_spec_preserves_step_and_log_metadata() -> None:
    metadata = dict(
        legacy_flat="phase_wind_field_cadence",
        type="int",
        min=8,
        max=60,
        step=2,
        log=True,
    )
    spec = build_optuna_suggestion_spec(metadata)

    assert spec is not None
    assert spec["name"] == "phase_wind_field_cadence"
    assert spec["step"] == 2
    assert spec["log"] is True


def test_trial_config_persists_optuna_metadata() -> None:
    config = build_trial_config(
        {"phase_apply_wind_cadence": 2},
        metadata={"profile": "mobile", "source_label": "local_optuna"},
    )

    assert config["source_label"] == "local_optuna"
    assert config["optuna"]["profile"] == "mobile"


def test_mobile_profile_prefers_mobile_relevant_surface() -> None:
    mobile_entries = select_optuna_manifest_parameters(profile="mobile")
    mobile_keys = {str(meta.get("legacy_flat")) for _, meta in mobile_entries}

    assert "phase_apply_wind_cadence" in mobile_keys
    assert "terrain_scale" in mobile_keys


def test_cloud_defaults_stay_scoped_to_runtime_mutable_manifest() -> None:
    runtime_defaults = manifest_defaults(stage_contains="optuna", runtime_mutable=True)
    assert (
        cloud_run_optimizer.DEFAULTS["phase_apply_wind_cadence"]
        == runtime_defaults["phase_apply_wind_cadence"]
    )
    assert "terrain_scale" not in cloud_run_optimizer.DEFAULTS
    assert "terrain_scale" in cloud_run_optimizer.EXTENDED_DEFAULTS


def test_cloud_suggest_params_respects_extended_surface_split() -> None:
    trial = _FakeTrial()
    fast_params = cloud_run_optimizer.suggest_params(trial, extended=False)
    extended_params = cloud_run_optimizer.suggest_params(trial, extended=True)

    assert "phase_apply_wind_cadence" in fast_params
    assert "terrain_scale" not in fast_params
    assert "terrain_scale" in extended_params


def test_optuna_uses_manifest_step_metadata_for_scheduler_and_worldgen() -> None:
    trial = _FakeTrial()
    params = suggest_params(trial)

    call_map = {name: (kind, low, high, kwargs) for kind, name, low, high, kwargs in trial.calls}

    assert params["phase_wind_field_cadence"] == 8
    assert call_map["phase_wind_field_cadence"][3]["step"] == 2
    assert call_map["terrain_scale"][3]["step"] == 0.05
    assert call_map["water_level"][3]["step"] == 0.01
