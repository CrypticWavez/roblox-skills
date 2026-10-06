"""Tests for the project starter (tools/new_project.py).

  python3 -m unittest tests/test_new_project.py

Scaffolds into temporary directories outside this repository. Covers package classes and the Rojo
layout (leaf copies for kits, no FilteringEnabled), the tier parse into starter.json, dependency
bundles (exact pins, licence notices, wally never run), --update (user files preserved; edited
packages, skills, hooks and managed files refused; stale ones refreshed; starter/1 layout migrated)
and the refusals.
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import new_project as np  # noqa: E402


def quiet(fn, *args):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        result = fn(*args)
    return result, out.getvalue()


def tree_node(project, *names):
    node = project["tree"]
    for name in names:
        node = node.get(name) if isinstance(node, dict) else None
    return node


class Scaffold(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="new-project-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def scaffold(self, name="Game", packages=None, bundles=()):
        dest = self.tmp / name
        code, out = quiet(np.scaffold, dest, name, packages or np.DEFAULT_PACKAGES, list(bundles))
        self.assertEqual(code, 0, out)
        return dest, out

    def read_json(self, path):
        return json.loads(Path(path).read_text(encoding="utf-8"))


class PackageClasses(Scaffold):
    def test_every_factory_package_has_a_class_and_a_home(self):
        self.assertEqual(np.PACKAGE_CLASSES["authoring"], ["SceneKit", "ProcGen", "Pipeline"])
        self.assertEqual(np.PACKAGE_CLASSES["kits"], ["GameKit", "UIKit", "Feel", "Cinematics", "AVKit"])
        self.assertEqual(np.PACKAGE_CLASSES["legacy"], ["Runtime", "Creator", "Diagnostics"])
        for pkg in np.package_names():
            self.assertIn(pkg, np.CLASS_OF, f"packages/{pkg} has no class")
        self.assertEqual(np.ROJO_HOME["authoring"], ("ServerStorage", "Authoring"))
        self.assertEqual(np.ROJO_HOME["kits"], ("ReplicatedStorage", "Kits"))
        self.assertEqual(np.DEFAULT_PACKAGES, ["SceneKit", "ProcGen", "Pipeline"])

    def test_default_tree_layout(self):
        dest, out = self.scaffold()
        project = self.read_json(dest / "default.project.json")
        text = (dest / "default.project.json").read_text(encoding="utf-8")
        self.assertNotIn("FilteringEnabled", text)
        for path in [("ReplicatedFirst", "Loading"), ("ReplicatedStorage", "Shared"), ("ServerScriptService", "Server"),
                     ("StarterPlayer", "StarterPlayerScripts", "Client"), ("StarterGui",), ("ServerStorage", "Assets"),
                     ("ServerStorage", "ServerPackages"), ("ReplicatedStorage", "Packages")]:
            self.assertIsInstance(tree_node(project, *path), dict, ".".join(path))
        authoring = tree_node(project, "ServerStorage", "Authoring")
        self.assertEqual(sorted(k for k in authoring if not k.startswith("$")), ["Pipeline", "ProcGen", "SceneKit"])
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Kits"))
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Workbench"))
        self.assertEqual(tree_node(project, "ServerStorage", "ServerPackages", "$path"), {"optional": "ServerPackages"})
        for rel in ["src/shared/Boot.luau", "src/shared/Config.luau", "src/shared/KitLoader.luau", "src/server/init.server.luau",
                    "src/server/Phases.luau", "src/client/init.client.luau", "src/client/Phases.luau",
                    "src/first/Loading.client.luau", "src/localization/strings.csv", "tests/boot.spec.luau",
                    "tests/layout.spec.luau", "tests/packages.spec.luau", "tools/check.py", "tools/release_check.py",
                    "tools/production.py", "tools/plan_issues.py", "production/brief.json", "production/pipeline.json",
                    "docs/production-plan.md", "docs/release-runbook.md", "release/release.json",
                    ".github/ISSUE_TEMPLATE/system.yml", ".github/ISSUE_TEMPLATE/playtest.yml", ".gitignore",
                    ".agents/skills/roblox-production-pipeline/SKILL.md", ".claude/skills/roblox-production-pipeline/SKILL.md"]:
            self.assertTrue((dest / rel).is_file(), rel)
        brief = self.read_json(dest / "production" / "brief.json")
        self.assertEqual(brief["name"], "Game")
        self.assertTrue(all(v == "TBD" or k in ("schema", "name", "references", "open_questions") or isinstance(v, dict)
                            for k, v in brief.items()))
        self.assertIn("| Workspace.AuthorityMode | engine.authority_mode | TBD |", (dest / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertNotIn("{{", (dest / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertIn("Packages/", (dest / ".gitignore").read_text(encoding="utf-8"))

    def test_kits_get_leaf_copies_and_dependencies(self):
        dest, out = self.scaffold(packages=["GameKit"])
        project = self.read_json(dest / "default.project.json")
        kits = tree_node(project, "ReplicatedStorage", "Kits")
        self.assertEqual(kits["GameKit"], {"$path": "packages/GameKit"})
        for leaf in ("Rng", "Grid", "Graph"):
            self.assertEqual(kits["ProcGen"][leaf], {"$path": f"packages/ProcGen/{leaf}.luau"})
        self.assertIn("ProcGen", tree_node(project, "ServerStorage", "Authoring"))  # added as a dependency
        self.assertIn("added as dependencies: ProcGen", out)
        starter = self.read_json(dest / "starter.json")
        self.assertEqual(starter["packages"]["GameKit"]["class"], "kits")
        self.assertEqual(starter["packages"]["ProcGen"]["class"], "authoring")

    def test_scaffolded_rojo_project_builds(self):
        if shutil.which("rojo") is None:
            self.skipTest("rojo not installed")
        dest, _ = self.scaffold(packages=np.package_names())
        (dest / "build").mkdir()
        proc = subprocess.run(["rojo", "build", "default.project.json", "-o", "build/t.rbxl"], cwd=dest, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)


class Tiers(Scaffold):
    def test_module_header_parse(self):
        self.assertEqual(np.module_header("--!strict\n-- @tier T3\n-- probe: foundation_x\n-- What it is.\nlocal M = {}"),
                         ("T3", "foundation_x"))
        self.assertEqual(np.module_header("--!strict\n-- @tier T0\n-- Text.\n"), ("T0", None))
        self.assertEqual(np.module_header("--!strict\n-- No tier here.\nlocal x = 1\n-- @tier T1\n"), (None, None))
        self.assertEqual(np.module_header("local x = 1\n"), (None, None))

    def test_starter_json_records_modules_tiers_and_pending_probes(self):
        dest, _ = self.scaffold(packages=["GameKit"])
        starter = self.read_json(dest / "starter.json")
        self.assertEqual(starter["schema"], "starter/2")
        modules = starter["modules"]
        self.assertEqual(modules["GameKit/Check"], {"class": "kits", "tier": "T0", "lune": True})
        env = modules["GameKit/EnvRoblox"]
        self.assertEqual((env["tier"], env["lune"], env["probe"]), ("T3", False, "foundation_env_studio"))
        self.assertIn({"probe": "foundation_env_studio", "module": "GameKit/EnvRoblox"}, starter["pending_probes"])
        self.assertEqual(sum(starter["tiers"].values()), len(modules))
        self.assertTrue(all(m["lune"] for name, m in modules.items() if name.startswith("ProcGen/")))
        for rel, digest in starter["managed"].items():
            self.assertEqual(np.file_sha(dest / rel), digest, rel)


class DependencyBundles(Scaffold):
    def run_cli(self, *args, path=None):
        env = dict(os.environ)
        if path:
            env["PATH"] = path + os.pathsep + env["PATH"]
        return subprocess.run([sys.executable, str(ROOT / "tools" / "new_project.py"), *args], capture_output=True, text=True, env=env)

    def test_deps_write_exact_pins_and_never_run_wally(self):
        fake_bin = self.tmp / "bin"
        fake_bin.mkdir()
        marker = self.tmp / "wally-was-run"
        for tool in ("wally", "rokit"):
            script = fake_bin / tool
            script.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
            script.chmod(script.stat().st_mode | stat.S_IEXEC)
        dest = self.tmp / "WithDeps"
        proc = self.run_cli("--name", "scratch", "--out", str(dest), "--deps", "persistence", "studio-tests", path=str(fake_bin))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(marker.exists(), "the starter ran wally or rokit")
        self.assertFalse((dest / "wally.lock").exists())
        self.assertFalse((dest / "Packages").exists())
        wally = (dest / "wally.toml").read_text(encoding="utf-8")
        self.assertIn('ProfileStore = "lm-loleris/profilestore@=1.0.3"', wally)
        self.assertIn('Jest = "jsdotlua/jest@=3.10.0"', wally)
        self.assertIn("private = true", wally)
        self.assertLess(wally.index("[server-dependencies]"), wally.index("ProfileStore"))
        self.assertLess(wally.index("[dev-dependencies]"), wally.index("Jest ="))
        notices = (dest / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn("Apache-2.0", notices)
        self.assertIn("Apache License, Version 2.0", notices)
        self.assertIn('wally = "UpliftGames/wally@0.3.2"', (dest / "rokit.toml").read_text(encoding="utf-8"))
        studio = json.loads((dest / "studio-tests.project.json").read_text(encoding="utf-8"))
        self.assertEqual(studio["tree"]["ServerStorage"]["DevPackages"], {"$path": {"optional": "DevPackages"}})
        self.assertIn("wally install", proc.stdout)
        starter = json.loads((dest / "starter.json").read_text(encoding="utf-8"))
        self.assertEqual(starter["deps"]["bundles"], ["persistence", "studio-tests"])

    def test_unknown_bundle_is_refused(self):
        proc = self.run_cli(str(self.tmp / "X"), "--deps", "everything")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unknown dependency bundle", proc.stderr)
        self.assertFalse((self.tmp / "X").exists())

    def test_merge_wally_refuses_a_changed_pin_without_force(self):
        deps = np.load_deps()
        text = np.wally_text("g", ["lm-loleris/profilestore"], deps).replace("@=1.0.3", "@=1.0.2")
        with self.assertRaises(np.Refused):
            np.merge_wally(text, ["lm-loleris/profilestore"], deps, force=False)
        self.assertIn("@=1.0.3", np.merge_wally(text, ["lm-loleris/profilestore"], deps, force=True))

    def test_rokit_merge_keeps_the_games_own_tools(self):
        existing = '[tools]\nrojo = "rojo-rbx/rojo@7.0.0"\nmytool = "someone/mytool@1.2.3"\n'
        merged = np.rokit_text(existing, {"rojo": "rojo-rbx/rojo@7.7.0", "wally": "UpliftGames/wally@0.3.2"})
        self.assertIn('rojo = "rojo-rbx/rojo@7.7.0"', merged)
        self.assertIn('mytool = "someone/mytool@1.2.3"', merged)
        self.assertIn('wally = "UpliftGames/wally@0.3.2"', merged)


class Update(Scaffold):
    def update(self, dest, packages=None, bundles=(), force=False):
        return quiet(np.update, dest, packages, list(bundles), force)

    def test_update_is_a_noop_on_a_fresh_copy_and_preserves_user_files(self):
        dest, _ = self.scaffold()
        config = dest / "src" / "shared" / "Config.luau"
        config.write_text(config.read_text(encoding="utf-8") + "-- game edit\n", encoding="utf-8")
        brief = dest / "production" / "brief.json"
        brief.write_text(brief.read_text(encoding="utf-8").replace('"pitch": "TBD"', '"pitch": "owner text"'), encoding="utf-8")
        before = (dest / "starter.json").read_text(encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0)
        self.assertIn("unchanged", out)
        self.assertIn("already up to date", out)
        self.assertTrue(config.read_text(encoding="utf-8").endswith("-- game edit\n"))
        self.assertIn('"pitch": "owner text"', brief.read_text(encoding="utf-8"))
        self.assertEqual((dest / "starter.json").read_text(encoding="utf-8"), before)

    def test_update_refuses_local_edits_of_factory_files(self):
        for rel, why in [("packages/ProcGen/Rng.luau", "edited here"),
                         (".agents/skills/roblox-release-pass/SKILL.md", "skills edited here"),
                         ("tools/hooks/lib.mjs", "managed files edited here"),
                         ("tools/release_check.py", "managed files edited here")]:
            with self.subTest(rel=rel):
                dest, _ = self.scaffold(name="G" + str(abs(hash(rel)) % 10000))
                target = dest / rel
                original = target.read_text(encoding="utf-8")
                target.write_text(original + "\n// local edit\n" if rel.endswith(".mjs") else original + "\n-- local edit\n", encoding="utf-8")
                with self.assertRaises(np.Refused) as ctx:
                    self.update(dest)
                self.assertIn(why, str(ctx.exception))
                code, _ = self.update(dest, force=True)
                self.assertEqual(code, 0)
                self.assertEqual(target.read_text(encoding="utf-8"), original)

    def test_update_refreshes_stale_managed_files_skills_and_hooks(self):
        dest, _ = self.scaffold()
        starter = self.read_json(dest / "starter.json")
        stale = {"tools/check.py": "# old gate\n", "tools/hooks/guard_bash.mjs": "// old guard\n"}
        for rel, text in stale.items():
            (dest / rel).write_text(text, encoding="utf-8")
            starter["managed"][rel] = np.sha(text.encode("utf-8"))
        skill = dest / ".agents" / "skills" / "visual-qa" / "SKILL.md"
        skill.write_text("old skill\n", encoding="utf-8")
        starter["skills"]["visual-qa"]["sha256"] = np.tree_hash(skill.parent)[0]
        (dest / "starter.json").write_text(json.dumps(starter, indent=2) + "\n", encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("skills: refreshed visual-qa", out)
        for rel in stale:
            self.assertEqual((dest / rel).read_bytes(), (ROOT / ("templates/starter/" if rel == "tools/check.py" else "") / rel).read_bytes()
                             .replace(b"\r\n", b"\n"))
        self.assertEqual(skill.read_bytes(), (ROOT / ".agents/skills/visual-qa/SKILL.md").read_bytes())
        self.assertEqual((dest / ".claude/skills/visual-qa/SKILL.md").read_bytes(), skill.read_bytes())
        fresh = self.read_json(dest / "starter.json")
        self.assertEqual(fresh["managed"]["tools/check.py"], np.file_sha(dest / "tools/check.py"))
        self.assertIn("updated", fresh)

    def test_update_adds_packages_and_bundles(self):
        dest, _ = self.scaffold()
        code, out = self.update(dest, packages=["SceneKit", "ProcGen", "Pipeline", "GameKit"], bundles=["persistence"])
        self.assertEqual(code, 0, out)
        project = self.read_json(dest / "default.project.json")
        self.assertIn("GameKit", tree_node(project, "ReplicatedStorage", "Kits"))
        self.assertIn("lm-loleris/profilestore@=1.0.3", (dest / "wally.toml").read_text(encoding="utf-8"))
        starter = self.read_json(dest / "starter.json")
        self.assertEqual(starter["deps"]["bundles"], ["persistence"])
        self.assertIn("GameKit/Check", starter["modules"])

    def test_update_migrates_a_starter1_layout(self):
        dest, _ = self.scaffold()
        project = self.read_json(dest / "default.project.json")
        del project["tree"]["ServerStorage"]["Authoring"]
        project["tree"]["ReplicatedStorage"]["Workbench"] = {"$path": "packages"}
        (dest / "default.project.json").write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        starter = self.read_json(dest / "starter.json")
        old = {"schema": "starter/1", "name": starter["name"], "created": starter["created"], "factory": starter["factory"],
               "packages": {k: {"sha256": v["sha256"], "files": v["files"]} for k, v in starter["packages"].items()},
               "skills": sorted(starter["skills"]), "smoke": starter.get("smoke")}
        (dest / "starter.json").write_text(json.dumps(old, indent=2) + "\n", encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("removed ReplicatedStorage.Workbench", out)
        project = self.read_json(dest / "default.project.json")
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Workbench"))
        self.assertIn("SceneKit", tree_node(project, "ServerStorage", "Authoring"))
        self.assertEqual(self.read_json(dest / "starter.json")["schema"], "starter/2")


def load_starter_tool(name):
    """A module from templates/starter/tools (the game repo's copy is byte-identical; functions take the repo root)."""
    tools = ROOT / "templates" / "starter" / "tools"
    if str(tools) not in sys.path:
        sys.path.insert(0, str(tools))
    spec = importlib.util.spec_from_file_location(f"starter_{name}", tools / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GameRepoGateSteps(Scaffold):
    """The game gate's own steps (brief, deps, skills-packages) on scaffolded repos."""

    @classmethod
    def setUpClass(cls):
        cls.check = load_starter_tool("check")

    def starter(self, dest):
        return self.read_json(dest / "starter.json")

    def set_stage(self, dest, stage):
        path = dest / "production" / "pipeline.json"
        pipeline = self.read_json(path)
        pipeline["current"] = stage
        path.write_text(json.dumps(pipeline, indent=2) + "\n", encoding="utf-8")

    def test_brief_step_is_stage_aware_and_owner_gated(self):
        dest, _ = self.scaffold()
        self.assertEqual(self.check.brief_problems(dest, self.starter(dest))[0], [])
        self.set_stage(dest, "greybox")
        problems = "\n".join(self.check.brief_problems(dest, self.starter(dest))[0])
        self.assertIn("pitch: still TBD", problems)
        self.assertIn("concept.approved", problems)
        self.assertIn("core-loop.md: Status is TBD", problems)
        # Decide the concept fields (synthetic values), mirror them in AGENTS.md, finish the doc, record the owner gate.
        decided = {"pitch": "Synthetic pitch.", "pillars": ["one"], "genre": {"primary": "Utility & Other", "subgenre": None},
                   "theme_and_setting": "Synthetic.", "core_loop": "Synthetic.", "audience": {"age_target": "Synthetic.", "maturity_label": "Minimal"},
                   "devices": ["computer"], "players_per_server": {"max": 2, "preferred": 2}, "session_minutes": 5,
                   "locales": {"source": "en-us", "targets": []}}
        brief = self.read_json(dest / "production" / "brief.json")
        brief.update(decided)
        (dest / "production" / "brief.json").write_text(json.dumps(brief, indent=2) + "\n", encoding="utf-8")
        agents = (dest / "AGENTS.md").read_text(encoding="utf-8")
        for key, value in decided.items():
            cell = value if isinstance(value, str) else ("5" if key == "session_minutes" else "decided (see production/brief.json)")
            agents = re.sub(rf"(\| {key} \|) TBD \|", lambda m: f"{m.group(1)} {cell} |", agents)
        (dest / "AGENTS.md").write_text(agents, encoding="utf-8")
        doc = dest / "docs" / "design" / "core-loop.md"
        doc.write_text(doc.read_text(encoding="utf-8").replace("Status: TBD", "Status: draft"), encoding="utf-8")
        (dest / "release" / "owner-test.json").write_text(json.dumps({"schema": "release-owner/1", "records": [
            {"id": "concept.approved", "date": "2026-10-06", "note": "synthetic"}]}), encoding="utf-8")
        self.assertEqual(self.check.brief_problems(dest, self.starter(dest))[0], [])
        self.set_stage(dest, "alpha")  # from alpha on every required field is decided, and greybox gates need records
        problems = "\n".join(self.check.brief_problems(dest, self.starter(dest))[0])
        self.assertIn("economy: still TBD", problems)
        self.assertIn("greybox.playtest", problems)

    def test_brief_step_catches_agents_md_drift_and_bad_values(self):
        dest, _ = self.scaffold()
        brief = self.read_json(dest / "production" / "brief.json")
        brief["pitch"] = "Synthetic pitch."
        brief["genre"] = {"primary": "Not A Genre", "subgenre": "TBD"}
        (dest / "production" / "brief.json").write_text(json.dumps(brief, indent=2) + "\n", encoding="utf-8")
        problems = "\n".join(self.check.brief_problems(dest, self.starter(dest))[0])
        self.assertIn("pitch is TBD here but decided in production/brief.json", problems)
        self.assertIn("not one of Roblox's 17 genres", problems)

    def test_deps_step_enforces_exact_allowlisted_pins_and_the_lockfile(self):
        dest, _ = self.scaffold(bundles=["persistence"])
        problems = self.check.deps_problems(dest)[0]
        self.assertTrue(any("wally.lock missing" in p for p in problems), problems)
        lock = dest / "wally.lock"
        lock.write_text('[[package]]\nname = "local/game"\nversion = "0.1.0"\n\n'
                        '[[package]]\nname = "lm-loleris/profilestore"\nversion = "1.0.3"\n', encoding="utf-8")
        self.assertEqual(self.check.deps_problems(dest)[0], [])
        lock.write_text(lock.read_text(encoding="utf-8") + '\n[[package]]\nname = "someone/unlisted"\nversion = "1.0.0"\n', encoding="utf-8")
        self.assertTrue(any("someone/unlisted" in p for p in self.check.deps_problems(dest)[0]))
        wally = dest / "wally.toml"
        wally.write_text(wally.read_text(encoding="utf-8").replace("@=1.0.3", "@1.0.3"), encoding="utf-8")
        self.assertTrue(any("exact pin" in p for p in self.check.deps_problems(dest)[0]))

    def test_deps_step_passes_without_wally(self):
        dest, _ = self.scaffold()
        self.assertEqual(self.check.deps_problems(dest)[0], [])

    def test_skills_packages_step(self):
        dest, _ = self.scaffold()
        self.assertEqual(self.check.skills_packages_problems(dest, self.starter(dest))[0], [])
        rng = dest / "packages" / "ProcGen" / "Rng.luau"
        rng.write_text(rng.read_text(encoding="utf-8") + "-- local patch\n", encoding="utf-8")
        self.assertTrue(any("packages/ProcGen differs" in p for p in self.check.skills_packages_problems(dest, self.starter(dest))[0]))
        starter = self.starter(dest)
        starter["patched"] = {"packages/ProcGen": "synthetic reason"}
        problems, notes = self.check.skills_packages_problems(dest, starter)
        self.assertEqual(problems, [])
        self.assertTrue(any("patched here" in n for n in notes))
        skill = dest / ".agents" / "skills" / "visual-qa" / "SKILL.md"
        skill.write_text(skill.read_text(encoding="utf-8") + "\nSee ProcGen/NoSuchModule.\n", encoding="utf-8")
        starter["patched"]["skills/visual-qa"] = "synthetic"
        problems, _ = self.check.skills_packages_problems(dest, starter)
        self.assertTrue(any("ProcGen/NoSuchModule" in p for p in problems), problems)


class Refusals(Scaffold):
    def test_refusals(self):
        with self.assertRaises(np.Refused):
            np.check_new_dest(ROOT / "build" / "inside")
        busy = self.tmp / "busy"
        busy.mkdir()
        (busy / "file.txt").write_text("x")
        with self.assertRaises(np.Refused):
            np.check_new_dest(busy)
        with self.assertRaises(np.Refused):
            np.with_dependencies(["NoSuchKit"])
        (self.tmp / "empty-repo" / ".git").mkdir(parents=True)
        np.check_new_dest(self.tmp / "empty-repo")  # a lone .git is allowed
        with self.assertRaises(np.Refused):
            quiet(np.update, self.tmp / "busy", None, [], False)  # no starter.json

    def test_scaffold_leaves_nothing_behind_when_it_fails(self):
        dest = self.tmp / "Half"
        with self.assertRaises(np.Refused):
            quiet(np.scaffold, dest, "Half", ["SceneKit"], ["no-such-bundle"])
        self.assertFalse(dest.exists())


if __name__ == "__main__":
    unittest.main()
