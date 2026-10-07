"""Ad campaign plans for Roblox Ads Manager (ad-campaign/1). Plans only: this tool never buys ads.

  python3 tools/ad_kit.py plan [--root DIR] [--goal plays|earnings|engagement] [--force]
  python3 tools/ad_kit.py lint [--root DIR] [--json]
  python3 tools/ad_kit.py sheet [--root DIR]          the Ads Manager entry sheet (Markdown) for the owner
  python3 tools/ad_kit.py estimate --credits N [--goal plays]

plan writes store/ads/campaign.json from production/brief.json, store/art/briefs.json and
store/page.json: the goal, the audience and filters (devices from the brief, a country tier, the genre),
three to five creatives that are clearly different concepts (the personalization thumbnails), a test
plan (pause losers after enough impressions, no restart within 7 days, refresh with each update), the
launch timing (with an update, before the Saturday peak) and budget scenarios as estimates from Roblox's
published cost per play. `purchase` is always false and the tool refuses a file that says otherwise:
buying ad credits converts Robux irreversibly and is the owner's decision in Ads Manager, never an
agent's. lint checks the creatives against the 16:9 creative spec and the copy rules (no Robux bait, no
prices, no URLs, English). sheet prints what to enter in Ads Manager, field by field. Reference data:
tools/storekit/ads.json (with sources; unverified community figures are marked).
"""
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import store_art  # noqa: E402
import store_page  # noqa: E402

ADS = json.loads((HERE / "storekit" / "ads.json").read_text(encoding="utf-8"))
SCHEMA = "ad-campaign/1"
CAMPAIGN = "store/ads/campaign.json"
GOALS = [g["id"] for g in ADS["goals"]]
DEVICE_MAP = {"computer": "desktop", "phone": "mobile", "tablet": "mobile", "console": "console"}


class Refused(Exception):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def estimate(credits, goal="plays"):
    b = ADS["benchmarks"]
    cpp = b["cost_per_play_usd"]["plays" if goal != "engagement" else "retention"]
    usd = credits * b["credit_usd"]["value"]
    mid = usd / cpp
    return {"credits": credits, "robux": credits * b["credit_robux"]["value"], "plays_low": int(mid * 0.5), "plays_mid": int(mid), "plays_high": int(mid * 1.5), "basis": f"Roblox average cost per play ${cpp} ({b['cost_per_play_usd']['as_of']}); 1 credit about ${b['credit_usd']['value']} (community estimate); real costs vary 2-3x"}


def plan(root, goal):
    brief = read_json(root / "production" / "brief.json") or {}
    art = read_json(root / "store" / "art" / "briefs.json") or {"tasks": []}
    page = read_json(root / store_page.PAGE)
    devices = brief.get("devices") if isinstance(brief.get("devices"), list) else ["computer", "phone", "tablet", "console"]
    genre = (brief.get("genre") or {}).get("primary") if isinstance(brief.get("genre"), dict) else None
    thumbs = [t for t in art["tasks"] if t["kind"] == "thumbnail"]
    creatives = [{"id": t["id"].replace("thumbnail_", "ad_"), "file": t["out"], "concept": t["concept"], "alt": t["concept"][:120]} for t in thumbs[:5]]
    if not creatives:
        creatives = [{"id": f"ad_{n}", "file": f"store/art/out/thumbnail_{n}.jpg", "concept": "TBD", "alt": "TBD"} for n in ("hero", "core_action", "reward")]
    return {
        "schema": SCHEMA,
        "purchase": False,
        "note": "A plan for the owner. Nothing here buys credits or starts a campaign: the owner decides and enters it in Ads Manager (python3 tools/ad_kit.py sheet).",
        "game": page["name"] if page else brief.get("name", "TBD"),
        "goal": goal,
        "audience": "new",
        "filters": {"countries": ADS["country_tiers"]["tier1"]["countries"], "country_tier": "tier1", "devices": sorted({DEVICE_MAP[d] for d in devices if d in DEVICE_MAP}), "genre": genre or "TBD", "age": "all", "gender": "all"},
        "creatives": creatives,
        "test": {"min_concepts": 3, "pause_after_impressions": 20000, "pause_if_ctr_below": ADS["benchmarks"]["ctr_target"]["value"], "no_restart_days": 7, "refresh": "with every update; keep the winner as the first personalization thumbnail"},
        "schedule": {"launch": "with an update, starting Thursday or Friday so the Saturday peak (~19:00 UTC) is covered", "mode": "continuous with a daily budget", "landing": "start place; optional launch data for an ad-specific welcome (no paid advantage)"},
        "budget_scenarios": [estimate(c, goal) for c in (10, 50, 200)],
        "kpis": ["CTR (impressions to clicks)", "cost per play", "D1 retention of ad players (Creator Analytics by acquisition source)", "first-play bounce", "earnings per ad player"],
        "rules": ADS["rules"],
    }


def lint_campaign(root, campaign):
    errors, warnings = [], []
    if campaign.get("schema") != SCHEMA:
        errors.append(f"schema must be {SCHEMA}")
    if campaign.get("purchase") is not False:
        errors.append("purchase must be false: buying ad credits is the owner's decision in Ads Manager, never a file or an agent's")
    for key in campaign:
        if any(word in key.lower() for word in ("token", "password", "card", "payment", "cookie")):
            errors.append(f"{key}: campaign files hold no credentials or payment data")
    if campaign.get("goal") not in GOALS:
        errors.append(f"goal must be one of {', '.join(GOALS)}")
    creatives = campaign.get("creatives") or []
    if len(creatives) < campaign.get("test", {}).get("min_concepts", 3):
        warnings.append(f"{len(creatives)} creatives: test at least 3 clearly different concepts")
    ids = set()
    for c in creatives:
        if c["id"] in ids:
            errors.append(f"creative {c['id']} repeated")
        ids.add(c["id"])
        path = root / c["file"]
        if not path.exists():
            warnings.append(f"{c['id']}: {c['file']} not made yet (python3 tools/store_art.py compose)")
        else:
            hard, *_ = store_art.hard_checks(path, "ad")
            errors += [f"{c['id']}: {e}" for e in hard]
        for text_key in ("concept", "alt"):
            problems = []
            store_page.scan(c.get(text_key, ""), f"{c['id']}.{text_key}", problems)
            errors += problems
        if any(ord(ch) > 0x2FF and not store_page.is_emoji(ch) for ch in c.get("alt", "")):
            warnings.append(f"{c['id']}: self-serve ad text must be English")
    return errors, warnings


def cmd_plan(args):
    root = Path(args.root)
    path = root / CAMPAIGN
    if path.exists() and not args.force:
        raise Refused(f"{CAMPAIGN} exists; --force replaces it")
    data = plan(root, args.goal)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"ad_kit: wrote {CAMPAIGN} ({len(data['creatives'])} creatives; purchase false: the owner decides in Ads Manager)")
    return 0


def load(root):
    data = read_json(Path(root) / CAMPAIGN)
    if data is None:
        raise Refused(f"{CAMPAIGN} missing (python3 tools/ad_kit.py plan)")
    return data


def cmd_lint(args):
    errors, warnings = lint_campaign(Path(args.root), load(args.root))
    if args.json:
        print(json.dumps({"errors": errors, "warnings": warnings}, indent=2))
    else:
        for e in errors:
            print("ERROR " + e)
        for w in warnings:
            print("warn  " + w)
        print(f"ad_kit lint: {len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


def cmd_sheet(args):
    c = load(args.root)
    errors, _ = lint_campaign(Path(args.root), c)
    if errors:
        raise Refused("fix lint errors first: " + "; ".join(errors))
    goal = next(g for g in ADS["goals"] if g["id"] == c["goal"])
    audience = next(a for a in ADS["audiences"] if a["id"] == c["audience"])
    lines = [
        f"# Ads Manager sheet: {c['game']}",
        "",
        "For the owner. Ads Manager (create.roblox.com > Ads) > Create campaign. Buying credits converts Robux",
        "irreversibly; decide the budget yourself. This sheet only lists what to enter.",
        "",
        f"1. Goal: **{goal['label']}** ({goal['use']}).",
        f"2. Audience: **{audience['label']}**. Advanced filters: countries {', '.join(c['filters']['countries'])}; devices {', '.join(c['filters']['devices'])}; genre {c['filters']['genre']}; age and gender: all.",
        f"3. Creatives (16:9, 1920x1080, under 3 MB, English): " + ", ".join(f"`{x['file']}`" for x in c["creatives"]) + ".",
        f"4. Schedule: {c['schedule']['launch']}; {c['schedule']['mode']}.",
        f"5. Test: pause a creative after {c['test']['pause_after_impressions']} impressions below {c['test']['pause_if_ctr_below']:.0%} CTR; no restart within {c['test']['no_restart_days']} days.",
        "",
        "| Credits | Robux | Plays (estimate) |",
        "|---|---|---|",
    ] + [f"| {b['credits']} | {b['robux']} | {b['plays_low']}-{b['plays_high']} |" for b in c["budget_scenarios"]] + [
        "",
        c["budget_scenarios"][0]["basis"] + ".",
        "",
        "Rules: " + " ".join(c["rules"]),
    ]
    print("\n".join(lines))
    return 0


def cmd_estimate(args):
    print(json.dumps(estimate(args.credits, args.goal), indent=2))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--root", default=".")
    p.add_argument("--goal", choices=GOALS, default="plays")
    p.add_argument("--force", action="store_true")
    li = sub.add_parser("lint")
    li.add_argument("--root", default=".")
    li.add_argument("--json", action="store_true")
    sh = sub.add_parser("sheet")
    sh.add_argument("--root", default=".")
    es = sub.add_parser("estimate")
    es.add_argument("--credits", type=int, required=True)
    es.add_argument("--goal", choices=GOALS, default="plays")
    args = parser.parse_args(argv)
    try:
        return {"plan": cmd_plan, "lint": cmd_lint, "sheet": cmd_sheet, "estimate": cmd_estimate}[args.cmd](args)
    except Refused as err:
        print(f"ad_kit: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
