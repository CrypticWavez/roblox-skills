"""`factory.py intake`: bring a third-party static model (CC0 download, FBX/GLB/glTF) into the
factory's conventions and emit a kit/1 entry for it. Offline: the file must already be on disk
(fetching is G9b's asset tooling; this never touches the network).

Steps, each recorded in `<out>/<key>/intake-report.json`:
1. structure: tools/gltf_validate.py on .glb/.gltf (errors stop the intake);
2. raw QA: bkit QA of the import as it arrived (informational: downloads usually fail the pivot,
   transform and appearance rules, which is why step 3 exists);
3. normalise: bake every object transform into its mesh, drop empties and other helpers, join
   into one `SM_<Key>`, scale to `--height` studs (or by `--scale`), weld by distance, recompute
   outward normals, clear imported custom normals and smooth by angle, base-centre pivot at the
   world origin, one UV set;
4. look: flat materials -> palette atlas (bake.palette_atlas, box UVs first); any image or node
   input -> Cycles bake_maps onto a fresh atlas layout (`--bake maps`), vertex colours on request;
5. gated export: `.blend`, then FBX + GLB only when QA has no errors, re-imported and compared;
   the shipped GLB is validated again and both files get `qa.check_file`;
6. kit/1: `<key>_kit.json` (one piece, file relative to it), previews before and after.
Rigged or skinned models are refused (use the rig workflow and `r15` profiles)."""
import shutil
import sys
from pathlib import Path

import bmesh
import bpy

from . import bake, build, env, expectation, formats, ops, qa, render

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools/, for gltf_validate
import gltf_validate  # noqa: E402

ROUTES = ("auto", "palette", "vertex", "maps")


def _pascal(key):
    return "".join(part.capitalize() for part in key.split("_"))


def _import(path):
    suffix = path.suffix.lower()
    env.reset()
    if suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path), anim_offset=0.0)
    elif suffix in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=str(path))
    else:
        raise ValueError(f"intake: unsupported file {path.name} (FBX, GLB or glTF)")
    bpy.context.view_layer.update()


def _flat(mat):
    try:
        bake.flat_values(mat)
        return True
    except ValueError:
        return False


def _has_input(mats, name):
    for mat in mats:
        bsdf = ops.principled(mat, create=False) if mat is not None else None
        socket = bsdf.inputs.get(name) if bsdf is not None else None
        if socket is not None and socket.is_linked:
            return True
    return False


def _emits(mats):
    for mat in mats:
        try:
            values = bake.flat_values(mat)
        except ValueError:
            bsdf = ops.principled(mat, create=False)
            strength = bsdf.inputs.get("Emission Strength") if bsdf is not None else None
            if strength is not None and (strength.is_linked or strength.default_value > 0) and _has_input([mat], "Emission Color"):
                return True
            continue
        if max(values["emission"]) > 0:
            return True
    return False


def normalise(key, height=None, scale=None, weld=1e-4):
    """Steps 3 of the module docstring on the current scene. Returns (object, facts)."""
    shapes = qa._bone_shapes()
    if any(o.type == "ARMATURE" for o in bpy.context.scene.objects):
        raise ValueError("rigged model: intake handles static props only (rig workflow: bkit r15 profiles and clips)")
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH" and o not in shapes]
    if not meshes:
        raise ValueError("no meshes in the file")
    bpy.context.view_layer.update()
    raw_objects = len(bpy.context.scene.objects)
    for obj in meshes:
        if obj.data.users > 1:
            obj.data = obj.data.copy()
        if obj.modifiers:
            ops.apply_modifiers(obj)
        world = obj.matrix_world.copy()
        obj.parent = None
        obj.data.transform(world)
        if world.determinant() < 0:
            obj.data.flip_normals()  # a mirrored transform turns faces inside out
        obj.matrix_world.identity()
    for obj in [o for o in bpy.context.scene.objects if o not in meshes]:
        bpy.data.objects.remove(obj)
    obj = ops.join(sorted(meshes, key=lambda o: o.name), f"SM_{_pascal(key)}")
    mesh = obj.data
    zs = [v.co.z for v in mesh.vertices]
    raw_height = max(zs) - min(zs)
    if raw_height <= 0:
        raise ValueError("model has no height")
    factor = (height / raw_height) if height else (scale or 1.0)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.scale(bm, vec=(factor, factor, factor), verts=bm.verts)
    merged = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=weld)
    merged -= len(bm.verts)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    if getattr(mesh, "has_custom_normals", False):
        with bpy.context.temp_override(object=obj, active_object=obj):
            bpy.ops.mesh.customdata_custom_splitnormals_clear()
    ops.shade_smooth(obj, angle=30)
    ops.set_origin_base_center(obj)
    obj.location = (0, 0, 0)
    bpy.context.view_layer.update()
    root = env.collection(key)
    export = env.collection(f"{key}/Export", root)
    for coll in list(obj.users_collection):
        coll.objects.unlink(obj)
    export.objects.link(obj)
    facts = {"raw_objects": raw_objects, "raw_meshes": len(meshes), "raw_height": round(raw_height, 4), "scale": round(factor, 6), "welded_vertices": merged,
             "triangles": ops.triangles(obj), "materials": [m.name for m in mesh.materials if m is not None]}
    return obj, facts


def look(obj, out, key, route="auto", size=1024):
    """Step 4: returns the appearance record."""
    mats = [m for m in obj.data.materials if m is not None]
    if not mats:
        mat = ops.pbr_material(f"MAT_{key}_Default", (0.8, 0.8, 0.8, 1))
        ops.assign(obj, mat)
        mats = [mat]
    flat = all(_flat(m) for m in mats)
    if route == "auto":
        route = "palette" if flat else "maps"
    if route in ("palette", "vertex") and not flat:
        raise ValueError(f"{route}: textured or node-driven materials need --bake maps")
    if route == "palette":
        for layer in list(obj.data.uv_layers):
            obj.data.uv_layers.remove(layer)
        ops.box_uv(obj)  # UVs only pick the palette cell; box UVs are never degenerate
        return bake.palette_atlas([obj], out, key)
    if route == "vertex":
        return bake.vertex_colors([obj], key)
    if not obj.data.uv_layers:
        ops.box_uv(obj)
    maps = ["color", "roughness", "metalness"]
    if _has_input(mats, "Normal"):
        maps.append("normal")
    if _emits(mats):
        maps.append("emissive")
    return bake.bake_maps(obj, out, key, maps=tuple(maps), size=size)


def kit_entry(obj, key, source, provenance, collision="box"):
    m = expectation.measure([obj])
    appearance = env.get_meta(obj).get("appearance") or {}
    if appearance.get("kind") in ("palette_atlas", "baked"):
        materials = [f"atlas:{appearance['maps']['color']}"]
    elif appearance.get("kind") == "vertex_colors":
        materials = ["vertex_color"]
    else:
        materials = ["builtin:SmoothPlastic"]
    return {
        "key": key,
        "source": source,
        "file": f"{key}.glb",
        "bounds": {"min": m["min"], "max": m["max"]},
        "pivot": "base_center",
        "materials": materials,
        "provenance": provenance,
        "collision": collision,
        "triangles": m["triangles"],
    }


def run(file, out_dir, key, height=None, scale=None, source=None, provenance=None, category="prop", route="auto", size=1024, previews=True):
    """Intake `file` into `<out_dir>/<key>/`. Returns {pass, kit, problems, report, files}."""
    file = Path(file)
    out = Path(out_dir).resolve() / key
    problems = []
    report = {"file": file.name, "key": key, "blender": bpy.app.version_string, "steps": {}}
    result = {"pass": False, "kit": None, "problems": problems, "report": str(out / "intake-report.json"), "files": {}}

    def finish():
        report["problems"] = problems
        report["pass"] = result["pass"] = not problems
        build.write_json(out / "intake-report.json", report)
        return result

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if not formats.LABEL.match(key or ""):
        problems.append(f"key {key!r} must be a label (lower_snake)")
    if source is None:
        problems.append("give --source cc0:<asset-sources key>:<item id> (kit/1 provenance)")
    elif not formats.SOURCE.match(source) or not source.startswith("cc0:"):
        problems.append(f"source {source!r} must be cc0:<asset-sources key>:<item id>")
    if route not in ROUTES:
        problems.append(f"bake route must be one of {', '.join(ROUTES)}")
    if height is not None and scale is not None:
        problems.append("give --height or --scale, not both")
    if not file.is_file():
        problems.append(f"{file} not found")
    if problems:
        return finish()
    provenance = provenance or source.split(":")[1]
    suffix = file.suffix.lower()
    if suffix in (".glb", ".gltf"):
        structure = gltf_validate.validate_file(file)
        report["steps"]["structure"] = {k: structure[k] for k in ("pass", "errors", "warnings", "info")}
        if not structure["pass"]:
            problems += [f"structure: {e['code']} {e['path']}: {e['message']}" for e in structure["errors"][:10]]
            return finish()
    else:
        report["steps"]["structure"] = {"pass": None, "detail": "not checked: FBX has no structural validator here"}
    try:
        _import(file)
    except (RuntimeError, ValueError) as exc:
        problems.append(f"import: {str(exc).strip()[:300]}")
        return finish()
    raw = qa.run(export_probe=False, weld=0.0 if suffix == ".fbx" else qa.GLTF_WELD, imported=suffix)
    report["steps"]["raw_qa"] = raw["summary"]
    if previews:
        shown = [o for o in bpy.context.scene.objects if o.type == "MESH"]
        render.setup_stage(ground=True, size=200)
        report["steps"]["raw_previews"] = render.render_objects(shown, out, f"{key}.raw", angles=("three-quarter",), resolution=(480, 360), samples=8)
        _import(file)
    try:
        obj, facts = normalise(key, height=height, scale=scale)
        report["steps"]["normalise"] = facts
        env.set_meta(obj, category=category, intake={"source": source, "provenance": provenance, "file": file.name, "scale": facts["scale"]})
        appearance = look(obj, out, key, route=route, size=size)
        report["steps"]["look"] = {k: v for k, v in appearance.items() if k not in ("files", "cells")}
    except (RuntimeError, ValueError) as exc:
        problems.append(f"normalise: {exc}")
        return finish()
    blend = out / f"{key}.blend"
    build.save_blend(blend)
    gated = qa.gated_export(env.export_objects(), out / f"{key}.fbx", out / f"{key}.glb")
    report["steps"]["qa"] = gated["summary"]
    if not gated["summary"]["pass"]:
        problems += [f"qa: {e}" for e in gated["summary"]["errors"][:10]]
        return finish()
    shipped = gltf_validate.validate_file(out / f"{key}.glb")
    report["steps"]["shipped_structure"] = {k: shipped[k] for k in ("pass", "errors", "warnings")}
    if not shipped["pass"]:
        problems += [f"shipped glb: {e['code']}: {e['message']}" for e in shipped["errors"][:10]]
    for fmt in ("glb", "fbx"):
        summary = qa.check_file(out / f"{key}.{fmt}")["summary"]
        report["steps"][f"shipped_qa_{fmt}"] = summary
        if not summary["pass"]:
            problems += [f"shipped {fmt} QA: {e}" for e in summary["errors"][:10]]
    bpy.ops.wm.open_mainfile(filepath=str(blend))
    obj = next(o for o in env.export_objects() if o.type == "MESH")
    piece = kit_entry(obj, key, source, provenance)
    kit = {"schema": "kit/1", "id": key, "pieces": [piece]}
    problems += [f"kit/1: {p}" for p in formats.validate_kit(kit)]
    (out / f"{key}_kit.json").write_text(formats.dumps(kit))
    build.write_json(out / f"{key}_expectation.json", expectation.expectation(key, [obj]))
    result["kit"] = kit
    result["files"] = {"blend": str(blend), "glb": str(out / f"{key}.glb"), "fbx": str(out / f"{key}.fbx"), "kit": str(out / f"{key}_kit.json"),
                       "maps": sorted(str(p) for p in out.glob(f"{key}_*.png"))}
    if previews:
        render.setup_stage(ground=True, size=200)
        report["steps"]["previews"] = render.render_objects([obj], out, key, angles=("front", "three-quarter"), resolution=(480, 360), samples=8)
    report["kit"] = f"{key}_kit.json"
    return finish()
