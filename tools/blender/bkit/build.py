"""Template builds: build, bake the look into maps Roblox reads (palette atlas by default), save,
QA-gated FBX/GLB export, clip export for rigs with clips, the Roblox expectation and previews.
`factory.py template`/`templates`/`kit` and the self-test use it."""
import json
import shutil
from pathlib import Path

import bpy

from . import bake, clips, env, expectation, qa, render, templates

BAKE_MODES = ("palette", "vertex", "none")


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2, default=str))


def save_blend(path):
    """Save, then make every external path (baked maps) relative to the .blend so the folder can
    move, and save again. The path is made absolute first: with a relative .blend path Blender
    resolves `//` image paths against the filesystem root (`template ... --out build/t.glb` found
    no maps)."""
    path = Path(path).resolve()
    path.unlink(missing_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))
    bpy.ops.file.make_paths_relative()
    bpy.ops.wm.save_mainfile()
    Path(str(path) + "1").unlink(missing_ok=True)  # no .blend1 backup next to the build


def bake_export_set(kind, out, mode="palette"):
    """Bake the look of the export set's meshes (bake.palette_atlas or bake.vertex_colors).
    Returns the appearance record, or None for mode "none" or nothing to bake."""
    if mode not in BAKE_MODES:
        raise ValueError(f"bake mode must be one of {', '.join(BAKE_MODES)}")
    meshes = [o for o in env.export_objects() if o.type == "MESH"]
    if mode == "none" or not meshes:
        return None
    if mode == "palette":
        return bake.palette_atlas(meshes, out, kind)
    return bake.vertex_colors(meshes, kind)


def _clean(out, kind):
    for path in list(out.glob(f"{kind}.*")) + list(out.glob(f"{kind}_*")):
        if path.is_file():
            path.unlink()


def _meshes():
    return [o for o in env.export_objects() if o.type == "MESH" and env.get_meta(o).get("qa_role") != "collision"]


def build_template(kind, out_dir, previews=True, bake_mode="palette"):
    """Build template `kind` into `<out_dir>/<kind>/`: `.blend`, maps (`<kind>_Color.png`, ...),
    `qa.json`, and only when QA has no errors `<kind>.fbx`/`.glb` (re-imported and compared),
    `<kind>_expectation.json` and, for rigs with clips, the clip files and clips/1 sidecar.
    previews: front and three-quarter PNGs. Returns the QA report."""
    out = Path(out_dir).resolve() / kind
    out.mkdir(parents=True, exist_ok=True)
    _clean(out, kind)
    templates.build(kind)
    appearance = bake_export_set(kind, out, bake_mode)
    blend = out / f"{kind}.blend"
    save_blend(blend)
    # QA gates the export: FBX/GLB are written only when the checks have no errors, and the probe
    # re-imports exactly those files. On failure only the .blend, maps, qa.json and previews remain.
    report = qa.gated_export(env.export_objects(), out / f"{kind}.fbx", out / f"{kind}.glb")
    report["template"] = kind
    if appearance:
        report["appearance"] = {k: v for k, v in appearance.items() if k not in ("files", "cells")}
    if report["summary"]["pass"]:
        bpy.ops.wm.open_mainfile(filepath=str(blend))
        meshes = _meshes()
        exp = expectation.expectation(kind, meshes, extra={"collision": env.get_meta(meshes[0]).get("kit_collision")} if meshes else None)
        write_json(out / f"{kind}_expectation.json", exp)
        report["expectation"] = f"{kind}_expectation.json"
        if kind in templates.CLIP_RIGS:
            rig = next(o for o in env.export_objects() if o.type == "ARMATURE")
            data = clips.export_clips(rig, meshes, out, kind, templates.CLIP_RIGS[kind])
            problems = clips.glb_problems(out / data["files"]["glb"], data)
            report["clips"] = {"sidecar": f"{kind}_clips.json", "clips": [c["name"] for c in data["clips"]], "files": data["files"], "problems": problems}
            if problems:
                report["summary"]["errors"].append("clips:" + "; ".join(problems))
                report["summary"]["pass"] = False
    write_json(out / "qa.json", report)
    if previews:
        bpy.ops.wm.open_mainfile(filepath=str(blend))
        render.setup_stage(ground=True, size=200)
        meshes = [o for o in env.export_objects() if o.type == "MESH"]
        report["previews"] = render.render_objects(meshes, out, kind, angles=("front", "three-quarter"), resolution=(480, 360), samples=8)
        write_json(out / "qa.json", report)
    s = report["summary"]
    print(f"{kind:18s} {'PASS' if s['pass'] else 'FAIL'} errors={len(s['errors'])} warnings={len(s['warnings'])} {s['errors'][:3]}")
    return report


def copy_outputs(out, kind, target):
    """Copy a built template's shipped files (FBX, GLB, maps, clips) to `target`."""
    target = Path(target)
    target.mkdir(parents=True, exist_ok=True)
    copied = []
    for path in sorted(Path(out).glob(f"{kind}*")):
        if path.suffix in (".fbx", ".glb", ".png", ".json") and not path.name.endswith((".front.png", ".three-quarter.png")):
            shutil.copy2(path, target / path.name)
            copied.append(path.name)
    return copied
