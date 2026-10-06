"""tools/kit_tiers.py: tier headers, probe names and registration, engine evidence and report freshness."""
import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import kit_tiers  # noqa: E402

def engine_report(status, probes=None, route="studio-cli", **extra):
    """A reports/engine document shaped like tools/studio_run.py writes it (engine-report/1)."""
    doc = {"schema": "engine-report/1", "status": status, "source": {"route": route}, **extra}
    if probes is not None:
        doc["probes"] = probes
    return json.dumps(doc)


CONTRACT = "## 7. Probe contract\n\n- **Name.** `^[a-z][a-z0-9_]+$`, owner prefix: `foundation_` (Stage 0); `platform_` (G1); `kitsmoke_`, `perf_` (G9b).\n"


class KitTiersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="kit-tiers-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.write("docs/runtime-kits.md", CONTRACT)
        self.write("packages/GameKit/Signal.luau", "--!strict\n-- @tier T0\n-- Signal.\nreturn {}\n")
        self.write("packages/GameKit/SignalRoblox.luau", "--!strict\n-- @tier T3\n-- probe: platform_signal\n-- Adapter.\nreturn {}\n")
        self.write("fixtures/kits/shared/platform_probes.luau", "local probes = {}\nfunction probes.platform_signal(ctx) end\nreturn probes\n")
        self.write("packages/SceneKit/Vec.luau", "--!strict\n-- No tier: not a kit, so not listed.\nreturn {}\n")

    def write(self, rel, text):
        path = self.tmp / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_tool(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = kit_tiers.main([*args, "--root", str(self.tmp)])
        return code, out.getvalue()

    def report(self):
        return json.loads((self.tmp / "reports/kit-tiers.json").read_text())

    def test_prefixes_come_from_the_contract(self):
        self.assertEqual(kit_tiers.owner_prefixes(self.tmp), ["foundation_", "kitsmoke_", "perf_", "platform_"])
        self.assertIn("kitsmoke_", kit_tiers.owner_prefixes(ROOT))

    def test_good_tree_writes_a_report_and_check_passes(self):
        code, text = self.run_tool()
        self.assertEqual(code, 0, text)
        report = self.report()
        self.assertEqual(report["schema"], "kit-tiers/1")
        self.assertEqual(report["counts"]["by_tier"], {"T0": 1, "T3": 1})
        self.assertEqual([m["path"] for m in report["modules"]], ["packages/GameKit/Signal.luau", "packages/GameKit/SignalRoblox.luau"])
        probe = report["probes"][0]
        self.assertEqual((probe["name"], probe["evidence"], probe["runner"]), ("platform_signal", "PENDING", "tests/engine/kitsmoke_all.luau"))
        self.assertEqual(probe["registered_in"], ["fixtures/kits/shared/platform_probes.luau"])
        self.assertEqual(self.run_tool("--check")[0], 0)

    def test_check_flags_a_stale_report_without_writing(self):
        self.run_tool()
        self.write("packages/GameKit/Fsm.luau", "--!strict\n-- @tier T0\nreturn {}\n")
        code, text = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("STALE reports/kit-tiers.json", text)
        self.assertEqual(self.report()["counts"]["modules"], 2, "--check never rewrites the report")

    def test_header_problems(self):
        self.write("packages/UIKit/NoStrict.luau", "-- @tier T0\nreturn {}\n")
        self.write("packages/UIKit/NoTier.luau", "--!strict\n-- Nothing here.\nreturn {}\n")
        self.write("packages/UIKit/Two.luau", "--!strict\n-- @tier T0\n-- @tier T1\nreturn {}\n")
        self.write("packages/UIKit/Bad.luau", "--!strict\n-- @tier T9\nreturn {}\n")
        self.write("packages/UIKit/Loose.luau", "--!strict\n--   @tier   T1 maybe\nreturn {}\n")
        self.write("packages/UIKit/NoProbe.luau", "--!strict\n-- @tier T3\nreturn {}\n")
        self.write("packages/UIKit/Unprefixed.luau", "--!strict\n-- @tier T3\n-- probe: mystery_probe\nreturn {}\n")
        self.write("packages/UIKit/Unregistered.luau", "--!strict\n-- @tier T3\n-- probe: platform_missing\nreturn {}\n")
        self.write("packages/UIKit/Commented.luau", "--!strict\n-- @tier T3\n-- probe: platform_commented\nreturn {}\n")
        self.write("fixtures/kits/server/platform2_probes.luau", "-- platform_commented is only mentioned here\nreturn {}\n")
        self.write("packages/UIKit/T4.luau", "--!strict\n-- @tier T4\n-- Live only, no probe needed.\nreturn {}\n")
        code, text = self.run_tool()
        self.assertEqual(code, 1)
        problems = "\n".join(self.report()["problems"])
        for needle in (
            "NoStrict.luau: line 1 must be --!strict",
            "NoTier.luau: header needs a '-- @tier T0..T4' line",
            "Two.luau: more than one @tier line",
            "Bad.luau: tier T9 is not T0..T4",
            "Loose.luau: malformed tier line",
            "NoProbe.luau: a T3 module names its probe",
            "Unprefixed.luau: probe mystery_probe needs a lower_snake name with an owner prefix",
            "Unregistered.luau: probe platform_missing is not registered",
            "Commented.luau: probe platform_commented is not registered",
        ):
            self.assertIn(needle, problems)
        self.assertNotIn("T4.luau", problems)

    def test_non_kit_modules_with_a_tier_line_are_held_to_the_rules(self):
        self.write("packages/Diagnostics/Probe.luau", "--!strict\n-- @tier T3\nreturn {}\n")
        code, _ = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("packages/Diagnostics/Probe.luau: a T3 module names its probe", "\n".join(self.report()["problems"]))

    def test_engine_evidence_from_own_and_combined_reports(self):
        self.write("tests/engine/platform_signal.luau", "-- entry\n")
        self.write("reports/engine/platform_signal.json", json.dumps({"status": "PASS", "probes": ["platform_signal"]}))
        self.run_tool()
        probe = self.report()["probes"][0]
        self.assertEqual((probe["evidence"], probe["report"], probe["runner"]), ("PASS", "reports/engine/platform_signal.json", "tests/engine/platform_signal.luau"))
        self.assertEqual(self.report()["counts"]["t3_with_passing_probe"], 1)

        (self.tmp / "reports/engine/platform_signal.json").unlink()
        self.write("reports/engine/kitsmoke_all.json", json.dumps({
            "status": "FAIL", "probes": ["platform_signal", "other"],
            "failures": [{"probe": "other", "check": "x"}],
        }))
        self.run_tool()
        self.assertEqual(self.report()["probes"][0]["evidence"], "FAIL", "a failing combined run is not a pass for anyone")

        self.write("reports/engine/kitsmoke_all.json", json.dumps({"status": "PASS", "probes": ["platform_signal"]}))
        self.run_tool()
        self.assertEqual(self.report()["probes"][0]["evidence"], "PASS")

        self.write("reports/engine/kitsmoke_all.json", "{broken")
        self.run_tool()
        self.assertEqual(self.report()["probes"][0]["evidence"], "INVALID_REPORT")

    def test_blocked_external_is_not_a_pass(self):
        self.write("reports/engine/platform_signal.json", json.dumps({"status": "BLOCKED_EXTERNAL"}))
        self.run_tool()
        self.assertEqual(self.report()["probes"][0]["evidence"], "BLOCKED_EXTERNAL")
        self.assertEqual(self.report()["counts"]["t3_with_passing_probe"], 0)

    def test_every_named_probe_is_checked_and_must_pass(self):
        self.write("packages/GameKit/SignalRoblox.luau",
                   "--!strict\n-- @tier T3\n-- probe: platform_signal\n-- probe: platform_signal_wires\n-- Adapter.\nreturn {}\n")
        code, text = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("SignalRoblox.luau: probe platform_signal_wires is not registered", text,
                      "the second probe line is checked, not dropped")
        self.write("fixtures/kits/shared/platform_probes.luau",
                   "local probes = {}\nfunction probes.platform_signal(ctx) end\nfunction probes.platform_signal_wires(ctx) end\nreturn probes\n")
        self.assertEqual(self.run_tool()[0], 0)
        report = self.report()
        self.assertEqual(report["modules"][1]["probes"], ["platform_signal", "platform_signal_wires"])
        self.assertEqual([p["name"] for p in report["probes"]], ["platform_signal", "platform_signal_wires"], "one row per named probe")
        self.assertEqual(report["counts"]["probes"], 2)

        self.write("reports/engine/kitsmoke_all.json", engine_report("PASS", ["platform_signal"], route="from-output"))
        self.run_tool()
        report = self.report()
        self.assertEqual({p["name"]: p["evidence"] for p in report["probes"]}, {"platform_signal": "PASS", "platform_signal_wires": "PENDING"})
        self.assertEqual(report["counts"]["t3_with_passing_probe"], 0, "one passing probe of two does not prove the module")

        self.write("reports/engine/kitsmoke_all.json", engine_report("PASS", ["platform_signal", "platform_signal_wires"], route="from-output"))
        self.run_tool()
        self.assertEqual(self.report()["counts"]["t3_with_passing_probe"], 1)

    def test_a_probe_named_twice_is_a_problem(self):
        self.write("packages/GameKit/SignalRoblox.luau", "--!strict\n-- @tier T3\n-- probe: platform_signal\n-- probe: platform_signal\nreturn {}\n")
        code, text = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("SignalRoblox.luau: probe platform_signal is named twice", text)
        self.assertEqual(self.report()["modules"][1]["probes"], ["platform_signal"])

    def test_missing_report_fails_check(self):
        code, text = self.run_tool("--check")
        self.assertEqual(code, 1)
        self.assertIn("MISSING reports/kit-tiers.json", text)

    def test_repository_headers_follow_the_rules(self):
        report = kit_tiers.build(ROOT)
        self.assertEqual(report["problems"], [])
        self.assertIn("perf_capture", [p["name"] for p in report["probes"]])
        audio = next(m for m in report["modules"] if m["path"] == "packages/AVKit/AudioGraphRoblox.luau")
        self.assertEqual(audio["probes"], ["av_audiograph_wires", "av_audio_master_level"], "both header probes are tracked")
        for name in audio["probes"]:
            self.assertIn(audio["path"], next(p for p in report["probes"] if p["name"] == name)["modules"])
        self.assertTrue(all(p["evidence"] != "PASS" or p.get("report") for p in report["probes"]), "a pass always cites its report")


if __name__ == "__main__":
    unittest.main()
