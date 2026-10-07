"""Tests for the starter's release checker (templates/starter/tools/release_check.py).

  python3 -m unittest tests/test_release_check.py

fixtures/release/good is a minimal generated-project tree that passes every automated item;
fixtures/release/bad/<case>/case.json names the one A-item the case must trip and how it differs from
good (json_set, replace, append, delete, files/ overlay, images). Store art is written here as blank
PNGs (good/images.json) and `{{TOKENS}}` are filled in, so the fixtures commit no binary, no asset id
outside the synthetic range and no literal publish command.
"""
import contextlib
import io
import json
import re
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STARTER = ROOT / "templates" / "starter"
FIXTURES = ROOT / "fixtures" / "release"
sys.path.insert(0, str(STARTER / "tools"))
import release_check  # noqa: E402

TOKENS = {"SYNTHETIC_ASSET_ID": "900000001", "UPLOAD_VERB": "upload"}
AUTOMATED = [f"A{n:02d}" for n in range(1, 19)]
_png_cache = {}


def png(width, height):
    """A blank 8-bit grayscale PNG of the given size."""
    key = (width, height)
    if key not in _png_cache:
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

        raw = (b"\x00" + bytes(width)) * height
        _png_cache[key] = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    return _png_cache[key]


def fill(text):
    for key, value in TOKENS.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def copy_tree(src, dest):
    for path in sorted(src.rglob("*")):
        if path.is_file() and path.name != "images.json":
            rel = path.relative_to(src).as_posix().removesuffix(".tmpl")
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(fill(path.read_text(encoding="utf-8")), encoding="utf-8")


def set_path(data, dotted, value):
    parts = dotted.split(".")
    node = data
    for part in parts[:-1]:
        node = node[int(part)] if isinstance(node, list) else node[part]
    last = parts[-1]
    if isinstance(node, list):
        node[int(last)] = value
    else:
        node[last] = value


def materialise(dest, case_dir=None):
    """Write the good tree, then the case's changes, into dest; returns the case (or None)."""
    copy_tree(FIXTURES / "good", dest)
    images = json.loads((FIXTURES / "good" / "images.json").read_text(encoding="utf-8"))["images"]
    case = None
    if case_dir is not None:
        case = json.loads((case_dir / "case.json").read_text(encoding="utf-8"))
        if (case_dir / "files").is_dir():
            copy_tree(case_dir / "files", dest)
        for rel, changes in case.get("json_set", {}).items():
            data = json.loads((dest / rel).read_text(encoding="utf-8"))
            for dotted, value in changes.items():
                set_path(data, dotted, value)
            (dest / rel).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        for rel, pairs in case.get("replace", {}).items():
            text = (dest / rel).read_text(encoding="utf-8")
            for old, new in pairs:
                if old not in text:
                    raise AssertionError(f"{case_dir.name}: {old!r} not found in {rel}")
                text = text.replace(old, new)
            (dest / rel).write_text(text, encoding="utf-8")
        for rel, extra in case.get("append", {}).items():
            with (dest / rel).open("a", encoding="utf-8") as handle:
                handle.write(extra)
        for rel in case.get("delete", []):
            (dest / rel).unlink()
        images.update(case.get("images", {}))
    for rel, (width, height) in images.items():
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        (dest / rel).write_bytes(png(width, height))
    return case


def statuses(report):
    return {item["id"]: item["status"] for item in report["items"]}


def failing(report):
    return sorted(i for i, s in statuses(report).items() if s == "FAIL")


def problems_of(report, item_id):
    return next(i["problems"] for i in report["items"] if i["id"] == item_id)


class ReleaseFixtureCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-check-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tree(self, case_dir=None):
        dest = self.tmp / (case_dir.name if case_dir else "good")
        dest.mkdir()
        return dest, materialise(dest, case_dir)


class GoodFixture(ReleaseFixtureCase):
    def test_good_passes_every_automated_item_and_owner_items_stay_required(self):
        dest, _ = self.tree()
        report = release_check.run_checks(dest)
        self.assertEqual(report["schema"], "release-check/1")
        got = statuses(report)
        for item_id in AUTOMATED:
            self.assertEqual(got[item_id], "PASS", f"{item_id}: {problems_of(report, item_id)}")
        owner = [i for i in report["items"] if i["tier"] != "A"]
        self.assertGreaterEqual(len(owner), 20)
        self.assertTrue(all(i["status"] == "OWNER_REQUIRED" for i in owner))
        self.assertEqual({i["tier"] for i in owner}, {"S", "O", "P"})
        self.assertTrue(report["summary"]["agent_checks_pass"])
        self.assertEqual(report["summary"]["publish"], "owner-only")

    def test_owner_items_cover_the_documented_store_specs(self):
        specs = {i["id"]: i for i in release_check.ITEMS}
        self.assertIn("512x512", specs["O07"]["spec"])  # icon
        self.assertIn("16:9", specs["O08"]["spec"])  # thumbnails
        self.assertIn("3 MB", specs["O08"]["spec"])
        self.assertIn("100 Robux", specs["O09"]["spec"])  # badges after the free ones
        self.assertIn("{experienceName}", specs["O11"]["spec"])  # friend invite message
        self.assertIn("200 characters", specs["O11"]["spec"])
        self.assertIn("questionnaire", specs["O03"]["spec"].lower() + specs["O03"]["title"].lower())
        self.assertTrue(all(i["source"] for i in release_check.ITEMS))

    def test_cli_writes_the_report_and_exits_zero(self):
        dest, _ = self.tree()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = release_check.main(["--root", str(dest)])
        self.assertEqual(code, 0, out.getvalue())
        report = json.loads((dest / "release" / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(failing(report), [])
        self.assertIn("publish: owner-only", out.getvalue())


class BadFixtures(ReleaseFixtureCase):
    def cases(self):
        return sorted(p for p in (FIXTURES / "bad").iterdir() if (p / "case.json").is_file())

    def test_every_automated_item_has_exactly_one_bad_case(self):
        expects = [json.loads((c / "case.json").read_text(encoding="utf-8"))["expect"] for c in self.cases()]
        self.assertEqual(sorted(expects), AUTOMATED)

    def test_each_bad_case_fails_exactly_its_item(self):
        for case_dir in self.cases():
            with self.subTest(case=case_dir.name):
                dest, case = self.tree(case_dir)
                report = release_check.run_checks(dest)
                self.assertEqual(failing(report), [case["expect"]], f"{case_dir.name}: {case['why']}\n"
                                 + "\n".join(f"{i}: {problems_of(report, i)}" for i in failing(report)))
                self.assertFalse(report["summary"]["agent_checks_pass"])
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(release_check.main(["--root", str(dest), "--out", str(dest / "r.json")]), 1)


class PaidRandomTag(ReleaseFixtureCase):
    """A05 and GameKit Commerce read one tag: a product Commerce gates on paidRandomItems is one A05 checks."""

    def edit_json(self, path, change):
        data = json.loads(path.read_text(encoding="utf-8"))
        change(data)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def test_the_tag_is_gamekit_commerce_random_tag(self):
        source = (ROOT / "packages" / "GameKit" / "Commerce.luau").read_text(encoding="utf-8")
        match = re.search(r'^Commerce\.RANDOM_TAG = "([^"]+)"', source, re.MULTILINE)
        self.assertIsNotNone(match, "Commerce.RANDOM_TAG not found in packages/GameKit/Commerce.luau")
        self.assertEqual(release_check.RANDOM_TAG, match.group(1))
        a05 = next(i for i in release_check.ITEMS if i["id"] == "A05")
        self.assertIn(f"tagged {match.group(1)} ", a05["spec"])
        good = FIXTURES / "good"
        catalog = json.loads((good / "src" / "shared" / "catalog.json").read_text(encoding="utf-8"))
        declared = [e["product"] for e in json.loads((good / "release" / "release.json").read_text(encoding="utf-8"))["paid_random_items"]]
        self.assertTrue(declared)
        for product in catalog["products"]:
            self.assertEqual(match.group(1) in product.get("tags", []), product["key"] in declared, product["key"])

    def test_a_declared_item_without_the_tag_fails(self):
        dest, _ = self.tree()
        catalog = dest / "src" / "shared" / "catalog.json"
        self.edit_json(catalog, lambda d: d["products"][1].update(tags=["paid_random"]))  # the runbook's former tag
        report = release_check.run_checks(dest)
        self.assertEqual(failing(report), ["A05"])
        self.assertTrue(any("random_pack_a' is not tagged paid_random_item" in p for p in problems_of(report, "A05")),
                        problems_of(report, "A05"))

    def test_a_tagged_product_without_a_declaration_fails(self):
        dest, _ = self.tree()
        self.edit_json(dest / "src" / "shared" / "catalog.json",
                       lambda d: d["products"][0].setdefault("tags", []).append(release_check.RANDOM_TAG))
        report = release_check.run_checks(dest)
        self.assertEqual(failing(report), ["A05"])
        self.assertIn("catalog product currency_pack_a is tagged paid_random_item but has no release.json paid_random_items entry",
                      problems_of(report, "A05"))


class ProjectMappings(ReleaseFixtureCase):
    def mapped(self, target, service="ReplicatedStorage"):
        """run_checks on the good tree plus one Rojo node mapping target into service."""
        dest = self.tmp / f"map-{service}-{target.replace('/', '-')}"
        dest.mkdir()
        materialise(dest)
        path = dest / "default.project.json"
        project = json.loads(path.read_text(encoding="utf-8"))
        project["tree"].setdefault(service, {})["Extra"] = {"$path": {"optional": target}}
        path.write_text(json.dumps(project, indent=2) + "\n", encoding="utf-8")
        return release_check.run_checks(dest)

    def test_wally_folders_and_authoring_packages_never_map_into_a_replicated_service_in_any_case(self):
        # Windows and macOS resolve names case-insensitively; the authoring packages live in factory/ (new_project.py).
        for target in ("Packages", "packages", "PACKAGES", "devpackages", "factory/SceneKit", "Factory/ProcGen", "factory/pipeline",
                       "src/server", "src/server/Phases.luau",
                       # the whole factory folder holds the authoring packages too, however the path is spelled
                       "factory", "factory/", "Factory", "./factory/SceneKit", "factory/SceneKit/Building.luau"):
            with self.subTest(target=target):
                report = self.mapped(target)
                self.assertEqual(failing(report), ["A01"])
                self.assertTrue(any(f"maps {target.strip('/')} into a replicated service" in p for p in problems_of(report, "A01")))

    def test_the_starter_layout_passes(self):
        # Kits and the leaf copies replicate; authoring packages stay in ServerStorage (tools/new_project.py package_nodes).
        for target, service in (("factory/GameKit", "ReplicatedStorage"), ("factory/ProcGen/Rng.luau", "ReplicatedStorage"),
                                ("factory/SceneKit/Lighting.luau", "ReplicatedStorage"),
                                ("factory/SceneKit", "ServerStorage"), ("factory/Pipeline", "ServerStorage")):
            with self.subTest(target=target):
                self.assertEqual(statuses(self.mapped(target, service))["A01"], "PASS")

    def test_the_leaf_list_matches_the_starter(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import new_project  # noqa: E402

        leaves = {f"{pkg}/{name}.luau" for pkg, names in new_project.LEAVES.items() for name in names}
        self.assertEqual(release_check.AUTHORING_LEAVES, leaves)

    def test_server_storage_may_hold_server_packages(self):
        dest, _ = self.tree()
        project = json.loads((dest / "default.project.json").read_text(encoding="utf-8"))
        self.assertEqual(project["tree"]["ServerStorage"]["ServerPackages"], {"$path": {"optional": "ServerPackages"}})
        self.assertNotIn("Packages", project["tree"]["ReplicatedStorage"])
        self.assertEqual(statuses(release_check.run_checks(dest))["A01"], "PASS")


class CatalogTopLevel(ReleaseFixtureCase):
    """A03 rejects at the top level what GameKit Catalog.define rejects (packages/GameKit/Catalog.luau)."""

    def test_the_top_level_keys_are_catalog_validates(self):
        source = (ROOT / "packages" / "GameKit" / "Catalog.luau").read_text(encoding="utf-8")
        loop = re.search(r"for key in catalog do\s*\n\s*if ((?:key ~= \"\w+\"(?: and )?)+) then", source)
        self.assertIsNotNone(loop, "the top-level key check of Catalog.validate not found")
        self.assertEqual(sorted(re.findall(r'"(\w+)"', loop.group(1))), sorted(release_check.CATALOG_KEYS))

    def edited(self, change):
        dest = Path(tempfile.mkdtemp(prefix="catalog-", dir=self.tmp))
        materialise(dest)
        path = dest / "src" / "shared" / "catalog.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        change(data)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return release_check.run_checks(dest)

    def test_an_unknown_top_level_key_fails_a03(self):
        report = self.edited(lambda d: d.update(note="ids are synthetic"))  # Catalog.define: "unexpected key note"
        self.assertEqual(failing(report), ["A03"])
        self.assertIn("src/shared/catalog.json: unexpected top-level key 'note' (GameKit Catalog.define accepts only schema, mode, "
                      "products)", problems_of(report, "A03"))

    def test_products_must_be_a_list(self):
        for value in ({"currency_pack_a": {}}, None, "products"):
            with self.subTest(products=value):
                report = self.edited(lambda d: d.update(products=value))
                self.assertIn("A03", failing(report))
                self.assertIn("src/shared/catalog.json: products must be a list", problems_of(report, "A03"))


    def test_every_product_entry_must_be_an_object(self):
        report = self.edited(lambda d: d["products"].insert(0, "junk"))  # Catalog.define: "products[1] must be a table"
        self.assertEqual(failing(report), ["A03"])
        self.assertIn("src/shared/catalog.json: products[1] must be an object (GameKit Catalog.define rejects it)",
                      problems_of(report, "A03"))

    def test_ad_reward_follows_catalog_define(self):
        # Catalog.define: adReward is a boolean, only on developer products, whose grants are then fixed (no custom grant).
        self.assertEqual(statuses(self.edited(lambda d: d["products"][0].update(adReward=True)))["A03"], "PASS")
        self.assertEqual(statuses(self.edited(lambda d: d["products"][0].update(adReward=False)))["A03"], "PASS")
        cases = (
            (0, {"grants": [{"type": "currency", "currency": "currency_a", "amount": 1}]}, "adReward must be true or false"),
            (1, True, "adReward only on developer products, with fixed"),  # a custom grant is not fixed
            (2, True, "adReward only on developer products, with fixed"),  # a game pass
        )
        for index, value, message in cases:
            with self.subTest(index=index, value=value):
                report = self.edited(lambda d: d["products"][index].update(adReward=value))
                self.assertEqual(failing(report), ["A03"])
                self.assertTrue(any(message in p for p in problems_of(report, "A03")), problems_of(report, "A03"))


class OwnerItems(ReleaseFixtureCase):
    def owner_file(self, dest, records, exceptions=()):
        path = dest / "release" / "owner-fixture.json"
        path.write_text(json.dumps({"schema": "release-owner/1", "owner": "fixture",
                                    "records": records, "exceptions": list(exceptions)}), encoding="utf-8")

    def test_owner_records_never_turn_an_item_into_pass(self):
        dest, _ = self.tree()
        ids = [i["id"] for i in release_check.ITEMS]
        self.owner_file(dest, [{"id": i, "date": "2026-10-06", "note": "fixture"} for i in ids])
        report = release_check.run_checks(dest)
        for item in report["items"]:
            if item["tier"] == "A":
                self.assertEqual(item["status"], "PASS")  # decided by the check alone
                continue
            self.assertEqual(item["status"], "OWNER_REQUIRED", item["id"])
            self.assertEqual(item["owner_record"]["file"], "release/owner-fixture.json")
        self.assertEqual(report["summary"]["owner_recorded"], len([i for i in ids if not i.startswith("A")]))

    def test_an_owner_record_cannot_rescue_a_failing_automated_item(self):
        dest, _ = self.tree(FIXTURES / "bad" / "a12-debug-on")
        self.owner_file(dest, [{"id": "A12", "date": "2026-10-06", "note": "fixture"}],
                        [{"id": "A12", "path": "src/shared/Config.luau", "reason": "fixture", "date": "2026-10-06"}])
        self.assertEqual(statuses(release_check.run_checks(dest))["A12"], "FAIL")

    def test_an_owner_exception_waives_a_publish_tripwire_hit(self):
        dest, _ = self.tree(FIXTURES / "bad" / "a16-publish-command")
        self.owner_file(dest, [], [{"id": "A16", "path": "scripts/ship.sh", "reason": "fixture", "date": "2026-10-06"}])
        report = release_check.run_checks(dest)
        self.assertEqual(statuses(report)["A16"], "WAIVED_BY_OWNER")
        self.assertTrue(report["summary"]["agent_checks_pass"])

    def test_a_malformed_owner_file_is_reported(self):
        dest, _ = self.tree()
        (dest / "release" / "owner-bad.json").write_text('{"schema": "something-else"}', encoding="utf-8")
        report = release_check.run_checks(dest)
        self.assertTrue(report["summary"]["owner_file_problems"])
        self.assertTrue(all(i["status"] == "OWNER_REQUIRED" for i in report["items"] if i["tier"] != "A"))


class FreshStarter(unittest.TestCase):
    def test_the_runbook_is_generated_from_the_checklist(self):
        current = (STARTER / "docs" / "release-runbook.md").read_text(encoding="utf-8")
        self.assertEqual(current, release_check.runbook_text(),
                         "regenerate: python3 templates/starter/tools/release_check.py --root templates/starter "
                         "--write-runbook docs/release-runbook.md")

    def test_a_fresh_starter_fails_only_on_undecided_release_data(self):
        report = release_check.run_checks(STARTER)
        self.assertEqual(failing(report), ["A08", "A09", "A17", "A18"], {i: problems_of(report, i)[:2] for i in failing(report)})
        self.assertTrue(all(i["status"] == "OWNER_REQUIRED" for i in report["items"] if i["tier"] != "A"))


class Helpers(unittest.TestCase):
    def test_strip_comments_keeps_strings_and_line_numbers(self):
        src = 'local a = "x -- y" -- gone\n--[[ long\ncomment ]] local b = [[ keep -- ]]\nlocal c = [==[ a ]] b ]==] -- gone'
        out = release_check.strip_comments(src)
        self.assertEqual(out.count("\n"), src.count("\n"))
        self.assertIn('"x -- y"', out)
        self.assertIn("[[ keep -- ]]", out)
        self.assertIn("[==[ a ]] b ]==]", out)
        self.assertNotIn("gone", out)
        self.assertNotIn("comment", out)

    def test_image_headers(self):
        tmp = Path(tempfile.mkdtemp(prefix="image-info-"))
        try:
            (tmp / "a.png").write_bytes(png(16, 9))
            (tmp / "b.gif").write_bytes(b"GIF89a" + struct.pack("<HH", 30, 20) + b"\0" * 10)
            (tmp / "c.bmp").write_bytes(b"BM" + b"\0" * 16 + struct.pack("<ii", 40, -30) + b"\0" * 8)
            sof = b"\xff\xc0" + struct.pack(">H", 17) + b"\x08" + struct.pack(">HH", 1080, 1920) + b"\0" * 10
            (tmp / "d.jpg").write_bytes(b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 4) + b"\0\0" + sof)
            (tmp / "e.txt").write_text("not an image")
            self.assertEqual(release_check.image_info(tmp / "a.png"), ("png", 16, 9))
            self.assertEqual(release_check.image_info(tmp / "b.gif"), ("gif", 30, 20))
            self.assertEqual(release_check.image_info(tmp / "c.bmp"), ("bmp", 40, 30))
            self.assertEqual(release_check.image_info(tmp / "d.jpg"), ("jpg", 1920, 1080))
            self.assertEqual(release_check.image_info(tmp / "e.txt"), (None, 0, 0))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_weights_are_checked_at_display_precision(self):
        ctx = type("Ctx", (), {})()
        ctx.meta = {"paid_random_items": [{"product": "p", "weights": {"a": 1, "b": 1, "c": 1}, "disclosure_key": "k"}]}
        ctx.catalog, ctx.csv_keys, ctx.root = None, {"k": "x"}, STARTER
        ctx.products = lambda: []
        ctx.realm = lambda *realms: []
        ctx.sources = []
        problems, _ = release_check.check_a05(ctx)
        self.assertTrue(any("99.99%" in p for p in problems), problems)  # 33.33 x 3


if __name__ == "__main__":
    unittest.main()
