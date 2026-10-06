"""Tests for tools/analytics_report.py (run: python3 -m unittest tests/test_analytics_report.py).

The legacy fixtures (fixtures/analytics/neutral_events.jsonl, expected_report.json,
excluded_by_default.json) predate this tool and are reproduced exactly, input hash included.
The kit-event/1 fixture (kit_events.jsonl) is written by tests/gamekit_platform_telemetry.spec.luau
from GameKit/Telemetry; expected_kit_report.json is this tool's reviewed output for it.
"""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import analytics_report  # noqa: E402

FIXTURES = ROOT / "fixtures" / "analytics"
WINDOW = ["--start", "2026-10-05T12:00:00Z", "--end", "2026-10-05T12:10:00Z"]


def run(args):
    """Runs the CLI; returns (exit code, parsed report or None, stderr text)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = analytics_report.main(args)
    text = out.getvalue()
    return code, (json.loads(text) if code == 0 and text else None), err.getvalue()


def write(directory, name, text):
    path = Path(directory) / name
    path.write_text(text, encoding="utf-8")
    return str(path)


def kit_line(**overrides):
    row = {
        "schema": "kit-event/1",
        "category": "custom",
        "name": "probe_event",
        "player": "1",
        "environment": "live",
        "synthetic": False,
    }
    row.update(overrides)
    return json.dumps(row)


class LegacyReport(unittest.TestCase):
    def test_reproduces_expected_report_with_synthetic_opt_in(self):
        code, report, _ = run([str(FIXTURES / "neutral_events.jsonl"), *WINDOW, "--include-synthetic"])
        self.assertEqual(code, 0)
        expected = json.loads((FIXTURES / "expected_report.json").read_text(encoding="utf-8"))
        self.assertEqual(report, expected)

    def test_reproduces_expected_report_text_and_key_order(self):
        raw = (FIXTURES / "neutral_events.jsonl").read_bytes()
        start = analytics_report.parse_time("2026-10-05T12:00:00Z")
        end = analytics_report.parse_time("2026-10-05T12:10:00Z")
        report = analytics_report.build_report(raw, start, end, include_synthetic=True)
        expected = (FIXTURES / "expected_report.json").read_bytes().decode("utf-8").replace("\r\n", "\n")
        self.assertEqual(json.dumps(report, indent=2) + "\n", expected)

    def test_excludes_synthetic_by_default(self):
        code, report, _ = run([str(FIXTURES / "neutral_events.jsonl"), *WINDOW])
        self.assertEqual(code, 0)
        expected = json.loads((FIXTURES / "excluded_by_default.json").read_text(encoding="utf-8"))
        self.assertEqual(report, expected)

    def test_window_duplicates_and_anomalies(self):
        rows = [
            {"schema_version": 1, "environment": "production", "event_id": "a", "name": "session_start",
             "session_id": "s", "timestamp": "2026-10-05T12:00:00Z", "cohort_id": "c", "build_id": "b",
             "acquisition": "x", "synthetic": False},
            {"schema_version": 1, "environment": "production", "event_id": "a", "name": "session_start",
             "session_id": "s", "timestamp": "2026-10-05T12:00:00Z"},
            {"schema_version": 1, "environment": "production", "event_id": "b", "name": "load_finished",
             "session_id": "s", "timestamp": "2026-10-05T13:00:00Z"},
            {"schema_version": 1, "environment": "production", "event_id": "c", "name": "load_finished",
             "session_id": "orphan", "timestamp": "2026-10-05T12:01:00Z"},
            {"schema_version": 1, "environment": "staging", "event_id": "d", "name": "session_start",
             "session_id": "t", "timestamp": "2026-10-05T12:00:00Z"},
            {"schema_version": 1, "environment": "production", "event_id": "e", "name": "load_finished",
             "session_id": "s", "timestamp": "not a time"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = write(directory, "rows.jsonl", "\n".join(json.dumps(row) for row in rows) + "\n")
            code, report, _ = run([path, *WINDOW])
        self.assertEqual(code, 0)
        self.assertEqual(report["duplicate_events_ignored"], 1)
        self.assertEqual(
            report["excluded_events"],
            {"invalid_timestamp": 1, "outside_window": 1, "test_or_staging_events": 1},
        )
        self.assertEqual(report["anomalies"], {"sessions_without_start": 1})
        self.assertEqual(len(report["cohorts"]), 1)
        self.assertEqual(report["cohorts"][0]["load_success"], {"numerator": 0, "denominator": 1, "rate": 0.0})

    def test_legacy_rows_need_a_window(self):
        code, report, err = run([str(FIXTURES / "neutral_events.jsonl")])
        self.assertEqual(code, 2)
        self.assertIsNone(report)
        self.assertIn("need --start and --end", err)
        code, _, err = run([str(FIXTURES / "neutral_events.jsonl"), "--start", "2026-10-05T12:10:00Z",
                            "--end", "2026-10-05T12:00:00Z"])
        self.assertEqual(code, 2)
        self.assertIn("before --end", err)
        code, _, err = run([str(FIXTURES / "neutral_events.jsonl"), "--start", "2026-10-05T12:00:00"])
        self.assertEqual(code, 2)


class KitEventReport(unittest.TestCase):
    def test_reproduces_expected_kit_report(self):
        code, report, _ = run([str(FIXTURES / "kit_events.jsonl"), "--include-synthetic"])
        self.assertEqual(code, 0)
        expected = json.loads((FIXTURES / "expected_kit_report.json").read_text(encoding="utf-8"))
        self.assertEqual(report, expected)

    def test_kit_report_numbers(self):
        code, report, _ = run([str(FIXTURES / "kit_events.jsonl"), "--include-synthetic"])
        self.assertEqual(code, 0)
        steps = report["funnels"]["first_session"]["steps"]
        self.assertEqual([step["sessions"] for step in steps], [4, 2, 1, 1])
        self.assertEqual(steps[1]["conversion_from_previous"], 0.5)
        self.assertEqual([step["players"] for step in report["onboarding"]["steps"]], [3, 2, 1])
        self.assertEqual(report["economy"]["currency_a"]["net"], 6)
        self.assertEqual(report["economy"]["currency_b"]["sources"], {"quest_reward": 5})
        levels = report["progression"]["main_path"]["levels"]
        self.assertEqual(levels[0]["drop_off"], 0.3333)
        self.assertEqual(levels[1]["failed"], 1)
        self.assertEqual(report["purchase_intent"]["product_a"]["offer_to_prompt"], 0.6667)
        self.assertEqual(report["custom"]["session_end"], {"count": 3, "value_sum": 440})

    def test_synthetic_rows_are_excluded_by_default(self):
        code, report, _ = run([str(FIXTURES / "kit_events.jsonl")])
        self.assertEqual(code, 0)
        self.assertEqual(report["events_used"], 0)
        self.assertEqual(report["excluded_events"], {"synthetic_events": 36})
        self.assertEqual(report["funnels"], {})

    def test_console_output_is_read_from_telemetry_lines(self):
        lines = (FIXTURES / "kit_events.jsonl").read_text(encoding="utf-8").splitlines()
        noise = ["  12:00:01.123  Server started", "ENGINE_CHECK {\"name\":\"x\"}"]
        console = noise + [f"  12:00:02  TELEMETRY_JSON {line}" for line in lines] + noise
        with tempfile.TemporaryDirectory() as directory:
            path = write(directory, "console.txt", "\n".join(console) + "\n")
            code, report, _ = run([path, "--console", "--include-synthetic"])
            plain_code, _, _ = run([path, "--include-synthetic"])
        self.assertEqual(code, 0)
        expected = json.loads((FIXTURES / "expected_kit_report.json").read_text(encoding="utf-8"))
        report.pop("input_sha256")
        expected.pop("input_sha256")
        self.assertEqual(report, expected)
        self.assertEqual(plain_code, 2, "without --console the noise is not JSON")

    def test_duplicates_invalid_rows_and_test_traffic(self):
        rows = [
            kit_line(event_id="a"),
            kit_line(event_id="a"),
            kit_line(category="economy", name="economy_source"),
            kit_line(environment="test"),
            kit_line(category="purchase_intent", purchase={"stage": "prompted", "product": "p", "kind": "gamepass"}),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = write(directory, "rows.jsonl", "\n".join(rows) + "\n")
            code, report, _ = run([path])
        self.assertEqual(code, 0)
        self.assertEqual(report["duplicate_events_ignored"], 1)
        self.assertEqual(report["excluded_events"], {"invalid_events": 1, "test_or_staging_events": 1})
        self.assertEqual(report["custom"], {"probe_event": {"count": 1, "value_sum": None}})
        self.assertEqual(report["purchase_intent"]["p"]["prompted"], 1)
        self.assertIsNone(report["purchase_intent"]["p"]["offer_to_prompt"])

    def test_window_needs_timestamps(self):
        rows = [
            kit_line(timestamp="2026-10-05T12:01:00Z"),
            kit_line(timestamp="2026-10-05T13:00:00Z"),
            kit_line(),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = write(directory, "rows.jsonl", "\n".join(rows) + "\n")
            code, report, _ = run([path, *WINDOW])
        self.assertEqual(code, 0)
        self.assertEqual(report["events_used"], 1)
        self.assertEqual(report["excluded_events"], {"missing_timestamp": 1, "outside_window": 1})

    def test_bad_input_exits_2(self):
        legacy = (FIXTURES / "neutral_events.jsonl").read_text(encoding="utf-8").splitlines()[0]
        cases = {
            "mixed.jsonl": kit_line() + "\n" + legacy + "\n",
            "unknown.jsonl": json.dumps({"hello": 1}) + "\n",
            "broken.jsonl": "{not json\n",
            "array.jsonl": "[1, 2]\n",
            "empty.jsonl": "\n",
        }
        with tempfile.TemporaryDirectory() as directory:
            for name, text in cases.items():
                code, report, err = run([write(directory, name, text)])
                self.assertEqual(code, 2, name)
                self.assertIsNone(report)
                self.assertTrue(err.startswith("analytics_report:"), err)
            code, _, _ = run([str(Path(directory) / "missing.jsonl")])
            self.assertEqual(code, 2)

    def test_out_writes_lf_json(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "report.json"
            code, _, _ = run([str(FIXTURES / "kit_events.jsonl"), "--include-synthetic", "--out", str(target)])
            self.assertEqual(code, 0)
            data = target.read_bytes()
        self.assertNotIn(b"\r\n", data)
        self.assertEqual(json.loads(data), json.loads((FIXTURES / "expected_kit_report.json").read_bytes()))


class Helpers(unittest.TestCase):
    def test_nearest_rank(self):
        self.assertIsNone(analytics_report.nearest_rank([], 50))
        self.assertEqual(analytics_report.nearest_rank([3], 95), 3.0)
        self.assertEqual(analytics_report.nearest_rank([4, 1, 3, 2], 50), 2.0)
        self.assertEqual(analytics_report.nearest_rank(list(range(1, 21)), 95), 19.0)

    def test_rate_rounds_and_handles_zero(self):
        self.assertEqual(analytics_report.rate(1, 3), {"numerator": 1, "denominator": 3, "rate": 0.3333})
        self.assertEqual(analytics_report.rate(0, 0)["rate"], None)


if __name__ == "__main__":
    unittest.main()
