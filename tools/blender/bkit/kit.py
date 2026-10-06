"""kit/1 output (docs/runtime-kits.md section 9.5): bkit templates as SceneKit kit pieces.

`build_kit(kinds, out)` builds each template (QA-gated, baked), then exports every piece on its
own at the world origin (Studio puts an imported model's pivot at the file origin, B05), one
GLB and one FBX per piece next to the kit file, and writes the kit/1 JSON: bounds and sockets in
studs in Roblox axes relative to the piece's base-centre pivot (bkit/expectation.py axes), the
materials the piece carries (`atlas:<map>` for a baked palette, `vertex_color`,
`library:<name>`), collision kind, triangles and provenance `local-template`. Each piece file is
QA'd again after export. `library:<name>` materials are checked against a material-library/1
file (G5's `assets/material-library.json`)."""
import json
import shutil
from pathlib import Path

import bpy
from mathutils import Matrix

from . import build, env, expectation, formats, ops, qa, textures


def _pieces():
    """Export roots of the open template: meshes and armatures whose parent is outside the set,
    minus collision proxies (they ride with their visual mesh as children)."""
    objects = env.export_objects()
    roots = [o for o in objects if o.parent not in objects and o.type in ("MESH", "ARMATURE") and env.get_meta(o).get("qa_role") != "collision"]
    return sorted(roots, key=lambda o: o.name)


def _family(root):
    return [root, *root.children_recursive]


def _mesh_of(root):
    if root.type == "MESH":
        return root
    return next((c for c in root.children_recursive if c.type == "MESH" and env.get_meta(c).get("qa_role") != "collision"), None)


def _bounds(meshes):
    """Rest-pose bounds (Roblox axes, studs) of the meshes as they sit now (root at the origin)."""
    m = expectation.measure(meshes)
    return {"min": m["min"], "max": m["max"]}, m["triangles"]


def _sockets(mesh):
    out = []
    for s in env.get_meta(mesh).get("sockets") or []:
        pos = expectation.to_roblox(s["position"])
        out.append({"name": s["name"], "position": [round(v, 4) + 0.0 for v in pos], "yaw": s.get("yaw", 0)})
    return out


def _materials(mesh, kit_dir, map_dir_name):
    """kit/1 material list for a piece from its appearance record."""
    appearance = env.get_meta(mesh).get("appearance") or {}
    kind = appearance.get("kind")
    if kind in ("palette_atlas", "baked"):
        return [f"atlas:{map_dir_name}/{appearance['maps']['color']}"]
    if kind == "vertex_colors":
        return ["vertex_color"]
    if kind == "library":
        return sorted(appearance.get("materials") or [])
    return ["builtin:SmoothPlastic"]


def library_problems(pieces, names, library="the material library"):
    """`library:<name>` materials of kit/1 pieces that the material-library/1 names lack."""
    return [f"{piece['key']}: {m} is not in {library}" for piece in pieces for m in piece.get("materials") or []
            if m.startswith("library:") and m[len("library:"):] not in names]


def build_kit(kinds, out, kit_id=None, library=None, bake_mode="palette"):
    """Build the templates `kinds` and write kit/1 to `out` (a .json path); piece files go to
    `<out dir>/<out stem>/`. Returns {kit, problems, report}; problems is empty when every
    template passed QA, every piece file passed QA and the kit validates."""
    out = Path(out)
    folder = out.parent / out.stem
    work = folder / "_templates"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    kit_id = kit_id or formats.snake(out.stem)
    problems, pieces, files = [], [], []
    lib_names = None
    if library:
        path = Path(library)
        if path.is_file():
            data = json.loads(path.read_text())
            lib_problems = textures.validate_library(data)
            problems += [f"library: {p}" for p in lib_problems]
            lib_names = textures.library_names(data)
        else:
            problems.append(f"library {library} not found: library:<name> materials cannot be checked")
    for kind in kinds:
        report = build.build_template(kind, work, previews=False, bake_mode=bake_mode)
        if not report["summary"]["pass"]:
            problems.append(f"{kind}: template QA failed: {report['summary']['errors'][:5]}")
            continue
        src = work / kind
        bpy.ops.wm.open_mainfile(filepath=str(src / f"{kind}.blend"))
        roots = _pieces()
        for path in src.glob(f"{kind}_*.png"):
            shutil.copy2(path, folder / path.name)
        for root in roots:
            mesh = _mesh_of(root)
            if mesh is None:
                continue
            key = kind if len(roots) == 1 else f"{kind}_{formats.snake(mesh.name)}"
            saved = root.matrix_world.copy()
            root.matrix_world = Matrix.Translation(-saved.translation) @ saved  # piece pivot to the world origin
            bpy.context.view_layer.update()
            family = _family(root)
            meshes = [o for o in family if o.type == "MESH" and env.get_meta(o).get("qa_role") != "collision"]
            bounds, tris = _bounds(meshes)
            ops.export_glb(folder / f"{key}.glb", family)
            ops.export_fbx(folder / f"{key}.fbx", family)
            root.matrix_world = saved
            bpy.context.view_layer.update()
            piece = {
                "key": key,
                "source": f"blender_template:{kind}",
                "file": f"{folder.name}/{key}.glb",
                "bounds": bounds,
                "pivot": "base_center",
                "materials": _materials(mesh, folder, folder.name),
                "provenance": "local-template",
                "collision": env.get_meta(mesh).get("kit_collision") or "box",
                "triangles": tris,
            }
            sockets = _sockets(mesh)
            if sockets:
                piece["sockets"] = sockets
            pieces.append(piece)
            files.append(folder / f"{key}.glb")
            files.append(folder / f"{key}.fbx")
    piece_qa = {}
    for path in files:
        summary = qa.check_file(path)["summary"]
        piece_qa[path.name] = summary
        if not summary["pass"]:
            problems.append(f"{path.name}: QA errors {summary['errors'][:5]}")
    kit = {"schema": "kit/1", "id": kit_id, "pieces": pieces}
    problems += [f"kit/1: {p}" for p in formats.validate_kit(kit)] if pieces else ["kit/1: no pieces"]
    if lib_names is not None:
        problems += library_problems(pieces, lib_names, library)
    out.write_text(formats.dumps(kit))
    report = {"kit": str(out), "pieces": [p["key"] for p in pieces], "piece_qa": piece_qa, "problems": problems, "pass": not problems}
    build.write_json(folder / "kit-report.json", report)
    shutil.rmtree(work, ignore_errors=True)
    return {"kit": kit, "problems": problems, "report": report}
