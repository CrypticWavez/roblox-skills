"""Factory gate. Tiers:
  fast        format check + JSON validity + secret scan                      (seconds)
  pre-commit  fast + skills sync + gap matrix + hook self-test + selene + Lune specs + fixture hashes (~10 s)
  pre-release pre-commit + Blender templates/QA + round trip + previews       (minutes)

  python3 tools/check.py [--tier fast|pre-commit|pre-release] [--update-golden] [--install-git-hook]

Missing optional tools (stylua, selene, lune, bpy) are reported as SKIPPED, never as passes.
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
SECRET_RE = [
    re.compile(r"_\|WARNING:-DO-NOT-SHARE-THIS"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bghp_[A-Za-z0-9]{36}\b"),
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
]


def files(suffixes=TEXT_SUFFIXES):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix in suffixes:
                yield p


def run(cmd, timeout=600):
    start = time.time()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s", round(time.time() - start, 1)
    tail = (proc.stdout + proc.stderr).strip().splitlines()[-15:]
    return proc.returncode, "\n".join(tail), round(time.time() - start, 1)


class Gate:
    def __init__(self):
        self.results = []

    def add(self, name, status, detail="", seconds=0.0):
        self.results.append({"name": name, "status": status, "detail": detail, "seconds": seconds})
        mark = {"PASS": "ok  ", "FAIL": "FAIL", "SKIPPED": "skip"}[status]
        last = detail.splitlines()[-1] if detail and status != "PASS" else ""
        print(f"[{mark}] {name} ({seconds}s){': ' + last if last else ''}")

    def cmd(self, name, cmd, needs=None, timeout=600):
        if needs and shutil.which(needs) is None:
            self.add(name, "SKIPPED", f"{needs} not installed")
            return False
        code, tail, secs = run(cmd, timeout)
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


def check_secrets(gate):
    hits = []
    for p in files():
        if p.name == "check.py" or p.parent.name == "hooks":
            continue  # these files contain the patterns themselves
        text = p.read_text(encoding="utf-8", errors="ignore")
        if any(r.search(text) for r in SECRET_RE):
            hits.append(str(p.relative_to(ROOT)))
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
    changed = [k for k in golden if golden[k] != hashes.get(k)]
    detail = f"changed: {', '.join(changed)} (intended? rerun with --update-golden)" if changed else ""
    gate.add("fixture-hashes", "FAIL" if changed else "PASS", detail)


def blender_cmd():
    if importlib.util.find_spec("bpy") is not None:
        return [sys.executable, "tools/blender/factory.py"]
    if shutil.which("blender"):
        return ["blender", "-b", "--python", "tools/blender/factory.py", "--"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="pre-commit", choices=["fast", "pre-commit", "pre-release"])
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
        gate.cmd("hooks-selftest", ["node", "tools/hooks/selftest.mjs"], needs="node")
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
            for fixture in ("modular_building", "dungeon", "settlement"):
                manifest = f"build/fixtures/{fixture}.manifest.json"
                gate.cmd(f"preview-{fixture}", blender + ["render-manifest", manifest, "build/previews"], timeout=900)

    failed = [r["name"] for r in gate.results if r["status"] == "FAIL"]
    skipped = [r["name"] for r in gate.results if r["status"] == "SKIPPED"]
    (ROOT / "build").mkdir(exist_ok=True)
    report = {"tier": args.tier, "pass": not failed, "failed": failed, "skipped": skipped, "results": gate.results}
    (ROOT / "build" / "check-report.json").write_text(json.dumps(report, indent=2))
    print(f"\n{args.tier}: {'PASS' if not failed else 'FAIL'}; failed={failed} skipped={skipped}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
