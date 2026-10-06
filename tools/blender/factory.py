"""Blender asset factory CLI.

  python3 tools/blender/factory.py <command> [args]            (bpy wheel)
  blender -b --python tools/blender/factory.py -- <command> ... (installed Blender)

Commands:
  template <kind> <out_dir> [--bake palette|vertex|none] [--no-previews]
  template --kind <kind> --out <dir | file.glb | file.fbx>
                                     build a template, bake its look (palette atlas by default),
                                     save .blend, QA, export FBX+GLB only if QA has no errors
                                     (re-imported and checked), expectation, clips, qa.json,
                                     previews. --out <file> also copies that shipped file there
  templates <out_dir> [--kinds a,b] [--bake ...] [--no-previews]
                                     every template (or the listed kinds)
  qa <file> [out]                    QA report (JSON) for a .blend/.fbx/.glb/.gltf; exit 1 on errors
  qa-selftest <out_dir>              known-good/known-bad assets, ops, bakes, clips, rig profiles,
                                     templates and the offline intake must get the expected verdicts
  render-manifest <manifest> <dir>   render a SceneKit manifest (Cycles CPU)
  roundtrip <out_dir>                Blender-side round trip: create, bake, modify, export, reimport,
                                     diff, roblox_expectation_v*.json
  kit --templates a,b --out <kit.json> [--id <label>] [--library <material-library.json>]
                                     build templates and write kit/1 with one file per piece
  compare-export <file>... --expect <expectation.json> [--source factory|studio] [--out <json>]
                                     re-import FBX/GLB/glTF files and diff them with an expectation
  textures <material-library.json> [--out <json>] [--cache <dir>]
                                     validate material-library/1 and every map file on disk
  bake <kind|file.blend> <out_dir> [--mode palette|vertex|maps|tile] [--size N] [--name <label>]
       [--library <material-library.json>] [--material <name>]
                                     bake a template or .blend and ship it (palette, vertex, maps),
                                     or bake one material as a MaterialVariant-ready tile and write
                                     material-library/1 for it (tile)
  material-preview <material-library.json> <out_dir>
                                     render each library material whose maps are on disk
  icon <kind|file.blend> <out.png> [--size N]
                                     deterministic UI thumbnail render (transparent background)
  intake <file> <out_dir> --key <label> --source cc0:<src>:<id> [--height H | --scale S]
         [--provenance <key>] [--category <budget row>] [--bake auto|palette|vertex|maps] [--size N]
                                     QA, normalise, bake and export a third-party model; writes a
                                     kit/1 entry for it
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bpy  # noqa: E402

from bkit import build, qa, render, templates  # noqa: E402

write_json = build.write_json


def _args():
    argv = sys.argv
    return argv[argv.index("--") + 1:] if "--" in argv else argv[1:]


def build_template(kind, out_dir, previews=True, bake_mode="palette"):
    return build.build_template(kind, out_dir, previews=previews, bake_mode=bake_mode)


def qa_file(path, out=None):
    # .blend: probe the set build_template ships; .fbx/.glb/.gltf: check the import (glTF seams welded).
    report = qa.check_file(path)
    if out:
        write_json(out, report)
    print(json.dumps(report["summary"], indent=2))
    return report


def _kinds(text):
    kinds = [k.strip() for k in text.split(",") if k.strip()]
    unknown = [k for k in kinds if k not in templates.TEMPLATES]
    if unknown:
        raise SystemExit(f"unknown template kind(s): {', '.join(unknown)} (known: {', '.join(templates.TEMPLATES)})")
    return kinds


def cmd_template(a):
    kind = a.kind_flag or a.kind
    if kind not in templates.TEMPLATES:
        print(f"template: unknown kind {kind!r} (known: {', '.join(templates.TEMPLATES)})")
        return 2
    target = Path(a.out_flag or a.out_dir or "build/blender")
    file = target if target.suffix.lower() in (".glb", ".fbx") else None
    out_dir = target.parent if file else target
    report = build.build_template(kind, out_dir, previews=not a.no_previews, bake_mode=a.bake)
    if file is not None:
        file.unlink(missing_ok=True)
        if report["summary"]["pass"]:
            shutil.copy2(out_dir / kind / f"{kind}{file.suffix.lower()}", file)
            print(file)
    return 0 if report["summary"]["pass"] else 1


def cmd_templates(a):
    kinds = _kinds(a.kinds) if a.kinds else list(templates.TEMPLATES)
    results = {k: build.build_template(k, a.out_dir, previews=not a.no_previews, bake_mode=a.bake)["summary"] for k in kinds}
    write_json(Path(a.out_dir) / "templates-summary.json", results)
    return 0 if all(r["pass"] for r in results.values()) else 1


def cmd_qa(a):
    if Path(a.file).suffix.lower() not in qa.ASSET_SUFFIXES:
        print(f"qa: unsupported file {a.file} (expected {', '.join(qa.ASSET_SUFFIXES)})")
        return 2
    return 0 if qa_file(a.file, a.report)["summary"]["pass"] else 1


def cmd_render_manifest(a):
    manifest = json.loads(Path(a.manifest).read_text())
    for p in render.render_manifest(manifest, a.out_dir):
        print(p)
    return 0


def cmd_roundtrip(a):
    from bkit import roundtrip

    return 0 if roundtrip.run(Path(a.out_dir))["pass"] else 1


def cmd_selftest(a):
    from bkit import selftest

    return 0 if selftest.run(Path(a.out_dir))["pass"] else 1


def cmd_kit(a):
    from bkit import kit

    result = kit.build_kit(_kinds(a.templates), a.out, kit_id=a.id, library=a.library, bake_mode=a.bake)
    print(json.dumps({"kit": a.out, "pieces": [p["key"] for p in result["kit"]["pieces"]], "problems": result["problems"]}, indent=2))
    return 0 if not result["problems"] else 1


def cmd_compare(a):
    from bkit import compare

    expectation = json.loads(Path(a.expect).read_text())
    report = compare.compare_files(a.files, expectation, source=a.source)
    if a.report:
        write_json(a.report, report)
    for fmt in report["files"]:
        print(f"{fmt['file']}: {'PASS' if fmt['pass'] else 'FAIL'} " + ", ".join(c["name"] for c in fmt["checks"] if not c["pass"]))
    return 0 if report["pass"] else 1


def cmd_textures(a):
    from bkit import textures

    data = json.loads(Path(a.library).read_text())
    problems = textures.validate_library(data)
    root = Path(__file__).resolve().parents[2]
    files = textures.check_library_files(data, root, a.cache) if not problems else []
    file_problems = [f"{r['material']}.{r['role']}: {p}" for r in files for p in r["problems"]]
    unchecked = [f"{r['material']}.{r['role']}" for r in files if not r["checked"]]
    report = {"library": a.library, "schema_problems": problems, "maps": files, "problems": problems + file_problems, "not_checked": unchecked,
              "pass": not problems and not file_problems}
    if a.report:
        write_json(a.report, report)
    print(json.dumps({k: report[k] for k in ("pass", "problems", "not_checked")}, indent=2))
    return 0 if report["pass"] else 1


def cmd_bake(a):
    from bkit import bakecmd

    result = bakecmd.run(a.source, a.out_dir, mode=a.mode, size=a.size, name=a.name, library=a.library, material=a.material)
    print(json.dumps({k: v for k, v in result.items() if k != "qa"}, indent=2, default=str))
    return 0 if result["pass"] else 1


def cmd_material_preview(a):
    from bkit import bakecmd

    result = bakecmd.material_preview(a.library, a.out_dir)
    print(json.dumps(result, indent=2))
    return 0 if not result["problems"] else 1


def cmd_icon(a):
    from bkit import icons

    result = icons.icon_for(a.source, a.out, size=a.size)
    print(json.dumps(result, indent=2))
    return 0


def cmd_intake(a):
    from bkit import intake

    result = intake.run(a.file, a.out_dir, key=a.key, height=a.height, scale=a.scale, source=a.source, provenance=a.provenance, category=a.category,
                        route=a.bake, size=a.size)
    print(json.dumps({k: result[k] for k in ("pass", "kit", "problems")}, indent=2))
    return 0 if result["pass"] else 1


def parser():
    ap = argparse.ArgumentParser(prog="factory.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command")
    p = sub.add_parser("template")
    p.add_argument("kind", nargs="?")
    p.add_argument("out_dir", nargs="?")
    p.add_argument("--kind", dest="kind_flag")
    p.add_argument("--out", dest="out_flag")
    p.add_argument("--bake", default="palette", choices=build.BAKE_MODES)
    p.add_argument("--no-previews", action="store_true")
    p.set_defaults(fn=cmd_template)
    p = sub.add_parser("templates")
    p.add_argument("out_dir")
    p.add_argument("--kinds")
    p.add_argument("--bake", default="palette", choices=build.BAKE_MODES)
    p.add_argument("--no-previews", action="store_true")
    p.set_defaults(fn=cmd_templates)
    p = sub.add_parser("qa")
    p.add_argument("file")
    p.add_argument("report", nargs="?")
    p.set_defaults(fn=cmd_qa)
    p = sub.add_parser("render-manifest")
    p.add_argument("manifest")
    p.add_argument("out_dir")
    p.set_defaults(fn=cmd_render_manifest)
    p = sub.add_parser("roundtrip")
    p.add_argument("out_dir")
    p.set_defaults(fn=cmd_roundtrip)
    p = sub.add_parser("qa-selftest")
    p.add_argument("out_dir")
    p.set_defaults(fn=cmd_selftest)
    p = sub.add_parser("kit")
    p.add_argument("--templates", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--id")
    p.add_argument("--library")
    p.add_argument("--bake", default="palette", choices=build.BAKE_MODES)
    p.set_defaults(fn=cmd_kit)
    p = sub.add_parser("compare-export")
    p.add_argument("files", nargs="+")
    p.add_argument("--expect", required=True)
    p.add_argument("--source", default="factory", choices=("factory", "studio"))
    p.add_argument("--out", dest="report")
    p.set_defaults(fn=cmd_compare)
    p = sub.add_parser("textures")
    p.add_argument("library")
    p.add_argument("--out", dest="report")
    p.add_argument("--cache")
    p.set_defaults(fn=cmd_textures)
    p = sub.add_parser("bake")
    p.add_argument("source")
    p.add_argument("out_dir")
    p.add_argument("--mode", default="palette", choices=("palette", "vertex", "maps", "tile"))
    p.add_argument("--size", type=int, default=1024)
    p.add_argument("--name")
    p.add_argument("--library")
    p.add_argument("--material")
    p.set_defaults(fn=cmd_bake)
    p = sub.add_parser("material-preview")
    p.add_argument("library")
    p.add_argument("out_dir")
    p.set_defaults(fn=cmd_material_preview)
    p = sub.add_parser("icon")
    p.add_argument("source")
    p.add_argument("out")
    p.add_argument("--size", type=int, default=512)
    p.set_defaults(fn=cmd_icon)
    p = sub.add_parser("intake")
    p.add_argument("file")
    p.add_argument("out_dir")
    p.add_argument("--key", required=True)
    p.add_argument("--height", type=float)
    p.add_argument("--scale", type=float)
    p.add_argument("--source")
    p.add_argument("--provenance")
    p.add_argument("--category", default="prop")
    p.add_argument("--bake", default="auto", choices=("auto", "palette", "vertex", "maps"))
    p.add_argument("--size", type=int, default=1024)
    p.set_defaults(fn=cmd_intake)
    return ap


def main():
    args = _args()
    ap = parser()
    if not args:
        print(__doc__)
        return 2
    a = ap.parse_args(args)
    if not getattr(a, "fn", None):
        print(__doc__)
        return 2
    if a.command == "template" and not (a.kind_flag or a.kind):
        print("template: give a kind (template <kind> <out_dir> or --kind <kind> --out <path>)")
        return 2
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
