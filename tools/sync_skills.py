"""Skills live once in .agents/skills (Codex discovers them there) and are mirrored to
.claude/skills (Claude Code discovers them there). Copies, not symlinks: OneDrive/Windows
checkouts break symlinks.

  python3 tools/sync_skills.py          mirror + validate
  python3 tools/sync_skills.py --check  validate and fail on drift (used by check.py / CI)

Every SKILL.md needs frontmatter (`name` equal to its directory, a `description`) and one
non-empty `## <Section>` heading for each name in SECTIONS.
"""
import filecmp
import re
import shutil
import sys
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


def validate():
    errors = []
    names = []
    for skill_dir in sorted(p for p in SRC.iterdir() if p.is_dir()):
        md = skill_dir / "SKILL.md"
        if not md.exists():
            errors.append(f"{skill_dir.name}: missing SKILL.md")
            continue
        text = md.read_text(encoding="utf-8")
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
        if "\r\n" in text or re.search(r"\\[#*_-]", text.split("\n---", 1)[-1][:2000]):
            errors.append(f"{skill_dir.name}: CRLF or escaped Markdown (paste damage)")
        names.append(name)
    return names, errors


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
