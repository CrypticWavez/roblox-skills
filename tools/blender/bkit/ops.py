"""Reusable, deterministic modelling operations built on bmesh/modifiers (no viewport needed).

Every op returns the object it created or changed so builders can chain them. Destructive
steps (apply_modifiers, apply_transforms) are explicit; nothing is applied implicitly.
"""
import math
from contextlib import contextmanager

import bmesh
import bpy
from mathutils import Matrix, Vector

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


def apply_modifiers(obj):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))
    old = obj.data
    obj.modifiers.clear()
    obj.data = mesh
    if old.users == 0:
        bpy.data.meshes.remove(old)
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


def pbr_material(name, color=(0.8, 0.8, 0.8, 1), roughness=0.6, metallic=0.0, emission=None):
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
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
    -Z forward / Y up, textures embedded, animation only when actions exist. objects: export
    exactly these (hidden ones included); None exports the whole scene."""
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
            path_mode="COPY",
            embed_textures=True,
            object_types={"MESH", "ARMATURE", "EMPTY"},
            use_custom_props=True,
        )
    return path


def export_glb(path, objects=None):
    """GLB, Y up, modifiers applied, custom properties as extras. objects: as export_fbx."""
    with _selection(objects):
        bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=objects is not None, export_yup=True, export_extras=True, export_apply=True)
    return path
