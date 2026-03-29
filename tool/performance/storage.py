"""Persistence backends for performance run data."""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class StorageConfig:
    sqlite_path: Path
    history_jsonl_path: Path
    duckdb_path: Path | None = None
    postgres_dsn: str | None = None


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


class SQLitePerfStore:
    def __init__(self, db_path: Path) -> None:
        self._db_path = db_path
        _ensure_parent(db_path)
        self._conn = sqlite3.connect(str(db_path))
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._init_schema()

    def _init_schema(self) -> None:
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS perf_runs (
              run_id TEXT PRIMARY KEY,
              schema_version INTEGER NOT NULL DEFAULT 1,
              timestamp_utc TEXT NOT NULL,
              git_sha TEXT,
              git_branch TEXT,
              host TEXT,
              platform TEXT,
              profile TEXT,
              soak_level TEXT,
              total_tests INTEGER NOT NULL,
              failed_tests INTEGER NOT NULL,
              failed_cases INTEGER NOT NULL DEFAULT 0,
              failed_targets INTEGER NOT NULL DEFAULT 0,
              timed_out_targets INTEGER NOT NULL DEFAULT 0,
              telemetry_complete INTEGER NOT NULL DEFAULT 1,
              total_visual_cases INTEGER NOT NULL DEFAULT 0,
              failed_visual_cases INTEGER NOT NULL DEFAULT 0,
              quality_score_total REAL NOT NULL DEFAULT 0,
              quality_grade TEXT NOT NULL DEFAULT 'F',
              quality_gate_failed INTEGER NOT NULL DEFAULT 0,
              quality_threshold REAL NOT NULL DEFAULT 0,
              duration_ms REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS perf_test_cases (
              run_id TEXT NOT NULL,
              target TEXT NOT NULL,
              test_name TEXT NOT NULL,
              outcome TEXT NOT NULL,
              duration_ms REAL NOT NULL,
              FOREIGN KEY(run_id) REFERENCES perf_runs(run_id)
            );

            CREATE TABLE IF NOT EXISTS perf_scenarios (
              run_id TEXT NOT NULL,
              suite TEXT NOT NULL,
              scenario TEXT NOT NULL,
              metric_key TEXT NOT NULL,
              metric_value REAL NOT NULL,
              tags_json TEXT NOT NULL,
              FOREIGN KEY(run_id) REFERENCES perf_runs(run_id)
            );

            CREATE TABLE IF NOT EXISTS perf_visual_artifacts (
              run_id TEXT NOT NULL,
              scenario TEXT NOT NULL,
              frame INTEGER NOT NULL,
              image_path TEXT NOT NULL,
              diff_path TEXT NOT NULL,
              ssim REAL NOT NULL,
              psnr REAL NOT NULL,
              diff_ratio REAL NOT NULL,
              pass INTEGER NOT NULL,
              FOREIGN KEY(run_id) REFERENCES perf_runs(run_id)
            );

            CREATE TABLE IF NOT EXISTS perf_quality_components (
              run_id TEXT NOT NULL,
              component_key TEXT NOT NULL,
              score REAL NOT NULL,
              weight REAL NOT NULL,
              raw_pass_rate REAL NOT NULL,
              status TEXT NOT NULL,
              details_json TEXT NOT NULL,
              FOREIGN KEY(run_id) REFERENCES perf_runs(run_id)
            );
            """
        )
        self._ensure_column("perf_runs", "schema_version", "INTEGER NOT NULL DEFAULT 1")
        self._ensure_column("perf_runs", "profile", "TEXT")
        self._ensure_column("perf_runs", "failed_cases", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "failed_targets", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "timed_out_targets", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "telemetry_complete", "INTEGER NOT NULL DEFAULT 1")
        self._ensure_column("perf_runs", "total_visual_cases", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "failed_visual_cases", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "quality_score_total", "REAL NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "quality_grade", "TEXT NOT NULL DEFAULT 'F'")
        self._ensure_column("perf_runs", "quality_gate_failed", "INTEGER NOT NULL DEFAULT 0")
        self._ensure_column("perf_runs", "quality_threshold", "REAL NOT NULL DEFAULT 0")
        self._conn.commit()

    def _ensure_column(self, table: str, column: str, decl: str) -> None:
        rows = self._conn.execute(f"PRAGMA table_info({table})").fetchall()
        existing = {row[1] for row in rows}
        if column in existing:
            return
        self._conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")

    def insert_run(self, run: dict[str, Any]) -> None:
        self._conn.execute(
            """
            INSERT OR REPLACE INTO perf_runs (
              run_id, schema_version, timestamp_utc, git_sha, git_branch, host,
              platform, profile, soak_level, total_tests, failed_tests,
              failed_cases, failed_targets, timed_out_targets, telemetry_complete,
              total_visual_cases, failed_visual_cases, quality_score_total,
              quality_grade, quality_gate_failed, quality_threshold, duration_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run["run_id"],
                int(run.get("schema_version", 1)),
                run["timestamp_utc"],
                run.get("git_sha"),
                run.get("git_branch"),
                run.get("host"),
                run.get("platform"),
                run.get("profile"),
                run.get("soak_level"),
                run["summary"]["total_tests"],
                run["summary"]["failed_tests"],
                run["summary"].get("failed_cases", 0),
                run["summary"].get("failed_targets", 0),
                run["summary"].get("timed_out_targets", 0),
                1 if run["summary"].get("telemetry_complete", True) else 0,
                run["summary"].get("total_visual_cases", 0),
                run["summary"].get("failed_visual_cases", 0),
                float(run["summary"].get("quality_score_total", 0.0)),
                str(run["summary"].get("quality_grade", "F")),
                1 if run["summary"].get("quality_gate_failed", False) else 0,
                float(run["summary"].get("quality_threshold", 0.0)),
                run["summary"]["duration_ms"],
            ),
        )
        self._conn.executemany(
            """
            INSERT INTO perf_test_cases (
              run_id, target, test_name, outcome, duration_ms
            ) VALUES (?, ?, ?, ?, ?)
            """,
            [
                (
                    run["run_id"],
                    case["target"],
                    case["name"],
                    case["outcome"],
                    float(case["duration_ms"]),
                )
                for case in run["test_cases"]
            ],
        )

        scenario_rows: list[tuple[str, str, str, str, float, str]] = []
        for scenario in run["scenarios"]:
            tags_json = json.dumps(scenario.get("tags", {}), sort_keys=True)
            for key, value in scenario.get("metrics", {}).items():
                scenario_rows.append(
                    (
                        run["run_id"],
                        scenario["suite"],
                        scenario["scenario"],
                        key,
                        float(value),
                        tags_json,
                    )
                )
        if scenario_rows:
            self._conn.executemany(
                """
                INSERT INTO perf_scenarios (
                  run_id, suite, scenario, metric_key, metric_value, tags_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                scenario_rows,
            )

        visual_rows: list[tuple[str, str, int, str, str, float, float, float, int]] = []
        for artifact in run.get("visual_artifacts", []):
            visual_rows.append(
                (
                    run["run_id"],
                    str(artifact.get("scenario", "unknown")),
                    int(artifact.get("frame", 0)),
                    str(artifact.get("image_path", "")),
                    str(artifact.get("diff_path", "")),
                    float(artifact.get("ssim", 0.0)),
                    float(artifact.get("psnr", 0.0)),
                    float(artifact.get("diff_ratio", 1.0)),
                    1 if bool(artifact.get("pass", False)) else 0,
                )
            )
        if visual_rows:
            self._conn.executemany(
                """
                INSERT INTO perf_visual_artifacts (
                  run_id, scenario, frame, image_path, diff_path, ssim, psnr, diff_ratio, pass
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                visual_rows,
            )

        quality_rows: list[tuple[str, str, float, float, float, str, str]] = []
        for component in run.get("quality_components", []):
            quality_rows.append(
                (
                    run["run_id"],
                    str(component.get("component_key", "unknown")),
                    float(component.get("score", 0.0)),
                    float(component.get("weight", 0.0)),
                    float(component.get("raw_pass_rate", 0.0)),
                    str(component.get("status", "unknown")),
                    json.dumps(component.get("details", {}), sort_keys=True),
                )
            )
        if quality_rows:
            self._conn.executemany(
                """
                INSERT INTO perf_quality_components (
                  run_id, component_key, score, weight, raw_pass_rate, status, details_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                quality_rows,
            )

        self._conn.commit()

    def get_previous_run(self, run_id: str) -> dict[str, Any] | None:
        row = self._conn.execute(
            """
            SELECT run_id, timestamp_utc, total_tests, failed_tests, duration_ms
                 , quality_score_total
            FROM perf_runs
            WHERE run_id != ?
            ORDER BY timestamp_utc DESC
            LIMIT 1
            """,
            (run_id,),
        ).fetchone()
        if row is None:
            return None
        return {
            "run_id": row[0],
            "timestamp_utc": row[1],
            "total_tests": row[2],
            "failed_tests": row[3],
            "duration_ms": row[4],
            "quality_score_total": row[5] if len(row) > 5 else 0.0,
        }

    def close(self) -> None:
        self._conn.close()


class JsonlPerfStore:
    def __init__(self, jsonl_path: Path) -> None:
        self._path = jsonl_path
        _ensure_parent(jsonl_path)

    def append_run(self, run: dict[str, Any]) -> None:
        with self._path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(run, sort_keys=True))
            f.write("\n")


class DuckDBPerfStore:
    def __init__(self, db_path: Path) -> None:
        try:
            import duckdb  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "duckdb package is not installed. Run: pip install duckdb"
            ) from exc

        self._duckdb = duckdb
        self._db_path = db_path
        _ensure_parent(db_path)
        self._conn = duckdb.connect(str(db_path))
        self._init_schema()

    def _init_schema(self) -> None:
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS perf_runs (
              run_id VARCHAR PRIMARY KEY,
              schema_version INTEGER,
              timestamp_utc VARCHAR,
              git_sha VARCHAR,
              git_branch VARCHAR,
              host VARCHAR,
              platform VARCHAR,
              profile VARCHAR,
              soak_level VARCHAR,
              total_tests INTEGER,
              failed_tests INTEGER,
              failed_cases INTEGER,
              failed_targets INTEGER,
              timed_out_targets INTEGER,
              telemetry_complete BOOLEAN,
              total_visual_cases INTEGER,
              failed_visual_cases INTEGER,
              quality_score_total DOUBLE,
              quality_grade VARCHAR,
              quality_gate_failed BOOLEAN,
              quality_threshold DOUBLE,
              duration_ms DOUBLE
            )
            """
        )
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS perf_scenarios (
              run_id VARCHAR,
              suite VARCHAR,
              scenario VARCHAR,
              metric_key VARCHAR,
              metric_value DOUBLE,
              tags_json VARCHAR
            )
            """
        )
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS perf_visual_artifacts (
              run_id VARCHAR,
              scenario VARCHAR,
              frame INTEGER,
              image_path VARCHAR,
              diff_path VARCHAR,
              ssim DOUBLE,
              psnr DOUBLE,
              diff_ratio DOUBLE,
              pass BOOLEAN
            )
            """
        )
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS perf_quality_components (
              run_id VARCHAR,
              component_key VARCHAR,
              score DOUBLE,
              weight DOUBLE,
              raw_pass_rate DOUBLE,
              status VARCHAR,
              details_json VARCHAR
            )
            """
        )

    def insert_run(self, run: dict[str, Any]) -> None:
        self._conn.execute(
            """
            INSERT OR REPLACE INTO perf_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run["run_id"],
                int(run.get("schema_version", 1)),
                run["timestamp_utc"],
                run.get("git_sha"),
                run.get("git_branch"),
                run.get("host"),
                run.get("platform"),
                run.get("profile"),
                run.get("soak_level"),
                run["summary"]["total_tests"],
                run["summary"]["failed_tests"],
                run["summary"].get("failed_cases", 0),
                run["summary"].get("failed_targets", 0),
                run["summary"].get("timed_out_targets", 0),
                bool(run["summary"].get("telemetry_complete", True)),
                run["summary"].get("total_visual_cases", 0),
                run["summary"].get("failed_visual_cases", 0),
                float(run["summary"].get("quality_score_total", 0.0)),
                str(run["summary"].get("quality_grade", "F")),
                bool(run["summary"].get("quality_gate_failed", False)),
                float(run["summary"].get("quality_threshold", 0.0)),
                run["summary"]["duration_ms"],
            ),
        )

        rows: list[tuple[str, str, str, str, float, str]] = []
        for scenario in run["scenarios"]:
            tags = json.dumps(scenario.get("tags", {}), sort_keys=True)
            for key, value in scenario.get("metrics", {}).items():
                rows.append(
                    (
                        run["run_id"],
                        scenario["suite"],
                        scenario["scenario"],
                        key,
                        float(value),
                        tags,
                    )
                )
        if rows:
            self._conn.executemany("INSERT INTO perf_scenarios VALUES (?, ?, ?, ?, ?, ?)", rows)

        visual_rows: list[tuple[str, str, int, str, str, float, float, float, bool]] = []
        for artifact in run.get("visual_artifacts", []):
            visual_rows.append(
                (
                    run["run_id"],
                    str(artifact.get("scenario", "unknown")),
                    int(artifact.get("frame", 0)),
                    str(artifact.get("image_path", "")),
                    str(artifact.get("diff_path", "")),
                    float(artifact.get("ssim", 0.0)),
                    float(artifact.get("psnr", 0.0)),
                    float(artifact.get("diff_ratio", 1.0)),
                    bool(artifact.get("pass", False)),
                )
            )
        if visual_rows:
            self._conn.executemany(
                "INSERT INTO perf_visual_artifacts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                visual_rows,
            )
        quality_rows: list[tuple[str, str, float, float, float, str, str]] = []
        for component in run.get("quality_components", []):
            quality_rows.append(
                (
                    run["run_id"],
                    str(component.get("component_key", "unknown")),
                    float(component.get("score", 0.0)),
                    float(component.get("weight", 0.0)),
                    float(component.get("raw_pass_rate", 0.0)),
                    str(component.get("status", "unknown")),
                    json.dumps(component.get("details", {}), sort_keys=True),
                )
            )
        if quality_rows:
            self._conn.executemany(
                "INSERT INTO perf_quality_components VALUES (?, ?, ?, ?, ?, ?, ?)",
                quality_rows,
            )

    def close(self) -> None:
        self._conn.close()


class PostgresPerfStore:
    def __init__(self, dsn: str) -> None:
        try:
            import psycopg  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "psycopg package is not installed. Run: pip install psycopg[binary]"
            ) from exc

        self._conn = psycopg.connect(dsn)
        self._init_schema()

    def _init_schema(self) -> None:
        with self._conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS perf_runs (
                  run_id TEXT PRIMARY KEY,
                  schema_version INTEGER NOT NULL DEFAULT 1,
                  timestamp_utc TEXT NOT NULL,
                  git_sha TEXT,
                  git_branch TEXT,
                  host TEXT,
                  platform TEXT,
                  profile TEXT,
                  soak_level TEXT,
                  total_tests INTEGER NOT NULL,
                  failed_tests INTEGER NOT NULL,
                  failed_cases INTEGER NOT NULL DEFAULT 0,
                  failed_targets INTEGER NOT NULL DEFAULT 0,
                  timed_out_targets INTEGER NOT NULL DEFAULT 0,
                  telemetry_complete BOOLEAN NOT NULL DEFAULT TRUE,
                  total_visual_cases INTEGER NOT NULL DEFAULT 0,
                  failed_visual_cases INTEGER NOT NULL DEFAULT 0,
                  quality_score_total DOUBLE PRECISION NOT NULL DEFAULT 0,
                  quality_grade TEXT NOT NULL DEFAULT 'F',
                  quality_gate_failed BOOLEAN NOT NULL DEFAULT FALSE,
                  quality_threshold DOUBLE PRECISION NOT NULL DEFAULT 0,
                  duration_ms DOUBLE PRECISION NOT NULL
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS perf_scenarios (
                  run_id TEXT NOT NULL,
                  suite TEXT NOT NULL,
                  scenario TEXT NOT NULL,
                  metric_key TEXT NOT NULL,
                  metric_value DOUBLE PRECISION NOT NULL,
                  tags_json JSONB NOT NULL
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS perf_visual_artifacts (
                  run_id TEXT NOT NULL,
                  scenario TEXT NOT NULL,
                  frame INTEGER NOT NULL,
                  image_path TEXT NOT NULL,
                  diff_path TEXT NOT NULL,
                  ssim DOUBLE PRECISION NOT NULL,
                  psnr DOUBLE PRECISION NOT NULL,
                  diff_ratio DOUBLE PRECISION NOT NULL,
                  pass BOOLEAN NOT NULL
                )
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS perf_quality_components (
                  run_id TEXT NOT NULL,
                  component_key TEXT NOT NULL,
                  score DOUBLE PRECISION NOT NULL,
                  weight DOUBLE PRECISION NOT NULL,
                  raw_pass_rate DOUBLE PRECISION NOT NULL,
                  status TEXT NOT NULL,
                  details_json JSONB NOT NULL
                )
                """
            )
        self._conn.commit()

    def insert_run(self, run: dict[str, Any]) -> None:
        with self._conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO perf_runs (
                  run_id, schema_version, timestamp_utc, git_sha, git_branch,
                  host, platform, profile, soak_level, total_tests, failed_tests,
                  failed_cases, failed_targets, timed_out_targets, telemetry_complete,
                  total_visual_cases, failed_visual_cases, quality_score_total,
                  quality_grade, quality_gate_failed, quality_threshold, duration_ms
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT(run_id) DO UPDATE SET
                  schema_version = EXCLUDED.schema_version,
                  timestamp_utc = EXCLUDED.timestamp_utc,
                  git_sha = EXCLUDED.git_sha,
                  git_branch = EXCLUDED.git_branch,
                  host = EXCLUDED.host,
                  platform = EXCLUDED.platform,
                  profile = EXCLUDED.profile,
                  soak_level = EXCLUDED.soak_level,
                  total_tests = EXCLUDED.total_tests,
                  failed_tests = EXCLUDED.failed_tests,
                  failed_cases = EXCLUDED.failed_cases,
                  failed_targets = EXCLUDED.failed_targets,
                  timed_out_targets = EXCLUDED.timed_out_targets,
                  telemetry_complete = EXCLUDED.telemetry_complete,
                  total_visual_cases = EXCLUDED.total_visual_cases,
                  failed_visual_cases = EXCLUDED.failed_visual_cases,
                  quality_score_total = EXCLUDED.quality_score_total,
                  quality_grade = EXCLUDED.quality_grade,
                  quality_gate_failed = EXCLUDED.quality_gate_failed,
                  quality_threshold = EXCLUDED.quality_threshold,
                  duration_ms = EXCLUDED.duration_ms
                """,
                (
                    run["run_id"],
                    int(run.get("schema_version", 1)),
                    run["timestamp_utc"],
                    run.get("git_sha"),
                    run.get("git_branch"),
                    run.get("host"),
                    run.get("platform"),
                    run.get("profile"),
                    run.get("soak_level"),
                    run["summary"]["total_tests"],
                    run["summary"]["failed_tests"],
                    run["summary"].get("failed_cases", 0),
                    run["summary"].get("failed_targets", 0),
                    run["summary"].get("timed_out_targets", 0),
                    bool(run["summary"].get("telemetry_complete", True)),
                    run["summary"].get("total_visual_cases", 0),
                    run["summary"].get("failed_visual_cases", 0),
                    float(run["summary"].get("quality_score_total", 0.0)),
                    str(run["summary"].get("quality_grade", "F")),
                    bool(run["summary"].get("quality_gate_failed", False)),
                    float(run["summary"].get("quality_threshold", 0.0)),
                    run["summary"]["duration_ms"],
                ),
            )
            for scenario in run["scenarios"]:
                tags = json.dumps(scenario.get("tags", {}), sort_keys=True)
                for key, value in scenario.get("metrics", {}).items():
                    cur.execute(
                        """
                        INSERT INTO perf_scenarios (
                          run_id, suite, scenario, metric_key, metric_value, tags_json
                        ) VALUES (%s, %s, %s, %s, %s, %s::jsonb)
                        """,
                        (
                            run["run_id"],
                            scenario["suite"],
                            scenario["scenario"],
                            key,
                            float(value),
                            tags,
                        ),
                    )
            for artifact in run.get("visual_artifacts", []):
                cur.execute(
                    """
                    INSERT INTO perf_visual_artifacts (
                      run_id, scenario, frame, image_path, diff_path, ssim, psnr, diff_ratio, pass
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        run["run_id"],
                        str(artifact.get("scenario", "unknown")),
                        int(artifact.get("frame", 0)),
                        str(artifact.get("image_path", "")),
                        str(artifact.get("diff_path", "")),
                        float(artifact.get("ssim", 0.0)),
                        float(artifact.get("psnr", 0.0)),
                        float(artifact.get("diff_ratio", 1.0)),
                        bool(artifact.get("pass", False)),
                    ),
                )
            for component in run.get("quality_components", []):
                cur.execute(
                    """
                    INSERT INTO perf_quality_components (
                      run_id, component_key, score, weight, raw_pass_rate, status, details_json
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb)
                    """,
                    (
                        run["run_id"],
                        str(component.get("component_key", "unknown")),
                        float(component.get("score", 0.0)),
                        float(component.get("weight", 0.0)),
                        float(component.get("raw_pass_rate", 0.0)),
                        str(component.get("status", "unknown")),
                        json.dumps(component.get("details", {}), sort_keys=True),
                    ),
                )
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()
