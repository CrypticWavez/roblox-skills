"""Reusable, deterministic modelling operations built on bmesh/modifiers (no viewport needed).

Every op returns the object it created or changed so builders can chain them. Destructive
steps (apply_modifiers, apply_transforms) are explicit; nothing is applied implicitly, except
that the retopology ops (voxel_remesh, quadriflow) bake the modifier stack they replace.
"""
import math
import random
from contextlib import contextmanager

import bmesh
import bpy
from mathutils import Matrix, Vector, geometry, noise
from mathutils.bvhtree import BVHTree

from . import env


def _new_object(name, mesh, coll=None):
    obj = bpy.data.objects.new(name, mesh)
    (coll or bpy.context.scene.collection).objects.link(obj)
    return obj


def _mesh_from_bmesh(name, bm):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    return mesh


# ---------- primitives (pivot at base centre unless noted) ----------

def box(name, size=(1, 1, 1), location=(0, 0, 0), coll=None, base_pivot=True):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if base_pivot:
        bmesh.ops.translate(bm, vec=Vector((0, 0, size[2] / 2)), verts=bm.verts)
    obj = _new_object(name, _mesh_from_bmesh(name, bm), coll)
    obj.location = location
    return obj


def cylinder(name, radius=0.5, depth=1.0, segments=16, location=(0, 0, 0), coll=None, base_pivot=True, axis="Z"):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius, radius2=radius, depth=depth)
    if base_pivot:
        bmesh.ops.translate(bm, vec=Vector((0, 0, depth / 2)), verts=bm.verts)
    if axis == "X":
        bmesh.ops.rotate(bm, cent=Vector(), matrix=Matrix.Rotation(math.radians(90), 3, "Y"), verts=bm.verts)
    elif axis == "Y":
        bmesh.ops.rotate(bm, cent=Vector(), matrix=Matrix.Rotation(math.radians(-90), 3, "X"), verts=bm.verts)
    obj = _new_object(name, _mesh_from_bmesh(name, bm), coll)
    obj.location = location
    return obj


def sphere(name, radius=0.5, segments=16, rings=8, location=(0, 0, 0), coll=None):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
    obj = _new_object(name, _mesh_from_bmesh(name, bm), coll)
    obj.location = location
    return obj


def icosphere(name, radius=0.5, subdivisions=2, location=(0, 0, 0), coll=None):
    """Evenly tessellated sphere (centre pivot): the usual base for rocks and blobs."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdivisions, radius=radius)
    obj = _new_object(name, _mesh_from_bmesh(name, bm), coll)
    obj.location = location
    return obj


def wedge(name, size=(1, 1, 1), location=(0, 0, 0), coll=None):
    """Roblox WedgePart geometry in Blender axes. The vertical face is at Roblox +Z (back),
    which is Blender -Y; the slope faces Roblox front (-Z = Blender +Y)."""
    sx, sy, sz = (s / 2 for s in size)
    bm = bmesh.new()
    v = [bm.verts.new(p) for p in [(-sx, -sy, -sz), (sx, -sy, -sz), (sx, sy, -sz), (-sx, sy, -sz), (-sx, -sy, sz), (sx, -sy, sz)]]
    for face in [(0, 3, 2, 1), (0, 1, 5, 4), (3, 4, 5, 2), (0, 4, 3), (1, 2, 5)]:
        bm.faces.new([v[i] for i in face])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = _new_object(name, _mesh_from_bmesh(name, bm), coll)
    obj.location = location
    return obj


# ---------- edit operations (bmesh, deterministic) ----------

def _edit(obj, fn):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    result = fn(bm)
    bm.normal_update()
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return result


def faces_facing(bm, direction, threshold=0.9):
    d = Vector(direction).normalized()
    return [f for f in bm.faces if f.normal.dot(d) > threshold]


def extrude(obj, direction=(0, 0, 1), distance=1.0, select=None):
    """Extrude faces facing `direction` (or a custom selector) along their normal."""
    def run(bm):
        faces = select(bm) if select else faces_facing(bm, direction)
        out = bmesh.ops.extrude_face_region(bm, geom=faces)
        verts = [g for g in out["geom"] if isinstance(g, bmesh.types.BMVert)]
        bmesh.ops.translate(bm, vec=Vector(direction).normalized() * distance, verts=verts)
        bmesh.ops.delete(bm, geom=faces, context="FACES")
        return len(faces)
    _edit(obj, run)
    return obj


def inset(obj, directions=((0, 0, 1),), thickness=0.1, depth=0.0):
    """Inset every face facing any of `directions` (selected once, so earlier insets'
    side walls are never re-selected) as individual panels."""
    def run(bm):
        faces = []
        for direction in directions:
            faces += [f for f in faces_facing(bm, direction) if f not in faces]
        bmesh.ops.inset_individual(bm, faces=faces, thickness=thickness, depth=depth)
    _edit(obj, run)
    return obj


def noise_displace(obj, strength=0.5, scale=1.0, seed=0, octaves=4):
    """Seeded fractal-noise displacement along vertex normals in object space: the scripted
    stand-in for sculpting rocks, cliffs and terrain pieces (brush sculpting needs a viewport).
    The seed picks an offset into Perlin noise space, so the same mesh, seed and settings give
    the same vertices on every bpy version tested (5.0.1, 5.1.2, 5.2.2). Displacement is about
    +-strength studs; scale is noise features per stud. Needs a welded mesh with enough
    vertices to show (`icosphere`, `voxel_remesh`); split vertices would crack apart."""
    rng = random.Random(seed)
    offset = Vector([rng.uniform(-100.0, 100.0) for _ in range(3)])

    def run(bm):
        bm.normal_update()
        moves = [(v, v.normal * (strength * noise.fractal(v.co * scale + offset, 1.0, 2.0, octaves))) for v in bm.verts]
        for v, move in moves:
            v.co += move
    _edit(obj, run)
    return obj


def bevel(obj, width=0.05, segments=2, limit_angle=30):
    mod = obj.modifiers.new("Bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(limit_angle)
    return mod


def boolean(obj, cutter, operation="DIFFERENCE", hide_cutter=True):
    mod = obj.modifiers.new("Boolean_" + cutter.name, "BOOLEAN")
    mod.object = cutter
    mod.operation = operation
    mod.solver = "EXACT"
    if hide_cutter:
        cutter.hide_render = True
        cutter.display_type = "WIRE"
        cutter["rbx_cutter"] = True
    return mod


def mirror(obj, axis="X", merge=True):
    mod = obj.modifiers.new("Mirror", "MIRROR")
    mod.use_axis = [axis == "X", axis == "Y", axis == "Z"]
    mod.use_clip = merge
    mod.use_mirror_merge = merge
    return mod


def array(obj, count=3, offset=(1.0, 0, 0), relative=True):
    mod = obj.modifiers.new("Array", "ARRAY")
    mod.count = count
    mod.use_relative_offset = relative
    mod.use_constant_offset = not relative
    if relative:
        mod.relative_offset_displace = offset
    else:
        mod.constant_offset_displace = offset
    return mod


def solidify(obj, thickness=0.1):
    mod = obj.modifiers.new("Solidify", "SOLIDIFY")
    mod.thickness = thickness
    return mod


def curve_tube(name, points, radius=0.1, resolution=4, coll=None):
    """Bezier-free poly curve with a round bevel, converted to mesh (pipes, rails, cables)."""
    data = bpy.data.curves.new(name, "CURVE")
    data.dimensions = "3D"
    data.bevel_depth = radius
    data.bevel_resolution = resolution
    spline = data.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for p, co in zip(spline.points, points):
        p.co = (*co, 1)
    curve_obj = bpy.data.objects.new(name + "_curve", data)
    (coll or bpy.context.scene.collection).objects.link(curve_obj)
    mesh = bpy.data.meshes.new_from_object(curve_obj.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    obj = _new_object(name, mesh, coll)
    bpy.data.objects.remove(curve_obj)
    return obj


def _evaluated_mesh(obj, all_layers=False):
    """A new mesh from obj with its modifier stack applied. all_layers keeps every data layer
    (vertex groups included); the default keeps what display and export need."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    if all_layers:
        return bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph), preserve_all_data_layers=True, depsgraph=depsgraph)
    return bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))


def _set_mesh(obj, mesh, keep=()):
    """Give obj `mesh` and drop its modifiers except those in `keep`; frees the old mesh."""
    old = obj.data
    for mod in [m for m in obj.modifiers if m not in keep]:
        obj.modifiers.remove(mod)
    obj.data = mesh
    if old.users == 0:
        bpy.data.meshes.remove(old)
    return obj


def apply_modifiers(obj):
    _set_mesh(obj, _evaluated_mesh(obj))
    prune_material_slots(obj)
    return obj


def prune_material_slots(obj):
    """Drop empty material slots no face uses. Blender 5.2's EXACT boolean adds one per
    material-less cutter (5.0 did not), which QA rightly reports as an unassigned material."""
    mats = obj.data.materials
    used = {p.material_index for p in obj.data.polygons}
    for i in reversed(range(len(mats))):
        if mats[i] is None and i not in used:
            mats.pop(index=i)  # shifts higher polygon indices down
    return obj


def apply_transforms(obj):
    """Bake location/rotation/scale into vertices, leaving an identity transform."""
    mat = obj.matrix_basis.copy()
    obj.data.transform(mat)
    obj.matrix_basis = Matrix.Identity(4)
    return obj


def set_origin_base_center(obj):
    """Move the origin to the bottom-centre of the mesh bounds without moving geometry."""
    coords = [v.co for v in obj.data.vertices]
    mn = Vector((min(c.x for c in coords), min(c.y for c in coords), min(c.z for c in coords)))
    mx = Vector((max(c.x for c in coords), max(c.y for c in coords), max(c.z for c in coords)))
    pivot = Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    obj.data.transform(Matrix.Translation(-pivot))
    # matrix_basis is computed from loc/rot/scale now; matrix_world can be stale until a depsgraph update.
    obj.location = obj.matrix_basis @ pivot
    return obj


def join(objects, name):
    base = objects[0]
    for other in objects[1:]:
        apply_modifiers(other)
        other_mesh = other.data.copy()
        other_mesh.transform(base.matrix_world.inverted() @ other.matrix_world)
        # Remap material indices into the base object's slot list.
        remap = {}
        for index, slot in enumerate(other.material_slots):
            mat = slot.material
            if mat is None:
                continue
            if mat.name not in [m.name for m in base.data.materials if m]:
                base.data.materials.append(mat)
            remap[index] = [m.name if m else None for m in base.data.materials].index(mat.name)
        for poly in other_mesh.polygons:
            poly.material_index = remap.get(poly.material_index, 0)
        bm = bmesh.new()
        bm.from_mesh(base.data)
        bm.from_mesh(other_mesh)
        bm.to_mesh(base.data)
        bm.free()
        bpy.data.objects.remove(other)
        bpy.data.meshes.remove(other_mesh)
    base.name = name
    base.data.name = name
    return base


def shade_smooth(obj, angle=35):
    for poly in obj.data.polygons:
        poly.use_smooth = True
    if hasattr(obj.data, "set_sharp_from_angle"):
        obj.data.set_sharp_from_angle(angle=math.radians(angle))
    return obj


# ---------- UV and materials ----------

def box_uv(obj, scale=0.25):
    """Deterministic world-aligned box projection (no operator context needed)."""
    mesh = obj.data
    uv = mesh.uv_layers.get("UVMap") or mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        n = poly.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        for li in poly.loop_indices:
            co = mesh.vertices[mesh.loops[li].vertex_index].co
            u, v = [(co.y, co.z), (co.x, co.z), (co.x, co.y)][axis]
            uv.data[li].uv = (u * scale, v * scale)
    return obj


def node_tree(mat):
    """The material's node tree. Blender 5.x creates one for every new material (and deprecates
    `use_nodes`, to be removed in 6.0), so `use_nodes` is only set when a tree is missing."""
    if mat.node_tree is None:
        mat.use_nodes = True
    return mat.node_tree


def principled(mat, create=True):
    """The material's Principled BSDF, found by node type (node names are localised). With
    create, a missing one is added and wired to the material output (also created if missing)."""
    tree = node_tree(mat)
    bsdf = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None and create:
        bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
        tree.links.new(bsdf.outputs[0], material_output(mat).inputs["Surface"])
    return bsdf


def material_output(mat):
    """The active Material Output node (by type), created when missing."""
    tree = node_tree(mat)
    outputs = [n for n in tree.nodes if n.type == "OUTPUT_MATERIAL"]
    active = next((n for n in outputs if n.is_active_output), outputs[0] if outputs else None)
    return active or tree.nodes.new("ShaderNodeOutputMaterial")


def pbr_material(name, color=(0.8, 0.8, 0.8, 1), roughness=0.6, metallic=0.0, emission=None):
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
    bsdf = principled(mat)
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission:
        bsdf.inputs["Emission Color"].default_value = emission
        bsdf.inputs["Emission Strength"].default_value = 1.0
    mat.diffuse_color = color
    return mat


def assign(obj, mat):
    if mat.name not in obj.data.materials:
        obj.data.materials.append(mat)
    index = list(obj.data.materials).index(mat)
    for poly in obj.data.polygons:
        poly.material_index = index
    return obj


# ---------- retopology and LOD ----------

def triangles(obj):
    """Triangles of obj's evaluated mesh (modifiers applied), counted as QA counts them."""
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    count = sum(len(p.vertices) - 2 for p in mesh.polygons)
    evaluated.to_mesh_clear()
    return count


def _face_lookup(obj):
    """BVH over obj's faces (object space) and each face's material index."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    indices = [f.material_index for f in bm.faces]
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    return tree, indices


def _retopo_finish(obj, lookup, uv_scale):
    """After a remesher: material index of the nearest source face, then box UVs."""
    tree, indices = lookup
    for poly in obj.data.polygons:
        hit = tree.find_nearest(poly.center)
        poly.material_index = indices[hit[2]] if hit[2] is not None else 0
    prune_material_slots(obj)
    if uv_scale:
        box_uv(obj, uv_scale)
    return obj


def voxel_remesh(obj, voxel_size=0.1, uv_scale=0.25):
    """Rebuild obj as one watertight, evenly spaced quad mesh (Remesh modifier, VOXEL mode),
    fusing intersecting blockout parts into a single shell; the modifier stack is baked first.
    Remeshing drops UVs, material indices and vertex groups: material indices are re-projected
    from the nearest source face and box UVs re-applied (uv_scale None: no UVs), so remesh
    before rigging. Raises ValueError when nothing is left (voxel_size too coarse for the shape)."""
    apply_modifiers(obj)
    lookup = _face_lookup(obj)
    mod = obj.modifiers.new("Remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = voxel_size
    _set_mesh(obj, _evaluated_mesh(obj))
    if not obj.data.polygons:
        raise ValueError(f"voxel_remesh: {obj.name}: no faces left at voxel_size {voxel_size}")
    return _retopo_finish(obj, lookup, uv_scale)


def quadriflow(obj, target_faces=1000, seed=0, preserve_sharp=False, uv_scale=0.25):
    """Quad retopology with Blender's QuadriFlow, headless and deterministic per seed (identical
    vertices on bpy 5.0.1, 5.1.2 and 5.2.2); the face count lands near target_faces. Bakes the
    modifier stack first. The input must be manifold with consistent normals and no degenerate
    faces: QuadriFlow cancels otherwise and this raises RuntimeError with the mesh unchanged
    (run `voxel_remesh` first on messy blockouts). Material indices re-projected and box UVs
    re-applied as in voxel_remesh; vertex groups are lost, so retopologise before rigging."""
    apply_modifiers(obj)
    lookup = _face_lookup(obj)
    with bpy.context.temp_override(active_object=obj, object=obj, selected_objects=[obj], selected_editable_objects=[obj]):
        try:
            result = bpy.ops.object.quadriflow_remesh(target_faces=target_faces, seed=seed, use_mesh_symmetry=False, use_preserve_sharp=preserve_sharp)
        except RuntimeError as exc:
            raise RuntimeError(f"quadriflow: {obj.name}: {str(exc).strip()}") from exc
    if result != {"FINISHED"} or not obj.data.polygons:
        raise RuntimeError(f"quadriflow: {obj.name}: QuadriFlow cancelled; it needs a manifold mesh with consistent normals and no degenerate faces")
    return _retopo_finish(obj, lookup, uv_scale)


def lod_chain(obj, ratios=(0.5, 0.25, 0.1), max_influences=4):
    """Level-of-detail copies of obj (LOD0, left as it is): `<name>_LOD1`.. made with the Decimate
    modifier (collapse) at each ratio of LOD0's triangles, at obj's transform and in its
    collections, tagged `rbx_lod`/`rbx_lod_ratio`. Each copy bakes obj's modifiers except Armature,
    which stays live; decimation blends vertex weights, so skinned copies get `limit_weights`
    again. Raises ValueError (removing the copies) unless ratios strictly decrease within (0, 1)
    and every level has strictly fewer triangles than the one before. Returns [obj, lod1, ...]."""
    if not ratios or any(not 0 < r < 1 for r in ratios) or any(b >= a for a, b in zip(ratios, ratios[1:])):
        raise ValueError(f"lod_chain: ratios must strictly decrease within (0, 1), got {list(ratios)}")
    chain, counts = [obj], [triangles(obj)]
    try:
        for level, ratio in enumerate(ratios, start=1):
            lod = obj.copy()
            lod.data = obj.data.copy()
            lod.name = f"{obj.name}_LOD{level}"
            for coll in obj.users_collection:
                coll.objects.link(lod)
            chain.append(lod)
            rigs = [m for m in lod.modifiers if m.type == "ARMATURE"]
            for mod in rigs:
                mod.show_viewport = False  # decimate the rest shape, not the posed one
            decimate = lod.modifiers.new("Decimate", "DECIMATE")
            decimate.ratio = ratio
            _set_mesh(lod, _evaluated_mesh(lod, all_layers=True), keep=rigs)
            lod.data.name = lod.name
            for mod in rigs:
                mod.show_viewport = True
            prune_material_slots(lod)
            if rigs and rigs[0].object is not None:
                limit_weights(lod, rigs[0].object, max_influences)
            env.set_meta(lod, lod=level, lod_ratio=ratio)
            counts.append(triangles(lod))
            if not 0 < counts[-1] < counts[-2]:
                raise ValueError(f"lod_chain: {lod.name} has {counts[-1]} triangles; need 1 to {counts[-2] - 1} (ratio {ratio})")
    except Exception:
        for lod in chain[1:]:
            mesh = lod.data
            bpy.data.objects.remove(lod)
            if mesh.users == 0:
                bpy.data.meshes.remove(mesh)
        raise
    env.set_meta(obj, lod=0)
    return chain


# ---------- rigging and animation ----------

def armature(name, bones, coll=None):
    """bones: list of (name, head, tail, parent_name|None). Built via edit-bones in object mode-free API."""
    data = bpy.data.armatures.new(name)
    obj = bpy.data.objects.new(name, data)
    (coll or bpy.context.scene.collection).objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    created = {}
    for bone_name, head, tail, parent in bones:
        eb = data.edit_bones.new(bone_name)
        eb.head, eb.tail = head, tail
        if parent:
            eb.parent = created[parent]
        created[bone_name] = eb
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def bind_rigid(mesh_obj, arm_obj, assignments):
    """Rigid skinning: assignments maps vertex predicate -> bone. One influence per vertex
    (well under Roblox's 4-influence limit) and fully deterministic."""
    for bone in arm_obj.data.bones:
        if bone.name not in mesh_obj.vertex_groups:
            mesh_obj.vertex_groups.new(name=bone.name)
    for v in mesh_obj.data.vertices:
        world = mesh_obj.matrix_world @ v.co
        for predicate, bone_name in assignments:
            if predicate(world):
                mesh_obj.vertex_groups[bone_name].add([v.index], 1.0, "REPLACE")
                break
    mod = mesh_obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm_obj
    mesh_obj.parent = arm_obj
    return mesh_obj


def limit_weights(mesh_obj, arm_obj, max_influences=4, min_weight=0.01):
    """Keep each vertex's `max_influences` strongest deform-bone weights (Roblox skins with at
    most 4), drop weights under min_weight (the strongest always stays) and normalise the rest
    to sum 1. Dropped memberships are removed, not zeroed. Weights at or below qa.WEIGHT_EPS do
    not count (as in QA); a vertex with none stays unweighted and QA reports it."""
    from . import qa

    deform = {b.name for b in arm_obj.data.bones if b.use_deform}
    groups = {g.index: g for g in mesh_obj.vertex_groups if g.name in deform}
    for v in mesh_obj.data.vertices:
        members = [(g.weight, g.group) for g in v.groups if g.group in groups]
        ranked = sorted((m for m in members if m[0] > qa.WEIGHT_EPS), key=lambda m: (-m[0], m[1]))
        keep = [m for m in ranked[:max_influences] if m[0] >= min_weight] or ranked[:1]
        kept = {index for _, index in keep}
        total = sum(weight for weight, _ in keep)
        for _, index in members:
            if index not in kept:
                groups[index].remove([v.index])
        for weight, index in keep:
            groups[index].add([v.index], weight / total, "REPLACE")
    return mesh_obj


def _bind_nearest(mesh_obj, arm_obj, vertex_indices):
    """Rigidly bind each vertex to the deform bone whose segment is nearest (world space)."""
    bones = [b for b in arm_obj.data.bones if b.use_deform]
    segments = [(b.name, arm_obj.matrix_world @ b.head_local, arm_obj.matrix_world @ b.tail_local) for b in bones]

    def distance(point, head, tail):
        closest, t = geometry.intersect_point_line(point, head, tail)
        return (point - (head if t <= 0 else tail if t >= 1 else closest)).length

    for index in vertex_indices:
        point = mesh_obj.matrix_world @ mesh_obj.data.vertices[index].co
        name = min(segments, key=lambda s: distance(point, s[1], s[2]))[0]
        group = mesh_obj.vertex_groups.get(name) or mesh_obj.vertex_groups.new(name=name)
        group.add([index], 1.0, "REPLACE")


def bind_auto(mesh_obj, arm_obj, max_influences=4, min_weight=0.01, fallback="nearest"):
    """Smooth skinning: Blender's automatic (bone heat) weights, then `limit_weights` (at most
    `max_influences`, normalised). Bone heat can fail without raising (Blender only prints
    "Bone Heat Weighting: failed to find solution") and leave vertices unweighted, typically a
    separate shell no bone runs through. Those are never left silently: fallback="nearest"
    binds each rigidly to its nearest deform bone and reports the count; fallback=None raises
    RuntimeError. Apply transforms and modifiers first. Records `rbx_weighting` on mesh_obj:
    method, raw_max_influences (heat output), max_influences, fallback_vertices, unused_bones."""
    from . import qa

    if not any(b.use_deform for b in arm_obj.data.bones):
        raise ValueError(f"bind_auto: {arm_obj.name} has no deform bones")
    for mod in [m for m in mesh_obj.modifiers if m.type == "ARMATURE"]:
        mesh_obj.modifiers.remove(mod)
    both = [mesh_obj, arm_obj]
    with bpy.context.temp_override(active_object=arm_obj, object=arm_obj, selected_objects=both, selected_editable_objects=both):
        result = bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    if result != {"FINISHED"}:
        raise RuntimeError(f"bind_auto: automatic weights did not run on {mesh_obj.name} ({result})")
    raw = qa.skin_stats(mesh_obj, arm_obj)["max_influences"]
    limit_weights(mesh_obj, arm_obj, max_influences, min_weight)
    missing = [i for i, w in enumerate(qa.skin_weights(mesh_obj, arm_obj)) if not w]
    if missing:
        message = f"bind_auto: bone heat left {len(missing)} of {len(mesh_obj.data.vertices)} vertices of {mesh_obj.name} unweighted"
        if fallback != "nearest":
            raise RuntimeError(message + " (pass fallback='nearest' to bind them to the nearest bone)")
        _bind_nearest(mesh_obj, arm_obj, missing)
        print(message + "; bound them rigidly to the nearest deform bone")
    weights = qa.skin_weights(mesh_obj, arm_obj)
    used = {mesh_obj.vertex_groups[i].name for w in weights for i in w}
    env.set_meta(mesh_obj, weighting={
        "method": "heat",
        "raw_max_influences": raw,
        "max_influences": max((len(w) for w in weights), default=0),
        "fallback_vertices": len(missing),
        "unused_bones": sorted(b.name for b in arm_obj.data.bones if b.use_deform and b.name not in used),
    })
    return mesh_obj


def keyframe_clip(arm_obj, clip_name, keys, fps=30):
    """keys: {bone: [(frame, (rx, ry, rz) degrees)]}. Creates one Action (one Roblox clip)."""
    scene = bpy.context.scene
    scene.render.fps = fps
    arm_obj.animation_data_create()
    action = bpy.data.actions.new(clip_name)
    arm_obj.animation_data.action = action
    last = 0
    for bone_name, frames in keys.items():
        pbone = arm_obj.pose.bones[bone_name]
        pbone.rotation_mode = "XYZ"
        for frame, rot in frames:
            pbone.rotation_euler = [math.radians(a) for a in rot]
            pbone.keyframe_insert("rotation_euler", frame=frame)
            last = max(last, frame)
    scene.frame_start, scene.frame_end = 0, last
    env.set_meta(action, clip=clip_name, frames=last, fps=fps)
    return action


# ---------- export ----------

@contextmanager
def _selection(objects):
    """Select exactly `objects` for a use_selection export (None: no change, whole scene).
    Hidden members cannot be selected and would silently drop out of the file, so they are
    revealed for the export (env.revealed); visibility and selection are restored afterwards.
    Objects outside the view layer (excluded collections) cannot be exported this way;
    env.export_objects() leaves them out."""
    if objects is None:
        yield
        return
    layer = bpy.context.view_layer
    wanted = set(objects)
    with env.revealed(wanted):
        previous = {o: o.select_get() for o in layer.objects}
        for o in layer.objects:
            o.select_set(o in wanted)
        try:
            yield
        finally:
            for o, selected in previous.items():
                o.select_set(selected)


def export_fbx(path, objects=None):
    """Roblox-oriented FBX: studs as units (scale 1, apply FBX_SCALE_UNITS), no leaf bones,
    -Z forward / Y up, textures embedded, colour attributes as sRGB (active one first), animation
    only when actions exist. Animation follows Roblox's Blender recipe: the active action baked
    over the scene frame range with NLA strips, all-actions and forced start/end keys off and
    simplify 0.0 (every frame kept). objects: export exactly these (hidden ones included); None
    exports the whole scene. Per-clip files: `clips.export_clip_fbx`."""
    has_anim = any(o.animation_data and o.animation_data.action for o in (bpy.context.scene.objects if objects is None else objects))
    with _selection(objects):
        bpy.ops.export_scene.fbx(
            filepath=str(path),
            use_selection=objects is not None,
            apply_scale_options="FBX_SCALE_UNITS",
            axis_forward="-Z",
            axis_up="Y",
            add_leaf_bones=False,
            bake_anim=has_anim,
            bake_anim_use_all_actions=False,  # one clip per export (Roblox imports one track)
            bake_anim_use_nla_strips=False,  # bake the active action over the scene range
            bake_anim_force_startend_keying=False,  # Roblox recipe; the clip's own keys bound it
            bake_anim_simplify_factor=0.0,  # keep every baked frame (Roblox recipe)
            colors_type="SRGB",  # vertex colours (palette fallback, vertex_colors route) ship
            prioritize_active_color=True,
            path_mode="COPY",
            embed_textures=True,
            object_types={"MESH", "ARMATURE", "EMPTY"},
            use_custom_props=True,
        )
    return path


def export_glb(path, objects=None, animation_mode="ACTIONS"):
    """GLB, Y up, modifiers applied, custom properties as extras, the active colour attribute as
    COLOR_0 (the glTF default only writes colours a material reads). animation_mode: ACTIONS
    (every action) or NLA_TRACKS (one glTF animation per NLA track, named after the track; what
    `clips.export_clips` uses). objects: as export_fbx."""
    with _selection(objects):
        bpy.ops.export_scene.gltf(
            filepath=str(path),
            export_format="GLB",
            use_selection=objects is not None,
            export_yup=True,
            export_extras=True,
            export_apply=True,
            export_vertex_color="ACTIVE",
            export_animation_mode=animation_mode,
        )
    return path


# ---------- collision ----------

def _kdop_directions():
    """The 26 directions of a 26-DOP: axes, edge diagonals and corner diagonals."""
    dirs = []
    for x in (-1, 0, 1):
        for y in (-1, 0, 1):
            for z in (-1, 0, 1):
                if (x, y, z) != (0, 0, 0):
                    dirs.append(Vector((x, y, z)).normalized())
    return dirs


def _kdop(name, points, coll):
    """Smallest 26-DOP around `points`: a box clipped by the 20 diagonal planes, each pushed out to
    the farthest point. Always contains every point, at most 26 faces."""
    mn = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    mx = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=mx - mn, verts=bm.verts)
    bmesh.ops.translate(bm, vec=(mn + mx) / 2, verts=bm.verts)
    for d in _kdop_directions():
        if sum(1 for c in d if abs(c) > 1e-6) == 1:
            continue  # the box faces already bound the axes
        reach = max(p.dot(d) for p in points)
        geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
        cut = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=d * reach, plane_no=d, clear_outer=True)
        edges = [e for e in cut["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
        if edges:
            bmesh.ops.contextual_create(bm, geom=edges)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.1), verts=bm.verts, edges=bm.edges)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _new_object(name, _mesh_from_bmesh(name, bm), coll)


def collision_proxy(obj, kind="hull", max_tris=256, coll=None):
    """An invisible collision stand-in for `obj` (Roblox imports neither collision meshes nor
    LODs: research blender-animation-pipeline section 6). kind "hull": the convex hull of obj's
    evaluated vertices; when it has more than `max_tris` triangles, a 26-DOP (box clipped by its
    diagonal planes, at most 26 faces) replaces it, which still contains every vertex. kind "box":
    the axis-aligned bounds (12 triangles). The proxy is `<name>_Collision` at obj's transform,
    in obj's collections, tagged `rbx_collision = {role: proxy, fidelity: Hull|Box, method}`; obj
    is tagged `{role: visual, can_collide: false, fidelity: Box}`. Whether FBX custom properties
    become Roblox attributes is UNVERIFIED, so the expectation and kit/1 carry these tags and a
    Studio helper sets CanCollide, Transparency and CollisionFidelity from them."""
    if kind not in ("hull", "box"):
        raise ValueError(f"collision_proxy: kind must be 'hull' or 'box', got {kind!r}")
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    points = [v.co.copy() for v in mesh.vertices]
    evaluated.to_mesh_clear()
    if not points:
        raise ValueError(f"collision_proxy: {obj.name} has no vertices")
    name = obj.name + "_Collision"
    target = coll or (obj.users_collection[0] if obj.users_collection else None)
    method = kind
    if kind == "box":
        mn = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
        mx = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
        proxy = box(name, size=tuple(mx - mn), location=((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z), coll=target)
        apply_transforms(proxy)
    else:
        bm = bmesh.new()
        verts = [bm.verts.new(p) for p in points]
        hull = bmesh.ops.convex_hull(bm, input=verts)
        unused = set(hull["geom_unused"]) | set(hull["geom_interior"])
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v in unused and not v.link_faces], context="VERTS")
        bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(0.1), verts=bm.verts, edges=bm.edges)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        tris = sum(len(f.verts) - 2 for f in bm.faces)
        if tris > max_tris:
            bm.free()
            proxy = _kdop(name, points, target)
            method = "kdop26"
        else:
            proxy = _new_object(name, _mesh_from_bmesh(name, bm), target)
    proxy.matrix_world = obj.matrix_world.copy()
    tris = sum(len(p.vertices) - 2 for p in proxy.data.polygons)
    if tris > max_tris:
        raise ValueError(f"collision_proxy: {name} has {tris} triangles, over max_tris {max_tris}")
    fidelity = "Box" if kind == "box" else "Hull"
    env.set_meta(proxy, collision={"role": "proxy", "fidelity": fidelity, "method": method, "of": obj.name}, qa_role="collision")
    env.set_meta(obj, collision={"role": "visual", "can_collide": False, "fidelity": "Box", "proxy": name})
    return proxy


def proxy_contains(proxy, obj, tol=1e-4):
    """Largest signed distance (studs) of obj's evaluated vertices outside proxy's face planes
    (world space); <= tol means every vertex is inside or on the proxy."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    points = [obj.matrix_world @ v.co for v in mesh.vertices]
    evaluated.to_mesh_clear()
    planes = []
    for poly in proxy.data.polygons:
        normal = (proxy.matrix_world.to_3x3() @ poly.normal).normalized()
        planes.append((normal, normal.dot(proxy.matrix_world @ poly.center)))
    return max(n.dot(p) - d for p in points for n, d in planes)
