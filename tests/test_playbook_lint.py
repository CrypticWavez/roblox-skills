"""Unit tests for tools/playbook_lint.py.

  python3 -m unittest tests/test_playbook_lint.py

Each case builds a small synthetic repository (research doc, runtime-kits.md, packages, a skill
with taxonomy.json and playbooks), breaks one thing, and expects the exact problem. The last
cases lint the real skill, which must pass.
"""
import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import playbook_lint  # noqa: E402

RESEARCH = """# Genre research

## 1. Official genre taxonomy

| Genre | Subgenres |
|---|---|
| Alpha | One, Two & Three |
| Beta | (none) |
| Gamma | (none) |

The rest of the doc.

## 2. Other
| Not | Taxonomy |
|---|---|
| Delta | Four |
"""

RUNTIME_KITS = """# Runtime kits

## 10. Interfaces
`GameKit/NotListed` appears outside section 11.

## 11. Module ownership list

| Owner | Modules |
|---|---|
| Stage 0 | `GameKit/Fsm`, `GameKit/Signal` |
| G4 | `UIKit/Components/Timer`, `Cinematics/Cinematics` |

Non-kit modules: G7 `SceneKit/Kit`, `ProcGen/Course`.

## 12. Determinism
"""

TAXONOMY = {
    "schema": "genre-taxonomy/1",
    "source": {"doc": "docs/research/genres.md", "section": "1. Official genre taxonomy"},
    "counts": {"genres": 3, "subgenres": 2, "genres_without_subgenres": 2},
    "genres": [
        {
            "genre": "Alpha",
            "subgenres": [
                {"subgenre": "One", "playbook": "alpha-play"},
                {"subgenre": "Two & Three", "playbook": "alpha-play", "also": ["beta-play"]},
            ],
        },
        {"genre": "Beta", "subgenres": [], "none": {"playbook": "beta-play"}},
        {
            "genre": "Gamma",
            "subgenres": [],
            "none": {"excluded": "A catch-all with no shared loop to describe, so no playbook here."},
        },
    ],
    "cross_cutting": [{"playbook": "cross-play", "systems": "queues and boards"}],
    "aliases": {"first": ["Alpha > One"], "nothing": ["Beta > (none)"]},
}


def playbook(title, kind="genre", covers=None, also=None, modules=None, sections=None, extra=""):
    head = [f"# Playbook: {title}", "", f"Kind: {kind}"]
    if covers is not None:
        head.append(f"Covers: {covers}")
    if also is not None:
        head.append(f"Also: {also}")
    modules = modules or ["`GameKit/Fsm`: states", "`GameKit/Signal`: events", "`UIKit/Components/Timer`: timer"]
    body = {
        "Core loop as systems": "- A loop.",
        "Kit modules": "\n".join(f"- {m}" for m in modules),
        "Data to author": "- Tables (TBD).",
        "Authority and abuse risks": "- The server decides.",
        "Performance pitfalls": "- Pool effects.",
        "Policy notes": "- Filter text.",
        "Test checklist": "\n".join(f"- [ ] Check {i}." for i in range(5)),
        "Design questions (TBD)": "\n".join(f"- TBD: Question {i}?" for i in range(3)),
        "Reference systems": "- The research doc.",
    }
    order = sections or list(body)
    out = head + [""]
    for name in order:
        out += [f"## {name}", body.get(name, "- Text."), ""]
    return "\n".join(out) + extra + "\n"


class Repo:
    """A synthetic repository in a temp dir; edit files, then lint()."""

    def __init__(self, tmp):
        self.root = Path(tmp)
        self.skill = self.root / ".agents" / "skills" / "genre-systems"
        self.refs = self.skill / "references"
        self.refs.mkdir(parents=True)
        (self.root / "docs" / "research").mkdir(parents=True)
        (self.root / "packages" / "SceneKit").mkdir(parents=True)
        self.write("docs/research/genres.md", RESEARCH)
        self.write("docs/runtime-kits.md", RUNTIME_KITS)
        self.write("packages/SceneKit/Measure.luau", "return {}\n")
        self.write_skill("Read references/taxonomy.json first.\n")
        self.taxonomy = copy.deepcopy(TAXONOMY)
        self.save_taxonomy()
        self.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three"))
        self.book("beta-play", playbook("Beta", covers="Beta > (none)", also="Alpha > Two & Three"))
        self.book("cross-play", playbook("Cross", kind="cross-cutting"))

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def write_skill(self, text):
        (self.skill / "SKILL.md").write_text(text, encoding="utf-8")

    def book(self, name, text):
        (self.refs / f"{name}.md").write_text(text, encoding="utf-8")

    def save_taxonomy(self):
        (self.refs / "taxonomy.json").write_text(json.dumps(self.taxonomy, indent=2), encoding="utf-8")

    def lint(self):
        return playbook_lint.lint(self.skill, self.root)


class PlaybookLintTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def problems(self):
        return self.repo.lint()[0]

    def assertProblem(self, needle):
        problems = self.problems()
        self.assertTrue(any(needle in p for p in problems), f"no problem containing {needle!r} in {problems}")

    # The synthetic repository is valid as built.
    def test_valid_repo_passes(self):
        problems, notes, stats = self.repo.lint()
        self.assertEqual(problems, [])
        self.assertEqual(stats["playbooks"], 3)
        self.assertEqual((stats["genres"], stats["subgenres"]), (3, 2))

    # The map.
    def test_research_table_is_parsed_from_section_one_only(self):
        table = playbook_lint.research_taxonomy(RESEARCH)
        self.assertEqual(table, {"Alpha": ["One", "Two & Three"], "Beta": [], "Gamma": []})

    def test_subgenre_in_doc_but_not_in_map(self):
        self.repo.taxonomy["genres"][0]["subgenres"].pop()
        self.repo.taxonomy["counts"]["subgenres"] = 1
        self.repo.save_taxonomy()
        self.assertProblem("Alpha: subgenres ['Two & Three'] from docs/research/genres.md are not mapped")

    def test_genre_in_map_but_not_in_doc(self):
        self.repo.taxonomy["genres"].append({"genre": "Omega", "subgenres": [], "none": {"playbook": "beta-play"}})
        self.repo.taxonomy["counts"].update(genres=4, genres_without_subgenres=3)
        self.repo.save_taxonomy()
        self.assertProblem("genre 'Omega' is not in docs/research/genres.md")

    def test_counts_must_match(self):
        self.repo.taxonomy["counts"]["subgenres"] = 39
        self.repo.save_taxonomy()
        self.assertProblem("counts.subgenres is 39 but the map has 2")

    def test_exclusion_needs_a_reason(self):
        self.repo.taxonomy["genres"][2]["none"] = {"excluded": "not a game"}
        self.repo.save_taxonomy()
        self.assertProblem("Gamma > (none): an exclusion needs a reason of at least 40 characters")

    def test_genre_without_subgenres_needs_a_none_entry(self):
        del self.repo.taxonomy["genres"][1]["none"]
        self.repo.save_taxonomy()
        self.assertProblem("Beta has no subgenres, so it needs a 'none' entry")

    def test_missing_playbook_file(self):
        self.repo.taxonomy["genres"][0]["subgenres"][0]["playbook"] = "ghost-play"
        self.repo.save_taxonomy()
        self.assertProblem("Alpha > One: playbook 'ghost-play' has no references/ghost-play.md")

    def test_alias_must_name_a_known_label(self):
        self.repo.taxonomy["aliases"]["typo"] = ["Alpha > Once"]
        self.repo.save_taxonomy()
        self.assertProblem("alias 'typo' names unknown label 'Alpha > Once'")

    def test_wrong_schema(self):
        self.repo.taxonomy["schema"] = "genre-taxonomy/0"
        self.repo.save_taxonomy()
        self.assertProblem("schema must be genre-taxonomy/1")

    # The playbook format.
    def test_missing_section(self):
        names = [s for s in playbook_lint.SECTIONS if s != "Policy notes"]
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", sections=names))
        self.assertProblem("alpha-play.md: missing sections: Policy notes")

    def test_sections_out_of_order(self):
        names = list(playbook_lint.SECTIONS)
        names[0], names[1] = names[1], names[0]
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", sections=names))
        self.assertProblem("alpha-play.md: sections out of order")

    def test_covers_must_equal_the_map(self):
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One"))
        self.assertProblem("'Covers:' lacks ['Alpha > Two & Three']")

    def test_also_must_equal_the_map(self):
        self.repo.book("beta-play", playbook("Beta", covers="Beta > (none)"))
        self.assertProblem("beta-play.md: needs an 'Also:' line with: Alpha > Two & Three")

    def test_genre_playbook_unreachable_from_the_map(self):
        self.repo.book("orphan-play", playbook("Orphan", covers="Alpha > One"))
        self.assertProblem("orphan-play.md: no taxonomy label maps to this genre playbook as primary")

    def test_cross_cutting_must_be_listed(self):
        self.repo.taxonomy["cross_cutting"] = []
        self.repo.save_taxonomy()
        self.assertProblem("cross-play.md: cross-cutting playbook missing from taxonomy cross_cutting")

    def test_checklist_and_questions_minimums(self):
        text = playbook("Alpha", covers="Alpha > One; Alpha > Two & Three")
        text = text.replace("- [ ] Check 4.\n", "").replace("- TBD: Question 2?", "- Question two")
        self.repo.book("alpha-play", text)
        self.assertProblem("'Test checklist' has 4 '- [ ]' items; at least 5")
        self.assertProblem("design questions must read '- TBD: ...?': 'Question two'")

    # Module names.
    def test_unknown_kit_module(self):
        modules = ["`GameKit/Fsm`: a", "`GameKit/Signal`: b", "`GameKit/NotListed`: c"]
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", modules=modules))
        self.assertProblem("GameKit/NotListed: not in docs/runtime-kits.md section 11")

    def test_inherited_package_is_refused(self):
        extra = "\nSee `Runtime/NativeUI` for the old panel.\n"
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", extra=extra))
        self.assertProblem("Runtime/NativeUI: inherited first-pass package")

    def test_authoring_module_on_disk_is_a_note_missing_is_a_problem(self):
        extra = "\nJumps use `SceneKit/Measure`; layouts use `ProcGen/Imaginary`.\n"
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", extra=extra))
        problems, notes, _ = self.repo.lint()
        self.assertTrue(any("SceneKit/Measure: not in section 11, exists" in n for n in notes), notes)
        self.assertFalse(any("SceneKit/Measure" in p for p in problems), problems)
        self.assertTrue(any("ProcGen/Imaginary: not in section 11 and no packages/" in p for p in problems), problems)

    def test_module_names_in_paths_are_checked(self):
        extra = "\nCode: packages/GameKit/Missing.luau.\n"
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", extra=extra))
        self.assertProblem("GameKit/Missing: not in docs/runtime-kits.md section 11")

    def test_ownership_list_reads_section_eleven_only(self):
        names = playbook_lint.ownership_modules(RUNTIME_KITS)
        self.assertIn("UIKit/Components/Timer", names)
        self.assertIn("ProcGen/Course", names)
        self.assertNotIn("GameKit/NotListed", names)

    def test_too_few_kit_modules(self):
        self.repo.book(
            "alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", modules=["`GameKit/Fsm`: a"])
        )
        self.assertProblem("'Kit modules' names 1 modules; at least 3")

    # Neutral wording.
    def test_recommendation_and_price_are_refused(self):
        extra = "\nWe recommend this layout. Sell it for 100 Robux.\n"
        self.repo.book("alpha-play", playbook("Alpha", covers="Alpha > One; Alpha > Two & Three", extra=extra))
        self.assertProblem("not neutral (recommends)")
        self.assertProblem("not neutral (states a price)")

    def test_skill_must_point_at_the_taxonomy(self):
        self.repo.write_skill("No pointer here.\n")
        self.assertProblem("SKILL.md: must point at references/taxonomy.json")

    # The command line.
    def test_cli_exit_codes_and_json(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(playbook_lint.main([str(self.repo.skill), "--root", str(self.repo.root)]), 0)
        self.assertIn("playbook-lint: PASS: 3 playbooks", out.getvalue())
        self.repo.write_skill("No pointer here.\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = playbook_lint.main([str(self.repo.skill), "--root", str(self.repo.root), "--json"])
        self.assertEqual(code, 1)
        report = json.loads(out.getvalue())
        self.assertFalse(report["pass"])
        self.assertEqual(report["problems"], ["SKILL.md: must point at references/taxonomy.json"])


class RealSkillTests(unittest.TestCase):
    def test_real_skill_passes(self):
        problems, _, stats = playbook_lint.lint()
        self.assertEqual(problems, [])
        self.assertEqual((stats["genres"], stats["subgenres"]), (17, 43))
        self.assertGreaterEqual(stats["playbooks"], 23)

    def test_real_map_covers_every_label_of_the_research_doc(self):
        data = json.loads((playbook_lint.DEFAULT_SKILL / "references" / "taxonomy.json").read_text(encoding="utf-8"))
        table = playbook_lint.research_taxonomy((ROOT / data["source"]["doc"]).read_text(encoding="utf-8"))
        mapped = {g["genre"]: sorted(s["subgenre"] for s in g["subgenres"]) for g in data["genres"]}
        self.assertEqual(mapped, {genre: sorted(subs) for genre, subs in table.items()})
        for genre in data["genres"]:
            if not genre["subgenres"]:
                self.assertIn("none", genre, genre["genre"])


if __name__ == "__main__":
    unittest.main()
