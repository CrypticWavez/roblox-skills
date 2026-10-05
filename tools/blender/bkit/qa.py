"""Asset quality gate. Produces a machine-readable report for a .blend scene or imported
FBX/GLB. Error-level failures block export; warnings need a human decision.

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


def mesh_checks(obj, meta):
    checks = []
    mesh = obj.data
    category = meta.get("category", "test")
    tri_budget, mat_budget = BUDGETS.get(category, BUDGETS["test"])
    if isinstance(meta.get("budget"), dict):
        tri_budget = meta["budget"].get("tris", tri_budget)
        mat_budget = meta["budget"].get("materials", mat_budget)

    # Transforms: export expects applied rotation/scale on meshes.
    scale = tuple(round(s, 4) for s in obj.scale)
    checks.append(_check("transform_scale_applied", all(abs(s - 1) < 1e-4 for s in obj.scale), scale, (1, 1, 1)))
    rot = tuple(round(math.degrees(r), 2) for r in obj.rotation_euler)
    checks.append(_check("transform_rotation_applied", obj.parent is not None or all(abs(r) < 0.01 for r in rot), rot, (0, 0, 0), level="warning"))

    bm = bmesh.new()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    bm.from_object(obj, depsgraph)
    bm.verts.ensure_lookup_table()
    tris = sum(len(f.verts) - 2 for f in bm.faces)
    checks.append(_check("triangles_roblox_limit", tris <= ROBLOX_MAX_TRIS, tris, ROBLOX_MAX_TRIS))
    checks.append(_check("triangles_budget", tris <= tri_budget, tris, tri_budget, level="warning", detail=category))

    non_manifold = sum(1 for e in bm.edges if not e.is_manifold and not e.is_boundary)
    boundary = sum(1 for e in bm.edges if e.is_boundary)
    checks.append(_check("non_manifold_edges", non_manifold == 0, non_manifold, 0))
    checks.append(_check("open_boundary_edges", boundary == 0 or meta.get("allow_open", False), boundary, 0, level="warning", detail="watertight preferred for Roblox collision"))
    degenerate = sum(1 for f in bm.faces if f.calc_area() < 1e-6)
    checks.append(_check("degenerate_faces", degenerate == 0, degenerate, 0))
    loose = sum(1 for v in bm.verts if not v.link_edges)
    checks.append(_check("loose_vertices", loose == 0, loose, 0))

    # Normals: compare against a recalculated copy; flipped faces count.
    copy = bm.copy()
    before = [f.normal.copy() for f in copy.faces]
    bmesh.ops.recalc_face_normals(copy, faces=copy.faces)
    flipped = sum(1 for f, n in zip(copy.faces, before) if f.normal.dot(n) < 0)
    copy.free()
    checks.append(_check("normals_consistent", flipped == 0, flipped, 0))
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

    # Skinning
    arm_mod = next((m for m in obj.modifiers if m.type == "ARMATURE"), None)
    if arm_mod or meta.get("rigged"):
        over = sum(1 for v in mesh.vertices if len([g for g in v.groups if g.weight > 1e-4]) > ROBLOX_MAX_INFLUENCES)
        unweighted = sum(1 for v in mesh.vertices if not any(g.weight > 1e-4 for g in v.groups))
        checks.append(_check("bone_influences", over == 0, over, ROBLOX_MAX_INFLUENCES))
        checks.append(_check("unweighted_vertices", unweighted == 0, unweighted, 0))
        checks.append(_check("armature_bound", arm_mod is not None and arm_mod.object is not None, bool(arm_mod), True))
    return checks


def armature_checks(obj, meta):
    checks = []
    bones = obj.data.bones
    checks.append(_check("bone_count", 0 < len(bones) <= 200, len(bones), "1..200"))
    expected = meta.get("bone_names")
    if expected:
        missing = [b for b in expected if b not in bones]
        checks.append(_check("bone_names", not missing, len(missing), 0, detail=", ".join(missing[:8])))
    checks.append(_check("armature_scale_applied", all(abs(s - 1) < 1e-4 for s in obj.scale), [round(s, 4) for s in obj.scale], (1, 1, 1)))
    action = obj.animation_data.action if obj.animation_data else None
    if meta.get("animated") or action:
        frames = 0
        if action:
            frames = int(action.frame_range[1] - action.frame_range[0])
        checks.append(_check("animation_clip", action is not None and frames > 0, frames, ">0"))
    return checks


def run(export_probe=True):
    report = {"file": bpy.data.filepath or None, "blender": bpy.app.version_string, "objects": []}
    for obj in sorted(bpy.context.scene.objects, key=lambda o: o.name):
        meta = env.get_meta(obj)
        if obj.get("rbx_cutter") or meta.get("qa") == "skip":
            continue
        if obj.type == "MESH":
            checks = mesh_checks(obj, meta)
        elif obj.type == "ARMATURE":
            checks = armature_checks(obj, meta)
        else:
            continue
        report["objects"].append({"name": obj.name, "type": obj.type, "category": meta.get("category"), "checks": checks})
    if export_probe:
        report["export"] = export_roundtrip_probe()
    errors = [f"{o['name']}:{c['name']}" for o in report["objects"] for c in o["checks"] if not c["pass"] and c["level"] == "error"]
    warnings = [f"{o['name']}:{c['name']}" for o in report["objects"] for c in o["checks"] if not c["pass"] and c["level"] == "warning"]
    if export_probe and not report["export"]["pass"]:
        errors.append("export:" + report["export"]["detail"])
    report["summary"] = {"pass": not errors, "errors": errors, "warnings": warnings}
    return report


def scene_signature():
    """Triangle count and world bounds of all exportable meshes (for export/reimport diffing)."""
    tris, pts = 0, []
    depsgraph = bpy.context.evaluated_depsgraph_get()
    # Importers add display-only meshes (e.g. glTF bone shapes); they are not exported geometry.
    shapes = {pb.custom_shape for o in bpy.context.scene.objects if o.type == "ARMATURE" for pb in o.pose.bones if pb.custom_shape}
    # Compare geometry in rest pose: animated exports are sampled at different frames.
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    previous = {a.name: a.data.pose_position for a in armatures}
    for a in armatures:
        a.data.pose_position = "REST"
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in bpy.context.scene.objects:
        if obj.type == "MESH" and obj not in shapes and not obj.get("rbx_cutter") and not obj.hide_render:
            ev = obj.evaluated_get(depsgraph)
            mesh = ev.to_mesh()
            tris += sum(len(p.vertices) - 2 for p in mesh.polygons)
            pts += [obj.matrix_world @ v.co for v in mesh.vertices]
            ev.to_mesh_clear()
    for a in armatures:
        a.data.pose_position = previous[a.name]
    if not pts:
        return {"tris": 0, "dims": [0, 0, 0], "min": [0, 0, 0]}
    mn = [min(p[i] for p in pts) for i in range(3)]
    mx = [max(p[i] for p in pts) for i in range(3)]
    return {"tris": tris, "dims": [round(mx[i] - mn[i], 3) for i in range(3)], "min": [round(v, 3) for v in mn]}


def export_roundtrip_probe():
    """Export FBX + GLB to a temp dir, re-import each into a clean file and compare triangle
    counts and bounds with the source. Restores the original file afterwards."""
    from . import ops

    source = scene_signature()
    source_actions = len(bpy.data.actions)
    tmp = Path(tempfile.mkdtemp(prefix="rbxqa_"))
    saved = tmp / "source.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(saved), copy=True)
    results = {}
    try:
        ops.export_fbx(tmp / "probe.fbx")
        ops.export_glb(tmp / "probe.glb")
        for fmt in ("fbx", "glb"):
            env.reset()
            if fmt == "fbx":
                bpy.ops.import_scene.fbx(filepath=str(tmp / "probe.fbx"))
            else:
                bpy.ops.import_scene.gltf(filepath=str(tmp / "probe.glb"))
            sig = scene_signature()
            dims_ok = all(abs(a - b) <= max(0.01, b * 0.01) for a, b in zip(sig["dims"], source["dims"]))
            anim_ok = source_actions == 0 or len(bpy.data.actions) > 0
            results[fmt] = {"signature": sig, "tris_match": sig["tris"] == source["tris"], "dims_match": dims_ok, "actions": len(bpy.data.actions), "animation_kept": anim_ok}
    finally:
        bpy.ops.wm.open_mainfile(filepath=str(saved))
    ok = all(r["tris_match"] and r["dims_match"] and r["animation_kept"] for r in results.values())
    detail = "" if ok else json.dumps({k: (v["tris_match"], v["dims_match"], v["animation_kept"]) for k, v in results.items()})
    return {"pass": ok, "source": source, "formats": results, "detail": detail}
