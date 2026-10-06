"""tools/user_skills.py: dry run by default, the starter's skills only, stamps, local edits kept,
refusal of this repository and of any git repository."""
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

import new_project  # noqa: E402
import user_skills  # noqa: E402


class UserSkillsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="user-skills-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.claude = self.tmp / "home" / ".claude" / "skills"
        self.codex = self.tmp / "home" / ".agents" / "skills"

    def run_tool(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = user_skills.main([*argv, "--today", "2026-10-06"])
        return code, out.getvalue()

    def test_skill_list_is_the_starters(self):
        self.assertEqual(user_skills.skill_names(), new_project.SKILLS)
        self.assertNotIn("luau-quality", user_skills.skill_names(), "factory-only skills stay in the factory")

    def test_dry_run_writes_nothing(self):
        code, text = self.run_tool("--claude", str(self.claude), "--codex", str(self.codex))
        self.assertEqual(code, 0, text)
        self.assertIn("would copy", text)
        self.assertIn("dry run: nothing written", text)
        self.assertFalse((self.tmp / "home").exists())

    def test_apply_copies_with_stamps_and_check_passes(self):
        code, text = self.run_tool("--claude", str(self.claude), "--codex", str(self.codex), "--apply")
        self.assertEqual(code, 0, text)
        for dest in (self.claude, self.codex):
            self.assertEqual(sorted(p.name for p in dest.iterdir()), sorted(new_project.SKILLS))
            stamp = json.loads((dest / "visual-qa" / user_skills.STAMP).read_text())
            self.assertEqual((stamp["schema"], stamp["skill"], stamp["copied"]), ("factory-skill-stamp/1", "visual-qa", "2026-10-06"))
            self.assertEqual(stamp["tree_sha256"], user_skills.tree_sha256(ROOT / ".agents/skills/visual-qa"))
            self.assertNotIn(str(self.tmp), json.dumps(stamp), "no destination path in the stamp")
            self.assertEqual((dest / "visual-qa" / "SKILL.md").read_bytes(), (ROOT / ".agents/skills/visual-qa/SKILL.md").read_bytes())
        self.assertEqual(self.run_tool("--claude", str(self.claude), "--check")[0], 0)
        self.assertEqual([p.name for p in self.claude.iterdir() if p.name.startswith(".")], [], "no temp folders left")

    def test_other_skills_are_never_touched(self):
        own = self.claude / "my-own-skill"
        own.mkdir(parents=True)
        (own / "SKILL.md").write_text("mine\n")
        self.run_tool("--claude", str(self.claude), "--apply")
        self.assertEqual((own / "SKILL.md").read_text(), "mine\n")

    def test_edited_and_unstamped_skills_are_kept_unless_forced(self):
        self.run_tool("--claude", str(self.claude), "--apply")
        edited = self.claude / "visual-qa" / "SKILL.md"
        edited.write_text(edited.read_text() + "\nlocal note\n")
        shutil.rmtree(self.claude / "roblox-release-pass")
        (self.claude / "roblox-release-pass").mkdir()
        (self.claude / "roblox-release-pass" / "SKILL.md").write_text("someone else's\n")
        states = dict(user_skills.status(self.claude))
        self.assertEqual((states["visual-qa"], states["roblox-release-pass"], states["roblox-ui-ux-pass"]), ("edited", "unstamped", "current"))
        code, text = self.run_tool("--claude", str(self.claude), "--check")
        self.assertEqual(code, 1)
        self.run_tool("--claude", str(self.claude), "--apply")
        self.assertIn("local note", edited.read_text(), "kept without --force")
        self.run_tool("--claude", str(self.claude), "--apply", "--force")
        self.assertNotIn("local note", edited.read_text())
        self.assertEqual(dict(user_skills.status(self.claude))["roblox-release-pass"], "current")

    def test_outdated_after_the_factory_changes(self):
        source = self.tmp / "source"
        shutil.copytree(ROOT / ".agents" / "skills", source)
        self.run_tool("--codex", str(self.codex), "--apply", "--source", str(source))
        skill = source / "visual-qa" / "SKILL.md"
        skill.write_text(skill.read_text() + "\nnew factory text\n")
        self.assertEqual(dict(user_skills.status(self.codex, source=source))["visual-qa"], "outdated")
        code, text = self.run_tool("--codex", str(self.codex), "--apply", "--source", str(source))
        self.assertEqual(code, 0)
        self.assertIn("new factory text", (self.codex / "visual-qa" / "SKILL.md").read_text())

    def test_refuses_this_repo_and_git_repositories(self):
        self.assertEqual(self.run_tool("--claude", str(ROOT / ".claude" / "skills"), "--apply")[0], 2)
        other = self.tmp / "other-repo"
        (other / ".git").mkdir(parents=True)
        code, text = self.run_tool("--codex", str(other / ".agents" / "skills"), "--apply")
        self.assertEqual(code, 2)
        self.assertIn("other repositories are never touched", text)
        self.assertFalse((other / ".agents").exists())
        self.assertEqual(self.run_tool()[0], 2, "a destination is required")


if __name__ == "__main__":
    unittest.main()
