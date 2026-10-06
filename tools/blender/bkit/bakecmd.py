"""`factory.py bake` and `factory.py material-preview`.

bake: take a template kind (built fresh) or a `.blend` (its Export collections) and bake:
- `palette`: bake.palette_atlas over the whole set (one atlas for all meshes);
- `vertex`: bake.vertex_colors;
- `maps`: Cycles bake_maps per mesh (`<name>` for one mesh, `<name>_<mesh>` for several): a
  SurfaceAppearance map set on the mesh's own atlas UVs.
These three ship the asset the factory way (save, QA-gated FBX + GLB, expectation, previews).
- `tile`: a MaterialVariant-ready tile. The material (`--material`, default the first material of
  the first shipped mesh) is baked onto a 1 x 1 plane whose UVs fill 0..1, so a seamless material
  (procedural patterns with whole-number repeats, image textures that already tile) gives a
  seamless tile. Writes the maps and a material-library/1 file `<name>_material-library.json`
  citing them as `build:<path>` (relative to the repo root). `--library` names an existing
  material-library/1 file (G5's `assets/material-library.json`; tests use
  tools/blender/fixtures/material-library.json): an entry of the same name lends base_material,
  studs_per_tile and pattern, and a name missing from it is reported.

material-preview: render each library material whose maps are on disk (`build:` paths or
`<source>#<file>` in build/asset-cache) on a sphere and a cube at its studs_per_tile, and check
every map file (format, size, channels, OpenGL normals). Materials whose maps are not on disk are
listed as not rendered, never passed."""
import json
import os
from pathlib import Path

import bmesh
import bpy

from . import bake, build, env, expectation, formats, ops, qa, render, templates, textures

ROOT = Path(__file__).resolve().parents[3]


def _open(source):
    if source in templates.TEMPLATES:
        env.reset()
        templates.build(source)
        return source
    path = Path(source)
    if path.suffix.lower() != ".blend" or not path.is_file():
        raise ValueError(f"bake: {source} is neither a template kind nor a .blend file")
    bpy.ops.wm.open_mainfile(filepath=str(path))
    return path.stem


def _meshes():
    return [o for o in env.export_objects() if o.type == "MESH" and env.get_meta(o).get("qa_role") != "collision"]


def _rel(path):
    try:
        return Path(os.path.relpath(Path(path).resolve(), ROOT)).as_posix()
    except ValueError:  # another drive on Windows
        return Path(path).resolve().as_posix()


def _library(library):
    if not library:
        return None, []
    path = Path(library)
    if not path.is_file():
        return None, [f"library {library} not found"]
    data = json.loads(path.read_text())
    problems = textures.validate_library(data)
    return ({m["name"]: m for m in data.get("materials", []) if isinstance(m, dict) and "name" in m}, [f"library: {p}" for p in problems])


def _clean(out, name):
    out.mkdir(parents=True, exist_ok=True)
    for path in list(out.glob(f"{name}.*")) + list(out.glob(f"{name}_*")):
        if path.is_file():
            path.unlink()


def _tile_roles(mat):
    """Maps a tile needs: colour and roughness always, metalness and normal when the material
    has them, emissive when it emits."""
    bsdf = ops.principled(mat, create=False)
    roles = ["color", "roughness"]
    if bsdf is None:
        return roles
    metal = bsdf.inputs.get("Metallic")
    if metal is not None and (metal.is_linked or metal.default_value > 0):
        roles.append("metalness")
    normal = bsdf.inputs.get("Normal")
    if normal is not None and normal.is_linked:
        roles.append("normal")
    strength = bsdf.inputs.get("Emission Strength")
    if strength is not None and (strength.is_linked or strength.default_value > 0):
        roles.append("emissive")
    return roles


def _tile_plane(mat):
    """A 1 x 1 plane at the origin with an `AtlasUV` layer exactly covering 0..1."""
    coll = env.collection("Tile/Export", env.collection("Tile"))
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, 0.0)) for x, y in ((-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5))]
    bm.faces.new(verts)
    mesh = bpy.data.meshes.new("SM_Tile")
    bm.to_mesh(mesh)
    bm.free()
    plane = bpy.data.objects.new("SM_Tile", mesh)
    coll.objects.link(plane)
    layer = mesh.uv_layers.new(name="AtlasUV")
    for poly in mesh.polygons:
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            layer.data[li].uv = (co.x + 0.5, co.y + 0.5)
    mesh.materials.append(mat)
    return plane


def run_tile(source, out_dir, size=1024, name=None, library=None, material=None, previews=True):
    """`bake --mode tile`: see the module docstring. Returns {pass, name, mode, maps, library, problems}."""
    problems = []
    lib, lib_problems = _library(library)
    problems += lib_problems
    kind = _open(source)
    name = formats.snake(name or kind)
    out = Path(out_dir).resolve() / name
    _clean(out, name)
    if material:
        mat = bpy.data.materials.get(material)
        if mat is None:
            return {"pass": False, "name": name, "mode": "tile", "problems": problems + [f"no material {material!r}"]}
    else:
        meshes = _meshes() or [o for o in bpy.context.scene.objects if o.type == "MESH"]
        mat = next((m for o in meshes for m in o.data.materials if m is not None), None)
        if mat is None:
            return {"pass": False, "name": name, "mode": "tile", "problems": problems + ["no material to bake"]}
    for obj in list(bpy.context.scene.objects):
        obj.hide_render = True  # only the tile plane may catch the bake rays
    plane = _tile_plane(mat)
    baked = bake.bake_maps(plane, out, name, maps=tuple(_tile_roles(mat)), size=size, margin=0)
    base = (lib or {}).get(name) or {}
    if lib is not None and not base:
        problems.append(f"{name}: not in {library}; the entry uses SmoothPlastic defaults")
    entry = textures.library_entry(
        name, {role: _rel(out / file) for role, file in baked["maps"].items()}, size,
        base_material=base.get("base_material", "SmoothPlastic"), studs_per_tile=base.get("studs_per_tile", 4),
        pattern=base.get("pattern", "Regular"), provenance="local")
    library_file = out / f"{name}_material-library.json"
    try:
        textures.write_library([entry], library_file)
    except ValueError as exc:
        problems.append(str(exc))
        library_file = None
    for role, file in baked["maps"].items():
        found, _info = textures.check_map_file(out / file, role, size)
        problems += [f"{role}: {p}" for p in found]
    result = {"pass": not problems, "name": name, "mode": "tile", "material": mat.name, "maps": baked["maps"],
              "library": str(library_file) if library_file else None, "problems": problems}
    if previews and library_file:
        result["preview"] = material_preview(library_file, out)["rendered"].get(name)
    return result


def run(source, out_dir, mode="palette", size=1024, name=None, library=None, material=None, previews=True):
    """Bake and ship (palette, vertex, maps) or bake a tile (`run_tile`). Returns {pass, name,
    mode, appearance, files, problems, qa}."""
    if mode == "tile":
        return run_tile(source, out_dir, size=size, name=name, library=library, material=material, previews=previews)
    if mode not in ("palette", "vertex", "maps"):
        raise ValueError("bake mode must be palette, vertex, maps or tile")
    problems = []
    kind = _open(source)
    name = formats.snake(name or kind)
    out = Path(out_dir).resolve() / name
    _clean(out, name)
    meshes = _meshes()
    if not meshes:
        return {"pass": False, "name": name, "mode": mode, "problems": ["no meshes in an Export collection"], "files": {}}
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    for rig in armatures:
        rig.data.pose_position = "REST"  # bake the bind pose
    appearance = None
    if mode == "palette":
        appearance = bake.palette_atlas(meshes, out, name)
    elif mode == "vertex":
        appearance = bake.vertex_colors(meshes, name)
    else:
        for obj in meshes:
            label = name if len(meshes) == 1 else f"{name}_{formats.snake(obj.name)}"
            mats = [m for m in obj.data.materials if m is not None]
            roles = ["color", "roughness", "metalness", "normal"]
            if any(max(bake.flat_values(m)["emission"]) > 0 for m in mats if _flat(m)):
                roles.append("emissive")
            appearance = bake.bake_maps(obj, out, label, maps=tuple(roles), size=size)
    for rig in armatures:
        rig.data.pose_position = "POSE"
    blend = out / f"{name}.blend"
    build.save_blend(blend)
    report = qa.gated_export(env.export_objects(), out / f"{name}.fbx", out / f"{name}.glb")
    build.write_json(out / "qa.json", report)
    if not report["summary"]["pass"]:
        problems += [f"qa: {e}" for e in report["summary"]["errors"][:10]]
    bpy.ops.wm.open_mainfile(filepath=str(blend))
    meshes = _meshes()
    if report["summary"]["pass"]:
        build.write_json(out / f"{name}_expectation.json", expectation.expectation(name, meshes))
    files = {"blend": str(blend), "maps": sorted(str(p) for p in out.glob(f"{name}*_*.png") if not p.name.endswith((".front.png", ".three-quarter.png")))}
    if report["summary"]["pass"]:
        files.update(fbx=str(out / f"{name}.fbx"), glb=str(out / f"{name}.glb"))
    if previews:
        render.setup_stage(ground=True, size=200)
        files["previews"] = render.render_objects(meshes, out, name, angles=("front", "three-quarter"), resolution=(480, 360), samples=8)
    clean = {k: v for k, v in (appearance or {}).items() if k not in ("files", "cells")}
    return {"pass": not problems, "name": name, "mode": mode, "appearance": clean, "files": files, "problems": problems, "qa": report["summary"]}


def _flat(mat):
    try:
        bake.flat_values(mat)
        return True
    except ValueError:
        return False


def _preview_objects(studs_per_tile):
    sphere = ops.sphere("PreviewSphere", radius=2.0, segments=48, rings=24, location=(-2.6, 0, 2.0))
    cube = ops.box("PreviewCube", size=(3.6, 3.6, 3.6), location=(2.6, 0, 0))
    for obj in (sphere, cube):
        ops.box_uv(obj, scale=1.0 / studs_per_tile)
    ops.shade_smooth(sphere, angle=80)
    return [sphere, cube]


def material_preview(library, out_dir, cache=None):
    """Render every material of a material-library/1 file whose colour map is on disk.
    Returns {rendered: {name: [png]}, not_rendered: {name: reason}, maps: [...], problems}."""
    data = json.loads(Path(library).read_text())
    problems = textures.validate_library(data)
    out = Path(out_dir).resolve()
    rendered, skipped, maps = {}, {}, []
    if problems:
        return {"rendered": rendered, "not_rendered": skipped, "maps": maps, "problems": problems}
    for m in data["materials"]:
        name = m["name"]
        files = {}
        for role in textures.ROLES:
            ref = m["maps"].get(role)
            if ref is None:
                continue
            path = textures.resolve_ref(ref, ROOT, cache)
            if path is None:
                continue
            map_problems, _info = textures.check_map_file(path, role, m["resolution"])
            maps.append({"material": name, "role": role, "file": str(path), "problems": map_problems})
            problems += [f"{name}.{role}: {p}" for p in map_problems]
            files[role] = path
        if "color" not in files:
            skipped[name] = "colour map not on disk (fetch it into build/asset-cache or bake it)"
            continue
        env.reset()
        objects = _preview_objects(m["studs_per_tile"])
        images = {role: textures.load_map(path, role) for role, path in files.items()}
        mat = textures.material_from_maps(f"MAT_{name}", images, {"roughness": 0.5, "metallic": 0.0})
        for obj in objects:
            ops.assign(obj, mat)
        render.setup_stage(ground=True, size=60)
        rendered[name] = render.render_objects(objects, out, name, angles=("three-quarter",), resolution=(480, 300), samples=12)
    return {"rendered": rendered, "not_rendered": skipped, "maps": maps, "problems": problems}
