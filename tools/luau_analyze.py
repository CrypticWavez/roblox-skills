"""luau-lsp type analysis with a no-regression baseline.

  python3 tools/luau_analyze.py                     analyze, compare with tests/golden/luau-lsp-baseline.json
  python3 tools/luau_analyze.py --update-baseline   rewrite the baseline (lowering it is the point; say why)
  python3 tools/luau_analyze.py --from-output FILE  compare canned analyzer output (stderr, gnu format)

Runs the pinned `luau-lsp analyze` (rokit.toml) over packages/ and fixtures/ with a Rojo sourcemap of
fixtures/kits.project.json (every package plus the kit fixtures) and the Roblox definitions pinned in
luau-defs.lock.json (fetch them with python3 tools/luau_defs.py). Diagnostics are counted per file;
the run fails when any file has more than the baseline records (a new file with diagnostics counts
from zero). Fewer is reported so the baseline can be ratcheted down. The baseline is a ratchet, not a
clean slate: the first one recorded the existing diagnostics as they were.

Exit codes: 0 no regression, 1 regression or broken setup, 2 usage, 3 luau-lsp not installed
(SKIPPED: CI installs it with rokit; this container has no release binary unless one is built).
luau-lsp's own exit code is kept: 0, or 1 with diagnostics, is a finished analysis; a signal, any other
code, or 1 with nothing parsed is a crash or a rejected argument and fails with the output's tail.
--from-output has no exit code, so non-empty output with neither a diagnostic nor a log line fails.
Writes build/luau-lsp/report.json (every diagnostic) and never touches the network.
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luau_defs  # noqa: E402  (sibling tool)

BASELINE = ROOT / "tests" / "golden" / "luau-lsp-baseline.json"
CACHE = ROOT / "build" / "luau-lsp"
PROJECT = "fixtures/kits.project.json"
TARGETS = ["packages", "fixtures"]
SCHEMA = "luau-lsp-baseline/1"
EXIT_SKIPPED = 3
# gnu formatter: <path>[ [<DataModel path>]]:<line>.<col>-<line>.<col>: <Type>: <message>
DIAGNOSTIC = re.compile(r"^(?P<path>.+?)(?: \[[^\]]*\])?:(?P<line>\d+)\.(?P<col>\d+)-(?P<end_line>\d+)\.(?P<end_col>\d+): (?P<type>[A-Za-z][\w]*): (?P<message>.*)$")
LOG_LINE = re.compile(r"^\[(INFO|WARN|WARNING|ERROR|DEBUG)\] ")
TAIL_LINES = 20


def pinned_version(rokit=ROOT / "rokit.toml"):
    match = re.search(r'^luau-lsp\s*=\s*"[^"@]+@([^"]+)"', Path(rokit).read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1) if match else None


def relative(path, root=ROOT):
    """Repo-relative posix path for an analyzer path (absolute or relative to the root)."""
    text = path.replace("\\", "/")
    root_text = str(root).replace("\\", "/").rstrip("/") + "/"
    if text.startswith(root_text):
        text = text[len(root_text):]
    elif os.path.isabs(text):
        try:
            text = Path(os.path.relpath(text, root)).as_posix()
        except ValueError:
            pass
    return text[2:] if text.startswith("./") else text


def parse(text, root=ROOT):
    """(diagnostics, errors): diagnostics de-duplicated (luau-lsp can report a module twice), in order;
    errors are [ERROR] log lines. Continuation lines extend the previous message."""
    diagnostics, errors, current = [], [], None
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        log = LOG_LINE.match(line)
        if log:
            current = None
            if log.group(1) == "ERROR":
                errors.append(line)
            continue
        match = DIAGNOSTIC.match(line)
        if match:
            current = {
                "path": relative(match.group("path"), root),
                "line": int(match.group("line")),
                "col": int(match.group("col")),
                "end_line": int(match.group("end_line")),
                "end_col": int(match.group("end_col")),
                "type": match.group("type"),
                "message": match.group("message"),
            }
            diagnostics.append(current)
        elif current is not None:
            current["message"] += "\n" + line
    # A module reached twice is reported twice; keep one copy of each full diagnostic.
    unique, keys = [], set()
    for item in diagnostics:
        key = json.dumps(item, sort_keys=True)
        if key not in keys:
            keys.add(key)
            unique.append(item)
    return unique, errors


def exit_problem(code, diagnostics):
    """Why luau-lsp's exit code says the analysis did not finish, or None. It exits 1 when it reports
    diagnostics, so only 0 and 1-with-diagnostics are a finished run."""
    if code < 0:
        return f"luau-lsp was killed by signal {-code}"
    if code not in (0, 1):
        return f"luau-lsp exited {code}"
    if code != 0 and not diagnostics:
        return f"luau-lsp exited {code} without a diagnostic it could be counted from"
    return None


def unrecognised(text, diagnostics):
    """True when non-empty output holds neither a diagnostic nor a luau-lsp log line (a crash message,
    an unprefixed error, the wrong file)."""
    lines = [line for line in text.splitlines() if line.strip()]
    return bool(lines) and not diagnostics and not any(LOG_LINE.match(line) for line in lines)


def tail(text, count=TAIL_LINES):
    lines = [line.rstrip("\r") for line in text.splitlines() if line.strip()]
    return lines[-count:] or ["(no output)"]


def summarise(diagnostics):
    """{path: {"total": n, "by_type": {type: n}}} sorted by path."""
    per_file = collections.defaultdict(collections.Counter)
    for item in diagnostics:
        per_file[item["path"]][item["type"]] += 1
    return {path: {"total": sum(counts.values()), "by_type": dict(sorted(counts.items()))} for path, counts in sorted(per_file.items())}


def compare(baseline_files, current_files):
    """(increases, decreases): lists of (path, baseline_total, current_total)."""
    increases, decreases = [], []
    for path in sorted(set(baseline_files) | set(current_files)):
        before = baseline_files.get(path, {}).get("total", 0)
        after = current_files.get(path, {}).get("total", 0)
        if after > before:
            increases.append((path, before, after))
        elif after < before:
            decreases.append((path, before, after))
    return increases, decreases


def baseline_document(files, version, definitions_sha):
    return {
        "schema": SCHEMA,
        "luau_lsp": version,
        "definitions_sha256": definitions_sha,
        "project": PROJECT,
        "targets": TARGETS,
        "note": "No-regression ratchet for tools/luau_analyze.py: per-file diagnostic counts may only go down. Rewrite with --update-baseline and say why in the commit.",
        "total": sum(entry["total"] for entry in files.values()),
        "files": files,
    }


def find_binary(explicit=None):
    candidate = explicit or os.environ.get("LUAU_LSP") or shutil.which("luau-lsp")
    return candidate if candidate and Path(candidate).is_file() else None


def run_analyzer(binary, definitions, sourcemap, timeout=600):
    cmd = [
        binary, "analyze", "--platform", "roblox", "--formatter", "gnu",
        "--sourcemap", str(sourcemap), f"--definitions:@roblox={definitions}", *TARGETS,
    ]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stderr + proc.stdout


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--update-baseline", action="store_true", help="rewrite tests/golden/luau-lsp-baseline.json")
    ap.add_argument("--from-output", metavar="FILE", help="parse canned analyzer output instead of running luau-lsp")
    ap.add_argument("--luau-lsp", metavar="PATH", help="luau-lsp binary (default: $LUAU_LSP, then PATH)")
    ap.add_argument("--baseline", default=str(BASELINE), help=argparse.SUPPRESS)
    ap.add_argument("--report", default=str(CACHE / "report.json"), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    baseline_path = Path(args.baseline)
    lock = luau_defs.load_lock()
    definitions_entry = next(entry for entry in lock["files"] if entry["role"] == "definitions")
    version = pinned_version()

    code = None  # --from-output: no exit code to check
    if args.from_output:
        text = Path(args.from_output).read_text(encoding="utf-8", errors="replace")
    else:
        binary = find_binary(args.luau_lsp)
        if binary is None:
            print("SKIPPED luau-lsp is not installed (rokit install; CI installs the pinned release). Nothing was analyzed.")
            return EXIT_SKIPPED
        got = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=60).stdout.strip()
        if got != version:
            print(f"FAIL luau-lsp {got or '?'} is not the pinned {version} (rokit.toml); the baseline is only comparable at the pin")
            return 1
        bad = [entry["name"] for entry, _, state in luau_defs.cached_state(lock) if state != "ok"]
        if bad:
            print(f"FAIL pinned definitions missing or changed: {', '.join(bad)} (run python3 tools/luau_defs.py)")
            return 1
        if shutil.which("rojo") is None:
            print("SKIPPED rojo is not installed (needed for the sourcemap). Nothing was analyzed.")
            return EXIT_SKIPPED
        sourcemap = CACHE / "sourcemap.json"
        sourcemap.parent.mkdir(parents=True, exist_ok=True)
        made = subprocess.run(["rojo", "sourcemap", PROJECT, "--absolute", "--output", str(sourcemap)], cwd=ROOT, capture_output=True, text=True, timeout=120)
        if made.returncode != 0:
            print(f"FAIL rojo sourcemap {PROJECT}: {(made.stderr or made.stdout).strip()[-400:]}")
            return 1
        code, text = run_analyzer(binary, CACHE / definitions_entry["name"], sourcemap)

    diagnostics, errors = parse(text)
    broken = exit_problem(code, diagnostics) if code is not None else (
        "the output has no diagnostic and no luau-lsp log line" if unrecognised(text, diagnostics) else None)
    if broken:
        print(f"FAIL {broken}; nothing was compared with the baseline. Last lines of the output:")
        for line in tail(text):
            print(f"     {line}")
        return 1
    if errors:
        for line in errors:
            print(f"FAIL analyzer error: {line}")
        return 1
    files = summarise(diagnostics)
    write_json(Path(args.report), {"luau_lsp": version, "total": len(diagnostics), "files": files, "diagnostics": diagnostics})
    document = baseline_document(files, version, definitions_entry["sha256"])
    if args.update_baseline:
        write_json(baseline_path, document)
        print(f"baseline written: {document['total']} diagnostics in {len(files)} files ({baseline_path.relative_to(ROOT) if baseline_path.is_relative_to(ROOT) else baseline_path})")
        return 0
    if not baseline_path.exists():
        print(f"FAIL {baseline_path.name} is missing (record one with --update-baseline)")
        return 1
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    if baseline.get("schema") != SCHEMA:
        print(f"FAIL baseline schema must be {SCHEMA}")
        return 1
    stale = []
    if baseline.get("luau_lsp") != version:
        stale.append(f"baseline was recorded with luau-lsp {baseline.get('luau_lsp')}, the pin is {version}")
    if baseline.get("definitions_sha256") != definitions_entry["sha256"]:
        stale.append("baseline was recorded with other definitions than luau-defs.lock.json pins")
    if stale:
        for line in stale:
            print(f"FAIL {line}; re-record it with --update-baseline in the same commit as the pin change")
        return 1
    increases, decreases = compare(baseline.get("files", {}), files)
    for path, before, after in increases:
        print(f"FAIL {path}: {after} diagnostics, baseline {before}")
        for item in [d for d in diagnostics if d["path"] == path][:5]:
            print(f"     {item['line']}:{item['col']} {item['type']}: {item['message'].splitlines()[0]}")
    for path, before, after in decreases:
        print(f"lower {path}: {after} diagnostics, baseline {before} (ratchet down with --update-baseline)")
    print(f"luau-lsp {version}: {len(diagnostics)} diagnostics in {len(files)} files; baseline {baseline.get('total')}; {len(increases)} files over, {len(decreases)} under")
    return 1 if increases else 0


if __name__ == "__main__":
    sys.exit(main())
