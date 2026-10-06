"""tools/luau_analyze.py (baseline comparison over canned analyzer output) and tools/luau_defs.py (lock,
sha256-verified fetch over file:// URLs). No network and no luau-lsp binary needed."""
import contextlib
import hashlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


# What luau-lsp 1.70.1 `analyze` printed for a file with no diagnostics (the clean capture's own lines).
PREAMBLE = """[INFO] Loading definitions file: @roblox - build/luau-lsp/globalTypes.PluginSecurity.d.luau
[WARN] client does not allow didChangeWatchedFiles registration - automatic updating on sourcemap changes disabled
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

    def test_unrecognised_output_fails(self):
        # Before: a crash message parsed as zero diagnostics, every baseline file counted as lower, exit 0.
        self.run_tool(CANNED, "--update-baseline")
        self.report.unlink()
        crash = "terminate called after throwing an instance of 'std::runtime_error'\n  what():  failed to load definitions file\n"
        code, text = self.run_tool(crash)
        self.assertEqual(code, 1, text)
        self.assertIn("FAIL the output has no diagnostic and no luau-lsp log line", text)
        self.assertIn("what():  failed to load definitions file", text, "the output's tail is shown")
        self.assertNotIn("under", text, "nothing was compared with the baseline")
        self.assertFalse(self.report.exists())
        self.assertEqual(self.run_tool("usage: luau-lsp analyze [options]\n")[0], 1)

    def test_log_lines_only_are_a_finished_clean_run(self):
        self.run_tool(CANNED, "--update-baseline")
        code, text = self.run_tool("[INFO] Loaded definitions file\n")
        self.assertEqual(code, 0, text)
        self.assertIn("0 diagnostics in 0 files", text)
        code, text = self.run_tool(PREAMBLE)
        self.assertEqual(code, 0, text)
        self.assertIn("0 diagnostics in 0 files", text)

    def test_crash_after_the_log_preamble_fails(self):
        # Before: one log line anywhere made the capture "recognised", so a crash after luau-lsp's
        # preamble parsed as zero diagnostics and passed with every baseline file "under".
        self.run_tool(CANNED, "--update-baseline")
        self.report.unlink()
        crash = PREAMBLE + "terminate called after throwing an instance of 'std::bad_alloc'\n  what():  std::bad_alloc\n"
        code, text = self.run_tool(crash)
        self.assertEqual(code, 1, text)
        self.assertIn("FAIL the output has no diagnostic and 2 line(s) that are not luau-lsp log lines, first: terminate called", text)
        self.assertIn("what():  std::bad_alloc", text, "the output's tail is shown")
        self.assertNotIn("under", text, "nothing was compared with the baseline")
        self.assertFalse(self.report.exists())
        # with diagnostics, other lines are continuations of their messages and still parse
        self.assertEqual(self.run_tool(PREAMBLE + CANNED)[0], 0)

    def test_empty_output_fails(self):
        # Before: an empty capture (a run that never started, the wrong file) passed as a clean run.
        self.run_tool(CANNED, "--update-baseline")
        self.report.unlink()
        for empty in ("", "\n \n\t\n"):
            with self.subTest(text=repr(empty)):
                code, text = self.run_tool(empty)
                self.assertEqual(code, 1, text)
                self.assertIn("FAIL the output is empty (luau-lsp always prints its [INFO] preamble)", text)
                self.assertNotIn("under", text)
                self.assertFalse(self.report.exists())

    def test_exit_problem_keeps_the_analyzer_exit_code(self):
        diagnostics, _ = luau_analyze.parse(CANNED)
        self.assertIsNone(luau_analyze.exit_problem(0, []))
        self.assertIsNone(luau_analyze.exit_problem(0, diagnostics))
        self.assertIsNone(luau_analyze.exit_problem(1, diagnostics), "luau-lsp exits 1 when it reports diagnostics")
        self.assertIn("killed by signal 6", luau_analyze.exit_problem(-6, diagnostics))
        self.assertIn("exited 2", luau_analyze.exit_problem(2, diagnostics))
        self.assertIn("exited 139", luau_analyze.exit_problem(139, []))
        self.assertIn("without a diagnostic", luau_analyze.exit_problem(1, []))

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


FAKE_LSP = """#!/bin/sh
if [ "$1" = "--version" ]; then echo "$FAKE_LSP_VERSION"; exit 0; fi
if [ "$1" = "sourcemap" ]; then exit 0; fi
cat "$FAKE_LSP_OUTPUT" >&2
if [ "$FAKE_LSP_EXIT" = "abort" ]; then kill -ABRT $$; fi
exit "$FAKE_LSP_EXIT"
"""


@unittest.skipIf(os.name == "nt", "the fake analyzer is a POSIX shell script")
class AnalyzerExitCodeTest(unittest.TestCase):
    """The live route with a fake luau-lsp and rojo on PATH: the analyzer's exit code decides too."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="luau-analyze-exit-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.baseline = self.tmp / "baseline.json"
        self.report = self.tmp / "report.json"
        self.output = self.tmp / "analyzer-output.txt"
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name in ("luau-lsp", "rojo"):
            path = bin_dir / name
            path.write_text(FAKE_LSP)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        self.binary = bin_dir / "luau-lsp"
        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}", "FAKE_LSP_VERSION": luau_analyze.pinned_version(),
               "FAKE_LSP_OUTPUT": str(self.output)}
        for patcher in (
            mock.patch.dict(os.environ, env),
            mock.patch.object(luau_analyze, "CACHE", self.tmp / "cache"),
            mock.patch.object(luau_analyze.luau_defs, "cached_state", return_value=[]),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.assertEqual(self.analyze(CANNED, "1", "--update-baseline")[0], 0)

    def analyze(self, text, exit_code, *args):
        self.output.write_text(text)
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"FAKE_LSP_EXIT": exit_code}), contextlib.redirect_stdout(out):
            code = luau_analyze.main(["--luau-lsp", str(self.binary), "--baseline", str(self.baseline), "--report", str(self.report), *args])
        return code, out.getvalue()

    def test_run_analyzer_returns_the_exit_code(self):
        self.output.write_text("x")
        with mock.patch.dict(os.environ, {"FAKE_LSP_EXIT": "abort"}):
            code, text = luau_analyze.run_analyzer(str(self.binary), self.tmp / "defs", self.tmp / "sourcemap.json")
        self.assertLess(code, 0, "killed by a signal")
        self.assertEqual(text, "x")

    def test_finished_runs_pass(self):
        self.assertEqual(self.analyze(CANNED, "1")[0], 0, "exit 1 with diagnostics is how luau-lsp reports them")
        code, text = self.analyze("", "0")
        self.assertEqual(code, 0, text)
        self.assertIn("0 diagnostics in 0 files", text)

    def test_crashes_and_rejected_arguments_fail(self):
        # Before: the exit code was discarded, so each of these passed with every file "under" the baseline.
        partial = CANNED.split("caused by:")[0] + "terminate called after throwing an instance of 'std::bad_alloc'\n"
        for text, exit_code, needle in (
            (partial, "abort", "luau-lsp was killed by signal 6"),
            ("", "abort", "luau-lsp was killed by signal 6"),
            ("Unknown option: --definitions:@roblox\n", "2", "luau-lsp exited 2"),
            (CANNED, "139", "luau-lsp exited 139"),
            ("failed to read sourcemap\n", "1", "luau-lsp exited 1 without a diagnostic"),
        ):
            with self.subTest(exit_code=exit_code, text=text[:30]):
                if self.report.exists():
                    self.report.unlink()
                code, out = self.analyze(text, exit_code)
                self.assertEqual(code, 1, out)
                self.assertIn(f"FAIL {needle}", out)
                self.assertNotIn("under", out, "nothing was compared with the baseline")
                self.assertFalse(self.report.exists())
                if text:
                    self.assertIn(text.strip().splitlines()[-1], out, "the output's tail is shown")


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


PLUGIN = ROOT / "plugins" / "luau-lsp" / ".claude-plugin" / "plugin.json"
MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"


def plugin_server():
    return json.loads(PLUGIN.read_text())["lspServers"]["luau-lsp"]


def expand(text):
    return text.replace("${CLAUDE_PROJECT_DIR}", str(ROOT))


class LspSession:
    """Minimal LSP client over stdio (Content-Length framing), enough for one push-diagnostics round trip."""

    def __init__(self, cmd, settings):
        import queue
        import subprocess
        import threading

        self.settings = settings
        self.messages = queue.Queue()
        self.proc = subprocess.Popen(cmd, cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        stream = self.proc.stdout
        while True:
            length = None
            while True:
                line = stream.readline()
                if not line:
                    self.messages.put(None)
                    return
                line = line.strip()
                if not line:
                    break
                name, _, value = line.decode("ascii").partition(":")
                if name.lower() == "content-length":
                    length = int(value)
            self.messages.put(json.loads(stream.read(length)))

    def send(self, payload):
        body = json.dumps({"jsonrpc": "2.0", **payload}).encode("utf-8")
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send({"id": self.next_id, "method": method, "params": params})
        return self.next_id

    def wait(self, predicate, timeout):
        """Answers the server's requests (configuration from the plugin's settings) until predicate matches."""
        import queue
        import time

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if message is None:
                raise AssertionError("luau-lsp exited")
            if "method" in message and "id" in message:
                result = None
                if message["method"] == "workspace/configuration":
                    result = [self.settings.get(item.get("section")) if item.get("section") else self.settings for item in message["params"]["items"]]
                self.send({"id": message["id"], "result": result})
            elif predicate(message):
                return message
        raise AssertionError("timed out waiting for luau-lsp")

    def close(self):
        try:
            self.request("shutdown", None)
            self.send({"method": "exit"})
            self.proc.wait(timeout=10)
        except Exception:  # noqa: BLE001  (best effort; kill below)
            pass
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except OSError:
                pass


class ClaudePluginTest(unittest.TestCase):
    def test_marketplace_lists_the_plugin(self):
        market = json.loads(MARKETPLACE.read_text())
        self.assertEqual(market["name"], "roblox-factory", "docs/pc-setup.md installs luau-lsp@roblox-factory")
        entry = next(p for p in market["plugins"] if p["name"] == "luau-lsp")
        self.assertEqual((ROOT / entry["source"]).resolve(), PLUGIN.parent.parent.resolve())

    def test_plugin_matches_the_pins(self):
        plugin = json.loads(PLUGIN.read_text())
        server = plugin_server()
        self.assertEqual(plugin["version"], luau_analyze.pinned_version(), "bump with rokit.toml")
        self.assertEqual(server["command"], "luau-lsp", "the rokit-installed binary, never a machine path")
        names = {entry["role"]: entry["name"] for entry in luau_defs.load_lock()["files"]}
        self.assertIn(f"--definitions:@roblox=${{CLAUDE_PROJECT_DIR}}/build/luau-lsp/{names['definitions']}", server["args"])
        self.assertIn(f"--docs=${{CLAUDE_PROJECT_DIR}}/build/luau-lsp/{names['docs']}", server["args"])
        self.assertNotIn("--enable-crash-reporting", server["args"])
        self.assertEqual(server["settings"]["luau-lsp"]["sourcemap"]["sourcemapFile"], luau_analyze.CACHE.relative_to(ROOT).as_posix() + "/sourcemap.json")
        text = PLUGIN.read_text() + MARKETPLACE.read_text()
        for needle in ("/home/", "/Users/", "C:\\\\", "/root/"):
            self.assertNotIn(needle, text)

    def test_language_server_reports_type_errors(self):
        binary = luau_analyze.find_binary()
        lock = luau_defs.load_lock()
        if binary is None or any(state != "ok" for _, _, state in luau_defs.cached_state(lock)):
            self.skipTest("needs a luau-lsp binary ($LUAU_LSP or PATH) and python3 tools/luau_defs.py")
        server = plugin_server()
        session = LspSession([binary, *(expand(a) for a in server["args"])], server["settings"])
        self.addCleanup(session.close)
        init = session.request("initialize", {
            "processId": None, "rootUri": ROOT.as_uri(), "workspaceFolders": [{"uri": ROOT.as_uri(), "name": "factory"}],
            "capabilities": {"workspace": {"configuration": True}, "textDocument": {"publishDiagnostics": {}}},
        })
        session.wait(lambda m: m.get("id") == init, 60)
        session.send({"method": "initialized", "params": {}})
        uri = (ROOT / "build" / "luau-lsp" / "plugin-smoke.luau").as_uri()  # never written: an open buffer only
        source = '--!strict\nlocal count: number = "three"\nlocal part = Instance.new("Part")\npart.Anchored = 5\nreturn count, part\n'
        session.send({"method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "luau", "version": 1, "text": source}}})
        published = session.wait(lambda m: m.get("method") == "textDocument/publishDiagnostics" and m["params"]["uri"] == uri and m["params"]["diagnostics"], 120)
        lines = sorted({d["range"]["start"]["line"] for d in published["params"]["diagnostics"]})
        self.assertEqual(lines, [1, 3], published["params"]["diagnostics"])
        self.assertTrue(any("boolean" in d["message"] for d in published["params"]["diagnostics"]), "Roblox definitions loaded: Part.Anchored is a boolean")
        self.assertFalse((ROOT / "build" / "luau-lsp" / "plugin-smoke.luau").exists())


if __name__ == "__main__":
    unittest.main()
