"""Animation clips: several named clips per rig, exported as one multi-clip GLB (one glTF
animation per clip, through temporary NLA tracks), one FBX per clip (Roblox's Blender recipe:
the clip as the active action, baked over its own frame range, every frame kept) and a clips/1
sidecar `<asset>_clips.json` (docs/runtime-kits.md section 9.4).

Clips are Blender actions tagged `rbx_clip = {name, slot, start, end, loop, root_motion,
priority, weight, markers: [[name, frame, param]]}`, listed in order on the rig's `rbx_clips`
and kept with a fake user (an unassigned action is otherwise dropped on save). Markers are also
action pose markers for the Blender UI; Blender's exporters do not carry them (UNVERIFIED for
FBX), so the sidecar is their source of truth in Studio (`GetMarkerReachedSignal` names).
F-curves are read through the 5.x layered-action API (channelbags); `Action.fcurves` is gone."""
import json
import math
import struct
from pathlib import Path

import bpy

from . import env, formats, ops

SCHEMA = "clips/1"


def fcurves(action):
    """Every F-curve of an action (5.x layered actions: layers > strips > channelbags)."""
    for layer in action.layers:
        for strip in layer.strips:
            for bag in getattr(strip, "channelbags", ()):
                yield from bag.fcurves


def bone_of(data_path):
    if data_path.startswith('pose.bones["'):
        return data_path.split('"')[1]
    return None


def add_clip(rig, name, keys, fps=30, start=0, end=None, loop=True, slot=None, root_motion=False, priority=None, weight=None, markers=()):
    """Key a clip on armature `rig`. keys: {bone: [(frame, (rx, ry, rz) degrees[, (x, y, z) studs])]}
    (Euler XYZ rotation, optional location). end defaults to the last key. markers: [(name,
    frame[, param])]. Returns the action (named after the clip, with a fake user), appended to
    the rig's `rbx_clips`; the first clip stays the rig's active action (what the template's
    main FBX bakes)."""
    scene = bpy.context.scene
    scene.render.fps = fps
    rig.animation_data_create()
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    last = start
    for bone_name, frames in keys.items():
        pbone = rig.pose.bones[bone_name]
        pbone.rotation_mode = "XYZ"
        for key in frames:
            frame, rot = key[0], key[1]
            pbone.rotation_euler = [math.radians(a) for a in rot]
            pbone.keyframe_insert("rotation_euler", frame=frame)
            if len(key) > 2:
                pbone.location = key[2]
                pbone.keyframe_insert("location", frame=frame)
            last = max(last, frame)
        pbone.rotation_euler = (0, 0, 0)
        pbone.location = (0, 0, 0)
    end = last if end is None else end
    for marker in markers:
        pm = action.pose_markers.new(marker[0])
        pm.frame = marker[1]
    env.set_meta(action, clip={
        "name": name, "slot": slot, "start": start, "end": end, "loop": loop, "root_motion": root_motion,
        "priority": priority, "weight": weight, "markers": [[m[0], m[1], m[2] if len(m) > 2 else None] for m in markers],
    }, fps=fps)
    names = list(env.get_meta(rig).get("clips") or [])
    names.append(action.name)
    env.set_meta(rig, clips=names, animated=True)
    first = bpy.data.actions.get(names[0])
    rig.animation_data.action = first
    scene.frame_start, scene.frame_end = clip_range(first)
    return action


def clip_meta(action):
    return env.get_meta(action).get("clip")


def clip_range(action):
    meta = clip_meta(action)
    if meta:
        return int(meta["start"]), int(meta["end"])
    return int(action.frame_range[0]), int(action.frame_range[1])


def clips_of(rig):
    """The rig's clip actions in order (rbx_clips), skipping names that no longer exist and
    actions without `rbx_clip`. A re-imported GLB or FBX keeps the rig's `rbx_clips` list (object
    extras) but its actions come back without their custom properties: the sidecar is the record
    there."""
    actions = (bpy.data.actions.get(n) for n in env.get_meta(rig).get("clips") or [])
    return [a for a in actions if a is not None and clip_meta(a)]


def entry(action):
    """The clips/1 entry of one clip action."""
    meta = clip_meta(action)
    out = {
        "name": meta["name"],
        "start": int(meta["start"]),
        "end": int(meta["end"]),
        "loop": bool(meta["loop"]),
        "root_motion": bool(meta["root_motion"]),
        "markers": [{k: v for k, v in (("name", m[0]), ("frame", int(m[1])), ("param", m[2])) if v is not None} for m in meta.get("markers") or []],
    }
    for key in ("slot", "priority", "weight"):
        if meta.get(key) is not None:
            out[key] = meta[key]
    return out


def sidecar(rig, asset, rig_kind="custom", fps=None, files=None):
    actions = clips_of(rig)
    fps = fps or int(bpy.context.scene.render.fps)
    names = [clip_meta(a)["name"] for a in actions]
    files = files or {"glb": f"{asset}_clips.glb", "fbx": {n: f"{asset}_{n}.fbx" for n in names}}
    return {"schema": SCHEMA, "asset": asset, "rig": rig_kind, "fps": fps, "files": files, "clips": [entry(a) for a in actions]}


def _evaluate(action, data_path, index, frame):
    for fc in fcurves(action):
        if fc.data_path == data_path and fc.array_index == index:
            return fc.evaluate(frame)
    return None


def clip_checks(rig):
    """QA checks over the rig's clips: clip_names_unique, clip_range (frames, keys inside the
    range), marker_in_range, clip_slot, clip_bones_known (keyed bones are deform bones of this
    rig), clip_loop_closed (a loop's last pose repeats its first), clip_scale_keys (a Roblox
    Pose holds only a CFrame: UNVERIFIED inference) and clip_in_place (root_motion = false keeps
    the root within 0.1 studs, a convention)."""
    from .qa import _check

    actions = clips_of(rig)
    if not actions:
        listed = env.get_meta(rig).get("clips") or []
        if not listed:
            return []
        # Imported file: the clip metadata did not travel; the sidecar and glb/fbx_problems check it.
        return [_check("clip_meta", True, 0, len(listed), level="warning",
                       detail="clip metadata is not in this file (imported): the clips/1 sidecar carries it")]
    checks = []
    names = [clip_meta(a)["name"] for a in actions]
    dupes = sorted({n for n in names if names.count(n) > 1})
    checks.append(_check("clip_names_unique", not dupes and all(formats.CLIP_NAME.match(n) for n in names), names, "unique ^[a-z][a-z0-9_]{0,47}$", detail=", ".join(dupes) or None))
    deform = {b.name for b in rig.data.bones if b.use_deform}
    roots = [b.name for b in rig.data.bones if b.parent is None]
    for action in actions:
        meta = clip_meta(action)
        name = meta["name"]
        start, end = int(meta["start"]), int(meta["end"])
        keyed = [kp.co.x for fc in fcurves(action) for kp in fc.keyframe_points]
        inside = all(start - 1e-3 <= f <= end + 1e-3 for f in keyed)
        checks.append(_check("clip_range", end > start and keyed and inside, [start, end], "end > start, keys inside",
                             detail=f"{name}: keys at {min(keyed, default=None)}..{max(keyed, default=None)}"))
        markers = meta.get("markers") or []
        bad = [m for m in markers if not (start <= m[1] <= end and formats.LABEL.match(str(m[0])))]
        checks.append(_check("marker_in_range", not bad, len(bad), 0, detail=f"{name}: " + ", ".join(f"{m[0]}@{m[1]}" for m in bad) if bad else name))
        slot = meta.get("slot")
        checks.append(_check("clip_slot", slot is None or slot in formats.SLOTS, slot, "standard slot or none", detail=name))
        bones = {bone_of(fc.data_path) for fc in fcurves(action)} - {None}
        unknown = sorted(bones - deform)
        checks.append(_check("clip_bones_known", not unknown, unknown or None, "deform bones of the rig", detail=name))
        scale_keys = [fc for fc in fcurves(action) if fc.data_path.endswith(".scale") and any(abs(kp.co.y - 1) > 1e-4 for kp in fc.keyframe_points)]
        checks.append(_check("clip_scale_keys", not scale_keys, len(scale_keys), 0, level="warning", detail=f"{name}: Roblox Poses hold a CFrame only (UNVERIFIED that scale is dropped)"))
        if meta.get("loop"):
            worst = 0.0
            for fc in fcurves(action):
                worst = max(worst, abs(fc.evaluate(start) - fc.evaluate(end)))
            checks.append(_check("clip_loop_closed", worst <= 1e-3, round(worst, 5), 1e-3, level="warning", detail=f"{name}: a loop's last frame repeats its first pose"))
        if not meta.get("root_motion"):
            drift = 0.0
            for root in roots:
                path = f'pose.bones["{root}"].location'
                for i in range(3):
                    values = [_evaluate(action, path, i, f) for f in range(start, end + 1)]
                    values = [v for v in values if v is not None]
                    if values:
                        drift = max(drift, max(values) - min(values))
            checks.append(_check("clip_in_place", drift <= 0.1, round(drift, 4), 0.1, level="warning", detail=f"{name}: root_motion = false (convention: 0.1 studs)"))
    return checks


def export_clip_fbx(rig, meshes, action, path):
    """One clip as its own FBX: the clip as the active action, NLA muted, the scene range set to
    the clip's frames and the scene named after the clip (the FBX take name), then
    `ops.export_fbx` (Roblox recipe). Restores the scene afterwards."""
    scene = bpy.context.scene
    saved = (rig.animation_data.action, scene.frame_start, scene.frame_end, scene.name)
    tracks = [(t, t.mute) for t in rig.animation_data.nla_tracks]
    try:
        for t, _ in tracks:
            t.mute = True
        rig.animation_data.action = action
        scene.frame_start, scene.frame_end = clip_range(action)
        scene.name = clip_meta(action)["name"]
        ops.export_fbx(path, [rig, *meshes])
    finally:
        rig.animation_data.action, scene.frame_start, scene.frame_end, scene.name = saved
        for t, mute in tracks:
            t.mute = mute
    return path


def export_clips_glb(rig, meshes, path):
    """Every clip in one GLB: a temporary NLA track per clip (named after it, strip at the clip's
    start), the active action cleared, glTF NLA_TRACKS mode; tracks removed afterwards."""
    data = rig.animation_data
    saved = data.action
    made = []
    try:
        data.action = None
        for action in clips_of(rig):
            track = data.nla_tracks.new()
            track.name = clip_meta(action)["name"]
            start, _ = clip_range(action)
            track.strips.new(track.name, start, action)
            made.append(track)
        ops.export_glb(path, [rig, *meshes], animation_mode="NLA_TRACKS")
    finally:
        for track in made:
            data.nla_tracks.remove(track)
        data.action = saved
    return path


def export_clips(rig, meshes, out_dir, asset, rig_kind="custom"):
    """Write `<asset>_clips.glb`, `<asset>_<clip>.fbx` per clip and `<asset>_clips.json` (clips/1)
    into out_dir. Raises ValueError when the sidecar would not validate. Returns the sidecar."""
    out = Path(out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)
    data = sidecar(rig, asset, rig_kind)
    problems = formats.validate_clips(data)
    if problems:
        raise ValueError("clips/1: " + "; ".join(problems))
    export_clips_glb(rig, meshes, out / data["files"]["glb"])
    for action in clips_of(rig):
        export_clip_fbx(rig, meshes, action, out / data["files"]["fbx"][clip_meta(action)["name"]])
    (out / f"{asset}_clips.json").write_text(formats.dumps(data))
    return data


def glb_animations(path):
    """[(name, duration seconds, channels)] read straight from a GLB's JSON and accessors."""
    raw = Path(path).read_bytes()
    length = struct.unpack_from("<I", raw, 12)[0]
    doc = json.loads(raw[20:20 + length])
    out = []
    for anim in doc.get("animations", []):
        times = [doc["accessors"][s["input"]].get("max", [0])[0] for s in anim.get("samplers", [])]
        out.append((anim.get("name"), max(times, default=0.0), len(anim.get("channels", []))))
    return out


def glb_problems(path, data):
    """The multi-clip GLB against its sidecar: one animation per clip, same names, each lasting
    (end - start) / fps seconds within half a frame."""
    found = {name: (duration, channels) for name, duration, channels in glb_animations(path)}
    problems = []
    names = [c["name"] for c in data["clips"]]
    if sorted(found) != sorted(names):
        problems.append(f"GLB animations {sorted(found)} != clips {sorted(names)}")
    for clip in data["clips"]:
        if clip["name"] in found:
            want = formats.clip_duration(clip, data["fps"])
            got, channels = found[clip["name"]]
            if abs(got - want) > 0.5 / data["fps"]:
                problems.append(f"{clip['name']}: GLB lasts {got:.4f} s, sidecar {want:.4f} s")
            if channels == 0:
                problems.append(f"{clip['name']}: no channels")
    return problems


def fbx_problems(path, clip, fps):
    """Re-import one clip FBX (into the current, reset scene; anim_offset 0) and check that it has
    one action spanning exactly the clip's frames with a key on every frame (simplify 0.0)."""
    env.reset()
    bpy.context.scene.render.fps = fps
    bpy.ops.import_scene.fbx(filepath=str(path), anim_offset=0.0)
    actions = list(bpy.data.actions)
    if len(actions) != 1:
        return [f"{Path(path).name}: {len(actions)} actions, expected 1"]
    action = actions[0]
    lo, hi = action.frame_range
    problems = []
    if (round(lo), round(hi)) != (clip["start"], clip["end"]):
        problems.append(f"{Path(path).name}: frame range {lo:g}..{hi:g}, clip {clip['start']}..{clip['end']}")
    keys = max((len(fc.keyframe_points) for fc in fcurves(action)), default=0)
    if keys != clip["end"] - clip["start"] + 1:
        problems.append(f"{Path(path).name}: {keys} keys per curve, expected {clip['end'] - clip['start'] + 1}")
    if not action.name.endswith("|" + clip["name"]) and action.name != clip["name"]:
        problems.append(f"{Path(path).name}: take {action.name!r} is not named after the clip")
    return problems
