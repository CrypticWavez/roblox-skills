"""Factory gate. Tiers:
  fast        format check + JSON validity + secret scan                      (seconds)
  pre-commit  fast + skills sync + gap matrix + hook self-test + selene + Lune specs + fixture hashes (~10 s)
  pre-release pre-commit + Blender templates/QA + round trip + QA self-test + previews (minutes)

  python3 tools/check.py [--tier fast|pre-commit|pre-release] [--strict] [--update-golden] [--install-git-hook]

Missing optional tools (stylua, selene, lune, bpy) are reported as SKIPPED, never as passes.
--strict counts every SKIPPED step as a failure; CI runs with it, so a missing tool cannot keep CI green.
The secret scan uses tools/hooks/secret-patterns.json, the same list as the Claude edit hook, over every
file git would commit (tracked plus untracked, not ignored), dotfiles and scripts included.
Writes build/check-report.json. Opens no Studio session; publishes, uploads and buys nothing.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT_SUFFIXES = {".luau", ".lua", ".py", ".mjs", ".js", ".json", ".md", ".toml", ".yml", ".yaml", ".txt"}
SKIP_DIRS = {".git", "build", ".venv", "node_modules", "__pycache__"}
GOLDEN = ROOT / "tests" / "golden" / "fixture-hashes.json"
INHERITED_SPECS = [
    "tests/runtime/run.luau",
    "tests/creator/animation.luau",
    "tests/creator/audio_movement.luau",
    "tests/creator/effects.luau",
    "tests/creator/ui.luau",
    "tests/creator/world.luau",
    "tests/diagnostics/network.luau",
]
SECRET_PATTERNS_FILE = ROOT / "tools" / "hooks" / "secret-patterns.json"
SECRET_SCAN_MAX_BYTES = 5_000_000


def load_secret_patterns(path=SECRET_PATTERNS_FILE):
    """(compiled regex, label) pairs from the pattern file shared with tools/hooks/lib.mjs."""
    data = json.loads(path.read_text(encoding="utf-8"))
    return [(re.compile(p["pattern"], re.IGNORECASE if "i" in p.get("flags", "") else 0), p["label"]) for p in data["patterns"]]


def find_secrets(text, patterns):
    return sorted({label for regex, label in patterns if regex.search(text)})


def files(suffixes=TEXT_SUFFIXES):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix in suffixes:
                yield p


FAILURE_LINE = re.compile(r"^\s*(FAIL|FAILED|ERROR|Error|error)\b|Traceback|AssertionError")


def run(cmd, timeout=600, env=None):
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s", round(time.time() - start, 1)
    lines = (proc.stdout + proc.stderr).strip().splitlines()
    tail = lines[-15:]
    # Keep failure lines that scrolled out of the tail, so the report names the failing case.
    failures = [line for line in lines[:-15] if FAILURE_LINE.search(line)][:20]
    return proc.returncode, "\n".join(failures + tail), round(time.time() - start, 1)


def headline(detail):
    """The line that explains a failure: the first FAIL/ERROR line, else the last line."""
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

    def cmd(self, name, cmd, needs=None, timeout=600, env=None):
        if needs and shutil.which(needs) is None:
            self.add(name, "SKIPPED", f"{needs} not installed")
            return False
        code, tail, secs = run(cmd, timeout, env)
        self.add(name, "PASS" if code == 0 else "FAIL", tail, secs)
        return code == 0


def check_json(gate):
    bad = []
    for p in files({".json"}):
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except ValueError as err:
            bad.append(f"{p.relative_to(ROOT)}: {err}")
    gate.add("json-valid", "FAIL" if bad else "PASS", "\n".join(bad))


def committable_files():
    """Every file git would commit: tracked plus untracked-but-not-ignored. Falls back to a walk."""
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


def check_secrets(gate):
    try:
        patterns = load_secret_patterns()
    except (OSError, ValueError, KeyError, re.error) as err:
        gate.add("secret-scan", "FAIL", f"{SECRET_PATTERNS_FILE.relative_to(ROOT)} could not be loaded: {err}")
        return
    hits = []
    for p in committable_files():
        if p.stat().st_size > SECRET_SCAN_MAX_BYTES:
            continue
        data = p.read_bytes()
        if b"\0" in data[:8192]:
            continue  # binary
        labels = find_secrets(data.decode("utf-8", errors="ignore"), patterns)
        if labels:
            hits.append(f"{p.relative_to(ROOT).as_posix()}: {', '.join(labels)}")
    gate.add("secret-scan", "FAIL" if hits else "PASS", "\n".join(hits))


def check_selene(gate):
    if shutil.which("selene") is None:
        gate.add("selene", "SKIPPED", "selene not installed")
        return
    if not (ROOT / "roblox.yml").exists() and run(["selene", "generate-roblox-std"], 120)[0] != 0:
        gate.add("selene", "SKIPPED", "roblox std could not be generated (needs network to the Roblox API dump)")
        return
    gate.cmd("selene", ["selene", "packages"])


def check_fixtures(gate, update):
    if shutil.which("lune") is None:
        gate.add("fixture-build", "SKIPPED", "lune not installed")
        return
    code, tail, secs = run(["lune", "run", "tools/lune/build_fixtures.luau", "build/fixtures"])
    gate.add("fixture-build", "PASS" if code == 0 else "FAIL", tail, secs)
    if code != 0:
        return
    report = json.loads((ROOT / "build/fixtures/report.json").read_text())
    hashes = {k: v["hash"] for k, v in report["fixtures"].items()}
    if update or not GOLDEN.exists():
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
        gate.add("fixture-hashes", "PASS", "golden updated")
        return
    golden = json.loads(GOLDEN.read_text())
    drift = {
        "added": sorted(set(hashes) - set(golden)),
        "removed": sorted(set(golden) - set(hashes)),
        "changed": sorted(k for k in set(golden) & set(hashes) if golden[k] != hashes[k]),
    }
    detail = "; ".join(f"{kind}: {', '.join(names)}" for kind, names in drift.items() if names)
    if detail:
        detail += " (intended? rerun with --update-golden)"
    gate.add("fixture-hashes", "FAIL" if detail else "PASS", detail)


def blender_cmd():
    if importlib.util.find_spec("bpy") is not None:
        return [sys.executable, "tools/blender/factory.py"]
    if shutil.which("blender"):
        return ["blender", "-b", "--python", "tools/blender/factory.py", "--"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="pre-commit", choices=["fast", "pre-commit", "pre-release"])
    ap.add_argument("--strict", action="store_true", help="count SKIPPED steps as failures (CI)")
    ap.add_argument("--update-golden", action="store_true")
    ap.add_argument("--install-git-hook", action="store_true")
    args = ap.parse_args()
    if args.install_git_hook:
        hook = ROOT / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\nexec python3 tools/check.py --tier pre-commit\n")
        hook.chmod(0o755)
        print("installed", hook)
        return 0

    gate = Gate()
    gate.cmd("stylua", ["stylua", "--check", "packages", "tests", "tools/lune", "fixtures"], needs="stylua")
    check_json(gate)
    check_secrets(gate)
    if args.tier in ("pre-commit", "pre-release"):
        gate.cmd("skills-sync", [sys.executable, "tools/sync_skills.py", "--check"])
        gate.cmd("gap-matrix", [sys.executable, "tools/gap_matrix.py", "--check"])
        selftest_env = {**os.environ, "FACTORY_PYTHON": sys.executable}  # secret-pattern parity check
        gate.cmd("hooks-selftest", ["node", "tools/hooks/selftest.mjs"], needs="node", env=selftest_env)
        check_selene(gate)
        gate.cmd("lune-specs", ["lune", "run", "tests/run.luau"], needs="lune")
        for script in INHERITED_SPECS:  # the first pass's own Lune suites, re-run here
            gate.cmd(f"inherited-{Path(script).parent.name}-{Path(script).stem}", ["lune", "run", script], needs="lune")
        check_fixtures(gate, args.update_golden)
    if args.tier == "pre-release":
        blender = blender_cmd()
        if blender is None:
            gate.add("blender", "SKIPPED", "no bpy module or blender executable")
        else:
            gate.cmd("blender-templates", blender + ["templates", "build/blender"], timeout=3000)
            gate.cmd("blender-roundtrip", blender + ["roundtrip", "build/roundtrip"], timeout=900)
            gate.cmd("blender-qa-selftest", blender + ["qa-selftest", "build/qa-selftest"], timeout=900)
            for fixture in ("modular_building", "dungeon", "settlement"):
                manifest = f"build/fixtures/{fixture}.manifest.json"
                gate.cmd(f"preview-{fixture}", blender + ["render-manifest", manifest, "build/previews"], timeout=900)

    failed = [r["name"] for r in gate.results if r["status"] == "FAIL"]
    skipped = [r["name"] for r in gate.results if r["status"] == "SKIPPED"]
    passed = not failed and not (args.strict and skipped)
    (ROOT / "build").mkdir(exist_ok=True)
    report = {"tier": args.tier, "strict": args.strict, "pass": passed, "failed": failed, "skipped": skipped, "results": gate.results}
    (ROOT / "build" / "check-report.json").write_text(json.dumps(report, indent=2))
    strict = " (strict: skipped steps count as failures)" if args.strict and skipped else ""
    print(f"\n{args.tier}: {'PASS' if passed else 'FAIL'}{strict}; failed={failed} skipped={skipped}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
