"""Reusable project starter: scaffold a NEW Roblox game repository outside this factory.

  python3 tools/new_project.py <dest> [--name NAME] [--packages PKG ...] [--deps BUNDLE ...]
  python3 tools/new_project.py --out <dest> ...          (same as the positional dest)
  python3 tools/new_project.py --update <game-repo> [--packages PKG ...] [--deps BUNDLE ...] [--force]
  python3 tools/new_project.py --list                    (package classes, dependency bundles, skills)

Use it only for an explicit game-build request (AGENTS.md: a game starts in a separate repository).
It copies infrastructure, never game content:
- factory packages in factory/<Pkg> (the factory itself keeps packages/; a game repo never uses that
  name: `wally install` first deletes Packages/, ServerPackages/ and DevPackages/, and on Windows NTFS
  and macOS APFS Packages/ is packages/), by class: authoring (SceneKit, ProcGen, Pipeline; Rojo
  ServerStorage.Authoring, never replicated), kits (GameKit, UIKit, Feel, Cinematics, AVKit;
  ReplicatedStorage.Kits, plus the leaf copies Kits/ProcGen/{Rng,Grid,Graph} and
  Kits/SceneKit/{Vec,Lighting}, the same files mapped a second time so the kits' "../ProcGen/Rng"
  requires resolve) and legacy opt-in (Runtime, Creator, Diagnostics; ReplicatedStorage.Kits beside the
  kits, whose modules they require). Default: DEFAULT_PACKAGES; packages they require are added;
- a phased boot skeleton (src/shared/Boot.luau runs config, kits, data, remotes, telemetry, ui, input
  with a timeout per phase), a loading screen, every Config field TBD, and specs for boot, layout and
  packages;
- the game gate (tools/check.py: fast, pre-commit, pre-release), the release checker
  (tools/release_check.py: automated A-checks, owner items that never pass on their own), the
  production pipeline (production/brief.json game-brief/1, production/pipeline.json, design prompts,
  issue templates, tools/production.py status, tools/plan_issues.py), CI, the Claude and Codex hooks
  and settings, the Studio MCP entry, game-repo AGENTS.md/CLAUDE.md with every game-design and engine
  field TBD, the game-facing skills, and the dependency allowlist deps.json.
--deps BUNDLE (persistence, studio-tests, networking; templates/starter/deps.json) writes exact pins:
wally.toml (private = true, `=` requirements), THIRD_PARTY_NOTICES.md and rokit.toml tool pins. It
never runs `wally install` (that downloads code); it prints the owner's command instead.
starter.json (starter/2) records the factory commit, each package's class and sha256, every module's
tier and probes (`probe` keeps the first for starter/2 readers) parsed from its `-- @tier` header, the
pending Studio probes, each skill's sha256, the sha256 of every factory-managed file, the dependency
bundles and the smoke hashes. Package and module names in it are relative to factory/ (to packages/ in
repos made before the move), and the game gate reads "patched" keys as factory/<Pkg>.

Refuses a dest inside this repo, inside another git repository, or non-empty (a lone .git, as in a
freshly created empty repository, is allowed). --update refreshes the factory-managed parts of an
existing starter repo and preserves user files: factory/, the copied skills, tools/hooks and the
other managed files (MANAGED_TEMPLATES, FACTORY_FILES, generated settings) are replaced; the package
nodes of default.project.json and the tool pins of rokit.toml are merged; template files the repo
lacks are added; everything else is left alone. A repo that still keeps the packages in packages/
(starter/1, earlier starter/2) has that folder moved to factory/, and default.project.json paths into
a factory package (packages/<Pkg>/...) move with it. It refuses when the repo has uncommitted changes,
when a package, skill or managed file was edited there (its sha256 differs from starter.json) or when
packages/ holds entries starter.json does not record, unless --force; it always refuses to move
packages/ onto a factory/ that has content. Runs no git command that writes (the move is a plain
rename), and publishes, uploads, installs or buys nothing.
Templates live in templates/starter: a top-level name in DOT_NAMES gains a leading dot, ".tmpl" is
stripped (so the game's AGENTS.md/CLAUDE.md are not loaded as instructions inside the factory),
{{NAME}} and {{CREATED}} are filled in.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "templates" / "starter"
PACKAGES = ROOT / "packages"
# Where a game repo keeps the factory packages. Not packages/: Wally 0.3.2's `wally install` first
# deletes Packages/ (src/installation.rs clean), which is packages/ on Windows NTFS and macOS APFS.
FACTORY_DIR = "factory"
OLD_FACTORY_DIR = "packages"  # starter/1 and earlier starter/2 repos; --update moves it to FACTORY_DIR
SKILLS_SRC = ROOT / ".agents" / "skills"
SMOKE_GOLDEN = ROOT / "tests" / "golden" / "studio-smoke.json"
DEPS_FILE = TEMPLATE / "deps.json"
SCHEMA = "starter/2"
READABLE_SCHEMAS = {"starter/1", SCHEMA}

# Package classes and where each class lives in the game's Rojo tree. Authoring code (plans as data,
# generators, import checks) runs on the server or in Studio only, so it sits in ServerStorage, which
# does not replicate. Runtime kits replicate (both sides require them). Legacy first-pass modules
# require kits ("../GameKit/Env", the AVKit and UIKit shims) and each other, so they sit beside the
# kits in one folder: every relative require resolves and each module exists once.
PACKAGE_CLASSES = {
    "authoring": ["SceneKit", "ProcGen", "Pipeline"],
    "kits": ["GameKit", "UIKit", "Feel", "Cinematics", "AVKit"],
    "legacy": ["Runtime", "Creator", "Diagnostics"],
}
CLASS_OF = {pkg: cls for cls, pkgs in PACKAGE_CLASSES.items() for pkg in pkgs}
ROJO_HOME = {
    "authoring": ("ServerStorage", "Authoring"),
    "kits": ("ReplicatedStorage", "Kits"),
    "legacy": ("ReplicatedStorage", "Kits"),
}
# starter/2 repos made before the legacy packages moved next to the kits; --update removes the folder.
OLD_LEGACY_HOME = ("ReplicatedStorage", "Legacy")
# Require-free leaf modules the kits may require (docs/runtime-kits.md section 8); mapped a second
# time under ReplicatedStorage.Kits when a kit is installed.
LEAVES = {"ProcGen": ["Rng", "Grid", "Graph"], "SceneKit": ["Vec", "Lighting"]}
# Default packages: authoring plus the five runtime kits; legacy packages are opt-in with --packages.
DEFAULT_PACKAGES = ["SceneKit", "ProcGen", "Pipeline", "GameKit", "UIKit", "Feel", "Cinematics", "AVKit"]
# Legacy modules that use `script`, `game` or Roblox datatypes while loading (no @tier header); the
# game's tests/packages.spec.luau loads every other module except *Roblox adapters.
LEGACY_ROBLOX_ONLY = {"Creator/Effects", "Creator/Observation"}  # Runtime/NativeUI loads in Lune since UIKit (env injection)
# Skills for working on a game. Not copied: luau-quality (describes the factory gate; the game gate
# is in its AGENTS.md), blender-* (Blender tooling stays in the factory), roblox-research (the
# research records stay in the factory), project-bootstrap (factory only).
SKILLS = [
    "roblox-animation-integration",
    "roblox-asset-intake",
    "roblox-gameplay-kit",
    "roblox-genre-systems",
    "roblox-level-design-review",
    "roblox-luau-testing",
    "roblox-multiplayer-integrity",
    "roblox-performance-pass",
    "roblox-persistence-and-commerce",
    "roblox-presentation-pass",
    "roblox-procedural-generation",
    "roblox-production-pipeline",
    "roblox-release-pass",
    "roblox-scene-authoring",
    "roblox-studio-testing",
    "roblox-ui-ux-pass",
    "visual-qa",
]
# Factory files copied verbatim (line endings normalized) and refreshed by --update.
FACTORY_FILES = ["tests/run.luau", "stylua.toml", "selene.toml", "tools/sync_skills.py"]
FACTORY_DIRS = ["tools/hooks"]
CODEX_FILES = [".codex/hooks.json", ".codex/rules/factory.rules"]
# Template files that are infrastructure, not game content: --update refreshes them (paths in the game repo).
MANAGED_TEMPLATES = [
    "deps.json",
    "tools/check.py",
    "tools/release_check.py",
    "tools/production.py",
    "tools/plan_issues.py",
    "tests/boot.spec.luau",
    "tests/layout.spec.luau",
    "tests/packages.spec.luau",
    "src/shared/Boot.luau",
    "src/shared/KitLoader.luau",
    "docs/release-runbook.md",
    ".github/workflows/ci.yml",
]
# Written at scaffold, merged (not replaced) by --update.
MERGED = {"default.project.json"}
MCP_SERVERS = ["Roblox_Studio"]
DOT_NAMES = {"gitignore", "gitattributes", "github"}
TEXT_SUFFIXES = {".luau", ".lua", ".py", ".mjs", ".js", ".json", ".md", ".toml", ".yml", ".yaml", ".txt", ".tmpl", ".csv", ""}
PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,49}$")
# Cross-package requires: string requires ("../ProcGen/Rng") and instance requires (script.Parent.Parent.Runtime).
CROSS_REQUIRE = re.compile(r'require\(\s*"\.\./(\w+)/|script\.Parent\.Parent\.(\w+)')
TIER_RE = re.compile(r"^--\s*@tier\s+(T[0-4])\b")
PROBE_RE = re.compile(r"^--\s*probe:\s*([a-z][a-z0-9_]*)")
ROKIT_LINE = re.compile(r'^\s*([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"\s*$')


class Refused(Exception):
    pass


# ---- files and hashes

def normalized(path, data):
    return data.replace(b"\r\n", b"\n") if Path(path).suffix in TEXT_SUFFIXES else data


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    return sha(normalized(path, path.read_bytes())) if path.is_file() else None


def source_files(src):
    return sorted(p for p in src.rglob("*") if p.is_file() and "__pycache__" not in p.parts)


def tree_hash(path):
    """sha256 over sorted relative paths and LF-normalized contents; same value on Windows and Linux."""
    digest, count = hashlib.sha256(), 0
    for p in source_files(path):
        digest.update(p.relative_to(path).as_posix().encode() + b"\0" + normalized(p, p.read_bytes()) + b"\0")
        count += 1
    return digest.hexdigest(), count


def render(src, values=None):
    """A template or factory file's bytes: LF endings, placeholders filled when values are given."""
    data = normalized(src, src.read_bytes())
    if values is not None and src.suffix in TEXT_SUFFIXES:
        text = data.decode("utf-8")
        unknown = sorted({m for m in PLACEHOLDER.findall(text) if m not in values})
        if unknown:
            raise Refused(f"{src.relative_to(ROOT)}: unknown placeholder(s) {unknown}")
        data = PLACEHOLDER.sub(lambda m: values[m.group(1)], text).encode("utf-8")
    return data


def write_bytes(dst, data):
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)


def copy_tree(src, dst):
    for p in source_files(src):
        write_bytes(dst / p.relative_to(src), normalized(p, p.read_bytes()))


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def json_bytes(data):
    return (json.dumps(data, indent=2) + "\n").encode("utf-8")


def template_dest(src):
    """Path in the game repo for a template file."""
    parts = list(src.relative_to(TEMPLATE).parts)
    if parts[0] in DOT_NAMES:
        parts[0] = "." + parts[0]
    parts[-1] = parts[-1].removesuffix(".tmpl")
    return "/".join(parts)


def template_files():
    """{repo path: template source} for every template file."""
    return {template_dest(p): p for p in source_files(TEMPLATE)}


# ---- packages, classes and module tiers

def package_names():
    return sorted(p.name for p in PACKAGES.iterdir() if p.is_dir())


def with_dependencies(requested):
    """Requested packages plus every package they require, transitively (scanned from the source)."""
    known = set(package_names())
    unknown = [n for n in requested if n not in known]
    if unknown:
        raise Refused(f"unknown package(s) {unknown}; available: {sorted(known)}")
    unclassified = sorted(n for n in known if n not in CLASS_OF)
    if unclassified:
        raise Refused(f"packages/{unclassified} have no class; add them to PACKAGE_CLASSES in tools/new_project.py")
    chosen, queue = set(), list(requested)
    while queue:
        name = queue.pop()
        if name in chosen:
            continue
        chosen.add(name)
        for p in source_files(PACKAGES / name):
            if p.suffix != ".luau":
                continue
            for match in CROSS_REQUIRE.finditer(p.read_text(encoding="utf-8")):
                dep = match.group(1) or match.group(2)
                if dep in known and dep != name:
                    queue.append(dep)
    return sorted(chosen)


def module_header(text):
    """(tier, probes) from the comment block after `--!strict` (docs/runtime-kits.md section 5): probes lists
    every `-- probe:` line in order (a module may name several, like AVKit/AudioGraphRoblox)."""
    lines = text.splitlines()
    index = 1 if lines and lines[0].startswith("--!") else 0
    tier, probes = None, []
    while index < len(lines) and lines[index].startswith("--"):
        tier = tier or (TIER_RE.match(lines[index]) or [None, None])[1]
        probe = (PROBE_RE.match(lines[index]) or [None, None])[1]
        if probe and probe not in probes:
            probes.append(probe)
        index += 1
    return tier, probes


def module_records(folder, packages):
    """{Pkg/Module: {class, tier, lune, probe?, probes?}} for every .luau module of the given packages under
    folder (a game repo's factory/, or the factory's packages/). probes lists every probe the header names;
    probe (the first) stays for starter/2 readers."""
    records = {}
    for pkg in packages:
        base = folder / pkg
        for path in sorted(base.rglob("*.luau")):
            name = f"{pkg}/{path.relative_to(base).with_suffix('').as_posix()}"
            tier, probes = module_header(path.read_text(encoding="utf-8"))
            adapter = name.rsplit("/", 1)[-1].endswith("Roblox")
            # Cores load in Lune whatever their tier (the factory's kits_load contract); engine
            # adapters (*Roblox) and the legacy Roblox-only modules never do.
            lune = not adapter and name not in LEGACY_ROBLOX_ONLY
            record = {"class": CLASS_OF[pkg], "tier": tier, "lune": lune}
            if probes:
                record["probe"] = probes[0]
                record["probes"] = probes
            records[name] = record
    return records


def tier_summary(modules):
    counts = {}
    for record in modules.values():
        key = record["tier"] or "untiered"
        counts[key] = counts.get(key, 0) + 1
    pending = sorted(
        ({"probe": probe, "module": name} for name, r in modules.items() if r["tier"] in ("T3", "T4") for probe in r.get("probes", [])),
        key=lambda item: (item["probe"], item["module"]),
    )
    return dict(sorted(counts.items())), pending


def package_record(packages):
    out = {}
    for name in packages:
        digest, count = tree_hash(PACKAGES / name)
        out[name] = {"sha256": digest, "files": count, "class": CLASS_OF[name]}
    return out


def package_nodes(packages, root):
    """Rojo children per class for the installed packages (paths relative to the game repo)."""
    nodes = {cls: {} for cls in PACKAGE_CLASSES}
    for pkg in sorted(packages):
        nodes[CLASS_OF[pkg]][pkg] = {"$path": f"{FACTORY_DIR}/{pkg}"}
    if nodes["kits"] or nodes["legacy"]:
        for leaf_pkg, modules in LEAVES.items():
            present = [m for m in modules if (root / FACTORY_DIR / leaf_pkg / f"{m}.luau").is_file()]
            if leaf_pkg in packages and present:
                folder = {"$className": "Folder"}
                for module in present:
                    folder[module] = {"$path": f"{FACTORY_DIR}/{leaf_pkg}/{module}.luau"}
                nodes["kits"][leaf_pkg] = folder
    return nodes


NOTE_SUFFIXES = {".luau", ".lua", ".md", ".json", ".toml", ".py", ".yml", ".yaml", ".csv", ".txt"}
NOTE_SKIP = {".git", FACTORY_DIR, "build", "node_modules", "Packages", "ServerPackages", "DevPackages"}


def user_files_naming(dest, text):
    """Relative paths of the game's own text files (not factory/, .git, build or Wally folders) that contain text."""
    found = []
    for root, dirs, files in os.walk(dest):
        dirs[:] = sorted(d for d in dirs if d not in NOTE_SKIP)
        for name in sorted(files):
            path = Path(root) / name
            if path.suffix in NOTE_SUFFIXES:
                try:
                    if text in path.read_text(encoding="utf-8"):
                        found.append(path.relative_to(dest))
                except (OSError, UnicodeDecodeError):
                    continue
    return found


def apply_package_nodes(project, packages, root):
    """Rewrite the factory-managed package folders of a Rojo project in place; returns a list of notes."""
    tree = project.setdefault("tree", {"$className": "DataModel"})
    notes = []
    replicated = tree.get("ReplicatedStorage", {})
    workbench = replicated.get("Workbench") if isinstance(replicated, dict) else None
    if isinstance(workbench, dict) and workbench.get("$path") == "packages":
        del replicated["Workbench"]  # starter/1 layout: every package replicated to clients
        notes.append("removed ReplicatedStorage.Workbench (starter/1); packages now map by class")
    if isinstance(replicated, dict) and replicated.get("Packages") == {"$path": {"optional": "Packages"}}:
        del replicated["Packages"]  # an earlier template's Wally shared folder; shared-realm dependencies are refused
        notes.append("removed ReplicatedStorage.Packages (shared-realm Wally dependencies are refused)")
    old_service, old_folder = OLD_LEGACY_HOME
    old = tree.get(old_service, {}).get(old_folder) if isinstance(tree.get(old_service), dict) else None
    if isinstance(old, dict) and all(isinstance(v, dict) and str(v.get("$path", "")).startswith((f"{OLD_FACTORY_DIR}/", f"{FACTORY_DIR}/"))
                                     for k, v in old.items() if not k.startswith("$")):
        del tree[old_service][old_folder]
        notes.append("removed ReplicatedStorage.Legacy; legacy packages now sit beside the kits in ReplicatedStorage.Kits")
    homes = {}
    for cls, children in package_nodes(packages, root).items():
        homes.setdefault(ROJO_HOME[cls], {}).update(children)
    for (service, folder), children in homes.items():
        node = tree.setdefault(service, {})
        if children:
            node[folder] = {"$className": "Folder", **children}
        elif folder in node:
            del node[folder]
    return notes


def move_rojo_paths(node, packages):
    """Rewrite every $path (string or optional) into a factory package, packages/<Pkg>/..., to factory/ in
    place; returns how many moved."""
    if not isinstance(node, dict):
        return 0
    count = 0
    raw = node.get("$path")
    inner = raw.get("optional") if isinstance(raw, dict) else raw
    parts = inner.replace("\\", "/").split("/") if isinstance(inner, str) else []
    if len(parts) > 1 and parts[0] == OLD_FACTORY_DIR and parts[1] in packages:
        moved = "/".join([FACTORY_DIR] + parts[1:])
        node["$path"] = {**raw, "optional": moved} if isinstance(raw, dict) else moved
        count += 1
    for key, child in node.items():
        if not key.startswith("$"):
            count += move_rojo_paths(child, packages)
    return count


def has_entry(directory, name):
    """True when directory holds an entry named exactly name (Path.exists folds case on Windows and macOS)."""
    return directory.is_dir() and name in {p.name for p in directory.iterdir()}


# ---- dependency bundles (templates/starter/deps.json)

def load_deps():
    return json.loads(DEPS_FILE.read_text(encoding="utf-8"))


def check_bundles(bundles, deps):
    unknown = sorted(set(bundles) - set(deps["bundles"]))
    if unknown:
        raise Refused(f"unknown dependency bundle(s) {unknown}; available: {sorted(deps['bundles'])}")
    shared = [n for n in bundle_packages(sorted(set(bundles)), deps) if deps["packages"][n]["realm"] == "shared"]
    if shared:
        raise Refused(f"{shared}: shared-realm Wally dependencies (Packages/) are refused: they replicate to clients, and the "
                      "starter maps no Wally folder into a replicated service (release check A01); see the deps.json policy")
    return sorted(set(bundles))


def bundle_packages(bundles, deps):
    names = []
    for bundle in bundles:
        names += [n for n in deps["bundles"][bundle]["packages"] if n not in names]
    return names


def bundle_tools(bundles, deps):
    tools = []
    for bundle in bundles:
        tools += [t for t in deps["bundles"][bundle]["tools"] if t not in tools]
    return tools


def wally_slug(name):
    slug = re.sub(r"[^a-z0-9-]+", "-", name.lower().replace("_", "-")).strip("-")
    return slug or "game"


def wally_entry(name, deps):
    entry = deps["packages"][name]
    return entry["alias"], f'{name}@={entry["version"]}', deps["wally"]["tables"][entry["realm"]]


def wally_text(name, packages, deps):
    tables = {t: [] for t in ("dependencies", "server-dependencies", "dev-dependencies")}
    for pkg in packages:
        alias, spec, table = wally_entry(pkg, deps)
        tables[table].append(f'{alias} = "{spec}"')
    lines = [
        "# Wally manifest written by the factory starter (tools/new_project.py --deps).",
        "# Pins come from deps.json, the allowlist: exact versions (`=x.y.z`). The gate step `deps` refuses",
        "# anything else, and wally.lock must be committed. private = true keeps this package off the registry.",
        "# `wally install` downloads code: the owner runs it, then commits wally.lock.",
        "[package]",
        f'name = "local/{wally_slug(name)}"',
        'version = "0.1.0"',
        f'registry = "{deps["wally"]["registry"]}"',
        'realm = "shared"',
        "private = true",
    ]
    for table, entries in tables.items():
        lines += ["", f"[{table}]"] + entries
    return "\n".join(lines) + "\n"


def merge_wally(text, packages, deps, force):
    """Add bundle entries to an existing wally.toml; refuses to change a different existing pin unless force."""
    lines = text.splitlines()
    for pkg in packages:
        alias, spec, table = wally_entry(pkg, deps)
        owner = [i for i, line in enumerate(lines) if re.search(rf'"{re.escape(pkg)}@', line)]
        if owner:
            current = lines[owner[0]].split("=", 1)[1].strip().strip('"')
            if current != spec:
                if not force:
                    raise Refused(f"wally.toml pins {current}; deps.json says {spec}. Pass --force to rewrite the pin.")
                lines[owner[0]] = f'{alias} = "{spec}"'
            continue
        header = f"[{table}]"
        if header not in lines:
            lines += ["", header]
        lines.insert(lines.index(header) + 1, f'{alias} = "{spec}"')
    return "\n".join(lines) + "\n"


def notices_text(name, bundles, deps):
    lines = [
        "# Third-party notices",
        "",
        f"Dependencies of {name} that come from outside the factory, pinned in `wally.toml` and `rokit.toml` from the allowlist",
        "`deps.json` (bundles: " + ", ".join(bundles) + "). Generated by the factory starter; `python3 tools/check.py` (step `deps`)",
        "checks that every Wally dependency is listed here with its licence.",
        "",
        "## Packages (Wally)",
        "",
        "| Package | Version | Realm | Licence | Source |",
        "|---|---|---|---|---|",
    ]
    packages = bundle_packages(bundles, deps)
    for pkg in packages:
        entry = deps["packages"][pkg]
        lines.append(f"| `{pkg}` | {entry['version']} | {entry['realm']} | {entry['license']} | {entry['source']} |")
    if not packages:
        lines.append("| (none) | | | | |")
    for pkg in packages:
        entry = deps["packages"][pkg]
        lines += ["", f"### {pkg} {entry['version']}", "", entry["attribution"] + ".", "", entry["notice"]]
    scopes = [(s, v) for s, v in deps.get("transitive_scopes", {}).items() if v["bundle"] in bundles]
    for scope, entry in scopes:
        lines += ["", f"Transitive `{scope}/*` packages ({entry['license']}): {entry['why']}"]
    lines += ["", "## Tools (rokit.toml; not shipped in the place)", "", "| Tool | Pin | Licence | Source |", "|---|---|---|---|"]
    for tool in bundle_tools(bundles, deps):
        entry = deps["tools"][tool]
        lines.append(f"| {tool} | `{entry['pin']}` | {entry['license']} | {entry['source']} |")
    return "\n".join(lines) + "\n"


def studio_tests_project(project):
    """studio-tests.project.json: the game tree plus DevPackages and the Jest specs in tests/studio."""
    tree = json.loads(json.dumps(project))
    tree["name"] = f"{project.get('name', 'game')}-studio-tests"
    storage = tree["tree"].setdefault("ServerStorage", {})
    storage["DevPackages"] = {"$path": {"optional": "DevPackages"}}
    storage["StudioTests"] = {"$path": "tests/studio"}
    return tree


# ---- rokit.toml (factory pins plus bundle tools; merged so the game's own tools survive)

def factory_pins():
    pins, in_tools = {}, False
    for line in (ROOT / "rokit.toml").read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("["):
            in_tools = line.strip() == "[tools]"
            continue
        match = ROKIT_LINE.match(line)
        if in_tools and match:
            pins[match.group(1)] = match.group(2)
    return pins


def wanted_pins(bundles, deps):
    pins = factory_pins()
    for tool in bundle_tools(bundles, deps):
        pins[tool] = deps["tools"][tool]["pin"]
    return pins


def rokit_text(existing, pins):
    """rokit.toml with every key in pins set to its pin; other lines (the game's own tools) kept."""
    header = "# Toolchain pins: the factory's (commit in starter.json) plus dependency-bundle tools. Rokit 1.2+.\n"
    if existing is None:
        return header + "[tools]\n" + "".join(f'{k} = "{v}"\n' for k, v in pins.items())
    lines, seen, in_tools, tools_at = existing.splitlines(), set(), False, None
    for i, line in enumerate(lines):
        if line.strip().startswith("["):
            in_tools = line.strip() == "[tools]"
            tools_at = i if in_tools else tools_at
            continue
        match = ROKIT_LINE.match(line)
        if in_tools and match and match.group(1) in pins:
            lines[i] = f'{match.group(1)} = "{pins[match.group(1)]}"'
            seen.add(match.group(1))
    missing = [f'{k} = "{v}"' for k, v in pins.items() if k not in seen]
    if tools_at is None:
        lines += ["[tools]"] + missing
    else:
        end = tools_at + 1
        while end < len(lines) and not lines[end].strip().startswith("["):
            end += 1
        while end > tools_at + 1 and not lines[end - 1].strip():
            end -= 1
        lines[end:end] = missing
    return "\n".join(lines).rstrip("\n") + "\n"


# ---- generated agent configuration

def claude_settings(present):
    """The factory's hooks and permissions, minus allow rules for scripts the game repo does not have."""
    settings = json.loads((ROOT / ".claude" / "settings.json").read_text(encoding="utf-8"))

    def keep(rule):
        return all(present(script) for script in re.findall(r"tools/[\w./-]+\.(?:py|mjs)", rule))

    permissions = settings.setdefault("permissions", {})
    permissions["allow"] = [rule for rule in permissions.get("allow", []) if keep(rule)]
    return json_bytes(settings)


def mcp_config():
    mcp = json.loads((ROOT / ".mcp.json").read_text(encoding="utf-8"))
    mcp["mcpServers"] = {k: v for k, v in mcp["mcpServers"].items() if k in MCP_SERVERS}
    return json_bytes(mcp)


def codex_config():
    """The factory's .codex/config.toml with only MCP_SERVERS."""
    kept, pending, keep = [], [], True
    for line in (ROOT / ".codex" / "config.toml").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            pending.append(line)  # comments and blank lines belong to the table that follows them
            continue
        if line.startswith("["):
            server = re.match(r"\[mcp_servers\.([\w-]+)", line)
            keep = not server or server.group(1) in MCP_SERVERS
        if keep:
            kept += pending + [line]
        pending = []
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(kept + pending)).rstrip("\n") + "\n"
    return text.encode("utf-8")


def managed_files(values, bundles, deps, planned):
    """{repo path: bytes} of every factory-managed file (refreshed by --update, hashed in starter.json)."""
    out = {}
    for rel in FACTORY_FILES + CODEX_FILES:
        out[rel] = render(ROOT / rel)
    for rel in FACTORY_DIRS:
        for p in source_files(ROOT / rel):
            out[p.relative_to(ROOT).as_posix()] = render(p)
    templates = template_files()
    missing = [rel for rel in MANAGED_TEMPLATES if rel not in templates]
    if missing:
        raise Refused(f"managed template file(s) missing in templates/starter: {missing}")
    for rel in MANAGED_TEMPLATES:
        out[rel] = render(templates[rel], values)
    out[".mcp.json"] = mcp_config()
    out[".codex/config.toml"] = codex_config()
    names = set(out) | set(planned)
    out[".claude/settings.json"] = claude_settings(lambda script: script in names)
    if bundle_packages(bundles, deps):
        out["THIRD_PARTY_NOTICES.md"] = notices_text(values["NAME"], bundles, deps).encode("utf-8")
    return dict(sorted(out.items()))


# ---- git and destination checks

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
        "packages_dirty": bool(git(ROOT, "status", "--porcelain", "--", "packages", "templates/starter")),
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


def skill_record(skills):
    missing = [s for s in skills if not (SKILLS_SRC / s / "SKILL.md").exists()]
    if missing:
        raise Refused(f"skills missing in the factory: {missing}")
    out = {}
    for skill in skills:
        digest, count = tree_hash(SKILLS_SRC / skill)
        out[skill] = {"sha256": digest, "files": count}
    return out


def sync_skills(dest):
    sync = subprocess.run([sys.executable, "tools/sync_skills.py"], cwd=dest, capture_output=True, text=True)
    if sync.returncode != 0:
        raise Refused(f"skill sync failed in {dest}: {sync.stdout}{sync.stderr}")


def starter_record(dest, name, created, packages, bundles, managed):
    modules = module_records(dest / FACTORY_DIR, packages)
    tiers, pending = tier_summary(modules)
    starter = {
        "schema": SCHEMA,
        "name": name,
        "created": created,
        "factory": factory_info(),
        "packages": package_record(packages),
        "modules": modules,
        "tiers": tiers,
        "pending_probes": pending,
        "skills": skill_record(SKILLS),
        "managed": {rel: sha(data) for rel, data in managed.items()},
        "deps": {"bundles": bundles},
    }
    smoke = smoke_hashes(packages)
    if smoke is not None:
        starter["smoke"] = smoke
    return starter


def owner_dep_steps(bundles, deps):
    steps = []
    if bundle_packages(bundles, deps):
        steps.append("review deps.json and wally.toml, then run `rokit install` and `wally install` yourself (downloads code), and commit wally.lock")
    if "networking" in bundles:
        steps.append("put Blink schemas in net/*.blink; the gate step `blink` compiles them")
    return steps


# ---- scaffold

def scaffold(dest, name, requested, bundles):
    check_new_dest(dest)
    created = not dest.exists()
    try:
        return write_starter_repo(dest, name, requested, bundles)
    except BaseException:
        if created:  # leave nothing half-written behind
            shutil.rmtree(dest, ignore_errors=True)
        raise


def write_starter_repo(dest, name, requested, bundles):
    deps = load_deps()
    bundles = check_bundles(bundles, deps)
    packages = with_dependencies(requested)
    added = sorted(set(packages) - set(requested))
    today = datetime.date.today().isoformat()
    values = {"NAME": name, "CREATED": today}
    dest.mkdir(parents=True, exist_ok=True)

    templates = template_files()
    user_files = {rel: src for rel, src in templates.items() if rel not in MANAGED_TEMPLATES and rel not in MERGED}
    managed = managed_files(values, bundles, deps, set(templates))
    for rel, src in user_files.items():
        write_bytes(dest / rel, render(src, values))
    for rel, data in managed.items():
        write_bytes(dest / rel, data)
    for pkg in packages:
        copy_tree(PACKAGES / pkg, dest / FACTORY_DIR / pkg)
    for skill in SKILLS:
        copy_tree(SKILLS_SRC / skill, dest / ".agents" / "skills" / skill)
    sync_skills(dest)

    project = json.loads(render(templates["default.project.json"], values))
    apply_package_nodes(project, packages, dest)
    write_json(dest / "default.project.json", project)
    (dest / "rokit.toml").write_text(rokit_text(None, wanted_pins(bundles, deps)), encoding="utf-8")
    write_dependency_files(dest, name, bundles, deps, project, force=False)

    starter = starter_record(dest, name, today, packages, bundles, managed)
    write_json(dest / "starter.json", starter)

    by_class = {cls: [p for p in packages if CLASS_OF[p] == cls] for cls in PACKAGE_CLASSES}
    print(f"scaffolded {name} at {dest}")
    print(f"  packages (in {FACTORY_DIR}/): " + "; ".join(f"{cls} {', '.join(p) or '-'}" for cls, p in by_class.items())
          + (f" (added as dependencies: {', '.join(added)})" if added else ""))
    print(f"  modules: {len(starter['modules'])} ({', '.join(f'{k} {v}' for k, v in starter['tiers'].items())}); "
          f"pending Studio probes: {len(starter['pending_probes'])}")
    print(f"  skills: {len(SKILLS)}; dependency bundles: {', '.join(bundles) or 'none'}; factory commit: {starter['factory']['commit'] or 'unknown'}")
    if starter["factory"]["packages_dirty"]:
        print("  note: the factory's packages/ or templates/starter has uncommitted changes; the hashes describe the working tree")
    print("next: cd into it, `git init` (the Codex hooks find the repo root with git), `rokit install`, `python3 tools/check.py`, then commit.")
    for step in owner_dep_steps(bundles, deps):
        print(f"owner: {step}")
    print("Fill the TBD fields of production/brief.json and AGENTS.md only from the game-build request or the owner; log them in docs/decisions.md.")
    return 0


def write_dependency_files(dest, name, bundles, deps, project, force):
    """wally.toml, studio-tests.project.json and per-bundle READMEs for the chosen bundles (never installs)."""
    packages = bundle_packages(bundles, deps)
    wally = dest / "wally.toml"
    if packages:
        text = merge_wally(wally.read_text(encoding="utf-8"), packages, deps, force) if wally.exists() else wally_text(name, packages, deps)
        wally.write_text(text, encoding="utf-8")
    if "studio-tests" in bundles:
        write_json(dest / "studio-tests.project.json", studio_tests_project(project))
        readme = dest / "tests" / "studio" / "README.md"
        if not readme.exists():
            write_bytes(readme, STUDIO_TESTS_README.encode("utf-8"))
    if "networking" in bundles:
        readme = dest / "net" / "README.md"
        if not readme.exists():
            write_bytes(readme, NET_README.encode("utf-8"))


STUDIO_TESTS_README = """# Studio tests (Jest Lua)

Specs that need the Roblox engine and cannot run in Lune go here as `*.spec.luau` ModuleScripts. The
`studio-tests` dependency bundle pins Jest Lua 3.10.0 (`jsdotlua/jest`, `jsdotlua/jest-globals`, dev realm)
in `wally.toml`; after the owner runs `wally install`, `studio-tests.project.json` maps `DevPackages` and
this folder into `ServerStorage` (the game's `default.project.json` never ships them).

Lune specs in `tests/*.spec.luau` stay the first choice (skill roblox-luau-testing). Running Jest Lua in
Studio needs a runner script and Studio settings described in the Jest Lua documentation; this starter
has not run it (UNVERIFIED), so record the first run's output before relying on it.
"""

NET_README = """# Network schemas (Blink)

Put Blink schemas here as `*.blink`. The `networking` dependency bundle pins the Blink CLI
(`1Axen/blink@0.18.9`, MIT) in `rokit.toml`; the gate step `blink` compiles every `.blink` file in the
repository and fails on a compile error. Generated modules go where each schema's output options say
(for example under `src/shared/net/`). Blink validates client payloads against the schema's ranges and
sizes; server code still checks authority (skill roblox-multiplayer-integrity). Remotes that are not
Blink-generated go through `GameKit/RemoteGuard` (release check A02).
"""


# ---- update

def recorded_sha(entry):
    return entry.get("sha256") if isinstance(entry, dict) else None


def update(dest, requested, bundles, force):
    if inside(dest, ROOT) or inside(ROOT, dest):
        raise Refused(f"{dest} overlaps the factory repo")
    path = dest / "starter.json"
    if not path.exists():
        raise Refused(f"{dest} has no starter.json; --update only works on a repo created by this starter")
    starter = json.loads(path.read_text(encoding="utf-8"))
    if starter.get("schema") not in READABLE_SCHEMAS:
        raise Refused(f"{path}: schema {starter.get('schema')!r}, expected one of {sorted(READABLE_SCHEMAS)}")
    if git(dest, "rev-parse", "--git-dir") is None:
        print(f"  note: {dest} is not a git repository, so the update cannot be reviewed with git diff")
    elif git(dest, "status", "--porcelain") and not force:
        raise Refused(f"{dest} has uncommitted changes; commit them, switch to a new branch, then update")

    deps = load_deps()
    old_bundles = (starter.get("deps") or {}).get("bundles", [])
    bundles = check_bundles(old_bundles + list(bundles or []), deps)
    name = starter.get("name") or dest.name
    values = {"NAME": name, "CREATED": starter.get("created") or datetime.date.today().isoformat()}
    recorded = starter.get("packages", {})
    packages = with_dependencies(requested or sorted(recorded))
    all_packages = sorted(set(recorded) | set(packages))
    templates = template_files()
    managed = managed_files(values, bundles, deps, set(templates) | set(starter.get("managed", {})))
    old_managed = starter.get("managed", {})
    old_skills = starter.get("skills", {}) if isinstance(starter.get("skills"), dict) else {}
    # A repo made before the packages moved to factory/ keeps them in packages/ (exact name: on Windows
    # and macOS Wally's Packages/ would also answer to it). It is moved below, after every refusal.
    factory = dest / FACTORY_DIR
    old_home = dest / OLD_FACTORY_DIR if has_entry(dest, OLD_FACTORY_DIR) and (dest / OLD_FACTORY_DIR).is_dir() else None
    if old_home is not None and factory.exists() and (not factory.is_dir() or any(factory.iterdir())):
        if any((old_home / pkg).is_dir() for pkg in recorded):
            raise Refused(f"{dest} keeps the factory packages in {OLD_FACTORY_DIR}/, and {FACTORY_DIR}/ already exists with other "
                          f"content; move {FACTORY_DIR}/ aside, then update (--force does not merge the two)")
        old_home = None  # the game's own folder beside factory/: left alone (the gate step deps flags its name)
    home = old_home or factory
    project_path = dest / "default.project.json"
    try:
        project = json.loads(project_path.read_text(encoding="utf-8")) if project_path.exists() else None
    except ValueError as err:  # checked before anything is written or moved
        raise Refused(f"{project_path} is not valid JSON ({err}); fix it before updating")

    # 1. Refuse local edits (anything whose sha256 differs from what the starter last wrote).
    edited = [p for p in packages if p in recorded and (home / p).exists()
              and tree_hash(home / p)[0] != recorded[p]["sha256"]]
    unrecorded = [p for p in packages if p not in recorded and (home / p).exists()]
    stray = sorted(p.name for p in old_home.iterdir() if p.name not in recorded and p.name not in unrecorded
                   and not p.name.startswith(".")) if old_home else []
    skill_edits, skill_unknown = [], []
    fresh_skills = skill_record(SKILLS)
    for skill in SKILLS:
        target = dest / ".agents" / "skills" / skill
        current = tree_hash(target)[0] if target.exists() else None
        old = recorded_sha(old_skills.get(skill))
        if current is None:
            continue
        if old is not None and current != old:
            skill_edits.append(skill)
        elif old is None and current != fresh_skills[skill]["sha256"]:
            skill_unknown.append(skill)
    file_edits, file_unknown = [], []
    for rel in sorted(set(managed) | set(old_managed)):
        current = file_sha(dest / rel)
        old = old_managed.get(rel)
        if current is None:
            continue
        if old is not None and current != old:
            file_edits.append(rel)
        elif old is None and rel in managed and current != sha(managed[rel]):
            file_unknown.append(rel)
    why = []
    if edited:
        why.append(f"packages edited here since the last scaffold/update: {edited}")
    if unrecorded:
        why.append(f"packages present but not in starter.json: {unrecorded}")
    if stray:
        why.append(f"{OLD_FACTORY_DIR}/ holds entries starter.json does not record, which the move to {FACTORY_DIR}/ would carry: {stray}")
    if skill_edits:
        why.append(f"skills edited here: {skill_edits}")
    if skill_unknown:
        why.append(f"skills that differ from the factory with no recorded hash: {skill_unknown}")
    if file_edits:
        why.append(f"managed files edited here: {file_edits}")
    if file_unknown:
        why.append(f"managed files that differ from the factory with no recorded hash: {file_unknown}")
    if why and not force:
        raise Refused("; ".join(why) + ". Move game changes out of factory-managed files (game code goes in src/, "
                      "game skills under a new name) or pass --force to overwrite.")

    changes = []
    if old_home is not None:
        if factory.is_dir():
            factory.rmdir()  # empty (checked above)
        old_home.rename(factory)
        changes.append(FACTORY_DIR)
        print(f"  {OLD_FACTORY_DIR}/: moved to {FACTORY_DIR}/ (`wally install` deletes Packages/, which is {OLD_FACTORY_DIR}/ "
              "on Windows and macOS)")
    # 2. Packages.
    fresh = package_record(packages)
    for pkg in packages:
        target = factory / pkg
        old = recorded.get(pkg, {}).get("sha256")
        current = tree_hash(target)[0] if target.exists() else None
        if old == fresh[pkg]["sha256"] and current == old:
            print(f"  {pkg}: unchanged")
            continue
        if target.exists():
            shutil.rmtree(target)
        copy_tree(PACKAGES / pkg, target)
        changes.append(pkg)
        print(f"  {pkg}: {'updated' if old else 'added'} {(old or '-')[:12]} -> {fresh[pkg]['sha256'][:12]}")
    # 3. Skills.
    skills_changed = []
    for skill in SKILLS:
        target = dest / ".agents" / "skills" / skill
        current = tree_hash(target)[0] if target.exists() else None
        if current == fresh_skills[skill]["sha256"]:
            continue
        if target.exists():
            shutil.rmtree(target)
        copy_tree(SKILLS_SRC / skill, target)
        skills_changed.append(skill)
    if skills_changed:
        sync_skills(dest)
        changes.append("skills")
        print(f"  skills: refreshed {', '.join(skills_changed)}")
    else:
        print("  skills: unchanged")
    # 4. Managed files (hooks, gate, release checker, boot runner, specs, settings).
    files_changed = []
    for rel, data in managed.items():
        if file_sha(dest / rel) != sha(data):
            write_bytes(dest / rel, data)
            files_changed.append(rel)
    for rel in sorted(set(old_managed) - set(managed)):
        if (dest / rel).is_file():
            (dest / rel).unlink()
            files_changed.append(f"{rel} (removed)")
    if files_changed:
        changes.append("managed")
        print(f"  managed files: {len(files_changed)} refreshed ({', '.join(files_changed[:6])}{', ...' if len(files_changed) > 6 else ''})")
    else:
        print("  managed files: unchanged")
    # 5. Template files the repo lacks (never overwrites a user file).
    for rel, src in templates.items():
        if rel in MANAGED_TEMPLATES or rel in MERGED or (dest / rel).exists():
            continue
        write_bytes(dest / rel, render(src, values))
        changes.append(rel)
        print(f"  {rel}: added")
    # 6. Merged files: the Rojo package folders and the toolchain pins.
    moved = 0
    if project is not None:
        before = project_path.read_text(encoding="utf-8")
        for note in apply_package_nodes(project, all_packages, dest):
            print(f"  default.project.json: {note}")
        moved = move_rojo_paths(project.get("tree"), all_packages)
        if moved:
            print(f"  default.project.json: {moved} other path(s) moved from {OLD_FACTORY_DIR}/ to {FACTORY_DIR}/")
        after = json.dumps(project, indent=2) + "\n"
        if after != before:
            project_path.write_text(after, encoding="utf-8")
            changes.append("default.project.json")
            print("  default.project.json: package folders rewritten")
    rokit = dest / "rokit.toml"
    old_rokit = rokit.read_text(encoding="utf-8") if rokit.exists() else None
    new_rokit = rokit_text(old_rokit, wanted_pins(bundles, deps))
    if new_rokit != old_rokit:
        rokit.write_text(new_rokit, encoding="utf-8")
        changes.append("rokit.toml")
        print("  rokit.toml: pins merged")
    if bundles != sorted(set(old_bundles)) and project is not None:
        write_dependency_files(dest, name, bundles, deps, project, force)
        changes.append("deps")
        print(f"  dependency bundles: {', '.join(bundles)}")
    elif "studio-tests" in bundles and project is not None:
        write_json(dest / "studio-tests.project.json", studio_tests_project(project))

    if old_home is not None or moved:
        regenerated = {"default.project.json"} | ({"studio-tests.project.json"} if "studio-tests" in bundles else set())
        for other in user_files_naming(dest, f"{OLD_FACTORY_DIR}/"):
            if other.as_posix() not in regenerated:
                print(f"  note: {other.as_posix()} still names {OLD_FACTORY_DIR}/ (a user file, left as it is); the factory "
                      f"packages are in {FACTORY_DIR}/ now")
    agents = dest / "AGENTS.md"
    if agents.is_file() and "| Brief key |" not in agents.read_text(encoding="utf-8"):
        print("  note: AGENTS.md predates game-brief/1; copy the Game decisions and Engine settings tables (with the Brief key "
              "column) from the factory's templates/starter/AGENTS.md.tmpl, or the gate step `brief` fails")
    if not changes and starter.get("schema") == SCHEMA:
        print(f"already up to date; {path} left unchanged")
        return 0
    fresh_record = starter_record(dest, name, values["CREATED"], all_packages, bundles, managed)
    fresh_record["updated"] = datetime.date.today().isoformat()
    write_json(path, fresh_record)
    print(f"updated {path}; review with `git diff` in {dest}, then run python3 tools/check.py there")
    for step in owner_dep_steps([b for b in bundles if b not in old_bundles], deps):
        print(f"owner: {step}")
    return 0


def list_options():
    deps = load_deps()
    print(f"package classes (Rojo home; files in the game repo's {FACTORY_DIR}/<Pkg>):")
    for cls, pkgs in PACKAGE_CLASSES.items():
        service, folder = ROJO_HOME[cls]
        print(f"  {cls:<10} {service}.{folder}: {', '.join(pkgs)}")
    print(f"default packages: {', '.join(DEFAULT_PACKAGES)}")
    print("dependency bundles (--deps):")
    for bundle, entry in deps["bundles"].items():
        pins = [f"{p}@{deps['packages'][p]['version']}" for p in entry["packages"]] + [deps["tools"][t]["pin"] for t in entry["tools"]]
        print(f"  {bundle:<13} {', '.join(pins)}: {entry['why']}")
    print(f"skills copied: {', '.join(SKILLS)}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dest", nargs="?", help="new repository directory, or the game repo with --update")
    ap.add_argument("--out", help="the destination directory (instead of the positional dest)")
    ap.add_argument("--name", help="project name (default: the dest folder name)")
    ap.add_argument("--packages", nargs="+", help=f"factory packages to copy (default: {' '.join(DEFAULT_PACKAGES)})")
    ap.add_argument("--deps", nargs="+", default=[], metavar="BUNDLE", help="dependency bundles from templates/starter/deps.json")
    ap.add_argument("--update", action="store_true", help="refresh the factory-managed parts of an existing starter repo")
    ap.add_argument("--force", action="store_true", help="with --update: overwrite local edits / dirty tree")
    ap.add_argument("--list", action="store_true", help="print package classes, dependency bundles and skills")
    args = ap.parse_args()
    try:
        if args.list:
            return list_options()
        if args.dest and args.out:
            raise Refused("give the destination once: positional dest or --out")
        target = args.dest or args.out
        if not target:
            raise Refused("missing destination: new_project.py <dest> (or --out <dest>)")
        dest = Path(target).expanduser().resolve()
        if args.update:
            return update(dest, args.packages, args.deps, args.force)
        if args.force:
            raise Refused("--force only applies to --update")
        name = args.name or dest.name
        if not NAME_RE.match(name):
            raise Refused(f"name {name!r} must match {NAME_RE.pattern}; pass --name")
        return scaffold(dest, name, args.packages or DEFAULT_PACKAGES, args.deps)
    except Refused as err:
        print(f"refused: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
