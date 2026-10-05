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
    ops.box_uv(obj)
    env.set_meta(obj, category="test", revision=revision, front="-Y", pivot_expected="base-centre")
    return obj


def _front_centroid(obj, material_name):
    idx = [i for i, m in enumerate(obj.data.materials) if m and m.name.startswith(material_name)]
    pts = [obj.matrix_world @ obj.data.vertices[v].co for p in obj.data.polygons if p.material_index in idx for v in p.vertices]
    return sum(pts, Vector()) / len(pts) if pts else None


def _inspect_import(path):
    env.reset()
    if path.suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    obj = meshes[0]
    sig = qa.scene_signature()
    front = _front_centroid(obj, "MAT_Front")
    return {
        "names": sorted(o.name for o in meshes),
        "materials": sorted(m.name for m in obj.data.materials if m),
        "signature": sig,
        "front_centroid": [round(v, 3) for v in front] if front else None,
        "origin": [round(v, 3) for v in obj.matrix_world.translation],
    }


def _expectation(sig, revision):
    dx, dy, dz = sig["dims"]
    return {
        "asset": ASSET,
        "revision": revision,
        "units": "studs (import with Scale Unit = Studs)",
        # Roblox axes: X = Blender X, Y(up) = Blender Z, Z(back) = -Blender Y
        "size": [dx, dz, dy],
        "front": "-Z",
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
        src_sig = qa.scene_signature()
        src_front = _front_centroid(obj, "MAT_Front")
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
                {"name": f"{path.suffix}:pivot_base", "pass": abs(sig["min"][2]) < 0.02, "value": sig["min"][2], "expected": 0},
                {"name": f"{path.suffix}:orientation_front", "pass": info["front_centroid"] is not None and info["front_centroid"][1] < -0.5, "value": info["front_centroid"], "expected": "y < 0 (front -Y)"},
                {"name": f"{path.suffix}:materials", "pass": all(any(m.startswith(n) for m in info["materials"]) for n in ("MAT_Body", "MAT_Front")), "value": info["materials"]},
                {"name": f"{path.suffix}:stable_name", "pass": ASSET in info["names"][0], "value": info["names"]},
            ]
        if previous:
            checks.append({"name": "revision_detected", "pass": previous["tris"] != src_sig["tris"] or previous["dims"] != src_sig["dims"], "value": [previous, src_sig]})
        expectation = _expectation(src_sig, revision)
        (out_dir / f"roblox_expectation_v{revision}.json").write_text(json.dumps(expectation, indent=2))
        ok = source_qa["summary"]["pass"] and all(c["pass"] for c in checks)
        report["pass"] = report["pass"] and ok
        report["revisions"].append({"revision": revision, "pass": ok, "source_qa": source_qa["summary"], "source": src_sig, "front": [round(v, 3) for v in src_front], "checks": checks, "imports": imports, "expectation": expectation})
        previous = src_sig
        print(f"roundtrip v{revision} {'PASS' if ok else 'FAIL'} " + ", ".join(c["name"] for c in checks if not c["pass"]))
    (out_dir / "roundtrip-report.json").write_text(json.dumps(report, indent=2, default=str))
    return report
