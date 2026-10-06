"""Pure-Python GLB fixtures for the offline intake test (no bpy, no network): a model shaped like
a typical third-party download. It sits off the origin under a rotated, scaled parent node, is
Y-up in metres, has no UVs and carries its colours as two glTF `baseColorFactor` materials (the
form Studio's importer drops, B06). `textured=True` gives the body a 4x4 checker
`baseColorTexture` with UVs instead, for the bake_maps route. Bytes are deterministic."""
import math
import struct
import sys
from pathlib import Path

from . import png

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools/, for gltf_validate.pack_glb
import gltf_validate  # noqa: E402

BODY_SRGB = (0.20, 0.45, 0.85)  # what the intake's palette must reproduce (sRGB 0..1)
CAP_SRGB = (0.95, 0.55, 0.10)
CHECKER = ((230, 230, 230), (40, 40, 40))
PARENT = {"translation": [4.0, 0.5, -3.0], "rotation_y_deg": 30.0, "scale": 0.5}
RAW_HEIGHT = 2.4 * 0.5  # metres: body 2 + cap 0.4, scaled by the parent


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _box(center, size, uvs=False):
    """24-vertex box (flat normals) in glTF axes: positions, normals, uvs, indices."""
    cx, cy, cz = center
    hx, hy, hz = (s / 2 for s in size)
    faces = [
        ((1, 0, 0), [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)]),
        ((-1, 0, 0), [(-1, -1, 1), (-1, 1, 1), (-1, 1, -1), (-1, -1, -1)]),
        ((0, 1, 0), [(-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)]),
        ((0, -1, 0), [(-1, -1, 1), (-1, -1, -1), (1, -1, -1), (1, -1, 1)]),
        ((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
        ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
    ]
    pos, nor, uv, idx = [], [], [], []
    for normal, corners in faces:
        base = len(pos)
        for i, (sx, sy, sz) in enumerate(corners):
            pos.append((cx + sx * hx, cy + sy * hy, cz + sz * hz))
            nor.append(normal)
            uv.append(((0, 0), (1, 0), (1, 1), (0, 1))[i])
        idx += [base, base + 1, base + 2, base, base + 2, base + 3]
    return pos, nor, (uv if uvs else None), idx


class _Bin:
    def __init__(self):
        self.data = bytearray()
        self.views, self.accessors = [], []

    def view(self, raw, target=None):
        self.data += b"\x00" * (-len(self.data) % 4)
        view = {"buffer": 0, "byteOffset": len(self.data), "byteLength": len(raw)}
        if target:
            view["target"] = target
        self.views.append(view)
        self.data += raw
        return len(self.views) - 1

    def accessor(self, rows, kind, component=5126, bounds=False, target=34962):
        fmt = {5126: "f", 5123: "H"}[component]
        flat = [c for r in rows for c in (r if isinstance(r, tuple) else (r,))]
        acc = {"bufferView": self.view(struct.pack("<" + fmt * len(flat), *flat), target), "componentType": component, "count": len(rows), "type": kind}
        if bounds:
            n = len(rows[0])
            acc["min"] = [min(r[i] for r in rows) for i in range(n)]
            acc["max"] = [max(r[i] for r in rows) for i in range(n)]
        self.accessors.append(acc)
        return len(self.accessors) - 1


def checker_png():
    rows = []
    for y in range(4):
        rows.append([c for x in range(4) for c in CHECKER[(x + y) % 2]])
    return png.encode(4, 4, rows, "RGB")


def intake_fixture(path, textured=False):
    """Write the fixture GLB to `path`; returns facts the intake test checks against."""
    b = _Bin()
    meshes, materials = [], []
    parts = (("Body", (0, 1, 0), (2, 2, 2), BODY_SRGB, textured), ("Cap", (0, 2.2, 0), (2.4, 0.4, 2.4), CAP_SRGB, False))
    doc_extra = {}
    for name, center, size, srgb, with_tex in parts:
        pos, nor, uv, idx = _box(center, size, uvs=with_tex)
        attrs = {"POSITION": b.accessor(pos, "VEC3", bounds=True), "NORMAL": b.accessor(nor, "VEC3")}
        if uv:
            attrs["TEXCOORD_0"] = b.accessor(uv, "VEC2")
        prim = {"attributes": attrs, "indices": b.accessor(idx, "SCALAR", component=5123, target=34963), "material": len(materials)}
        meshes.append({"name": name, "primitives": [prim]})
        pbr = {"baseColorFactor": [*(_srgb_to_linear(c) for c in srgb), 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.8}
        if with_tex:
            doc_extra = {"images": [{"bufferView": b.view(checker_png()), "mimeType": "image/png", "name": "fixture_checker"}],
                         "textures": [{"source": 0, "sampler": 0}],
                         "samplers": [{"magFilter": 9728, "minFilter": 9728}]}
            pbr = {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.8}
        materials.append({"name": f"{name}Paint", "pbrMetallicRoughness": pbr})
    half = math.radians(PARENT["rotation_y_deg"]) / 2
    s = PARENT["scale"]
    doc = {
        "asset": {"version": "2.0", "generator": "bkit glbfix (intake fixture)"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [
            {"name": "DownloadRoot", "translation": PARENT["translation"], "rotation": [0.0, math.sin(half), 0.0, math.cos(half)], "scale": [s, s, s], "children": [1, 2]},
            {"name": "Body", "mesh": 0},
            {"name": "Cap", "mesh": 1, "translation": [0.0, 0.0, 0.0]},
        ],
        "meshes": meshes,
        "materials": materials,
        "buffers": [{"byteLength": len(b.data)}],
        "bufferViews": b.views,
        "accessors": b.accessors,
        **doc_extra,
    }
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(gltf_validate.pack_glb(doc, bytes(b.data)))
    return {"file": str(path), "raw_height": RAW_HEIGHT, "body_srgb": [round(c * 255) for c in BODY_SRGB], "cap_srgb": [round(c * 255) for c in CAP_SRGB],
            "textured": textured, "triangles": 24, "materials": 2}
