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
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

from . import env

ROBLOX_MAX_TRIS = 20000
ROBLOX_MAX_INFLUENCES = 4
# glTF stores one vertex per corner attribute set, so imported .glb meshes are split along UV and
# normal seams. Welding exact duplicates restores the authored topology for the topology checks.
GLTF_WELD = 1e-5

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
    """World scale, so a scaled parent (Empty, armature) counts. Mirroring always reads negative."""
    m = obj.matrix_world
    scale = m.to_scale()
    if m.to_3x3().determinant() < 0 and min(scale) > 0:  # mathutils may return magnitudes only
        scale.x = -scale.x
    return tuple(round(s, 4) for s in scale)


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


def mesh_checks(obj, meta, weld=0.0):
    """weld > 0 merges vertices closer than `weld` on a copy before the topology and normals
    checks (use GLTF_WELD for glTF input); triangle counts always use the mesh as stored."""
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
    depsgraph = bpy.context.evaluated_depsgraph_get()
    bm.from_object(obj, depsgraph)
    bm.verts.ensure_lookup_table()
    tris = sum(len(f.verts) - 2 for f in bm.faces)
    checks.append(_check("triangles_roblox_limit", tris <= ROBLOX_MAX_TRIS, tris, ROBLOX_MAX_TRIS))
    checks.append(_check("triangles_budget", tris <= tri_budget, tris, tri_budget, level="warning", detail=category))

    if weld:
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=weld)
        bm.normal_update()
    welded = f"welded at {weld}" if weld else None
    non_manifold = sum(1 for e in bm.edges if not e.is_manifold and not e.is_boundary)
    boundary = sum(1 for e in bm.edges if e.is_boundary)
    checks.append(_check("non_manifold_edges", non_manifold == 0, non_manifold, 0, detail=welded))
    checks.append(_check("open_boundary_edges", boundary == 0 or meta.get("allow_open", False), boundary, 0, level="warning", detail="watertight preferred for Roblox collision"))
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-6)
    checks.append(_check("degenerate_faces", degenerate == 0, degenerate, 0, detail=welded))
    loose = sum(1 for v in bm.verts if not v.link_edges)
    checks.append(_check("loose_vertices", loose == 0, loose, 0, detail=welded))

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
    bone display shapes. export_probe: export `objects` (default: the whole scene) to a temp dir
    with the factory exporters, re-import and compare. weld: see mesh_checks."""
    bpy.context.view_layer.update()  # world matrices are stale after scripted transform edits
    report = {"file": bpy.data.filepath or None, "blender": bpy.app.version_string, "objects": []}
    shapes = _bone_shapes()
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


def scene_signature(objects=None):
    """Triangle count, world bounds and mesh names of exportable meshes (for export/reimport
    diffing). objects: restrict to this set (the shipped export set); default every scene mesh."""
    tris, pts = 0, []
    # Importers add display-only meshes (e.g. glTF bone shapes); they are not exported geometry.
    shapes = _bone_shapes()
    pool = bpy.context.scene.objects if objects is None else objects
    meshes = [o for o in pool if o.type == "MESH" and o not in shapes and not o.get("rbx_cutter") and not o.hide_render]
    # Compare geometry in rest pose: animated exports are sampled at different frames.
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    previous = {a.name: a.data.pose_position for a in armatures}
    for a in armatures:
        a.data.pose_position = "REST"
    bpy.context.view_layer.update()
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


def _source(objects):
    pool = bpy.context.scene.objects if objects is None else objects
    return {"signature": scene_signature(objects), "animated": any(o.animation_data and o.animation_data.action for o in pool)}


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
                "actions": len(bpy.data.actions),
                "animation_kept": not source["animated"] or len(bpy.data.actions) > 0,
            }
    finally:
        bpy.ops.wm.open_mainfile(filepath=str(saved))
    failed = {fmt: [k for k in keys if not r[k]] for fmt, r in results.items() if not all(r[k] for k in keys)}
    return {"pass": not failed and len(results) == len(paths), "source": expected, "formats": results, "detail": json.dumps(failed) if failed else ""}


def export_roundtrip_probe(objects=None):
    """Export `objects` (default: the whole scene) as FBX + GLB to a temp dir with the factory
    exporters, re-import each into a clean file and compare with the source signature."""
    from . import ops

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
        report["export"] = {"pass": False, "files": {}, "detail": "nothing to export: no objects in a <Kind>/Export collection"}
        return summarize(report)
    if not report["summary"]["pass"]:
        report["export"] = {"pass": False, "files": {}, "detail": "blocked by QA errors; no FBX/GLB written"}
        return summarize(report)
    source = _source(objects)
    ops.export_fbx(paths["fbx"], objects)
    ops.export_glb(paths["glb"], objects)
    report["export"] = _reimport(paths, source)
    report["export"]["files"] = {fmt: str(path) for fmt, path in paths.items()}
    if not report["export"]["pass"]:
        for path in paths.values():
            path.unlink(missing_ok=True)
        report["export"]["files"] = {}
        report["export"]["detail"] = "shipped files do not match the export set, deleted: " + report["export"]["detail"]
    return summarize(report)
