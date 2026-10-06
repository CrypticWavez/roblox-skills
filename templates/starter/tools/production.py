"""Production data shared by the gate (step `brief`), the release checker and the issue planner.

  python3 tools/production.py status      current stage, its exit gates, undecided brief fields

Formats (factory-managed; the game's values live in the JSON files, never here):
- game-brief/1 (production/brief.json): what the game is. Every field starts "TBD" and is decided only
  from the game-build request or by the owner, then logged in docs/decisions.md and mirrored in the
  AGENTS.md tables (Brief key column). TBD is allowed before alpha, except for the fields named by the
  brief gates of stages already passed; from alpha on every required field is decided.
- production-pipeline/1 (production/pipeline.json): the stages concept, greybox, vertical-slice, alpha,
  beta and release-candidate, each with exit gates of kind brief, file, gate, release, playtest or
  owner. Moving `current` past a stage needs that stage's owner and playtest gates recorded in a
  release/owner-*.json file (release-owner/1), which only the owner writes.
The genre list is Roblox's 17-genre taxonomy (Genres doc, updated 2026-10-02); the engine enums are
from the Roblox API reflection data (2026). Nothing here chooses a genre, theme or any game content.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIEF = ROOT / "production" / "brief.json"
PIPELINE = ROOT / "production" / "pipeline.json"
BRIEF_SCHEMA = "game-brief/1"
PIPELINE_SCHEMA = "production-pipeline/1"
OWNER_SCHEMA = "release-owner/1"
TBD = "TBD"

STAGES = ["concept", "greybox", "vertical-slice", "alpha", "beta", "release-candidate"]
ALL_DECIDED_FROM = "alpha"
GATE_KINDS = {"brief", "file", "gate", "release", "playtest", "owner"}
CHECK_TIERS = {"fast", "pre-commit", "pre-release"}
RELEASE_ID = re.compile(r"^[ASOP]\d{2}$")
LABEL = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
LOCALE = re.compile(r"^[a-z]{2,3}(-[a-z0-9]{2,4})?$")
DESIGN_STATUS = re.compile(r"^Status:\s*(\S+)", re.MULTILINE)

# Roblox genres and subgenres (an empty list: the genre has no subgenres).
GENRES = {
    "Action": ["Battlegrounds & Fighting", "Music & Rhythm", "Open World Action"],
    "Adventure": ["Exploration", "Scavenger Hunt", "Story"],
    "Education": [],
    "Entertainment": ["Music & Audio", "Showcase & Hub", "Video"],
    "Obby & Platformer": ["Classic Obby", "Runner", "Tower Obby"],
    "Party & Casual": ["Childhood Game", "Coloring & Drawing", "Minigame", "Quiz"],
    "Puzzle": ["Escape Room", "Match & Merge", "Word"],
    "RPG": ["Action RPG", "Open World & Survival RPG", "Turn-based RPG"],
    "Roleplay & Avatar Sim": ["Animal Sim", "Dress Up", "Life", "Morph Roleplay", "Pet Care"],
    "Shooter": ["Battle Royale", "Deathmatch Shooter", "PvE Shooter"],
    "Shopping": ["Avatar Shopping"],
    "Simulation": ["Idle", "Incremental Simulator", "Physics Sim", "Sandbox", "Tycoon", "Vehicle Sim"],
    "Social": [],
    "Sports & Racing": ["Racing", "Sports"],
    "Strategy": ["Board & Card Games", "Tower Defense"],
    "Survival": ["1 vs All", "Escape"],
    "Utility & Other": [],
}
# Playable devices in the experience settings, and the perf/1 device classes that cover each.
DEVICES = {"computer": ["desktop"], "phone": ["phone", "phone_low"], "tablet": ["tablet"], "console": ["console"], "vr": ["desktop"]}
MATURITY_LABELS = ["Minimal", "Mild", "Moderate", "Restricted"]
# Engine settings the brief records (brief key -> (property, allowed values or bool)).
ENGINE = {
    "authority_mode": ("Workspace.AuthorityMode", ["Automatic", "Server"]),
    "streaming_enabled": ("Workspace.StreamingEnabled", bool),
    "signal_behavior": ("Workspace.SignalBehavior", ["Default", "Immediate", "Deferred", "AncestryDeferred"]),
    "lighting_style": ("Lighting.LightingStyle", ["Realistic", "Soft"]),
    "prioritize_lighting_quality": ("Lighting.PrioritizeLightingQuality", bool),
    "avatar_type": ("Game Settings > Avatar (StarterPlayer.GameSettingsAvatar)", ["R6", "R15", "PlayerChoice"]),
    "default_listener_location": ("SoundService.DefaultListenerLocation", ["Default", "None", "Character", "Camera"]),
}

# game-brief/1 fields: key -> (kind, required). Optional fields may stay empty; "TBD" is undecided.
BRIEF_FIELDS = {
    "name": ("text", True),
    "pitch": ("text", True),
    "pillars": ("texts", True),
    "genre": ("genre", True),
    "theme_and_setting": ("text", True),
    "world": ("text", True),
    "characters": ("text_or_texts", True),
    "core_loop": ("text", True),
    "progression": ("text", True),
    "economy": ("text", True),
    "monetization": ("text_or_texts", True),
    "social": ("text", True),
    "ui_direction": ("text", True),
    "art_direction": ("text", True),
    "audio_direction": ("text", True),
    "audience": ("audience", True),
    "devices": ("devices", True),
    "players_per_server": ("players", True),
    "session_minutes": ("positive", True),
    "locales": ("locales", True),
    "kits": ("kits", True),
    "engine": ("engine", True),
    "references": ("texts_or_empty", False),
    "success_metrics": ("texts", True),
    "open_questions": ("texts_or_empty", False),
}


def is_tbd(value):
    """True when a value or any part of it is still "TBD"."""
    if isinstance(value, str):
        return value.strip().upper() == TBD
    if isinstance(value, dict):
        return any(is_tbd(v) for v in value.values())
    if isinstance(value, list):
        return any(is_tbd(v) for v in value)
    return False  # numbers, booleans and null (an explicit "none", e.g. no subgenre) are decided


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")), None
    except (OSError, ValueError) as err:
        return None, f"{Path(path).name}: {err}"


def text_ok(value):
    return isinstance(value, str) and bool(value.strip())


def field_problems(key, kind, value, modules=None):
    """Type problems of one decided brief field (empty when fine). Undecided parts are not judged here."""
    p = []

    def need(cond, why):
        if not cond:
            p.append(f"{key}: {why}")

    if kind == "text":
        need(text_ok(value), "a non-empty string")
    elif kind in ("texts", "texts_or_empty"):
        ok = isinstance(value, list) and all(text_ok(v) for v in value)
        need(ok and (kind == "texts_or_empty" or len(value) > 0), "a list of non-empty strings")
    elif kind == "text_or_texts":
        need(text_ok(value) or (isinstance(value, list) and value and all(text_ok(v) for v in value)), "a string or a list of strings")
    elif kind == "positive":
        need(isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0, "a positive number")
    elif kind == "genre":
        if not isinstance(value, dict):
            return [f"{key}: an object {{primary, subgenre}}"]
        primary, sub = value.get("primary"), value.get("subgenre")
        if not is_tbd(primary):
            need(primary in GENRES, f"primary {primary!r} is not one of Roblox's 17 genres")
        if not is_tbd(sub) and primary in GENRES:
            need(sub is None or sub in GENRES[primary], f"subgenre {sub!r} is not a subgenre of {primary} (null when none)")
    elif kind == "audience":
        if not isinstance(value, dict):
            return [f"{key}: an object {{age_target, maturity_label}}"]
        if not is_tbd(value.get("age_target")):
            need(text_ok(value.get("age_target")), "age_target a non-empty string")
        label = value.get("maturity_label")
        if not is_tbd(label):
            need(label in MATURITY_LABELS, f"maturity_label one of {MATURITY_LABELS}")
    elif kind == "devices":
        need(isinstance(value, list) and value and all(v in DEVICES for v in value), f"a non-empty list from {sorted(DEVICES)}")
    elif kind == "players":
        if not isinstance(value, dict):
            return [f"{key}: an object {{max, preferred}}"]
        top, preferred = value.get("max"), value.get("preferred")
        for name, number in (("max", top), ("preferred", preferred)):
            if not is_tbd(number):
                need(isinstance(number, int) and not isinstance(number, bool) and number >= 1, f"{name} an integer >= 1")
        if isinstance(top, int) and isinstance(preferred, int):
            need(preferred <= top, "preferred must not exceed max")
    elif kind == "locales":
        if not isinstance(value, dict):
            return [f"{key}: an object {{source, targets}}"]
        if not is_tbd(value.get("source")):
            need(isinstance(value.get("source"), str) and LOCALE.match(value["source"]), "source a lowercase locale id (en-us)")
        targets = value.get("targets")
        if not is_tbd(targets):
            need(isinstance(targets, list) and all(isinstance(t, str) and LOCALE.match(t) for t in targets), "targets a list of locale ids")
    elif kind == "kits":
        if not (isinstance(value, list) and all(isinstance(v, str) for v in value)):
            return [f"{key}: a list of package or Package/Module names"]
        for name in value:
            if modules is not None and name not in modules and not any(m.startswith(name + "/") for m in modules):
                p.append(f"{key}: {name} is not installed (starter.json modules)")
    elif kind == "engine":
        if not isinstance(value, dict):
            return [f"{key}: an object of engine settings"]
        missing = sorted(set(ENGINE) - set(value))
        need(not missing, f"missing {missing}")
        for name, setting in value.items():
            if name not in ENGINE:
                p.append(f"{key}.{name}: unknown engine setting")
                continue
            if is_tbd(setting):
                continue
            allowed = ENGINE[name][1]
            if allowed is bool:
                need(isinstance(setting, bool), f"{name} true or false")
            else:
                need(setting in allowed, f"{name} one of {allowed}")
    return p


def brief_problems(brief, stage=None, pipeline=None, modules=None):
    """Problems with a game-brief/1 document for the given current stage (None: types only)."""
    if not isinstance(brief, dict):
        return ["brief.json must be an object"]
    problems = []
    if brief.get("schema") != BRIEF_SCHEMA:
        problems.append(f"schema must be {BRIEF_SCHEMA!r}")
    unknown = sorted(set(brief) - set(BRIEF_FIELDS) - {"schema"})
    if unknown:
        problems.append(f"unknown fields {unknown} (game-brief/1 has {sorted(BRIEF_FIELDS)})")
    for key, (kind, _required) in BRIEF_FIELDS.items():
        if key not in brief:
            problems.append(f"{key}: missing (use \"TBD\" while undecided)")
            continue
        value = brief[key]
        if isinstance(value, str) and is_tbd(value):
            continue
        problems += field_problems(key, kind, value, modules)
    if stage is not None and pipeline is not None:
        index = STAGES.index(stage) if stage in STAGES else 0
        needed = {}
        for passed in pipeline.get("stages", [])[:index]:
            for gate in passed.get("exit", []):
                if gate.get("kind") == "brief":
                    for field in gate.get("fields", []):
                        needed.setdefault(field, passed.get("id"))
        if index >= STAGES.index(ALL_DECIDED_FROM):
            for key, (_kind, required) in BRIEF_FIELDS.items():
                if required:
                    needed.setdefault(key, ALL_DECIDED_FROM)
        for field, by in sorted(needed.items()):
            if field in brief and is_tbd(brief[field]):
                problems.append(f"{field}: still TBD but the {by} stage needs it decided (current stage {stage})")
    return problems


def undecided(brief):
    return sorted(k for k, (_kind, required) in BRIEF_FIELDS.items() if required and is_tbd(brief.get(k, TBD)))


def owner_records(root=ROOT):
    """{id: {file, date, note}} from release/owner-*.json (release-owner/1) plus problems found."""
    records, problems = {}, []
    for path in sorted((Path(root) / "release").glob("owner-*.json")):
        data, err = load_json(path)
        if err:
            problems.append(err)
            continue
        if not isinstance(data, dict) or data.get("schema") != OWNER_SCHEMA:
            problems.append(f"{path.name}: schema must be {OWNER_SCHEMA!r}")
            continue
        for record in data.get("records", []):
            if isinstance(record, dict) and isinstance(record.get("id"), str) and record.get("date"):
                records[record["id"]] = {"file": f"release/{path.name}", "date": str(record["date"]), "note": str(record.get("note", ""))}
            else:
                problems.append(f"{path.name}: each record needs id and date")
    return records, problems


def pipeline_problems(pipeline, brief_keys=None):
    if not isinstance(pipeline, dict) or pipeline.get("schema") != PIPELINE_SCHEMA:
        return [f"pipeline.json: schema must be {PIPELINE_SCHEMA!r}"]
    problems = []
    stages = pipeline.get("stages")
    ids = [s.get("id") for s in stages] if isinstance(stages, list) and all(isinstance(s, dict) for s in stages) else None
    if ids != STAGES:
        return problems + [f"pipeline.json: stages must be {STAGES} in order, got {ids}"]
    if pipeline.get("current") not in STAGES:
        problems.append(f"pipeline.json: current must be one of {STAGES}")
    seen = set()
    for stage in stages:
        if not text_ok(stage.get("goal")):
            problems.append(f"{stage['id']}: needs a goal")
        for gate in stage.get("exit", []):
            gid, kind = gate.get("id"), gate.get("kind")
            where = f"{stage['id']} gate {gid}"
            if not isinstance(gid, str) or not gid.startswith(stage["id"] + ".") or gid in seen:
                problems.append(f"{where}: id must be unique and start with '{stage['id']}.'")
            seen.add(gid)
            if kind not in GATE_KINDS:
                problems.append(f"{where}: kind must be one of {sorted(GATE_KINDS)}")
            elif kind == "brief" and (not gate.get("fields") or (brief_keys and set(gate["fields"]) - set(brief_keys))):
                problems.append(f"{where}: fields must be brief keys")
            elif kind == "file" and not text_ok(gate.get("path")):
                problems.append(f"{where}: needs a path")
            elif kind == "gate" and gate.get("tier") not in CHECK_TIERS:
                problems.append(f"{where}: tier must be one of {sorted(CHECK_TIERS)}")
            elif kind == "release" and not (gate.get("items") and all(isinstance(i, str) and RELEASE_ID.match(i) for i in gate["items"])):
                problems.append(f"{where}: items must be release check ids (A01, S03, O07, ...)")
            if not text_ok(gate.get("text")):
                problems.append(f"{where}: needs a text saying what is done")
    return problems


def file_gate_done(root, gate):
    """A file gate passes when the file exists and its `Status:` line is no longer TBD."""
    path = Path(root) / gate["path"]
    if not path.is_file():
        return False, f"{gate['path']} missing"
    match = DESIGN_STATUS.search(path.read_text(encoding="utf-8"))
    if match and match.group(1).upper() == TBD:
        return False, f"{gate['path']}: Status is TBD"
    return True, gate["path"]


def gate_status(root, gate, brief, records, report):
    """(status, detail) for one exit gate. Owner and playtest gates are never passed by a tool."""
    kind = gate.get("kind")
    if kind == "brief":
        open_fields = [f for f in gate.get("fields", []) if is_tbd(brief.get(f, TBD))]
        return ("DONE", "fields decided") if not open_fields else ("OPEN", f"TBD: {', '.join(open_fields)}")
    if kind == "file":
        done, why = file_gate_done(root, gate)
        return ("DONE" if done else "OPEN"), why
    if kind == "gate":
        return "RUN", f"python3 tools/check.py --tier {gate['tier']}"
    if kind == "release":
        statuses = {i["id"]: i for i in (report or {}).get("items", [])}
        open_items = []
        for item in gate["items"]:
            if item.startswith("A"):
                if statuses.get(item, {}).get("status") not in ("PASS", "WAIVED_BY_OWNER"):
                    open_items.append(item)
            elif item not in records:
                open_items.append(item)
        if not report and any(i.startswith("A") for i in gate["items"]):
            return "RUN", "python3 tools/release_check.py (no release/report.json yet)"
        return ("DONE", "release items done") if not open_items else ("OPEN", f"open: {', '.join(open_items)}")
    record = records.get(gate.get("id"))
    if record:
        return "OWNER_RECORDED", f"{record['file']} {record['date']}"
    return "OWNER_REQUIRED", "only the owner records this (release/owner-*.json)"


def status(root=ROOT):
    brief, err1 = load_json(Path(root) / "production" / "brief.json")
    pipeline, err2 = load_json(Path(root) / "production" / "pipeline.json")
    if err1 or err2:
        print(f"refused: {err1 or err2}", file=sys.stderr)
        return 2
    problems = pipeline_problems(pipeline, BRIEF_FIELDS)
    if problems:
        print("pipeline.json problems:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1
    records, _ = owner_records(root)
    report, _ = load_json(Path(root) / "release" / "report.json")
    current = pipeline["current"]
    stage = pipeline["stages"][STAGES.index(current)]
    print(f"stage: {current} ({STAGES.index(current) + 1}/{len(STAGES)}): {stage['goal']}")
    for gate in stage.get("exit", []):
        state, detail = gate_status(root, gate, brief, records, report if isinstance(report, dict) else None)
        print(f"  [{state}] {gate['id']}: {gate['text']} ({detail})")
    print(f"brief: {len(undecided(brief))} required field(s) TBD: {', '.join(undecided(brief)) or 'none'}")
    print("skills for this stage: " + ", ".join(stage.get("skills", [])))
    print("next: python3 tools/plan_issues.py writes issue drafts for this stage; the owner moves `current` after recording the owner gates.")
    return 0


def main(argv):
    if argv[1:] == ["status"] or len(argv) == 1:
        return status()
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
