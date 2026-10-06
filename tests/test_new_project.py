"""Tests for the project starter (tools/new_project.py).

  python3 -m unittest tests/test_new_project.py

Scaffolds into temporary directories outside this repository. Covers package classes and the Rojo
layout (packages in factory/, leaf copies for kits, no FilteringEnabled), the tier parse into
starter.json, dependency bundles (exact pins, licence notices, wally never run), --update (user files
preserved; edited packages, skills, hooks and managed files refused; stale ones refreshed; starter/1
layout migrated; packages/ moved to factory/) and the refusals. Case-insensitive filesystems (Windows,
macOS), where `wally install` deletes a packages/ folder along with Packages/, are simulated with
tests/fakes/case_insensitive_fs.py (lookups and Wally's clean step) and git's core.ignorecase.
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
sys.path.insert(0, str(ROOT / "tests" / "fakes"))
import new_project as np  # noqa: E402
from case_insensitive_fs import case_insensitive_paths, wally_clean  # noqa: E402


def quiet(fn, *args):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        result = fn(*args)
    return result, out.getvalue()


def tree_node(project, *names):
    node = project["tree"]
    for name in names:
        node = node.get(name) if isinstance(node, dict) else None
    return node


def mapped_paths(node, trail=()):
    """(trail, $path target) for every node of a Rojo tree; optional paths unwrapped."""
    if not isinstance(node, dict):
        return
    raw = node.get("$path")
    raw = raw.get("optional") if isinstance(raw, dict) else raw
    if isinstance(raw, str):
        yield ".".join(trail), raw
    for key, child in node.items():
        if not key.startswith("$"):
            yield from mapped_paths(child, trail + (key,))


def entry_names(directory):
    """Stored names in directory (Path.exists would fold case on Windows and macOS)."""
    return {p.name for p in directory.iterdir()}


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
        self.assertEqual(np.DEFAULT_PACKAGES, np.PACKAGE_CLASSES["authoring"] + np.PACKAGE_CLASSES["kits"])
        _, out = quiet(np.list_options)
        self.assertIn("files in the game repo's factory/<Pkg>", out)

    def test_default_tree_layout(self):
        dest, out = self.scaffold()
        project = self.read_json(dest / "default.project.json")
        text = (dest / "default.project.json").read_text(encoding="utf-8")
        self.assertNotIn("FilteringEnabled", text)
        for path in [("ReplicatedFirst", "Loading"), ("ReplicatedStorage", "Shared"), ("ServerScriptService", "Server"),
                     ("StarterPlayer", "StarterPlayerScripts", "Client"), ("StarterGui",), ("ServerStorage", "Assets"),
                     ("ServerStorage", "ServerPackages")]:
            self.assertIsInstance(tree_node(project, *path), dict, ".".join(path))
        authoring = tree_node(project, "ServerStorage", "Authoring")
        self.assertEqual(sorted(k for k in authoring if not k.startswith("$")), ["Pipeline", "ProcGen", "SceneKit"])
        kits = tree_node(project, "ReplicatedStorage", "Kits")
        self.assertEqual(sorted(k for k in kits if not k.startswith("$") and k not in ("ProcGen", "SceneKit")),
                         ["AVKit", "Cinematics", "Feel", "GameKit", "UIKit"])
        self.assertEqual(sorted(k for k in kits["ProcGen"] if not k.startswith("$")), ["Graph", "Grid", "Rng"])
        self.assertEqual(sorted(k for k in kits["SceneKit"] if not k.startswith("$")), ["Lighting", "Vec"])
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Legacy"))
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Workbench"))
        self.assertEqual(tree_node(project, "ServerStorage", "ServerPackages", "$path"), {"optional": "ServerPackages"})
        # Wally's Packages/ is packages/ on Windows and macOS: mapping it would map every factory package again.
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Packages"))
        whole = [(trail, target) for trail, target in mapped_paths(project["tree"]) if target.lower().strip("/") == "packages"]
        self.assertEqual(whole, [])
        # The packages live in factory/: `wally install` deletes Packages/, which is packages/ on Windows and macOS.
        self.assertIn("factory", entry_names(dest))
        self.assertNotIn("packages", entry_names(dest))
        self.assertEqual(sorted(entry_names(dest / "factory")), sorted(np.DEFAULT_PACKAGES))
        package_paths = [target for trail, target in mapped_paths(project["tree"]) if ".Authoring." in f".{trail}." or ".Kits." in f".{trail}."]
        self.assertTrue(package_paths)
        self.assertEqual([t for t in package_paths if not t.startswith("factory/")], [])
        self.assertIn("packages (in factory/)", out)
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
        ignore = (dest / ".gitignore").read_text(encoding="utf-8").splitlines()
        self.assertIn("ServerPackages/", ignore)
        self.assertIn("DevPackages/", ignore)
        self.assertEqual([line for line in ignore if line.strip().strip("/").lower() == "packages"], [])

    def test_gitignore_keeps_the_factory_packages_tracked_under_ignorecase(self):
        # git init sets core.ignorecase=true on NTFS and APFS; ignore rules then match case-insensitively.
        if shutil.which("git") is None:
            self.skipTest("git not installed")
        dest, _ = self.scaffold(packages=["ProcGen"])
        subprocess.run(["git", "init", "-q", str(dest)], check=True, capture_output=True)

        def ignored(rel):
            proc = subprocess.run(["git", "-c", "core.ignorecase=true", "check-ignore", "-q", rel], cwd=dest, capture_output=True)
            self.assertIn(proc.returncode, (0, 1), proc.stderr)
            return proc.returncode == 0

        self.assertFalse(ignored("factory/ProcGen/Rng.luau"))
        self.assertTrue(ignored("ServerPackages/_Index/x.lua"))
        self.assertTrue(ignored("DevPackages/_Index/x.lua"))
        with (dest / ".gitignore").open("a", encoding="utf-8") as handle:
            handle.write("Packages/\n")  # a Wally line no longer touches the factory packages ...
        self.assertFalse(ignored("factory/ProcGen/Rng.luau"))
        self.assertTrue(ignored("packages/ProcGen/Rng.luau"))  # ... it hid them in the old packages/ layout

    def test_wally_install_keeps_the_factory_packages(self):
        dest, _ = self.scaffold(packages=["ProcGen"])
        self.assertEqual(wally_clean(dest), [])  # Wally's clean step on Windows or macOS (simulated)
        self.assertIn("ProcGen", entry_names(dest / "factory"))
        # The old layout: on those filesystems Wally's clean step removed packages/ as Packages/.
        (dest / "factory").rename(dest / "packages")
        self.assertEqual(wally_clean(dest), ["packages"])
        self.assertNotIn("packages", entry_names(dest))

    def test_kits_get_leaf_copies_and_dependencies(self):
        dest, out = self.scaffold(packages=["GameKit"])
        project = self.read_json(dest / "default.project.json")
        kits = tree_node(project, "ReplicatedStorage", "Kits")
        self.assertEqual(kits["GameKit"], {"$path": "factory/GameKit"})
        for leaf in ("Rng", "Grid", "Graph"):
            self.assertEqual(kits["ProcGen"][leaf], {"$path": f"factory/ProcGen/{leaf}.luau"})
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
                         ("T3", ["foundation_x"]))
        self.assertEqual(np.module_header("--!strict\n-- @tier T0\n-- Text.\n"), ("T0", []))
        self.assertEqual(np.module_header("--!strict\n-- No tier here.\nlocal x = 1\n-- @tier T1\n"), (None, []))
        self.assertEqual(np.module_header("local x = 1\n"), (None, []))

    def test_every_probe_line_is_recorded_and_pending(self):
        # Before: module_header kept only the first probe line, so a starter dropped the module's other probes.
        two = "--!strict\n-- @tier T3\n-- probe: av_one\n-- probe: av_two\n-- probe: av_one\n-- Adapter.\n"
        self.assertEqual(np.module_header(two), ("T3", ["av_one", "av_two"]))
        modules = np.module_records(np.PACKAGES, ["AVKit"])
        audio = modules["AVKit/AudioGraphRoblox"]
        self.assertEqual(audio["probes"], ["av_audiograph_wires", "av_audio_master_level"])
        self.assertEqual(audio["probe"], "av_audiograph_wires", "starter/2 readers (tests/packages.spec.luau) read a string")
        _, pending = np.tier_summary(modules)
        self.assertEqual([p["probe"] for p in pending if p["module"] == "AVKit/AudioGraphRoblox"],
                         ["av_audio_master_level", "av_audiograph_wires"])

    def test_starter_json_records_modules_tiers_and_pending_probes(self):
        dest, _ = self.scaffold(packages=["GameKit"])
        starter = self.read_json(dest / "starter.json")
        self.assertEqual(starter["schema"], "starter/2")
        modules = starter["modules"]
        self.assertEqual(modules["GameKit/Check"], {"class": "kits", "tier": "T0", "lune": True})
        env = modules["GameKit/EnvRoblox"]
        self.assertEqual((env["tier"], env["lune"], env["probe"], env["probes"]), ("T3", False, "foundation_env_studio", ["foundation_env_studio"]))
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
        self.assertNotIn("wally.lock", entry_names(dest))
        self.assertNotIn("Packages", entry_names(dest))
        self.assertIn("factory", entry_names(dest))
        self.assertNotIn("packages", entry_names(dest))
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
        self.assertEqual([t for _, t in mapped_paths(studio["tree"]) if t.startswith("packages")], [])
        self.assertIn("wally install", proc.stdout)
        starter = json.loads((dest / "starter.json").read_text(encoding="utf-8"))
        self.assertEqual(starter["deps"]["bundles"], ["persistence", "studio-tests"])

    def test_unknown_bundle_is_refused(self):
        proc = self.run_cli(str(self.tmp / "X"), "--deps", "everything")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unknown dependency bundle", proc.stderr)
        self.assertFalse((self.tmp / "X").exists())

    def test_shared_realm_bundles_are_refused(self):
        deps = np.load_deps()
        self.assertEqual([n for n, e in deps["packages"].items() if e["realm"] == "shared"], [])
        deps["packages"]["someone/shared-lib"] = {**deps["packages"]["lm-loleris/profilestore"], "realm": "shared", "alias": "SharedLib"}
        deps["bundles"]["shared-lib"] = {"packages": ["someone/shared-lib"], "tools": ["wally"], "why": "synthetic"}
        self.assertEqual(np.check_bundles(["persistence"], deps), ["persistence"])
        with self.assertRaises(np.Refused) as ctx:
            np.check_bundles(["persistence", "shared-lib"], deps)
        self.assertIn("someone/shared-lib", str(ctx.exception))
        self.assertIn("shared-realm", str(ctx.exception))
        self.assertNotIn("packages/", str(ctx.exception))  # refused for replication, not for a folder collision
        dest = self.tmp / "Shared"
        original = np.load_deps
        np.load_deps = lambda: deps
        try:
            with self.assertRaises(np.Refused):
                quiet(np.scaffold, dest, "Shared", np.DEFAULT_PACKAGES, ["shared-lib"])
        finally:
            np.load_deps = original
        self.assertFalse(dest.exists())

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
        for rel, why in [("factory/ProcGen/Rng.luau", "edited here"),
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

    def test_update_moves_legacy_packages_next_to_the_kits(self):
        dest, _ = self.scaffold()
        packages = np.DEFAULT_PACKAGES + ["Runtime"]
        code, out = self.update(dest, packages=packages)
        self.assertEqual(code, 0, out)
        project = self.read_json(dest / "default.project.json")
        self.assertIn("Runtime", tree_node(project, "ReplicatedStorage", "Kits"))
        # A starter/2 repo made before the move kept legacy packages in ReplicatedStorage.Legacy.
        del project["tree"]["ReplicatedStorage"]["Kits"]["Runtime"]
        project["tree"]["ReplicatedStorage"]["Legacy"] = {"$className": "Folder", "Runtime": {"$path": "packages/Runtime"}}
        (dest / "default.project.json").write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        code, out = self.update(dest, packages=packages)
        self.assertEqual(code, 0, out)
        self.assertIn("removed ReplicatedStorage.Legacy", out)
        project = self.read_json(dest / "default.project.json")
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Legacy"))
        self.assertIn("Runtime", tree_node(project, "ReplicatedStorage", "Kits"))

    def test_update_removes_the_replicated_wally_packages_mapping(self):
        dest, _ = self.scaffold()
        path = dest / "default.project.json"
        project = self.read_json(path)
        project["tree"]["ReplicatedStorage"]["Packages"] = {"$path": {"optional": "Packages"}}  # earlier starter/2 template
        path.write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("removed ReplicatedStorage.Packages", out)
        project = self.read_json(path)
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Packages"))
        self.assertIn("Shared", tree_node(project, "ReplicatedStorage"))
        self.assertEqual(tree_node(project, "ServerStorage", "ServerPackages", "$path"), {"optional": "ServerPackages"})

    def test_update_migrates_a_starter1_layout(self):
        dest, _ = self.scaffold()
        project = self.read_json(dest / "default.project.json")
        del project["tree"]["ServerStorage"]["Authoring"]
        del project["tree"]["ReplicatedStorage"]["Kits"]
        project["tree"]["ReplicatedStorage"]["Workbench"] = {"$path": "packages"}
        (dest / "default.project.json").write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        (dest / "factory").rename(dest / "packages")  # starter/1 kept every package in packages/
        starter = self.read_json(dest / "starter.json")
        old = {"schema": "starter/1", "name": starter["name"], "created": starter["created"], "factory": starter["factory"],
               "packages": {k: {"sha256": v["sha256"], "files": v["files"]} for k, v in starter["packages"].items()},
               "skills": sorted(starter["skills"]), "smoke": starter.get("smoke")}
        (dest / "starter.json").write_text(json.dumps(old, indent=2) + "\n", encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("removed ReplicatedStorage.Workbench", out)
        self.assertIn("packages/: moved to factory/", out)
        self.assertEqual({"factory", "packages"} & entry_names(dest), {"factory"})
        project = self.read_json(dest / "default.project.json")
        self.assertIsNone(tree_node(project, "ReplicatedStorage", "Workbench"))
        self.assertEqual(tree_node(project, "ServerStorage", "Authoring", "SceneKit"), {"$path": "factory/SceneKit"})
        self.assertEqual(self.read_json(dest / "starter.json")["schema"], "starter/2")

    def old_layout(self, dest):
        """A repo made before the move: the packages in packages/, every Rojo path into them under packages/."""
        (dest / "factory").rename(dest / "packages")
        for name in ("default.project.json", "studio-tests.project.json"):
            if (dest / name).is_file():
                text = (dest / name).read_text(encoding="utf-8")
                (dest / name).write_text(text.replace('"factory/', '"packages/'), encoding="utf-8")
        agents = dest / "AGENTS.md"
        agents.write_text(agents.read_text(encoding="utf-8").replace("`factory/`", "`packages/`"), encoding="utf-8")

    def test_update_moves_packages_to_factory(self):
        dest, _ = self.scaffold(bundles=["studio-tests"])
        self.old_layout(dest)
        path = dest / "default.project.json"
        project = self.read_json(path)
        self.assertEqual(tree_node(project, "ReplicatedStorage", "Kits", "GameKit"), {"$path": "packages/GameKit"})
        project["tree"]["ReplicatedStorage"]["Extra"] = {"$path": {"optional": "packages/GameKit/Signal.luau"}}
        project["tree"]["ServerStorage"]["Own"] = {"$path": "packages/MyLib"}  # not a factory package: left alone
        path.write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        (dest / "tests" / "mine.spec.luau").write_text('local Signal = require("../packages/GameKit/Signal")\nreturn {}\n',
                                                       encoding="utf-8")  # a game's own spec into the old folder
        digests = {pkg: np.tree_hash(dest / "packages" / pkg)[0] for pkg in np.DEFAULT_PACKAGES}
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("packages/: moved to factory/", out)
        self.assertIn("default.project.json: 1 other path(s) moved from packages/ to factory/", out)
        self.assertIn("note: AGENTS.md still names packages/", out)
        self.assertIn("note: tests/mine.spec.luau still names packages/", out)
        self.assertNotIn("note: default.project.json still names", out)
        self.assertEqual({"factory", "packages"} & entry_names(dest), {"factory"})
        self.assertEqual({pkg: np.tree_hash(dest / "factory" / pkg)[0] for pkg in np.DEFAULT_PACKAGES}, digests)
        project = self.read_json(path)
        self.assertEqual(tree_node(project, "ReplicatedStorage", "Kits", "GameKit"), {"$path": "factory/GameKit"})
        self.assertEqual(tree_node(project, "ReplicatedStorage", "Kits", "ProcGen", "Rng"), {"$path": "factory/ProcGen/Rng.luau"})
        self.assertEqual(tree_node(project, "ReplicatedStorage", "Extra", "$path"), {"optional": "factory/GameKit/Signal.luau"})
        self.assertEqual(tree_node(project, "ServerStorage", "Own", "$path"), "packages/MyLib")
        studio = self.read_json(dest / "studio-tests.project.json")
        self.assertEqual(tree_node(studio, "ServerStorage", "Authoring", "SceneKit"), {"$path": "factory/SceneKit"})
        starter = self.read_json(dest / "starter.json")
        self.assertEqual(starter["modules"], np.module_records(dest / "factory", sorted(starter["packages"])))
        check = load_starter_tool("check")
        self.assertEqual(check.skills_packages_problems(dest, starter)[0], [])
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertIn("already up to date", out)

    def test_update_refuses_a_move_it_cannot_make_safely(self):
        # A package edited in packages/: refused like any edit (nothing moved); --force moves and refreshes it.
        dest, _ = self.scaffold(name="Edited")
        self.old_layout(dest)
        rng = dest / "packages" / "ProcGen" / "Rng.luau"
        original = rng.read_text(encoding="utf-8")
        rng.write_text(original + "-- local edit\n", encoding="utf-8")
        with self.assertRaises(np.Refused) as ctx:
            self.update(dest)
        self.assertIn("packages edited here", str(ctx.exception))
        self.assertEqual({"factory", "packages"} & entry_names(dest), {"packages"})
        code, out = self.update(dest, force=True)
        self.assertEqual(code, 0, out)
        self.assertEqual((dest / "factory" / "ProcGen" / "Rng.luau").read_text(encoding="utf-8"), original)
        # Entries starter.json does not record would be carried into factory/: refused without --force.
        dest, _ = self.scaffold(name="Stray")
        self.old_layout(dest)
        (dest / "packages" / "MyLib").mkdir()
        (dest / "packages" / "MyLib" / "init.luau").write_text("return {}\n", encoding="utf-8")
        with self.assertRaises(np.Refused) as ctx:
            self.update(dest)
        self.assertIn("packages/ holds entries starter.json does not record", str(ctx.exception))
        self.assertIn("MyLib", str(ctx.exception))
        self.assertEqual({"factory", "packages"} & entry_names(dest), {"packages"})
        # factory/ already holds something else: refused even with --force, nothing moved or written.
        dest, _ = self.scaffold(name="Taken")
        self.old_layout(dest)
        (dest / "factory").mkdir()
        (dest / "factory" / "notes.txt").write_text("the game's own\n", encoding="utf-8")
        before = (dest / "starter.json").read_text(encoding="utf-8")
        for force in (False, True):
            with self.assertRaises(np.Refused) as ctx:
                self.update(dest, force=force)
            self.assertIn("factory/ already exists with other content", str(ctx.exception))
        self.assertEqual(entry_names(dest / "factory"), {"notes.txt"})
        self.assertIn("ProcGen", entry_names(dest / "packages"))
        self.assertEqual((dest / "starter.json").read_text(encoding="utf-8"), before)
        # An empty factory/ is no conflict.
        (dest / "factory" / "notes.txt").unlink()
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertEqual({"factory", "packages"} & entry_names(dest), {"factory"})

    def test_update_leaves_a_games_own_packages_folder_beside_factory(self):
        dest, _ = self.scaffold(name="Own")
        (dest / "packages" / "MyLib").mkdir(parents=True)
        (dest / "packages" / "MyLib" / "init.luau").write_text("return {}\n", encoding="utf-8")
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertNotIn("moved to factory/", out)
        self.assertEqual(entry_names(dest / "packages"), {"MyLib"})
        self.assertEqual(sorted(entry_names(dest / "factory")), sorted(np.DEFAULT_PACKAGES))

    def test_update_restores_packages_wally_already_deleted(self):
        # On Windows or macOS an older repo's `wally install` removed packages/; --update writes factory/.
        dest, _ = self.scaffold(name="Wiped")
        self.old_layout(dest)
        self.assertEqual(wally_clean(dest), ["packages"])
        code, out = self.update(dest)
        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(entry_names(dest / "factory")), sorted(np.DEFAULT_PACKAGES))
        project = self.read_json(dest / "default.project.json")
        self.assertEqual([t for _, t in mapped_paths(project["tree"]) if t.startswith("packages/")], [])


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

    def test_deps_step_compares_exact_folder_names(self):
        dest, _ = self.scaffold()
        with case_insensitive_paths():
            self.assertFalse((dest / "Packages").exists())  # factory/ answers to no Wally folder name
            self.assertEqual(self.check.deps_problems(dest)[0], [])
        # A packages/ folder (a game's own, or the old layout) is what `wally install` deletes on Windows and macOS.
        (dest / "packages").mkdir()
        (dest / "packages" / "x.luau").write_text("return nil\n", encoding="utf-8")
        deleted = "packages/: `wally install` deletes Packages/, which is packages/ on Windows and macOS; rename it (factory packages live in factory/)"
        self.assertEqual(self.check.deps_problems(dest)[0], [deleted])
        with case_insensitive_paths():
            self.assertTrue((dest / "Packages").is_dir() and any((dest / "Packages").iterdir()))
            self.assertEqual(self.check.deps_problems(dest)[0], [deleted])  # never "Packages/ has content"
        shutil.rmtree(dest / "packages")
        (dest / "ServerPackages").mkdir()
        (dest / "ServerPackages" / "x.lua").write_text("return nil\n", encoding="utf-8")
        (dest / "Packages").mkdir()  # possible only on a case-sensitive filesystem
        (dest / "Packages" / "x.lua").write_text("return nil\n", encoding="utf-8")
        problems = self.check.deps_problems(dest)[0]
        self.assertEqual(sorted(problems), ["Packages/ has content but there is no wally.toml",
                                            "ServerPackages/ has content but there is no wally.toml"])

    def test_deps_step_refuses_shared_realm_dependencies(self):
        dest, _ = self.scaffold(bundles=["persistence"])
        (dest / "wally.lock").write_text('[[package]]\nname = "lm-loleris/profilestore"\nversion = "1.0.3"\n', encoding="utf-8")
        self.assertEqual(self.check.deps_problems(dest)[0], [])
        wally = dest / "wally.toml"
        text = wally.read_text(encoding="utf-8")
        self.assertIn("[dependencies]\n", text)
        wally.write_text(text.replace("[dependencies]\n", '[dependencies]\nProfileStore2 = "lm-loleris/profilestore@=1.0.3"\n'),
                         encoding="utf-8")
        problems = self.check.deps_problems(dest)[0]
        self.assertTrue(any("[dependencies] ProfileStore2: shared-realm dependencies are refused" in p for p in problems), problems)

    def test_skills_packages_step(self):
        dest, _ = self.scaffold()
        self.assertEqual(self.check.skills_packages_problems(dest, self.starter(dest))[0], [])
        rng = dest / "factory" / "ProcGen" / "Rng.luau"
        rng.write_text(rng.read_text(encoding="utf-8") + "-- local patch\n", encoding="utf-8")
        self.assertTrue(any("factory/ProcGen differs" in p for p in self.check.skills_packages_problems(dest, self.starter(dest))[0]))
        starter = self.starter(dest)
        starter["patched"] = {"packages/ProcGen": "the old key"}
        self.assertTrue(any("factory/ProcGen differs" in p for p in self.check.skills_packages_problems(dest, starter)[0]))
        starter["patched"] = {"factory/ProcGen": "synthetic reason"}
        problems, notes = self.check.skills_packages_problems(dest, starter)
        self.assertEqual(problems, [])
        self.assertTrue(any("patched here" in n for n in notes))
        skill = dest / ".agents" / "skills" / "visual-qa" / "SKILL.md"
        skill.write_text(skill.read_text(encoding="utf-8") + "\nSee ProcGen/NoSuchModule.\n", encoding="utf-8")
        starter["patched"]["skills/visual-qa"] = "synthetic"
        problems, _ = self.check.skills_packages_problems(dest, starter)
        self.assertTrue(any("ProcGen/NoSuchModule" in p for p in problems), problems)
        (dest / "factory").rename(dest / "packages")  # the old layout: the gate points at --update
        problems, _ = self.check.skills_packages_problems(dest, starter)
        self.assertTrue(any(p.startswith("factory/GameKit is recorded in starter.json but missing") and "--update" in p
                            for p in problems), problems)


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
