"""Scene reset, collections, metadata and deterministic settings."""
import json
import bpy

ROBLOX_META_PREFIX = "rbx_"


def reset(empty=True):
    bpy.ops.wm.read_factory_settings(use_empty=empty)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    scene["rbx_units"] = "1 BU = 1 stud"
    return scene


def collection(name, parent=None):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
        (parent or bpy.context.scene.collection).children.link(coll)
    return coll


def export_objects(scene=None):
    """The shipped set: objects in every `<Kind>/Export` collection, including its sub-collections,
    minus boolean cutters. Sorted by name so exports are deterministic."""
    scene = scene or bpy.context.scene
    in_scene = set(scene.objects)
    found = set()
    for coll in bpy.data.collections:
        if coll.name.endswith("/Export"):
            found.update(o for o in coll.all_objects if o in in_scene and not o.get("rbx_cutter"))
    return sorted(found, key=lambda o: o.name)


def link(obj, coll):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    coll.objects.link(obj)
    return obj


def set_meta(target, **values):
    """Validation metadata stored as custom properties (survive .blend save, FBX export as user props)."""
    for key, value in values.items():
        target[ROBLOX_META_PREFIX + key] = json.dumps(value) if isinstance(value, (dict, list)) else value


def get_meta(target):
    out = {}
    for key in target.keys():
        if key.startswith(ROBLOX_META_PREFIX):
            value = target[key]
            if isinstance(value, str) and value[:1] in "[{":
                try:
                    value = json.loads(value)
                except ValueError:
                    pass
            out[key[len(ROBLOX_META_PREFIX):]] = value
    return out
