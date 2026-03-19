#!/usr/bin/env python3
"""Import all historical experiment data into MLflow."""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

RESEARCH_DIR = Path(__file__).resolve().parent


def import_engine_results():
    """Import engine_results.tsv (autoresearch experiments)."""
    from research.mlflow_setup import setup_mlflow

    import mlflow

    setup_mlflow()

    tsv_path = RESEARCH_DIR / "engine_results.tsv"
    if not tsv_path.exists():
        print("No engine_results.tsv found")
        return

    count = 0
    with open(tsv_path, encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            run_name = f"autoresearch_{row.get('id', '?')}"
            with mlflow.start_run(run_name=run_name):
                mlflow.set_tag("run_type", "autoresearch")
                mlflow.set_tag("experiment_id", row.get("id", ""))
                mlflow.set_tag("file_changed", row.get("file", ""))
                mlflow.set_tag("description", row.get("description", ""))
                mlflow.set_tag("kept", row.get("kept", ""))
                mlflow.set_tag("timestamp", row.get("timestamp", ""))

                fps = row.get("fps", "")
                if fps and fps != "-":
                    try:
                        mlflow.log_metric("fps", float(fps))
                    except ValueError:
                        pass

                physics = row.get("physics", "")
                if physics and physics != "-":
                    try:
                        mlflow.log_metric("physics_score", float(physics))
                    except ValueError:
                        pass

                visuals = row.get("visuals", "")
                if visuals and visuals != "-":
                    try:
                        mlflow.log_metric("visual_score", float(visuals))
                    except ValueError:
                        pass

            count += 1

    print(f"Imported {count} engine_results.tsv entries")


def import_benchmark_history():
    """Import benchmark_history.jsonl."""
    from research.mlflow_setup import setup_mlflow

    import mlflow

    setup_mlflow()

    jsonl_path = RESEARCH_DIR / "benchmark_history.jsonl"
    if not jsonl_path.exists():
        print("No benchmark_history.jsonl found")
        return

    count = 0
    with open(jsonl_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue

            run_name = f"benchmark_{data.get('timestamp', count)}"
            with mlflow.start_run(run_name=run_name):
                mlflow.set_tag("run_type", "benchmark")
                mlflow.set_tag("timestamp", data.get("timestamp", ""))
                if data.get("git_hash"):
                    mlflow.set_tag("git_hash", data["git_hash"])

                mlflow.log_metric(
                    "overall_score", data.get("overall_score", 0)
                )
                mlflow.log_metric(
                    "total_passed", data.get("total_passed", 0)
                )
                mlflow.log_metric(
                    "total_failed", data.get("total_failed", 0)
                )
                mlflow.log_metric(
                    "total_tests", data.get("total_tests", 0)
                )
                mlflow.log_metric(
                    "duration_seconds", data.get("duration_seconds", 0)
                )

                for domain, ddata in data.get("domain_scores", {}).items():
                    score = (
                        ddata.get("score", 0) if isinstance(ddata, dict) else 0
                    )
                    mlflow.log_metric(f"domain_{domain.lower()}", score)

                for cat, cdata in data.get("category_scores", {}).items():
                    if isinstance(cdata, dict):
                        safe = (
                            cat.lower()
                            .replace(" ", "_")
                            .replace(":", "")
                            .replace("/", "_")
                            .replace("&", "and")
                        )
                        mlflow.log_metric(
                            f"cat_{safe}_pass_rate",
                            cdata.get("pass_rate", 0),
                        )

            count += 1

    print(f"Imported {count} benchmark history entries")


def import_optuna_study():
    """Import Optuna study trials if they exist."""
    from research.mlflow_setup import setup_mlflow

    import mlflow

    setup_mlflow()

    db_path = RESEARCH_DIR / "optuna_study.db"
    if not db_path.exists():
        print("No optuna_study.db found")
        return

    try:
        import optuna

        study = optuna.load_study(
            study_name="particle_engine",
            storage=f"sqlite:///{db_path}",
        )
    except Exception as e:
        print(f"Could not load Optuna study: {e}")
        return

    count = 0
    for trial in study.trials:
        if trial.state != optuna.trial.TrialState.COMPLETE:
            continue

        run_name = f"optuna_trial_{trial.number}"
        with mlflow.start_run(run_name=run_name):
            mlflow.set_tag("run_type", "optuna_trial")
            mlflow.set_tag("trial_number", str(trial.number))

            for key, value in trial.params.items():
                mlflow.log_param(key, value)

            if trial.values:
                if len(trial.values) >= 1:
                    mlflow.log_metric("physics_score", trial.values[0])
                if len(trial.values) >= 2:
                    mlflow.log_metric("visual_score", trial.values[1])

            for key, value in trial.user_attrs.items():
                if isinstance(value, (int, float)):
                    mlflow.log_metric(key, value)
                else:
                    mlflow.set_tag(key, str(value))

        count += 1

    print(f"Imported {count} Optuna trials")


if __name__ == "__main__":
    # Add project root to path so `research.mlflow_setup` resolves
    project_root = RESEARCH_DIR.parent
    if str(project_root) not in sys.path:
        sys.path.insert(0, str(project_root))

    print("Importing all historical data into MLflow...")
    print()
    import_engine_results()
    import_benchmark_history()
    import_optuna_study()
    print()
    print("Done! Start the MLflow UI:")
    print(
        f"  mlflow server --port 8080 --backend-store-uri sqlite:///{RESEARCH_DIR / 'mlflow.db'}"
    )
    print("  Then open http://localhost:8080")
