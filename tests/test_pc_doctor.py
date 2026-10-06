"""tools/pc_doctor.py against a fake PATH of shell scripts: versions, PATH order, Node, telemetry (repo
configs and a fake Blender), the tools folder and the skills copy. Nothing on the real PC is read."""
import contextlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import pc_doctor  # noqa: E402
import user_skills  # noqa: E402

GOOD = {
    "rojo": "Rojo 7.7.0", "lune": "lune 0.10.5", "stylua": "stylua 2.5.2", "selene": "selene 0.31.0",
    "luau-lsp": "1.70.1", "darklua": "darklua 0.19.0", "wally": "wally 0.3.2", "node": "v22.4.0",
    "magick": "Version: ImageMagick 7.1.2-32 Q16-HDRI x86_64", "inkscape": "Inkscape 1.4.4 (abc, 2026-05-06)",
    "gltf-transform": "4.5.1", "krita": "", "audacity": "", "material_maker": "",
    "code": "JohnnyMorganz.luau-lsp@1.70.1\nJohnnyMorganz.stylua@1.7.2\nKampfkarren.selene-vscode@1.4.0\nanthropic.claude-code@2.1.290\nopenai.chatgpt@26.5908.31748",
}


@unittest.skipIf(os.name == "nt", "fake tools are POSIX shell scripts")
class PcDoctorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pc-doctor-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.home = self.tmp / "home"
        self.rokit = self.home / ".rokit" / "bin"
        self.aftman = self.home / ".aftman" / "bin"
        self.other = self.tmp / "bin"
        for folder in (self.rokit, self.aftman, self.other):
            folder.mkdir(parents=True)
        for name in ("rojo", "lune", "stylua", "selene", "luau-lsp", "darklua", "wally"):
            self.tool(self.rokit, name, GOOD[name])
        for name in ("node", "magick", "inkscape", "gltf-transform", "krita", "audacity", "material_maker", "code"):
            self.tool(self.other, name, GOOD[name])
        self.tool(self.aftman, "rojo", "aftman shim error", code=1)
        self.repo = self.tmp / "repo"
        (self.repo / ".codex").mkdir(parents=True)
        shutil.copy(ROOT / ".mcp.json", self.repo / ".mcp.json")
        shutil.copy(ROOT / ".codex" / "config.toml", self.repo / ".codex" / "config.toml")

    def tool(self, folder, name, output, code=0):
        path = folder / name
        assert "'" not in output
        # printf is a shell builtin: the fake PATH holds only the fake tools, so no cat.
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\nexit {code}\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def doctor(self, *path_dirs):
        env = {"PATH": os.pathsep.join(str(p) for p in path_dirs), "HOME": str(self.home)}
        return pc_doctor.Doctor(env=env, root=self.repo, timeout=20)

    def statuses(self, doctor):
        return {row["check"]: row["status"] for row in doctor.results}

    def test_good_pc_passes(self):
        doctor = self.doctor(self.rokit, self.aftman, self.other)
        args = type("A", (), {"tools_dir": None, "blender": None, "claude_skills": None, "codex_skills": None})()
        doctor.all(args)
        status = self.statuses(doctor)
        for check in ("toolchain:rojo", "toolchain:luau-lsp", "pc-tools:darklua", "pc-tools:wally", "path-order", "node",
                      "telemetry:server", "imagemagick", "inkscape", "gltf-transform", "krita", "audacity", "material-maker", "vscode-extensions"):
            self.assertEqual(status[check], "PASS", (check, doctor.results))
        self.assertEqual(status["telemetry:addon"], "UNCHECKED")
        self.assertEqual(status["tools-folder"], "UNCHECKED")
        self.assertNotIn("FAIL", status.values())
        self.assertNotIn(str(self.home), json.dumps(doctor.results), "the home folder is shown as ~")

    def test_wrong_version_and_aftman_first(self):
        self.tool(self.rokit, "rojo", "Rojo 7.6.0")
        doctor = self.doctor(self.aftman, self.rokit, self.other)
        doctor.tool_versions("toolchain", pc_doctor.TOOLCHAIN)
        doctor.path_order()
        status = self.statuses(doctor)
        self.assertEqual(status["toolchain:rojo"], "FAIL", "aftman's failing shim answers first")
        self.assertEqual(status["path-order"], "FAIL")
        doctor = self.doctor(self.rokit, self.other)
        doctor.tool_versions("toolchain", pc_doctor.TOOLCHAIN)
        self.assertIn("7.6.0", next(r["detail"] for r in doctor.results if r["check"] == "toolchain:rojo"))

    def test_aftman_first_with_its_rojo_shim_disabled(self):
        (self.aftman / "rojo").rename(self.aftman / "rojo.aftman-disabled")
        doctor = self.doctor(self.aftman, self.rokit, self.other)
        doctor.path_order()
        result = next(r for r in doctor.results if r["check"] == "path-order")
        self.assertEqual(result["status"], "FAIL", "another Aftman shim could still come first")
        self.assertIn("rojo resolves to Rokit for now", result["detail"])
        self.assertNotIn("runs Aftman's shim", result["detail"])

    def test_missing_tools_and_old_node(self):
        self.tool(self.other, "node", "v18.19.0")
        doctor = self.doctor(self.other)
        doctor.node()
        doctor.path_order()
        doctor.tool_versions("pc-tools", pc_doctor.PC_TOOLS, ["darklua", "wally"], missing_status="TODO")
        doctor.app("inkscape-missing", ["no-such-inkscape"], ["--version"], approved=False)
        doctor.app("krita-missing", ["no-such-krita"], None)
        status = self.statuses(doctor)
        self.assertEqual(status["node"], "FAIL")
        self.assertEqual(status["path-order"], "TODO")
        self.assertEqual(status["pc-tools:darklua"], "TODO")
        self.assertEqual(status["inkscape-missing"], "OPTIONAL")
        self.assertEqual(status["krita-missing"], "TODO")

    def test_telemetry_server_flags(self):
        doctor = self.doctor(self.other)
        doctor.telemetry()
        self.assertEqual(self.statuses(doctor)["telemetry:server"], "PASS")
        config = json.loads((self.repo / ".mcp.json").read_text())
        config["mcpServers"]["blender"]["env"]["DISABLE_TELEMETRY"] = "false"
        (self.repo / ".mcp.json").write_text(json.dumps(config))
        doctor = self.doctor(self.other)
        doctor.telemetry()
        row = doctor.results[0]
        self.assertEqual(row["status"], "FAIL")
        self.assertIn(".mcp.json blender DISABLE_TELEMETRY=false", row["detail"])

    def test_telemetry_addon_through_a_fake_blender(self):
        for value, expected in (("false", "PASS"), ("true", "FAIL")):
            blender = self.tool(self.other, "blender", 'PC_DOCTOR_BLENDER {"addons": ["mcp_for_blender"], "telemetry": {"mcp_for_blender.telemetry_consent": %s}}' % value)
            doctor = self.doctor(self.other)
            doctor.telemetry(str(blender))
            self.assertEqual(self.statuses(doctor)["telemetry:addon"], expected)
        blender = self.tool(self.other, "blender", 'PC_DOCTOR_BLENDER {"addons": [], "telemetry": {}}')
        doctor = self.doctor(self.other)
        doctor.telemetry(str(blender))
        self.assertEqual(self.statuses(doctor)["telemetry:addon"], "TODO")
        broken = self.tool(self.other, "blender-broken", "Segmentation fault", code=139)
        doctor = self.doctor(self.other)
        doctor.telemetry(str(broken))
        self.assertEqual(self.statuses(doctor)["telemetry:addon"], "FAIL")

    def test_blender_script_runs_on_bpy(self):
        try:
            import bpy  # noqa: F401
        except ImportError:
            self.skipTest("bpy is not installed")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(pc_doctor.BLENDER_SCRIPT, {})
        line = out.getvalue().strip().splitlines()[-1]
        self.assertTrue(line.startswith("PC_DOCTOR_BLENDER "))
        self.assertIn("telemetry", json.loads(line[len("PC_DOCTOR_BLENDER "):]))

    def test_tools_folder(self):
        folder = self.home / "roblox-tools"
        folder.mkdir()
        doctor = self.doctor(self.other)
        doctor.tools_folder(str(folder))
        self.assertEqual(doctor.results[-1]["status"], "TODO")
        shutil.copy(pc_doctor.PC_TOOLS, folder / "rokit.toml")
        doctor.tools_folder(str(folder))
        self.assertEqual(doctor.results[-1]["status"], "PASS")
        (folder / "rokit.toml").write_text((folder / "rokit.toml").read_text().replace("0.19.0", "0.18.0"))
        doctor.tools_folder(str(folder))
        self.assertEqual(doctor.results[-1]["status"], "FAIL")
        shutil.copy(pc_doctor.PC_TOOLS, folder / "rokit.toml")
        (folder / ".git").mkdir()
        doctor.tools_folder(str(folder))
        self.assertEqual(doctor.results[-1]["status"], "FAIL")

    def test_skills_copy(self):
        claude = self.home / ".claude" / "skills"
        doctor = self.doctor(self.other)
        doctor.skills()
        status = self.statuses(doctor)
        self.assertEqual(status["skills-copy:claude"], "UNCHECKED", "no default folder yet")
        with contextlib.redirect_stdout(io.StringIO()):
            user_skills.main(["--claude", str(claude), "--apply"])
        doctor = self.doctor(self.other)
        doctor.skills()
        self.assertEqual(self.statuses(doctor)["skills-copy:claude"], "PASS")
        (claude / "visual-qa" / "SKILL.md").write_text("edited\n")
        doctor = self.doctor(self.other)
        doctor.skills(claude=str(claude))
        row = next(r for r in doctor.results if r["check"] == "skills-copy:claude")
        self.assertEqual(row["status"], "TODO")
        self.assertIn("visual-qa edited", row["detail"])

    def test_pins_and_versions(self):
        self.assertEqual(pc_doctor.pins(pc_doctor.PC_TOOLS)["darklua"], "0.19.0")
        self.assertEqual(pc_doctor.pins(pc_doctor.TOOLCHAIN)["luau-lsp"], "1.70.1")
        for name in ("rojo", "lune", "stylua", "selene", "luau-lsp"):
            self.assertEqual(pc_doctor.pins(pc_doctor.PC_TOOLS)[name], pc_doctor.pins(pc_doctor.TOOLCHAIN)[name], name)
        self.assertEqual(pc_doctor.version_of("Version: ImageMagick 7.1.2-32 Q16"), "7.1.2")
        self.assertIsNone(pc_doctor.version_of("no digits"))


if __name__ == "__main__":
    unittest.main()
