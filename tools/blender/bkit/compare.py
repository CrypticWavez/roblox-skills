"""`factory.py compare-export`: re-import FBX/GLB/glTF files and diff them against a Roblox
expectation (`roblox_expectation_v*.json` from the round trip or `<kind>_expectation.json` from a
template). The same measurements ImportInspector takes in Studio, taken headlessly:

- source "factory": the factory's own exports (the container stand-in; must pass).
- source "studio": a model exported from Studio with 3D Export (beta, glTF), which shows what
  Studio actually holds (textures, vertex colours, skinning) without trusting the EditableMesh
  reader. Its axis mapping is UNVERIFIED until the owner's first export (bkit/expectation.py).

Checks: scale (with the unit and axis diagnoses ImportInspector uses), triangles (1% slack),
front/up/side surface offsets, pivot at the base centre, appearance (the expected route
present: a colour map for palette/baked looks, enough distinct vertex colours for vertex_colors)
and animation count. A check the expectation cannot support fails as not checked."""
from pathlib import Path

import bpy

from . import env, expectation, qa


def _import(path):
    env.reset()
    suffix = Path(path).suffix.lower()
    if suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path), anim_offset=0.0)
    elif suffix in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=str(path))
    else:
        raise ValueError(f"compare-export: unsupported file {path}")
    bpy.context.view_layer.update()
    shapes = qa._bone_shapes()
    return [o for o in bpy.context.scene.objects if o.type == "MESH" and o not in shapes]


def _check(name, ok, value=None, expected=None, detail=None, checked=True):
    out = {"name": name, "pass": bool(ok) and checked, "value": value, "expected": expected}
    if detail:
        out["detail"] = detail
    if not checked:
        out["checked"] = False
        out["detail"] = "not checked: " + (detail or "")
    return out


def _same(a, b, tol):
    return abs(a - b) <= max(tol, abs(b) * tol)


def _offset(observed, expected):
    return abs(observed - expected) <= max(0.1, abs(expected) * 0.2)


def checks_for(measured, appearance, actions, exp):
    """Compare one file's measurements with an expectation (same rules as ImportInspector)."""
    tol = exp.get("tolerance", 0.05)
    out = []
    size, want = measured["size"], exp["size"]
    ok = all(_same(a, b, tol) for a, b in zip(size, want))
    detail = None
    if not ok:
        ratio = size[1] / want[1] if want[1] else 0
        swapped = _same(size[0], want[0], tol) and _same(size[1], want[2], tol) and _same(size[2], want[1], tol)
        detail = ("Y/Z swapped: export axis_up/forward wrong" if swapped
                  else "metre/stud mismatch" if abs(ratio - 3.571) < 0.2 or abs(ratio - 0.28) < 0.05
                  else "centimetre scale: FBX unit scale not applied" if abs(ratio - 100) < 5 or abs(ratio - 0.01) < 0.001
                  else "unexpected size")
    out.append(_check("scale", ok, size, want, detail))
    if exp.get("triangles") is None:
        out.append(_check("triangle_count", False, measured["triangles"], None, "expectation has no triangles", checked=False))
    else:
        slack = max(1, int(exp["triangles"] * 0.01))
        out.append(_check("triangle_count", abs(measured["triangles"] - exp["triangles"]) <= slack, measured["triangles"], exp["triangles"]))
    for key in ("front_offset", "up_offset", "side_offset"):
        if exp.get(key) is None:
            if key != "side_offset":
                out.append(_check(key, False, measured[key], None, f"expectation has no {key}", checked=False))
            continue
        ok = _offset(measured[key], exp[key])
        flipped = not ok and _offset(-measured[key], exp[key]) and abs(exp[key]) >= 0.1
        detail = None
        if flipped:
            detail = {"front_offset": "faces +Z (turned 180 degrees)", "up_offset": "upside down", "side_offset": "mirrored or turned along X"}[key]
        elif abs(exp[key]) < 0.1:
            detail = f"{key} under 0.1 studs: too small to tell a flip"
        out.append(_check(key, ok, measured[key], exp[key], detail))
    if exp.get("pivot") == "base-centre":
        off = measured["pivot_offset"]
        out.append(_check("pivot_base_centre", all(abs(v) <= tol for v in off), off, [0, 0, 0]))
    else:
        out.append(_check("pivot_base_centre", False, measured["pivot_offset"], exp.get("pivot"), "expectation has no pivot = base-centre", checked=False))
    want_look = exp.get("appearance")
    if want_look is None:
        out.append(_check("appearance", False, appearance, None, "expectation has no appearance block (pre-bake expectation)", checked=False))
    else:
        kind = want_look.get("kind")
        if kind in ("palette_atlas", "baked"):
            ok = "color" in appearance["maps"]
            out.append(_check("appearance", ok, appearance["maps"], {"color": want_look.get("maps", {}).get("color")}, None if ok else "no colour map on the import: colours lost (B06)"))
            for role in sorted(set(want_look.get("maps", {})) - {"color"}):
                out.append(_check(f"appearance_{role}", role in appearance["maps"], sorted(appearance["maps"]), role,
                                  None if role in appearance["maps"] else f"{role} map missing after import"))
        elif kind == "vertex_colors":
            want = want_look.get("palette", 2)
            out.append(_check("appearance", appearance["vertex_colors"] >= want, appearance["vertex_colors"], want, "distinct vertex colours"))
        elif kind == "library":
            out.append(_check("appearance", True, appearance["materials"], "library", "MaterialVariant is applied by SceneKit, not carried by the file"))
        else:
            out.append(_check("appearance", False, appearance, want_look, f"unknown appearance kind {kind!r}", checked=False))
    if exp.get("animations") is not None:
        out.append(_check("animations", actions >= exp["animations"], actions, exp["animations"]))
    return out


def compare_files(paths, exp, source="factory"):
    """Import each file in turn and compare it with the expectation. Returns
    {pass, files: [{file, pass, measured, appearance, checks, not_checked}]}."""
    results = []
    for path in paths:
        meshes = _import(path)
        if not meshes:
            results.append({"file": str(path), "pass": False, "checks": [_check("mesh_present", False, 0, ">=1")], "not_checked": []})
            continue
        roots = [o for o in bpy.context.scene.objects if o.parent is None and o.type in ("MESH", "ARMATURE", "EMPTY")]
        pivot = roots[0].matrix_world.translation if len(roots) == 1 else (0, 0, 0)
        measured = expectation.measure(meshes, frame=source, pivot=tuple(pivot))
        look = expectation.appearance_of(meshes)
        checks = checks_for(measured, look, len(bpy.data.actions), exp)
        results.append({
            "file": str(path),
            "pass": all(c["pass"] for c in checks),
            "measured": measured,
            "appearance": look,
            "checks": checks,
            "not_checked": [c["name"] for c in checks if c.get("checked") is False],
        })
    return {"pass": bool(results) and all(r["pass"] for r in results), "source": source, "files": results}
