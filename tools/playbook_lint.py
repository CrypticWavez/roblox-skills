"""Lint the genre playbooks in the roblox-genre-systems skill.

  python3 tools/playbook_lint.py [SKILL_DIR] [--root REPO_ROOT] [--json]

SKILL_DIR defaults to .agents/skills/roblox-genre-systems. Exit 0 when clean, 1 with problems.

1. The map, references/taxonomy.json (genre-taxonomy/1):
   - its source doc exists, and its genres and subgenres equal the table in that doc's
     section "1. Official genre taxonomy" (names, membership and the declared counts);
   - every subgenre, and every genre without subgenres ('<Genre> > (none)'), maps to an existing
     playbook or to an exclusion whose reason is at least MIN_REASON characters;
   - 'also' playbooks exist and differ from the primary; cross_cutting playbooks exist; aliases
     name known labels.
2. The format of every references/*.md (all of them are playbooks):
   - a '# Playbook: <title>' line, then 'Kind: genre' or 'Kind: cross-cutting';
   - genre playbooks have 'Covers:' equal to the labels the map gives them as primary;
     cross-cutting ones have no 'Covers:' and are listed under cross_cutting;
   - 'Also:' equals the labels whose 'also' names the playbook (required when there are any);
   - the SECTIONS as '## ' headings, in order, none empty, no others;
   - at least MIN_MODULES module names under 'Kit modules', MIN_CHECKS '- [ ] ' items under
     'Test checklist', MIN_QUESTIONS '- TBD: ...?' items under 'Design questions (TBD)'.
   Every playbook must be reachable from the map.
3. Modules: every Package/Module name a playbook mentions must exist. Kit names (GameKit,
   UIKit, AVKit, Feel, Cinematics) must appear in docs/runtime-kits.md section 11, the module
   ownership list. Authoring names (SceneKit, ProcGen, Pipeline, Diagnostics) must appear there
   or exist as packages/<Package>/<Module>.luau (reported as a note). Inherited first-pass
   packages (Runtime, Creator) are refused: playbooks cite the kits.
4. Neutral wording: a playbook recommends no genre and states no prices.
5. SKILL.md points at references/taxonomy.json.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SKILL = ROOT / ".agents" / "skills" / "roblox-genre-systems"
SCHEMA = "genre-taxonomy/1"
SECTIONS = [
    "Core loop as systems",
    "Kit modules",
    "Data to author",
    "Authority and abuse risks",
    "Performance pitfalls",
    "Policy notes",
    "Test checklist",
    "Design questions (TBD)",
    "Reference systems",
]
KINDS = ("genre", "cross-cutting")
KIT_PACKAGES = ("GameKit", "UIKit", "AVKit", "Feel", "Cinematics")
AUTHORING_PACKAGES = ("SceneKit", "ProcGen", "Pipeline", "Diagnostics")
REFUSED_PACKAGES = ("Runtime", "Creator")
MIN_REASON = 40
MIN_MODULES = 3
MIN_CHECKS = 5
MIN_QUESTIONS = 3
NONE = "(none)"
TAXONOMY_HEADING = "## 1. Official genre taxonomy"
OWNERSHIP_HEADING = "## 11. Module ownership list"
MODULE_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])(" + "|".join(KIT_PACKAGES + AUTHORING_PACKAGES + REFUSED_PACKAGES) + r")"
    r"((?:/[A-Z][A-Za-z0-9]*)+)"
)
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# Wording a neutral reference never uses: a genre pick, a promise, or a price.
NEUTRALITY = [
    (re.compile(r"\b(we|i)\s+(strongly\s+)?(recommend|suggest)\b", re.I), "recommends"),
    (re.compile(r"\byou\s+should\s+(make|build|pick|choose)\b", re.I), "tells the owner what to make"),
    (re.compile(r"\b(best|recommended|winning)\s+genre\b", re.I), "ranks genres"),
    (re.compile(r"\b(most\s+profitable|guaranteed\s+(hit|success|revenue))\b", re.I), "promises results"),
    (re.compile(r"\b\d[\d,.]*\s*(robux|r\$)", re.I), "states a price"),
    (re.compile(r"(r\$|\$|usd)\s*\d", re.I), "states a price"),
]


def label(genre, subgenre):
    return f"{genre} > {subgenre}"


def research_taxonomy(text):
    """{genre: [subgenres]} from the doc's section-1 table, or None when the table is missing."""
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip().startswith(TAXONOMY_HEADING))
    except StopIteration:
        return None
    table, seen_table = {}, False
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        stripped = line.strip()
        if not stripped.startswith("|"):
            if seen_table:
                break
            continue
        seen_table = True
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) < 2 or cells[0] in ("Genre", "") or set(cells[0]) <= set("-: "):
            continue
        subs = [] if cells[1] == NONE else [s.strip() for s in cells[1].split(",") if s.strip()]
        table[cells[0]] = subs
    return table or None


def ownership_modules(text):
    """Backticked Package/Module names in runtime-kits.md section 11 (table and non-kit list)."""
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip().startswith(OWNERSHIP_HEADING))
    except StopIteration:
        return None
    names = set()
    for line in lines[start + 1 :]:
        if line.startswith("## "):
            break
        for span in re.findall(r"`([^`]+)`", line):
            match = MODULE_RE.fullmatch(span.strip())
            if match:
                names.add(match.group(1) + match.group(2))
    return names


def parse_playbook(text):
    """(title, header fields, [(section, body)]) of a playbook."""
    lines = text.splitlines()
    title = lines[0][len("# Playbook: ") :].strip() if lines and lines[0].startswith("# Playbook: ") else None
    header, sections, current, fence = {}, [], None, False
    for line in lines[1:]:
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
        if not fence and line.startswith("## "):
            current = [line[3:].strip(), ""]
            sections.append(current)
            continue
        if not fence and line.startswith("# "):
            sections.append(["#" + line, ""])  # a second H1 is reported as an unexpected section
            current = sections[-1]
            continue
        if current is None:
            match = re.match(r"^(Kind|Covers|Also):\s*(.*)$", line)
            if match:
                header[match.group(1).lower()] = match.group(2).strip()
        else:
            current[1] += line + "\n"
    return title, header, [(name, body) for name, body in sections]


def split_labels(value):
    return {part.strip() for part in value.split(";") if part.strip()}


class Linter:
    def __init__(self, skill_dir, root):
        self.skill = Path(skill_dir)
        self.root = Path(root)
        self.problems = []
        self.notes = []
        self.stats = {"playbooks": 0, "genres": 0, "subgenres": 0, "module_citations": 0}

    def problem(self, where, text):
        self.problems.append(f"{where}: {text}")

    # 1. The map -----------------------------------------------------------------------------
    def load_map(self):
        refs = self.skill / "references"
        path = refs / "taxonomy.json"
        where = "references/taxonomy.json"
        playbooks = {p.stem for p in refs.glob("*.md")} if refs.is_dir() else set()
        if not path.is_file():
            self.problem(where, "missing")
            return None, playbooks
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as err:
            self.problem(where, f"not JSON ({err})")
            return None, playbooks
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            self.problem(where, f"schema must be {SCHEMA}")
            return None, playbooks
        return data, playbooks

    def check_map(self, data, playbooks):
        where = "references/taxonomy.json"
        primary, also, labels = {}, {}, set()
        source = data.get("source") or {}
        doc = source.get("doc")
        expected = None
        if not isinstance(doc, str) or not (self.root / doc).is_file():
            self.problem(where, f"source.doc must name an existing research doc (got {doc!r})")
        else:
            expected = research_taxonomy((self.root / doc).read_text(encoding="utf-8"))
            if expected is None:
                self.problem(where, f"{doc} has no '{TAXONOMY_HEADING}' table to check against")

        genres = data.get("genres")
        if not isinstance(genres, list) or not genres:
            self.problem(where, "genres must be a non-empty list")
            return primary, also, labels
        found = {}
        for entry in genres:
            genre = entry.get("genre") if isinstance(entry, dict) else None
            if not isinstance(genre, str) or not genre:
                self.problem(where, f"genre entry without a name: {entry!r}")
                continue
            if genre in found:
                self.problem(where, f"genre {genre!r} listed twice")
            subs = entry.get("subgenres")
            if not isinstance(subs, list):
                self.problem(where, f"{genre}: subgenres must be a list")
                subs = []
            names = []
            for sub in subs:
                name = sub.get("subgenre") if isinstance(sub, dict) else None
                if not isinstance(name, str) or not name:
                    self.problem(where, f"{genre}: subgenre entry without a name")
                    continue
                if name in names:
                    self.problem(where, f"{genre}: subgenre {name!r} listed twice")
                names.append(name)
                self.check_target(label(genre, name), sub, playbooks, primary, also, labels)
            found[genre] = names
            if "none" in entry:
                self.check_target(label(genre, NONE), entry["none"], playbooks, primary, also, labels)
            elif not names:
                self.problem(where, f"{genre} has no subgenres, so it needs a 'none' entry (playbook or exclusion)")

        counts = data.get("counts") or {}
        actual = {
            "genres": len(found),
            "subgenres": sum(len(v) for v in found.values()),
            "genres_without_subgenres": sum(1 for v in found.values() if not v),
        }
        for key, value in actual.items():
            if counts.get(key) != value:
                self.problem(where, f"counts.{key} is {counts.get(key)!r} but the map has {value}")
        self.stats["genres"], self.stats["subgenres"] = actual["genres"], actual["subgenres"]
        if expected is not None:
            for genre in sorted(set(expected) - set(found)):
                self.problem(where, f"genre {genre!r} from {doc} is not mapped")
            for genre in sorted(set(found) - set(expected)):
                self.problem(where, f"genre {genre!r} is not in {doc}")
            for genre in sorted(set(found) & set(expected)):
                missing = sorted(set(expected[genre]) - set(found[genre]))
                extra = sorted(set(found[genre]) - set(expected[genre]))
                if missing:
                    self.problem(where, f"{genre}: subgenres {missing} from {doc} are not mapped")
                if extra:
                    self.problem(where, f"{genre}: subgenres {extra} are not in {doc}")

        cross = data.get("cross_cutting", [])
        cross_names = set()
        for item in cross if isinstance(cross, list) else []:
            name = item.get("playbook") if isinstance(item, dict) else None
            if name not in playbooks:
                self.problem(where, f"cross_cutting playbook {name!r} has no references/{name}.md")
            elif not str(item.get("systems", "")).strip():
                self.problem(where, f"cross_cutting {name}: 'systems' must say what it covers")
            cross_names.add(name)
        for alias, targets in (data.get("aliases") or {}).items():
            for target in targets if isinstance(targets, list) else [targets]:
                if target not in labels:
                    self.problem(where, f"alias {alias!r} names unknown label {target!r}")
        return primary, also, cross_names

    def check_target(self, name, target, playbooks, primary, also, labels):
        where = "references/taxonomy.json"
        labels.add(name)
        if not isinstance(target, dict):
            self.problem(where, f"{name}: must be an object with 'playbook' or 'excluded'")
            return
        book, excluded = target.get("playbook"), target.get("excluded")
        if book and excluded:
            self.problem(where, f"{name}: has both a playbook and an exclusion")
        elif book:
            if book not in playbooks:
                self.problem(where, f"{name}: playbook {book!r} has no references/{book}.md")
            primary.setdefault(book, set()).add(name)
        elif isinstance(excluded, str) and len(excluded.strip()) >= MIN_REASON:
            pass
        elif excluded is not None:
            self.problem(where, f"{name}: an exclusion needs a reason of at least {MIN_REASON} characters")
        else:
            self.problem(where, f"{name}: maps to no playbook and has no reasoned exclusion")
        for other in target.get("also", []) or []:
            if other not in playbooks:
                self.problem(where, f"{name}: 'also' playbook {other!r} has no references/{other}.md")
            elif other == book:
                self.problem(where, f"{name}: 'also' repeats the primary playbook {other!r}")
            also.setdefault(other, set()).add(name)

    # 2-4. The playbooks ---------------------------------------------------------------------
    def check_playbook(self, path, primary, also, cross_names, known_modules):
        name = path.stem
        where = f"references/{path.name}"
        if not NAME_RE.match(name):
            self.problem(where, "file name must be lower-case words joined by '-'")
        text = path.read_text(encoding="utf-8")
        if "\r" in text:
            self.problem(where, "CRLF line endings")
        title, header, sections = parse_playbook(text)
        if not title:
            self.problem(where, "first line must be '# Playbook: <title>'")
        kind = header.get("kind")
        if kind not in KINDS:
            self.problem(where, f"needs a 'Kind:' line with one of {', '.join(KINDS)}")
        covers = split_labels(header["covers"]) if "covers" in header else None
        if kind == "genre":
            want = primary.get(name, set())
            if covers is None:
                self.problem(where, "a genre playbook needs a 'Covers:' line")
            elif covers != want:
                self.mismatch(where, "Covers", covers, want)
            if not want:
                self.problem(where, "no taxonomy label maps to this genre playbook as primary")
        elif kind == "cross-cutting":
            if covers is not None:
                self.problem(where, "a cross-cutting playbook has no 'Covers:' line")
            if name not in cross_names:
                self.problem(where, "cross-cutting playbook missing from taxonomy cross_cutting")
            if name in primary:
                self.problem(where, f"is primary for {sorted(primary[name])}, so its Kind must be genre")
        want_also = also.get(name, set())
        have_also = split_labels(header["also"]) if "also" in header else set()
        if have_also != want_also:
            self.mismatch(where, "Also", have_also, want_also)

        names = [section for section, _ in sections]
        if names != SECTIONS:
            missing = [s for s in SECTIONS if s not in names]
            extra = [s for s in names if s not in SECTIONS]
            if missing:
                self.problem(where, f"missing sections: {', '.join(missing)}")
            if extra:
                self.problem(where, f"unexpected sections: {', '.join(extra)}")
            if not missing and not extra:
                self.problem(where, f"sections out of order; expected: {', '.join(SECTIONS)}")
        bodies = dict(sections)
        for section in SECTIONS:
            if section in bodies and not bodies[section].strip():
                self.problem(where, f"section '{section}' is empty")
        cited = {m.group(1) + m.group(2) for m in MODULE_RE.finditer(bodies.get("Kit modules", ""))}
        if "Kit modules" in bodies and len(cited) < MIN_MODULES:
            self.problem(where, f"'Kit modules' names {len(cited)} modules; at least {MIN_MODULES}")
        checks = re.findall(r"^- \[ \] \S", bodies.get("Test checklist", ""), re.M)
        if "Test checklist" in bodies and len(checks) < MIN_CHECKS:
            self.problem(where, f"'Test checklist' has {len(checks)} '- [ ]' items; at least {MIN_CHECKS}")
        questions = bodies.get("Design questions (TBD)", "")
        items = re.findall(r"^- (.*)$", questions, re.M)
        bad = [item for item in items if not (item.startswith("TBD: ") and item.rstrip().endswith("?"))]
        if bad:
            self.problem(where, f"design questions must read '- TBD: ...?': {bad[0]!r}")
        if "Design questions (TBD)" in bodies and len(items) < MIN_QUESTIONS:
            self.problem(where, f"'Design questions (TBD)' has {len(items)} items; at least {MIN_QUESTIONS}")

        for number, line in enumerate(text.splitlines(), 1):
            for match in MODULE_RE.finditer(line):
                self.check_module(f"{where}:{number}", match.group(1), match.group(1) + match.group(2), known_modules)
            for pattern, why in NEUTRALITY:
                hit = pattern.search(line)
                if hit:
                    self.problem(f"{where}:{number}", f"not neutral ({why}): {hit.group(0)!r}")

    def mismatch(self, where, field, have, want):
        if want and not have:
            self.problem(where, f"needs an '{field}:' line with: {'; '.join(sorted(want))}")
            return
        missing, extra = sorted(want - have), sorted(have - want)
        if missing:
            self.problem(where, f"'{field}:' lacks {missing} (taxonomy.json maps them here)")
        if extra:
            self.problem(where, f"'{field}:' lists {extra}, which taxonomy.json does not map here")

    def check_module(self, where, package, module, known_modules):
        self.stats["module_citations"] += 1
        if package in REFUSED_PACKAGES:
            self.problem(where, f"{module}: inherited first-pass package; cite the kit module instead")
        elif module in known_modules:
            return
        elif package in KIT_PACKAGES:
            self.problem(where, f"{module}: not in docs/runtime-kits.md section 11 (module ownership list)")
        elif (self.root / "packages" / (module + ".luau")).is_file():
            note = f"{module}: not in section 11, exists as packages/{module}.luau"
            if note not in self.notes:
                self.notes.append(note)
        else:
            self.problem(where, f"{module}: not in section 11 and no packages/{module}.luau")

    def run(self):
        data, playbooks = self.load_map()
        kits = self.root / "docs" / "runtime-kits.md"
        known = ownership_modules(kits.read_text(encoding="utf-8")) if kits.is_file() else None
        if known is None:
            self.problem("docs/runtime-kits.md", f"missing, or no '{OWNERSHIP_HEADING}' section")
            known = set()
        primary, also, cross_names = {}, {}, set()
        if data is not None:
            primary, also, cross_names = self.check_map(data, playbooks)
        refs = self.skill / "references"
        for path in sorted(refs.glob("*.md")) if refs.is_dir() else []:
            self.stats["playbooks"] += 1
            self.check_playbook(path, primary, also, cross_names, known)
        skill_md = self.skill / "SKILL.md"
        if not skill_md.is_file() or "references/taxonomy.json" not in skill_md.read_text(encoding="utf-8"):
            self.problem("SKILL.md", "must point at references/taxonomy.json")
        return self.problems


def lint(skill_dir=DEFAULT_SKILL, root=ROOT):
    linter = Linter(skill_dir, root)
    linter.run()
    return linter.problems, linter.notes, linter.stats


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("skill", nargs="?", default=str(DEFAULT_SKILL))
    ap.add_argument("--root", default=str(ROOT), help="repository root (docs/, packages/)")
    ap.add_argument("--json", action="store_true", help="print a JSON report")
    args = ap.parse_args(argv)
    problems, notes, stats = lint(Path(args.skill), Path(args.root))
    if args.json:
        print(json.dumps({"pass": not problems, "problems": problems, "notes": notes, "stats": stats}, indent=2))
    else:
        for line in problems:
            print("playbook-lint:", line)
        for line in notes:
            print("playbook-lint: note:", line)
        verdict = "PASS" if not problems else f"FAIL ({len(problems)} problems)"
        print(
            f"playbook-lint: {verdict}: {stats['playbooks']} playbooks, {stats['genres']} genres, "
            f"{stats['subgenres']} subgenres, {stats['module_citations']} module citations"
        )
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
