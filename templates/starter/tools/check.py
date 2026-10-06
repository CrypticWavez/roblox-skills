"""Game repository gate (factory-managed). Tiers:
  fast         stylua, json-valid, secret-scan                                                  (seconds)
  pre-commit   fast + skills-sync, skills-packages, brief, deps, blink (only with .blink files),
               asset-provenance, hooks-selftest, selene, lune-specs, rojo-build
  pre-release  pre-commit + release-check (tools/release_check.py: automated A-items; owner items stay
               OWNER_REQUIRED and never pass here)

  python3 tools/check.py [--tier fast|pre-commit|pre-release] [--strict]

Missing optional tools (stylua, selene, lune, rojo, node, blink) are reported as SKIPPED, never as
passes; --strict counts every SKIPPED step as a failure (CI runs with it). Writes build/check-report.json.
Runs no publish, upload, install or purchase: `wally install` and publishing are the owner's.
Steps:
- skills-packages: the skills and packages on disk are the ones starter.json records, with the recorded
  sha256 (or listed under starter.json "patched" with a reason), and every Package/Module a skill names
  exists when that package is installed;
- brief: production/brief.json (game-brief/1) and production/pipeline.json are valid for the current
  stage (TBD allowed before alpha except fields of passed stages' brief gates; passed stages need their
  owner and playtest gates recorded by the owner), and the AGENTS.md decision tables match the brief;
- deps: wally.toml is private with exact `=x.y.z` pins from the deps.json allowlist in the right realm
  (server or dev: shared-realm [dependencies] install into Packages/, which is packages/ on Windows and
  macOS, and are refused), wally.lock is committed and lists only allowlisted packages,
  THIRD_PARTY_NOTICES.md names each dependency and its licence, rokit.toml pins are exact;
- blink: compiles every .blink schema (only when one exists);
- asset-provenance: asset ids are registered in assets/provenance.json; place content uses approved ids.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import production  # noqa: E402
import release_check  # noqa: E402

LUAU_DIRS = ["src", "packages", "tests"]
SKIP_DIRS = {".git", "build", ".venv", "node_modules", "__pycache__", "Packages", "ServerPackages", "DevPackages"}
SECRET_PATTERNS_FILE = ROOT / "tools" / "hooks" / "secret-patterns.json"
SECRET_SCAN_MAX_BYTES = 5_000_000
FAILURE_LINE = re.compile(r"^\s*(FAIL|FAILED|ERROR|Error|error)\b|Traceback|AssertionError")
FACTORY_PACKAGES = ["SceneKit", "ProcGen", "Pipeline", "GameKit", "UIKit", "Feel", "Cinematics", "AVKit", "Runtime", "Creator", "Diagnostics"]
MODULE_REF = re.compile(r"(?<![\w-])(" + "|".join(FACTORY_PACKAGES) + r")/((?:[A-Z][A-Za-z0-9_]*/)*[A-Z][A-Za-z0-9_]*)(\.[A-Za-z]+)?")
EXACT_PIN = re.compile(r"^([a-z0-9_-]+/[a-z0-9_-]+)@=(\d+\.\d+\.\d+)$")
ROKIT_PIN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@\d+\.\d+\.\d+$")


def load_secret_patterns(path=SECRET_PATTERNS_FILE):
    """(compiled regex, label) pairs from the pattern file shared with tools/hooks/lib.mjs."""
    data = json.loads(path.read_text(encoding="utf-8"))
    return [(re.compile(p["pattern"], re.IGNORECASE if "i" in p.get("flags", "") else 0), p["label"]) for p in data["patterns"]]


def find_secrets(text, patterns):
    return sorted({label for regex, label in patterns if regex.search(text)})


def run(cmd, timeout=600, env=None):
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s", round(time.time() - start, 1)
    except OSError as err:
        return 127, str(err), round(time.time() - start, 1)
    lines = (proc.stdout + proc.stderr).strip().splitlines()
    failures = [line for line in lines[:-15] if FAILURE_LINE.search(line)][:20]
    return proc.returncode, "\n".join(failures + lines[-15:]), round(time.time() - start, 1)


def headline(detail):
    lines = [line for line in detail.splitlines() if line.strip()]
    return next((line for line in lines if FAILURE_LINE.search(line)), lines[-1] if lines else "")


class Gate:
    def __init__(self):
        self.results = []

    def add(self, name, status, detail="", seconds=0.0):
        self.results.append({"name": name, "status": status, "detail": detail, "seconds": seconds})
        mark = {"PASS": "ok  ", "FAIL": "FAIL", "SKIPPED": "skip"}[status]
        why = headline(detail) if status != "PASS" else ""
        print(f"[{mark}] {name} ({seconds}s){': ' + why if why else ''}")

    def problems(self, name, problems, ok_detail, start):
        self.add(name, "FAIL" if problems else "PASS", "\n".join(problems or [ok_detail]), round(time.time() - start, 2))

    def cmd(self, name, cmd, needs=None, timeout=600, env=None):
        if needs and shutil.which(needs) is None:
            self.add(name, "SKIPPED", f"{needs} not installed (rokit install)")
            return False
        code, tail, secs = run(cmd, timeout, env)
        self.add(name, "PASS" if code == 0 else "FAIL", tail, secs)
        return code == 0


def committable_files():
    """Every file git would commit (tracked plus untracked, not ignored); a plain walk outside git."""
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=ROOT, capture_output=True, timeout=60, check=True,
        ).stdout
        paths = [ROOT / name for name in out.decode("utf-8", "surrogateescape").split("\0") if name]
    except (OSError, subprocess.SubprocessError):
        paths = []
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            paths.extend(Path(dirpath) / name for name in filenames)
    return sorted({p for p in paths if p.is_file()})


def text_files():
    out = []
    for p in committable_files():
        if p.stat().st_size > SECRET_SCAN_MAX_BYTES:
            continue
        data = p.read_bytes()
        if b"\0" not in data[:8192]:
            out.append(p)
    return out


def check_json(gate):
    bad = []
    for p in committable_files():
        if p.suffix == ".json":
            try:
                json.loads(p.read_text(encoding="utf-8"))
            except ValueError as err:
                bad.append(f"{p.relative_to(ROOT)}: {err}")
    gate.add("json-valid", "FAIL" if bad else "PASS", "\n".join(bad))


def check_secrets(gate):
    try:
        patterns = load_secret_patterns()
    except (OSError, ValueError, KeyError, re.error) as err:
        gate.add("secret-scan", "FAIL", f"{SECRET_PATTERNS_FILE.relative_to(ROOT)} could not be loaded: {err}")
        return
    hits = []
    for p in text_files():
        labels = find_secrets(p.read_bytes().decode("utf-8", errors="ignore"), patterns)
        if labels:
            hits.append(f"{p.relative_to(ROOT).as_posix()}: {', '.join(labels)}")
    gate.add("secret-scan", "FAIL" if hits else "PASS", "\n".join(hits))


# ---- skills-packages

def tree_hash(path):
    """Same digest as tools/new_project.py in the factory (sorted relative paths, LF-normalized text)."""
    import hashlib

    text_suffixes = {".luau", ".lua", ".py", ".mjs", ".js", ".json", ".md", ".toml", ".yml", ".yaml", ".txt", ".tmpl", ".csv", ""}
    digest = hashlib.sha256()
    for p in sorted(q for q in path.rglob("*") if q.is_file() and "__pycache__" not in q.parts):
        data = p.read_bytes()
        if p.suffix in text_suffixes:
            data = data.replace(b"\r\n", b"\n")
        digest.update(p.relative_to(path).as_posix().encode() + b"\0" + data + b"\0")
    return digest.hexdigest()


def load_starter():
    data, err = production.load_json(ROOT / "starter.json")
    if err:
        return None, err
    if data.get("schema") != "starter/2":
        return None, f"starter.json schema {data.get('schema')!r}; refresh it with the factory's tools/new_project.py --update"
    return data, None


def skills_packages_problems(root, starter):
    problems, notes = [], []
    patched = starter.get("patched") or {}
    packages = starter.get("packages") or {}
    modules = starter.get("modules") or {}
    on_disk = sorted(p.name for p in (root / "packages").iterdir() if p.is_dir()) if (root / "packages").is_dir() else []
    for name in sorted(set(on_disk) - set(packages)):
        problems.append(f"packages/{name} is not recorded in starter.json (add packages with the factory's new_project.py --update --packages)")
    for name, record in sorted(packages.items()):
        path = root / "packages" / name
        if not path.is_dir():
            problems.append(f"packages/{name} is recorded in starter.json but missing")
        elif tree_hash(path) != record.get("sha256"):
            if f"packages/{name}" in patched:
                notes.append(f"packages/{name} patched here: {patched[f'packages/{name}']}")
            else:
                problems.append(f"packages/{name} differs from starter.json: factory packages are fixed in the factory and refreshed with "
                                f"new_project.py --update (or list \"packages/{name}\" under starter.json \"patched\" with a reason)")
    skills = starter.get("skills") or {}
    for name, record in sorted(skills.items()):
        src, mirror = root / ".agents" / "skills" / name, root / ".claude" / "skills" / name
        if not (src / "SKILL.md").is_file():
            problems.append(f".agents/skills/{name}/SKILL.md missing (recorded in starter.json)")
            continue
        if not (mirror / "SKILL.md").is_file():
            problems.append(f".claude/skills/{name}/SKILL.md missing (python3 tools/sync_skills.py)")
        if isinstance(record, dict) and record.get("sha256") and tree_hash(src) != record["sha256"]:
            if f"skills/{name}" in patched:
                notes.append(f"skills/{name} patched here: {patched[f'skills/{name}']}")
            else:
                problems.append(f".agents/skills/{name} differs from starter.json: copy it under a new name for game-specific changes "
                                f"(or list \"skills/{name}\" under starter.json \"patched\")")
        for md in sorted(src.rglob("*.md")):
            text = md.read_text(encoding="utf-8")
            for match in MODULE_REF.finditer(text):
                pkg, path, ext = match.group(1), match.group(2), match.group(3)
                if (ext and ext != ".luau") or path in FACTORY_PACKAGES:
                    continue
                ref = f"{pkg}/{path}"
                if pkg not in packages:
                    continue
                if ref not in modules and not any(m.startswith(ref + "/") for m in modules):
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(f".agents/skills/{name}/{md.relative_to(src).as_posix()}:{line}: names {ref}, which is not in the installed {pkg}")
    not_installed = sorted({m.group(1) for s in skills for md in (root / ".agents" / "skills" / s).rglob("*.md")
                            for m in MODULE_REF.finditer(md.read_text(encoding="utf-8")) if m.group(1) not in packages})
    if not_installed:
        notes.append(f"skills also name packages not installed here: {', '.join(not_installed)}")
    return problems, notes


def check_skills_packages(gate):
    start = time.time()
    starter, err = load_starter()
    if err:
        gate.add("skills-packages", "FAIL", err)
        return
    problems, notes = skills_packages_problems(ROOT, starter)
    ok = f"{len(starter.get('skills', {}))} skills, {len(starter.get('packages', {}))} packages, {len(starter.get('modules', {}))} modules match starter.json"
    gate.problems("skills-packages", problems, "\n".join([ok] + notes), start)


# ---- brief

TABLE_HEAD = re.compile(r"^\|\s*(Field|Setting)\s*\|\s*Brief key\s*\|\s*Decision\s*\|\s*$")


def decision_rows(text):
    rows, active = [], False
    for number, line in enumerate(text.splitlines(), start=1):
        if TABLE_HEAD.match(line):
            active = True
            continue
        if active and line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 3 and not set(cells[0]) <= {"-", ":", " "}:
                rows.append((number, cells[1].strip("`"), cells[2]))
            continue
        active = False
    return rows


def lookup(data, dotted):
    node = data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None, False
        node = node[part]
    return node, True


def render(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def agents_problems(text, brief):
    problems = []
    rows = decision_rows(text)
    if not rows:
        return ["AGENTS.md has no decision table (| Field | Brief key | Decision |)"]
    for number, key, cell in rows:
        value, found = lookup(brief, key)
        if not found:
            problems.append(f"AGENTS.md:{number}: brief key {key} does not exist in production/brief.json")
            continue
        cell_tbd = cell.strip("`* ").upper() == production.TBD
        if production.is_tbd(value) != cell_tbd:
            problems.append(f"AGENTS.md:{number}: {key} is {'TBD' if cell_tbd else repr(cell)} here but "
                            f"{'TBD' if production.is_tbd(value) else 'decided'} in production/brief.json; keep them in step")
        elif not cell_tbd and isinstance(value, (str, bool, int, float)) and cell.strip("`") != render(value):
            problems.append(f"AGENTS.md:{number}: {key} says {cell!r} but production/brief.json has {render(value)!r}")
    return problems


def brief_problems(root, starter):
    brief, err1 = production.load_json(root / "production" / "brief.json")
    pipeline, err2 = production.load_json(root / "production" / "pipeline.json")
    if err1 or err2:
        return [e for e in (err1, err2) if e], ""
    problems = production.pipeline_problems(pipeline, production.BRIEF_FIELDS)
    if problems:
        return problems, ""
    stage = pipeline["current"]
    modules = (starter or {}).get("modules")
    problems += production.brief_problems(brief, stage, pipeline, modules)
    records, record_problems = production.owner_records(root)
    problems += record_problems
    index = production.STAGES.index(stage)
    for passed in pipeline["stages"][:index]:
        for gate in passed.get("exit", []):
            if gate["kind"] in ("owner", "playtest") and gate["id"] not in records:
                problems.append(f"stage {passed['id']} is passed but its {gate['kind']} gate {gate['id']} has no owner record (release/owner-*.json)")
            if gate["kind"] == "file":
                done, why = production.file_gate_done(root, gate)
                if not done:
                    problems.append(f"stage {passed['id']} is passed but {why}")
    agents = root / "AGENTS.md"
    if agents.is_file():
        problems += agents_problems(agents.read_text(encoding="utf-8"), brief)
    else:
        problems.append("AGENTS.md missing")
    return problems, f"stage {stage}; {len(production.undecided(brief))} required brief field(s) TBD"


def check_brief(gate):
    start = time.time()
    starter, _ = load_starter()
    problems, ok = brief_problems(ROOT, starter)
    gate.problems("brief", problems, ok, start)


# ---- deps

def read_toml(path):
    text = path.read_text(encoding="utf-8")
    try:
        import tomllib

        return tomllib.loads(text)
    except ImportError:
        pass
    data = {}  # minimal reader for the flat files Wally and Rokit write (Python < 3.11)
    data_table = data
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip() if not raw.strip().startswith("#") else ""
        if not line:
            continue
        if line.startswith("[["):
            name = line.strip("[]").strip()
            data.setdefault(name, []).append({})
            data_table = data[name][-1]
        elif line.startswith("["):
            data_table = data.setdefault(line.strip("[]").strip(), {})
        elif "=" in line:
            key, value = (s.strip() for s in line.split("=", 1))
            data_table[key.strip('"')] = value == "true" if value in ("true", "false") else value.strip('"')
    return data


def git_ignored(path):
    try:
        proc = subprocess.run(["git", "check-ignore", "-q", str(path)], cwd=ROOT, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def deps_problems(root):
    problems, notes = [], []
    allow, err = production.load_json(root / "deps.json")
    if err:
        return [f"deps.json (the allowlist): {err}"], ""
    tables = allow["wally"]["tables"]
    wally = root / "wally.toml"
    rokit = root / "rokit.toml"
    pins = read_toml(rokit).get("tools", {}) if rokit.is_file() else {}
    for tool, pin in pins.items():
        if not ROKIT_PIN.match(str(pin)):
            problems.append(f"rokit.toml: {tool} = {pin!r} is not an exact owner/repo@x.y.z pin")
    if not wally.is_file():
        # Exact names: on Windows and macOS (case-insensitive) root / "Packages" would open the factory packages/.
        names = {p.name for p in root.iterdir() if p.is_dir()}
        for folder in ("Packages", "ServerPackages", "DevPackages"):
            if folder in names and any((root / folder).iterdir()):
                problems.append(f"{folder}/ has content but there is no wally.toml")
        return problems, "no Wally dependencies"
    manifest = read_toml(wally)
    if manifest.get("package", {}).get("private") is not True:
        problems.append("wally.toml: [package] needs private = true (a game is never uploaded to the registry)")
    wanted = {}
    for table in ("dependencies", "server-dependencies", "dev-dependencies"):
        for alias, spec in (manifest.get(table) or {}).items():
            if table == "dependencies":  # Wally's shared realm
                problems.append(f"wally.toml [{table}] {alias}: shared-realm dependencies are refused while the factory kits live in "
                                "packages/ (Wally installs them into Packages/, the same folder on Windows and macOS)")
                continue
            match = EXACT_PIN.match(str(spec))
            if not match:
                problems.append(f"wally.toml [{table}] {alias} = {spec!r}: needs an exact pin scope/name@=x.y.z")
                continue
            name, version = match.groups()
            entry = allow["packages"].get(name)
            if entry is None:
                problems.append(f"wally.toml [{table}] {name} is not in the deps.json allowlist")
                continue
            if version != entry["version"]:
                problems.append(f"wally.toml [{table}] {name}@{version}: deps.json pins {entry['version']}")
            if tables[entry["realm"]] != table:
                problems.append(f"wally.toml {name} belongs in [{tables[entry['realm']]}] (realm {entry['realm']})")
            wanted[name] = version
    if "wally" not in pins:
        problems.append("rokit.toml has no wally pin (deps.json tools.wally)")
    lock = root / "wally.lock"
    if wanted and not lock.is_file():
        problems.append("wally.lock missing: the owner runs `wally install` and commits wally.lock (committed-lockfile policy)")
    elif lock.is_file():
        if git_ignored(lock):
            problems.append("wally.lock is gitignored; it must be committed")
        locked = read_toml(lock).get("package", [])
        scopes = allow.get("transitive_scopes", {})
        for entry in locked if isinstance(locked, list) else []:
            name, version = entry.get("name", ""), entry.get("version", "")
            if name.startswith("local/"):
                continue
            if name in allow["packages"]:
                if version != allow["packages"][name]["version"]:
                    problems.append(f"wally.lock: {name} {version}, deps.json pins {allow['packages'][name]['version']}")
            elif name.split("/")[0] not in scopes:
                problems.append(f"wally.lock: {name} {version} is not allowlisted (deps.json packages or transitive_scopes)")
        missing = sorted(set(wanted) - {e.get("name") for e in locked if isinstance(e, dict)})
        if missing:
            problems.append(f"wally.lock lacks {missing}; re-run `wally install` (owner) and commit the lockfile")
    notices = root / "THIRD_PARTY_NOTICES.md"
    text = notices.read_text(encoding="utf-8") if notices.is_file() else ""
    for name in wanted:
        if f"`{name}`" not in text or allow["packages"][name]["license"] not in text:
            problems.append(f"THIRD_PARTY_NOTICES.md must list `{name}` with its licence {allow['packages'][name]['license']}")
    return problems, f"{len(wanted)} pinned Wally dependencies, {len(pins)} rokit pins"


def check_deps(gate):
    start = time.time()
    problems, ok = deps_problems(ROOT)
    gate.problems("deps", problems, ok, start)


def blink_files():
    return [p for p in committable_files() if p.suffix == ".blink"]


def check_blink(gate):
    files = blink_files()
    if not files:
        return  # the step exists only when a schema does
    if shutil.which("blink") is None:
        gate.add("blink", "SKIPPED", "blink not installed (the networking bundle pins it in rokit.toml; rokit install)")
        return
    start, problems = time.time(), []
    for path in files:
        code, out, _ = run(["blink", str(path.relative_to(ROOT))], timeout=120)
        if code != 0:
            problems.append(f"{path.relative_to(ROOT).as_posix()}: {headline(out)}")
    gate.problems("blink", problems, f"{len(files)} schema(s) compiled", start)


def check_asset_provenance(gate):
    start = time.time()
    paths = [p for p in text_files() if p.resolve() != (ROOT / "assets" / "provenance.json").resolve()]
    problems, count = release_check.asset_problems(ROOT, paths)
    gate.problems("asset-provenance", problems, f"{len(paths)} files scanned, {count} asset id reference(s)", start)


def check_release(gate):
    """release-check: tools/release_check.py; FAIL while an automated item fails. Owner items are listed,
    never counted as passes or failures here."""
    start = time.time()
    code, out, secs = run([sys.executable, "tools/release_check.py"], timeout=300)
    report, err = production.load_json(ROOT / "release" / "report.json")
    if err or not isinstance(report, dict):
        gate.add("release-check", "FAIL", f"FAIL release/report.json not written ({err}): {out}", secs)
        return
    failing = [i for i in report["items"] if i["status"] == "FAIL"]
    owner = [i for i in report["items"] if i["tier"] != "A"]
    lines = [f"FAIL {i['id']} {i['title']}: {i['problems'][0]}" for i in failing]
    lines.append(f"owner items: {len(owner)} OWNER_REQUIRED ({sum(1 for i in owner if i.get('owner_record'))} recorded by the owner); "
                 "they never pass here (docs/release-runbook.md)")
    gate.add("release-check", "FAIL" if failing or code != 0 else "PASS", "\n".join(lines), round(time.time() - start, 2))


def check_selene(gate):
    if shutil.which("selene") is None:
        gate.add("selene", "SKIPPED", "selene not installed")
        return
    if not (ROOT / "roblox.yml").exists() and run(["selene", "generate-roblox-std"], 120)[0] != 0:
        gate.add("selene", "SKIPPED", "roblox std could not be generated (needs network to the Roblox API dump)")
        return
    gate.cmd("selene", ["selene", "src", "packages"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="pre-commit", choices=["fast", "pre-commit", "pre-release"])
    ap.add_argument("--strict", action="store_true", help="count SKIPPED steps as failures (CI)")
    args = ap.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)

    gate = Gate()
    gate.cmd("stylua", ["stylua", "--check", *[d for d in LUAU_DIRS if (ROOT / d).is_dir()]], needs="stylua")
    check_json(gate)
    check_secrets(gate)
    if args.tier in ("pre-commit", "pre-release"):
        gate.cmd("skills-sync", [sys.executable, "tools/sync_skills.py", "--check"])
        check_skills_packages(gate)
        check_brief(gate)
        check_deps(gate)
        check_blink(gate)
        check_asset_provenance(gate)
        selftest_env = {**os.environ, "FACTORY_PYTHON": sys.executable}  # secret-pattern parity check
        gate.cmd("hooks-selftest", ["node", "tools/hooks/selftest.mjs"], needs="node", env=selftest_env)
        check_selene(gate)
        gate.cmd("lune-specs", ["lune", "run", "tests/run.luau"], needs="lune", timeout=300)
        gate.cmd("rojo-build", ["rojo", "build", "default.project.json", "-o", "build/game.rbxl"], needs="rojo")
    if args.tier == "pre-release":
        check_release(gate)

    failed = [r["name"] for r in gate.results if r["status"] == "FAIL"]
    skipped = [r["name"] for r in gate.results if r["status"] == "SKIPPED"]
    passed = not failed and not (args.strict and skipped)
    report = {"tier": args.tier, "strict": args.strict, "pass": passed, "failed": failed, "skipped": skipped, "results": gate.results}
    (ROOT / "build" / "check-report.json").write_text(json.dumps(report, indent=2))
    strict = " (strict: skipped steps count as failures)" if args.strict and skipped else ""
    print(f"\n{args.tier}: {'PASS' if passed else 'FAIL'}{strict}; failed={failed} skipped={skipped}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
