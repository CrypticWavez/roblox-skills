"""QA self-test: known-good and known-bad assets must get the same verdict from source QA (the
scene), FBX QA and GLB QA. Guards the import paths against false errors on valid kit geometry
(closed shells stacked, abutting or meeting along an edge in one mesh, which a plain glTF vertex
weld fuses into non-manifold edges) and against false passes (flipped, degenerate, non-manifold,
unmaterialled). `factory.py qa-selftest <out_dir>` runs it; exit 1 on any disagreement."""
import json
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

from . import env, ops, qa


def _box(name, size=(4, 4, 4), loc=(0, 0, 0), smooth=False, material=True):
    obj = ops.box(name, size=size, location=loc)
    if material:
        ops.assign(obj, ops.pbr_material("MAT_A", (0.5, 0.5, 0.5, 1)))
    if smooth:
        ops.shade_smooth(obj, angle=180)
    ops.box_uv(obj)
    return obj


def _boxes(name, specs, smooth=False):
    """One mesh made of closed boxes, each (size, location)."""
    parts = [_box(f"{name}_{i}", size=s, loc=loc, smooth=smooth) for i, (s, loc) in enumerate(specs)]
    for part in parts:
        ops.apply_transforms(part)
    return ops.join(parts, name)


def _edit(obj, fn):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    fn(bm)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def _flip_all(bm):
    bmesh.ops.reverse_faces(bm, faces=bm.faces)


def _flip_top_side(bm):
    side = max((f for f in bm.faces if f.normal.x > 0.9), key=lambda f: f.calc_center_median().z)
    bmesh.ops.reverse_faces(bm, faces=[side])


def _add_fin(bm):
    """A quad hanging off the top front edge: that edge has three faces."""
    a, b = sorted((v for v in bm.verts if v.co.z > 3.9 and v.co.y < -1.9), key=lambda v: v.co.x)
    bm.faces.new((a, b, bm.verts.new(b.co + Vector((0, -2, 0))), bm.verts.new(a.co + Vector((0, -2, 0)))))


def _add_sliver(bm):
    """A zero-area triangle (two coincident corners) beside the box."""
    v1, v2, v3 = (bm.verts.new(co) for co in ((10, 0, 0), (10, 0, 0), (10, 1, 0)))
    bm.faces.new((v1, v2, v3))


def _rigged():
    body = _box("SK_Box")
    rig = ops.armature("RIG_Box", [("Root", (0, 0, 0), (0, 0, 4), None)])
    ops.bind_rigid(body, rig, [(lambda w: True, "Root")])


def _ball():
    ball = ops.sphere("SM_Ball", radius=2, segments=24, rings=12)
    ops.shade_smooth(ball)
    ops.assign(ball, ops.pbr_material("MAT_A", (0.5, 0.5, 0.5, 1)))
    ops.set_origin_base_center(ball)
    ops.box_uv(ball)


def _inverted_stack():
    low = _edit(_box("SM_InvStack_low"), _flip_all)
    high = _box("SM_InvStack_high", loc=(0, 0, 4))
    ops.apply_transforms(high)
    ops.join([low, high], "SM_InvStack")


_CUBE = (4, 4, 4)
_UNIT = (2, 2, 2)

# (name, builder, None for a valid asset or the error check every format must report)
CASES = [
    ("box", lambda: _box("SM_Box"), None),
    ("stacked", lambda: _boxes("SM_Stack", [(_CUBE, (0, 0, 0)), (_CUBE, (0, 0, 4))]), None),
    ("side_by_side", lambda: _boxes("SM_Pair", [(_CUBE, (0, 0, 0)), (_CUBE, (4, 0, 0))]), None),
    ("edge_touch", lambda: _boxes("SM_Edge", [(_CUBE, (0, 0, 0)), (_CUBE, (4, 0, 4))]), None),
    ("stairs", lambda: _boxes("SM_Stairs", [((4, 1, 0.5 * (i + 1)), (0, i + 0.5, 0)) for i in range(4)]), None),
    ("three_around_edge", lambda: _boxes("SM_ThreeQ", [(_UNIT, (-1, 0, 0)), (_UNIT, (1, 0, 0)), (_UNIT, (-1, 0, 2))]), None),
    ("four_around_edge", lambda: _boxes("SM_Grid", [(_UNIT, (x, 0, z)) for z in (0, 2) for x in (-1, 1)]), None),
    ("smooth_stacked", lambda: _boxes("SM_SmoothStack", [(_CUBE, (0, 0, 0)), (_CUBE, (0, 0, 4))], smooth=True), None),
    ("uv_sphere", _ball, None),
    ("rigged", _rigged, None),
    ("inverted", lambda: _edit(_box("SM_Inverted"), _flip_all), "normals_consistent"),
    ("stacked_one_flipped", lambda: _edit(_boxes("SM_StackFlip", [(_CUBE, (0, 0, 0)), (_CUBE, (0, 0, 4))]), _flip_top_side), "normals_consistent"),
    ("stacked_one_inverted", _inverted_stack, "normals_consistent"),
    ("fin", lambda: ops.box_uv(_edit(_box("SM_Fin"), _add_fin)), "non_manifold_edges"),
    ("degenerate", lambda: _edit(_box("SM_Degen"), _add_sliver), "degenerate_faces"),
    ("no_material", lambda: _box("SM_NoMat", material=False), "material_assigned"),
]


def _agrees(summary, error):
    if error is None:
        return summary["pass"]
    return not summary["pass"] and any(e.endswith(":" + error) for e in summary["errors"])


def run(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = {"blender": bpy.app.version_string, "cases": [], "pass": True}
    for name, build, error in CASES:
        env.reset()
        build()
        verdicts = {"source": qa.run(export_probe=False)["summary"]}
        files = {"fbx": ops.export_fbx(out / f"{name}.fbx"), "glb": ops.export_glb(out / f"{name}.glb")}
        for fmt, path in files.items():
            verdicts[fmt] = qa.check_file(path)["summary"]
        ok = all(_agrees(v, error) for v in verdicts.values())
        report["pass"] = report["pass"] and ok
        report["cases"].append({"case": name, "expected": error or "pass", "pass": ok, "errors": {fmt: v["errors"] for fmt, v in verdicts.items()}})
        got = "; ".join(f"{fmt}={v['errors'] or 'pass'}" for fmt, v in verdicts.items())
        print(f"qa-selftest {name:22s} {'OK  ' if ok else 'FAIL'} expected={error or 'pass'} {got}")
    (out / "qa-selftest-report.json").write_text(json.dumps(report, indent=2))
    return report
