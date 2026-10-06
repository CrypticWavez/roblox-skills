"""tools/luau_analyze.py (baseline comparison over canned analyzer output) and tools/luau_defs.py (lock,
sha256-verified fetch over file:// URLs). No network and no luau-lsp binary needed."""
import contextlib
import hashlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import luau_analyze  # noqa: E402
import luau_defs  # noqa: E402

CANNED = f"""[INFO] Loaded definitions file
{ROOT}/packages/GameKit/Signal.luau [ReplicatedStorage.Workbench.GameKit.Signal]:10.5-10.9: TypeError: Type 'string' could not be converted into 'number'
caused by:
  Property 'x' is missing
packages/GameKit/Signal.luau:12.1-12.4: LintWarning: (UnusedLocal) Variable 'y' is never used
{ROOT}/packages/GameKit/Signal.luau [ReplicatedStorage.Workbench.GameKit.Signal]:10.5-10.9: TypeError: Type 'string' could not be converted into 'number'
caused by:
  Property 'x' is missing
./fixtures/kits/shared/foundation_probes.luau:3.1-3.5: SyntaxError: Expected identifier
"""


class ParseTest(unittest.TestCase):
    def test_parse_relativises_dedupes_and_joins_continuations(self):
        diagnostics, errors = luau_analyze.parse(CANNED)
        self.assertEqual(errors, [])
        self.assertEqual(len(diagnostics), 3, "the duplicate module report counts once")
        first = diagnostics[0]
        self.assertEqual((first["path"], first["line"], first["col"], first["type"]), ("packages/GameKit/Signal.luau", 10, 5, "TypeError"))
        self.assertIn("Property 'x' is missing", first["message"])
        self.assertEqual(diagnostics[2]["path"], "fixtures/kits/shared/foundation_probes.luau")
        self.assertEqual(luau_analyze.summarise(diagnostics), {
            "fixtures/kits/shared/foundation_probes.luau": {"total": 1, "by_type": {"SyntaxError": 1}},
            "packages/GameKit/Signal.luau": {"total": 2, "by_type": {"LintWarning": 1, "TypeError": 1}},
        })

    def test_same_line_different_message_is_kept(self):
        text = "a.luau:1.1-1.2: TypeError: one\na.luau:1.1-1.2: TypeError: two\n"
        self.assertEqual(len(luau_analyze.parse(text)[0]), 2)

    def test_error_log_lines_are_reported(self):
        _, errors = luau_analyze.parse("[ERROR] failed to load sourcemap\n")
        self.assertEqual(errors, ["[ERROR] failed to load sourcemap"])

    def test_compare_finds_increases_new_files_and_decreases(self):
        baseline = {"a.luau": {"total": 2}, "b.luau": {"total": 3}}
        current = {"a.luau": {"total": 2}, "b.luau": {"total": 1}, "c.luau": {"total": 1}}
        self.assertEqual(luau_analyze.compare(baseline, current), ([("c.luau", 0, 1)], [("b.luau", 3, 1)]))

    def test_pinned_version_reads_rokit(self):
        self.assertEqual(luau_analyze.pinned_version(), "1.70.1")


class BaselineFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="luau-analyze-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.baseline = self.tmp / "baseline.json"
        self.report = self.tmp / "report.json"

    def run_tool(self, text, *args):
        output = self.tmp / "output.txt"
        output.write_text(text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = luau_analyze.main(["--from-output", str(output), "--baseline", str(self.baseline), "--report", str(self.report), *args])
        return code, out.getvalue()

    def test_record_then_no_regression_then_increase_then_decrease(self):
        code, text = self.run_tool(CANNED, "--update-baseline")
        self.assertEqual(code, 0, text)
        doc = json.loads(self.baseline.read_text())
        self.assertEqual((doc["schema"], doc["total"], doc["luau_lsp"]), ("luau-lsp-baseline/1", 3, "1.70.1"))
        self.assertEqual(json.loads(self.report.read_text())["total"], 3)

        code, text = self.run_tool(CANNED)
        self.assertEqual(code, 0, text)
        self.assertIn("0 files over, 0 under", text)

        worse = CANNED + "packages/GameKit/Signal.luau:20.1-20.2: TypeError: planted\n"
        code, text = self.run_tool(worse)
        self.assertEqual(code, 1)
        self.assertIn("FAIL packages/GameKit/Signal.luau: 3 diagnostics, baseline 2", text)
        self.assertIn("20:1 TypeError: planted", text)

        new_file = CANNED + "packages/UIKit/New.luau:1.1-1.2: TypeError: new file\n"
        self.assertEqual(self.run_tool(new_file)[0], 1, "a new file with diagnostics counts from zero")

        better = "packages/GameKit/Signal.luau:12.1-12.4: LintWarning: (UnusedLocal) Variable 'y' is never used\n"
        code, text = self.run_tool(better)
        self.assertEqual(code, 0)
        self.assertIn("lower packages/GameKit/Signal.luau: 1 diagnostics, baseline 2", text)

    def test_stale_or_missing_baseline_fails(self):
        self.assertEqual(self.run_tool(CANNED)[0], 1, "no baseline yet")
        self.run_tool(CANNED, "--update-baseline")
        doc = json.loads(self.baseline.read_text())
        doc["luau_lsp"] = "1.60.0"
        self.baseline.write_text(json.dumps(doc))
        code, text = self.run_tool(CANNED)
        self.assertEqual(code, 1)
        self.assertIn("recorded with luau-lsp 1.60.0", text)
        doc["luau_lsp"] = "1.70.1"
        doc["definitions_sha256"] = "0" * 64
        self.baseline.write_text(json.dumps(doc))
        self.assertIn("other definitions", self.run_tool(CANNED)[1])

    def test_analyzer_errors_fail(self):
        self.run_tool(CANNED, "--update-baseline")
        code, text = self.run_tool(CANNED + "[ERROR] could not read definitions\n")
        self.assertEqual(code, 1)
        self.assertIn("FAIL analyzer error", text)

    def test_missing_binary_is_skipped_not_passed(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = luau_analyze.main(["--luau-lsp", str(self.tmp / "no-such-binary"), "--baseline", str(self.baseline), "--report", str(self.report)])
        self.assertEqual(code, luau_analyze.EXIT_SKIPPED)
        self.assertIn("SKIPPED", out.getvalue())
        self.assertFalse(self.report.exists(), "nothing analyzed, nothing reported")

    def test_repository_baseline_matches_the_pins(self):
        doc = json.loads(luau_analyze.BASELINE.read_text())
        lock = luau_defs.load_lock()
        self.assertEqual(doc["luau_lsp"], luau_analyze.pinned_version())
        self.assertEqual(doc["definitions_sha256"], next(f["sha256"] for f in lock["files"] if f["role"] == "definitions"))
        self.assertEqual(doc["total"], sum(entry["total"] for entry in doc["files"].values()))


class DefinitionsLockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="luau-defs-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.source = self.tmp / "source"
        self.source.mkdir()
        self.payload = b"declare game: DataModel\n"
        (self.source / "defs.d.luau").write_bytes(self.payload)
        self.lock = {
            "schema": "luau-defs-lock/1",
            "luau_lsp": {"version": "1.70.1", "commit": "a" * 40},
            "files": [{
                "name": "defs.d.luau", "role": "definitions", "bytes": len(self.payload),
                "sha256": hashlib.sha256(self.payload).hexdigest(), "url": (self.source / "defs.d.luau").as_uri(),
            }],
        }

    def test_repository_lock_is_valid_and_pinned_to_a_commit(self):
        lock = luau_defs.load_lock()
        self.assertEqual(lock["luau_lsp"]["version"], "1.70.1")
        for entry in lock["files"]:
            self.assertIn(f"/{lock['luau_lsp']['commit']}/", entry["url"])
            self.assertTrue(entry["url"].startswith("https://raw.githubusercontent.com/"))

    def test_lock_problems(self):
        self.assertEqual(luau_defs.lock_problems(self.lock, allow_file_urls=True), [])
        problems = luau_defs.lock_problems(self.lock)
        self.assertTrue(any("url must be https" in p for p in problems), problems)
        bad = json.loads(json.dumps(self.lock))
        bad["files"][0].update({"name": "../escape", "role": "other", "sha256": "XYZ", "bytes": 0})
        bad["luau_lsp"]["commit"] = "main"
        problems = "; ".join(luau_defs.lock_problems(bad, allow_file_urls=True))
        for needle in ("40-hex commit", "plain file name", "role must be", "sha256 must be", "bytes must be", "role 'definitions'"):
            self.assertIn(needle, problems)
        wrong_commit = json.loads(json.dumps(self.lock))
        wrong_commit["files"][0]["url"] = "https://raw.githubusercontent.com/x/y/" + "b" * 40 + "/defs.d.luau"
        self.assertTrue(any("pinned commit" in p for p in luau_defs.lock_problems(wrong_commit)))

    def test_fetch_verifies_and_refuses_a_changed_file(self):
        cache = self.tmp / "cache"
        logs = []
        self.assertEqual(luau_defs.fetch(self.lock, cache, log=logs.append), [])
        self.assertEqual((cache / "defs.d.luau").read_bytes(), self.payload)
        self.assertEqual([state for _, _, state in luau_defs.cached_state(self.lock, cache)], ["ok"])
        (self.source / "defs.d.luau").write_bytes(b"declare game: any\n" + b"x" * 7)
        (cache / "defs.d.luau").unlink()
        problems = luau_defs.fetch(self.lock, cache, log=logs.append)
        self.assertEqual(len(problems), 1)
        self.assertFalse((cache / "defs.d.luau").exists(), "a mismatched download is never kept")
        self.assertEqual(list(cache.iterdir()), [], "no temp files left behind")


if __name__ == "__main__":
    unittest.main()
