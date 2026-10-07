"""Store setup through Open Cloud: create passes and developer products, set prices, upload store art.

  python3 tools/store_publish.py target --universe ID --place ID [--root DIR]   record the experience
  python3 tools/store_publish.py approve --by NAME --quote TEXT [--root DIR]    record the owner's go-ahead
  python3 tools/store_publish.py plan [--root DIR] [--only STEP ...] [--update]  dry run: print every request
  python3 tools/store_publish.py run --yes [--root DIR] [--only STEP ...] [--update]
  python3 tools/store_publish.py scopes                                         API key permissions to grant

Steps (store-publish/1, state in store/publish.json):
  products   create each catalog/1 game pass and developer product that still has a placeholder id, with
             the name and description from monetization/plan.json, the suggested price, regional pricing
             on and the composed icon (store/art/out/pass_<key>.png, product_<key>.png); record the id in
             the catalog (enabled, ownershipVerified: the API created it in this universe). --update also
             patches products that already have an id. Subscriptions have no Open Cloud API: listed for
             Creator Hub.
  page       set the place name and description from store/page.json (store_page.py lint must be clean).
  icon       upload store/art/out/icon.png as the experience icon.
  thumbnails upload store/art/out/thumbnail_*.jpg and order them (hero first).
Money: nothing here spends. Requests go only to the path templates in ALLOWED (no badge creation, which
can charge Robux, no ads, no purchases, no place publishing), and a request body may not carry a
payment or cost field. Prices are what players pay; setting them costs nothing.
Safety: run refuses in the factory repository, without a recorded owner approval, without --yes and
without the key in the ROBLOX_OPEN_CLOUD_KEY environment variable (never an argument, never printed,
never written). Each step is recorded in store/publish.json so a rerun continues where it stopped. The icon and
thumbnail endpoints take a language code (default en; set languageCode in store/publish.json).
Rate limits from the API reference: game passes 5/s, developer products 3/s; the tool waits between calls.
"""
import argparse
import datetime
import json
import mimetypes
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import store_page  # noqa: E402

SCHEMA = "store-publish/1"
STATE = "store/publish.json"
CATALOG = "src/shared/catalog.json"
PLAN = "monetization/plan.json"
ART = "store/art/out"
BASE = "https://apis.roblox.com"
KEY_ENV = "ROBLOX_OPEN_CLOUD_KEY"
STEPS = ["products", "page", "icon", "thumbnails"]
THUMB_ORDER = ["hero", "core_action", "reward", "social", "update"]
# Every request this tool may send. Anything else is refused before it leaves the machine.
ALLOWED = [
    ("POST", r"/game-passes/v1/universes/\d+/game-passes"),
    ("PATCH", r"/game-passes/v1/universes/\d+/game-passes/\d+"),
    ("POST", r"/developer-products/v2/universes/\d+/developer-products"),
    ("PATCH", r"/developer-products/v2/universes/\d+/developer-products/\d+"),
    ("PATCH", r"/cloud/v2/universes/\d+/places/\d+"),
    ("POST", r"/legacy-game-internationalization/v1/game-icon/games/\d+/language-codes/[a-z_]+"),
    ("POST", r"/legacy-game-internationalization/v1/game-thumbnails/games/\d+/language-codes/[a-z_]+/image"),
    ("POST", r"/legacy-game-internationalization/v1/game-thumbnails/games/\d+/language-codes/[a-z_]+/images/order"),
]
MONEY_FIELDS = re.compile(r"payment|cost|credit|budget|purchase|funds", re.IGNORECASE)
SCOPES = [
    ("game-pass:write", "create and update game passes"),
    ("developer-product:write", "create and update developer products"),
    ("universe.place:write", "set the place name and description"),
    ("legacy-universe:manage", "upload the experience icon and thumbnails"),
]


class Refused(Exception):
    pass


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(root):
    state = read_json(root / STATE) or {}
    state.setdefault("schema", SCHEMA)
    state.setdefault("universeId", 0)
    state.setdefault("placeId", 0)
    state.setdefault("languageCode", "en")
    state.setdefault("approval", None)
    state.setdefault("done", {})
    return state


def is_factory(root):
    return (root / "tools" / "new_project.py").exists() and (root / "templates" / "starter").is_dir()


def check_request(method, path, fields):
    if not any(m == method and re.fullmatch(p, path) for m, p in ALLOWED):
        raise Refused(f"{method} {path} is not a store-setup request this tool may send")
    for name in fields:
        if MONEY_FIELDS.search(name):
            raise Refused(f"{method} {path}: field {name} could spend money; refused")


def multipart(fields, files):
    boundary = "----store" + uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        if isinstance(value, bool):
            value = "true" if value else "false"
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
    for name, path in files.items():
        mime = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{Path(path).name}\"\r\nContent-Type: {mime}\r\n\r\n".encode()
        out += Path(path).read_bytes() + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


class Client:
    """Sends allowed requests. dry=True only prints them. base is overridable for tests (loopback only)."""

    def __init__(self, dry, key=None, base=BASE, wait=0.4, out=print):
        self.dry, self.key, self.base, self.wait, self.out = dry, key, base, wait, out
        self.sent = 0

    def call(self, method, path, fields=None, files=None, query=None, body=None):
        fields, files = fields or {}, {k: v for k, v in (files or {}).items() if v}
        check_request(method, path, list(fields) + list((body or {}).keys()))
        shown = {k: v for k, v in fields.items()}
        shown.update({k: f"<file {Path(v).as_posix()}>" for k, v in files.items()})
        if body is not None:
            shown = body
        url = self.base + path + (f"?{query}" if query else "")
        self.out(f"{'would send' if self.dry else 'send'} {method} {path}{'?' + query if query else ''} {json.dumps(shown, ensure_ascii=False)}")
        if self.dry:
            return {}
        if body is not None:
            data, ctype = json.dumps(body).encode(), "application/json"
        else:
            data, ctype = multipart(fields, files)
        req = urllib.request.Request(url, data=data, method=method, headers={"x-api-key": self.key, "Content-Type": ctype})
        if self.sent:
            time.sleep(self.wait)
        self.sent += 1
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                text = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:400]
            raise Refused(f"{method} {path}: HTTP {err.code} {detail}") from None
        return json.loads(text) if text.strip() else {}


def art(root, name):
    path = root / ART / name
    return path if path.exists() else None


def step_products(root, state, client, update, notes):
    catalog = read_json(root / CATALOG)
    plan = read_json(root / PLAN)
    if not catalog or not plan:
        raise Refused(f"{CATALOG} and {PLAN} are needed (python3 tools/monetize.py plan)")
    planned = {p["key"]: p for p in plan.get("products", [])}
    universe = state["universeId"]
    changed = False
    for product in catalog["products"]:
        key, kind = product["key"], product["kind"]
        info = planned.get(key)
        if kind == "subscription":
            notes.append(f"{key}: subscriptions have no Open Cloud API; create it in Creator Hub, then python3 tools/monetize.py set-id {key} EXP-...")
            continue
        if info is None or "robux" not in info.get("suggested", {}):
            notes.append(f"{key}: no suggested Robux price in {PLAN}; skipped")
            continue
        fields = {"name": info["name"][:50], "description": info["description"][:1000], "price": int(info["suggested"]["robux"]), "isForSale": True, "isRegionalPricingEnabled": True}
        if kind == "gamepass":
            base, id_field = f"/game-passes/v1/universes/{universe}/game-passes", "gamePassId"
        else:
            base, id_field = f"/developer-products/v2/universes/{universe}/developer-products", "productId"
        has_id = isinstance(product["id"], int) and product["id"] > 0
        if has_id and not update:
            continue
        icon_name = f"{'pass' if kind == 'gamepass' else 'product'}_{key}.png"
        icon = art(root, icon_name)
        if icon is None:
            notes.append(f"{key}: no {ART}/{icon_name} yet; sent without an icon (python3 tools/store_art.py compose, then run --update)")
        if has_id:
            client.call("PATCH", f"{base}/{product['id']}", fields, {"imageFile": icon})
            continue
        result = client.call("POST", base, fields, {"imageFile": icon})
        if client.dry:
            continue
        new_id = result.get(id_field)
        if not isinstance(new_id, int) or new_id <= 0:
            raise Refused(f"{key}: the response had no {id_field}: {json.dumps(result)[:200]}")
        product.update(id=new_id, enabled=True, ownershipVerified=True)
        state["done"][f"products.{key}"] = {"id": new_id, "price": fields["price"], "at": now()}
        write_json(root / CATALOG, catalog)
        write_json(root / STATE, state)
        changed = True
    if changed and all(p["kind"] == "subscription" or (isinstance(p["id"], int) and p["id"] > 0) for p in catalog["products"]):
        notes.append("every pass and developer product has an id: set the catalog mode to \"game\" when the game is ready to sell")


def step_page(root, state, client, update, notes):
    page = read_json(root / store_page.PAGE)
    if page is None:
        raise Refused(f"{store_page.PAGE} missing (python3 tools/store_page.py draft)")
    errors, _ = store_page.lint_page(page)
    if errors:
        raise Refused("store page lint errors: " + "; ".join(errors[:5]))
    if "page" in state["done"] and not update:
        return
    body = {"displayName": store_page.title(page), "description": store_page.description(page)}
    client.call("PATCH", f"/cloud/v2/universes/{state['universeId']}/places/{state['placeId']}", query="updateMask=displayName,description", body=body)
    if not client.dry:
        state["done"]["page"] = {"at": now()}
        write_json(root / STATE, state)


def step_icon(root, state, client, update, notes):
    icon = art(root, "icon.png")
    if icon is None:
        notes.append(f"icon: {ART}/icon.png not made yet (python3 tools/store_art.py compose --template icon_hero ...)")
        return
    if "icon" in state["done"] and not update:
        return
    client.call("POST", f"/legacy-game-internationalization/v1/game-icon/games/{state['universeId']}/language-codes/{state['languageCode']}", files={"Files": icon})
    if not client.dry:
        state["done"]["icon"] = {"at": now()}
        write_json(root / STATE, state)


def step_thumbnails(root, state, client, update, notes):
    found = sorted((root / ART).glob("thumbnail_*.jpg")) + sorted((root / ART).glob("thumbnail_*.png"))
    if not found:
        notes.append(f"thumbnails: none in {ART}/ yet")
        return
    rank = {name: i for i, name in enumerate(THUMB_ORDER)}
    found.sort(key=lambda p: rank.get(re.sub(r"^thumbnail_", "", p.stem), 99))
    done = state["done"].setdefault("thumbnails", {})
    if update:
        done.clear()
    game, lang = state["universeId"], state["languageCode"]
    for path in found[:10]:
        if path.name in done:
            continue
        result = client.call("POST", f"/legacy-game-internationalization/v1/game-thumbnails/games/{game}/language-codes/{lang}/image", files={"Files": path})
        if not client.dry:
            done[path.name] = result.get("mediaAssetId")
            write_json(root / STATE, state)
    ids = [done[p.name] for p in found[:10] if done.get(p.name)]
    if ids:
        client.call("POST", f"/legacy-game-internationalization/v1/game-thumbnails/games/{game}/language-codes/{lang}/images/order", body={"mediaAssetIds": ids})


STEP_FUNCS = {"products": step_products, "page": step_page, "icon": step_icon, "thumbnails": step_thumbnails}


def execute(root, steps, client, update):
    state = load_state(root)
    if not client.dry and not (state["universeId"] and state["placeId"]):
        raise Refused(f"no experience recorded in {STATE}: python3 tools/store_publish.py target --universe ID --place ID")
    notes = []
    for step in steps:
        STEP_FUNCS[step](root, state, client, update, notes)
    for note in notes:
        client.out("note " + note)
    return notes


def cmd_target(args):
    root = Path(args.root)
    if args.universe <= 0 or args.place <= 0:
        raise Refused("universe and place ids are positive integers (Creator Hub > the experience > ... > Copy Universe ID / Start Place ID)")
    state = load_state(root)
    state.update(universeId=args.universe, placeId=args.place)
    write_json(root / STATE, state)
    print(f"store_publish: target universe {args.universe}, place {args.place}")
    return 0


def cmd_approve(args):
    root = Path(args.root)
    state = load_state(root)
    state["approval"] = {"by": args.by, "quote": args.quote, "date": datetime.date.today().isoformat(), "scope": "create and update passes and developer products, set prices, upload store art and page text; never spend"}
    write_json(root / STATE, state)
    print(f"store_publish: owner approval recorded ({args.by})")
    return 0


def cmd_plan(args):
    root = Path(args.root)
    execute(root, args.only or STEPS, Client(dry=True), args.update)
    print("store_publish: dry run; nothing was sent")
    return 0


def cmd_run(args):
    root = Path(args.root).resolve()
    if is_factory(root):
        raise Refused("this is the factory repository (SETUP_ONLY): run it in a game repository")
    if not load_state(root).get("approval"):
        raise Refused(f"no owner approval in {STATE}: python3 tools/store_publish.py approve --by NAME --quote \"the owner's words\"")
    if not args.yes:
        raise Refused("add --yes to send (run plan first to see every request)")
    key = os.environ.get(KEY_ENV, "").strip()
    if not key:
        raise Refused(f"set the Open Cloud API key in the {KEY_ENV} environment variable (python3 tools/store_publish.py scopes)")
    base = os.environ.get("STORE_PUBLISH_BASE", BASE)
    if base != BASE and not re.match(r"^http://127\.0\.0\.1:\d+$", base):
        raise Refused("STORE_PUBLISH_BASE may only point at a loopback test server")
    client = Client(dry=False, key=key, base=base, wait=float(os.environ.get("STORE_PUBLISH_WAIT", "0.4")))
    execute(root, args.only or STEPS, client, args.update)
    print(f"store_publish: {client.sent} requests sent")
    return 0


def cmd_scopes(_args):
    print("Create an API key: create.roblox.com > Open Cloud > API Keys > Create API Key. Add these permissions for the")
    print(f"game's experience only, restrict it to your IP if you can, and put it in the {KEY_ENV} environment variable:")
    for scope, why in SCOPES:
        print(f"  {scope:<28} {why}")
    print("Do not add asset, data store, messaging or badge permissions: this tool never needs them.")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("target")
    t.add_argument("--universe", type=int, required=True)
    t.add_argument("--place", type=int, required=True)
    t.add_argument("--root", default=".")
    a = sub.add_parser("approve")
    a.add_argument("--by", required=True)
    a.add_argument("--quote", required=True)
    a.add_argument("--root", default=".")
    for name in ("plan", "run"):
        p = sub.add_parser(name)
        p.add_argument("--root", default=".")
        p.add_argument("--only", nargs="+", choices=STEPS)
        p.add_argument("--update", action="store_true")
        if name == "run":
            p.add_argument("--yes", action="store_true")
    sub.add_parser("scopes")
    args = parser.parse_args(argv)
    try:
        return {"target": cmd_target, "approve": cmd_approve, "plan": cmd_plan, "run": cmd_run, "scopes": cmd_scopes}[args.cmd](args)
    except Refused as err:
        print(f"store_publish: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
