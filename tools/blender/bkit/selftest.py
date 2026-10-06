"""QA self-test: known-good and known-bad assets must get the same verdict from source QA (the
scene) and from `factory.py qa` on the saved .blend (no Export collection: whole scene, export
probe included), the FBX and the GLB. Guards the import paths against false errors on valid kit
geometry (closed shells stacked, abutting or meeting along an edge in one mesh, which a plain
glTF vertex weld fuses into non-manifold edges) and against false passes (flipped, degenerate,
non-manifold, unmaterialled, over-influenced or unweighted skins, a single root off the world
origin where Studio anchors the pivot). Also covers the retopology, LOD and weighting ops
(`ops.voxel_remesh`, `quadriflow`, `lod_chain`, `bind_auto`): their output must pass QA in every
format, and their refusals must raise. `factory.py qa-selftest <out_dir>` runs it; exit 1 on
any disagreement.

Skin-weight defects are the one place the formats legitimately differ: Blender's glTF exporter
keeps each vertex's 4 strongest influences (export_influence_nb) and re-imports a vertex with no
weight as fully bound to one bone, so a .glb of an over-influenced or unweighted skin passes.
Those cases expect the error from every format but GLB; check weights on the .blend or .fbx."""
import hashlib
import json
import re
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

from . import env, ops, qa, templates


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


def _grounded(obj):
    """Origin at the base centre, and that at the world origin (where Studio anchors the pivot)."""
    ops.set_origin_base_center(obj)
    obj.location = (0, 0, 0)
    return obj


def _ball():
    ball = ops.sphere("SM_Ball", radius=2, segments=24, rings=12)
    ops.shade_smooth(ball)
    ops.assign(ball, ops.pbr_material("MAT_A", (0.5, 0.5, 0.5, 1)))
    _grounded(ball)
    ops.box_uv(ball)


def _inverted_stack():
    low = _edit(_box("SM_InvStack_low"), _flip_all)
    high = _box("SM_InvStack_high", loc=(0, 0, 4))
    ops.apply_transforms(high)
    ops.join([low, high], "SM_InvStack")


# ---------- retopology, LOD and weighting ----------

def _rock(name="SM_Rock", seed=7):
    rock = ops.icosphere(name, radius=2, subdivisions=4)
    ops.noise_displace(rock, strength=0.5, scale=0.6, seed=seed)
    ops.assign(rock, ops.pbr_material("MAT_A", (0.5, 0.5, 0.5, 1)))
    _grounded(rock)
    ops.box_uv(rock)
    return rock


def _quadriflow_rock():
    _grounded(ops.quadriflow(_rock(), target_faces=600, seed=0))


def _column(name):
    """A 6-stud column smooth-weighted to a 3-bone chain (as the rig_test template)."""
    column = ops.cylinder(name, radius=0.5, depth=6, segments=12)
    _edit(column, lambda bm: bmesh.ops.subdivide_edges(bm, edges=[e for e in bm.edges if abs(e.verts[0].co.z - e.verts[1].co.z) > 1], cuts=12, use_grid_fill=True))
    ops.assign(column, ops.pbr_material("MAT_A", (0.5, 0.5, 0.5, 1)))
    ops.box_uv(column)
    rig = ops.armature("RIG_" + name, [("Bone1", (0, 0, 0), (0, 0, 2), None), ("Bone2", (0, 0, 2), (0, 0, 4), "Bone1"), ("Bone3", (0, 0, 4), (0, 0, 6), "Bone2")])
    return ops.bind_auto(column, rig)


def _smooth_humanoid():
    """The humanoid blockout fused by voxel remesh, then bone-heat weighted to its R15 rig: raw
    heat gives some vertices more than 4 influences, so `limit_weights` must cut them."""
    body, rig = templates.humanoid()
    ops.voxel_remesh(body, voxel_size=0.25)
    ops.bind_auto(body, rig)


def _two_shells(name):
    """Two separate boxes with both bones inside the first: bone heat cannot reach the second."""
    body = _boxes(name, [((2, 2, 4), (0, 0, 0)), ((1, 1, 1), (4, 0, 0))])
    rig = ops.armature("RIG_" + name, [("Low", (0, 0, 0.2), (0, 0, 2), None), ("High", (0, 0, 2), (0, 0, 3.8), "Low")])
    return body, rig


def _over_influenced():
    body = _box("SK_Over")
    rig = ops.armature("RIG_Over", [(f"B{i}", (0, 0, i * 0.8), (0, 0, i * 0.8 + 0.8), f"B{i - 1}" if i else None) for i in range(5)])
    for bone in rig.data.bones:  # 5 equal influences on every vertex
        body.vertex_groups.new(name=bone.name).add([v.index for v in body.data.vertices], 0.2, "REPLACE")
    body.modifiers.new("Armature", "ARMATURE").object = rig
    body.parent = rig


def _half_weighted():
    body = _box("SK_Half")
    rig = ops.armature("RIG_Half", [("Root", (0, 0, 0), (0, 0, 2), None), ("Top", (0, 0, 2), (0, 0, 4), "Root")])
    ops.bind_rigid(body, rig, [(lambda w: w.z > 2, "Top")])  # the bottom four vertices get nothing


def _rig_of(obj):
    return next((m.object for m in obj.modifiers if m.type == "ARMATURE" and m.object), None)


def _skinned():
    return [o for o in bpy.context.scene.objects if o.type == "MESH" and _rig_of(o)]


def _skin_problems(fmt, raw_over=False, fallback=False):
    """Every skinned mesh: <= 4 influences, none unweighted, normalised and actually smooth.
    raw_over/fallback (source only): bone heat gave > 4 influences / left vertices for the fallback."""
    problems = []
    skinned = _skinned()
    if not skinned:
        return ["no skinned mesh"]
    for obj in skinned:
        stats = qa.skin_stats(obj, _rig_of(obj))
        if stats["max_influences"] > qa.ROBLOX_MAX_INFLUENCES or stats["unweighted"] or stats["unnormalized"]:
            problems.append(f"{obj.name}: {stats}")
        if not stats["multi_influence"]:
            problems.append(f"{obj.name}: rigid, no vertex has two influences")
        weighting = env.get_meta(obj).get("weighting") or {}
        if fmt == "source" and raw_over and weighting.get("raw_max_influences", 0) <= qa.ROBLOX_MAX_INFLUENCES:
            problems.append(f"{obj.name}: heat gave {weighting.get('raw_max_influences')} influences at most; the limit was not exercised")
        if fmt == "source" and fallback and not weighting.get("fallback_vertices"):
            problems.append(f"{obj.name}: no fallback vertices recorded")
    return problems


def _glb_repaired(fmt, stat, value):
    """The .glb of a bad skin re-imports repaired by the exporter (see module docstring)."""
    if fmt != "glb":
        return []
    obj = _skinned()[0]
    stats = qa.skin_stats(obj, _rig_of(obj))
    return [] if stats[stat] == value else [f"glb {stat} {stats[stat]}, expected {value}: exporter behaviour changed"]


def _lod_problems(base, levels, skinned=False):
    def check(fmt):
        found = {}
        for obj in bpy.context.scene.objects:
            match = re.fullmatch(re.escape(base) + r"(?:_LOD(\d+))?", obj.name)
            if obj.type == "MESH" and match:
                found[int(match.group(1) or 0)] = obj
        tris = [ops.triangles(found[i]) for i in sorted(found)]
        problems = [] if len(tris) == levels and all(b < a for a, b in zip(tris, tris[1:])) else [f"{base} LOD triangles {tris}: want {levels} strictly decreasing"]
        return problems + (_skin_problems(fmt) if skinned else [])
    return check


def _quads_only(fmt):
    if fmt not in ("source", "blend"):
        return []  # glTF triangulates; the quads are judged where they were made
    mesh = bpy.data.objects["SM_Rock"].data
    tris = sum(1 for p in mesh.polygons if len(p.vertices) != 4)
    return [f"SM_Rock: {tris} of {len(mesh.polygons)} faces are not quads"] if tris else []


def _skinned_lods():
    ops.lod_chain(_column("SK_Column"), (0.5, 0.25))


def _rock_lods():
    ops.lod_chain(_rock(), (0.5, 0.25, 0.1))


_CUBE = (4, 4, 4)
_UNIT = (2, 2, 2)
FORMATS = ("source", "blend", "fbx", "glb")
_SKIN_BAD = ("source", "blend", "fbx")  # see module docstring: the .glb comes back repaired

# (name, builder, expected, [verify]): expected is None for a valid asset, the error check every
# format must report, or {format: check or None}. verify(fmt) runs on the scene each QA saw (the
# source, then each file QA) and returns problems; any problem fails the case.
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
    ("off_origin", lambda: _box("SM_OffOrigin", loc=(0, -0.75, 0)), "studio_pivot_at_origin"),  # marker v1's Studio defect
    ("kit_offsets", lambda: [_box("SM_KitA"), _box("SM_KitB", loc=(8, 0, 0))], None),  # several roots: a warning only
    ("auto_weighted_humanoid", _smooth_humanoid, None, lambda fmt: _skin_problems(fmt, raw_over=True)),
    ("auto_weighted_fallback", lambda: ops.bind_auto(*_two_shells("SK_TwoShells")), None, lambda fmt: _skin_problems(fmt, fallback=True)),
    ("quadriflow_rock", _quadriflow_rock, None, _quads_only),
    ("lod_chain_rock", _rock_lods, None, _lod_problems("SM_Rock", 4)),
    ("lod_chain_skinned", _skinned_lods, None, _lod_problems("SK_Column", 3, skinned=True)),
    ("over_influenced", _over_influenced, {f: "bone_influences" if f in _SKIN_BAD else None for f in FORMATS}, lambda fmt: _glb_repaired(fmt, "max_influences", 4)),
    ("unweighted", _half_weighted, {f: "unweighted_vertices" if f in _SKIN_BAD else None for f in FORMATS}, lambda fmt: _glb_repaired(fmt, "unweighted", 0)),
]


def _geometry_hash(obj):
    return hashlib.sha1(json.dumps(sorted([round(c, 4) for c in v.co] for v in obj.data.vertices)).encode()).hexdigest()[:12]


def _raises(fn, error):
    try:
        fn()
    except error as exc:
        return str(exc)
    raise AssertionError(f"expected {error.__name__}")


def _op_no_fallback():
    body, rig = _two_shells("SK_NoFallback")
    return _raises(lambda: ops.bind_auto(body, rig, fallback=None), RuntimeError)


def _op_quadriflow_refuses():
    fin = _edit(_box("SM_Fin"), _add_fin)
    before = _geometry_hash(fin)
    message = _raises(lambda: ops.quadriflow(fin, target_faces=300), RuntimeError)
    assert _geometry_hash(fin) == before, "mesh changed"
    return message


def _op_lod_refuses():
    """Ratios that do not decrease, and a box that cannot go below 2 triangles: LOD3 fails after
    LOD1 and LOD2 were made, and no copy may be left behind."""
    first = _raises(lambda: ops.lod_chain(_rock(), (0.5, 0.5)), ValueError)
    second = _raises(lambda: ops.lod_chain(_box("SM_Crate"), (0.5, 0.2, 0.1)), ValueError)
    left = sorted(o.name for o in bpy.data.objects)
    assert left == ["SM_Crate", "SM_Rock"], f"LOD copies left behind: {left}"
    return f"{first}; {second}"


def _op_noise_seeded():
    a, b, c = _rock("SM_A", seed=7), _rock("SM_B", seed=7), _rock("SM_C", seed=8)
    hashes = [_geometry_hash(o) for o in (a, b, c)]
    assert hashes[0] == hashes[1] != hashes[2], f"seeding broken: {hashes}"
    return f"seed 7 -> {hashes[0]}, seed 8 -> {hashes[2]}"


def _op_hashes():
    """Geometry hashes of the seeded ops, for comparing bpy versions (not pinned: a Blender
    upgrade may legitimately change remesher output)."""
    out = {"noise_displace": _geometry_hash(_rock("SM_Noise"))}
    out["quadriflow"] = _geometry_hash(ops.quadriflow(_rock("SM_Quad"), target_faces=600, seed=0))
    out["voxel_remesh"] = _geometry_hash(ops.voxel_remesh(_boxes("SM_Blockout", [(_CUBE, (0, 0, 0)), ((2, 2, 6), (1, 1, 2))]), voxel_size=0.2))
    return json.dumps(out)


# Op behaviour without export: refusals must raise, seeds must reproduce. (name, fn -> detail)
OP_CASES = [
    ("op_bind_auto_no_fallback", _op_no_fallback),
    ("op_quadriflow_refuses_fin", _op_quadriflow_refuses),
    ("op_lod_chain_refuses", _op_lod_refuses),
    ("op_noise_displace_seeded", _op_noise_seeded),
    ("op_geometry_hashes", _op_hashes),
]

# Export gate (qa.gated_export, what `template` ships): Studio puts an imported model's pivot at the
# file origin, so a single-root asset off the world origin must be blocked; kit pieces may be offset.
GATE_CASES = [
    ("gate_at_origin", lambda: [_box("SM_AtOrigin")], None),
    ("gate_off_origin", lambda: [_box("SM_OffOrigin", loc=(0, -0.75, 0))], "studio_pivot_at_origin"),
    ("gate_kit_offsets", lambda: [_box("SM_KitA"), _box("SM_KitB", loc=(8, 0, 0))], None),
]


def _agrees(summary, error):
    if error is None:
        return summary["pass"]
    return not summary["pass"] and any(e.endswith(":" + error) for e in summary["errors"])


def run(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = {"blender": bpy.app.version_string, "cases": [], "pass": True}
    for name, build, expected, *verify in CASES:
        env.reset()
        try:
            build()
        except Exception as exc:  # a builder op raised: this case fails, the others still run
            report["pass"] = False
            report["cases"].append({"case": name, "pass": False, "detail": f"build raised {type(exc).__name__}: {exc}"})
            print(f"qa-selftest {name:22s} FAIL build raised {type(exc).__name__}: {exc}")
            continue
        errors = expected if isinstance(expected, dict) else {fmt: expected for fmt in FORMATS}
        verdicts = {"source": qa.run(export_probe=False)["summary"]}
        problems = [f"source: {p}" for v in verify for p in v("source")]
        blend = out / f"{name}.blend"
        blend.unlink(missing_ok=True)  # no .blend1 backups on re-runs
        bpy.ops.wm.save_as_mainfile(filepath=str(blend), copy=True)
        files = {"blend": blend, "fbx": ops.export_fbx(out / f"{name}.fbx"), "glb": ops.export_glb(out / f"{name}.glb")}
        for fmt, path in files.items():
            verdicts[fmt] = qa.check_file(path)["summary"]
            problems += [f"{fmt}: {p}" for v in verify for p in v(fmt)]
        ok = all(_agrees(v, errors[fmt]) for fmt, v in verdicts.items()) and not problems
        report["pass"] = report["pass"] and ok
        shown = expected if isinstance(expected, dict) else expected or "pass"
        report["cases"].append({"case": name, "expected": shown, "pass": ok, "errors": {fmt: v["errors"] for fmt, v in verdicts.items()}, "problems": problems})
        got = "; ".join(f"{fmt}={v['errors'] or 'pass'}" for fmt, v in verdicts.items())
        print(f"qa-selftest {name:22s} {'OK  ' if ok else 'FAIL'} expected={json.dumps(shown) if isinstance(shown, dict) else shown} {got}" + (f" problems={problems}" if problems else ""))
    for name, fn in OP_CASES:
        env.reset()
        try:
            detail, ok = fn(), True
        except Exception as exc:  # an op that did not raise, or raised the wrong error
            detail, ok = f"{type(exc).__name__}: {exc}", False
        report["pass"] = report["pass"] and ok
        report["cases"].append({"case": name, "expected": "op behaviour", "pass": ok, "detail": detail})
        print(f"qa-selftest {name:22s} {'OK  ' if ok else 'FAIL'} {detail}")
    for name, build, error in GATE_CASES:
        env.reset()
        objects = build()
        result = qa.gated_export(objects, out / f"{name}.fbx", out / f"{name}.glb")
        shipped = bool(result["export"].get("files"))
        ok = _agrees(result["summary"], error) and shipped == (error is None)
        report["pass"] = report["pass"] and ok
        report["cases"].append({"case": name, "expected": error or "pass", "pass": ok, "errors": {"gate": result["summary"]["errors"]}, "shipped": shipped})
        print(f"qa-selftest {name:22s} {'OK  ' if ok else 'FAIL'} expected={error or 'pass'} gate={result['summary']['errors'] or 'pass'} shipped={shipped}")
    (out / "qa-selftest-report.json").write_text(json.dumps(report, indent=2))
    return report
