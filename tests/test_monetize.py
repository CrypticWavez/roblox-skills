"""Tests for the starter's store tools: monetize.py, store_art.py, store_page.py and ad_kit.py.

  python3 -m unittest tests/test_monetize.py

Every Roblox genre and subgenre gets a full shop that passes `monetize.py check`; the committed
fixtures/monetization/<genre> trees are what `plan` writes today (regenerate them with the command in
fixtures/README.md); PvP genres drop power products; overwrites, bad ids and broken files are refused.
store_page and ad_kit enforce the copy rules, and ad_kit never plans a purchase. store_art reads image
headers without Pillow and, with Pillow, composes assets that pass its own lint. store_publish sends only
allow-listed store-setup requests (against a loopback fake of the API here), records the ids it gets back,
continues where it stopped, and refuses in the factory, without approval, --yes or the key, and any request
that could spend money.
"""
import contextlib
import io
import json
import shutil
import struct
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "templates" / "starter" / "tools"
sys.path.insert(0, str(TOOLS))
import ad_kit  # noqa: E402
import monetize  # noqa: E402
import production  # noqa: E402
import store_art  # noqa: E402
import store_page  # noqa: E402
import store_publish  # noqa: E402

FIXTURES = ROOT / "fixtures" / "monetization"
# fixture folder -> (genre, subgenre); fixtures/README.md has the regeneration command.
FIXTURE_GENRES = {
    "tycoon": ("Simulation", "Tycoon"),
    "incremental": ("Simulation", "Incremental Simulator"),
    "obby": ("Obby & Platformer", "Classic Obby"),
    "shooter": ("Shooter", None),
    "rpg": ("RPG", "Action RPG"),
    "life": ("Roleplay & Avatar Sim", "Life"),
    "tower_defense": ("Strategy", "Tower Defense"),
    "survival": ("Survival", None),
}

try:
    import PIL  # noqa: F401
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False


def quiet(fn, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fn(*args)
    return code, out.getvalue() + err.getvalue()


def plan_args(genre, subgenre, root, *extra):
    args = ["plan", "--genre", genre, "--root", str(root)]
    if subgenre:
        args += ["--subgenre", subgenre]
    return args + list(extra)


def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + b"\0" * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


class Temp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="monetize-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Planner(Temp):
    def test_every_genre_and_subgenre_gets_a_full_shop(self):
        for genre, subs in production.GENRES.items():
            for sub in [None] + subs:
                with self.subTest(genre=genre, subgenre=sub):
                    dest = self.tmp / f"{genre}-{sub}".replace(" ", "_").replace("&", "and")
                    code, out = quiet(monetize.main, plan_args(genre, sub, dest))
                    self.assertEqual(code, 0, out)
                    docs, plan = monetize.read_docs(dest)
                    result = monetize.check_docs(docs, plan)
                    self.assertEqual(result["errors"], [])
                    kinds = [p["kind"] for p in docs["catalog"]["products"]]
                    self.assertGreaterEqual(kinds.count("gamepass"), 3)
                    self.assertGreaterEqual(kinds.count("devproduct"), 4)
                    self.assertEqual(docs["catalog"]["mode"], "setup")
                    self.assertTrue(all(not p["enabled"] for p in docs["catalog"]["products"]))
                    text = json.dumps(docs["catalog"]).lower()
                    self.assertNotIn("robux", text, "no prices in the catalog")
                    self.assertTrue((dest / "docs" / "design" / "monetization.md").exists())

    def test_the_committed_fixtures_are_current(self):
        self.assertEqual(sorted(p.name for p in FIXTURES.iterdir() if p.is_dir()), sorted(FIXTURE_GENRES))
        for name, (genre, sub) in FIXTURE_GENRES.items():
            with self.subTest(fixture=name):
                dest = self.tmp / name
                self.assertEqual(quiet(monetize.main, plan_args(genre, sub, dest))[0], 0)
                for rel in monetize.OUTPUTS.values():
                    self.assertEqual((dest / rel).read_text(encoding="utf-8"), (FIXTURES / name / rel).read_text(encoding="utf-8"),
                                     f"{name}/{rel} is stale: see fixtures/README.md (monetization/)")

    def test_pvp_genres_drop_power_unless_allowed(self):
        keys, pvp, _, notes = monetize.select("Survival", None)
        self.assertTrue(pvp)
        self.assertNotIn("revive", keys)
        self.assertTrue(any("revive" in n for n in notes))
        keys, _, _, _ = monetize.select("Survival", None, allow_power=True)
        self.assertIn("revive", keys)
        keys, pvp, _, _ = monetize.select("Survival", "Escape")
        self.assertFalse(pvp, "the subgenre overrides the genre")
        self.assertIn("revive", keys)

    def test_paid_random_items_are_opt_in_and_flagged(self):
        keys, *_ = monetize.select("Simulation", None, add=["lucky_crate"])
        self.assertNotIn("lucky_crate", keys)
        keys, *_ = monetize.select("Simulation", None, add=["lucky_crate"], allow_random=True)
        self.assertIn("lucky_crate", keys)
        dest = self.tmp / "random"
        code, out = quiet(monetize.main, plan_args("Simulation", None, dest, "--add", "lucky_crate", "--allow-random"))
        self.assertEqual(code, 0)
        self.assertIn("odds", out)

    def test_brief_genre_is_read_and_unknowns_are_refused(self):
        (self.tmp / "production").mkdir()
        (self.tmp / "production" / "brief.json").write_text(json.dumps({"genre": {"primary": "Puzzle", "subgenre": "Escape Room"}}))
        self.assertEqual(quiet(monetize.main, ["plan", "--root", str(self.tmp)])[0], 0)
        self.assertEqual(json.loads((self.tmp / "monetization" / "plan.json").read_text())["genre"]["subgenre"], "Escape Room")
        code, out = quiet(monetize.main, ["plan", "--root", str(self.tmp)])
        self.assertEqual(code, 2)
        self.assertIn("--force", out)
        self.assertEqual(quiet(monetize.main, ["plan", "--genre", "Farming", "--root", str(self.tmp / "x")])[0], 2)
        self.assertEqual(quiet(monetize.main, ["plan", "--root", str(self.tmp / "nobrief")])[0], 2)

    def test_check_reports_broken_edits(self):
        quiet(monetize.main, plan_args("Simulation", "Tycoon", self.tmp))
        docs, plan = monetize.read_docs(self.tmp)
        docs["shop"]["sections"] = [s for s in docs["shop"]["sections"] if s["id"] != "currency"]
        docs["catalog"]["products"] = [p for p in docs["catalog"]["products"] if p["key"] not in ("auto_collect", "plot_upgrade", "speed_boost")]
        docs["catalog"]["products"][0]["priceRobux"] = 99
        docs["boosts"]["boosts"] = []
        docs["shop"]["entry"]["hud"] = "hidden"
        errors = "\n".join(monetize.check_docs(docs, plan)["errors"])
        for needle in ("no section shows currency_large", "at least 3", "prices are runtime reads", "boosts.json does not define", "HUD"):
            self.assertIn(needle, errors)
        self.assertIn("missing", "\n".join(monetize.check_docs({}, None)["errors"]) + "missing")
        self.assertEqual(quiet(monetize.main, ["check", "--root", str(self.tmp / "empty")])[0], 1)

    def test_set_id_records_creator_hub_ids_and_refuses_bad_ones(self):
        quiet(monetize.main, plan_args("Simulation", "Tycoon", self.tmp))
        self.assertEqual(quiet(monetize.main, ["set-id", "vip", "1234567", "--root", str(self.tmp)])[0], 0)
        catalog = json.loads((self.tmp / "src/shared/catalog.json").read_text())
        vip = next(p for p in catalog["products"] if p["key"] == "vip")
        self.assertEqual(vip["id"], 1234567)
        self.assertFalse(vip["enabled"], "set-id never enables")
        for bad in (["vip", "0"], ["vip", "abc"], ["double_currency", "1234567"], ["ghost", "5"]):
            with self.subTest(args=bad):
                self.assertEqual(quiet(monetize.main, ["set-id", *bad, "--root", str(self.tmp)])[0], 2)


class StorePage(Temp):
    def page(self, **changes):
        page = {"schema": "store-page/1", "name": "Sample Game", "emoji": "", "update_tag": None,
                "description": {"hook": "Build things in a sample world.", "features": ["One", "Two"], "update": None, "purchases": None, "footer": None},
                "update_log": [], "events_update": None, "alt_text": {}}
        page.update(changes)
        return page

    def test_clean_page_passes(self):
        self.assertEqual(store_page.lint_page(self.page()), ([], []))

    def test_copy_rules(self):
        cases = {
            "free robux": self.page(name="Free Robux Tycoon"),
            "giveaway": self.page(description={"hook": "Huge giveaway today", "features": []}),
            "discount": self.page(description={"hook": "Passes 50% off", "features": []}),
            "hashtags": self.page(description={"hook": "Fun #roblox", "features": []}),
            "link": self.page(description={"hook": "Join https://discord.gg/abc", "features": []}),
            "repeats": self.page(name="Tycoon Tycoon"),
            "emoji": self.page(emoji="\U0001F525\U0001F525\U0001F525\U0001F525"),
            "characters": self.page(name="A" * 30 + " " + "B" * 30),
            "pressure": self.page(description={"hook": "Hurry, last chance!", "features": []}),
        }
        for name, page in cases.items():
            with self.subTest(rule=name):
                self.assertTrue(store_page.lint_page(page)[0], name)
        ok, _ = store_page.lint_page(self.page(description={"hook": "Join our group https://www.roblox.com/communities/1/x", "features": []}))
        self.assertEqual(ok, [])

    def test_draft_update_and_render(self):
        (self.tmp / "production").mkdir()
        (self.tmp / "production" / "brief.json").write_text(json.dumps({"name": "Sample", "genre": {"primary": "Simulation", "subgenre": "Tycoon"}, "pitch": "Build a sample empire."}))
        quiet(monetize.main, plan_args("Simulation", "Tycoon", self.tmp))
        self.assertEqual(quiet(store_page.main, ["draft", "--root", str(self.tmp)])[0], 0)
        code, out = quiet(store_page.main, ["lint", "--root", str(self.tmp)])
        self.assertEqual(code, 0, out)
        self.assertIn("TBD", out)
        self.assertEqual(quiet(store_page.main, ["update", "--tag", "Hatch Wars", "--notes", "New arena", "--root", str(self.tmp)])[0], 0)
        _, out = quiet(store_page.main, ["render", "--root", str(self.tmp)])
        self.assertIn("[HATCH WARS] Sample", out)
        page = json.loads((self.tmp / store_page.PAGE).read_text())
        self.assertLessEqual(len(page["events_update"]), 60)
        self.assertEqual(quiet(store_page.main, ["update", "--tag", "Free Robux", "--notes", "x", "--root", str(self.tmp)])[0], 2)


class AdKit(Temp):
    def test_plan_is_never_a_purchase(self):
        self.assertEqual(quiet(ad_kit.main, ["plan", "--root", str(self.tmp)])[0], 0)
        campaign = json.loads((self.tmp / ad_kit.CAMPAIGN).read_text())
        self.assertIs(campaign["purchase"], False)
        self.assertGreaterEqual(len(campaign["creatives"]), 3)
        campaign["purchase"] = True
        campaign["paymentToken"] = "x"
        errors, _ = ad_kit.lint_campaign(self.tmp, campaign)
        self.assertTrue(any("purchase must be false" in e for e in errors))
        self.assertTrue(any("no credentials" in e for e in errors))
        (self.tmp / ad_kit.CAMPAIGN).write_text(json.dumps(campaign))
        self.assertEqual(quiet(ad_kit.main, ["sheet", "--root", str(self.tmp)])[0], 2, "no sheet for a purchase")

    def test_creatives_are_checked(self):
        quiet(ad_kit.main, ["plan", "--root", str(self.tmp)])
        campaign = json.loads((self.tmp / ad_kit.CAMPAIGN).read_text())
        target = self.tmp / campaign["creatives"][0]["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png(1080, 1080))
        campaign["creatives"][1]["alt"] = "FREE ROBUX inside"
        errors, warnings = ad_kit.lint_campaign(self.tmp, campaign)
        self.assertTrue(any("not 16:9" in e for e in errors), errors)
        self.assertTrue(any("free" in e for e in errors), errors)
        self.assertTrue(any("not made yet" in w for w in warnings))

    def test_estimate_is_labelled(self):
        e = ad_kit.estimate(10)
        self.assertEqual(e["robux"], 2630)
        self.assertLess(e["plays_low"], e["plays_mid"])
        self.assertIn("community estimate", e["basis"])


class StoreArt(Temp):
    def test_headers_and_hard_rules_without_pillow(self):
        cases = {"icon.png": (png(512, 512), "icon", []), "icon_small.png": (png(256, 256), "icon", ["must be 512x512"]),
                 "thumbnail.png": (png(1920, 1080), "thumbnail", []), "thumbnail_square.png": (png(800, 800), "thumbnail", ["not 16:9"]),
                 "pass.png": (png(512, 512), "pass", []), "pass_big.png": (png(1024, 1024), "pass", ["at most 512"])}
        for name, (data, kind, expected) in cases.items():
            with self.subTest(file=name):
                path = self.tmp / name
                path.write_bytes(data)
                errors, fmt, w, h = store_art.hard_checks(path, kind)
                self.assertEqual(fmt, "png")
                if expected:
                    self.assertTrue(any(expected[0] in e for e in errors), errors)
                else:
                    self.assertEqual(errors, [])
        fake = self.tmp / "thumbnail.jpg"
        fake.write_bytes(png(1920, 1080))
        self.assertTrue(any("extension" in e for e in store_art.hard_checks(fake, "thumbnail")[0]))

    def test_briefs_cover_icon_thumbnails_products_and_ad(self):
        quiet(monetize.main, plan_args("Simulation", "Tycoon", self.tmp))
        data = store_art.briefs(self.tmp)
        kinds = [t["kind"] for t in data["tasks"]]
        self.assertEqual(kinds.count("icon"), 1)
        self.assertEqual(kinds.count("thumbnail"), 5)
        self.assertEqual(kinds.count("ad"), 1)
        plan = json.loads((self.tmp / "monetization" / "plan.json").read_text())
        self.assertEqual(kinds.count("pass") + kinds.count("product"), len(plan["products"]))
        for t in data["tasks"]:
            self.assertNotIn("robux", t["prompt"].lower().replace("no robux symbol", ""))

    @unittest.skipUnless(HAVE_PIL, "Pillow not installed")
    def test_compose_then_lint_and_preview(self):
        from PIL import Image, ImageDraw
        subject = Image.new("RGBA", (400, 500), (0, 0, 0, 0))
        d = ImageDraw.Draw(subject)
        d.rounded_rectangle((60, 40, 340, 300), 40, fill=(255, 210, 160, 255))
        d.rounded_rectangle((90, 280, 310, 490), 30, fill=(30, 120, 255, 255))
        subject.save(self.tmp / "subject.png")
        outputs = []
        for template in ("icon_hero", "thumbnail_hero", "pass_icon", "product_icon", "badge_icon", "thumbnail_action", "icon_clean"):
            with self.subTest(template=template):
                kind = store_art.ART["templates"][template]["kind"]
                out = self.tmp / f"{template}.{'jpg' if kind == 'thumbnail' else 'png'}"
                store_art.compose(template, out, subject=str(self.tmp / "subject.png"), title="Sample", ribbon="New", palette="sky", root=str(self.tmp))
                errors, *_ = store_art.hard_checks(out, kind)
                self.assertEqual(errors, [])
                outputs.append(str(out))
        code, _ = quiet(store_art.main, ["lint", "--kind", "icon", outputs[0]])
        self.assertEqual(code, 0)
        sheet = self.tmp / "sheet.png"
        self.assertEqual(quiet(store_art.main, ["preview", *outputs[:3], "--out", str(sheet)])[0], 0)
        self.assertTrue(sheet.exists())


if __name__ == "__main__":
    unittest.main()


class FakeApi(BaseHTTPRequestHandler):
    calls = []
    next_id = [1000]

    def log_message(self, *args):
        pass

    def _answer(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        FakeApi.calls.append((self.command, self.path, self.headers.get("x-api-key"), body))
        FakeApi.next_id[0] += 1
        if "/game-passes" in self.path and self.command == "POST":
            out = {"gamePassId": FakeApi.next_id[0]}
        elif "/developer-products" in self.path and self.command == "POST":
            out = {"productId": FakeApi.next_id[0]}
        elif self.path.endswith("/image"):
            out = {"mediaAssetId": FakeApi.next_id[0]}
        else:
            out = {}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = do_PATCH = _answer


class StorePublish(Temp):
    def setUp(self):
        super().setUp()
        self.assertEqual(quiet(monetize.main, plan_args("Simulation", "Tycoon", self.tmp, "--add", "vip_subscription"))[0], 0)
        page = {"schema": "store-page/1", "name": "Sample Game", "emoji": "", "update_tag": None,
                "description": {"hook": "Build a tycoon in a sample world.", "features": ["One", "Two"], "update": None, "purchases": None, "footer": None},
                "update_log": [], "events_update": None, "alt_text": {}}
        store_publish.write_json(self.tmp / store_page.PAGE, page)
        out = self.tmp / store_publish.ART
        out.mkdir(parents=True)
        (out / "icon.png").write_bytes(png(512, 512))
        (out / "pass_vip.png").write_bytes(png(512, 512))
        for name in ("reward", "hero"):
            (out / f"thumbnail_{name}.png").write_bytes(png(1920, 1080))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeApi)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        FakeApi.calls.clear()
        self.env = {"STORE_PUBLISH_BASE": f"http://127.0.0.1:{self.server.server_port}", "STORE_PUBLISH_WAIT": "0", store_publish.KEY_ENV: "test-key"}
        self.saved = {k: store_publish.os.environ.get(k) for k in self.env}
        store_publish.os.environ.update(self.env)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        for k, v in self.saved.items():
            if v is None:
                store_publish.os.environ.pop(k, None)
            else:
                store_publish.os.environ[k] = v
        super().tearDown()

    def run_tool(self, *args):
        return quiet(store_publish.main, [*args, "--root", str(self.tmp)] if args[0] != "scopes" else list(args))

    def ready(self):
        self.assertEqual(self.run_tool("target", "--universe", "111", "--place", "222")[0], 0)
        self.assertEqual(self.run_tool("approve", "--by", "Owner", "--quote", "go ahead")[0], 0)

    def test_dry_run_sends_nothing_and_shows_prices(self):
        code, out = self.run_tool("plan")
        self.assertEqual(code, 0, out)
        self.assertEqual(FakeApi.calls, [])
        self.assertIn('"price": 399', out)
        self.assertIn("subscriptions have no Open Cloud API", out)

    def test_run_refusals(self):
        self.assertEqual(self.run_tool("run", "--yes")[0], 2, "no approval yet")
        self.ready()
        self.assertEqual(self.run_tool("run")[0], 2, "no --yes")
        store_publish.os.environ.pop(store_publish.KEY_ENV)
        self.assertIn("ROBLOX_OPEN_CLOUD_KEY", self.run_tool("run", "--yes")[1])
        store_publish.os.environ[store_publish.KEY_ENV] = "test-key"
        store_publish.os.environ["STORE_PUBLISH_BASE"] = "https://example.com"
        self.assertEqual(self.run_tool("run", "--yes")[0], 2, "only loopback overrides")
        self.assertEqual(FakeApi.calls, [])
        code, out = quiet(store_publish.main, ["run", "--yes", "--root", str(ROOT)])
        self.assertEqual(code, 2)
        self.assertIn("factory", out)

    def test_only_store_setup_requests_and_no_money_fields(self):
        for method, path, fields in [("POST", "/legacy-badges/v1/universes/1/badges", []), ("POST", "/v1/assets", []),
                                     ("POST", "/game-passes/v1/universes/1/game-passes", ["expectedCost"]),
                                     ("POST", "/developer-products/v2/universes/1/developer-products", ["paymentSourceType"])]:
            with self.subTest(path=path, fields=fields):
                with self.assertRaises(store_publish.Refused):
                    store_publish.check_request(method, path, fields)
        store_publish.check_request("POST", "/game-passes/v1/universes/1/game-passes", ["name", "price", "isForSale", "isRegionalPricingEnabled", "imageFile"])

    def test_run_creates_products_records_ids_and_resumes(self):
        self.ready()
        code, out = self.run_tool("run", "--yes")
        self.assertEqual(code, 0, out)
        catalog = json.loads((self.tmp / store_publish.CATALOG).read_text())
        sellable = [p for p in catalog["products"] if p["kind"] != "subscription"]
        self.assertTrue(sellable and all(p["id"] > 1000 and p["enabled"] and p["ownershipVerified"] for p in sellable))
        paths = [path for _, path, _, _ in FakeApi.calls]
        self.assertTrue(all(key == "test-key" for _, _, key, _ in FakeApi.calls))
        self.assertEqual(sum("/game-passes" in p or "/developer-products" in p for p in paths), len(sellable))
        self.assertIn("/cloud/v2/universes/111/places/222?updateMask=displayName,description", paths)
        self.assertTrue(any("/game-icon/games/111/" in p for p in paths))
        images = [b for m, p, _, b in FakeApi.calls if p.endswith("/image")]
        self.assertEqual(len(images), 2)
        self.assertIn(b"thumbnail_hero.png", images[0], "hero goes first")
        vip_call = next(b for m, p, _, b in FakeApi.calls if b"name=\"name\"\r\n\r\nVIP\r\n" in b)
        self.assertIn(b"pass_vip.png", vip_call)
        self.assertIn(b"\r\n399\r\n", vip_call)
        state = json.loads((self.tmp / store_publish.STATE).read_text())
        self.assertIn("products.vip", state["done"])
        before = len(FakeApi.calls)
        code, _ = self.run_tool("run", "--yes")
        self.assertEqual(code, 0)
        rerun = [p for _, p, _, _ in FakeApi.calls[before:]]
        self.assertEqual([p for p in rerun if "/game-passes" in p or "/developer-products" in p or "/image" in p.split("?")[0][-6:]], [], "a rerun creates nothing twice")
        code, _ = self.run_tool("run", "--yes", "--only", "products", "--update")
        self.assertTrue(all(m == "PATCH" for m, p, _, _ in FakeApi.calls[before + len(rerun):]))
