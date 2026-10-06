"""Reusable project starter: scaffold a NEW Roblox game repository outside this factory.

  python3 tools/new_project.py <dest> [--name NAME] [--packages SceneKit ProcGen Pipeline ...]
  python3 tools/new_project.py --update <game-repo> [--packages ...] [--force]

Use it only for an explicit game-build request (AGENTS.md: a game starts in a separate repository).
It copies infrastructure, never game content: the factory packages (default SceneKit, ProcGen,
Pipeline; required packages are added automatically), a Rojo project with empty src/server,
src/client and src/shared, the pinned toolchain, StyLua/Selene configs, the Lune runner with one
starter spec, a trimmed gate, CI, the Claude hooks and settings, the Studio MCP entry, game-repo
AGENTS.md/CLAUDE.md with every game-design field left TBD, and the game-facing skills.
starter.json records the factory commit and a content hash per package.

Refuses a dest inside this repo, inside another git repository, or non-empty (a lone .git, as in
a freshly created empty repository, is allowed). --update replaces packages/<name> in an existing
starter repo with this factory's copy and rewrites starter.json; it refuses when the game repo has
uncommitted changes or a package was edited there (hash differs from starter.json) unless --force.
Runs no git command that writes, and publishes, uploads or buys nothing. Templates live in
templates/starter: a top-level name in DOT_NAMES gains a leading dot, ".tmpl" is stripped (so the
game's AGENTS.md/CLAUDE.md are not loaded as instructions inside the factory), {{NAME}} and
{{CREATED}} are filled in.
"""
import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "templates" / "starter"
PACKAGES = ROOT / "packages"
SKILLS_SRC = ROOT / ".agents" / "skills"
SMOKE_GOLDEN = ROOT / "tests" / "golden" / "studio-smoke.json"
SCHEMA = "starter/1"

# Plans-as-data packages, verified in Lune and Studio. Runtime (commerce, receipts, native UI/audio),
# Creator (Studio inspectors, depends on Runtime) and Diagnostics (network fault queue) are opt-in:
# they are first-pass modules whose Studio halves are only partly re-verified, and whether a game
# has commerce or which UI it uses is a game-build decision.
DEFAULT_PACKAGES = ["SceneKit", "ProcGen", "Pipeline"]
# Skills for working on a game. Not copied: luau-quality (describes the factory gate; the game gate
# is in its AGENTS.md), blender-* (Blender tooling stays in the factory), roblox-research (the
# research records stay in the factory), project-bootstrap (factory only).
SKILLS = [
    "roblox-animation-integration",
    "roblox-asset-intake",
    "roblox-genre-systems",
    "roblox-level-design-review",
    "roblox-luau-testing",
    "roblox-multiplayer-integrity",
    "roblox-performance-pass",
    "roblox-persistence-and-commerce",
    "roblox-procedural-generation",
    "roblox-release-pass",
    "roblox-scene-authoring",
    "roblox-studio-testing",
    "roblox-ui-ux-pass",
    "visual-qa",
]
# Factory files copied verbatim (line endings normalized).
FACTORY_FILES = ["tests/run.luau", "stylua.toml", "selene.toml", "rokit.toml", "tools/sync_skills.py"]
FACTORY_DIRS = ["tools/hooks"]
MCP_SERVERS = ["Roblox_Studio"]
DOT_NAMES = {"gitignore", "gitattributes", "github"}
TEXT_SUFFIXES = {".luau", ".lua", ".py", ".mjs", ".js", ".json", ".md", ".toml", ".yml", ".yaml", ".txt", ".tmpl", ""}
PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,49}$")
# Cross-package requires: string requires ("../ProcGen/Rng") and instance requires (script.Parent.Parent.Runtime).
CROSS_REQUIRE = re.compile(r'require\(\s*"\.\./(\w+)/|script\.Parent\.Parent\.(\w+)')


class Refused(Exception):
    pass


def normalized(path, data):
    return data.replace(b"\r\n", b"\n") if path.suffix in TEXT_SUFFIXES else data


def source_files(src):
    return sorted(p for p in src.rglob("*") if p.is_file() and "__pycache__" not in p.parts)


def tree_hash(path):
    """sha256 over sorted relative paths and LF-normalized contents; same value on Windows and Linux."""
    digest, count = hashlib.sha256(), 0
    for p in source_files(path):
        digest.update(p.relative_to(path).as_posix().encode() + b"\0" + normalized(p, p.read_bytes()) + b"\0")
        count += 1
    return digest.hexdigest(), count


def copy_file(src, dst, values=None):
    data = normalized(src, src.read_bytes())
    if values is not None and src.suffix in TEXT_SUFFIXES:
        text = data.decode("utf-8")
        unknown = sorted({m for m in PLACEHOLDER.findall(text) if m not in values})
        if unknown:
            raise Refused(f"{src.relative_to(ROOT)}: unknown placeholder(s) {unknown}")
        data = PLACEHOLDER.sub(lambda m: values[m.group(1)], text).encode("utf-8")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)


def copy_tree(src, dst):
    for p in source_files(src):
        copy_file(p, dst / p.relative_to(src))


def package_names():
    return sorted(p.name for p in PACKAGES.iterdir() if p.is_dir())


def with_dependencies(requested):
    """Requested packages plus every package they require, transitively (scanned from the source)."""
    known = set(package_names())
    unknown = [n for n in requested if n not in known]
    if unknown:
        raise Refused(f"unknown package(s) {unknown}; available: {sorted(known)}")
    chosen, queue = set(), list(requested)
    while queue:
        name = queue.pop()
        if name in chosen:
            continue
        chosen.add(name)
        for p in source_files(PACKAGES / name):
            for match in CROSS_REQUIRE.finditer(p.read_text(encoding="utf-8")):
                dep = match.group(1) or match.group(2)
                if dep in known and dep != name:
                    queue.append(dep)
    return sorted(chosen)


def git(cwd, *args):
    try:
        proc = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout.strip() if proc.returncode == 0 else None


def factory_info():
    remote = git(ROOT, "remote", "get-url", "origin") or ""
    # Only a plain GitHub URL is recorded (never a local path or a URL carrying credentials).
    match = re.match(r"^(?:https://github\.com/|git@github\.com:)([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", remote)
    return {
        "repository": f"https://github.com/{match.group(1)}/{match.group(2)}" if match else None,
        "commit": git(ROOT, "rev-parse", "HEAD"),
        "packages_dirty": bool(git(ROOT, "status", "--porcelain", "--", "packages")),
    }


def inside(path, parent):
    return path == parent or parent in path.parents


def check_new_dest(dest):
    if inside(dest, ROOT) or inside(ROOT, dest):
        raise Refused(f"{dest} overlaps the factory repo; a game lives in its own repository (AGENTS.md)")
    if dest.exists():
        if not dest.is_dir():
            raise Refused(f"{dest} exists and is not a directory")
        extra = [p.name for p in dest.iterdir() if p.name != ".git"]
        if extra:
            raise Refused(f"{dest} is not empty ({', '.join(sorted(extra)[:5])}); choose a new or empty directory")
    probe = dest
    while not probe.exists():
        probe = probe.parent
    top = git(probe, "rev-parse", "--show-toplevel")
    if top and Path(top).resolve() != dest:
        raise Refused(f"{dest} is inside the git repository {top}; never scaffold into another repo")


def smoke_hashes(packages):
    return json.loads(SMOKE_GOLDEN.read_text(encoding="utf-8")) if "Pipeline" in packages else None


def package_record(packages):
    out = {}
    for name in packages:
        digest, count = tree_hash(PACKAGES / name)
        out[name] = {"sha256": digest, "files": count}
    return out


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def write_claude_settings(dest):
    """The factory's hooks and permissions, minus allow rules for factory-only scripts."""
    settings = json.loads((ROOT / ".claude" / "settings.json").read_text(encoding="utf-8"))
    def present(rule):
        return all((dest / script).exists() for script in re.findall(r"tools/[\w./-]+\.(?:py|mjs)", rule))

    permissions = settings.setdefault("permissions", {})
    permissions["allow"] = [rule for rule in permissions.get("allow", []) if present(rule)]
    write_json(dest / ".claude" / "settings.json", settings)


def write_mcp(dest):
    mcp = json.loads((ROOT / ".mcp.json").read_text(encoding="utf-8"))
    mcp["mcpServers"] = {k: v for k, v in mcp["mcpServers"].items() if k in MCP_SERVERS}
    write_json(dest / ".mcp.json", mcp)


def scaffold(dest, name, requested):
    check_new_dest(dest)
    created = not dest.exists()
    try:
        return write_starter_repo(dest, name, requested)
    except BaseException:
        if created:  # leave nothing half-written behind
            shutil.rmtree(dest, ignore_errors=True)
        raise


def write_starter_repo(dest, name, requested):
    packages = with_dependencies(requested)
    added = sorted(set(packages) - set(requested))
    missing_skills = [s for s in SKILLS if not (SKILLS_SRC / s / "SKILL.md").exists()]
    if missing_skills:
        raise Refused(f"skills missing in the factory: {missing_skills}")
    today = datetime.date.today().isoformat()
    values = {"NAME": name, "CREATED": today}
    dest.mkdir(parents=True, exist_ok=True)

    for src in source_files(TEMPLATE):
        parts = list(src.relative_to(TEMPLATE).parts)
        if parts[0] in DOT_NAMES:
            parts[0] = "." + parts[0]
        parts[-1] = parts[-1].removesuffix(".tmpl")
        copy_file(src, dest.joinpath(*parts), values)
    for rel in FACTORY_FILES:
        copy_file(ROOT / rel, dest / rel)
    rokit = dest / "rokit.toml"
    pins = [line for line in rokit.read_text(encoding="utf-8").splitlines() if not line.startswith("#")]
    rokit.write_text("# Toolchain pins copied from the factory (commit in starter.json).\n" + "\n".join(pins) + "\n")
    for rel in FACTORY_DIRS:
        copy_tree(ROOT / rel, dest / rel)
    write_claude_settings(dest)
    write_mcp(dest)
    for pkg in packages:
        copy_tree(PACKAGES / pkg, dest / "packages" / pkg)
    for skill in SKILLS:
        copy_tree(SKILLS_SRC / skill, dest / ".agents" / "skills" / skill)
    sync = subprocess.run([sys.executable, "tools/sync_skills.py"], cwd=dest, capture_output=True, text=True)
    if sync.returncode != 0:
        raise Refused(f"skill sync failed in {dest}: {sync.stdout}{sync.stderr}")

    starter = {
        "schema": SCHEMA,
        "name": name,
        "created": today,
        "factory": factory_info(),
        "packages": package_record(packages),
        "skills": SKILLS,
    }
    smoke = smoke_hashes(packages)
    if smoke is not None:
        starter["smoke"] = smoke
    write_json(dest / "starter.json", starter)

    print(f"scaffolded {name} at {dest}")
    print(f"  packages: {', '.join(packages)}" + (f" (added as dependencies: {', '.join(added)})" if added else ""))
    print(f"  skills: {len(SKILLS)}; factory commit: {starter['factory']['commit'] or 'unknown'}")
    if starter["factory"]["packages_dirty"]:
        print("  note: the factory's packages/ has uncommitted changes; the hashes describe the working tree")
    print("next: cd into it, `rokit install`, `python3 tools/check.py`, then git init and commit.")
    print("Fill the TBD game decisions in AGENTS.md from the game-build request; log them in docs/decisions.md.")
    return 0


def update(dest, requested, force):
    if inside(dest, ROOT) or inside(ROOT, dest):
        raise Refused(f"{dest} overlaps the factory repo")
    path = dest / "starter.json"
    if not path.exists():
        raise Refused(f"{dest} has no starter.json; --update only works on a repo created by this starter")
    starter = json.loads(path.read_text(encoding="utf-8"))
    if starter.get("schema") != SCHEMA:
        raise Refused(f"{path}: schema {starter.get('schema')!r}, expected {SCHEMA!r}")
    if git(dest, "rev-parse", "--git-dir") is None:
        print(f"  note: {dest} is not a git repository, so the update cannot be reviewed with git diff")
    elif git(dest, "status", "--porcelain") and not force:
        raise Refused(f"{dest} has uncommitted changes; commit them, switch to a new branch, then update")
    recorded = starter.get("packages", {})
    packages = with_dependencies(requested or sorted(recorded))
    edited = [p for p in packages if p in recorded and (dest / "packages" / p).exists()
              and tree_hash(dest / "packages" / p)[0] != recorded[p]["sha256"]]
    unrecorded = [p for p in packages if p not in recorded and (dest / "packages" / p).exists()]
    if (edited or unrecorded) and not force:
        why = [f"edited here since the last scaffold/update: {edited}"] if edited else []
        why += [f"present but not in starter.json: {unrecorded}"] if unrecorded else []
        raise Refused("; ".join(why) + ". Move game changes out of packages/ or pass --force to overwrite.")

    fresh = package_record(packages)
    for pkg in packages:
        target = dest / "packages" / pkg
        old = recorded.get(pkg, {}).get("sha256")
        current = tree_hash(target)[0] if target.exists() else None
        if old == fresh[pkg]["sha256"] and current == old:
            print(f"  {pkg}: unchanged")
            continue
        if target.exists():
            shutil.rmtree(target)
        copy_tree(PACKAGES / pkg, target)
        print(f"  {pkg}: {'updated' if old else 'added'} {(old or '-')[:12]} -> {fresh[pkg]['sha256'][:12]}")
    recorded.update(fresh)
    starter["packages"] = dict(sorted(recorded.items()))
    starter["factory"] = factory_info()
    starter["updated"] = datetime.date.today().isoformat()
    smoke = smoke_hashes(starter["packages"])
    if smoke is not None:
        starter["smoke"] = smoke
    write_json(path, starter)
    print(f"updated {path}; review with `git diff` in {dest}, then run python3 tools/check.py there")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dest", help="new repository directory, or the game repo with --update")
    ap.add_argument("--name", help="project name (default: the dest folder name)")
    ap.add_argument("--packages", nargs="+", help=f"factory packages to copy (default: {' '.join(DEFAULT_PACKAGES)})")
    ap.add_argument("--update", action="store_true", help="refresh packages/ in an existing starter repo")
    ap.add_argument("--force", action="store_true", help="with --update: overwrite edited packages / dirty tree")
    args = ap.parse_args()
    dest = Path(args.dest).expanduser().resolve()
    try:
        if args.update:
            return update(dest, args.packages, args.force)
        if args.force:
            raise Refused("--force only applies to --update")
        name = args.name or dest.name
        if not NAME_RE.match(name):
            raise Refused(f"name {name!r} must match {NAME_RE.pattern}; pass --name")
        return scaffold(dest, name, args.packages or DEFAULT_PACKAGES)
    except Refused as err:
        print(f"refused: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
