"""Asset quality gate. Produces a machine-readable report for a .blend scene or imported
FBX/GLB. Error-level failures block export: `gated_export` runs the checks first, writes
FBX/GLB only when they have no errors, re-imports exactly the shipped files and deletes them
again if they do not match the export set. Warnings need a human decision.

Limits come from Roblox import rules (20k triangles per mesh, 4 influences per vertex) and
from the asset's own `rbx_*` metadata (category budgets, expected dimensions)."""
import json
import math
import os
import tempfile
from collections import defaultdict
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector, kdtree

from . import env

ROBLOX_MAX_TRIS = 20000
ROBLOX_MAX_INFLUENCES = 4
# glTF stores one vertex per corner attribute set, so imported .glb meshes are split along UV and
# normal seams. `_weld_seams` joins those seams again (vertices closer than this) for the topology
# checks without merging separate shells that merely touch.
GLTF_WELD = 1e-5
TAU = 2 * math.pi

BUDGETS = {  # triangles, materials (per mesh) - workbench defaults, override with rbx_budget
    "prop": (2000, 2),
    "furniture": (3000, 3),
    "weapon": (4000, 3),
    "building": (10000, 6),
    "modular": (1500, 2),
    "vehicle": (10000, 6),
    "humanoid": (8000, 4),
    "creature": (10000, 4),
    "vegetation": (3000, 2),
    "environment": (15000, 6),
    "test": (20000, 8),
}


def _check(name, ok, value=None, limit=None, level="error", detail=None):
    return {"name": name, "pass": bool(ok), "level": level, "value": value, "limit": limit, "detail": detail}


def _world_bounds(obj):
    pts = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def _bone_shapes():
    """Meshes drawn as pose-bone custom shapes (the glTF importer adds an Icosphere). Display
    only: never exported geometry, so neither checked nor counted in signatures."""
    return {pb.custom_shape for o in bpy.context.scene.objects if o.type == "ARMATURE" for pb in o.pose.bones if pb.custom_shape}


def _world_scale(obj):
    """World scale (column lengths of the world matrix), so a scaled parent (Empty, armature)
    counts. A mirrored matrix (negative determinant) always reads negative on the axes whose
    column points against its own axis (`(-1, 1, 1)` reads as such, not as `(-1, -1, -1)`, which
    is what Matrix.to_scale reports); a rotated mirror blames its least-aligned axis. A positive
    determinant is a pure rotation and reads positive (the rotation check reports it)."""
    m = obj.matrix_world.to_3x3()
    cols = [m.col[i] for i in range(3)]
    mags = [c.length for c in cols]
    signs = [1, 1, 1]
    if m.determinant() < 0:
        signs = [-1 if cols[i][i] < 0 else 1 for i in range(3)]
        if math.prod(signs) > 0:
            worst = min(range(3), key=lambda i: cols[i][i] / (mags[i] or 1))
            signs = [-1 if i == worst else 1 for i in range(3)]
    return tuple(round(s * g, 4) for s, g in zip(signs, mags))


def _world_rotation(obj):
    """World rotation as Euler degrees plus its total angle in degrees (parents included)."""
    m = obj.matrix_world
    angle = math.degrees(m.to_quaternion().angle)
    return tuple(round(math.degrees(r), 2) for r in m.to_euler()), min(angle, 360 - angle)


def transform_checks(obj, prefix="transform", rotation_level="warning"):
    """Applied-transform checks on the world matrix: export bakes the whole parent chain."""
    scale = _world_scale(obj)
    rot, angle = _world_rotation(obj)
    return [
        _check(f"{prefix}_scale_applied", all(abs(s - 1) < 1e-4 for s in scale), scale, (1, 1, 1), detail="world scale, parents included"),
        _check(f"{prefix}_rotation_applied", angle < 0.01, rot, (0, 0, 0), level=rotation_level, detail="world rotation, parents included"),
    ]


class _Sets:
    """Union-find over integer ids."""

    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, i):
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, a, b):
        a, b = self.find(a), self.find(b)
        if a != b:
            self.parent[max(a, b)] = min(a, b)


def _radial_pairs(edges, a, b, cls, origin):
    """Pair coincident boundary edges (all spanning position classes a -> b) around their common
    line the way closed shells close: sorted by the angle at which each face leaves the edge, a
    face with solid on its counter-clockwise side pairs with the next face counter-clockwise.
    Faces at the same angle (shells touching face to face) order closing-before-opening, so the
    zero-thickness gap is void, not solid. Returns None when the faces do not alternate (odd
    count, inconsistent winding or interpenetration): the caller then welds them all."""
    v0, v1 = edges[0].verts
    d = ((v1.co - v0.co) if cls[v0.index] == a else (v0.co - v1.co)).normalized()
    e1 = d.orthogonal().normalized()
    e2 = d.cross(e1)
    items = []
    for e in edges:
        loop = e.link_loops[0]
        sign = 1 if cls[loop.vert.index] == a else -1  # winding along a -> b
        w = loop.face.calc_center_median() - origin
        u = w - d * w.dot(d)  # direction from the edge into the face
        if u.length < 1e-9:
            return None
        items.append((math.atan2(u.dot(e2), u.dot(e1)) % TAU, sign, e))
    items.sort(key=lambda t: t[0])
    n = len(items)
    # Start after the widest angular gap so faces at the same angle never straddle the 0/TAU wrap.
    widest = max(range(n), key=lambda i: ((items[(i + 1) % n][0] - items[i][0]) % TAU, -i))
    seq = items[widest + 1 :] + items[: widest + 1]
    ordered, group = [], [seq[0]]
    for item in seq[1:]:
        if (item[0] - group[-1][0]) % TAU < 1e-4:
            group.append(item)
        else:
            ordered += sorted(group, key=lambda t: -t[1])
            group = [item]
    ordered += sorted(group, key=lambda t: -t[1])
    signs = [t[1] for t in ordered]
    if n % 2 or any(signs[i] == signs[(i + 1) % n] for i in range(n)):
        return None
    first = 0 if signs[0] == -1 else 1
    return [(ordered[i][2], ordered[(i + 1) % n][2]) for i in range(first, n + first, 2)]


def _weld_seams(bm, dist):
    """Undo glTF's per-corner vertex split for the topology checks without merging separate
    shells. A plain distance weld also fuses closed shells that share an edge or face (stacked
    or abutting boxes in one mesh) into false non-manifold edges and flipped normals. Instead,
    coincident boundary edges are paired: two always pair (a seam; if their windings agree the
    normals check reports the flip), more than two pair radially (`_radial_pairs`), anything
    that does not pair cleanly is welded together. Only paired edges merge their endpoints.
    Returns the number of vertices merged away."""
    bm.verts.index_update()
    verts = list(bm.verts)
    tree = kdtree.KDTree(len(verts))
    for v in verts:
        tree.insert(v.co, v.index)
    tree.balance()
    near = _Sets(len(verts))
    for v in verts:
        for _co, j, _dist in tree.find_range(v.co, dist):
            near.union(v.index, j)
    cls = [near.find(i) for i in range(len(verts))]
    lines = defaultdict(list)
    for e in bm.edges:
        if len(e.link_faces) == 1:
            a, b = cls[e.verts[0].index], cls[e.verts[1].index]
            if a != b:
                lines[(min(a, b), max(a, b))].append(e)
    merge = _Sets(len(verts))

    def join(e1, e2):
        for v in e1.verts:
            for w in e2.verts:
                if cls[w.index] == cls[v.index]:
                    merge.union(v.index, w.index)

    for (a, b), edges in lines.items():
        if len(edges) < 2:
            continue  # a real open boundary
        origin = next(v.co for v in edges[0].verts if cls[v.index] == a)
        pairs = [tuple(edges)] if len(edges) == 2 else _radial_pairs(edges, a, b, cls, origin)
        if pairs is None:
            for other in edges[1:]:
                join(edges[0], other)
            continue
        for e1, e2 in pairs:
            if e1.link_faces[0] is not e2.link_faces[0]:  # never collapse a face onto itself
                join(e1, e2)
    targetmap = {verts[i]: verts[merge.find(i)] for i in range(len(verts)) if merge.find(i) != i}
    if targetmap:
        bmesh.ops.weld_verts(bm, targetmap=targetmap)
    return len(targetmap)


def mesh_checks(obj, meta, weld=0.0):
    """weld > 0 joins glTF seams (`_weld_seams`, vertices closer than `weld`) on a copy before
    the edge and normals checks (use GLTF_WELD for glTF input); triangle counts, degenerate faces
    and loose vertices always use the mesh as stored."""
    checks = []
    mesh = obj.data
    category = meta.get("category", "test")
    tri_budget, mat_budget = BUDGETS.get(category, BUDGETS["test"])
    if isinstance(meta.get("budget"), dict):
        tri_budget = meta["budget"].get("tris", tri_budget)
        mat_budget = meta["budget"].get("materials", mat_budget)

    # Transforms: export expects applied rotation/scale on meshes (rotation is a warning).
    checks += transform_checks(obj)

    bm = bmesh.new()
    evaluated = "modifiers applied"
    try:
        bm.from_object(obj, bpy.context.evaluated_depsgraph_get())
    except ValueError:  # not in the evaluated depsgraph (collection excluded or disabled)
        bm.from_mesh(mesh)
        evaluated = "base mesh, modifiers not applied: not evaluated (collection excluded or disabled)"
    bm.verts.ensure_lookup_table()
    tris = sum(len(f.verts) - 2 for f in bm.faces)
    checks.append(_check("triangles_roblox_limit", tris <= ROBLOX_MAX_TRIS, tris, ROBLOX_MAX_TRIS, detail=evaluated))
    checks.append(_check("triangles_budget", tris <= tri_budget, tris, tri_budget, level="warning", detail=category))

    # Degenerate faces and loose vertices are properties of the stored mesh: check before welding.
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-6)
    loose = sum(1 for v in bm.verts if not v.link_edges)
    welded = None
    if weld:
        merged = _weld_seams(bm, weld)
        bm.normal_update()
        welded = f"glTF seams welded at {weld} ({merged} vertices merged)"
    non_manifold = sum(1 for e in bm.edges if not e.is_manifold and not e.is_boundary)
    boundary = sum(1 for e in bm.edges if e.is_boundary)
    checks.append(_check("non_manifold_edges", non_manifold == 0, non_manifold, 0, detail=welded))
    checks.append(_check("open_boundary_edges", boundary == 0 or meta.get("allow_open", False), boundary, 0, level="warning", detail="watertight preferred for Roblox collision"))
    checks.append(_check("degenerate_faces", degenerate == 0, degenerate, 0, detail="mesh as stored"))
    checks.append(_check("loose_vertices", loose == 0, loose, 0, detail="mesh as stored"))

    # Normals: compare against a recalculated copy; flipped faces count.
    copy = bm.copy()
    before = [f.normal.copy() for f in copy.faces]
    bmesh.ops.recalc_face_normals(copy, faces=copy.faces)
    flipped = sum(1 for f, n in zip(copy.faces, before) if f.normal.dot(n) < 0)
    copy.free()
    checks.append(_check("normals_consistent", flipped == 0, flipped, 0, detail=welded))
    bm.free()

    # UVs
    uv_ok = len(mesh.uv_layers) > 0
    zero_uv = 0
    if uv_ok:
        layer = mesh.uv_layers.active.data
        for poly in mesh.polygons:
            uvs = [layer[i].uv for i in poly.loop_indices]
            area = 0.0
            for i in range(len(uvs)):
                a, b = uvs[i], uvs[(i + 1) % len(uvs)]
                area += a.x * b.y - b.x * a.y
            if abs(area) < 1e-9:
                zero_uv += 1
    checks.append(_check("uv_present", uv_ok, len(mesh.uv_layers), ">=1"))
    checks.append(_check("uv_zero_area_faces", zero_uv == 0, zero_uv, 0, level="warning"))

    # Materials and textures
    mats = [s.material for s in obj.material_slots]
    checks.append(_check("material_assigned", len(mats) > 0 and all(mats), len(mats), ">=1"))
    checks.append(_check("material_count", len(mats) <= mat_budget, len(mats), mat_budget, level="warning"))
    missing = []
    for mat in filter(None, mats):
        if mat.use_nodes:
            for node in mat.node_tree.nodes:
                if node.type == "TEX_IMAGE" and node.image and not node.image.packed_file:
                    path = bpy.path.abspath(node.image.filepath)
                    if not os.path.exists(path):
                        missing.append(node.image.filepath)
    checks.append(_check("texture_paths", not missing, len(missing), 0, detail=", ".join(missing[:5])))

    # Pivot at base centre (world-space bounds vs origin), dimensions vs expectation.
    mn, mx = _world_bounds(obj)
    origin = obj.matrix_world.translation
    centre = (mn + mx) / 2
    tol = max(0.05, (mx - mn).length * 0.02)
    pivot_ok = abs(origin.z - mn.z) <= tol and abs(origin.x - centre.x) <= tol and abs(origin.y - centre.y) <= tol
    checks.append(_check("pivot_base_center", pivot_ok or meta.get("pivot") == "custom", [round(v, 3) for v in origin], "base-centre", level="warning"))
    dims = [round(v, 3) for v in (mx - mn)]
    expected = meta.get("expected_dims")  # [x, y, z] studs, Blender axes
    if expected:
        ok = all(abs(d - e) <= max(0.1, e * 0.15) for d, e in zip(dims, expected))
        checks.append(_check("scale_expected_dims", ok, dims, expected))
    else:
        checks.append(_check("scale_plausible", 0.05 <= max(dims) <= 2048, dims, "0.05..2048 studs", level="warning"))
    up = meta.get("up_axis_longest")
    if up:
        checks.append(_check("orientation_up", dims[2] >= max(dims[0], dims[1]) * 0.9, dims, "Z tallest"))

    # Skinning: only vertex groups named after a deform bone of the bound armature are bone weights.
    arm_mod = next((m for m in obj.modifiers if m.type == "ARMATURE"), None)
    if arm_mod or meta.get("rigged"):
        rig = arm_mod.object if arm_mod else None
        deform = {b.name for b in rig.data.bones if b.use_deform} if rig is not None and rig.type == "ARMATURE" else set()
        bone_groups = {g.index for g in obj.vertex_groups if g.name in deform}
        influences = [sum(1 for g in v.groups if g.group in bone_groups and g.weight > 1e-4) for v in mesh.vertices]
        over = sum(1 for n in influences if n > ROBLOX_MAX_INFLUENCES)
        unweighted = sum(1 for n in influences if n == 0)
        checks.append(_check("bone_influences", over == 0, over, ROBLOX_MAX_INFLUENCES, detail="deform-bone groups only"))
        checks.append(_check("unweighted_vertices", unweighted == 0, unweighted, 0, detail="no weight on any deform bone"))
        checks.append(_check("armature_bound", rig is not None, bool(arm_mod), True))
    return checks


def armature_checks(obj, meta):
    checks = []
    bones = obj.data.bones
    checks.append(_check("bone_count", 0 < len(bones) <= 200, len(bones), "1..200"))
    expected = meta.get("bone_names")
    if expected:
        missing = [b for b in expected if b not in bones]
        checks.append(_check("bone_names", not missing, len(missing), 0, detail=", ".join(missing[:8])))
    # Rigs import with their object transform frozen (scale 1, rotation 0), parents included.
    checks += transform_checks(obj, prefix="armature", rotation_level="error")
    action = obj.animation_data.action if obj.animation_data else None
    if meta.get("animated") or action:
        frames = 0
        if action:
            frames = int(action.frame_range[1] - action.frame_range[0])
        checks.append(_check("animation_clip", action is not None and frames > 0, frames, ">0"))
    return checks


def empty_checks(obj, meta):
    """Empties export as nodes whose transform scales and turns everything under them."""
    return transform_checks(obj)


def summarize(report):
    """(Re)compute report["summary"] from the object checks and the export result."""
    errors = [f"{o['name']}:{c['name']}" for o in report["objects"] for c in o["checks"] if not c["pass"] and c["level"] == "error"]
    warnings = [f"{o['name']}:{c['name']}" for o in report["objects"] for c in o["checks"] if not c["pass"] and c["level"] == "warning"]
    export = report.get("export")
    if export is not None and not export["pass"]:
        errors.append("export:" + export["detail"])
    report["summary"] = {"pass": not errors, "errors": errors, "warnings": warnings}
    return report


def run(export_probe=True, objects=None, weld=0.0):
    """Check every scene mesh, armature and empty except cutters, `rbx_qa = "skip"` objects and
    bone display shapes. export_probe: export `objects` (default: every scene object except
    cutters) to a temp dir with the factory exporters, re-import and compare. weld: see
    mesh_checks; QA of an imported .glb/.gltf needs GLTF_WELD, which `check_file` sets."""
    bpy.context.view_layer.update()  # world matrices are stale after scripted transform edits
    report = {"file": bpy.data.filepath or None, "blender": bpy.app.version_string, "objects": []}
    shapes = _bone_shapes()
    with env.revealed(bpy.context.scene.objects):  # hidden objects still ship: evaluate them too
        for obj in sorted(bpy.context.scene.objects, key=lambda o: o.name):
            meta = env.get_meta(obj)
            if obj.get("rbx_cutter") or meta.get("qa") == "skip" or obj in shapes:
                continue
            if obj.type == "MESH":
                checks = mesh_checks(obj, meta, weld)
            elif obj.type == "ARMATURE":
                checks = armature_checks(obj, meta)
            elif obj.type == "EMPTY":
                checks = empty_checks(obj, meta)
            else:
                continue
            report["objects"].append({"name": obj.name, "type": obj.type, "category": meta.get("category"), "checks": checks})
    if export_probe:
        report["export"] = export_roundtrip_probe(objects)
    return summarize(report)


ASSET_SUFFIXES = (".blend", ".fbx", ".glb", ".gltf")


def check_file(path):
    """QA an asset file (the library form of `factory.py qa`). .blend: open it, check the scene
    and probe the set build_template ships (its Export collections, else every object except
    cutters). .fbx/.glb/.gltf: import into a clean scene and check what was imported, with glTF
    seams welded for the topology checks. Raises ValueError for other file types."""
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix not in ASSET_SUFFIXES:
        raise ValueError(f"unsupported asset file {path.name}: expected one of {', '.join(ASSET_SUFFIXES)}")
    if suffix == ".blend":
        bpy.ops.wm.open_mainfile(filepath=str(path))
        return run(export_probe=True, objects=env.export_objects() or None)
    env.reset()
    if suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    report = run(export_probe=False, weld=0.0 if suffix == ".fbx" else GLTF_WELD)
    report["file"] = str(path)
    return report


def scene_signature(objects=None):
    """Triangle count, world bounds and mesh names of exported meshes (for export/reimport
    diffing). objects: the export set, signed as the exporters write it (hidden members ship
    too); default every scene mesh except cutters."""
    tris, pts = 0, []
    # Importers add display-only meshes (e.g. glTF bone shapes); they are not exported geometry.
    shapes = _bone_shapes()
    pool = bpy.context.scene.objects if objects is None else objects
    meshes = [o for o in pool if o.type == "MESH" and o not in shapes and not o.get("rbx_cutter")]
    # Compare geometry in rest pose: animated exports are sampled at different frames.
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    previous = {a.name: a.data.pose_position for a in armatures}
    for a in armatures:
        a.data.pose_position = "REST"
    with env.revealed(meshes):  # evaluate hidden members (modifiers) as the exporters write them
        depsgraph = bpy.context.evaluated_depsgraph_get()
        for obj in meshes:
            ev = obj.evaluated_get(depsgraph)
            mesh = ev.to_mesh()
            tris += sum(len(p.vertices) - 2 for p in mesh.polygons)
            pts += [obj.matrix_world @ v.co for v in mesh.vertices]
            ev.to_mesh_clear()
    for a in armatures:
        a.data.pose_position = previous[a.name]
    names = sorted(o.name for o in meshes)
    if not pts:
        return {"tris": 0, "dims": [0, 0, 0], "min": [0, 0, 0], "meshes": names}
    mn = [min(p[i] for p in pts) for i in range(3)]
    mx = [max(p[i] for p in pts) for i in range(3)]
    return {"tris": tris, "dims": [round(mx[i] - mn[i], 3) for i in range(3)], "min": [round(v, 3) for v in mn], "meshes": names}


def _export_set(objects=None):
    """`objects`, or by default every scene object the exporters can select, except cutters."""
    if objects is not None:
        return list(objects)
    layer = bpy.context.view_layer
    layer.update()
    return [o for o in bpy.context.scene.objects if layer.objects.get(o.name) is o and not o.get("rbx_cutter")]


def _source(objects):
    return {"signature": scene_signature(objects), "animated": any(o.animation_data and o.animation_data.action for o in objects)}


def _reimport(paths, source):
    """Re-import each file in `paths` ({"fbx": path, "glb": path}) into a clean file and compare
    its triangles, bounds, mesh names and animation with `source`. Restores the open file."""
    tmp = Path(tempfile.mkdtemp(prefix="rbxqa_"))
    saved = tmp / "source.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(saved), copy=True)
    expected = source["signature"]
    keys = ("tris_match", "dims_match", "meshes_match", "animation_kept")
    results = {}
    try:
        for fmt, path in paths.items():
            env.reset()
            try:
                if fmt == "fbx":
                    bpy.ops.import_scene.fbx(filepath=str(path))
                else:
                    bpy.ops.import_scene.gltf(filepath=str(path))
            except Exception as exc:  # unreadable or missing file: a failed probe, not a crash
                results[fmt] = {"file": str(path), "import_error": str(exc).strip()[:300], **{k: False for k in keys}}
                continue
            sig = scene_signature()
            results[fmt] = {
                "file": str(path),
                "signature": sig,
                "tris_match": sig["tris"] == expected["tris"],
                "dims_match": all(abs(a - b) <= max(0.01, b * 0.01) for a, b in zip(sig["dims"], expected["dims"])),
                "meshes_match": sig["meshes"] == expected["meshes"],
                "missing_meshes": sorted(set(expected["meshes"]) - set(sig["meshes"])),
                "extra_meshes": sorted(set(sig["meshes"]) - set(expected["meshes"])),
                "actions": len(bpy.data.actions),
                "animation_kept": not source["animated"] or len(bpy.data.actions) > 0,
            }
    finally:
        bpy.ops.wm.open_mainfile(filepath=str(saved))
    failed = {}
    for fmt, r in results.items():
        problems = [k for k in keys if not r[k]]
        if problems:
            names = {k: r[k] for k in ("missing_meshes", "extra_meshes", "import_error") if r.get(k)}
            failed[fmt] = problems + ([names] if names else [])
    return {"pass": not failed and len(results) == len(paths), "source": expected, "formats": results, "detail": json.dumps(failed) if failed else ""}


def export_roundtrip_probe(objects=None):
    """Export `objects` (default: every scene object except cutters) as FBX + GLB to a temp dir
    with the factory exporters, re-import each into a clean file and compare with the source
    signature over the same set."""
    from . import ops

    objects = _export_set(objects)
    source = _source(objects)
    tmp = Path(tempfile.mkdtemp(prefix="rbxqa_"))
    paths = {"fbx": ops.export_fbx(tmp / "probe.fbx", objects), "glb": ops.export_glb(tmp / "probe.glb", objects)}
    return _reimport(paths, source)


def gated_export(objects, fbx_path, glb_path):
    """QA, then ship: write FBX + GLB of `objects` only when the checks have no errors, then
    re-import exactly those files and compare them with a signature over `objects`. On any
    error nothing is left at fbx_path/glb_path (stale files from earlier runs are removed
    first). Reopens a saved copy of the current file, so `objects` are invalid afterwards."""
    from . import ops

    paths = {"fbx": Path(fbx_path), "glb": Path(glb_path)}
    for path in paths.values():
        path.unlink(missing_ok=True)
    objects = list(objects)
    report = run(export_probe=False)
    if not objects:
        report["export"] = {"pass": False, "files": {}, "detail": "nothing to export: no objects in a <Kind>/Export collection (in the view layer)"}
        return summarize(report)
    if not report["summary"]["pass"]:
        report["export"] = {"pass": False, "files": {}, "detail": "blocked by QA errors; no FBX/GLB written"}
        return summarize(report)
    names = [o.name for o in objects]
    source = _source(objects)
    ops.export_fbx(paths["fbx"], objects)
    ops.export_glb(paths["glb"], objects)
    report["export"] = _reimport(paths, source)
    report["export"]["objects"] = names
    report["export"]["files"] = {fmt: str(path) for fmt, path in paths.items()}
    if not report["export"]["pass"]:
        for path in paths.values():
            path.unlink(missing_ok=True)
        report["export"]["files"] = {}
        report["export"]["detail"] = "shipped files do not match the export set, deleted: " + report["export"]["detail"]
    return summarize(report)
