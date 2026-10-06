"""Skills live once in .agents/skills (Codex discovers them there) and are mirrored to
.claude/skills (Claude Code discovers them there). Copies, not symlinks: OneDrive/Windows
checkouts break symlinks.

  python3 tools/sync_skills.py          mirror + validate
  python3 tools/sync_skills.py --check  validate and fail on drift (used by check.py / CI)

Every SKILL.md needs frontmatter (`name` equal to its directory, a `description`), one
non-empty `## <Section>` heading for each name in SECTIONS, and LF line endings. `--check`
also runs selftest(): synthetic skills that must pass (good) and fail (CRLF, missing heading).
"""
import filecmp
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / ".agents" / "skills"
DST = ROOT / ".claude" / "skills"
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
SECTIONS = [
    "Purpose",
    "Triggers",
    "Inputs",
    "Required context",
    "Tools",
    "Procedure",
    "Outputs",
    "Acceptance",
    "Failure",
    "Related",
]
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def frontmatter(text):
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        return None
    fields = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith(" "):
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def sections(body):
    """Level-1/2 headings outside code fences, lower-cased, mapped to the text under them."""
    found, current, fence = {}, None, False
    for line in body.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
        match = None if fence else HEADING_RE.match(line)
        if match and len(match.group(1)) <= 2:
            current = match.group(2).lower()
            found.setdefault(current, "")
        elif current is not None:
            found[current] += line + "\n"
    return found


def validate(src=SRC):
    errors = []
    names = []
    for skill_dir in sorted(p for p in src.iterdir() if p.is_dir()):
        md = skill_dir / "SKILL.md"
        if not md.exists():
            errors.append(f"{skill_dir.name}: missing SKILL.md")
            continue
        # Bytes, not read_text(): universal-newline decoding turns CRLF into LF before any check.
        # .gitattributes pins LF for skills, so a CRLF file here is an editor or paste, not git.
        raw = md.read_bytes()
        if b"\r" in raw:
            errors.append(f"{skill_dir.name}: CRLF/CR line endings (save with LF)")
        text = raw.decode("utf-8").replace("\r\n", "\n")
        fm = frontmatter(text)
        if fm is None:
            errors.append(f"{skill_dir.name}: SKILL.md must start with --- frontmatter")
            continue
        name, desc = fm.get("name", ""), fm.get("description", "")
        if name != skill_dir.name:
            errors.append(f"{skill_dir.name}: name '{name}' must equal directory name")
        if not NAME_RE.match(name) or len(name) > 64:
            errors.append(f"{skill_dir.name}: name must be 1-64 chars [a-z0-9-]")
        if not desc or len(desc) > 1024 or "<" in desc or ">" in desc:
            errors.append(f"{skill_dir.name}: description required, <=1024 chars, no angle brackets")
        found = sections(text[text.find("\n---", 4) + 4 :])
        missing = [s for s in SECTIONS if s.lower() not in found]
        if missing:
            errors.append(f"{skill_dir.name}: missing section headings ('## <Name>'): {', '.join(missing)}")
        empty = [s for s in SECTIONS if s.lower() in found and not found[s.lower()].strip()]
        if empty:
            errors.append(f"{skill_dir.name}: empty sections: {', '.join(empty)}")
        if len(text.splitlines()) > 500:
            errors.append(f"{skill_dir.name}: SKILL.md over 500 lines; move detail to references/")
        if re.search(r"\\[#*_-]", text.split("\n---", 1)[-1][:2000]):
            errors.append(f"{skill_dir.name}: escaped Markdown (paste damage)")
        names.append(name)
    return names, errors


def selftest():
    """Negative cases for validate(): a good synthetic skill must pass, a CRLF copy and one
    missing a heading must fail. Returns a list of errors (empty when the checks still bite)."""
    def skill(name):
        head = f"---\nname: {name}\ndescription: Synthetic skill for the sync_skills self-test.\n---\n\n# T\n\n"
        return head + "".join(f"## {section}\nText.\n\n" for section in SECTIONS)

    cases = {  # directory name -> (SKILL.md text, substring the error must contain or None)
        "selftest-good": (skill("selftest-good"), None),
        "selftest-crlf": (skill("selftest-crlf").replace("\n", "\r\n"), "CRLF"),
        "selftest-heading": (skill("selftest-heading").replace("## Failure", "Failure"), "missing section"),
    }
    out = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, (text, _) in cases.items():
            (Path(tmp) / name).mkdir()
            # newline="" keeps the "\r\n" exactly as written (no platform translation).
            with open(Path(tmp) / name / "SKILL.md", "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
        _, errors = validate(Path(tmp))
    for name, (_, needle) in cases.items():
        hits = [e for e in errors if e.startswith(name + ":")]
        if needle is None and hits:
            out.append(f"selftest: valid skill rejected: {hits}")
        elif needle is not None and not any(needle in e for e in hits):
            out.append(f"selftest: {name} was not rejected for {needle}")
    return out


def drift():
    if not DST.exists():
        return ["(.claude/skills missing)"]
    cmp = filecmp.dircmp(SRC, DST)
    out = []

    def walk(c, prefix=""):
        out.extend(prefix + n for n in c.left_only + c.right_only + c.diff_files)
        for sub, sc in c.subdirs.items():
            walk(sc, prefix + sub + "/")

    walk(cmp)
    return out


def main():
    names, errors = validate()
    if "--check" in sys.argv:
        errors += selftest()
        diff = drift()
        if diff:
            errors.append("skills out of sync (run python3 tools/sync_skills.py): " + ", ".join(diff[:10]))
    else:
        if DST.exists():
            shutil.rmtree(DST)
        shutil.copytree(SRC, DST)
    for e in errors:
        print("ERROR", e)
    print(f"{len(names)} skills, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
