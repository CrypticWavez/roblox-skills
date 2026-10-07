"""Store page text: title, description, update log and product names (store-page/1).

  python3 tools/store_page.py draft [--root DIR] [--force]     store/page.json from the brief and the plan
  python3 tools/store_page.py render [--root DIR]               print the title and description to paste
  python3 tools/store_page.py lint [--root DIR] [--json]        check every text against the copy rules
  python3 tools/store_page.py update --tag TAG --notes TEXT [--version V] [--root DIR]

The page follows what top-chart games do (factory docs/research/monetization-ads-store-2026-10.md):
a stable name with at most one bracketed update tag and one or two emoji ("[HATCH WARS] Name"), a hook
sentence that names the genre in the first 160 characters (search snippets), a short feature list, the
latest update and a line about optional purchases. Text rules (tools/storekit/copy_rules.json): no free
Robux, giveaway, discount or pressure wording, no hashtags, no off-platform links, length limits.
render prints the text for the owner to paste into Creator Hub (Configure > Basic Info); nothing here
calls Roblox. update records an update: the title tag, the update log and a 60-character Events &
Updates line.
"""
import argparse
import datetime
import json
import re
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULES = json.loads((HERE / "storekit" / "copy_rules.json").read_text(encoding="utf-8"))
SCHEMA = "store-page/1"
PAGE = "store/page.json"
LIMIT = {k: v["value"] for k, v in RULES["limits"].items()}


class Refused(Exception):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def tbd(value):
    return value in (None, "", "TBD") or (isinstance(value, list) and not value)


def is_emoji(ch):
    return unicodedata.category(ch) == "So" or 0x1F000 <= ord(ch) <= 0x1FAFF


def draft(root):
    brief = read_json(root / "production" / "brief.json") or {}
    plan = read_json(root / "monetization" / "plan.json") or {"products": []}
    name = brief.get("name") if not tbd(brief.get("name")) else "TBD"
    genre = brief.get("genre") if isinstance(brief.get("genre"), dict) else {}
    kind = genre.get("subgenre") if not tbd(genre.get("subgenre")) else genre.get("primary")
    kind = kind if not tbd(kind) else "TBD"
    pitch = brief.get("pitch") if not tbd(brief.get("pitch")) else "TBD: one sentence that says what the player does and why it is fun"
    loop = brief.get("core_loop") if not tbd(brief.get("core_loop")) else None
    features = [
        "TBD: the core loop in one line" if not loop else str(loop).split(".")[0],
        "TBD: the thing players collect or unlock",
        "TBD: what friends do together",
        "TBD: the newest world, boss or event",
    ]
    passes = [p["name"] for p in plan.get("products", []) if p["kind"] == "gamepass"][:3]
    return {
        "schema": SCHEMA,
        "name": name,
        "emoji": "",
        "update_tag": None,
        "description": {
            "hook": f"{pitch} A {kind} game on Roblox." if not pitch.startswith("TBD") else pitch,
            "features": features,
            "update": None,
            "purchases": "Optional passes and items" + (f" ({', '.join(passes)})" if passes else "") + " support the game; everything else is free to earn.",
            "footer": "Like and favourite to follow updates. Join our community for events.",
        },
        "update_log": [],
        "events_update": None,
        "alt_text": {},
    }


def title(page):
    parts = []
    if page.get("update_tag"):
        parts.append(f"[{page['update_tag']}]")
    parts.append(page["name"])
    if page.get("emoji"):
        parts.append(page["emoji"])
    return " ".join(parts)


def description(page):
    d = page["description"]
    lines = [d["hook"], ""]
    lines += [f"- {f}" for f in d.get("features", [])]
    if d.get("update"):
        lines += ["", f"UPDATE: {d['update']}"]
    if d.get("purchases"):
        lines += ["", d["purchases"]]
    if d.get("footer"):
        lines += ["", d["footer"]]
    return "\n".join(lines).strip()


def scan(text, where, problems):
    low = text.lower()
    for rule in RULES["banned"]:
        if re.search(rule["pattern"], low):
            problems.append(f"{where}: matches /{rule['pattern']}/: {rule['why']}")
    for url in re.findall(RULES["url"]["pattern"], text):
        if not re.match(RULES["url"]["allowed"], url):
            problems.append(f"{where}: link {url}: only roblox.com community, group or game links")


def lint_page(page):
    errors, warnings = [], []
    if page.get("schema") != SCHEMA:
        errors.append(f"schema must be {SCHEMA}")
        return errors, warnings
    t = title(page)
    if "TBD" in t:
        warnings.append("title still has TBD")
    if len(t) > LIMIT["title_max"]:
        errors.append(f"title is {len(t)} characters (max {LIMIT['title_max']})")
    elif len(t) > LIMIT["title_warn"]:
        warnings.append(f"title is {len(t)} characters; under {LIMIT['title_warn']} stays readable on tiles")
    emoji = sum(1 for ch in t if is_emoji(ch))
    if emoji > LIMIT["title_emoji_max"]:
        errors.append(f"title has {emoji} emoji (max {LIMIT['title_emoji_max']}): Roblox can demote over-decorated titles")
    if t.count("[") > LIMIT["title_tags_max"]:
        errors.append("title has more than one bracketed tag")
    words = re.findall(r"[a-z0-9']+", re.sub(r"\[.*?\]", "", t).lower())
    if len(words) != len(set(words)):
        errors.append("title repeats a word (keyword stuffing)")
    bare = re.sub(r"\[.*?\]", "", t)
    letters = [c for c in bare if c.isalpha()]
    if letters and sum(c.isupper() for c in letters) / len(letters) > RULES["caps_ratio_max"] and len(letters) > 6:
        warnings.append("title is mostly capitals outside the update tag")
    scan(t, "title", errors)
    text = description(page)
    if len(text) > LIMIT["description_max"]:
        errors.append(f"description is {len(text)} characters (max {LIMIT['description_max']})")
    hook = page["description"]["hook"]
    if len(hook) > LIMIT["hook_max"]:
        warnings.append(f"hook is {len(hook)} characters; the first {LIMIT['hook_max']} show in search")
    if "TBD" in text:
        warnings.append("description still has TBD lines")
    scan(text, "description", errors)
    update = page.get("events_update")
    if update:
        if len(update) > LIMIT["update_text_max"]:
            errors.append(f"events_update is {len(update)} characters (max {LIMIT['update_text_max']})")
        scan(update, "events_update", errors)
    for key, alt in (page.get("alt_text") or {}).items():
        scan(alt, f"alt_text.{key}", errors)
    return errors, warnings


def load_page(root):
    page = read_json(root / PAGE)
    if page is None:
        raise Refused(f"{PAGE} is missing or not JSON (python3 tools/store_page.py draft)")
    return page


def save(root, page):
    path = root / PAGE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(page, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")


def cmd_draft(args):
    root = Path(args.root)
    if (root / PAGE).exists() and not args.force:
        raise Refused(f"{PAGE} exists; --force replaces it")
    page = draft(root)
    save(root, page)
    print(f"store_page: wrote {PAGE}; fill the TBD lines, then: python3 tools/store_page.py lint")
    return 0


def cmd_render(args):
    page = load_page(Path(args.root))
    print("TITLE\n" + title(page) + "\n\nDESCRIPTION\n" + description(page))
    if page.get("events_update"):
        print("\nEVENTS & UPDATES\n" + page["events_update"])
    return 0


def cmd_lint(args):
    errors, warnings = lint_page(load_page(Path(args.root)))
    if args.json:
        print(json.dumps({"errors": errors, "warnings": warnings}, indent=2))
    else:
        for e in errors:
            print("ERROR " + e)
        for w in warnings:
            print("warn  " + w)
        print(f"store_page lint: {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


def cmd_update(args):
    root = Path(args.root)
    page = load_page(root)
    tag = args.tag.strip().upper()
    if len(tag.split()) > 3:
        raise Refused("keep the update tag to three words or fewer")
    page["update_tag"] = tag
    page["description"]["update"] = args.notes
    page["update_log"].insert(0, {"version": args.version, "date": datetime.date.today().isoformat(), "tag": tag, "notes": args.notes})
    page["events_update"] = (f"{tag.title()} is live! " + args.notes)[: LIMIT["update_text_max"]].rstrip()
    errors, _ = lint_page(page)
    if errors:
        raise Refused("the update breaks the copy rules: " + "; ".join(errors))
    save(root, page)
    print(f"store_page: title is now {title(page)!r}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("draft", "render", "lint", "update"):
        p = sub.add_parser(name)
        p.add_argument("--root", default=".")
        if name == "draft":
            p.add_argument("--force", action="store_true")
        if name == "lint":
            p.add_argument("--json", action="store_true")
        if name == "update":
            p.add_argument("--tag", required=True)
            p.add_argument("--notes", required=True)
            p.add_argument("--version")
    args = parser.parse_args(argv)
    try:
        return {"draft": cmd_draft, "render": cmd_render, "lint": cmd_lint, "update": cmd_update}[args.cmd](args)
    except Refused as err:
        print(f"store_page: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
