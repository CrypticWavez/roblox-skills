"""Tests for tools/starter_smoke.py's skip contract, its folder checks and the factory gate step that runs it.

  python3 -m unittest tests/test_starter_smoke.py

A missing rojo, lune or stylua is a skip, never a pass: exit 3 (exit 1 with --strict), which
tools/check.py maps to SKIPPED for starter-smoke-full, and a SKIPPED starter-smoke-full blocks a
non-strict run unless --allow-skip names it. The all-packages repo's folder checks (packages in
factory/, no Wally Packages/) compare exact names, also on a simulated case-insensitive filesystem.
No scaffold is made here (no tool runs; scaffold and Smoke.run are faked).
"""
import contextlib
import fnmatch
import importlib.util
import io
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "fakes"))
from case_insensitive_fs import case_insensitive_paths  # noqa: E402


def load_tool(name, alias):
    spec = importlib.util.spec_from_file_location(alias, ROOT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load_tool("starter_smoke", "factory_starter_smoke")
gate_module = load_tool("check", "factory_check")


class MissingTools(unittest.TestCase):
    def main(self, *argv, which=lambda tool: None):
        with mock.patch.object(smoke.shutil, "which", which), contextlib.redirect_stdout(io.StringIO()) as out:
            return smoke.main(list(argv)), out.getvalue()

    def test_missing_tools_exit_3_never_0(self):
        code, out = self.main()
        self.assertEqual(code, 3)
        self.assertEqual(code, smoke.SKIP_EXIT)
        self.assertIn("[skip] starter smoke: rojo, lune, stylua not installed", out)

    def test_strict_turns_a_missing_tool_into_a_failure(self):
        code, _ = self.main("--strict", which=lambda tool: None if tool == "lune" else f"/bin/{tool}")
        self.assertEqual(code, 1)

    def test_the_gate_reports_the_skip_as_skipped_and_counts_it(self):
        source = (ROOT / "tools" / "check.py").read_text(encoding="utf-8")
        call = re.search(r'gate\.cmd\("starter-smoke-full",[^\n]*\)\n', source)
        self.assertIsNotNone(call, "tools/check.py no longer runs starter-smoke-full")
        self.assertIn("skip_codes=(3,)", call.group(0))
        # Not an allowed skip: a SKIPPED starter-smoke-full fails a non-strict run without --allow-skip.
        self.assertFalse(any(fnmatch.fnmatchcase("starter-smoke-full", pattern) for pattern in gate_module.ALLOWED_SKIPS))
        empty = Path(tempfile.mkdtemp(prefix="no-tools-"))
        try:
            gate = gate_module.Gate()
            env = dict(os.environ, PATH=str(empty))
            with contextlib.redirect_stdout(io.StringIO()):
                gate.cmd("starter-smoke-full", [sys.executable, "tools/starter_smoke.py"], timeout=120, env=env, skip_codes=(3,))
                gate.cmd("starter-smoke-full-strict", [sys.executable, "tools/starter_smoke.py", "--strict"], timeout=120, env=env,
                         skip_codes=(3,))
        finally:
            shutil.rmtree(empty, ignore_errors=True)
        self.assertEqual([r["status"] for r in gate.results], ["SKIPPED", "FAIL"], gate.results)


class AllPackagesFolderChecks(unittest.TestCase):
    FACTORY = "SmokeAll: packages in factory/, no packages/"
    WALLY = "SmokeAll: wally never ran (no wally.lock, no Packages/)"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="smoke-all-"))
        self.dest = self.tmp / "SmokeAll"
        (self.dest / "factory" / "ProcGen").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def results(self):
        """{check: ok} from all_packages_repo on self.dest, with the scaffold and every tool run faked."""
        fake = smoke.Smoke()
        with mock.patch.object(smoke, "scaffold", lambda *args: self.dest), \
                mock.patch.object(smoke.Smoke, "run", lambda *args, **kwargs: "specs\n 0 failed"), \
                contextlib.redirect_stdout(io.StringIO()):
            smoke.all_packages_repo(fake, self.tmp)
        return {name: ok for name, ok, _ in fake.results}

    def test_a_scaffold_with_factory_passes_both_checks(self):
        got = self.results()
        self.assertTrue(got[self.FACTORY])
        self.assertTrue(got[self.WALLY])

    def test_a_packages_folder_fails_the_factory_check_but_is_never_wally_packages(self):
        (self.dest / "packages" / "ProcGen").mkdir(parents=True)  # the layout before the move to factory/
        with case_insensitive_paths():
            self.assertTrue((self.dest / "Packages").exists())  # what Windows and macOS answer
            got = self.results()
        self.assertFalse(got[self.FACTORY])
        self.assertTrue(got[self.WALLY])  # (dest / "Packages").exists() would call this a wally run

    def test_wally_output_fails_the_wally_check(self):
        (self.dest / "Packages").mkdir()
        self.assertFalse(self.results()[self.WALLY])
        (self.dest / "Packages").rmdir()
        (self.dest / "wally.lock").write_text("", encoding="utf-8")
        self.assertFalse(self.results()[self.WALLY])


class ExactNames(unittest.TestCase):
    def test_packages_is_not_found_through_the_factory_packages_folder(self):
        tmp = Path(tempfile.mkdtemp(prefix="smoke-names-"))
        try:
            (tmp / "packages" / "ProcGen").mkdir(parents=True)
            self.assertFalse(smoke.has_entry(tmp, "Packages"))
            with case_insensitive_paths():
                self.assertTrue((tmp / "Packages").exists())  # what Windows and macOS answer
                self.assertFalse(smoke.has_entry(tmp, "Packages"))
                self.assertTrue(smoke.has_entry(tmp, "packages"))
            (tmp / "wally.lock").write_text("", encoding="utf-8")
            self.assertTrue(smoke.has_entry(tmp, "wally.lock"))
            self.assertFalse(smoke.has_entry(tmp / "missing", "wally.lock"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
