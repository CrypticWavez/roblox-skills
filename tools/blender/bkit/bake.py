"""Colour and PBR transfer into maps Roblox reads (gap rows B06, B02). Studio's Import 3D drops
plain Principled base colours (2026-10-05 round trip: both marker parts arrived grey), so every
asset's look has to travel as an image texture or as vertex colours. Routes, in order of
preference (research blender-animation-pipeline section 3.2):

1. `palette_atlas` (the default for flat-coloured assets, which every template is): each material
   becomes a cell of one small image; each material's existing UV islands are moved into the
   inner half of its cell (non-zero area, inside 0..1, one UV set) and the slots collapse to one
   `MAT_<asset>` that reads the image. No Cycles: pixel-exact on every bpy version. Roughness,
   metalness and emissive maps are written only when the materials differ in them. The same
   colours also go into a `Color` attribute (face corners) as a fallback for an import that
   drops the texture (Studio multiplies vertex colours by the part Color, so that needs a white
   part; under a SurfaceAppearance they are masked by the colour map's alpha, which is opaque).
2. `vertex_colors`: the material colours as a `Color` attribute and one white material, no
   texture (stylised kits combined with Roblox materials).
3. `atlas_uvs` + `bake_maps`: a fresh non-overlapping UV layout and Cycles bakes of base colour,
   roughness, metalness, normal (tangent space, OpenGL: Blender's default +X +Y +Z swizzle) and
   emissive, for procedural shaders and high-to-low-poly detail. Deterministic: CPU, fixed
   samples and seed, no denoising.

Every route records `rbx_appearance` on each mesh (what the expectation and kit/1 cite) and
writes maps named `<asset>_Color.png` etc. (Studio's Reimport suffixes) with the pure-Python PNG
writer: 24-bit RGB colour and normal maps, 8-bit greyscale data maps."""
import math
from pathlib import Path

import bpy
from mathutils import Color, Vector

from . import env, ops, png, textures

CELL = 16  # px per palette cell: about four mip levels stay inside a cell (UNVERIFIED on Roblox)


def _next_pow2(n):
    return 1 << max(0, math.ceil(math.log2(max(1, n))))


def _srgb8(rgb_linear):
    """Scene-linear RGB -> 8-bit sRGB, as Blender's colour management converts it."""
    c = Color([max(0.0, min(1.0, v)) for v in rgb_linear[:3]]).from_scene_linear_to_srgb()
    return tuple(int(round(max(0.0, min(1.0, v)) * 255)) for v in c)


def _input_value(bsdf, name):
    socket = bsdf.inputs.get(name)
    if socket is None:
        return None
    if socket.is_linked:
        raise ValueError(f"{name} is driven by a node link")
    value = socket.default_value
    return tuple(value) if hasattr(value, "__len__") else float(value)


def flat_values(mat):
    """{base (linear RGBA), roughness, metallic, emission (linear RGB x strength)} of a material
    whose Principled inputs are plain values. Raises ValueError when an input is linked (a
    textured or procedural material needs `bake_maps`, not a palette)."""
    bsdf = ops.principled(mat, create=False) if mat is not None else None
    if bsdf is None:
        raise ValueError(f"{getattr(mat, 'name', None)}: no Principled BSDF")
    try:
        base = _input_value(bsdf, "Base Color")
        rough = _input_value(bsdf, "Roughness")
        metal = _input_value(bsdf, "Metallic")
        emit_color = _input_value(bsdf, "Emission Color") or (0, 0, 0, 1)
        emit_strength = _input_value(bsdf, "Emission Strength") or 0.0
    except ValueError as exc:
        raise ValueError(f"palette_atlas: {mat.name}: {exc}; use bake_maps for textured or procedural materials") from exc
    emission = tuple(c * emit_strength for c in emit_color[:3])
    return {"base": base, "roughness": rough, "metallic": metal, "emission": emission}


def _meshes(objects):
    return [o for o in objects if o.type == "MESH" and env.get_meta(o).get("qa_role") != "collision"]


def _library_name(mat):
    return mat.get("rbx_library") if mat is not None else None


def _single_uv(obj, keep):
    """Remove every UV layer except `keep`, rename it UVMap and make it active and render-active."""
    mesh = obj.data
    for layer in [l for l in mesh.uv_layers if l.name != keep]:
        mesh.uv_layers.remove(layer)
    layer = mesh.uv_layers[keep]
    layer.name = "UVMap"
    mesh.uv_layers.active = layer
    layer.active_render = True
    return layer


def _set_material(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    for poly in obj.data.polygons:
        poly.material_index = 0


def _purge(materials):
    for mat in materials:
        if mat is not None and mat.users == 0:
            bpy.data.materials.remove(mat)


def write_vertex_colors(obj, face_colors, name="Color", domain="CORNER"):
    """A BYTE_COLOR attribute from per-face sRGB 8-bit colours (domain CORNER keeps material
    borders hard on welded meshes; POINT averages shared vertices). Made active and render-active,
    which is what ops.export_glb (ACTIVE) and export_fbx (active first) write."""
    mesh = obj.data
    old = mesh.color_attributes.get(name)
    if old is not None:
        mesh.color_attributes.remove(old)
    attr = mesh.color_attributes.new(name, "BYTE_COLOR", domain)
    if domain == "CORNER":
        for poly in mesh.polygons:
            rgb = face_colors[poly.index]
            for li in poly.loop_indices:
                attr.data[li].color_srgb = (rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, 1.0)
    else:
        sums = {}
        for poly in mesh.polygons:
            for vi in poly.vertices:
                sums.setdefault(vi, []).append(face_colors[poly.index])
        for vi, cols in sums.items():
            attr.data[vi].color_srgb = tuple(sum(c[i] for c in cols) / len(cols) / 255 for i in range(3)) + (1.0,)
    mesh.color_attributes.active_color = attr
    mesh.color_attributes.render_color_index = list(mesh.color_attributes).index(attr)
    return attr


def _record(objects, appearance):
    for obj in objects:
        env.set_meta(obj, appearance=appearance)
    return appearance


def palette_atlas(objects, out_dir, asset, cell=CELL, vertex_colors=True):
    """Bake the flat materials of `objects` (meshes; collision proxies and meshes whose material
    carries `rbx_library` are left alone) into one palette atlas. Writes `<asset>_Color.png` and,
    when the materials differ in them, `_Roughness`, `_Metalness`, `_Emissive` (8-bit greyscale);
    gives every baked mesh one material `MAT_<asset>`, one UV set inside 0..1 and (vertex_colors)
    a `Color` attribute. Returns the appearance record (also stored as rbx_appearance):
    {kind, maps, palette, cell_px, size, vertex_colors, cells}. Raises ValueError for a mesh
    mixing library and flat materials, a material driven by node links, or nothing to bake."""
    out = Path(out_dir).resolve()  # absolute: image paths must not depend on the cwd
    meshes, library = [], []
    for obj in _meshes(objects):
        names = {_library_name(m) for m in obj.data.materials}
        if names == {None}:
            meshes.append(obj)
        elif None in names:
            raise ValueError(f"palette_atlas: {obj.name} mixes library and flat materials; split it (a MeshPart takes one MaterialVariant)")
        else:
            library.append(obj)
    for obj in library:
        env.set_meta(obj, appearance={"kind": "library", "materials": sorted(f"library:{_library_name(m)}" for m in obj.data.materials)})
    if not meshes:
        if library:
            return {"kind": "library", "meshes": [o.name for o in library]}
        raise ValueError("palette_atlas: no meshes to bake")
    used = {}
    for obj in meshes:
        if not obj.data.materials:
            raise ValueError(f"palette_atlas: {obj.name} has no material")
        for poly in obj.data.polygons:
            mat = obj.data.materials[poly.material_index] if poly.material_index < len(obj.data.materials) else None
            if mat is None:
                raise ValueError(f"palette_atlas: {obj.name} has faces without a material")
            used[mat.name] = mat
    mats = [used[name] for name in sorted(used)]
    values = {m.name: flat_values(m) for m in mats}
    n = len(mats)
    cols = math.ceil(math.sqrt(n))
    rows = math.ceil(n / cols)
    size = _next_pow2(max(cols, rows) * cell)
    cells = {m.name: (i % cols, i // cols) for i, m in enumerate(mats)}
    srgb = {name: _srgb8(v["base"]) for name, v in values.items()}

    def image(fill, background):
        grid = [[background] * size for _ in range(size)]
        for name, (cx, cy) in cells.items():
            for y in range(cy * cell, (cy + 1) * cell):
                for x in range(cx * cell, (cx + 1) * cell):
                    grid[y][x] = fill(name)
        return grid

    def flat(grid):
        return [[c for px in row for c in (px if isinstance(px, tuple) else (px,))] for row in grid]

    maps = {}
    color = image(lambda name: srgb[name], (128, 128, 128))
    png.write(out / textures.map_name(asset, "color"), size, size, flat(color), "RGB")
    maps["color"] = textures.map_name(asset, "color")
    constants = {}
    for role, key in (("roughness", "roughness"), ("metalness", "metallic")):
        levels = {name: int(round(max(0.0, min(1.0, v[key])) * 255)) for name, v in values.items()}
        if len(set(levels.values())) > 1:
            png.write(out / textures.map_name(asset, role), size, size, flat(image(lambda name: levels[name], 0)), "L")
            maps[role] = textures.map_name(asset, role)
        else:
            constants[key] = next(iter(levels.values())) / 255
    emissive = {name: int(round(max(0.0, min(1.0, max(v["emission"])) ) * 255)) for name, v in values.items()}
    if any(emissive.values()):
        png.write(out / textures.map_name(asset, "emissive"), size, size, flat(image(lambda name: emissive[name], 0)), "L")
        maps["emissive"] = textures.map_name(asset, "emissive")

    # UVs: each material's islands (per mesh) scaled into the inner half of its cell.
    quarter = cell / 4 / size
    for obj in meshes:
        mesh = obj.data
        if not mesh.uv_layers:
            ops.box_uv(obj)
        layer = mesh.uv_layers.active or mesh.uv_layers[0]
        uv = layer.data
        by_mat = {}
        for poly in mesh.polygons:
            by_mat.setdefault(mesh.materials[poly.material_index].name, []).append(poly)
        for name, polys in by_mat.items():
            loops = [li for p in polys for li in p.loop_indices]
            us = [uv[li].uv[0] for li in loops]
            vs = [uv[li].uv[1] for li in loops]
            u0, v0 = min(us), min(vs)
            span = max(max(us) - u0, max(vs) - v0, 1e-9)
            cx, cy = cells[name]
            left = cx * cell / size + quarter
            bottom = 1 - (cy + 1) * cell / size + quarter
            scale = 2 * quarter / span
            for li in loops:
                u, v = uv[li].uv
                uv[li].uv = (left + (u - u0) * scale, bottom + (v - v0) * scale)
        _single_uv(obj, layer.name)
    images = {role: textures.load_map(out / file, role) for role, file in maps.items()}
    for image_ in images.values():
        image_.filepath = bpy.path.relpath(str(out / image_.name)) if bpy.data.filepath else str(out / image_.name)
    mat = textures.material_from_maps(f"MAT_{asset}", images, constants)
    old = list(mats)
    for obj in meshes:
        face_colors = [srgb[obj.data.materials[p.material_index].name] for p in obj.data.polygons]
        _set_material(obj, mat)
        if vertex_colors:
            write_vertex_colors(obj, face_colors)
    _purge(old)
    appearance = {
        "kind": "palette_atlas",
        "maps": maps,
        "palette": n,
        "cell_px": cell,
        "size": [size, size],
        "vertex_colors": "Color" if vertex_colors else None,
        "cells": {name: {"cell": list(cells[name]), "srgb": list(srgb[name])} for name in sorted(cells)},
        "material": mat.name,
    }
    _record(meshes, appearance)
    return {**appearance, "meshes": [o.name for o in meshes], "files": {role: str(out / f) for role, f in maps.items()}}


def vertex_colors(objects, asset, domain="CORNER"):
    """Material colours as a `Color` attribute plus one material `MAT_<asset>_VC` whose base colour
    reads it (roughness and metallic averaged over faces). No texture: in Studio the MeshPart's
    Color must be white because Studio multiplies vertex colours by it."""
    meshes = _meshes(objects)
    if not meshes:
        raise ValueError("vertex_colors: no meshes")
    mat = bpy.data.materials.get(f"MAT_{asset}_VC") or bpy.data.materials.new(f"MAT_{asset}_VC")
    tree = ops.node_tree(mat)
    bsdf = ops.principled(mat)
    node = next((n for n in tree.nodes if n.type == "VERTEX_COLOR"), None) or tree.nodes.new("ShaderNodeVertexColor")
    node.layer_name = "Color"
    tree.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
    colours, rough, metal, faces, old = set(), 0.0, 0.0, 0, []
    for obj in meshes:
        face_colors = []
        for poly in obj.data.polygons:
            v = flat_values(obj.data.materials[poly.material_index])
            face_colors.append(_srgb8(v["base"]))
            rough += v["roughness"]
            metal += v["metallic"]
            faces += 1
        colours.update(face_colors)
        old += list(obj.data.materials)
        _set_material(obj, mat)
        write_vertex_colors(obj, face_colors, domain=domain)
    bsdf.inputs["Roughness"].default_value = rough / max(1, faces)
    bsdf.inputs["Metallic"].default_value = metal / max(1, faces)
    _purge(set(old))
    appearance = {"kind": "vertex_colors", "maps": {}, "palette": len(colours), "vertex_colors": "Color", "domain": domain, "material": mat.name, "part_color": [255, 255, 255]}
    _record(meshes, appearance)
    return {**appearance, "meshes": [o.name for o in meshes]}


def _enum(op, prop, wanted):
    items = [i.identifier for i in op.get_rna_type().properties[prop].enum_items]
    if wanted not in items:
        raise RuntimeError(f"{prop}: {wanted!r} not in this Blender's {items}")
    return wanted


def atlas_uvs(obj, size=1024, margin_px=16, angle_limit=66.0, shape="AABB"):
    """A fresh non-overlapping UV layout in a new `AtlasUV` layer: Smart UV Project, then island
    packing with a margin of `margin_px` at `size` (the packer keeps at least that much space
    around each island). shape "AABB" with axis-aligned rotation packs instantly; "CONCAVE"
    packs tighter but took 2-80 s per mesh on bpy 5.0 (with free rotation), so it is opt-in.
    The other layers stay until `bake_maps` finishes (shaders may still sample through them).
    Runs headless: the operators need an edit-mode mesh, not a UV editor. Returns the layer name."""
    mesh = obj.data
    layer = mesh.uv_layers.get("AtlasUV") or mesh.uv_layers.new(name="AtlasUV")
    render = next((l for l in mesh.uv_layers if l.active_render), None)
    mesh.uv_layers.active = layer
    if render is not None:
        render.active_render = True  # image nodes without a UV input keep reading the old layout
    shape = _enum(bpy.ops.uv.pack_islands, "shape_method", shape)
    margin_method = _enum(bpy.ops.uv.pack_islands, "margin_method", "FRACTION")
    rotate_method = _enum(bpy.ops.uv.pack_islands, "rotate_method", "AXIS_ALIGNED" if shape == "AABB" else "CARDINAL")
    layer_objects = bpy.context.view_layer.objects
    layer_objects.active = obj  # edit-mode operators read the view layer's active object, not the override
    for other in layer_objects:
        other.select_set(other is obj)
    with bpy.context.temp_override(active_object=obj, object=obj, edit_object=obj, selected_objects=[obj], selected_editable_objects=[obj]):
        bpy.ops.object.mode_set(mode="EDIT")
        if obj.mode != "EDIT":
            raise RuntimeError(f"atlas_uvs: {obj.name} did not enter edit mode (hidden or not in the view layer?)")
        try:
            bpy.ops.mesh.select_all(action="SELECT")
            bpy.ops.uv.smart_project(angle_limit=math.radians(angle_limit), island_margin=0.0, scale_to_bounds=False)
            bpy.ops.uv.pack_islands(shape_method=shape, margin_method=margin_method, margin=margin_px / size, rotate=True, rotate_method=rotate_method)
        finally:
            bpy.ops.object.mode_set(mode="OBJECT")
    _fit_unit_square(mesh.uv_layers["AtlasUV"], margin_px / size)
    return "AtlasUV"


def _fit_unit_square(layer, margin):
    """Scale and move a packed layout uniformly into [margin, 1 - margin] when the packer left
    corners outside 0..1 (it can with large margins); islands keep their relative spacing."""
    uv = layer.data
    us = [d.uv[0] for d in uv]
    vs = [d.uv[1] for d in uv]
    if not us or (min(us) >= 0 and min(vs) >= 0 and max(us) <= 1 and max(vs) <= 1):
        return
    span = max(max(us) - min(us), max(vs) - min(vs), 1e-9)
    scale = (1 - 2 * margin) / span
    u0, v0 = min(us), min(vs)
    for d in uv:
        d.uv = (margin + (d.uv[0] - u0) * scale, margin + (d.uv[1] - v0) * scale)


def uv_triangles(obj, layer=None):
    """UV triangles of obj per face: [(face index, ((u, v), (u, v), (u, v))), ...]."""
    mesh = obj.data
    uv = (mesh.uv_layers[layer] if layer else mesh.uv_layers.active).data
    mesh.calc_loop_triangles()
    return [(t.polygon_index, tuple(tuple(uv[li].uv) for li in t.loops)) for t in mesh.loop_triangles]


def uv_islands(obj, layer=None):
    """Face index lists of the UV islands (faces sharing a UV-space edge)."""
    mesh = obj.data
    uv = (mesh.uv_layers[layer] if layer else mesh.uv_layers.active).data
    key = lambda li: (mesh.loops[li].vertex_index, round(uv[li].uv[0], 5), round(uv[li].uv[1], 5))  # noqa: E731
    parent = list(range(len(mesh.polygons)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    edges = {}
    for poly in mesh.polygons:
        loops = list(poly.loop_indices)
        for a, b in zip(loops, loops[1:] + loops[:1]):
            edge = tuple(sorted((key(a), key(b))))
            if edge in edges:
                ra, rb = find(edges[edge]), find(poly.index)
                parent[max(ra, rb)] = min(ra, rb)
            else:
                edges[edge] = poly.index
    groups = {}
    for poly in mesh.polygons:
        groups.setdefault(find(poly.index), []).append(poly.index)
    return list(groups.values())


def _seg_dist(p, q, r, s):
    """Distance between 2D segments pq and rs (0 when they cross)."""
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    d1, d2, d3, d4 = cross(r, s, p), cross(r, s, q), cross(p, q, r), cross(p, q, s)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and d1 and d2 and d3 and d4:
        return 0.0

    def point_seg(a, b, c):
        dx, dy = c[0] - b[0], c[1] - b[1]
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((a[0] - b[0]) * dx + (a[1] - b[1]) * dy) / length))
        return math.hypot(a[0] - b[0] - t * dx, a[1] - b[1] - t * dy)

    return min(point_seg(p, r, s), point_seg(q, r, s), point_seg(r, p, q), point_seg(s, p, q))


def _inside(pt, tri):
    (ax, ay), (bx, by), (cx, cy) = tri
    d1 = (pt[0] - bx) * (ay - by) - (ax - bx) * (pt[1] - by)
    d2 = (pt[0] - cx) * (by - cy) - (bx - cx) * (pt[1] - cy)
    d3 = (pt[0] - ax) * (cy - ay) - (cx - ax) * (pt[1] - ay)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


def island_gap(obj, layer=None):
    """Smallest UV-space distance between triangles of different islands (0 when two islands
    overlap) and the UV bounds: proof that a packed layout keeps its margin."""
    islands = uv_islands(obj, layer)
    island_of = {f: i for i, faces in enumerate(islands) for f in faces}
    tris = [(island_of[f], t) for f, t in uv_triangles(obj, layer)]
    boxes = [(min(p[0] for p in t), min(p[1] for p in t), max(p[0] for p in t), max(p[1] for p in t)) for _, t in tris]
    best = math.inf
    for i in range(len(tris)):
        for j in range(i + 1, len(tris)):
            if tris[i][0] == tris[j][0]:
                continue
            a, b = boxes[i], boxes[j]
            if a[0] - b[2] > best or b[0] - a[2] > best or a[1] - b[3] > best or b[1] - a[3] > best:
                continue
            ti, tj = tris[i][1], tris[j][1]
            if any(_inside(p, tj) for p in ti) or any(_inside(p, ti) for p in tj):
                return 0.0, len(islands)
            for k in range(3):
                for m in range(3):
                    best = min(best, _seg_dist(ti[k], ti[(k + 1) % 3], tj[m], tj[(m + 1) % 3]))
    return best, len(islands)


def _image(name, size, role):
    image = bpy.data.images.new(name, size, size, alpha=False, float_buffer=False)
    image.colorspace_settings.name = textures.COLORSPACE[role]
    return image


def _swap_to_emission(mat, input_name):
    """Route a Principled input (its link or value) into an Emission shader on the output, so an
    EMIT bake writes that input exactly (Cycles has no Metallic bake type, and the DIFFUSE colour
    pass darkens metallic albedo). Returns a restore function."""
    tree = ops.node_tree(mat)
    bsdf = ops.principled(mat)
    output = ops.material_output(mat)
    surface = output.inputs["Surface"]
    previous = surface.links[0].from_socket if surface.is_linked else None
    emit = tree.nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = 1.0
    source = bsdf.inputs[input_name]
    if source.is_linked:
        tree.links.new(source.links[0].from_socket, emit.inputs["Color"])
    else:
        value = source.default_value
        emit.inputs["Color"].default_value = tuple(value) if hasattr(value, "__len__") else (value, value, value, 1.0)
    tree.links.new(emit.outputs[0], surface)

    def restore():
        tree.nodes.remove(emit)
        if previous is not None:
            tree.links.new(previous, surface)
    return restore


BAKE_PASSES = {  # role -> (bake type, Principled input routed through emission or None, pass filter)
    "color": ("EMIT", "Base Color", None),
    "roughness": ("ROUGHNESS", None, None),
    "metalness": ("EMIT", "Metallic", None),
    "normal": ("NORMAL", None, None),
    "emissive": ("EMIT", None, None),
}


def bake_maps(obj, out_dir, asset, maps=("color", "roughness", "metalness", "normal"), size=1024, margin=None, high=None, cage_extrusion=0.02, samples=1, seed=0):
    """Cycles (CPU) bakes of obj's materials into `<asset>_<Map>.png` on an `AtlasUV` layout
    (made with `atlas_uvs` when missing), then one material `MAT_<asset>` reading them and a
    single UV set. Colour and metalness bake through an emission swap (exact values); roughness
    bakes ROUGHNESS; normal bakes tangent space with Blender's default swizzle (+X +Y +Z, OpenGL),
    from `high` onto obj (Selected to Active, `cage_extrusion`) when given. EXTEND margin of
    `margin` px (default size / 64: 16 px at 1024). samples/seed fixed and denoising off, so the
    same input gives the same pixels."""
    out = Path(out_dir).resolve()
    margin = max(2, size // 64) if margin is None else margin
    scene = bpy.context.scene
    try:
        scene.render.engine = "CYCLES"
    except TypeError as exc:  # the message lists the engines this build has
        raise RuntimeError(f"bake_maps needs Cycles: {exc}") from exc
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.seed = seed
    scene.cycles.use_denoising = False
    if "AtlasUV" not in obj.data.uv_layers:
        atlas_uvs(obj, size=size, margin_px=margin)
    mats = [m for m in obj.data.materials if m is not None]
    if not mats:
        raise ValueError(f"bake_maps: {obj.name} has no material")
    layer = bpy.context.view_layer
    for o in layer.objects:
        o.select_set(o is obj or o is high)
    layer.objects.active = obj
    written = {}
    for role in maps:
        kind, swap, pass_filter = BAKE_PASSES[role]
        image = _image(f"bake_{asset}_{role}", size, role)
        restores, temp = [], []
        for mat in mats:
            node = ops.node_tree(mat).nodes.new("ShaderNodeTexImage")
            node.image = image
            ops.node_tree(mat).nodes.active = node
            temp.append((mat, node))
            if swap:
                restores.append(_swap_to_emission(mat, swap))
        kwargs = {"type": _enum(bpy.ops.object.bake, "type", kind), "uv_layer": "AtlasUV", "margin": margin, "margin_type": "EXTEND", "use_clear": True, "target": "IMAGE_TEXTURES"}
        if pass_filter:
            kwargs["pass_filter"] = pass_filter
        if role == "normal":
            kwargs.update(normal_space="TANGENT", normal_r="POS_X", normal_g="POS_Y", normal_b="POS_Z")
            if high is not None:
                kwargs.update(use_selected_to_active=True, cage_extrusion=cage_extrusion)
        try:
            selected = [obj, high] if (role == "normal" and high is not None) else [obj]
            with bpy.context.temp_override(active_object=obj, object=obj, selected_objects=selected, selected_editable_objects=selected):
                result = bpy.ops.object.bake(**kwargs)
            if result != {"FINISHED"}:
                raise RuntimeError(f"bake_maps: {role} bake returned {result}")
        finally:
            for restore in restores:
                restore()
            for mat, node in temp:
                ops.node_tree(mat).nodes.remove(node)
        pixels = image.pixels[:]
        rows = []
        for y in reversed(range(size)):  # Blender stores bottom-up, PNG top-down
            row = pixels[y * size * 4:(y + 1) * size * 4]
            if textures.MODE[role] == "L":
                rows.append([int(round(row[i] * 255)) for i in range(0, len(row), 4)])
            else:
                rows.append([int(round(row[i + c] * 255)) for i in range(0, len(row), 4) for c in range(3)])
        file = textures.map_name(asset, role)
        png.write(out / file, size, size, rows, textures.MODE[role])
        bpy.data.images.remove(image)
        written[role] = file
    images = {role: textures.load_map(out / file, role) for role, file in written.items()}
    for image in images.values():
        image.filepath = bpy.path.relpath(str(out / image.name)) if bpy.data.filepath else str(out / image.name)
    mat = textures.material_from_maps(f"MAT_{asset}", images, {"roughness": 0.5, "metallic": 0.0})
    old = list(obj.data.materials)
    _set_material(obj, mat)
    _single_uv(obj, "AtlasUV")
    _purge(old)
    appearance = {"kind": "baked", "maps": written, "size": [size, size], "samples": samples, "seed": seed, "margin_px": margin, "high": high.name if high is not None else None, "material": mat.name, "vertex_colors": None}
    _record([obj], appearance)
    return {**appearance, "files": {role: str(out / f) for role, f in written.items()}}


def sample_map(path, uv):
    """Pixel of a PNG map at UV (u, v) (v up, as Blender stores UVs), nearest pixel."""
    image = png.read(path)
    x = min(image["width"] - 1, max(0, int(uv[0] * image["width"])))
    y = min(image["height"] - 1, max(0, int((1 - uv[1]) * image["height"])))
    return png.pixel(image, x, y)


def face_uv_centres(obj):
    """{face index: UV centroid} of obj's active UV layer."""
    mesh = obj.data
    uv = mesh.uv_layers.active.data
    out = {}
    for poly in mesh.polygons:
        pts = [Vector(uv[li].uv) for li in poly.loop_indices]
        out[poly.index] = tuple(sum(pts, Vector((0, 0))) / len(pts))
    return out
