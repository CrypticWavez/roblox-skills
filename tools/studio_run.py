"""Run an engine probe in Roblox Studio through the documented Studio command line, or parse its output.

  python3 tools/studio_run.py --probe <name> [--build] [--place build/kits.rbxl] [--studio PATH] [--timeout S]
  python3 tools/studio_run.py --probe <name> --from-output <console.txt>   (output captured elsewhere)
  python3 tools/studio_run.py --list

A probe is tests/engine/<name>.luau, a RunScript entry that prints `ENGINE_CHECK {json}` lines and one
`ENGINE_DONE {json}` line (docs/runtime-kits.md section 7; tests/engine/README.md). The Studio run is

  <Studio> --task RunScript --localPlaceFile <abs place> --runScriptFile <abs probe>
           --outputFile <tmp> --quitAfterExecution

(create.roblox.com/docs/studio/command-line-interface). The place must be a local .rbxl/.rbxlx under
this repository's build/ (`--build` makes build/kits.rbxl from fixtures/kits.project.json with rojo).
`--placeId`, `--universeId` and every other way to target a published game are refused: probes run
only on the unpublished diagnostic place. RunScript runs at command-bar level after the place loads,
which the docs imply is Edit mode (UNVERIFIED, as is whether Studio needs a logged-in user here);
probes that need a play session run through Studio MCP or the kitsmoke runner fixture and are
recorded with --from-output.

Results: reports/engine/<probe>.json (schema engine-report/1) for a real run or a parsed output, with
repo-relative paths only. Where Studio is absent (this Linux container, CI) the status is
BLOCKED_EXTERNAL, nothing under reports/ is written (build/engine/<probe>.json instead) and the exit
code is 3, never 0. Output from Lune (tools/lune/kit_smoke.luau over fakes; its ENGINE_DONE lines carry
"runtime":"lune") is refused on either route and writes nothing: Lune output is never engine evidence.
Exit codes: 0 PASS, 1 FAIL, 2 refused or bad usage, 3 BLOCKED_EXTERNAL.
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE_DIR = ROOT / "tests" / "engine"
REPORT_DIR = ROOT / "reports" / "engine"
BLOCKED_DIR = ROOT / "build" / "engine"
DEFAULT_PLACE = "build/kits.rbxl"
KITS_PROJECT = "fixtures/kits.project.json"
SCHEMA = "engine-report/1"
NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
LINE_RE = re.compile(r"(ENGINE_CHECK|ENGINE_DONE) (\{.*\})\s*$")
EXIT = {"PASS": 0, "FAIL": 1, "REFUSED": 2, "BLOCKED_EXTERNAL": 3}
# Arguments that would point Studio at a published game, in any spelling (the CLI is case-insensitive).
FORBIDDEN_ARGS = ("--placeid", "--universeid", "--placeversion", "--assetid", "editplace", "editplacerevision", "tryasset")


class Refused(Exception):
    pass


def refuse_published_targets(argv):
    """Raises Refused when any argument targets a published place, universe or asset."""
    for arg in argv:
        text = str(arg).strip().lower()
        for bad in FORBIDDEN_ARGS:
            if text == bad or text.startswith(bad + "=") or (bad.startswith("--") and text.startswith(bad)):
                raise Refused(f"{arg!r} is refused: probes run only on a local unpublished place (--localPlaceFile)")


def probe_names():
    return sorted(p.stem for p in ENGINE_DIR.glob("*.luau") if NAME_RE.match(p.stem))


def probe_script(name):
    if not NAME_RE.match(name or ""):
        raise Refused(f"probe name {name!r} must be lower_snake (a-z, 0-9, _), at most 64 characters")
    path = ENGINE_DIR / f"{name}.luau"
    if not path.is_file():
        raise Refused(f"no probe entry tests/engine/{name}.luau (see --list)")
    return path


def place_file(value):
    """Absolute path of a local place under this repository's build/ directory."""
    path = (ROOT / value).resolve() if not os.path.isabs(value) else Path(value).resolve()
    build = (ROOT / "build").resolve()
    if path.suffix.lower() not in (".rbxl", ".rbxlx"):
        raise Refused(f"{value}: the place must be a local .rbxl or .rbxlx file")
    if build not in path.parents:
        raise Refused(f"{value}: the place must be a file under build/ built from a fixtures project (rojo build {KITS_PROJECT} -o {DEFAULT_PLACE})")
    return path


def find_studio(explicit=None, env=None, system=None):
    """Studio executable, or None. Order: --studio, $ROBLOX_STUDIO, the documented install locations."""
    env = os.environ if env is None else env
    system = system or platform.system()
    for candidate in (explicit, env.get("ROBLOX_STUDIO")):
        if candidate:
            return candidate if Path(candidate).is_file() else None
    if system == "Windows" and env.get("LOCALAPPDATA"):
        found = glob.glob(os.path.join(env["LOCALAPPDATA"], "Roblox", "Versions", "*", "RobloxStudioBeta.exe"))
        return max(found, key=os.path.getmtime) if found else None
    if system == "Darwin":
        mac = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio"
        return mac if Path(mac).is_file() else None
    return None  # Linux: Studio does not exist here


def studio_command(studio, place, script, output):
    cmd = [str(studio), "--task", "RunScript", "--localPlaceFile", str(place), "--runScriptFile", str(script), "--outputFile", str(output), "--quitAfterExecution"]
    refuse_published_targets(cmd[1:])
    return cmd


def parse_output(text):
    """Splits probe output into runs. Returns {"runs": [...], "problems": [...]}; each run is
    {"checks": [...], "done": {...} or None}. Lines may carry a prefix (timestamps, log tags)."""
    runs, problems, current = [], [], []
    for number, raw in enumerate(text.splitlines(), 1):
        match = LINE_RE.search(raw)
        if not match:
            continue
        kind, payload = match.groups()
        try:
            data = json.loads(payload)
        except ValueError as err:
            problems.append(f"line {number}: {kind} carries invalid JSON ({err})")
            continue
        if not isinstance(data, dict):
            problems.append(f"line {number}: {kind} JSON must be an object")
            continue
        if kind == "ENGINE_CHECK":
            missing = [key for key in ("probe", "check", "ok") if key not in data]
            if missing or not isinstance(data.get("ok"), bool):
                problems.append(f"line {number}: ENGINE_CHECK needs probe, check and a boolean ok")
                continue
            current.append(data)
        else:
            runs.append({"checks": current, "done": data})
            current = []
    if current:
        runs.append({"checks": current, "done": None})
        problems.append(f"{len(current)} ENGINE_CHECK line(s) after the last ENGINE_DONE: a run did not finish")
    return {"runs": runs, "problems": problems}


def refuse_lune_output(text, where):
    """Raises Refused when any ENGINE_DONE line says it ran in Lune (tests/fakes/FakeKitSmoke.luau marks
    them "runtime":"lune"): those probes ran against fakes, which is not engine evidence."""
    marked = [run for run in parse_output(text)["runs"] if run["done"] and run["done"].get("runtime") == "lune"]
    if marked:
        raise Refused(f"{where}: {len(marked)} ENGINE_DONE line(s) say runtime lune; Lune output (tools/lune/kit_smoke.luau) "
                      "is not engine evidence and is never recorded under reports/engine. Record the Studio output instead")


def run_problems(run):
    """Consistency of one run's ENGINE_DONE with its ENGINE_CHECK lines (contract: docs/runtime-kits.md)."""
    done, checks = run["done"], run["checks"]
    if done is None:
        return ["no ENGINE_DONE line: the run did not finish"]
    problems = []
    passed = sum(1 for c in checks if c["ok"])
    failed = len(checks) - passed
    errors = len({c["probe"] for c in checks if c.get("check") == "error" and not c["ok"]})
    expect = {"checks": len(checks), "passed": passed, "failed": failed, "errors": errors}
    for key, value in expect.items():
        if done.get(key) != value:
            problems.append(f"ENGINE_DONE {key}={done.get(key)!r} but the check lines give {value}")
    probes = done.get("probes")
    if not isinstance(probes, list) or probes != sorted(probes):
        problems.append("ENGINE_DONE probes must be a sorted list")
    else:
        stray = sorted({c["probe"] for c in checks} - set(probes))
        if stray:
            problems.append(f"check lines name probes missing from ENGINE_DONE: {stray}")
    ok = len(checks) > 0 and failed == 0 and errors == 0
    if done.get("ok") is not ok:
        problems.append(f"ENGINE_DONE ok={done.get('ok')!r} but the checks say {ok}")
    return problems


def evaluate(probe, text):
    """(status, report body) for the probe's output."""
    parsed = parse_output(text)
    problems = list(parsed["problems"])
    runs = parsed["runs"]
    if not runs:
        problems.append("no ENGINE_CHECK or ENGINE_DONE lines in the output")
    for index, run in enumerate(runs):
        problems += [f"run {index + 1}: {p}" for p in run_problems(run)]
    probes_run = sorted({name for run in runs if run["done"] for name in run["done"].get("probes", [])})
    aggregate = probe.endswith("_all")  # kitsmoke_all runs every registry
    if not aggregate and probe not in probes_run:
        problems.append(f"probe {probe} did not run (ENGINE_DONE lists {probes_run})")
    checks = [c for run in runs for c in run["checks"]]
    failed = [c for c in checks if not c["ok"]]
    status = "PASS" if not problems and not failed and checks else "FAIL"
    body = {
        "probes": probes_run,
        "runs": len(runs),
        "checks": len(checks),
        "passed": len(checks) - len(failed),
        "failed": len(failed),
        "failures": [{"probe": c["probe"], "check": c["check"], "detail": c.get("detail")} for c in failed][:50],
        "problems": problems,
        "lines": checks,
    }
    return status, body


USER_DIR = re.compile(r"(?i)([A-Z]:)?([\\/])(Users|home)\2[^\\/\s\"']+")


def scrub(value, secrets):
    """Replaces machine-specific path prefixes in every string (reports are committed): this
    repository and the home directory, then any remaining Users/<name> or home/<name> segment."""
    if isinstance(value, str):
        for secret, placeholder in secrets:
            if secret:
                value = value.replace(secret, placeholder)
        return USER_DIR.sub("<home>", value)
    if isinstance(value, list):
        return [scrub(v, secrets) for v in value]
    if isinstance(value, dict):
        return {k: scrub(v, secrets) for k, v in value.items()}
    return value


def machine_prefixes():
    pairs = [(str(ROOT), "<repo>"), (str(ROOT).replace("\\", "/"), "<repo>"), (str(Path.home()), "<home>"), (str(Path.home()).replace("\\", "/"), "<home>")]
    return sorted({pair for pair in pairs if len(pair[0]) > 1}, key=lambda pair: -len(pair[0]))


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_commit():
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=30)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def build_place(place):
    if shutil.which("rojo") is None:
        raise Refused("--build needs rojo (rokit install)")
    place.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(["rojo", "build", KITS_PROJECT, "-o", str(place)], cwd=ROOT, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise Refused(f"rojo build {KITS_PROJECT} failed: {(proc.stderr or proc.stdout).strip()[-400:]}")


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def report_document(probe, status, body, source, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return {
        "schema": SCHEMA,
        "probe": probe,
        "status": status,
        "date": now.strftime("%Y-%m-%d"),
        "source": source,
        **body,
    }


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        refuse_published_targets(argv)
    except Refused as err:
        print(f"REFUSED {err}")
        return EXIT["REFUSED"]
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--probe", help="tests/engine/<probe>.luau entry to run")
    ap.add_argument("--list", action="store_true", help="list the probe entries")
    ap.add_argument("--place", default=DEFAULT_PLACE, help=f"local place under build/ (default {DEFAULT_PLACE})")
    ap.add_argument("--build", action="store_true", help=f"rojo build {KITS_PROJECT} into the place first")
    ap.add_argument("--studio", help="Studio executable (default: $ROBLOX_STUDIO, then the documented install location)")
    ap.add_argument("--timeout", type=int, default=900, help="seconds before Studio is stopped (default 900)")
    ap.add_argument("--from-output", metavar="FILE", help="parse output captured elsewhere (Studio MCP console, an earlier --outputFile)")
    ap.add_argument("--report-dir", default=str(REPORT_DIR), help=argparse.SUPPRESS)
    ap.add_argument("--blocked-dir", default=str(BLOCKED_DIR), help=argparse.SUPPRESS)
    ap.add_argument("--system", help=argparse.SUPPRESS)  # tests: pretend to be another OS
    args = ap.parse_args(argv)
    if args.list:
        for name in probe_names():
            print(name)
        return 0
    try:
        script = probe_script(args.probe)
    except Refused as err:
        print(f"REFUSED {err}")
        return EXIT["REFUSED"]
    secrets = machine_prefixes()
    source = {"commit": git_commit(), "probe_entry": f"tests/engine/{script.name}", "probe_sha256": sha256_file(script)}

    if args.from_output:
        text = Path(args.from_output).read_text(encoding="utf-8", errors="replace")
        try:
            refuse_lune_output(text, args.from_output)
        except Refused as err:
            print(f"REFUSED {err}")
            return EXIT["REFUSED"]
        # The output's digest ties the report to the captured file; the route says it was not a CLI
        # run here.
        source.update({"route": "from-output", "output_sha256": sha256_file(Path(args.from_output))})
        status, body = evaluate(args.probe, text)
        report = scrub(report_document(args.probe, status, body, source), secrets)
        path = write_report(Path(args.report_dir) / f"{args.probe}.json", report)
        print(f"{status} {args.probe}: {body['passed']}/{body['checks']} checks, {len(body['problems'])} problems -> {os.path.relpath(path, ROOT)}")
        for problem in body["problems"]:
            print(f"  problem: {problem}")
        return EXIT[status]

    studio = find_studio(args.studio, system=args.system)
    if studio is None:
        why = "Roblox Studio is not installed here (it runs only on Windows and macOS)"
        report = scrub(report_document(args.probe, "BLOCKED_EXTERNAL", {"problems": [why]}, {**source, "route": "studio-cli"}), secrets)
        path = write_report(Path(args.blocked_dir) / f"{args.probe}.json", report)
        print(f"BLOCKED_EXTERNAL {args.probe}: {why}. Run it on the owner's PC; nothing under reports/ was written ({os.path.relpath(path, ROOT)}).")
        return EXIT["BLOCKED_EXTERNAL"]
    try:
        place = place_file(args.place)
        if args.build:
            build_place(place)
        if not place.is_file():
            raise Refused(f"{args.place} does not exist (pass --build)")
        with tempfile.TemporaryDirectory(prefix="studio-run-") as tmp:
            output = Path(tmp) / "output.log"
            cmd = studio_command(studio, place, script.resolve(), output)
            try:
                proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=args.timeout)
                text = (output.read_text(encoding="utf-8", errors="replace") if output.exists() else "") or proc.stdout
                exit_note = f"exit {proc.returncode}"
            except subprocess.TimeoutExpired as err:
                text = (output.read_text(encoding="utf-8", errors="replace") if output.exists() else "") or (err.stdout or "")
                text = text.decode("utf-8", "replace") if isinstance(text, bytes) else text
                exit_note = f"timed out after {args.timeout}s"
        refuse_lune_output(text, "the Studio run's output")
    except Refused as err:
        print(f"REFUSED {err}")
        return EXIT["REFUSED"]
    source.update({"route": "studio-cli", "place": os.path.relpath(place, ROOT).replace("\\", "/"), "place_sha256": sha256_file(place), "studio_exit": exit_note})
    status, body = evaluate(args.probe, text)
    report = scrub(report_document(args.probe, status, body, source), secrets)
    path = write_report(Path(args.report_dir) / f"{args.probe}.json", report)
    print(f"{status} {args.probe}: {body['passed']}/{body['checks']} checks ({exit_note}) -> {os.path.relpath(path, ROOT)}")
    for problem in body["problems"]:
        print(f"  problem: {problem}")
    return EXIT[status]


if __name__ == "__main__":
    sys.exit(main())
