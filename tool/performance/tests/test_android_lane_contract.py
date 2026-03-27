from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tool" / "performance"))

import run_android_investigative_lane as lane  # type: ignore  # noqa: E402


class AndroidLaneContractTests(unittest.TestCase):
    def test_parse_machine_test_events(self) -> None:
        output = "\n".join(
            [
                '{"type":"testStart","test":{"id":1,"name":"a"}}',
                '{"type":"testDone","testID":1,"result":"success","hidden":false}',
                '{"type":"testDone","testID":2,"result":"failure","hidden":false}',
                '{"type":"testDone","testID":3,"result":"success","hidden":true}',
            ]
        )
        total, failed = lane._parse_machine_test_events(output)  # noqa: SLF001
        self.assertEqual(total, 2)
        self.assertEqual(failed, 1)

    def test_find_artifact_dir_uses_explicit_or_pipeline_output(self) -> None:
        explicit = lane._find_artifact_dir("artifact_dir=unused", "reports/custom")  # noqa: SLF001
        self.assertEqual(explicit, Path("reports/custom"))

        inferred = lane._find_artifact_dir("run_id=abc\nartifact_dir=reports/perf/r1\n", "")  # noqa: SLF001
        self.assertEqual(inferred, Path("reports/perf/r1"))

    def test_append_metrics_to_run_json_adds_scenarios(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            run_json = Path(td) / "run.json"
            run_json.write_text('{"scenarios": []}', encoding="utf-8")
            lane._append_metrics_to_run_json(  # noqa: SLF001
                run_json,
                [
                    lane.AndroidTargetResult(
                        target="test/smoke/ant_placement_regression_test.dart",
                        return_code=0,
                        timed_out=False,
                        elapsed_ms=1234.0,
                        test_count=1,
                        failed_count=0,
                    )
                ],
            )
            payload = run_json.read_text(encoding="utf-8")
            self.assertIn("runtime_smoke_android", payload)
            self.assertIn("ant_placement_regression_test", payload)


if __name__ == "__main__":
    unittest.main()
