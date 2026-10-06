"""Deterministic icon renders for UI thumbnails: a square, transparent-background still of an
object set from a fixed three-quarter camera fitted to its bounding sphere, under a fixed
two-sun rig. Cycles on the CPU with fixed samples and seed and no denoiser, so the same scene on
the same bpy version gives the same pixels (`pixel_hash` proves it). The icon is a production
input for UI (G4's ShopCard/InventoryGrid take icon keys), not an upload."""
import hashlib
import math
from pathlib import Path

import bpy
from mathutils import Vector

from . import env, png, render


def _rig(scene, yaw, pitch):
    for name, energy, angles in (("IconKey", 3.5, (45, 0, 35 + yaw)), ("IconFill", 1.2, (60, 0, 200 + yaw))):
        light = bpy.data.lights.new(name, "SUN")
        light.energy = energy
        obj = bpy.data.objects.new(name, light)
        obj.rotation_euler = [math.radians(a) for a in angles]
        scene.collection.objects.link(obj)
    world = scene.world or bpy.data.worlds.new("IconWorld")
    scene.world = world
    background = render.world_background(world)
    background.inputs["Color"].default_value = (0.8, 0.82, 0.86, 1)
    background.inputs["Strength"].default_value = 0.6


def render_icon(objects, path, size=512, samples=32, seed=0, yaw=35, pitch=22, fov=30, margin=1.08):
    """Render `objects` (meshes) to `path` (RGBA PNG). Returns {file, size, samples, seed,
    pixel_hash}; the hash is over the decoded pixels, so PNG encoder differences do not count."""
    scene = bpy.context.scene
    meshes = [o for o in objects if o.type == "MESH"]
    if not meshes:
        raise ValueError("render_icon: no meshes")
    bpy.context.view_layer.update()
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    focus = (mn + mx) / 2
    radius = max((mx - mn).length / 2, 0.25) * margin
    dist = radius / math.sin(math.radians(fov) / 2)
    y, p = math.radians(yaw), math.radians(pitch)
    eye = focus + Vector((math.sin(y) * math.cos(p), -math.cos(y) * math.cos(p), math.sin(p))) * dist
    _rig(scene, yaw, pitch)
    try:
        scene.render.engine = "CYCLES"
    except TypeError as exc:
        raise RuntimeError(f"render_icon needs Cycles: {exc}") from exc
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.seed = seed
    scene.cycles.use_denoising = False
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    settings = scene.render.image_settings
    if hasattr(settings, "media_type"):
        settings.media_type = "IMAGE"  # 5.x: set before file_format
    settings.file_format = "PNG"
    settings.color_mode = "RGBA"
    settings.color_depth = "8"
    cam_data = bpy.data.cameras.new("IconCam")
    cam_data.sensor_fit = "VERTICAL"
    cam_data.angle = math.radians(fov)
    cam = bpy.data.objects.new("IconCam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = eye
    cam.rotation_euler = (focus - eye).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    for obj in scene.objects:  # only the icon's subject renders (no ground or helpers)
        if obj.type == "MESH":
            obj.hide_render = obj not in meshes
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    image = png.read(path)
    digest = hashlib.sha1(bytes(v for row in image["rows"] for v in row)).hexdigest()[:16]
    return {"file": str(path), "size": size, "samples": samples, "seed": seed, "pixel_hash": digest}


def icon_for(source, out, size=512):
    """Icon of a template kind (built in memory) or of a .blend's export set."""
    from . import templates

    if source in templates.TEMPLATES:
        templates.build(source)
    else:
        bpy.ops.wm.open_mainfile(filepath=str(source))
    objects = env.export_objects() or list(bpy.context.scene.objects)
    return render_icon(objects, out, size=size)
