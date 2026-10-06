"""Starter smoke test: scaffold game repositories with tools/new_project.py and run their own tools.

  python3 tools/starter_smoke.py [--keep DIR] [--strict]

1. default packages: `rojo build`, `lune run tests/run.luau` (boot, layout and packages specs), the
   game gate's fast tier, `tools/release_check.py` (only A08, A09 and A17 may fail, on release data a
   fresh repo has not decided; every S/O/P item OWNER_REQUIRED), `tools/production.py status` and
   `tools/plan_issues.py` (drafts written, no API call);
2. every package and every dependency bundle: `rojo build` and the Lune specs; wally.toml holds the
   exact pins (ProfileStore 1.0.3 server, Jest Lua 3.10.0 dev) and neither wally.lock nor Packages/
   exists (the starter never runs wally).
The factory gate's starter-smoke step runs the default repo's full pre-commit gate; this script adds
the release, production and all-packages paths. Missing rojo, lune or stylua: SKIPPED (exit 0, or 1
with --strict). --keep DIR scaffolds into DIR (outside this repo) and leaves the repos there.
Publishes, uploads, installs and buys nothing.
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NEW_PROJECT = [sys.executable, str(ROOT / "tools" / "new_project.py")]
EXPECTED_FRESH_FAILURES = ["A08", "A09", "A17"]


class Smoke:
    def __init__(self):
        self.results = []

    def add(self, name, ok, detail=""):
        self.results.append((name, ok, detail))
        print(f"[{'ok  ' if ok else 'FAIL'}] {name}{': ' + detail if detail and not ok else ''}")

    def run(self, name, cmd, cwd, expect=0, timeout=300):
        try:
            proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            self.add(name, False, f"timed out after {timeout}s")
            return None
        out = (proc.stdout + proc.stderr).strip()
        ok = proc.returncode == expect
        self.add(name, ok, f"exit {proc.returncode} (wanted {expect}): {out.splitlines()[-1] if out else ''}")
        return out


def scaffold(smoke, base, name, *args):
    dest = base / name
    out = smoke.run(f"{name}: scaffold", NEW_PROJECT + [str(dest), "--name", name, *args], ROOT)
    if out is None or not (dest / "starter.json").is_file():
        return None
    subprocess.run(["git", "init", "-q", str(dest)], capture_output=True, text=True, timeout=60)
    (dest / "build").mkdir(exist_ok=True)
    return dest


def default_repo(smoke, base):
    dest = scaffold(smoke, base, "SmokeDefault")
    if dest is None:
        return
    smoke.run("SmokeDefault: rojo build", ["rojo", "build", "default.project.json", "-o", "build/game.rbxl"], dest)
    out = smoke.run("SmokeDefault: lune specs", ["lune", "run", "tests/run.luau"], dest)
    if out is not None:
        smoke.add("SmokeDefault: boot, layout and packages specs ran", "(3 files)" in out and " 0 failed" in out, out.splitlines()[-1] if out else "")
    smoke.run("SmokeDefault: gate fast tier", [sys.executable, "tools/check.py", "--tier", "fast"], dest)
    smoke.run("SmokeDefault: release_check exits 1 on undecided release data", [sys.executable, "tools/release_check.py"], dest, expect=1)
    report_path = dest / "release" / "report.json"
    if report_path.is_file():
        report = json.loads(report_path.read_text(encoding="utf-8"))
        failing = sorted(i["id"] for i in report["items"] if i["status"] == "FAIL")
        smoke.add("SmokeDefault: only undecided release data fails", failing == EXPECTED_FRESH_FAILURES, f"failing {failing}")
        owner = [i for i in report["items"] if i["tier"] != "A"]
        smoke.add("SmokeDefault: every S/O/P item is OWNER_REQUIRED", bool(owner) and all(i["status"] == "OWNER_REQUIRED" for i in owner))
    else:
        smoke.add("SmokeDefault: release/report.json written", False)
    smoke.run("SmokeDefault: production status", [sys.executable, "tools/production.py", "status"], dest)
    smoke.run("SmokeDefault: plan_issues", [sys.executable, "tools/plan_issues.py"], dest)
    index = dest / "build" / "issue-drafts" / "concept" / "index.json"
    drafts = json.loads(index.read_text(encoding="utf-8"))["drafts"] if index.is_file() else []
    smoke.add("SmokeDefault: issue drafts for the concept stage", len(drafts) >= 3, f"{len(drafts)} drafts")


def all_packages_repo(smoke, base):
    packages = sorted(p.name for p in (ROOT / "packages").iterdir() if p.is_dir())
    bundles = sorted(json.loads((ROOT / "templates" / "starter" / "deps.json").read_text(encoding="utf-8"))["bundles"])
    dest = scaffold(smoke, base, "SmokeAll", "--packages", *packages, "--deps", *bundles)
    if dest is None:
        return
    smoke.run("SmokeAll: rojo build", ["rojo", "build", "default.project.json", "-o", "build/game.rbxl"], dest)
    out = smoke.run("SmokeAll: lune specs", ["lune", "run", "tests/run.luau"], dest)
    if out is not None:
        smoke.add("SmokeAll: specs report 0 failed", " 0 failed" in out, out.splitlines()[-1] if out else "")
    wally = (dest / "wally.toml").read_text(encoding="utf-8") if (dest / "wally.toml").is_file() else ""
    smoke.add("SmokeAll: ProfileStore pinned =1.0.3 (server)", 'ProfileStore = "lm-loleris/profilestore@=1.0.3"' in wally)
    smoke.add("SmokeAll: Jest Lua pinned =3.10.0 (dev)", 'Jest = "jsdotlua/jest@=3.10.0"' in wally)
    smoke.add("SmokeAll: wally never ran (no wally.lock, no Packages/)", not (dest / "wally.lock").exists() and not (dest / "Packages").exists())
    smoke.add("SmokeAll: THIRD_PARTY_NOTICES.md written", (dest / "THIRD_PARTY_NOTICES.md").is_file())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--keep", help="scaffold into this directory (outside the factory) and keep the repos")
    ap.add_argument("--strict", action="store_true", help="a missing tool fails instead of skipping")
    args = ap.parse_args()
    missing = [tool for tool in ("rojo", "lune", "stylua") if shutil.which(tool) is None]
    if missing:
        print(f"[skip] starter smoke: {', '.join(missing)} not installed")
        return 1 if args.strict else 0
    smoke = Smoke()
    if args.keep:
        base = Path(args.keep).expanduser().resolve()
        base.mkdir(parents=True, exist_ok=True)
        default_repo(smoke, base)
        all_packages_repo(smoke, base)
    else:
        with tempfile.TemporaryDirectory(prefix="starter-smoke-") as tmp:
            default_repo(smoke, Path(tmp))
            all_packages_repo(smoke, Path(tmp))
    failed = [name for name, ok, _ in smoke.results if not ok]
    print(f"\nstarter smoke: {'PASS' if not failed else 'FAIL'}; {len(smoke.results)} checks, failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
