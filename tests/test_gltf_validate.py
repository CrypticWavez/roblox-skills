"""Unit tests for tools/gltf_validate.py with handcrafted GLBs (no bpy, no network).

  python3 -m unittest tests/test_gltf_validate.py
"""
import contextlib
import io
import json
import struct
import sys
import tempfile
import unittest
import zlib
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import gltf_validate as gv  # noqa: E402


def png_bytes(width, height):
    """A valid grey RGB PNG of the given size."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x80" * (3 * width) for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


class Builder:
    """Accumulates a BIN payload, buffer views and accessors for a glTF document."""

    def __init__(self):
        self.bin = bytearray()
        self.doc = {"asset": {"version": "2.0", "generator": "test"}, "buffers": [{}], "bufferViews": [], "accessors": [], "scene": 0, "scenes": [{"nodes": []}], "nodes": [], "meshes": []}

    def view(self, data, target=None):
        self.bin += b"\x00" * (-len(self.bin) % 4)
        view = {"buffer": 0, "byteOffset": len(self.bin), "byteLength": len(data)}
        if target:
            view["target"] = target
        self.bin += data
        self.doc["bufferViews"].append(view)
        return len(self.doc["bufferViews"]) - 1

    def accessor(self, values, kind, component=5126, bounds=True, target=None):
        fmt = gv.COMPONENTS[component][0]
        n = gv.TYPES[kind]
        flat = [c for v in values for c in (v if isinstance(v, (list, tuple)) else (v,))]
        acc = {"bufferView": self.view(struct.pack("<" + fmt * len(flat), *flat), target), "componentType": component, "count": len(values), "type": kind}
        if bounds:
            rows = [v if isinstance(v, (list, tuple)) else (v,) for v in values]
            acc["min"] = [min(r[c] for r in rows) for c in range(n)]
            acc["max"] = [max(r[c] for r in rows) for c in range(n)]
        self.doc["accessors"].append(acc)
        return len(self.doc["accessors"]) - 1

    def triangle(self, with_indices=True):
        pos = self.accessor([(0, 0, 0), (1, 0, 0), (0, 1, 0)], "VEC3", target=34962)
        uv = self.accessor([(0, 0), (1, 0), (0, 1)], "VEC2", bounds=False, target=34962)
        prim = {"attributes": {"POSITION": pos, "TEXCOORD_0": uv}}
        if with_indices:
            prim["indices"] = self.accessor([0, 1, 2], "SCALAR", component=5123, bounds=False, target=34963)
        self.doc["meshes"].append({"primitives": [prim]})
        self.doc["nodes"].append({"mesh": len(self.doc["meshes"]) - 1})
        self.doc["scenes"][0]["nodes"].append(len(self.doc["nodes"]) - 1)
        return prim

    def texture(self, image, mime="image/png"):
        self.doc.setdefault("images", []).append({"bufferView": self.view(image), "mimeType": mime})
        self.doc.setdefault("textures", []).append({"source": len(self.doc["images"]) - 1})
        self.doc.setdefault("materials", []).append({"pbrMetallicRoughness": {"baseColorTexture": {"index": len(self.doc["textures"]) - 1}}})
        return len(self.doc["materials"]) - 1

    def glb(self):
        return gv.pack_glb(self.doc, bytes(self.bin))


def codes(result, level="errors"):
    return {item["code"] for item in result[level]}


class ContainerTests(unittest.TestCase):
    def test_good_textured_triangle_passes(self):
        b = Builder()
        prim = b.triangle()
        prim["material"] = b.texture(png_bytes(4, 4))
        result = gv.validate_bytes(b.glb())
        self.assertTrue(result["pass"], result["errors"])
        self.assertEqual(result["warnings"], [])
        self.assertEqual(result["info"]["triangles"], 1)
        self.assertEqual(result["info"]["images"][0]["width"], 4)
        self.assertEqual(result["info"]["images"][0]["detected"], "image/png")

    def test_bad_magic(self):
        data = bytearray(Builder().glb())
        data[0:4] = b"gltf"
        self.assertIn("NOT_GLTF", codes(gv.validate_bytes(bytes(data))))
        data[0:4] = b"glTX"
        self.assertFalse(gv.validate_bytes(bytes(data))["pass"])

    def test_wrong_version_and_length(self):
        data = bytearray(Builder().glb())
        data[4:8] = struct.pack("<I", 1)
        self.assertIn("GLB_VERSION", codes(gv.validate_bytes(bytes(data))))
        data = Builder().glb() + b"\x00\x00\x00\x00"
        self.assertIn("GLB_LENGTH", codes(gv.validate_bytes(data)))
        self.assertIn("GLB_LENGTH", codes(gv.validate_bytes(Builder().glb()[:-8])))

    def test_chunk_order_and_alignment(self):
        b = Builder()
        b.triangle()
        good = b.glb()
        json_len = struct.unpack_from("<I", good, 12)[0]
        json_chunk = good[12:20 + json_len]
        bin_chunk = good[20 + json_len:]
        swapped = good[:12] + bin_chunk + json_chunk
        self.assertIn("GLB_JSON_CHUNK", codes(gv.validate_bytes(swapped)))
        doubled = good[:8] + struct.pack("<I", len(good) + len(bin_chunk)) + good[12:] + bin_chunk
        self.assertIn("GLB_CHUNK_ORDER", codes(gv.validate_bytes(doubled)))
        text = json.dumps({"asset": {"version": "2.0"}}).encode()
        text += b" " * (1 if len(text) % 4 == 0 else 0)  # a JSON chunk whose length is not a multiple of 4
        self.assertNotEqual(len(text) % 4, 0)
        body = struct.pack("<II", len(text), gv.CHUNK_JSON) + text
        odd = struct.pack("<III", gv.GLB_MAGIC, 2, 12 + len(body)) + body
        self.assertIn("GLB_CHUNK_ALIGNMENT", codes(gv.validate_bytes(odd)))

    def test_bad_json_and_asset_version(self):
        body = b"{not json"
        body += b" " * (-len(body) % 4)
        data = struct.pack("<III", gv.GLB_MAGIC, 2, 20 + len(body)) + struct.pack("<II", len(body), gv.CHUNK_JSON) + body
        self.assertIn("JSON_PARSE", codes(gv.validate_bytes(data)))
        b = Builder()
        b.triangle()
        b.doc["asset"]["version"] = "1.0"
        self.assertIn("ASSET_VERSION", codes(gv.validate_bytes(b.glb())))

    def test_bin_length_mismatch(self):
        b = Builder()
        b.triangle()
        b.doc["buffers"] = [{"byteLength": len(b.bin) + 64}]
        result = gv.validate_bytes(b.glb())
        self.assertIn("GLB_BIN_LENGTH", codes(result))


class AccessorTests(unittest.TestCase):
    def test_values_outside_declared_bounds(self):
        b = Builder()
        b.triangle()
        b.doc["accessors"][0]["max"] = [0.5, 1, 0]
        self.assertIn("ACCESSOR_OUT_OF_BOUNDS", codes(gv.validate_bytes(b.glb())))

    def test_loose_bounds_warn(self):
        b = Builder()
        b.triangle()
        b.doc["accessors"][0]["max"] = [2, 1, 0]
        result = gv.validate_bytes(b.glb())
        self.assertTrue(result["pass"])
        self.assertIn("ACCESSOR_BOUNDS_LOOSE", codes(result, "warnings"))

    def test_accessor_past_view_and_view_past_buffer(self):
        b = Builder()
        b.triangle()
        b.doc["accessors"][0]["count"] = 30
        self.assertIn("ACCESSOR_OUT_OF_VIEW", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        b.triangle()
        b.doc["bufferViews"][0]["byteLength"] = 4096
        self.assertIn("VIEW_OUT_OF_BUFFER", codes(gv.validate_bytes(b.glb())))

    def test_misaligned_and_bad_stride(self):
        b = Builder()
        b.triangle()
        b.doc["accessors"][0]["byteOffset"] = 2
        self.assertIn("ACCESSOR_ALIGNMENT", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        b.triangle()
        b.doc["bufferViews"][0]["byteStride"] = 6
        self.assertIn("VIEW_STRIDE", codes(gv.validate_bytes(b.glb())))

    def test_position_needs_bounds_and_indices_in_range(self):
        b = Builder()
        b.triangle()
        del b.doc["accessors"][0]["min"]
        self.assertIn("POSITION_BOUNDS", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        prim = b.triangle(with_indices=False)
        prim["indices"] = b.accessor([0, 1, 7], "SCALAR", component=5123, bounds=False)
        self.assertIn("INDEX_OVER_VERTEX_COUNT", codes(gv.validate_bytes(b.glb())))

    def test_bad_indices(self):
        b = Builder()
        b.triangle()
        b.doc["meshes"][0]["primitives"][0]["attributes"]["NORMAL"] = 99
        self.assertIn("INDEX_OUT_OF_RANGE", codes(gv.validate_bytes(b.glb())))


class SkinAndAnimationTests(unittest.TestCase):
    def skinned(self, joints_values=None, ibm_count=2, extra_influences=False):
        b = Builder()
        prim = b.triangle()
        joints = joints_values or [(0, 1, 0, 0)] * 3
        prim["attributes"]["JOINTS_0"] = b.accessor(joints, "VEC4", component=5121, bounds=False)
        prim["attributes"]["WEIGHTS_0"] = b.accessor([(0.5, 0.5, 0, 0)] * 3, "VEC4", bounds=False)
        if extra_influences:
            prim["attributes"]["JOINTS_1"] = b.accessor([(0, 0, 0, 0)] * 3, "VEC4", component=5121, bounds=False)
            prim["attributes"]["WEIGHTS_1"] = b.accessor([(0, 0, 0, 0)] * 3, "VEC4", bounds=False)
        identity = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
        ibm = b.accessor([identity] * ibm_count, "MAT4", bounds=False)
        b.doc["nodes"] += [{"name": "Root", "children": [2]}, {"name": "Body"}]
        b.doc["scenes"][0]["nodes"].append(1)
        b.doc["nodes"][0]["skin"] = 0
        b.doc["skins"] = [{"joints": [1, 2], "inverseBindMatrices": ibm}]
        return b

    def test_good_skin(self):
        result = gv.validate_bytes(self.skinned().glb())
        self.assertTrue(result["pass"], result["errors"])
        self.assertEqual(result["info"]["skins"], [{"skin": 0, "joints": 2}])

    def test_skin_counts(self):
        self.assertIn("SKIN_IBM_COUNT", codes(gv.validate_bytes(self.skinned(ibm_count=3).glb())))
        self.assertIn("JOINT_INDEX_OVER_COUNT", codes(gv.validate_bytes(self.skinned(joints_values=[(0, 5, 0, 0)] * 3).glb())))
        self.assertIn("INFLUENCES_OVER_4", codes(gv.validate_bytes(self.skinned(extra_influences=True).glb())))

    def animated(self, times=(0.0, 0.5, 1.0), outputs=3, path="rotation"):
        b = Builder()
        b.triangle()
        inp = b.accessor(list(times), "SCALAR")
        kind = "VEC4" if path == "rotation" else "VEC3"
        out = b.accessor([(0, 0, 0, 1) if kind == "VEC4" else (0, 0, 0)] * outputs, kind, bounds=False)
        b.doc["animations"] = [{"name": "idle", "samplers": [{"input": inp, "output": out}], "channels": [{"sampler": 0, "target": {"node": 0, "path": path}}]}]
        return b

    def test_good_animation(self):
        result = gv.validate_bytes(self.animated().glb())
        self.assertTrue(result["pass"], result["errors"])
        self.assertEqual(result["info"]["animations"], [{"name": "idle", "channels": 1, "samplers": 1, "duration": 1.0}])

    def test_bad_animation(self):
        self.assertIn("SAMPLER_TIMES_ORDER", codes(gv.validate_bytes(self.animated(times=(0.0, 1.0, 0.5)).glb())))
        self.assertIn("SAMPLER_OUTPUT_COUNT", codes(gv.validate_bytes(self.animated(outputs=2).glb())))
        b = self.animated()
        b.doc["animations"][0]["channels"].append({"sampler": 0, "target": {"node": 0, "path": "rotation"}})
        self.assertIn("CHANNEL_DUPLICATE", codes(gv.validate_bytes(b.glb())))
        b = self.animated()
        b.doc["animations"][0]["channels"][0]["sampler"] = 4
        self.assertIn("CHANNEL_SAMPLER", codes(gv.validate_bytes(b.glb())))
        b = self.animated()
        b.doc["animations"][0]["channels"][0]["target"]["path"] = "translation"
        self.assertIn("SAMPLER_OUTPUT_TYPE", codes(gv.validate_bytes(b.glb())))


class TextureAndNodeTests(unittest.TestCase):
    def test_texture_formats(self):
        b = Builder()
        prim = b.triangle()
        prim["material"] = b.texture(png_bytes(2, 2), mime="image/jpeg")
        self.assertIn("IMAGE_MIME_MISMATCH", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        prim = b.triangle()
        prim["material"] = b.texture(b"RIFF\x00\x00\x00\x00WEBPVP8 ", mime="image/webp")
        self.assertIn("IMAGE_FORMAT", codes(gv.validate_bytes(b.glb())))

    def test_texture_size_warnings(self):
        header = png_bytes(1, 1)
        big = header[:16] + struct.pack(">II", 2048, 2048) + header[24:]  # IHDR size only (CRC not checked)
        b = Builder()
        prim = b.triangle()
        prim["material"] = b.texture(big)
        result = gv.validate_bytes(b.glb())
        self.assertTrue(result["pass"])
        self.assertIn("IMAGE_SIZE", codes(result, "warnings"))
        b = Builder()
        prim = b.triangle()
        prim["material"] = b.texture(png_bytes(3, 2))
        self.assertIn("IMAGE_NOT_POW2", codes(gv.validate_bytes(b.glb()), "warnings"))

    def test_second_uv_set_warns(self):
        b = Builder()
        prim = b.triangle()
        prim["attributes"]["TEXCOORD_1"] = prim["attributes"]["TEXCOORD_0"]
        self.assertIn("SECOND_UV_SET", codes(gv.validate_bytes(b.glb()), "warnings"))

    def test_node_hierarchy(self):
        b = Builder()
        b.triangle()
        b.doc["nodes"] += [{"children": [2]}, {"children": [1]}]
        self.assertIn("NODE_CYCLE", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        b.triangle()
        b.doc["nodes"] += [{"children": [0]}, {"children": [0]}]
        self.assertIn("NODE_MULTIPLE_PARENTS", codes(gv.validate_bytes(b.glb())))
        b = Builder()
        b.triangle()
        b.doc["nodes"][0].update(matrix=[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], translation=[0, 1, 0])
        self.assertIn("NODE_MATRIX_AND_TRS", codes(gv.validate_bytes(b.glb())))


class CliTests(unittest.TestCase):
    def test_cli_exit_codes_and_report(self):
        b = Builder()
        b.triangle()
        with tempfile.TemporaryDirectory() as tmp:
            good, bad, report = Path(tmp) / "good.glb", Path(tmp) / "bad.glb", Path(tmp) / "report.json"
            good.write_bytes(b.glb())
            bad.write_bytes(b.glb()[:-4])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gv.main([str(good), "--json", str(report)]), 0)
                self.assertEqual(gv.main([str(good), str(bad)]), 1)
            data = json.loads(report.read_text())
            self.assertEqual(data["schema"], "gltf-validate/1")
            self.assertTrue(data["pass"])
            self.assertFalse(data["files"][0]["gltf_transform"]["ran"])  # opt-in only
            self.assertIn("FILE_MISSING", codes(gv.validate_file(Path(tmp) / "absent.glb")))

    def test_gltf_transform_launches_the_resolved_npx(self):
        # On Windows shutil.which finds npx.cmd, and only that full path can be started.
        resolved = str(Path("node") / "npx.cmd")
        done = mock.Mock(returncode=0, stdout="ok", stderr="")
        with mock.patch.object(gv.shutil, "which", return_value=resolved), mock.patch.object(gv.subprocess, "run", return_value=done) as run:
            result = gv.gltf_transform(Path("a.glb"), opted_in=True)
        self.assertTrue(result["ran"])
        argv = run.call_args.args[0]
        self.assertEqual(argv[0], resolved)
        self.assertEqual(argv[1:], gv.GLTF_TRANSFORM[1:] + ["a.glb"])
        with mock.patch.object(gv.shutil, "which", return_value=None):
            self.assertEqual(gv.gltf_transform(Path("a.glb"), opted_in=True)["reason"], "npx not on PATH")

    def test_gltf_json_with_external_buffer(self):
        b = Builder()
        b.triangle()
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "mesh.bin").write_bytes(bytes(b.bin))
            doc = dict(b.doc, buffers=[{"byteLength": len(b.bin), "uri": "mesh.bin"}])
            (Path(tmp) / "mesh.gltf").write_text(json.dumps(doc))
            self.assertTrue(gv.validate_file(Path(tmp) / "mesh.gltf")["pass"])
            doc["buffers"][0]["uri"] = "missing.bin"
            (Path(tmp) / "mesh.gltf").write_text(json.dumps(doc))
            self.assertIn("BUFFER_MISSING", codes(gv.validate_file(Path(tmp) / "mesh.gltf")))


if __name__ == "__main__":
    unittest.main()
