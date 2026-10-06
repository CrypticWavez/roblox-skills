"""Copy the factory's game-facing skills into a user skill folder (Claude Code and/or Codex layout).

  python3 tools/user_skills.py --claude <dir>                 dry run: what would be copied
  python3 tools/user_skills.py --claude <dir> --codex <dir> --apply
  python3 tools/user_skills.py --claude <dir> --check         exit 1 unless every skill is current

The skills are the starter's SKILLS list in tools/new_project.py (the ones a game repository gets), read
from .agents/skills/. Usual folders: Claude Code `<home>/.claude/skills`, Codex `<home>/.agents/skills`
(the same SKILL.md works in both). Nothing is written unless --apply is given, and then only the named
skill folders inside the given folder: other skills there are never touched or deleted.

Each copied skill gets `.factory-stamp.json` (the factory commit, the date and a sha256 of the skill's
files), so later runs tell `current`, `outdated` (the factory changed), `edited` (changed in place; kept
unless --force), `unstamped` (a skill of that name not copied by this tool; kept unless --force) and
`missing`. Refused destinations: anything inside this repository or inside any git repository (other
repos are never touched). Paths are printed, never written into this repository.
Exit 0 on success, 1 when --check finds a skill that is not current, 2 on refused or bad usage.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".agents" / "skills"
STAMP = ".factory-stamp.json"
SCHEMA = "factory-skill-stamp/1"
sys.path.insert(0, str(ROOT / "tools"))


class Refused(Exception):
    pass


def skill_names():
    import new_project  # noqa: E402  (sibling tool; its SKILLS list is the starter's)

    return list(new_project.SKILLS)


def tree_files(folder):
    """Sorted relative posix paths of the files in a skill folder, the stamp excluded."""
    folder = Path(folder)
    return sorted(p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file() and p.name != STAMP)


def tree_sha256(folder):
    digest = hashlib.sha256()
    for rel in tree_files(folder):
        digest.update(rel.encode("utf-8") + b"\0")
        digest.update(hashlib.sha256((Path(folder) / rel).read_bytes()).digest())
    return digest.hexdigest()


def factory_commit():
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=30)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def inside_git(path):
    """The first ancestor (or the path itself) that holds a .git entry, or None."""
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def check_destination(dest):
    dest = Path(dest).expanduser().resolve()
    root = ROOT.resolve()
    if dest == root or root in dest.parents or dest in root.parents:
        raise Refused(f"{dest} overlaps this repository; give a user skill folder outside it")
    repo = inside_git(dest)
    if repo is not None:
        raise Refused(f"{dest} is inside the git repository {repo}; other repositories are never touched")
    if dest.exists() and not dest.is_dir():
        raise Refused(f"{dest} exists and is not a folder")
    return dest


def read_stamp(folder):
    try:
        stamp = json.loads((Path(folder) / STAMP).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return stamp if isinstance(stamp, dict) and stamp.get("schema") == SCHEMA else None


def status(dest, names=None, source=SOURCE):
    """[(name, state)] for each skill: current, outdated, edited, unstamped or missing."""
    rows = []
    for name in names or skill_names():
        target = Path(dest) / name
        if not target.is_dir():
            rows.append((name, "missing"))
            continue
        stamp = read_stamp(target)
        if stamp is None:
            rows.append((name, "unstamped"))
        elif tree_sha256(target) != stamp.get("tree_sha256"):
            rows.append((name, "edited"))
        elif stamp.get("tree_sha256") != tree_sha256(Path(source) / name):
            rows.append((name, "outdated"))
        else:
            rows.append((name, "current"))
    return rows


def copy_skill(name, dest, source, commit, today):
    """Replaces dest/name with a fresh copy plus its stamp (written beside it first, then swapped in)."""
    src = Path(source) / name
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=dest))
    try:
        staged = work / name
        shutil.copytree(src, staged, ignore=shutil.ignore_patterns(STAMP, "__pycache__"))
        stamp = {"schema": SCHEMA, "skill": name, "factory_commit": commit, "copied": today, "tree_sha256": tree_sha256(src)}
        (staged / STAMP).write_text(json.dumps(stamp, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        target = dest / name
        if target.exists():
            old = work / (name + ".old")
            os.replace(target, old)
        os.replace(staged, target)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def plan(dest, names, source, force):
    """[(name, state, action)] where action is copy, skip or keep."""
    rows = []
    for name, state in status(dest, names, source):
        if state == "current":
            action = "skip"
        elif state in ("missing", "outdated"):
            action = "copy"
        else:  # edited or unstamped: someone's own changes
            action = "copy" if force else "keep"
        rows.append((name, state, action))
    return rows


def display(path):
    home = str(Path.home())
    text = str(path)
    return "~" + text[len(home):] if home not in ("", "/") and text.startswith(home) else text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--claude", metavar="DIR", help="Claude Code user skill folder (usually <home>/.claude/skills)")
    ap.add_argument("--codex", metavar="DIR", help="Codex user skill folder (usually <home>/.agents/skills)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="copy (default is a dry run)")
    mode.add_argument("--check", action="store_true", help="exit 1 unless every skill is current; writes nothing")
    ap.add_argument("--force", action="store_true", help="with --apply: also replace edited or unstamped skills")
    ap.add_argument("--source", default=str(SOURCE), help=argparse.SUPPRESS)
    ap.add_argument("--today", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    targets = [(label, value) for label, value in (("claude", args.claude), ("codex", args.codex)) if value]
    if not targets:
        print("REFUSED give --claude <dir> and/or --codex <dir> (see --help for the usual folders)")
        return 2
    names = skill_names()
    missing = [n for n in names if not (Path(args.source) / n / "SKILL.md").is_file()]
    if missing:
        print(f"REFUSED skills missing in the factory: {', '.join(missing)}")
        return 2
    commit = factory_commit()
    today = args.today or datetime.date.today().isoformat()
    not_current = 0
    for label, value in targets:
        try:
            dest = check_destination(value)
        except Refused as err:
            print(f"REFUSED {err}")
            return 2
        rows = plan(dest, names, args.source, args.force)
        print(f"{label}: {display(dest)} ({len(names)} game-facing skills, factory {commit[:12] if commit else 'unknown'})")
        for name, state, action in rows:
            verb = {"copy": "copy" if args.apply else "would copy", "skip": "up to date", "keep": "kept (use --force to replace)"}[action]
            print(f"  {name:<34} {state:<10} {verb}")
            if args.apply and action == "copy":
                copy_skill(name, dest, args.source, commit, today)
            if state != "current" and not (args.apply and action == "copy"):
                not_current += 1
    if not args.apply and not args.check:
        print("dry run: nothing written; add --apply to copy")
    if args.check and not_current:
        print(f"{not_current} skill(s) not current; run with --apply")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
