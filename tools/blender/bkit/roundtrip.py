"""Blender side of the Blender -> Roblox round trip.

Creates an asymmetric neutral marker asset (so scale, orientation, handedness and pivot errors are
visible): a body, an orange nose on the front (-Y) and, since 2026-10-06, a blue side fin on +X so
the next Studio import measures the X mapping (`side_offset`; bkit/expectation.py derives Roblox
x = -Blender x but the 2026-10-05 import could not observe it). The three flat colours are baked
into a palette atlas (`<asset>_vN_Color.png`, one material, a `Color` attribute fallback) because
Studio drops plain material colours (gap B06). It saves, exports FBX + GLB, re-imports both and
checks geometry, pivot, offsets, facing, side and appearance (one material, colour map, colour
attribute, and the nose and fin faces still sample orange and blue through their UVs), then
revises the source and proves the revision is detected. It writes `roblox_expectation_v1.json` and
`roblox_expectation_v2.json` (with the appearance block and side_offset) for
packages/Pipeline/ImportInspector.luau, which performs the Studio half (tests/engine/
import_appearance.luau; BLOCKED_EXTERNAL until run in Studio)."""
import json
from pathlib import Path

import bpy
from mathutils import Color, Vector

from . import bake, env, expectation, ops, qa, textures

ASSET = "SM_RoundTripMarker"
REVISIONS = (1, 2)
SRGB = {"MAT_Body": (0.6, 0.6, 0.65), "MAT_Front": (0.95, 0.45, 0.1), "MAT_Side": (0.15, 0.4, 0.9)}


def _srgb8(name):
    return tuple(int(round(c * 255)) for c in SRGB[name])


def _material(name):
    linear = Color(SRGB[name]).from_srgb_to_scene_linear()
    return ops.pbr_material(name, (*linear, 1.0))


def _build(revision, out_dir):
    env.reset()
    exp = env.collection("RoundTrip/Export")
    body = ops.box("body", size=(4, 2, 6), coll=exp)
    ops.extrude(body, (0, 0, 1), 1.0 if revision == 1 else 2.0)  # modify: taller crown on v2
    nose = ops.box("nose", size=(1, 1.5 if revision == 1 else 2.5, 1), location=(0, -1.0 - (0.75 if revision == 1 else 1.25), 3), coll=exp)
    fin = ops.box("fin", size=(0.6, 1.0, 1.2), location=(2.3, 0, 4.0), coll=exp)  # +X side: handedness
    ops.assign(body, _material("MAT_Body"))
    ops.assign(nose, _material("MAT_Front"))
    ops.assign(fin, _material("MAT_Side"))
    if revision >= 2:
        ops.bevel(body, width=0.1, segments=1)
        ops.apply_modifiers(body)
    for o in (body, nose, fin):
        ops.apply_transforms(o)
    obj = ops.join([body, nose, fin], ASSET)
    ops.set_origin_base_center(obj)
    # Studio puts the imported model's pivot at the file origin, so the asset's origin must be there too.
    obj.location = (0, 0, 0)
    ops.box_uv(obj)
    env.set_meta(obj, category="test", revision=revision, front="-Y", pivot_expected="base-centre")
    bpy.context.view_layer.update()
    look = bake.palette_atlas([obj], out_dir, f"{ASSET}_v{revision}")
    return obj, look


def _faces_coloured(obj, color_png, srgb, tol=8):
    """World-space centroid of the faces whose UV centre samples `srgb` in the colour map, and how
    many there are: the colour reached those faces through their UVs."""
    uv = obj.data.uv_layers.active.data if obj.data.uv_layers else None
    if uv is None:
        return None, 0
    pts, faces = [], 0
    for poly in obj.data.polygons:
        centre = sum((Vector(uv[li].uv) for li in poly.loop_indices), Vector((0, 0))) / len(poly.loop_indices)
        got = bake.sample_map(color_png, centre)
        if all(abs(a - b) <= tol for a, b in zip(got, srgb)):
            faces += 1
            pts += [obj.matrix_world @ obj.data.vertices[v].co for v in poly.vertices]
    return (sum(pts, Vector()) / len(pts) if pts else None), faces


def _bounds(obj):
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    return [min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)]


def _surface_offsets(obj):
    """Area-weighted surface centroid minus bounds centre along the declared front (-Y), up (+Z)
    and +X, in Blender axes. Intrinsic to the shape, so the Studio inspector compares it without
    assuming an axis mapping (front, up) or with the derived one (side)."""
    bpy.context.view_layer.update()
    mesh = obj.data
    mesh.calc_loop_triangles()
    pts = [obj.matrix_world @ v.co for v in mesh.vertices]
    mn, mx = _bounds(obj)
    total, acc = 0.0, Vector()
    for tri in mesh.loop_triangles:
        a, b, c = (pts[i] for i in tri.vertices)
        area = (b - a).cross(c - a).length / 2
        total += area
        acc += area * (a + b + c) / 3
    centroid = acc / total
    return (round((mn[1] + mx[1]) / 2 - centroid.y, 3), round(centroid.z - (mn[2] + mx[2]) / 2, 3), round(centroid.x - (mn[0] + mx[0]) / 2, 3))


def _inspect_import(path, color_png):
    env.reset()
    if path.suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    obj = meshes[0]
    bpy.context.view_layer.update()
    sig = qa.scene_signature()
    front, front_faces = _faces_coloured(obj, color_png, _srgb8("MAT_Front"))
    side, side_faces = _faces_coloured(obj, color_png, _srgb8("MAT_Side"))
    mn, mx = _bounds(obj)
    mats = [m for m in obj.data.materials if m]
    roles = {r for m in mats for rs in textures.image_roles(m).values() for r in rs}
    return {
        "names": sorted(o.name for o in meshes),
        "materials": sorted(m.name for m in mats),
        "map_roles": sorted(roles),
        "color_attributes": sorted(a.name for a in obj.data.color_attributes),
        "signature": sig,
        "front_centroid": [round(v, 3) for v in front] if front else None,
        "front_faces": front_faces,
        "side_centroid": [round(v, 3) for v in side] if side else None,
        "side_faces": side_faces,
        "origin": [round(v, 3) for v in obj.matrix_world.translation],
        "base_centre": [round((mn[0] + mx[0]) / 2, 3), round((mn[1] + mx[1]) / 2, 3), round(mn[2], 3)],
        "offsets": _surface_offsets(obj),
    }


COLLISION = "Box or Hull CollisionFidelity for props; PreciseConvexDecomposition only when gameplay needs it"


def _clean(out_dir):
    """A failing run must not leave an earlier run's exports, maps, sources or expectations (for
    any revision) next to its report for Studio to pick up."""
    for revision in REVISIONS:
        stem = f"{ASSET}_v{revision}"
        for path in list(out_dir.glob(f"{stem}.*")) + list(out_dir.glob(f"{stem}_*")) + [out_dir / f"roblox_expectation_v{revision}.json"]:
            path.unlink(missing_ok=True)
    (out_dir / "roundtrip-report.json").unlink(missing_ok=True)


def run(out_dir):
    out_dir = Path(out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    _clean(out_dir)
    report = {"asset": ASSET, "revisions": [], "pass": True, "studio": "BLOCKED_EXTERNAL: run tests/engine/import_appearance.luau (Pipeline/ImportInspector) in Studio"}
    previous = None
    for revision in REVISIONS:
        obj, look = _build(revision, out_dir)
        source_qa = qa.run(export_probe=False)
        if not source_qa["summary"]["pass"]:
            # QA errors block export: nothing is written for this or any later revision.
            report["pass"] = False
            report["revisions"].append({"revision": revision, "pass": False, "source_qa": source_qa["summary"], "export": "blocked by source QA errors"})
            print(f"roundtrip v{revision} FAIL source QA: {source_qa['summary']['errors']}")
            break
        color_png = Path(look["files"]["color"])
        src_sig = qa.scene_signature()
        src_front, _ = _faces_coloured(obj, color_png, _srgb8("MAT_Front"))
        src_side, _ = _faces_coloured(obj, color_png, _srgb8("MAT_Side"))
        src_offsets = _surface_offsets(obj)
        exp = expectation.expectation(ASSET, [obj], revision=revision, extra={"collision": COLLISION})
        blend = out_dir / f"{ASSET}_v{revision}.blend"
        bpy.ops.wm.save_as_mainfile(filepath=str(blend))
        bpy.ops.file.make_paths_relative()
        bpy.ops.wm.save_mainfile()
        Path(str(blend) + "1").unlink(missing_ok=True)
        fbx = ops.export_fbx(out_dir / f"{ASSET}_v{revision}.fbx")
        glb = ops.export_glb(out_dir / f"{ASSET}_v{revision}.glb")
        checks = []
        imports = {}
        for path in (fbx, glb):
            info = _inspect_import(Path(path), color_png)
            imports[Path(path).suffix[1:]] = info
            sig = info["signature"]
            s = path.suffix
            checks += [
                {"name": f"{s}:geometry_tris", "pass": sig["tris"] == src_sig["tris"], "value": sig["tris"], "expected": src_sig["tris"]},
                {"name": f"{s}:scale_dims", "pass": all(abs(a - b) < 0.02 for a, b in zip(sig["dims"], src_sig["dims"])), "value": sig["dims"], "expected": src_sig["dims"]},
                {"name": f"{s}:pivot_base_centre", "pass": all(abs(o - b) < 0.02 for o, b in zip(info["origin"], info["base_centre"])), "value": info["origin"], "expected": info["base_centre"]},
                {"name": f"{s}:origin_at_world_origin", "pass": all(abs(o) < 0.02 for o in info["origin"]), "value": info["origin"], "expected": [0, 0, 0]},
                {"name": f"{s}:surface_offsets", "pass": all(abs(a - b) < 0.02 for a, b in zip(info["offsets"], src_offsets)), "value": info["offsets"], "expected": src_offsets},
                {"name": f"{s}:orientation_front", "pass": info["front_centroid"] is not None and info["front_centroid"][1] < -0.5, "value": info["front_centroid"], "expected": "orange faces at y < 0 (front -Y)"},
                {"name": f"{s}:orientation_side", "pass": info["side_centroid"] is not None and info["side_centroid"][0] > 0.5, "value": info["side_centroid"], "expected": "blue fin faces at x > 0 (+X)"},
                {"name": f"{s}:appearance_one_material", "pass": len(info["materials"]) == 1, "value": info["materials"]},
                {"name": f"{s}:appearance_color_map", "pass": "color" in info["map_roles"], "value": info["map_roles"], "expected": "colour map wired to Base Color"},
                {"name": f"{s}:appearance_color_attribute", "pass": bool(info["color_attributes"]), "value": info["color_attributes"], "expected": "vertex-colour fallback kept"},
                {"name": f"{s}:stable_name", "pass": ASSET in info["names"][0], "value": info["names"]},
            ]
        checks.append({"name": "front_asymmetric", "pass": abs(src_offsets[0]) >= 0.1, "value": src_offsets[0], "expected": ">= 0.1 so Studio can tell front from back"})
        checks.append({"name": "side_asymmetric", "pass": abs(exp["side_offset"]) >= 0.1, "value": exp["side_offset"], "expected": ">= 0.1 so Studio can tell a mirrored X"})
        checks.append({"name": "appearance_baked", "pass": look["kind"] == "palette_atlas" and look["palette"] == 3, "value": {k: look[k] for k in ("kind", "palette", "maps")}})
        if previous:
            checks.append({"name": "revision_detected", "pass": previous["tris"] != src_sig["tris"] or previous["dims"] != src_sig["dims"], "value": [previous, src_sig]})
        (out_dir / f"roblox_expectation_v{revision}.json").write_text(json.dumps(exp, indent=2))
        ok = source_qa["summary"]["pass"] and all(c["pass"] for c in checks)
        report["pass"] = report["pass"] and ok
        report["revisions"].append({
            "revision": revision, "pass": ok, "source_qa": source_qa["summary"], "source": src_sig,
            "front": [round(v, 3) for v in src_front] if src_front else None, "side": [round(v, 3) for v in src_side] if src_side else None,
            "checks": checks, "imports": imports, "expectation": exp,
        })
        previous = src_sig
        print(f"roundtrip v{revision} {'PASS' if ok else 'FAIL'} " + ", ".join(c["name"] for c in checks if not c["pass"]))
    (out_dir / "roundtrip-report.json").write_text(json.dumps(report, indent=2, default=str))
    return report
