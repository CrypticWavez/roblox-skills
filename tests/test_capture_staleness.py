"""tools/capture_staleness.py: capture manifests and Studio smoke records against the current goldens."""
import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import capture_staleness  # noqa: E402


def manifest(scene="dungeon", source="fixture", digest="06ace82c", shots=None):
    shots = shots if shots is not None else [
        {"id": f"{scene}.inspection-flat.{angle}", "angle": angle, "profile": "inspection-flat",
         "file": f"{scene}.inspection-flat.{angle}.png", "eye": {"x": 0, "y": 1, "z": -9}, "focus": {"x": 0, "y": 1, "z": 0}, "fov": 70}
        for angle in ("front", "top")
    ]
    return {"schema": "capture-manifest/1", "scene": {"name": scene, "hash": digest, "source": source}, "shots": shots}


class CaptureStalenessTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="capture-staleness-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "packages/SceneKit").mkdir(parents=True)
        shutil.copy(ROOT / "packages/SceneKit/Camera.luau", self.tmp / "packages/SceneKit/Camera.luau")
        golden = self.tmp / "tests/golden"
        golden.mkdir(parents=True)
        (golden / "fixture-hashes.json").write_text(json.dumps({"dungeon": "06ace82c", "cave": "a9fa3357"}))
        (golden / "studio-smoke.json").write_text(json.dumps({
            "building": {"hash": "778d1d9a", "parts": 96, "pass": True},
            "dungeon": {"hash": "927f2db4", "parts": 108, "pass": True},
        }))

    def write(self, rel, value, raw=False):
        path = self.tmp / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if raw else json.dumps(value))
        return path

    def run_tool(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = capture_staleness.main([*args, "--root", str(self.tmp)])
        return code, out.getvalue()

    def statuses(self, *args):
        code, text = self.run_tool("--json", *args)
        doc = json.loads(text)
        return code, {(i["path"], i.get("scene")): i for i in doc["items"]}, doc["counts"]

    def test_angles_come_from_scenekit_camera(self):
        self.assertEqual(capture_staleness.camera_angles(ROOT), ["front", "side", "three-quarter", "top"])

    def test_current_capture_with_all_images(self):
        path = self.write("reports/captures/dungeon/manifest.json", manifest())
        for name in ("dungeon.inspection-flat.front.png", "dungeon.inspection-flat.top.png"):
            (path.parent / name).write_bytes(b"png")
        code, items, counts = self.statuses()
        self.assertEqual(code, 0)
        self.assertEqual(counts, {"CURRENT": 1})
        item = items[("reports/captures/dungeon/manifest.json", "dungeon")]
        self.assertEqual((item["recorded"], item["current"], item["shots"]), ("06ace82c", "06ace82c", 2))

    def test_changed_fixture_hash_is_stale(self):
        self.write("reports/captures/dungeon/manifest.json", manifest(digest="deadbeef"))
        code, items, counts = self.statuses()
        self.assertEqual(code, 0, "stale is reported, not fatal, by default")
        self.assertEqual(counts, {"STALE": 1})
        self.assertEqual(self.run_tool("--fail-stale")[0], 1)
        code, text = self.run_tool()
        self.assertIn("STALE reports/captures/dungeon/manifest.json dungeon: recorded deadbeef, current 06ace82c", text)

    def test_missing_images_are_incomplete(self):
        path = self.write("reports/captures/cave/manifest.json", manifest(scene="cave", digest="a9fa3357"))
        (path.parent / "cave.inspection-flat.front.png").write_bytes(b"png")
        code, items, counts = self.statuses()
        self.assertEqual(counts, {"INCOMPLETE": 1})
        self.assertEqual(items[("reports/captures/cave/manifest.json", "cave")]["missing"], ["cave.inspection-flat.top.png"])
        self.assertEqual(self.run_tool("--fail-stale")[0], 1)

    def test_studio_smoke_source_and_records(self):
        self.write("reports/captures/smoke/manifest.json", manifest(scene="dungeon", source="studio-smoke", digest="927f2db4"))
        self.write("reports/studio/smoke-2026-10-05.json", {"result": {"building": {"hash": "778d1d9a"}, "dungeon": {"hash": "8494d161"}}})
        code, items, counts = self.statuses()
        self.assertEqual(code, 0)
        self.assertEqual(items[("reports/studio/smoke-2026-10-05.json", "dungeon")]["status"], "STALE")
        self.assertEqual(items[("reports/studio/smoke-2026-10-05.json", "building")]["status"], "CURRENT")
        self.assertEqual(items[("reports/captures/smoke/manifest.json", "dungeon")]["status"], "INCOMPLETE")

    def test_malformed_and_unknown_records_fail(self):
        bad = manifest()
        bad["shots"][0]["angle"] = "low"
        bad["shots"][1]["file"] = "../escape.png"
        self.write("reports/a/manifest.json", bad)
        self.write("reports/b/manifest.json", manifest(scene="castle"))
        self.write("reports/studio/smoke-broken.json", {"result": {"dungeon": {"hash": "XYZ"}}})
        self.write("reports/c/manifest.json", "{not json", raw=True)
        self.write("reports/unrelated.json", {"schema": "something-else/1"})
        code, items, counts = self.statuses()
        self.assertEqual(code, 1)
        self.assertEqual(counts, {"INVALID": 4})
        problems = items[("reports/a/manifest.json", None)]["problems"]
        self.assertTrue(any("unknown angle" in p for p in problems), problems)
        self.assertTrue(any("plain .png name" in p for p in problems), problems)
        self.assertEqual(items[("reports/b/manifest.json", "castle")]["problems"], ["castle is not in tests/golden/fixture-hashes.json"])
        self.assertEqual(items[("reports/c/manifest.json", None)]["problems"], ["unreadable JSON: JSONDecodeError"])

    def test_explicit_paths_and_missing_path(self):
        path = self.write("elsewhere/manifest.json", manifest(digest="06ace82c"))
        code, items, _ = self.statuses(str(path))
        self.assertEqual(list(items), [("elsewhere/manifest.json", "dungeon")])
        self.assertEqual(self.run_tool("no/such/dir")[0], 1)

    def test_repository_reports_parse(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = capture_staleness.main([])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
