"""Structural glTF 2.0 / GLB validator in pure Python (no network, no npm, no bpy).

  python3 tools/gltf_validate.py <file.glb|file.gltf>... [--json <report.json>] [--gltf-transform]

Checks what breaks or silently degrades a Roblox import before Studio sees the file:
- GLB container: magic, version 2, declared length, chunk order (JSON then optional BIN),
  4-byte chunk alignment, JSON parses, `asset.version` is 2.0;
- buffers and buffer views: GLB buffer 0 is the BIN chunk, every view inside its buffer, stride
  4..252 and a multiple of 4; external URIs in a .glb are flagged (the file is not self-contained);
- accessors: component and element types, alignment, every element inside its buffer view,
  POSITION has min/max, and the decoded values lie inside the declared min/max (accessor bounds);
- meshes: attribute types, one vertex count per primitive, index values below it, at most four
  influences (JOINTS_1/WEIGHTS_1 is an error), weights summing to 1, a second UV set (TEXCOORD_1)
  as a warning (Roblox reads one), over 20,000 triangles per mesh as a warning (R10);
- nodes and scenes: index ranges, one parent per node, no cycles, matrix xor TRS;
- skins: joints are nodes, inverseBindMatrices is MAT4 FLOAT with one matrix per joint, JOINTS_0
  values below the joint count; joint counts are reported;
- animations: sampler input is SCALAR FLOAT with min/max and strictly increasing times, output
  count matches (x3 for CUBICSPLINE), output type matches the target path, one channel per node
  and path;
- textures and images: PNG or JPEG only (signature checked against the declared mimeType), size
  read from the header, over 1024 px or non power of two as warnings (SurfaceAppearance limit),
  texCoord > 0 as a warning.

Exit code 0 when no file has errors. `--gltf-transform` (or FACTORY_GLTF_TRANSFORM=1) also runs
`npx @gltf-transform/cli@4.5.1 inspect` when npx is on PATH: opt-in only, never part of a gate,
because npx may download the package. Without opt-in or npx it is reported as not run.
`pack_glb(document, bin)` builds a GLB from a dict and bytes (tests and fixtures use it)."""
import argparse
import base64
import json
import math
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

GLB_MAGIC = 0x46546C67  # "glTF"
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942
COMPONENTS = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
TYPES = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}
MODES = {0: "POINTS", 1: "LINES", 2: "LINE_LOOP", 3: "LINE_STRIP", 4: "TRIANGLES", 5: "TRIANGLE_STRIP", 6: "TRIANGLE_FAN"}
PATH_TYPES = {"translation": ("VEC3",), "scale": ("VEC3",), "rotation": ("VEC4",), "weights": ("SCALAR",)}
MAX_TEXTURE = 1024  # SurfaceAppearance/MaterialVariant map maximum
MAX_TRIANGLES = 20000  # per mesh (create.roblox.com art/modeling/specifications, R10)
GLTF_TRANSFORM = ["npx", "--yes", "@gltf-transform/cli@4.5.1", "inspect"]
OPT_IN_ENV = "FACTORY_GLTF_TRANSFORM"


def pack_glb(document, binary=None):
    """GLB bytes from a glTF dict and an optional BIN payload (JSON padded with spaces, BIN with
    zeros, both to 4 bytes). Sets buffers[0].byteLength to the payload length when it is absent."""
    doc = dict(document)
    if binary is not None and doc.get("buffers") and "byteLength" not in doc["buffers"][0]:
        doc["buffers"] = [{**doc["buffers"][0], "byteLength": len(binary)}] + list(doc["buffers"][1:])
    text = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    text += b" " * (-len(text) % 4)
    chunks = struct.pack("<II", len(text), CHUNK_JSON) + text
    if binary is not None:
        data = bytes(binary) + b"\x00" * (-len(binary) % 4)
        chunks += struct.pack("<II", len(data), CHUNK_BIN) + data
    return struct.pack("<III", GLB_MAGIC, 2, 12 + len(chunks)) + chunks


class Report:
    def __init__(self, name):
        self.name = name
        self.errors, self.warnings = [], []
        self.info = {}

    def error(self, code, where, message):
        self.errors.append({"code": code, "path": where, "message": message})

    def warn(self, code, where, message):
        self.warnings.append({"code": code, "path": where, "message": message})

    def as_dict(self):
        return {"file": self.name, "pass": not self.errors, "errors": self.errors, "warnings": self.warnings, "info": self.info}


def _parse_glb(data, rep):
    """(document, bin bytes or None) from GLB bytes; None document when the container is broken."""
    if len(data) < 20:
        rep.error("GLB_TOO_SHORT", "", f"{len(data)} bytes: not a GLB")
        return None, None
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        rep.error("GLB_MAGIC", "", "missing glTF magic: not a binary glTF")
        return None, None
    if version != 2:
        rep.error("GLB_VERSION", "", f"container version {version}, expected 2")
        return None, None
    if length != len(data):
        rep.error("GLB_LENGTH", "", f"header length {length} but the file has {len(data)} bytes (truncated or padded)")
        if length > len(data):
            return None, None
    offset, chunks = 12, []
    while offset < min(length, len(data)):
        if offset + 8 > len(data):
            rep.error("GLB_CHUNK_HEADER", f"chunk[{len(chunks)}]", "chunk header runs past the end of the file")
            return None, None
        size, kind = struct.unpack_from("<II", data, offset)
        if offset + 8 + size > len(data):
            rep.error("GLB_CHUNK_LENGTH", f"chunk[{len(chunks)}]", f"chunk of {size} bytes runs past the end of the file")
            return None, None
        if size % 4:
            rep.error("GLB_CHUNK_ALIGNMENT", f"chunk[{len(chunks)}]", f"chunk length {size} is not a multiple of 4")
        chunks.append((kind, data[offset + 8:offset + 8 + size]))
        offset += 8 + size
    if not chunks or chunks[0][0] != CHUNK_JSON:
        rep.error("GLB_JSON_CHUNK", "chunk[0]", "the first chunk must be JSON")
        return None, None
    binary = None
    for index, (kind, payload) in enumerate(chunks[1:], start=1):
        if kind == CHUNK_BIN and index == 1:
            binary = payload
        elif kind in (CHUNK_JSON, CHUNK_BIN):
            rep.error("GLB_CHUNK_ORDER", f"chunk[{index}]", "only one JSON chunk then at most one BIN chunk")
        else:
            rep.warn("GLB_UNKNOWN_CHUNK", f"chunk[{index}]", f"unknown chunk type 0x{kind:08x} (ignored by readers)")
    try:
        document = json.loads(chunks[0][1].decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        rep.error("JSON_PARSE", "chunk[0]", f"JSON chunk does not parse: {exc}")
        return None, None
    return document, binary


def _index(rep, doc, key, value, where):
    items = doc.get(key) or []
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < len(items):
        rep.error("INDEX_OUT_OF_RANGE", where, f"{value!r} is not an index into {key} ({len(items)})")
        return False
    return True


def _buffers(rep, doc, binary, base_dir, glb):
    """Bytes of every buffer (None when unavailable)."""
    out = []
    for i, buf in enumerate(doc.get("buffers") or []):
        where = f"buffers[{i}]"
        length = buf.get("byteLength")
        if not isinstance(length, int) or length < 1:
            rep.error("BUFFER_LENGTH", where, "byteLength must be an integer >= 1")
            out.append(None)
            continue
        uri = buf.get("uri")
        data = None
        if uri is None:
            if not glb or i != 0:
                rep.error("BUFFER_URI", where, "only GLB buffer 0 may omit uri (it is the BIN chunk)")
            elif binary is None:
                rep.error("GLB_BIN_MISSING", where, "buffer 0 has no uri but the GLB has no BIN chunk")
            else:
                data = binary
                if len(binary) < length or len(binary) > length + 3:
                    rep.error("GLB_BIN_LENGTH", where, f"BIN chunk is {len(binary)} bytes for a {length}-byte buffer (allowed padding 0-3)")
        elif uri.startswith("data:"):
            try:
                data = base64.b64decode(uri.split(",", 1)[1])
            except (IndexError, ValueError):
                rep.error("BUFFER_DATA_URI", where, "data URI does not decode")
            if glb:
                rep.warn("GLB_EMBEDDED_URI", where, "data URI inside a GLB (use the BIN chunk)")
        else:
            if glb:
                rep.warn("GLB_EXTERNAL_BUFFER", where, f"external buffer {uri}: the GLB is not self-contained")
            path = (base_dir / uri) if base_dir else None
            if path is not None and path.is_file():
                data = path.read_bytes()
            else:
                rep.error("BUFFER_MISSING", where, f"external buffer {uri} not found")
        if data is not None and len(data) < length:
            rep.error("BUFFER_SHORT", where, f"{len(data)} bytes for byteLength {length}")
            data = None
        out.append(data)
    return out


def _views(rep, doc):
    ok = []
    for i, view in enumerate(doc.get("bufferViews") or []):
        where = f"bufferViews[{i}]"
        good = _index(rep, doc, "buffers", view.get("buffer"), where + ".buffer")
        offset, length = view.get("byteOffset", 0), view.get("byteLength")
        if not isinstance(length, int) or length < 1 or not isinstance(offset, int) or offset < 0:
            rep.error("VIEW_RANGE", where, "byteLength must be >= 1 and byteOffset >= 0")
            good = False
        elif good and offset + length > doc["buffers"][view["buffer"]].get("byteLength", 0):
            rep.error("VIEW_OUT_OF_BUFFER", where, f"bytes {offset}..{offset + length} past buffer {view['buffer']}'s byteLength")
            good = False
        stride = view.get("byteStride")
        if stride is not None and (not isinstance(stride, int) or not 4 <= stride <= 252 or stride % 4):
            rep.error("VIEW_STRIDE", where, f"byteStride {stride} must be 4..252 and a multiple of 4")
            good = False
        if view.get("target") not in (None, 34962, 34963):
            rep.error("VIEW_TARGET", where, f"target {view.get('target')} is not ARRAY_BUFFER or ELEMENT_ARRAY_BUFFER")
        ok.append(good)
    return ok


def _element_size(acc):
    fmt, size = COMPONENTS[acc["componentType"]]
    kind = acc["type"]
    if kind.startswith("MAT") and size < 4:  # matrix columns start on 4-byte boundaries
        n = int(kind[3])
        return n * (math.ceil(n * size / 4) * 4)
    return TYPES[kind] * size


def _decode(acc, doc, buffers):
    """Element tuples of an accessor, or None when it cannot be read (sparse, no data, padded matrix)."""
    if acc.get("sparse") is not None:
        return None
    count, n = acc["count"], TYPES[acc["type"]]
    fmt, size = COMPONENTS[acc["componentType"]]
    if "bufferView" not in acc:
        return [tuple([0] * n)] * count
    view = doc["bufferViews"][acc["bufferView"]]
    data = buffers[view["buffer"]]
    if data is None or (acc["type"].startswith("MAT") and size < 4):
        return None
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride") or n * size
    unpack = struct.Struct("<" + fmt * n).unpack_from
    return [unpack(data, start + i * stride) for i in range(count)]


def _accessors(rep, doc, buffers, view_ok):
    """Validate accessors; returns {index: decoded elements or None}."""
    values = {}
    for i, acc in enumerate(doc.get("accessors") or []):
        where = f"accessors[{i}]"
        values[i] = None
        if acc.get("componentType") not in COMPONENTS:
            rep.error("ACCESSOR_COMPONENT", where, f"componentType {acc.get('componentType')} is not valid")
            continue
        if acc.get("type") not in TYPES:
            rep.error("ACCESSOR_TYPE", where, f"type {acc.get('type')!r} is not valid")
            continue
        count = acc.get("count")
        if not isinstance(count, int) or count < 1:
            rep.error("ACCESSOR_COUNT", where, "count must be >= 1")
            continue
        n = TYPES[acc["type"]]
        for bound in ("min", "max"):
            if bound in acc and (not isinstance(acc[bound], list) or len(acc[bound]) != n):
                rep.error("ACCESSOR_BOUND_LENGTH", where, f"{bound} must have {n} components")
        if acc.get("sparse") is not None:
            rep.warn("ACCESSOR_SPARSE", where, "sparse accessor: values not checked")
        if "bufferView" in acc:
            if not _index(rep, doc, "bufferViews", acc["bufferView"], where + ".bufferView") or not view_ok[acc["bufferView"]]:
                continue
            view = doc["bufferViews"][acc["bufferView"]]
            size = COMPONENTS[acc["componentType"]][1]
            offset = acc.get("byteOffset", 0)
            elem = _element_size(acc)
            stride = view.get("byteStride") or elem
            if (offset + view.get("byteOffset", 0)) % size:
                rep.error("ACCESSOR_ALIGNMENT", where, f"offset {offset + view.get('byteOffset', 0)} is not a multiple of the {size}-byte component")
                continue
            if stride < elem:
                rep.error("ACCESSOR_STRIDE", where, f"byteStride {stride} is smaller than the {elem}-byte element")
                continue
            end = offset + stride * (count - 1) + elem
            if end > view["byteLength"]:
                rep.error("ACCESSOR_OUT_OF_VIEW", where, f"needs {end} bytes of a {view['byteLength']}-byte buffer view")
                continue
        elif acc.get("sparse") is None:
            rep.warn("ACCESSOR_ZEROS", where, "no bufferView: every element is zero")
        decoded = _decode(acc, doc, buffers)
        values[i] = decoded
        if decoded is None or "min" not in acc or "max" not in acc or not isinstance(acc["min"], list) or len(acc["min"]) != n:
            continue
        lo = [min(e[c] for e in decoded) for c in range(n)]
        hi = [max(e[c] for e in decoded) for c in range(n)]
        for c in range(n):
            tol = 1e-5 * max(1.0, abs(acc["min"][c]), abs(acc["max"][c]))
            if lo[c] < acc["min"][c] - tol or hi[c] > acc["max"][c] + tol:
                rep.error("ACCESSOR_OUT_OF_BOUNDS", where, f"component {c}: data {lo[c]:.6g}..{hi[c]:.6g} outside declared min/max {acc['min'][c]:.6g}..{acc['max'][c]:.6g}")
                break
            if lo[c] > acc["min"][c] + tol or hi[c] < acc["max"][c] - tol:
                rep.warn("ACCESSOR_BOUNDS_LOOSE", where, f"component {c}: declared min/max {acc['min'][c]:.6g}..{acc['max'][c]:.6g} wider than the data {lo[c]:.6g}..{hi[c]:.6g}")
                break
    return values


def _accessor(doc, index):
    return (doc.get("accessors") or [])[index]


def _meshes(rep, doc, values):
    tris_total, verts_total = 0, 0
    for m, mesh in enumerate(doc.get("meshes") or []):
        mesh_tris = 0
        prims = mesh.get("primitives") or []
        if not prims:
            rep.error("MESH_NO_PRIMITIVES", f"meshes[{m}]", "a mesh needs at least one primitive")
        for p, prim in enumerate(prims):
            where = f"meshes[{m}].primitives[{p}]"
            attrs = prim.get("attributes") or {}
            if "POSITION" not in attrs:
                rep.error("PRIMITIVE_NO_POSITION", where, "no POSITION attribute")
                continue
            counts = set()
            good = True
            for name, index in attrs.items():
                if not _index(rep, doc, "accessors", index, f"{where}.attributes.{name}"):
                    good = False
                    continue
                acc = _accessor(doc, index)
                counts.add(acc.get("count"))
                want = {"POSITION": ("VEC3", (5126,)), "NORMAL": ("VEC3", (5126,)), "TANGENT": ("VEC4", (5126,))}.get(name)
                if name.startswith("TEXCOORD_"):
                    want = ("VEC2", (5126, 5121, 5123))
                elif name.startswith("COLOR_"):
                    want = (("VEC3", "VEC4"), (5126, 5121, 5123))
                elif name.startswith("JOINTS_"):
                    want = ("VEC4", (5121, 5123))
                elif name.startswith("WEIGHTS_"):
                    want = ("VEC4", (5126, 5121, 5123))
                if want and (acc.get("type") not in (want[0] if isinstance(want[0], tuple) else (want[0],)) or acc.get("componentType") not in want[1]):
                    rep.error("ATTRIBUTE_TYPE", f"{where}.attributes.{name}", f"{acc.get('type')}/{acc.get('componentType')} is not a valid {name}")
                    good = False
            if "TEXCOORD_1" in attrs:
                rep.warn("SECOND_UV_SET", where, "TEXCOORD_1: Roblox reads one UV set")
            if "JOINTS_1" in attrs or "WEIGHTS_1" in attrs:
                rep.error("INFLUENCES_OVER_4", where, "JOINTS_1/WEIGHTS_1: more than 4 influences per vertex (Roblox allows 4)")
            if ("JOINTS_0" in attrs) != ("WEIGHTS_0" in attrs):
                rep.error("SKIN_ATTRIBUTES", where, "JOINTS_0 and WEIGHTS_0 come together")
            if len(counts) > 1:
                rep.error("ATTRIBUTE_COUNTS", where, f"attributes disagree on the vertex count {sorted(c for c in counts if c is not None)}")
                good = False
            if not good:
                continue
            vcount = _accessor(doc, attrs["POSITION"])["count"]
            pos = _accessor(doc, attrs["POSITION"])
            if "min" not in pos or "max" not in pos:
                rep.error("POSITION_BOUNDS", f"{where}.attributes.POSITION", "POSITION accessors must declare min and max")
            mode = prim.get("mode", 4)
            if mode not in MODES:
                rep.error("PRIMITIVE_MODE", where, f"mode {mode} is not valid")
            elif mode != 4:
                rep.warn("PRIMITIVE_NOT_TRIANGLES", where, f"mode {MODES[mode]}: Roblox imports triangle lists")
            n = vcount
            if "indices" in prim and _index(rep, doc, "accessors", prim["indices"], where + ".indices"):
                acc = _accessor(doc, prim["indices"])
                if acc.get("type") != "SCALAR" or acc.get("componentType") not in (5121, 5123, 5125):
                    rep.error("INDICES_TYPE", where + ".indices", "indices must be SCALAR unsigned byte/short/int")
                else:
                    n = acc["count"]
                    vals = values.get(prim["indices"])
                    if vals is not None and vals and max(v[0] for v in vals) >= vcount:
                        rep.error("INDEX_OVER_VERTEX_COUNT", where + ".indices", f"index {max(v[0] for v in vals)} >= vertex count {vcount}")
            if mode == 4:
                if n % 3:
                    rep.error("TRIANGLE_COUNT", where, f"{n} indices is not a multiple of 3")
                mesh_tris += n // 3
            if "material" in prim:
                _index(rep, doc, "materials", prim["material"], where + ".material")
            weights = values.get(attrs.get("WEIGHTS_0"))
            if weights:
                acc = _accessor(doc, attrs["WEIGHTS_0"])
                scale = {5126: 1.0, 5121: 255.0, 5123: 65535.0}[acc["componentType"]]
                bad = sum(1 for w in weights if abs(sum(w) / scale - 1.0) > 0.01)
                if bad:
                    rep.warn("WEIGHTS_NOT_NORMALISED", where, f"{bad} vertices' weights do not sum to 1")
            verts_total += vcount
        tris_total += mesh_tris
        if mesh_tris > MAX_TRIANGLES:
            rep.warn("MESH_TRIANGLES", f"meshes[{m}]", f"{mesh_tris} triangles: over {MAX_TRIANGLES} per mesh (Roblox splits or refuses)")
    rep.info["triangles"] = tris_total
    rep.info["vertices"] = verts_total


def _nodes(rep, doc):
    nodes = doc.get("nodes") or []
    parent = {}
    for i, node in enumerate(nodes):
        where = f"nodes[{i}]"
        for child in node.get("children") or []:
            if not _index(rep, doc, "nodes", child, where + ".children"):
                continue
            if child == i:
                rep.error("NODE_SELF_CHILD", where, "node is its own child")
            elif child in parent:
                rep.error("NODE_MULTIPLE_PARENTS", f"nodes[{child}]", f"children of both nodes[{parent[child]}] and nodes[{i}]")
            else:
                parent[child] = i
        if "mesh" in node:
            _index(rep, doc, "meshes", node["mesh"], where + ".mesh")
        if "skin" in node:
            _index(rep, doc, "skins", node["skin"], where + ".skin")
            if "mesh" not in node:
                rep.error("SKIN_WITHOUT_MESH", where, "skin on a node without a mesh")
        if "camera" in node:
            _index(rep, doc, "cameras", node["camera"], where + ".camera")
        if "matrix" in node and any(k in node for k in ("translation", "rotation", "scale")):
            rep.error("NODE_MATRIX_AND_TRS", where, "matrix and translation/rotation/scale together")
        rot = node.get("rotation")
        if isinstance(rot, list) and len(rot) == 4 and abs(math.sqrt(sum(c * c for c in rot)) - 1.0) > 0.001:
            rep.error("NODE_ROTATION_NOT_UNIT", where, "rotation quaternion is not unit length")
    for start in range(len(nodes)):  # cycles through the parent map
        seen, n = set(), start
        while n in parent:
            if n in seen:
                rep.error("NODE_CYCLE", f"nodes[{start}]", "node hierarchy has a cycle")
                break
            seen.add(n)
            n = parent[n]
    scenes = doc.get("scenes") or []
    for s, scene in enumerate(scenes):
        for root in scene.get("nodes") or []:
            if _index(rep, doc, "nodes", root, f"scenes[{s}].nodes") and root in parent:
                rep.error("SCENE_ROOT_HAS_PARENT", f"scenes[{s}].nodes", f"nodes[{root}] is a child of nodes[{parent[root]}]")
    if "scene" in doc:
        _index(rep, doc, "scenes", doc["scene"], "scene")
    elif scenes:
        rep.warn("NO_DEFAULT_SCENE", "scene", "no default scene: importers pick scene 0 or nothing")
    if not scenes and doc.get("meshes"):
        rep.warn("NO_SCENES", "scenes", "meshes but no scene: some importers show nothing")
    rep.info["nodes"] = len(nodes)


def _skins(rep, doc, values):
    info = []
    for s, skin in enumerate(doc.get("skins") or []):
        where = f"skins[{s}]"
        joints = skin.get("joints") or []
        if not joints:
            rep.error("SKIN_NO_JOINTS", where, "a skin needs joints")
        for j in joints:
            _index(rep, doc, "nodes", j, where + ".joints")
        if len(set(joints)) != len(joints):
            rep.error("SKIN_DUPLICATE_JOINTS", where, "a node is listed twice in joints")
        if "inverseBindMatrices" in skin and _index(rep, doc, "accessors", skin["inverseBindMatrices"], where + ".inverseBindMatrices"):
            acc = _accessor(doc, skin["inverseBindMatrices"])
            if acc.get("type") != "MAT4" or acc.get("componentType") != 5126:
                rep.error("SKIN_IBM_TYPE", where, "inverseBindMatrices must be MAT4 FLOAT")
            elif acc.get("count") != len(joints):
                rep.error("SKIN_IBM_COUNT", where, f"{acc.get('count')} inverse bind matrices for {len(joints)} joints")
        if "skeleton" in skin:
            _index(rep, doc, "nodes", skin["skeleton"], where + ".skeleton")
        info.append({"skin": s, "joints": len(joints)})
    for m_index, node in enumerate(doc.get("nodes") or []):
        if "skin" not in node or "mesh" not in node:
            continue
        skins, meshes = doc.get("skins") or [], doc.get("meshes") or []
        if not (isinstance(node["skin"], int) and 0 <= node["skin"] < len(skins) and isinstance(node["mesh"], int) and 0 <= node["mesh"] < len(meshes)):
            continue
        n_joints = len(skins[node["skin"]].get("joints") or [])
        for p, prim in enumerate(meshes[node["mesh"]].get("primitives") or []):
            index = (prim.get("attributes") or {}).get("JOINTS_0")
            vals = values.get(index) if isinstance(index, int) else None
            if vals and max(max(v) for v in vals) >= n_joints:
                rep.error("JOINT_INDEX_OVER_COUNT", f"meshes[{node['mesh']}].primitives[{p}].JOINTS_0", f"joint index {max(max(v) for v in vals)} >= {n_joints} joints of skins[{node['skin']}]")
    rep.info["skins"] = info


def _morph_targets(doc, node_index):
    """Morph target count of the mesh on node `node_index` (1 when unknown)."""
    nodes, meshes = doc.get("nodes") or [], doc.get("meshes") or []
    if not isinstance(node_index, int) or not 0 <= node_index < len(nodes):
        return 1
    mesh = nodes[node_index].get("mesh")
    if not isinstance(mesh, int) or not 0 <= mesh < len(meshes):
        return 1
    prims = meshes[mesh].get("primitives") or [{}]
    return max(1, len(prims[0].get("targets") or []))


def _animations(rep, doc, values):
    info = []
    for a, anim in enumerate(doc.get("animations") or []):
        where = f"animations[{a}]"
        samplers = anim.get("samplers") or []
        channels = anim.get("channels") or []
        if not channels:
            rep.error("ANIMATION_NO_CHANNELS", where, "an animation needs channels")
        end = 0.0
        for s, sampler in enumerate(samplers):
            sw = f"{where}.samplers[{s}]"
            interp = sampler.get("interpolation", "LINEAR")
            if interp not in ("LINEAR", "STEP", "CUBICSPLINE"):
                rep.error("SAMPLER_INTERPOLATION", sw, f"interpolation {interp!r} is not valid")
            good = _index(rep, doc, "accessors", sampler.get("input"), sw + ".input") & _index(rep, doc, "accessors", sampler.get("output"), sw + ".output")
            if not good:
                continue
            inp, out = _accessor(doc, sampler["input"]), _accessor(doc, sampler["output"])
            if inp.get("type") != "SCALAR" or inp.get("componentType") != 5126:
                rep.error("SAMPLER_INPUT_TYPE", sw, "input must be SCALAR FLOAT (seconds)")
                continue
            if "min" not in inp or "max" not in inp:
                rep.error("SAMPLER_INPUT_BOUNDS", sw, "input accessor must declare min and max")
            times = values.get(sampler["input"])
            if times:
                ts = [t[0] for t in times]
                if ts[0] < 0:
                    rep.error("SAMPLER_NEGATIVE_TIME", sw, f"first key at {ts[0]} s")
                if any(b <= a for a, b in zip(ts, ts[1:])):
                    rep.error("SAMPLER_TIMES_ORDER", sw, "key times must strictly increase")
                end = max(end, ts[-1])
            per_key = 3 if interp == "CUBICSPLINE" else 1
            targets = [c for c in channels if c.get("sampler") == s]
            path = (targets[0].get("target") or {}).get("path") if targets else None
            stride = _morph_targets(doc, targets[0]["target"].get("node")) if path == "weights" else 1
            if out.get("count") != inp.get("count") * per_key * stride:
                rep.error("SAMPLER_OUTPUT_COUNT", sw, f"{out.get('count')} output values for {inp.get('count')} keys ({interp}{', x' + str(stride) + ' morph targets' if stride > 1 else ''})")
            if path in PATH_TYPES and out.get("type") not in PATH_TYPES[path]:
                rep.error("SAMPLER_OUTPUT_TYPE", sw, f"{out.get('type')} output for a {path} channel")
            if path in ("translation", "scale") and out.get("componentType") != 5126:
                rep.error("SAMPLER_OUTPUT_COMPONENT", sw, f"{path} output must be FLOAT")
        seen = set()
        for c, channel in enumerate(channels):
            cw = f"{where}.channels[{c}]"
            if not isinstance(channel.get("sampler"), int) or not 0 <= channel["sampler"] < len(samplers):
                rep.error("CHANNEL_SAMPLER", cw, f"sampler {channel.get('sampler')!r} is not an index into this animation's samplers")
            target = channel.get("target") or {}
            if target.get("path") not in PATH_TYPES:
                rep.error("CHANNEL_PATH", cw, f"path {target.get('path')!r} is not translation/rotation/scale/weights")
            if "node" in target:
                _index(rep, doc, "nodes", target["node"], cw + ".target.node")
            key = (target.get("node"), target.get("path"))
            if key in seen:
                rep.error("CHANNEL_DUPLICATE", cw, f"node {key[0]} {key[1]} is animated twice")
            seen.add(key)
        info.append({"name": anim.get("name"), "channels": len(channels), "samplers": len(samplers), "duration": round(end, 4)})
    rep.info["animations"] = info


def image_header(data):
    """(mime, width, height) from PNG or JPEG bytes, else (None, None, None)."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return "image/png", *struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return "image/jpeg", w, h
            i += 2 + length
        return "image/jpeg", None, None
    return None, None, None


def _images(rep, doc, buffers, base_dir, view_ok):
    info = []
    for i, image in enumerate(doc.get("images") or []):
        where = f"images[{i}]"
        data = None
        if "bufferView" in image:
            if not image.get("mimeType"):
                rep.error("IMAGE_MIME_MISSING", where, "an image in a bufferView needs mimeType")
            if _index(rep, doc, "bufferViews", image["bufferView"], where + ".bufferView") and view_ok[image["bufferView"]]:
                view = doc["bufferViews"][image["bufferView"]]
                buf = buffers[view["buffer"]]
                if buf is not None:
                    data = buf[view.get("byteOffset", 0):view.get("byteOffset", 0) + view["byteLength"]]
        elif "uri" in image:
            uri = image["uri"]
            if uri.startswith("data:"):
                try:
                    data = base64.b64decode(uri.split(",", 1)[1])
                except (IndexError, ValueError):
                    rep.error("IMAGE_DATA_URI", where, "data URI does not decode")
            else:
                rep.warn("IMAGE_EXTERNAL", where, f"external image {uri}: keep it next to the model (Studio reads embedded or same-folder maps)")
                path = (base_dir / uri) if base_dir else None
                if path is not None and path.is_file():
                    data = path.read_bytes()[:65536]
                else:
                    rep.error("IMAGE_MISSING", where, f"image file {uri} not found")
        else:
            rep.error("IMAGE_SOURCE", where, "an image needs bufferView or uri")
        entry = {"image": i, "name": image.get("name"), "mime": image.get("mimeType")}
        if data is not None:
            mime, w, h = image_header(data)
            entry.update(detected=mime, width=w, height=h)
            if mime is None:
                rep.error("IMAGE_FORMAT", where, "not PNG or JPEG (Roblox imports PNG and JPEG maps)")
            elif image.get("mimeType") and image["mimeType"] != mime:
                rep.error("IMAGE_MIME_MISMATCH", where, f"declared {image['mimeType']} but the bytes are {mime}")
            if w and h:
                if max(w, h) > MAX_TEXTURE:
                    rep.warn("IMAGE_SIZE", where, f"{w}x{h}: SurfaceAppearance maps are at most {MAX_TEXTURE} px")
                if w != h or w & (w - 1):
                    rep.warn("IMAGE_NOT_POW2", where, f"{w}x{h} is not a square power of two")
        info.append(entry)
    rep.info["images"] = info
    for t, tex in enumerate(doc.get("textures") or []):
        where = f"textures[{t}]"
        if "source" in tex:
            _index(rep, doc, "images", tex["source"], where + ".source")
        else:
            rep.warn("TEXTURE_NO_SOURCE", where, f"no PNG/JPEG source (extensions {sorted((tex.get('extensions') or {}))}): Roblox gets no image")
        if "sampler" in tex:
            _index(rep, doc, "samplers", tex["sampler"], where + ".sampler")


def _materials(rep, doc):
    slots = ("baseColorTexture", "metallicRoughnessTexture")
    for m, mat in enumerate(doc.get("materials") or []):
        refs = [(f"pbrMetallicRoughness.{s}", (mat.get("pbrMetallicRoughness") or {}).get(s)) for s in slots]
        refs += [(s, mat.get(s)) for s in ("normalTexture", "occlusionTexture", "emissiveTexture")]
        for name, ref in refs:
            if ref is None:
                continue
            where = f"materials[{m}].{name}"
            _index(rep, doc, "textures", ref.get("index"), where + ".index")
            if ref.get("texCoord", 0) != 0:
                rep.warn("TEXCOORD_NOT_ZERO", where, f"texCoord {ref['texCoord']}: Roblox reads one UV set")
    rep.info["materials"] = len(doc.get("materials") or [])


def validate_document(doc, binary=None, base_dir=None, glb=True, name=""):
    rep = Report(name)
    if not isinstance(doc, dict):
        rep.error("JSON_ROOT", "", "the glTF JSON root must be an object")
        return rep.as_dict()
    asset = doc.get("asset")
    if not isinstance(asset, dict) or asset.get("version") != "2.0":
        rep.error("ASSET_VERSION", "asset.version", f"must be '2.0' (got {asset.get('version') if isinstance(asset, dict) else asset!r})")
    rep.info["generator"] = (asset or {}).get("generator") if isinstance(asset, dict) else None
    required = doc.get("extensionsRequired") or []
    used = doc.get("extensionsUsed") or []
    for ext in required:
        if ext not in used:
            rep.error("EXTENSION_NOT_USED", "extensionsRequired", f"{ext} is required but not in extensionsUsed")
        rep.warn("EXTENSION_REQUIRED", "extensionsRequired", f"{ext} is required: a reader without it (Roblox's importer, UNVERIFIED) cannot load the file")
    rep.info["extensions_used"], rep.info["extensions_required"] = used, required
    buffers = _buffers(rep, doc, binary, base_dir, glb)
    view_ok = _views(rep, doc)
    values = _accessors(rep, doc, buffers, view_ok)
    _meshes(rep, doc, values)
    _nodes(rep, doc)
    _skins(rep, doc, values)
    _animations(rep, doc, values)
    _images(rep, doc, buffers, base_dir, view_ok)
    _materials(rep, doc)
    for key in ("meshes", "textures", "samplers", "scenes"):
        rep.info[key] = len(doc.get(key) or [])
    return rep.as_dict()


def validate_bytes(data, name="<bytes>", base_dir=None):
    if data[:4] == b"glTF":
        rep = Report(name)
        doc, binary = _parse_glb(data, rep)
        if doc is None:
            return rep.as_dict()
        result = validate_document(doc, binary, base_dir, glb=True, name=name)
        result["errors"] = rep.errors + result["errors"]
        result["warnings"] = rep.warnings + result["warnings"]
        result["pass"] = not result["errors"]
        return result
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        rep = Report(name)
        rep.error("NOT_GLTF", "", f"neither a GLB nor glTF JSON: {exc}")
        return rep.as_dict()
    return validate_document(doc, None, base_dir, glb=False, name=name)


def validate_file(path):
    path = Path(path)
    if not path.is_file():
        rep = Report(str(path))
        rep.error("FILE_MISSING", "", "no such file")
        return rep.as_dict()
    return validate_bytes(path.read_bytes(), name=str(path), base_dir=path.parent)


def gltf_transform(path, opted_in):
    """`gltf-transform inspect` output when the owner opted in and npx exists; else why not."""
    if not opted_in:
        return {"ran": False, "reason": f"not opted in (--gltf-transform or {OPT_IN_ENV}=1)"}
    npx = shutil.which("npx")
    if npx is None:
        return {"ran": False, "reason": "npx not on PATH"}
    try:
        # Launch the resolved path: on Windows npx is npx.cmd, which a bare "npx" cannot start.
        proc = subprocess.run([npx, *GLTF_TRANSFORM[1:], str(path)], capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ran": False, "reason": str(exc)}
    return {"ran": True, "returncode": proc.returncode, "output": (proc.stdout + proc.stderr)[-20000:]}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="gltf_validate.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", dest="report")
    ap.add_argument("--gltf-transform", action="store_true")
    a = ap.parse_args(argv)
    opted = a.gltf_transform or os.environ.get(OPT_IN_ENV) == "1"
    results = []
    for file in a.files:
        result = validate_file(file)
        result["gltf_transform"] = gltf_transform(file, opted)
        results.append(result)
        info = result["info"]
        print(f"{file}: {'PASS' if result['pass'] else 'FAIL'} errors={len(result['errors'])} warnings={len(result['warnings'])} "
              f"meshes={info.get('meshes', 0)} triangles={info.get('triangles', 0)} images={len(info.get('images') or [])} "
              f"animations={len(info.get('animations') or [])} skins={[s['joints'] for s in info.get('skins') or []]}")
        for item in result["errors"] + result["warnings"]:
            level = "ERROR" if item in result["errors"] else "warning"
            print(f"  {level} {item['code']} {item['path']}: {item['message']}")
    report = {"schema": "gltf-validate/1", "pass": all(r["pass"] for r in results), "files": results}
    if a.report:
        Path(a.report).parent.mkdir(parents=True, exist_ok=True)
        Path(a.report).write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
