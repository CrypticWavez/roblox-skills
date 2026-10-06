"""Tier headers and probe evidence for every kit module: write or check reports/kit-tiers.json.

  python3 tools/kit_tiers.py           check the rules and write reports/kit-tiers.json
  python3 tools/kit_tiers.py --check   check the rules and that reports/kit-tiers.json is current (writes nothing)
  python3 tools/kit_tiers.py --print   print the report instead of writing it

Rules (docs/runtime-kits.md sections 5 and 7; tests/kits_load.spec.luau enforces the same headers in Lune):
- every module under packages/{GameKit,UIKit,AVKit,Feel,Cinematics} starts with --!strict and its header
  comment block holds exactly one `-- @tier T0..T4` line; any other package module that carries a tier
  line is held to the same rules (Diagnostics/PerfProbeRoblox, Pipeline/KitSmoke);
- a T3 module names its probes, one `-- probe: <name>` line each (at least one); a T4 module may;
- a probe name is a lower_snake label with an owner prefix listed in docs/runtime-kits.md section 7, and it
  is registered: a whole word in a fixtures/kits/<side>/*_probes.luau registry, or tests/engine/<probe>.luau.

Evidence per probe comes from reports/engine/<probe>.json, or from reports/engine/kitsmoke_all.json when the
probe ran there (tools/studio_run.py writes both). Without a report a probe is PENDING; a report that is not
an engine-report/1 object with a studio_run route and status PASS, FAIL or BLOCKED_EXTERNAL is INVALID_REPORT
and a problem. A T3 module is proven only when every probe it names passes, and T4 is never claimed here.
The report has no dates, so it changes only when headers, registrations or engine reports change. Exit 0
when the rules hold (and, with --check, the report is current), else 1.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KITS = ("GameKit", "UIKit", "AVKit", "Feel", "Cinematics")
REPORT = "reports/kit-tiers.json"
SCHEMA = "kit-tiers/1"
CONTRACT = "docs/runtime-kits.md"
TIER_LINE = re.compile(r"^-- @tier (T\d)\s*$")
TIER_LOOSE = re.compile(r"^--\s*@tier")
PROBE_LINE = re.compile(r"^-- probe: (\S+)\s*$")
PROBE_NAME = re.compile(r"^[a-z][a-z0-9_]+$")
SIDES = ("shared", "server", "client")
ENGINE_SCHEMA = "engine-report/1"
ENGINE_ROUTES = ("studio-cli", "from-output")  # tools/studio_run.py
ENGINE_STATUSES = ("PASS", "FAIL", "BLOCKED_EXTERNAL")


def owner_prefixes(root):
    """Probe-name prefixes from the contract's 'Name.' bullet in section 7."""
    text = (root / CONTRACT).read_text(encoding="utf-8")
    for line in text.splitlines():
        if line.startswith("- **Name.**"):
            prefixes = sorted(set(re.findall(r"`([a-z][a-z0-9]*_)`", line)))
            if prefixes:
                return prefixes
    raise ValueError(f"{CONTRACT}: no '- **Name.**' line with owner prefixes")


def parse_header(text):
    lines = text.split("\n")
    header = {"strict": lines[0].rstrip("\r") == "--!strict", "tier": None, "probes": [], "problems": []}
    tiers = 0
    for raw in lines[1:]:
        line = raw.rstrip("\r")
        if not line.startswith("--"):
            break
        match = TIER_LINE.match(line)
        if match:
            tiers += 1
            header["tier"] = match.group(1)
        elif TIER_LOOSE.match(line):
            header["problems"].append(f"malformed tier line: {line}")
        probe = PROBE_LINE.match(line)
        if probe:
            if probe.group(1) in header["probes"]:
                header["problems"].append(f"probe {probe.group(1)} is named twice")
            else:
                header["probes"].append(probe.group(1))
    if tiers > 1:
        header["problems"].append("more than one @tier line")
    return header


def strip_comments(text):
    """Luau source without comments, so a probe named only in a comment is not 'registered'."""
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def registries(root):
    """{ 'fixtures/kits/<side>/<file>': code } for every *_probes.luau registry (comments removed)."""
    found = {}
    for side in SIDES:
        base = root / "fixtures" / "kits" / side
        if base.is_dir():
            for path in sorted(base.rglob("*_probes.luau")):
                found[path.relative_to(root).as_posix()] = strip_comments(path.read_text(encoding="utf-8"))
    return found


def registered_in(probe, regs, root):
    places = [rel for rel, text in regs.items() if re.search(rf"(?<![\w]){re.escape(probe)}(?![\w])", text)]
    entry = root / "tests" / "engine" / f"{probe}.luau"
    if entry.is_file():
        places.append(entry.relative_to(root).as_posix())
    return sorted(places)


def modules(root):
    """(rel, text, is_kit) for kit modules and for other package modules that carry a tier line."""
    out = []
    packages = root / "packages"
    for path in sorted(packages.rglob("*.luau")):
        rel = path.relative_to(root).as_posix()
        package = path.relative_to(packages).parts[0]
        text = path.read_text(encoding="utf-8")
        is_kit = package in KITS
        if is_kit or any(TIER_LOOSE.match(line) for line in text.split("\n")[1:40]):
            out.append((rel, text, is_kit))
    return out


def report_problem(doc):
    """Why a parsed reports/engine document is not engine evidence, or None."""
    if not isinstance(doc, dict):
        return "is not a JSON object"
    if doc.get("schema") != ENGINE_SCHEMA:
        return f"schema is {doc.get('schema')!r}, not {ENGINE_SCHEMA}"
    source = doc.get("source")
    route = source.get("route") if isinstance(source, dict) else None
    if route not in ENGINE_ROUTES:
        return f"source.route is {route!r}, not one of {', '.join(ENGINE_ROUTES)} (tools/studio_run.py)"
    if doc.get("status") not in ENGINE_STATUSES:
        return f"status is {doc.get('status')!r}, not one of {', '.join(ENGINE_STATUSES)}"
    if not isinstance(doc.get("probes", []), list):
        return "probes is not a list"
    return None


def engine_evidence(probe, root):
    """(status, report path, why) from reports/engine; PENDING when no report names the probe. why says
    what is wrong with the report when the status is INVALID_REPORT, else it is None."""
    engine = root / "reports" / "engine"
    own = engine / f"{probe}.json"
    candidates = [own] if own.is_file() else []
    combined = engine / "kitsmoke_all.json"
    if combined.is_file():
        candidates.append(combined)
    for path in candidates:
        rel = path.relative_to(root).as_posix()
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):  # no error text: it can carry a machine path into the report
            return "INVALID_REPORT", rel, "is not readable JSON"
        why = report_problem(doc)
        if why:
            return "INVALID_REPORT", rel, why
        if path == own or probe in doc.get("probes", []):
            status = doc["status"]
            if path != own and status == "PASS":
                failed = {f.get("probe") for f in doc.get("failures") or [] if isinstance(f, dict)}
                status = "FAIL" if probe in failed else "PASS"
            return status, rel, None
    return "PENDING", None, None


def build(root):
    prefixes = owner_prefixes(root)
    regs = registries(root)
    problems, rows, probes = [], [], {}
    for rel, text, is_kit in modules(root):
        header = parse_header(text)
        own = []
        if rel.endswith("/init.luau") and is_kit:
            own.append("init.luau is not used in kits")
        if not header["strict"]:
            own.append("line 1 must be --!strict")
        own.extend(header["problems"])
        tier = header["tier"]
        if tier is None:
            own.append("header needs a '-- @tier T0..T4' line")
        elif tier not in ("T0", "T1", "T2", "T3", "T4"):
            own.append(f"tier {tier} is not T0..T4")
        named = header["probes"]
        if tier == "T3" and not named:
            own.append("a T3 module names its probe: '-- probe: <name>'")
        for probe in named:
            if not PROBE_NAME.match(probe) or len(probe) > 64 or not any(probe.startswith(p) for p in prefixes):
                own.append(f"probe {probe} needs a lower_snake name with an owner prefix ({CONTRACT} section 7)")
            else:
                places = registered_in(probe, regs, root)
                if not places:
                    own.append(f"probe {probe} is not registered (fixtures/kits/<side>/*_probes.luau or tests/engine/{probe}.luau)")
                entry = probes.setdefault(probe, {"name": probe, "modules": [], "registered_in": places})
                entry["modules"].append(rel)
        row = {"path": rel, "kit": is_kit, "tier": tier}
        if named:
            row["probes"] = named
        rows.append(row)
        problems.extend(f"{rel}: {p}" for p in own)
    probe_rows, invalid = [], {}
    for name in sorted(probes):
        entry = probes[name]
        status, report, why = engine_evidence(name, root)
        if why:
            invalid[report] = why
        runner = f"tests/engine/{name}.luau" if (root / "tests" / "engine" / f"{name}.luau").is_file() else (
            "tests/engine/kitsmoke_all.luau" if any(p.startswith("fixtures/") for p in entry["registered_in"]) else None)
        row = {**entry, "evidence": status, "runner": runner}
        if report:
            row["report"] = report
        probe_rows.append(row)
    problems.extend(f"{report}: {why}; it is not engine evidence (tools/studio_run.py writes {ENGINE_SCHEMA})" for report, why in sorted(invalid.items()))
    by_tier, evidence = {}, {}
    for row in rows:
        by_tier[row["tier"] or "none"] = by_tier.get(row["tier"] or "none", 0) + 1
    for row in probe_rows:
        evidence[row["evidence"]] = evidence.get(row["evidence"], 0) + 1
    t3 = [r for r in rows if r["tier"] == "T3"]
    passing = {p["name"] for p in probe_rows if p["evidence"] == "PASS"}
    t3_proven = [r for r in t3 if r.get("probes") and all(name in passing for name in r["probes"])]
    return {
        "schema": SCHEMA,
        "counts": {
            "modules": len(rows),
            "kit_modules": sum(1 for r in rows if r["kit"]),
            "by_tier": dict(sorted(by_tier.items())),
            "probes": len(probe_rows),
            "evidence": dict(sorted(evidence.items())),
            "t3_modules": len(t3),
            "t3_with_passing_probe": len(t3_proven),
        },
        "modules": rows,
        "probes": probe_rows,
        "problems": problems,
    }


def render(report):
    return json.dumps(report, indent=2, sort_keys=True) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help=f"check the rules and that {REPORT} is current; write nothing")
    mode.add_argument("--print", action="store_true", help="print the report to stdout instead of writing it")
    ap.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    root = Path(args.root)
    try:
        report = build(root)
    except (OSError, ValueError) as err:
        print(f"kit_tiers: {err}", file=sys.stderr)
        return 1
    text = render(report)
    for problem in report["problems"]:
        print(f"PROBLEM {problem}")
    counts = report["counts"]
    summary = (f"kit_tiers: {counts['modules']} modules ({counts['kit_modules']} kit), tiers {counts['by_tier']}, "
               f"{counts['probes']} probes, evidence {counts['evidence'] or {}}, "
               f"T3 with every probe passing {counts['t3_with_passing_probe']}/{counts['t3_modules']}")
    path = root / REPORT
    if args.print:
        sys.stdout.write(text)
    elif args.check:
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current != text:
            state = "MISSING" if current is None else "STALE"
            print(f"{state} {REPORT}: run python3 tools/kit_tiers.py to regenerate it")
            print(summary)
            return 1
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        summary += f" -> {REPORT}"
    print(summary)
    return 1 if report["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
