"""Game repository gate, trimmed from the Roblox production factory's tools/check.py. Tiers:
  fast        StyLua check + JSON validity + secret scan                                     (seconds)
  pre-commit  fast + skills sync + hook self-test + Selene + Lune specs + Rojo build         (~5 s)

  python3 tools/check.py [--tier fast|pre-commit] [--strict]

Missing optional tools (stylua, selene, lune, rojo, node) are reported as SKIPPED, never as passes.
--strict counts every SKIPPED step as a failure; CI runs with it. The secret scan uses
tools/hooks/secret-patterns.json, the same list as the Claude edit hook, over every file git would
commit. Writes build/check-report.json. Publishes, uploads and buys nothing.
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
LUAU_DIRS = ["src", "packages", "tests"]
SKIP_DIRS = {".git", "build", ".venv", "node_modules", "__pycache__"}
SECRET_PATTERNS_FILE = ROOT / "tools" / "hooks" / "secret-patterns.json"
SECRET_SCAN_MAX_BYTES = 5_000_000
FAILURE_LINE = re.compile(r"^\s*(FAIL|FAILED|ERROR|Error|error)\b|Traceback|AssertionError")


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

    def cmd(self, name, cmd, needs=None, timeout=600, env=None):
        if needs and shutil.which(needs) is None:
            self.add(name, "SKIPPED", f"{needs} not installed")
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
    gate.cmd("selene", ["selene", "src", "packages"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="pre-commit", choices=["fast", "pre-commit"])
    ap.add_argument("--strict", action="store_true", help="count SKIPPED steps as failures (CI)")
    args = ap.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)

    gate = Gate()
    gate.cmd("stylua", ["stylua", "--check", *LUAU_DIRS], needs="stylua")
    check_json(gate)
    check_secrets(gate)
    if args.tier == "pre-commit":
        gate.cmd("skills-sync", [sys.executable, "tools/sync_skills.py", "--check"])
        selftest_env = {**os.environ, "FACTORY_PYTHON": sys.executable}  # secret-pattern parity check
        gate.cmd("hooks-selftest", ["node", "tools/hooks/selftest.mjs"], needs="node", env=selftest_env)
        check_selene(gate)
        gate.cmd("lune-specs", ["lune", "run", "tests/run.luau"], needs="lune", timeout=180)
        gate.cmd("rojo-build", ["rojo", "build", "default.project.json", "-o", "build/game.rbxl"], needs="rojo")

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
