"""Blender side of the Blender -> Roblox round trip.

Creates an asymmetric neutral marker asset (so scale, orientation and pivot errors are
visible), modifies it, materials it, saves, exports FBX + GLB, re-imports both and checks
them, then revises the source and proves the revision is detected. It writes
`roblox_expectation.json` per revision for packages/Pipeline/ImportInspector.luau, which
performs the Studio half (BLOCKED_EXTERNAL until run in Studio)."""
import json
from pathlib import Path

import bpy
from mathutils import Vector

from . import env, ops, qa

ASSET = "SM_RoundTripMarker"


def _build(revision):
    env.reset()
    exp = env.collection("RoundTrip/Export")
    body = ops.box("body", size=(4, 2, 6), coll=exp)
    ops.extrude(body, (0, 0, 1), 1.0 if revision == 1 else 2.0)  # modify: taller crown on v2
    nose = ops.box("nose", size=(1, 1.5 if revision == 1 else 2.5, 1), location=(0, -1.0 - (0.75 if revision == 1 else 1.25), 3), coll=exp)
    body_mat = ops.pbr_material("MAT_Body", (0.6, 0.6, 0.65, 1))
    nose_mat = ops.pbr_material("MAT_Front", (0.9, 0.3, 0.1, 1))
    ops.assign(body, body_mat)
    ops.assign(nose, nose_mat)
    if revision >= 2:
        ops.bevel(body, width=0.1, segments=1)
        ops.apply_modifiers(body)
    for o in (body, nose):
        ops.apply_transforms(o)
    obj = ops.join([body, nose], ASSET)
    ops.set_origin_base_center(obj)
    # Studio puts the imported model's pivot at the file origin, so the asset's origin must be there too.
    obj.location = (0, 0, 0)
    ops.box_uv(obj)
    env.set_meta(obj, category="test", revision=revision, front="-Y", pivot_expected="base-centre")
    return obj


def _front_centroid(obj, material_name):
    idx = [i for i, m in enumerate(obj.data.materials) if m and m.name.startswith(material_name)]
    pts = [obj.matrix_world @ obj.data.vertices[v].co for p in obj.data.polygons if p.material_index in idx for v in p.vertices]
    return sum(pts, Vector()) / len(pts) if pts else None


def _bounds(obj):
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    return [min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)]


def _surface_offsets(obj):
    """Area-weighted surface centroid minus bounds centre, along the declared front (-Y) and up (+Z).
    Intrinsic to the shape, so the Studio inspector compares it without assuming an axis mapping."""
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
    return round((mn[1] + mx[1]) / 2 - centroid.y, 3), round(centroid.z - (mn[2] + mx[2]) / 2, 3)


def _inspect_import(path):
    env.reset()
    if path.suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    obj = meshes[0]
    bpy.context.view_layer.update()
    sig = qa.scene_signature()
    front = _front_centroid(obj, "MAT_Front")
    mn, mx = _bounds(obj)
    return {
        "names": sorted(o.name for o in meshes),
        "materials": sorted(m.name for m in obj.data.materials if m),
        "signature": sig,
        "front_centroid": [round(v, 3) for v in front] if front else None,
        "origin": [round(v, 3) for v in obj.matrix_world.translation],
        "base_centre": [round((mn[0] + mx[0]) / 2, 3), round((mn[1] + mx[1]) / 2, 3), round(mn[2], 3)],
        "offsets": _surface_offsets(obj),
    }


def _expectation(sig, revision, offsets):
    dx, dy, dz = sig["dims"]
    return {
        "asset": ASSET,
        "revision": revision,
        "units": "studs (import with Scale Unit = Studs)",
        # Roblox axes: X = Blender X, Y(up) = Blender Z, Z(back) = -Blender Y
        "size": [dx, dz, dy],
        "front": "-Z",
        # Surface centroid minus bounds centre along front (-Y here, -Z in Roblox) and up, in studs.
        "front_offset": offsets[0],
        "up_offset": offsets[1],
        "pivot": "base-centre",
        "materials": ["MAT_Body", "MAT_Front"],
        "triangles": sig["tris"],
        "collision": "Box or Hull CollisionFidelity for props; PreciseConvexDecomposition only when gameplay needs it",
        "tolerance": 0.05,
    }


def run(out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {"asset": ASSET, "revisions": [], "pass": True, "studio": "BLOCKED_EXTERNAL: run packages/Pipeline/ImportInspector in Studio"}
    previous = None
    for revision in (1, 2):
        obj = _build(revision)
        source_qa = qa.run(export_probe=False)
        if not source_qa["summary"]["pass"]:
            # QA errors block export: leave nothing for Studio to import.
            for suffix in ("fbx", "glb"):
                (out_dir / f"{ASSET}_v{revision}.{suffix}").unlink(missing_ok=True)
            report["pass"] = False
            report["revisions"].append({"revision": revision, "pass": False, "source_qa": source_qa["summary"], "export": "blocked by source QA errors"})
            print(f"roundtrip v{revision} FAIL source QA: {source_qa['summary']['errors']}")
            break
        src_sig = qa.scene_signature()
        src_front = _front_centroid(obj, "MAT_Front")
        src_offsets = _surface_offsets(obj)
        blend = out_dir / f"{ASSET}_v{revision}.blend"
        bpy.ops.wm.save_as_mainfile(filepath=str(blend))
        fbx = ops.export_fbx(out_dir / f"{ASSET}_v{revision}.fbx")
        glb = ops.export_glb(out_dir / f"{ASSET}_v{revision}.glb")
        checks = []
        imports = {}
        for path in (fbx, glb):
            info = _inspect_import(Path(path))
            imports[Path(path).suffix[1:]] = info
            sig = info["signature"]
            checks += [
                {"name": f"{path.suffix}:geometry_tris", "pass": sig["tris"] == src_sig["tris"], "value": sig["tris"], "expected": src_sig["tris"]},
                {"name": f"{path.suffix}:scale_dims", "pass": all(abs(a - b) < 0.02 for a, b in zip(sig["dims"], src_sig["dims"])), "value": sig["dims"], "expected": src_sig["dims"]},
                {"name": f"{path.suffix}:pivot_base_centre", "pass": all(abs(o - b) < 0.02 for o, b in zip(info["origin"], info["base_centre"])), "value": info["origin"], "expected": info["base_centre"]},
                {"name": f"{path.suffix}:origin_at_world_origin", "pass": all(abs(o) < 0.02 for o in info["origin"]), "value": info["origin"], "expected": [0, 0, 0]},
                {"name": f"{path.suffix}:surface_offsets", "pass": all(abs(a - b) < 0.02 for a, b in zip(info["offsets"], src_offsets)), "value": info["offsets"], "expected": src_offsets},
                {"name": f"{path.suffix}:orientation_front", "pass": info["front_centroid"] is not None and info["front_centroid"][1] < -0.5, "value": info["front_centroid"], "expected": "y < 0 (front -Y)"},
                {"name": f"{path.suffix}:materials", "pass": all(any(m.startswith(n) for m in info["materials"]) for n in ("MAT_Body", "MAT_Front")), "value": info["materials"]},
                {"name": f"{path.suffix}:stable_name", "pass": ASSET in info["names"][0], "value": info["names"]},
            ]
        checks.append({"name": "front_asymmetric", "pass": abs(src_offsets[0]) >= 0.1, "value": src_offsets[0], "expected": ">= 0.1 so Studio can tell front from back"})
        if previous:
            checks.append({"name": "revision_detected", "pass": previous["tris"] != src_sig["tris"] or previous["dims"] != src_sig["dims"], "value": [previous, src_sig]})
        expectation = _expectation(src_sig, revision, src_offsets)
        (out_dir / f"roblox_expectation_v{revision}.json").write_text(json.dumps(expectation, indent=2))
        ok = source_qa["summary"]["pass"] and all(c["pass"] for c in checks)
        report["pass"] = report["pass"] and ok
        report["revisions"].append({"revision": revision, "pass": ok, "source_qa": source_qa["summary"], "source": src_sig, "front": [round(v, 3) for v in src_front], "checks": checks, "imports": imports, "expectation": expectation})
        previous = src_sig
        print(f"roundtrip v{revision} {'PASS' if ok else 'FAIL'} " + ", ".join(c["name"] for c in checks if not c["pass"]))
    (out_dir / "roundtrip-report.json").write_text(json.dumps(report, indent=2, default=str))
    return report
