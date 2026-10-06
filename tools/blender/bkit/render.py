"""Headless previews: SceneKit manifests and Blender assets rendered with Cycles (CPU),
so an agent can look at what it authored without opening Studio."""
import math
from pathlib import Path

import bpy
from mathutils import Vector

from . import coords, env, ops


def _material_for(color, transparency, cache):
    key = (tuple(color), round(transparency or 0, 2))
    if key not in cache:
        rgba = (color[0] / 255, color[1] / 255, color[2] / 255, 1)
        mat = ops.pbr_material("c_%02x%02x%02x_%d" % (*color, int((transparency or 0) * 100)), rgba, roughness=0.7)
        if transparency:
            bsdf = ops.principled(mat)
            bsdf.inputs["Alpha"].default_value = max(0.05, 1 - transparency)
        cache[key] = mat
    return cache[key]


def build_manifest(manifest):
    """Create Blender objects for every SceneKit part. Returns the parent collection."""
    coll = env.collection(manifest.get("name", "Scene"))
    cache = {}
    for part in manifest["parts"]:
        sx, sy, sz = part["size"]
        shape = part.get("shape", "Block")
        name = part["id"]
        if shape == "Cylinder":
            obj = ops.cylinder(name, radius=min(sy, sz) / 2, depth=sx, segments=16, coll=coll, base_pivot=False, axis="X")
        elif shape == "Ball":
            obj = ops.sphere(name, radius=min(sx, sy, sz) / 2, coll=coll)
        elif shape == "Wedge":
            obj = ops.wedge(name, size=tuple(coords.rbx_size_to_blender(sx, sy, sz)), coll=coll)
        else:
            obj = ops.box(name, size=tuple(coords.rbx_size_to_blender(sx, sy, sz)), coll=coll, base_pivot=False)
        if shape == "Cylinder":
            # Cylinder axis is local X in both conventions; only basis-map the radii.
            pass
        obj.matrix_world = coords.rbx_to_blender_matrix(part["pos"], part.get("rot", (0, 0, 0)))
        ops.assign(obj, _material_for(part.get("color", (200, 200, 200)), part.get("transparency"), cache))
    return coll


def _look_at(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def world_background(world):
    """The world's Background node, found by type (node names are localised); created and wired
    to a World Output when missing. Blender 5.x worlds get a node tree when created."""
    if world.node_tree is None:
        world.use_nodes = True
    tree = world.node_tree
    background = next((n for n in tree.nodes if n.type == "BACKGROUND"), None)
    if background is None:
        background = tree.nodes.new("ShaderNodeBackground")
        output = next((n for n in tree.nodes if n.type == "OUTPUT_WORLD"), None) or tree.nodes.new("ShaderNodeOutputWorld")
        tree.links.new(background.outputs[0], output.inputs["Surface"])
    return background


def setup_stage(ground=True, size=2000, sun_angle=(50, 0, 35), clearance=0.02):
    """Sun, sky and a ground slab. Call after the scene's meshes exist: the ground's top sits
    `clearance` studs below the lowest of them (and below 0), never coplanar with a face. Cycles
    rendered faces coplanar with the old ground top (z = 0) black, e.g. floor slabs whose top is
    at Roblox Y = 0."""
    scene = bpy.context.scene
    if ground:
        bpy.context.view_layer.update()
        corners = [(o.matrix_world @ Vector(c)).z for o in scene.objects if o.type == "MESH" for c in o.bound_box]
        top = min([0.0, *corners]) - clearance
        plane = ops.box("Ground", size=(size, size, 0.1), location=(0, 0, top - 0.1))
        ops.assign(plane, ops.pbr_material("ground", (0.22, 0.3, 0.2, 1), roughness=1))
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 4.0
    sun_obj = bpy.data.objects.new("Sun", sun)
    scene.collection.objects.link(sun_obj)
    sun_obj.rotation_euler = [math.radians(a) for a in sun_angle]
    world = bpy.data.worlds.new("World")
    background = world_background(world)
    background.inputs["Color"].default_value = (0.55, 0.65, 0.8, 1)
    background.inputs["Strength"].default_value = 0.45
    scene.world = world
    return scene


def render_views(views, out_dir, prefix, resolution=(640, 400), samples=12):
    """views: {name: {"eye": Vector(blender), "focus": Vector(blender), "fov": deg}}"""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    scene.render.resolution_x, scene.render.resolution_y = resolution
    scene.render.image_settings.file_format = "PNG"
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.clip_end = 10000
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    out = []
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    for name, view in views.items():
        cam.location = view["eye"]
        _look_at(cam, view["focus"])
        cam_data.angle = math.radians(view.get("fov", 70))
        path = Path(out_dir) / f"{prefix}.{name}.png"
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        out.append(str(path))
    return out


# Port of packages/SceneKit/Camera.luau (ANGLES, frame, captureSet) in Roblox axes; keep in sync.
CAPTURE_ANGLES = {"front": (0, 15), "three-quarter": (35, 30), "side": (90, 15), "top": (0, 89)}  # yaw, pitch


def manifest_bounds(manifest):
    """Rotated-corner world AABB of every manifest part in Roblox axes, as Scene.bounds computes it."""
    mn, mx = [math.inf] * 3, [-math.inf] * 3
    for part in manifest["parts"]:
        half = Vector(part["size"]) / 2
        rot = coords.rbx_rotation_matrix(*part.get("rot", (0, 0, 0)))  # = Vec.rotate (Ry * Rx * Rz)
        pos = Vector(part["pos"])
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    corner = pos + rot @ Vector((sx * half.x, sy * half.y, sz * half.z))
                    mn = [min(a, b) for a, b in zip(mn, corner)]
                    mx = [max(a, b) for a, b in zip(mx, corner)]
    if not manifest["parts"]:
        raise ValueError("manifest has no parts and no cameras: nothing to frame")
    return mn, mx


def capture_set(mn, mx, fov=70, margin=1.1):
    """Camera.captureSet: per angle, an eye/focus (Roblox axes) whose view fits the bounding sphere."""
    focus = [(a + b) / 2 for a, b in zip(mn, mx)]
    radius = math.dist(mn, mx) / 2 * margin
    distance = radius / math.sin(math.radians(fov) / 2)
    cameras = {}
    for name, (yaw_deg, pitch_deg) in CAPTURE_ANGLES.items():
        yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
        # SceneKit fronts face -Z, so the "front" camera (yaw 0) sits on -Z looking toward +Z.
        offset = (math.sin(yaw) * math.cos(pitch) * distance, math.sin(pitch) * distance, -math.cos(yaw) * math.cos(pitch) * distance)
        eye = [f + o for f, o in zip(focus, offset)]
        cameras[name] = {"eye": dict(zip("xyz", eye)), "focus": dict(zip("xyz", focus)), "fov": fov, "distance": distance}
    return cameras


def render_manifest(manifest, out_dir, angles=("three-quarter", "top"), **kwargs):
    # scene:manifest() carries no cameras (build_fixtures adds them); frame the parts the same way.
    cameras = manifest.get("cameras") or {}
    if any(name not in cameras for name in angles):
        cameras = {**capture_set(*manifest_bounds(manifest)), **cameras}
    env.reset()
    build_manifest(manifest)
    setup_stage()
    views = {}
    for name in angles:
        cam = cameras[name]
        views[name] = {
            "eye": coords.rbx_to_blender_vec(cam["eye"]["x"], cam["eye"]["y"], cam["eye"]["z"]),
            "focus": coords.rbx_to_blender_vec(cam["focus"]["x"], cam["focus"]["y"], cam["focus"]["z"]),
            "fov": cam["fov"],
        }
    return render_views(views, out_dir, Path(manifest["name"]).stem, **kwargs)


def render_objects(objects, out_dir, prefix, angles=("front", "three-quarter", "side"), **kwargs):
    """Turntable-style stills of existing objects framed by their world bounds."""
    pts = [o.matrix_world @ Vector(c) for o in objects if o.type == "MESH" for c in o.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    focus = (mn + mx) / 2
    radius = max((mx - mn).length / 2, 0.5) * 1.15
    fov = 40
    dist = radius / math.sin(math.radians(fov) / 2)
    yaw_pitch = {"front": (0, 10), "three-quarter": (35, 25), "side": (90, 10), "top": (0, 85)}
    views = {}
    for name in angles:
        yaw, pitch = (math.radians(a) for a in yaw_pitch[name])
        # Front of assets faces -Y in Blender, so the camera sits on -Y.
        offset = Vector((math.sin(yaw) * math.cos(pitch), -math.cos(yaw) * math.cos(pitch), math.sin(pitch))) * dist
        views[name] = {"eye": focus + offset, "focus": focus, "fov": fov}
    return render_views(views, out_dir, prefix, **kwargs)
