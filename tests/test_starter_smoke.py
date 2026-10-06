"""Tests for tools/starter_smoke.py's skip contract and the factory gate step that runs it.

  python3 -m unittest tests/test_starter_smoke.py

A missing rojo, lune or stylua is a skip, never a pass: exit 3 (exit 1 with --strict), which
tools/check.py maps to SKIPPED for starter-smoke-full, and a SKIPPED starter-smoke-full blocks a
non-strict run unless --allow-skip names it. No scaffold is made here (no tool runs).
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


if __name__ == "__main__":
    unittest.main()
