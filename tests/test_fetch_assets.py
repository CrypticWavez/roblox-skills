"""tools/fetch_assets.py and tools/asset_sources.py with file:// fixtures only: dry runs, pins, re-pins,
licence-text checks, non-CC0 and unsafe archives refused. No network."""
import contextlib
import copy
import hashlib
import io
import json
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import asset_sources  # noqa: E402
import fetch_assets  # noqa: E402

LICENCE_TEXT = b"CC0 1.0 Universal (fixture text for tests)\n"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32


def fixture_sources(licence_url):
    doc = json.loads((ROOT / "assets" / "sources.json").read_text())
    sha = hashlib.sha256(LICENCE_TEXT).hexdigest()
    doc["licence_texts"]["CC0-1.0"] = {"url": licence_url, "sha256": sha, "bytes": len(LICENCE_TEXT), "retrieved": "2026-10-06"}
    for source in doc["sources"]:
        source["licence_text_sha256"] = sha
    return doc


def make_zip(path, members):
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)
    return path


class FetchAssetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fetch-assets-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.site = self.tmp / "site"
        (self.site / "get").mkdir(parents=True)
        self.licence = self.tmp / "licence"
        self.licence.mkdir()
        (self.licence / "legalcode.txt").write_bytes(LICENCE_TEXT)
        self.sources = self.tmp / "sources.json"
        self.sources_doc = fixture_sources((self.licence / "legalcode.txt").as_uri())
        self.save_sources()
        self.provenance = self.tmp / "provenance.json"
        self.provenance.write_text(json.dumps({"schema": "asset-provenance/1", "files": [], "assets": []}, indent=2) + "\n")
        self.cache = self.tmp / "cache"
        # ambientCG serves /get?file=<item>.zip; as a file:// fixture that is a file literally named so.
        self.item = "Concrete034_1K-PNG"
        make_zip(self.site / f"get?file={self.item}.zip", {
            "Concrete034_1K-PNG_Color.png": PNG,
            "Concrete034_1K-PNG_NormalGL.png": PNG,
            "Concrete034.usda": b"#usda 1.0\n",
            "readme.html": b"<p>skip me</p>",
            "maps/": b"",
        })

    def save_sources(self):
        self.sources.write_text(json.dumps(self.sources_doc, indent=2) + "\n")

    def run_tool(self, *argv, test_roots=True):
        args = [*argv, "--sources", str(self.sources), "--provenance", str(self.provenance), "--cache", str(self.cache), "--today", "2026-10-06"]
        if test_roots:
            args += ["--allow-file-urls", "--url-root", self.site.as_uri(), "--licence-root", self.licence.as_uri()]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = fetch_assets.main(args)
        return code, out.getvalue()

    def files(self):
        return json.loads(self.provenance.read_text())["files"]

    def test_dry_run_touches_nothing(self):
        before = self.provenance.read_text()
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item)
        self.assertEqual(code, 0, text)
        self.assertIn("dry run", text)
        self.assertIn("https://ambientcg.com/get?file=Concrete034_1K-PNG.zip", text)
        self.assertIn("not pinned yet", text)
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.provenance.read_text(), before)

    def test_pin_extracts_records_and_repin_verifies(self):
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin", "--purpose", "material-library fixture")
        self.assertEqual(code, 0, text)
        archive = (self.site / f"get?file={self.item}.zip").read_bytes()
        entry = self.files()[0]
        self.assertEqual(entry["sha256"], hashlib.sha256(archive).hexdigest())
        self.assertEqual((entry["bytes"], entry["type"], entry["licence"], entry["approval"]), (len(archive), "zip", "CC0-1.0", "pinned"))
        self.assertEqual(entry["url"], "https://ambientcg.com/get?file=Concrete034_1K-PNG.zip", "the real URL, never the fixture path")
        self.assertEqual(entry["licence_text_sha256"], hashlib.sha256(LICENCE_TEXT).hexdigest())
        self.assertNotIn(str(self.tmp), self.provenance.read_text())
        item_dir = self.cache / "ambientcg" / self.item
        manifest = json.loads((item_dir / "cache-manifest.json").read_text())
        self.assertEqual([f["path"] for f in manifest["files"]], ["Concrete034.usda", "Concrete034_1K-PNG_Color.png", "Concrete034_1K-PNG_NormalGL.png"])
        self.assertEqual(manifest["skipped"], ["readme.html"])
        self.assertTrue((item_dir / "files" / "Concrete034_1K-PNG_Color.png").is_file())
        self.assertFalse((item_dir / "files" / "readme.html").exists())
        self.assertEqual(asset_sources.provenance_problems(json.loads(self.provenance.read_text()), self.sources_doc), [])

        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin")
        self.assertEqual(code, 0, text)
        self.assertIn("verified against the existing pin", text)
        self.assertEqual(len(self.files()), 1)
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item)
        self.assertIn("pinned " + entry["sha256"][:12], text)

    def test_changed_file_at_the_source_is_refused(self):
        self.run_tool("--source", "ambientcg", "--item", self.item, "--pin", "--purpose", "fixture")
        before = self.provenance.read_text()
        make_zip(self.site / f"get?file={self.item}.zip", {"Concrete034_1K-PNG_Color.png": PNG + b"changed"})
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin")
        self.assertEqual(code, 1)
        self.assertIn("differs from the pin", text)
        self.assertEqual(self.provenance.read_text(), before)
        self.assertTrue((self.cache / "ambientcg" / self.item / "files" / "Concrete034.usda").is_file(), "the verified cache stays")
        self.assertEqual([p.name for p in (self.cache / "ambientcg").iterdir()], [self.item], "no temp folders left")

    def test_changed_licence_text_is_refused_before_the_download(self):
        (self.licence / "legalcode.txt").write_bytes(LICENCE_TEXT + b"amended\n")
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin", "--purpose", "fixture")
        self.assertEqual(code, 1)
        self.assertIn("legal code text changed", text)
        self.assertEqual(self.files(), [])
        self.assertFalse((self.cache / "ambientcg" / self.item).exists())

    def test_non_cc0_source_is_refused(self):
        self.sources_doc["sources"][0]["licence"] = "CC-BY-4.0"
        self.save_sources()
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin", "--purpose", "fixture")
        self.assertNotEqual(code, 0)
        self.assertIn("not allowed; only ['CC0-1.0']", text)
        source = copy.deepcopy(self.sources_doc["sources"][0])
        with self.assertRaises(fetch_assets.Refused):
            fetch_assets.plan(type("A", (), {"source": "ambientcg", "item": self.item, "pin": True, "from_file": None})(),
                              {"sources": [source]}, {"files": []})

    def test_unsafe_archives_are_refused(self):
        for name, members in (
            ("slip", {"../outside.png": PNG}),
            ("absolute", {"/abs.png": PNG}),
            ("drive", {"C:/win.png": PNG}),
        ):
            with self.subTest(name):
                item = f"Unsafe{len(name):03d}_1K-PNG"
                make_zip(self.site / f"get?file={item}.zip", members)
                code, text = self.run_tool("--source", "ambientcg", "--item", item, "--pin", "--purpose", "fixture")
                self.assertEqual(code, 1, text)
                self.assertIn("unsafe archive", text)
        link_item = "Linked001_1K-PNG"
        with zipfile.ZipFile(self.site / f"get?file={link_item}.zip", "w") as zf:
            info = zipfile.ZipInfo("link.png")
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            zf.writestr(info, "/etc/passwd")
        code, text = self.run_tool("--source", "ambientcg", "--item", link_item, "--pin", "--purpose", "fixture")
        self.assertEqual(code, 1)
        self.assertIn("symbolic link", text)
        self.assertEqual(self.files(), [])
        self.assertFalse((self.tmp / "outside.png").exists())
        self.assertFalse((self.cache / "outside.png").exists())

    def test_wrong_type_and_size_cap(self):
        (self.site / "get?file=Picture001_1K-PNG.zip").write_bytes(PNG)
        code, text = self.run_tool("--source", "ambientcg", "--item", "Picture001_1K-PNG", "--pin", "--purpose", "fixture")
        self.assertEqual(code, 1)
        self.assertIn("the file is png", text)
        self.sources_doc["sources"][0]["max_bytes"] = 10
        self.save_sources()
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin", "--purpose", "fixture")
        self.assertEqual(code, 1)
        self.assertIn("larger than the cap", text)

    def test_manual_source_needs_from_file(self):
        code, text = self.run_tool("--source", "kenney", "--item", "interface-sounds", "--pin", "--purpose", "audio fixture")
        self.assertEqual(code, 2)
        self.assertIn("--from-file", text)
        pack = make_zip(self.tmp / "downloaded.zip", {"Audio/click_001.ogg": b"OggS" + b"\x00" * 20, "License.txt": b"CC0", "preview.exe": b"MZ"})
        code, text = self.run_tool("--source", "kenney", "--item", "interface-sounds", "--from-file", str(pack), "--pin", "--purpose", "audio fixture")
        self.assertEqual(code, 0, text)
        entry = self.files()[0]
        self.assertEqual(entry["url"], "manual:https://kenney.nl/assets")
        self.assertNotIn("downloaded.zip", self.provenance.read_text(), "the owner's local path is never recorded")
        manifest = json.loads((self.cache / "kenney" / "interface-sounds" / "cache-manifest.json").read_text())
        self.assertEqual(manifest["skipped"], ["preview.exe"])
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--from-file", str(pack), "--pin", "--purpose", "x")
        self.assertEqual(code, 2)

    def test_bad_items_purpose_and_test_roots(self):
        for item in ("../escape_1K-PNG", "Concrete034_9K-PNG", "Concrete034_1K-PNG/../x"):
            self.assertEqual(self.run_tool("--source", "ambientcg", "--item", item)[0], 2, item)
        self.assertEqual(self.run_tool("--source", "nowhere", "--item", "x")[0], 2)
        code, text = self.run_tool("--source", "ambientcg", "--item", self.item, "--pin")
        self.assertEqual(code, 2)
        self.assertIn("--purpose is required", text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = fetch_assets.main(["--source", "ambientcg", "--item", self.item, "--url-root", self.site.as_uri()])
        self.assertEqual(code, 2, "test roots need --allow-file-urls")

    def test_redirects_only_to_allowed_hosts(self):
        handler = fetch_assets.HostRedirects({"ambientcg.com"})
        with self.assertRaises(fetch_assets.Failed):
            handler.redirect_request(None, None, 302, "Found", {}, "https://elsewhere.example/file.zip")
        with self.assertRaises(fetch_assets.Failed):
            handler.redirect_request(None, None, 302, "Found", {}, "http://ambientcg.com/file.zip")
        with self.assertRaises(fetch_assets.Refused):
            fetch_assets.download("https://api.polyhaven.com/files/x", self.tmp / "x", 10, {"dl.polyhaven.org"})

    def test_list(self):
        code, text = self.run_tool("--list")
        self.assertEqual(code, 0)
        self.assertIn("ambientcg", text)
        self.assertIn("pinned: none", text)


class AssetSourcesTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads((ROOT / "assets" / "sources.json").read_text())

    def test_repository_files_are_valid(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = asset_sources.main(["--check", str(ROOT / "assets/sources.json"), str(ROOT / "assets/provenance.json")])
        self.assertEqual(code, 0, out.getvalue())
        self.assertLessEqual(len(self.doc["sources"]), 12)
        self.assertTrue(all(s["licence"] == "CC0-1.0" for s in self.doc["sources"]))

    def test_sources_problems_name_each_break(self):
        bad = copy.deepcopy(self.doc)
        first = bad["sources"][0]
        first.update({"licence": "CC-BY-4.0", "commit": "commit-ok", "attribution": "required", "allowed_types": ["exe"], "max_bytes": 0})
        first["retrieval"].update({"host": "evil.example", "path": "/no-item", "item_pattern": "unanchored"})
        bad["sources"][1]["notes"] = "see https://api.polyhaven.com/files/x"
        bad["sources"][2]["licence_text_sha256"] = "0" * 64
        bad["sources"][3]["retrieval"] = {"method": "torrent", "item_pattern": "^x$"}
        bad["sources"] += [dict(self.doc["sources"][0], key=f"extra-{i}") for i in range(9)]
        problems = "\n".join(asset_sources.sources_problems(bad))
        for needle in (
            "api.polyhaven.com must never appear",
            "licence 'CC-BY-4.0' is not allowed",
            "commit must be fetch-only",
            "attribution must be none",
            "allowed_types must be",
            "max_bytes must be",
            "retrieval.host must be one of",
            "retrieval.path must start with / and hold {item} once",
            "item_pattern must be an anchored",
            "licence_text_sha256 must equal",
            "retrieval.method must be https-get or manual",
            "at most 12 candidates",
        ):
            self.assertIn(needle, problems)
        self.assertEqual(asset_sources.sources_problems({"schema": "x"}), ["sources: schema must be asset-sources/1"])

    def test_provenance_links(self):
        sha = self.doc["sources"][0]["licence_text_sha256"]
        good = {"source_key": "ambientcg", "item": "Concrete034_1K-PNG", "url": "https://ambientcg.com/get?file=Concrete034_1K-PNG.zip",
                "sha256": "a" * 64, "bytes": 10, "type": "zip", "licence": "CC0-1.0", "licence_url": "https://docs.ambientcg.com/license/",
                "licence_text_sha256": sha, "date": "2026-10-06", "purpose": "fixture", "approval": "pinned"}
        self.assertEqual(asset_sources.provenance_problems({"files": [good], "assets": []}, self.doc), [])
        broken = dict(good, item="../x", sha256="nope", type="exe", licence="CC-BY-4.0", date="today", approval="approved", url="http://x")
        unknown = dict(good, source_key="sketchfab")
        doc = {"files": [good, good, broken, unknown], "assets": [{"id": 1, "source_key": "nowhere"}]}
        problems = "\n".join(asset_sources.provenance_problems(doc, self.doc))
        for needle in ("pinned twice", "must not contain '..'", "sha256 must be", "type 'exe'", "licence must be CC0-1.0", "date must be",
                       "approval must be pinned", "url must be", "'sketchfab' is not in", "source_key 'nowhere' is not in"):
            self.assertIn(needle, problems)

    def test_committed_binaries_under_assets_are_flagged(self):
        tmp = Path(tempfile.mkdtemp(prefix="assets-dir-"))
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "assets").mkdir()
        (tmp / "assets" / "sources.json").write_text("{}")
        (tmp / "assets" / "texture.png").write_bytes(PNG)
        problems = asset_sources.committed_file_problems(tmp / "assets")
        self.assertEqual(len(problems), 1)
        self.assertIn("assets/texture.png", problems[0])


if __name__ == "__main__":
    unittest.main()
