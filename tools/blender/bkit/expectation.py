"""Roblox-side measurements of an asset and the expectation JSON that ImportInspector (Studio) and
`factory.py compare-export` (container) check an import against.

Axes. Studio's Import 3D of the factory's FBX (2026-10-05, reports/studio/roundtrip-2026-10-05.json)
kept the asset's front (Blender -Y) at Roblox -Z and its up (Blender +Z) at Roblox +Y; the
surface-centroid offsets matched to 0.001 studs. A proper rotation that does that maps Blender
(x, y, z) to Roblox (-x, z, y). The X sign is derived, not observed (the marker was symmetric in
X): the marker now carries a side fin so the next import measures it (`side_offset`).
A Studio 3D Export (glTF, beta) re-imported into Blender arrives through the glTF importer's
Y-up conversion instead: Roblox (x, y, z) = Blender (x, z, -y), assuming the exporter writes
Roblox axes unchanged (UNVERIFIED)."""
from mathutils import Vector

import bpy

from . import env, textures

FRAMES = {
    "factory": lambda v: (-v[0], v[2], v[1]),  # factory FBX/GLB as Studio imports it
    "studio": lambda v: (v[0], v[2], -v[1]),  # a Studio 3D Export (glTF) as Blender imports it (UNVERIFIED)
}


def to_roblox(v, frame="factory"):
    return FRAMES[frame](v)


def _triangles(meshes):
    """World-space triangles of the evaluated meshes in rest pose."""
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    previous = {a.name: a.data.pose_position for a in armatures}
    for a in armatures:
        a.data.pose_position = "REST"
    depsgraph = bpy.context.evaluated_depsgraph_get()
    tris = []
    for obj in meshes:
        ev = obj.evaluated_get(depsgraph)
        mesh = ev.to_mesh()
        mesh.calc_loop_triangles()
        pts = [obj.matrix_world @ v.co for v in mesh.vertices]
        tris += [tuple(pts[i] for i in t.vertices) for t in mesh.loop_triangles]
        ev.to_mesh_clear()
    for a in armatures:
        a.data.pose_position = previous[a.name]
    return tris


def measure(meshes, frame="factory", pivot=(0, 0, 0)):
    """Size, bounds, triangle count and surface offsets of `meshes` in Roblox axes: front_offset is
    the bounds centre minus the area-weighted surface centroid along -Z, up_offset the centroid
    minus the centre along +Y, side_offset along +X (ImportInspector's definitions). pivot: the
    model pivot (Blender world), reported as an offset from the base centre."""
    bpy.context.view_layer.update()
    tris = _triangles(meshes)
    if not tris:
        raise ValueError("measure: no triangles")
    pts = [to_roblox(p, frame) for t in tris for p in t]
    mn = [min(p[i] for p in pts) for i in range(3)]
    mx = [max(p[i] for p in pts) for i in range(3)]
    mid = [(a + b) / 2 for a, b in zip(mn, mx)]
    total, acc = 0.0, Vector()
    for t in tris:
        a, b, c = (Vector(to_roblox(p, frame)) for p in t)
        area = (b - a).cross(c - a).length / 2
        total += area
        acc += area * (a + b + c) / 3
    centroid = acc / total
    base = [mid[0], mn[1], mid[2]]
    piv = to_roblox(pivot, frame)
    return {
        "size": [round(b - a, 3) for a, b in zip(mn, mx)],
        "min": [round(v, 3) for v in mn],
        "max": [round(v, 3) for v in mx],
        "triangles": len(tris),
        "front_offset": round(mid[2] - centroid.z, 3),
        "up_offset": round(centroid.y - mid[1], 3),
        "side_offset": round(centroid.x - mid[0], 3),
        "pivot_offset": [round(p - b, 3) for p, b in zip(piv, base)],
    }


def appearance_of(meshes):
    """What the meshes carry for their look: materials, maps by role (image names and sizes),
    colour attributes and their distinct colours (sRGB bytes)."""
    mats, maps, distinct, attrs = set(), {}, set(), set()
    for obj in meshes:
        for mat in obj.data.materials:
            if mat is None:
                continue
            mats.add(mat.name)
            for image, roles in textures.image_roles(mat).items():
                for role in roles:
                    maps.setdefault(role, set()).add((image.name, tuple(image.size)))
        for attr in obj.data.color_attributes:
            attrs.add(attr.name)
            for d in attr.data:
                distinct.add(tuple(int(round(c * 255)) for c in d.color_srgb[:3]))
    return {
        "materials": sorted(mats),
        "maps": {role: sorted(f"{n} {s[0]}x{s[1]}" for n, s in v) for role, v in sorted(maps.items())},
        "color_attributes": sorted(attrs),
        "vertex_colors": len(distinct),
    }


def expectation(asset, meshes, revision=1, appearance=None, extra=None):
    """The roblox_expectation JSON for an asset built in this scene (factory frame)."""
    m = measure(meshes)
    record = appearance or next((env.get_meta(o).get("appearance") for o in meshes if env.get_meta(o).get("appearance")), None)
    out = {
        "asset": asset,
        "revision": revision,
        "units": "studs (import with Scale Unit = Studs)",
        "axes": "Roblox: x = -Blender x, y = Blender z, z = Blender y (front -Z, derived; see bkit/expectation.py)",
        "size": m["size"],
        "front": "-Z",
        "front_offset": m["front_offset"],
        "up_offset": m["up_offset"],
        "side_offset": m["side_offset"],
        "pivot": "base-centre",
        "materials": sorted({mat.name for o in meshes for mat in o.data.materials if mat is not None}),
        "triangles": m["triangles"],
        "tolerance": 0.05,
    }
    if record:
        out["appearance"] = {k: record[k] for k in ("kind", "maps", "palette", "vertex_colors", "material", "part_color") if k in record and record[k] is not None}
    if extra:
        out.update(extra)
    return out
