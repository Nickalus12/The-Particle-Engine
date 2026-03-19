"""MLflow setup and utilities for The Particle Engine."""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

RESEARCH_DIR = Path(__file__).resolve().parent
MLFLOW_DB = f"sqlite:///{RESEARCH_DIR / 'mlflow.db'}"
EXPERIMENT_NAME = "particle-engine"


def setup_mlflow():
    """Configure MLflow with local SQLite backend."""
    import mlflow

    mlflow.set_tracking_uri(MLFLOW_DB)

    experiment = mlflow.get_experiment_by_name(EXPERIMENT_NAME)
    if experiment is None:
        mlflow.create_experiment(
            EXPERIMENT_NAME,
            tags={
                "project": "The Particle Engine",
                "type": "physics_simulation",
                "framework": "flutter_flame",
            },
        )
    mlflow.set_experiment(EXPERIMENT_NAME)
    return EXPERIMENT_NAME


def log_benchmark_run(result: dict, run_name: str | None = None):
    """Log a benchmark.py result dict to MLflow."""
    import mlflow

    setup_mlflow()

    with mlflow.start_run(run_name=run_name):
        # Overall metrics
        mlflow.log_metric("overall_score", result["overall_score"])
        mlflow.log_metric("total_passed", result["total_passed"])
        mlflow.log_metric("total_failed", result["total_failed"])
        mlflow.log_metric("total_tests", result["total_tests"])
        mlflow.log_metric("duration_seconds", result["duration_seconds"])

        # Domain scores
        for domain, data in result.get("domain_scores", {}).items():
            score = data.get("score", 0) if isinstance(data, dict) else 0
            mlflow.log_metric(f"domain_{domain.lower()}", score)

        # Per-category scores
        for category, data in result.get("category_scores", {}).items():
            if not isinstance(data, dict):
                continue
            safe_name = (
                category.lower()
                .replace(" ", "_")
                .replace(":", "")
                .replace("/", "_")
                .replace("&", "and")
            )
            mlflow.log_metric(
                f"cat_{safe_name}_pass_rate", data.get("pass_rate", 0)
            )
            mlflow.log_metric(f"cat_{safe_name}_passed", data.get("passed", 0))
            mlflow.log_metric(f"cat_{safe_name}_failed", data.get("failed", 0))

        # Tags
        mlflow.set_tag(
            "benchmark_type",
            "full" if result.get("total_tests", 0) > 500 else "quick",
        )
        if result.get("git_hash"):
            mlflow.set_tag("git_hash", result["git_hash"])
        if result.get("timestamp"):
            mlflow.set_tag("timestamp", result["timestamp"])

        # Log the full result as artifact
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(result, f, indent=2, default=str)
            mlflow.log_artifact(f.name, "benchmark_results")


def log_optuna_trial(
    trial_number: int,
    params: dict,
    physics_score: float,
    visual_score: float,
    overall_score: float,
):
    """Log an individual Optuna trial to MLflow."""
    import mlflow

    setup_mlflow()

    with mlflow.start_run(run_name=f"optuna_trial_{trial_number}"):
        for key, value in params.items():
            mlflow.log_param(key, value)

        mlflow.log_metric("physics_score", physics_score)
        mlflow.log_metric("visual_score", visual_score)
        mlflow.log_metric("overall_score", overall_score)
        mlflow.log_metric("trial_number", trial_number)

        mlflow.set_tag("run_type", "optuna_trial")
        mlflow.set_tag("trial_number", str(trial_number))
