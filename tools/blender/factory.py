"""Blender asset factory CLI.

  python3 tools/blender/factory.py <command> [args]            (bpy wheel)
  blender -b --python tools/blender/factory.py -- <command> ... (installed Blender)

Commands:
  template <kind> <out_dir>          build a template, save .blend, QA, export FBX+GLB only if QA
                                     has no errors (re-imported and checked), qa.json, previews
  templates <out_dir>                every template
  qa <file> [out]                    QA report (JSON) for a .blend/.fbx/.glb/.gltf; exit 1 on errors
  render-manifest <manifest> <dir>   render a SceneKit manifest (Cycles CPU)
  roundtrip <out_dir>                Blender-side round-trip: create, modify, export, reimport, diff
  qa-selftest <out_dir>              known-good/known-bad assets: source, FBX and GLB QA must agree
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402

from bkit import env, qa, render, templates  # noqa: E402


def _args():
    argv = sys.argv
    return argv[argv.index("--") + 1:] if "--" in argv else argv[1:]


def write_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2, default=str))


def build_template(kind, out_dir, previews=True):
    out = Path(out_dir) / kind
    out.mkdir(parents=True, exist_ok=True)
    templates.build(kind)
    blend = out / f"{kind}.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(blend))
    # QA gates the export: FBX/GLB are written only when the checks have no errors, and the probe
    # re-imports exactly those files. On failure only the .blend, qa.json and previews remain.
    report = qa.gated_export(env.export_objects(), out / f"{kind}.fbx", out / f"{kind}.glb")
    report["template"] = kind
    write_json(out / "qa.json", report)
    if previews:
        bpy.ops.wm.open_mainfile(filepath=str(blend))
        render.setup_stage(ground=True, size=200)
        meshes = [o for o in env.export_objects() if o.type == "MESH"]
        report["previews"] = render.render_objects(meshes, out, kind, angles=("front", "three-quarter"), resolution=(480, 360), samples=8)
        write_json(out / "qa.json", report)
    s = report["summary"]
    print(f"{kind:15s} {'PASS' if s['pass'] else 'FAIL'} errors={len(s['errors'])} warnings={len(s['warnings'])} {s['errors'][:3]}")
    return report


def qa_file(path, out=None):
    # .blend: probe the set build_template ships; .fbx/.glb/.gltf: check the import (glTF seams welded).
    report = qa.check_file(path)
    if out:
        write_json(out, report)
    print(json.dumps(report["summary"], indent=2))
    return report


def main():
    args = _args()
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    if cmd == "template":
        return 0 if build_template(args[1], args[2])["summary"]["pass"] else 1
    if cmd == "templates":
        results = {k: build_template(k, args[1], previews="--no-previews" not in args)["summary"] for k in templates.TEMPLATES}
        write_json(Path(args[1]) / "templates-summary.json", results)
        return 0 if all(r["pass"] for r in results.values()) else 1
    if cmd == "qa":
        if Path(args[1]).suffix.lower() not in qa.ASSET_SUFFIXES:
            print(f"qa: unsupported file {args[1]} (expected {', '.join(qa.ASSET_SUFFIXES)})")
            return 2
        return 0 if qa_file(args[1], args[2] if len(args) > 2 else None)["summary"]["pass"] else 1
    if cmd == "render-manifest":
        manifest = json.loads(Path(args[1]).read_text())
        for p in render.render_manifest(manifest, args[2]):
            print(p)
        return 0
    if cmd == "roundtrip":
        from bkit import roundtrip
        result = roundtrip.run(Path(args[1]))
        return 0 if result["pass"] else 1
    if cmd == "qa-selftest":
        from bkit import selftest
        return 0 if selftest.run(Path(args[1]))["pass"] else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    code = main()
    if bpy.app.background and "--" in sys.argv:
        sys.exit(code)
    sys.exit(code)
