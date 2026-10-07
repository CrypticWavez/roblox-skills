"""Monetization planner: a full shop for the game's genre (monetization-plan/1).

  python3 tools/monetize.py plan [--genre G] [--subgenre S] [--currency LABEL] [--tier low|mid|high]
                                 [--add KEY ...] [--drop KEY ...] [--allow-power] [--allow-random]
                                 [--root DIR] [--force] [--dry-run]
  python3 tools/monetize.py check [--root DIR] [--json]
  python3 tools/monetize.py set-id KEY ID [--root DIR]     record a Creator Hub id (owner step)
  python3 tools/monetize.py list                           the product archetypes and genre sets

plan picks product archetypes (tools/storekit/archetypes.json) for the genre in production/brief.json
(or --genre/--subgenre; tools/storekit/genre_sets.json) and writes:
  src/shared/catalog.json          catalog/1 in setup mode: placeholder ids, every product disabled
  src/shared/offers.json           offers/1 (GameKit/Offers): starter pack, contextual offers
  src/shared/boosts.json           boosts/1 (GameKit/Boosts): timed boosts sold as developer products
  src/shared/perks.json            perks/1 (GameKit/Perks): what each pass or gifted entitlement does
  src/shared/shop.json             shop/1 (GameKit/ShopLayout): sections, featured product, ribbons
  src/localization/store.csv       names and descriptions of every product and shop section
  monetization/plan.json           the plan: suggested Robux prices, why each product, icon briefs
  docs/design/monetization.md      the owner's Creator Hub sheet (create each product, paste its id)
Suggested prices live only in the plan and the sheet: the catalog and UI read prices at runtime
(GetProductInfoAsync), as regional pricing and price optimization change them (release check A14).
PvP genres drop archetypes that sell power over other players unless --allow-power; paid random items
(lucky_crate) need --allow-random, odds disclosure and the PolicyService gate (release check A05).
check validates those files against each other and the minimums (at least 3 passes and 4 developer
products, a starter offer, a visible shop entry, every product shown). It never prompts, uploads or
spends: creating products in Creator Hub, setting their prices and enabling them stays with the owner.
"""
import argparse
import csv
import io
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STOREKIT = HERE / "storekit"
PLAN_SCHEMA = "monetization-plan/1"
LABEL = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
KEY = re.compile(r"^[\w.\-]{1,100}$")
TIERS = ("low", "mid", "high")
SECTION_ORDER = ["featured", "passes", "boosts", "currency", "bundles", "cosmetics", "gifts"]
RIBBONS = ("best_value", "most_popular", "limited", "new", "sale", "starter")
OUTPUTS = {
    "catalog": "src/shared/catalog.json",
    "offers": "src/shared/offers.json",
    "boosts": "src/shared/boosts.json",
    "perks": "src/shared/perks.json",
    "shop": "src/shared/shop.json",
    "strings": "src/localization/store.csv",
    "plan": "monetization/plan.json",
    "sheet": "docs/design/monetization.md",
}
PLACEHOLDER = {"gamepass": 0, "devproduct": 0, "subscription": "EXP-0"}
OFFER_RULES = {"maxPerSession": 3, "minSpacing": 180, "grace": 120, "quietAfterPurchase": 300}


class Refused(Exception):
    pass


def load(name):
    return json.loads((STOREKIT / name).read_text(encoding="utf-8"))


def archetypes():
    data = load("archetypes.json")
    return data, {a["key"]: a for a in data["archetypes"]}


def display_name(label):
    return " ".join(part.capitalize() for part in label.split("_"))


def fill(text, currency):
    return text.replace("{currency}", currency).replace("{Currency}", display_name(currency))


def read_brief(root):
    path = root / "production" / "brief.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def is_tbd(value):
    return value is None or value == "TBD"


def select(genre, subgenre, add=(), drop=(), allow_power=False, allow_random=False):
    """(archetype keys, pvp, default currency, notes) for a genre and subgenre."""
    sets = load("genre_sets.json")
    _, by_key = archetypes()
    if genre not in sets["genres"]:
        raise Refused(f"unknown genre {genre!r}: one of {', '.join(sorted(sets['genres']))}")
    base = sets["genres"][genre]
    sub = sets["subgenres"].get(subgenre) if subgenre else None
    pvp = (sub or {}).get("pvp", base["pvp"])
    currency = (sub or {}).get("currency", base["currency"])
    chosen = list(sets["base"]) + list((sub or base)["products"])
    chosen += [k for k in add if k not in chosen]
    notes = []
    keys = []
    for key in chosen:
        if key not in by_key:
            raise Refused(f"unknown archetype {key!r} (python3 tools/monetize.py list)")
        arch = by_key[key]
        if key in drop or key in keys:
            continue
        if pvp and arch["pvp"] == "avoid" and not allow_power:
            notes.append(f"dropped {key}: sells power over other players in a PvP game (--allow-power keeps it)")
            continue
        if arch.get("random") and not allow_random:
            notes.append(f"dropped {key}: a paid random item (--allow-random, then odds and the policy gate)")
            continue
        keys.append(key)
    return keys, pvp, currency, notes


def price(arch, tier):
    index = TIERS.index(tier)
    if arch["kind"] == "subscription":
        return {"usd": arch["usd"][index]}
    return {"robux": arch["robux"][index]}


def build(keys, currency, tier, genre, subgenre, pvp, notes):
    """Every output document for the chosen archetype keys."""
    _, by_key = archetypes()
    products, offers, boosts, perks, rows, plan_products = [], [], [], [], [], []
    tags_used = set()
    ribbons = {}
    featured_pass = None
    order = 0
    for key in keys:
        arch = by_key[key]
        order += 10
        kind = arch["kind"]
        tags = list(arch.get("tags", []))
        tags_used.update(t for t in tags if t != "paid_random_item")
        if kind in ("gamepass", "subscription"):
            grants = [{"type": "entitlement", "entitlement": key}]
        else:
            g = arch["grant"]
            if g["type"] == "currency":
                grants = [{"type": "currency", "currency": currency, "amount": g["amount_base"]}]
            else:
                grants = [{"type": g["type"], "handler": g["handler"], "data": dict(g.get("data", {}))}]
        products.append({
            "key": key,
            "kind": kind,
            "id": PLACEHOLDER[kind],
            "grants": grants,
            "display": {"nameKey": f"store.{key}.name", "descriptionKey": f"store.{key}.description", "iconKey": f"store.{key}.icon"},
            "enabled": False,
            "ownershipVerified": False,
            "tags": tags,
            "order": order,
        })
        name, description = fill(arch["name"], currency), fill(arch["description"], currency)
        rows.append((f"store.{key}.name", name, f"Shop: name of the {kind} {key} (Creator Hub name too)"))
        rows.append((f"store.{key}.description", description, f"Shop: description of {key}"))
        if arch.get("ribbon"):
            ribbons[key] = arch["ribbon"]
        if "featured" in tags and kind == "gamepass" and featured_pass is None:
            featured_pass = key
        if "offer" in arch:
            offer = {"key": f"{key}_offer", "productKey": key}
            offer.update(json.loads(json.dumps(arch["offer"])))
            if kind == "devproduct":
                # Developer products are bought again (revive, skip): the offer returns after its
                # cooldown unless the archetype marks it one-time (the starter pack).
                offer.setdefault("untilBought", False)
            if arch.get("ribbon"):
                offer["ribbon"] = arch["ribbon"]
            offers.append(offer)
        if "boost" in arch:
            b = dict(arch["boost"])
            b["stat"] = fill(b["stat"], currency)
            boosts.append({"key": key, **b})
        if "perk" in arch:
            effects = []
            for effect in arch["perk"]:
                e = dict(effect)
                if "stat" in e:
                    e["stat"] = fill(e["stat"], currency)
                effects.append(e)
            perks.append({"key": key, "source": {"productKey": key}, "effects": effects})
        plan_products.append({
            "key": key,
            "kind": kind,
            "name": name,
            "description": description,
            "suggested": price(arch, tier),
            "ladder": arch.get("usd") if kind == "subscription" else arch["robux"],
            "ribbon": arch.get("ribbon"),
            "tags": tags,
            "pvp": arch["pvp"],
            "random": bool(arch.get("random")),
            "icon_brief": arch["icon"],
            "why": arch["why"],
        })
    # Gifts grant an entitlement whose perks mirror the pass.
    for key in keys:
        arch = by_key[key]
        if arch["kind"] == "devproduct" and arch["grant"].get("handler") == "gift":
            target = arch["grant"]["data"]["entitlement"]
            source = next((p for p in perks if p["key"] == target), None)
            if source:
                perks.append({"key": f"{target}_gifted", "source": {"entitlement": target}, "effects": source["effects"]})
    # Contextual offers every shop has: the featured pass when the shop opens, a currency pack when short.
    if featured_pass:
        offers.append({"key": "featured_pass", "productKey": featured_pass, "trigger": "shop_open", "priority": 10})
    best_currency = next((k for k in ("currency_medium", "currency_small", "currency_large") if k in keys), None)
    if best_currency:
        offers.append({"key": "low_currency_pack", "productKey": best_currency, "trigger": "low_currency", "priority": 20, "cooldown": 600, "untilBought": False})
    sections = []
    for section in SECTION_ORDER:
        if section in tags_used:
            entry = {"id": section, "titleKey": f"store.section.{section}", "tag": section}
            if section == "featured" and featured_pass:
                entry["featured"] = featured_pass
            sections.append(entry)
            rows.append((f"store.section.{section}", display_name(section), "Shop: section tab title"))
    rows.append(("store.button", "Shop", "HUD: the shop button label"))
    stats = {}
    for b in boosts:
        stats.setdefault(b["stat"], {"combine": "multiply", "cap": 16})
    perk_stats = {}
    for p in perks:
        for e in p["effects"]:
            if "stat" in e:
                perk_stats.setdefault(e["stat"], {"combine": "add" if "add" in e else "multiply"})
    docs = {
        "catalog": {"schema": "catalog/1", "mode": "setup", "products": products},
        "offers": {"schema": "offers/1", "rules": dict(OFFER_RULES), "offers": offers},
        "boosts": {"schema": "boosts/1", "stats": stats, "boosts": boosts},
        "perks": {"schema": "perks/1", "stats": perk_stats, "perks": perks},
        "shop": {"schema": "shop/1", "entry": {"hud": "left", "label": True, "notify": True}, "sections": sections, "ribbons": ribbons},
    }
    plan = {
        "schema": PLAN_SCHEMA,
        "genre": {"primary": genre, "subgenre": subgenre},
        "pvp": pvp,
        "currency": currency,
        "tier": tier,
        "note": "Suggested prices are starting points for Creator Hub; Roblox reads prices at runtime, regional pricing and price optimization change them. Change products by editing this plan's inputs and re-running plan --force, or edit the generated files and re-run check.",
        "notes": notes,
        "products": plan_products,
        "outputs": OUTPUTS,
    }
    return docs, plan, rows


def csv_text(rows):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["Key", "Source", "Context", "Example"])
    for key, source, context in rows:
        writer.writerow([key, source, context, ""])
    return out.getvalue()


def sheet(plan):
    lines = [
        "# Monetization sheet",
        "",
        f"Generated by `python3 tools/monetize.py plan` for {plan['genre']['primary']}"
        + (f" / {plan['genre']['subgenre']}" if plan["genre"]["subgenre"] else "")
        + f" (tier {plan['tier']}, currency `{plan['currency']}`). Owner steps, never an agent's: create each product in",
        "Creator Hub (Monetization > Passes / Developer Products / Subscriptions, after the first publish), upload its icon",
        "(512x512, circle-safe: `python3 tools/store_art.py lint`), set the price, then record the id with",
        "`python3 tools/monetize.py set-id KEY ID`. Enabling products (catalog mode game, enabled, ownershipVerified) is the",
        "owner's check that the product really belongs to this game (release items O06 and O10).",
        "",
        "| Key | Kind | Name | Suggested price | Ladder | Ribbon | Why |",
        "|---|---|---|---|---|---|---|",
    ]
    for p in plan["products"]:
        suggested = f"${p['suggested']['usd']}/month" if "usd" in p["suggested"] else f"{p['suggested']['robux']} Robux"
        ladder = ", ".join(str(x) for x in p["ladder"])
        lines.append(f"| `{p['key']}` | {p['kind']} | {p['name']} | {suggested} | {ladder} | {p['ribbon'] or ''} | {p['why']} |")
    lines += ["", "## Icon briefs", ""]
    for p in plan["products"]:
        lines.append(f"- `{p['key']}`: {p['icon_brief']}.")
    if plan["notes"]:
        lines += ["", "## Notes", ""] + [f"- {n}" for n in plan["notes"]]
    lines += [
        "",
        "## Rules this shop keeps",
        "",
        "- The shop button sits on the HUD (left, labelled) from the first session; offers pop up at most 3 times a session, never in the first 2 minutes of a first session, never while a prompt is open (GameKit/Offers).",
        "- Contextual beats random: revives at the death screen, skips after repeated fails, currency when a purchase fails, the starter pack once per session for 24 h.",
        "- Prices are never hard-coded: cards show the runtime price (GameKit/Commerce priceProvider).",
        "- Developer products grant only from the one receipt handler; passes are checked with UserOwnsGamePassAsync (GameKit/Commerce).",
        "",
    ]
    return "\n".join(lines)


def write(root, rel, text, force, dry_run, written):
    path = root / rel
    if path.exists() and not force:
        raise Refused(f"{rel} exists; re-run with --force to replace it (your edits there are lost)")
    written.append(rel)
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def cmd_plan(args):
    root = Path(args.root).resolve()
    brief = read_brief(root)
    genre_info = brief.get("genre", {}) if isinstance(brief.get("genre"), dict) else {}
    genre = args.genre or (None if is_tbd(genre_info.get("primary")) else genre_info.get("primary"))
    subgenre = args.subgenre or (None if is_tbd(genre_info.get("subgenre")) else genre_info.get("subgenre"))
    if not genre:
        raise Refused("no genre: decide production/brief.json genre.primary or pass --genre")
    keys, pvp, currency, notes = select(genre, subgenre, args.add, args.drop, args.allow_power, args.allow_random)
    if args.currency:
        if not LABEL.match(args.currency):
            raise Refused("--currency must be a lower_snake label")
        currency = args.currency
    docs, plan, rows = build(keys, currency, args.tier, genre, subgenre, pvp, notes)
    problems = check_docs(docs, plan)
    if problems["errors"]:
        raise Refused("generated files fail check: " + "; ".join(problems["errors"]))
    written = []
    for name in ("catalog", "offers", "boosts", "perks", "shop"):
        write(root, OUTPUTS[name], json.dumps(docs[name], indent=2) + "\n", args.force, args.dry_run, written)
    write(root, OUTPUTS["strings"], csv_text(rows), args.force, args.dry_run, written)
    write(root, OUTPUTS["plan"], json.dumps(plan, indent=2) + "\n", args.force, args.dry_run, written)
    write(root, OUTPUTS["sheet"], sheet(plan), args.force, args.dry_run, written)
    counts = {}
    for p in plan["products"]:
        counts[p["kind"]] = counts.get(p["kind"], 0) + 1
    verb = "would write" if args.dry_run else "wrote"
    print(f"monetize: {verb} {len(written)} files for {genre}{' / ' + subgenre if subgenre else ''}: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    for note in notes:
        print("  note: " + note)
    for warning in problems["warnings"]:
        print("  warning: " + warning)
    return 0


def dicts(value):
    """The dict entries of a list (anything else gives none: malformed files fail their own checks)."""
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def doc(docs, name):
    value = docs.get(name)
    return value if isinstance(value, dict) else {}


SCHEMAS = {"catalog": "catalog/1", "offers": "offers/1", "boosts": "boosts/1", "perks": "perks/1", "shop": "shop/1"}
BOOST_STACKS, BOOST_CLOCKS = ("extend", "refresh", "stack"), ("realtime", "playtime")


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def text(value):
    return isinstance(value, str) and value != ""


def shape_errors(docs):
    """The fields the GameKit validators (Offers, Boosts, Perks, ShopLayout .define) require, so a
    hand-edited file that the game would refuse at load also fails here (release check A18)."""
    errors = []
    for name, schema in SCHEMAS.items():
        if doc(docs, name).get("schema") != schema:
            errors.append(f"{name}: schema must be {schema}")
    def entries(name, field):
        raw = doc(docs, name).get(field)
        if not isinstance(raw, list):
            errors.append(f"{name}.{field} must be a list")
            return []
        seen = set()
        for i, entry in enumerate(raw):
            if not isinstance(entry, dict):
                errors.append(f"{name}.{field}[{i + 1}] must be an object")
                continue
            key = entry.get("key", entry.get("id"))
            if key in seen:
                errors.append(f"{name}.{field}: {key} repeated")
            seen.add(key)
        return [e for e in raw if isinstance(e, dict)]
    for o in entries("offers", "offers"):
        for field in ("key", "productKey", "trigger"):
            if not text(o.get(field)):
                errors.append(f"offers {o.get('key')}: {field} is required")
        for field in ("priority", "cooldown", "maxShows", "maxShowsPerSession", "duration"):
            if field in o and not (number(o[field]) and o[field] >= 0):
                errors.append(f"offers {o.get('key')}: {field} must be a number >= 0")
        if "untilBought" in o and not isinstance(o["untilBought"], bool):
            errors.append(f"offers {o.get('key')}: untilBought must be true or false")
    for b in entries("boosts", "boosts"):
        if not (text(b.get("key")) and text(b.get("stat"))):
            errors.append(f"boosts {b.get('key')}: key and stat are required")
        if not (number(b.get("duration")) and b["duration"] > 0):
            errors.append(f"boosts {b.get('key')}: duration must be a number > 0")
        if ("multiplier" in b) == ("add" in b):
            errors.append(f"boosts {b.get('key')}: exactly one of multiplier or add")
        if b.get("stack", "extend") not in BOOST_STACKS or b.get("clock", "realtime") not in BOOST_CLOCKS:
            errors.append(f"boosts {b.get('key')}: stack is one of {', '.join(BOOST_STACKS)}; clock one of {', '.join(BOOST_CLOCKS)}")
    for perk in entries("perks", "perks"):
        source = perk.get("source")
        if not text(perk.get("key")) or not isinstance(source, dict) or not (text(source.get("productKey")) or text(source.get("entitlement"))):
            errors.append(f"perks {perk.get('key')}: key and a source with productKey or entitlement are required")
        effects = perk.get("effects")
        if not isinstance(effects, list) or not effects:
            errors.append(f"perks {perk.get('key')}: effects must be a non-empty list")
            continue
        for e in effects:
            ok = isinstance(e, dict) and (text(e.get("flag")) or (text(e.get("stat")) and (number(e.get("multiplier")) != number(e.get("add")))))
            if not ok:
                errors.append(f"perks {perk.get('key')}: each effect is {{stat, multiplier | add}} or {{flag}}")
    for section in entries("shop", "sections"):
        if not (text(section.get("id")) and text(section.get("titleKey"))):
            errors.append(f"shop section {section.get('id')}: id and titleKey are required")
    return errors


def check_docs(docs, plan=None):
    """{errors, warnings} for a set of generated or edited documents."""
    errors, warnings = shape_errors(docs), []
    catalog = doc(docs, "catalog")
    products = dicts(catalog.get("products"))  # malformed entries are release check A03's
    by_key = {p.get("key"): p for p in products if isinstance(p, dict)}
    kinds = {}
    for p in products:
        kinds[p.get("kind")] = kinds.get(p.get("kind"), 0) + 1
        for field in p:
            low = str(field).lower()
            if "price" in low or "robux" in low or "cost" in low:
                errors.append(f"catalog {p.get('key')}.{field}: prices are runtime reads, never catalog data")
        if catalog.get("mode") == "setup" and p.get("enabled"):
            errors.append(f"catalog {p.get('key')}: setup mode keeps every product disabled")
        if "paid_random_item" in (p.get("tags") or []):
            warnings.append(f"{p.get('key')} sells a random item: show odds before purchase and gate it with PolicyGate paidRandomItems (release check A05)")
    minimums = load("genre_sets.json")["minimums"]
    for kind, minimum in minimums.items():
        if kinds.get(kind, 0) < minimum:
            errors.append(f"catalog has {kinds.get(kind, 0)} {kind} products; every game ships at least {minimum}")
    offers = dicts(doc(docs, "offers").get("offers"))
    for o in offers:
        if o.get("productKey") not in by_key:
            errors.append(f"offers {o.get('key')}: productKey {o.get('productKey')} is not in the catalog")
        if o.get("ribbon") is not None and o["ribbon"] not in RIBBONS:
            errors.append(f"offers {o.get('key')}: unknown ribbon {o['ribbon']}")
    if not any(o.get("trigger") == "join" and (o.get("audience") or {}).get("payer") == "non_payer" for o in offers):
        warnings.append("no first-purchase offer (a join offer for non_payer players): a starter pack converts best")
    boosts = dicts(doc(docs, "boosts").get("boosts"))
    boost_keys = {b.get("key") for b in boosts}
    for p in products:
        for g in dicts(p.get("grants")):
            if g.get("type") == "custom" and g.get("handler") in ("boost", "server_boost"):
                if (g.get("data") or {}).get("boost") not in boost_keys:
                    errors.append(f"{p.get('key')}: grants boost {(g.get('data') or {}).get('boost')} that boosts.json does not define")
    for perk in dicts(doc(docs, "perks").get("perks")):
        source = perk.get("source") if isinstance(perk.get("source"), dict) else {}
        if "productKey" in source:
            target = by_key.get(source["productKey"])
            if target is None:
                errors.append(f"perks {perk.get('key')}: productKey {source['productKey']} is not in the catalog")
            elif target.get("kind") == "devproduct":
                errors.append(f"perks {perk.get('key')}: a developer product is consumed, not owned; use an entitlement")
    shop = doc(docs, "shop")
    if (shop.get("entry") if isinstance(shop.get("entry"), dict) else {}).get("hud") not in ("left", "right", "top"):
        errors.append("shop.entry.hud must put the shop button on the HUD (left, right or top)")
    shown = set()
    for section in dicts(shop.get("sections")):
        for p in products:
            if section.get("tag") in (p.get("tags") or []):
                shown.add(p.get("key"))
        shown.update(k for k in section.get("products") or [] if isinstance(k, str))
        if section.get("featured") and section["featured"] not in shown:
            errors.append(f"shop {section.get('id')}: featured {section['featured']} is not in the section")
    for key in by_key:
        if key not in shown:
            errors.append(f"shop: no section shows {key}")
    if len(shop.get("sections") or []) > 8:
        errors.append("shop: at most 8 sections (UIKit Tabs)")
    for key, ribbon in (shop.get("ribbons") if isinstance(shop.get("ribbons"), dict) else {}).items():
        if ribbon not in RIBBONS:
            errors.append(f"shop.ribbons.{key}: unknown ribbon {ribbon}")
        if key not in by_key:
            errors.append(f"shop.ribbons.{key}: not in the catalog")
    if isinstance(plan, dict):
        for p in dicts(plan.get("products")):
            if p.get("key") not in by_key:
                warnings.append(f"plan lists {p.get('key')}, the catalog does not")
            robux = (p.get("suggested") if isinstance(p.get("suggested"), dict) else {}).get("robux")
            if robux is not None and robux not in load("archetypes.json")["price_points"]:
                warnings.append(f"{p['key']}: suggested {robux} Robux is off the usual price points")
    return {"errors": errors, "warnings": warnings}


def read_docs(root):
    docs = {}
    for name in ("catalog", "offers", "boosts", "perks", "shop"):
        path = root / OUTPUTS[name]
        if path.exists():
            docs[name] = json.loads(path.read_text(encoding="utf-8"))
    plan_path = root / OUTPUTS["plan"]
    plan = json.loads(plan_path.read_text(encoding="utf-8")) if plan_path.exists() else None
    return docs, plan


def cmd_check(args):
    root = Path(args.root).resolve()
    docs, plan = read_docs(root)
    missing = [OUTPUTS[n] for n in ("catalog", "offers", "boosts", "perks", "shop") if n not in docs]
    result = check_docs(docs, plan)
    if missing:
        result["errors"].insert(0, "missing " + ", ".join(missing) + " (run python3 tools/monetize.py plan)")
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for e in result["errors"]:
            print("ERROR " + e)
        for w in result["warnings"]:
            print("warn  " + w)
        print(f"monetize check: {len(result['errors'])} errors, {len(result['warnings'])} warnings")
    return 1 if result["errors"] else 0


def cmd_set_id(args):
    root = Path(args.root).resolve()
    path = root / OUTPUTS["catalog"]
    catalog = json.loads(path.read_text(encoding="utf-8"))
    product = next((p for p in catalog["products"] if p["key"] == args.key), None)
    if product is None:
        raise Refused(f"{args.key} is not in {OUTPUTS['catalog']}")
    if product["kind"] == "subscription":
        if not re.match(r"^EXP-\w+$", args.id) or args.id == "EXP-0":
            raise Refused("a subscription id looks like EXP-1234567890")
        product["id"] = args.id
    else:
        if not args.id.isdigit() or int(args.id) <= 0:
            raise Refused("a pass or developer product id is a positive integer from Creator Hub")
        if any(p["id"] == int(args.id) for p in catalog["products"] if p is not product):
            raise Refused(f"id {args.id} is already used by another product")
        product["id"] = int(args.id)
    path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"monetize: {args.key} id = {product['id']} (still disabled: the owner enables it and sets ownershipVerified)")
    return 0


def cmd_list(_args):
    data, _ = archetypes()
    sets = load("genre_sets.json")
    for a in data["archetypes"]:
        ladder = a.get("robux") or [f"${x}" for x in a.get("usd", [])]
        print(f"{a['key']:<18} {a['kind']:<12} pvp={a['pvp']:<8} {ladder}  {a['name']}")
    print()
    for genre, entry in sets["genres"].items():
        print(f"{genre}: {', '.join(sets['base'] + entry['products'])}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--genre")
    plan.add_argument("--subgenre")
    plan.add_argument("--currency")
    plan.add_argument("--tier", choices=TIERS, default="mid")
    plan.add_argument("--add", nargs="*", default=[])
    plan.add_argument("--drop", nargs="*", default=[])
    plan.add_argument("--allow-power", action="store_true")
    plan.add_argument("--allow-random", action="store_true")
    plan.add_argument("--root", default=".")
    plan.add_argument("--force", action="store_true")
    plan.add_argument("--dry-run", action="store_true")
    check = sub.add_parser("check")
    check.add_argument("--root", default=".")
    check.add_argument("--json", action="store_true")
    setid = sub.add_parser("set-id")
    setid.add_argument("key")
    setid.add_argument("id")
    setid.add_argument("--root", default=".")
    sub.add_parser("list")
    args = parser.parse_args(argv)
    try:
        return {"plan": cmd_plan, "check": cmd_check, "set-id": cmd_set_id, "list": cmd_list}[args.cmd](args)
    except Refused as err:
        print(f"monetize: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
