"""tools/studio_run.py: recorded probe output, refusals, BLOCKED_EXTERNAL where Studio is absent, a
fake Studio executable for the CLI route, and path scrubbing. Studio itself never runs here."""
import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import studio_run  # noqa: E402

GOOD = """\
12:00:01.123  ENGINE_CHECK {"check":"env_valid","detail":[],"ok":true,"probe":"foundation_env_studio"}
12:00:01.124  ENGINE_CHECK {"check":"place_is_diagnostic","detail":{"reason":null},"ok":true,"probe":"foundation_env_studio"}
12:00:01.125  ENGINE_DONE {"checks":2,"errors":0,"failed":0,"ok":true,"passed":2,"probes":["foundation_env_studio"]}
"""
FAILED = """\
ENGINE_CHECK {"check":"env_valid","ok":true,"probe":"foundation_env_studio"}
ENGINE_CHECK {"check":"place_is_diagnostic","detail":{"reason":"published_game"},"ok":false,"probe":"foundation_env_studio"}
ENGINE_DONE {"checks":2,"errors":0,"failed":1,"ok":false,"passed":1,"probes":["foundation_env_studio"]}
"""
NO_DONE = 'ENGINE_CHECK {"check":"env_valid","ok":true,"probe":"foundation_env_studio"}\n'
LYING_DONE = """\
ENGINE_CHECK {"check":"a","ok":false,"probe":"foundation_env_studio"}
ENGINE_DONE {"checks":1,"errors":0,"failed":0,"ok":true,"passed":1,"probes":["foundation_env_studio"]}
"""
RAISED = """\
ENGINE_CHECK {"check":"error","detail":"oops","ok":false,"probe":"foundation_env_studio"}
ENGINE_DONE {"checks":1,"errors":1,"failed":1,"ok":false,"passed":0,"probes":["foundation_env_studio"]}
"""
TWO_RUNS = """\
ENGINE_CHECK {"check":"loaded server/kitsmoke_probes","ok":true,"probe":"kitsmoke_registries"}
ENGINE_DONE {"checks":1,"errors":0,"failed":0,"ok":true,"passed":1,"probes":["kitsmoke_registries"]}
ENGINE_CHECK {"check":"frames_sampled","ok":true,"probe":"perf_capture_client"}
ENGINE_DONE {"checks":1,"errors":0,"failed":0,"ok":true,"passed":1,"probes":["perf_capture_client"]}
"""

# The Lune runner's lines (tools/lune/kit_smoke.luau prints them; tests/golden/kit-smoke.json records them).
KIT_SMOKE_GOLDEN = json.loads((ROOT / "tests" / "golden" / "kit-smoke.json").read_text())
LUNE = "\n".join(KIT_SMOKE_GOLDEN["server"]["lines"] + KIT_SMOKE_GOLDEN["client"]["lines"]) + "\n"


class EvaluateTest(unittest.TestCase):
    def test_recorded_pass_with_log_prefixes(self):
        status, body = studio_run.evaluate("foundation_env_studio", GOOD)
        self.assertEqual(status, "PASS", body["problems"])
        self.assertEqual((body["runs"], body["checks"], body["passed"]), (1, 2, 2))

    def test_failed_check_fails(self):
        status, body = studio_run.evaluate("foundation_env_studio", FAILED)
        self.assertEqual(status, "FAIL")
        self.assertEqual(body["failures"], [{"probe": "foundation_env_studio", "check": "place_is_diagnostic", "detail": {"reason": "published_game"}}])

    def test_missing_engine_done_fails(self):
        status, body = studio_run.evaluate("foundation_env_studio", NO_DONE)
        self.assertEqual(status, "FAIL")
        self.assertTrue(any("did not finish" in p for p in body["problems"]), body["problems"])

    def test_done_line_must_agree_with_the_checks(self):
        status, body = studio_run.evaluate("foundation_env_studio", LYING_DONE)
        self.assertEqual(status, "FAIL")
        joined = "; ".join(body["problems"])
        self.assertIn("ENGINE_DONE passed=1 but the check lines give 0", joined)
        self.assertIn("ENGINE_DONE ok=True but the checks say False", joined)

    def test_raised_probe_counts_as_error(self):
        status, body = studio_run.evaluate("foundation_env_studio", RAISED)
        self.assertEqual(status, "FAIL")
        self.assertEqual(body["problems"], [], "the done line is consistent; the failure is the error check")

    def test_empty_output_and_wrong_probe_fail(self):
        self.assertEqual(studio_run.evaluate("foundation_env_studio", "Studio started\n")[0], "FAIL")
        status, body = studio_run.evaluate("perf_capture", GOOD)
        self.assertEqual(status, "FAIL")
        self.assertTrue(any("did not run" in p for p in body["problems"]))

    def test_aggregate_probe_accepts_several_runs(self):
        status, body = studio_run.evaluate("kitsmoke_all", TWO_RUNS)
        self.assertEqual(status, "PASS", body["problems"])
        self.assertEqual(body["probes"], ["kitsmoke_registries", "perf_capture_client"])

    def test_lune_output_is_refused(self):
        self.assertIn('"runtime":"lune"}', LUNE, "FakeKitSmoke marks every ENGINE_DONE line it emits")
        # The lines parse and pass on their own; only the mark tells them apart from a play-session capture.
        self.assertEqual(studio_run.evaluate("kitsmoke_all", LUNE)[0], "PASS")
        with self.assertRaises(studio_run.Refused) as caught:
            studio_run.refuse_lune_output(LUNE, "out.txt")
        self.assertIn("2 ENGINE_DONE line(s) say runtime lune", str(caught.exception))
        studio_run.refuse_lune_output(GOOD, "out.txt")
        studio_run.refuse_lune_output(TWO_RUNS, "out.txt")

    def test_bad_json_is_a_problem(self):
        status, body = studio_run.evaluate("foundation_env_studio", GOOD + "ENGINE_CHECK {not json}\n")
        self.assertEqual(status, "FAIL")
        self.assertTrue(any("invalid JSON" in p for p in body["problems"]))


class RefusalTest(unittest.TestCase):
    def run_tool(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = studio_run.main(list(argv))
        return code, out.getvalue()

    def test_published_targets_are_refused_in_any_spelling(self):
        for argv in (["--probe", "foundation_env_studio", "--placeId", "1"], ["--probe", "x", "--PLACEID=1"],
                     ["--universeId", "2"], ["EditPlace"], ["--probe", "foundation_env_studio", "--assetId", "3"]):
            code, text = self.run_tool(*argv)
            self.assertEqual(code, 2, argv)
            self.assertIn("REFUSED", text)
        with self.assertRaises(studio_run.Refused):
            studio_run.refuse_published_targets(["--task", "TryAsset"])

    def test_bad_names_and_places_are_refused(self):
        self.assertEqual(self.run_tool("--probe", "../escape")[0], 2)
        self.assertEqual(self.run_tool("--probe", "no_such_probe_here")[0], 2)
        with self.assertRaises(studio_run.Refused):
            studio_run.place_file("/tmp/elsewhere.rbxl")
        with self.assertRaises(studio_run.Refused):
            studio_run.place_file("build/kits.txt")
        self.assertEqual(studio_run.place_file("build/kits.rbxl"), (ROOT / "build" / "kits.rbxl").resolve())

    def test_command_line_is_the_documented_one(self):
        cmd = studio_run.studio_command("Studio", "/p/place.rbxl", "/p/probe.luau", "/p/out.log")
        self.assertEqual(cmd[1:], ["--task", "RunScript", "--localPlaceFile", "/p/place.rbxl", "--runScriptFile", "/p/probe.luau",
                                   "--outputFile", "/p/out.log", "--quitAfterExecution"])

    def test_list_names_the_entries(self):
        code, text = self.run_tool("--list")
        self.assertEqual(code, 0)
        for name in ("foundation_env_studio", "kitsmoke_all", "perf_capture"):
            self.assertIn(name, text.split())


class RouteTest(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="studio-run-test-", dir=ROOT / "build"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.reports = self.tmp / "reports"
        self.blocked = self.tmp / "blocked"

    def run_tool(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = studio_run.main([*argv, "--report-dir", str(self.reports), "--blocked-dir", str(self.blocked)])
        return code, out.getvalue()

    def test_linux_without_studio_is_blocked_external(self):
        saved = os.environ.pop("ROBLOX_STUDIO", None)
        try:
            code, text = self.run_tool("--probe", "foundation_env_studio", "--system", "Linux")
        finally:
            if saved is not None:
                os.environ["ROBLOX_STUDIO"] = saved
        self.assertEqual(code, 3)
        self.assertIn("BLOCKED_EXTERNAL", text)
        report = json.loads((self.blocked / "foundation_env_studio.json").read_text())
        self.assertEqual(report["status"], "BLOCKED_EXTERNAL")
        self.assertFalse(self.reports.exists(), "nothing under the reports folder")

    def test_from_output_writes_a_scrubbed_report(self):
        output = self.tmp / "console.txt"
        output.write_text(GOOD.replace('"detail":[]', f'"detail":"{ROOT}/packages/GameKit/Env.luau and C:\\\\Users\\\\someone\\\\x"'))
        code, text = self.run_tool("--probe", "foundation_env_studio", "--from-output", str(output))
        self.assertEqual(code, 0, text)
        raw = (self.reports / "foundation_env_studio.json").read_text()
        report = json.loads(raw)
        self.assertEqual((report["schema"], report["status"], report["source"]["route"]), ("engine-report/1", "PASS", "from-output"))
        self.assertEqual(len(report["source"]["output_sha256"]), 64)
        self.assertNotIn(str(ROOT), raw)
        self.assertNotIn("someone", raw)
        self.assertIn("<repo>/packages/GameKit/Env.luau", raw)

    def test_from_output_refuses_lune_output(self):
        # Before: Lune output recorded as a PASS engine-report/1 under reports/engine, which kit_tiers then
        # counted as Studio evidence for the kitsmoke_ and perf_ probes.
        output = self.tmp / "kit_smoke.txt"
        output.write_text("REGISTRY server/kitsmoke_probes kitsmoke_debug_commands\n" + LUNE + "GOLDEN kit-smoke: matches\n")
        code, text = self.run_tool("--probe", "kitsmoke_all", "--from-output", str(output))
        self.assertEqual(code, 2, text)
        self.assertIn("REFUSED", text)
        self.assertIn("runtime lune", text)
        self.assertFalse(self.reports.exists(), "nothing is recorded under the reports folder")

    @unittest.skipIf(shutil.which("lune") is None, "lune not installed")
    def test_lune_kit_smoke_run_is_refused(self):
        proc = subprocess.run(["lune", "run", "tools/lune/kit_smoke.luau"], cwd=ROOT, capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stdout[-2000:] + proc.stderr[-2000:])
        output = self.tmp / "kit_smoke.txt"
        output.write_text(proc.stdout)
        code, text = self.run_tool("--probe", "kitsmoke_all", "--from-output", str(output))
        self.assertEqual(code, 2, text)
        self.assertFalse(self.reports.exists())

    def test_fake_studio_cli_route(self):
        fake = self.tmp / "FakeStudio"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "args = sys.argv[1:]\n"
            "out = args[args.index('--outputFile') + 1]\n"
            "assert args[args.index('--task') + 1] == 'RunScript'\n"
            f"open(out, 'w').write({GOOD!r})\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        place = self.tmp / "kits.rbxl"
        place.write_bytes(b"<roblox/>")
        code, text = self.run_tool("--probe", "foundation_env_studio", "--studio", str(fake), "--place", str(place))
        self.assertEqual(code, 0, text)
        report = json.loads((self.reports / "foundation_env_studio.json").read_text())
        self.assertEqual(report["source"]["route"], "studio-cli")
        self.assertEqual(report["source"]["studio_exit"], "exit 0")
        self.assertTrue(report["source"]["place"].startswith("build/"))
        self.assertEqual(len(report["source"]["place_sha256"]), 64)

    def test_fake_studio_printing_lune_output_is_refused(self):
        fake = self.tmp / "FakeStudio"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "args = sys.argv[1:]\n"
            "out = args[args.index('--outputFile') + 1]\n"
            f"open(out, 'w').write({LUNE!r})\n"
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        place = self.tmp / "kits.rbxl"
        place.write_bytes(b"<roblox/>")
        code, text = self.run_tool("--probe", "kitsmoke_all", "--studio", str(fake), "--place", str(place))
        self.assertEqual(code, 2, text)
        self.assertIn("REFUSED the Studio run's output", text)
        self.assertFalse(self.reports.exists())

    def test_find_studio_order(self):
        fake = self.tmp / "Studio.exe"
        fake.write_text("")
        self.assertEqual(studio_run.find_studio(str(fake), env={}, system="Linux"), str(fake))
        self.assertEqual(studio_run.find_studio(None, env={"ROBLOX_STUDIO": str(fake)}, system="Linux"), str(fake))
        self.assertIsNone(studio_run.find_studio(None, env={}, system="Linux"))
        versions = self.tmp / "Roblox" / "Versions" / "version-abc"
        versions.mkdir(parents=True)
        (versions / "RobloxStudioBeta.exe").write_text("")
        found = studio_run.find_studio(None, env={"LOCALAPPDATA": str(self.tmp)}, system="Windows")
        self.assertTrue(found.endswith("RobloxStudioBeta.exe"))


class ScrubTest(unittest.TestCase):
    def test_scrub_paths_everywhere(self):
        secrets = [("/work/repo", "<repo>"), ("/home/dev", "<home>")]
        value = {"a": ["/work/repo/x.luau", "/home/dev/.cache"], "b": "C:\\Users\\Someone\\AppData", "c": 3, "d": "/home/other/file"}
        self.assertEqual(studio_run.scrub(value, secrets), {"a": ["<repo>/x.luau", "<home>/.cache"], "b": "<home>\\AppData", "c": 3, "d": "<home>/file"})


if __name__ == "__main__":
    unittest.main()
