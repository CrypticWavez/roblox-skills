"""Pure-Python validators for the formats the Blender factory writes (docs/runtime-kits.md
section 9): clips/1 (9.4) and kit/1 (9.5). material-library/1 (9.6) lives in textures.py. No bpy
import, so tests and other tools can use them. Validators return a list of problem strings."""
import json
import math
import re

LABEL = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
CLIP_NAME = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
SLOTS = ("idle", "walk", "run", "jump", "fall", "climb", "swim", "sit", "land") + tuple(f"action_{i}" for i in range(1, 9))
PRIORITIES = ("Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4")
RIGS = ("r15_pose", "r15_avatar", "custom")
PIVOTS = ("base_center", "center", "origin")
COLLISIONS = ("box", "hull", "default", "none")
SOURCE = re.compile(r"^(procedural|blender_template:[a-z][a-z0-9_]{0,63}|cc0:[A-Za-z0-9_.\-/]+:[A-Za-z0-9_.\-]+)$")
MATERIAL = re.compile(r"^(library:[a-z][a-z0-9_]{0,63}|builtin:[A-Z][A-Za-z]+|atlas:[^\s:]+|vertex_color)$")


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _vec3(v):
    return isinstance(v, list) and len(v) == 3 and all(_num(c) for c in v)


def validate_clips(data):
    """clips/1 sidecar: schema, asset label, rig, fps, files, clips (unique names, standard
    slots, inclusive integer frame ranges, booleans, priority names, weights, markers inside the
    clip's range)."""
    problems = []
    if not isinstance(data, dict) or data.get("schema") != "clips/1":
        return ["schema must be 'clips/1'"]
    if not isinstance(data.get("asset"), str) or not LABEL.match(data["asset"]):
        problems.append("asset must be a label")
    if data.get("rig") not in RIGS:
        problems.append(f"rig must be one of {', '.join(RIGS)}")
    fps = data.get("fps")
    if not _int(fps) or fps <= 0:
        problems.append("fps must be an integer > 0")
    clips = data.get("clips")
    if not isinstance(clips, list) or not clips:
        return problems + ["clips must be a non-empty list"]
    names = [c.get("name") for c in clips if isinstance(c, dict)]
    files = data.get("files")
    if not isinstance(files, dict) or not isinstance(files.get("glb"), str) or not isinstance(files.get("fbx"), dict):
        problems.append("files must be {glb = <file>, fbx = {clip = <file>}}")
    else:
        unknown = sorted(set(files["fbx"]) - set(names))
        if unknown:
            problems.append(f"files.fbx names clips that do not exist: {', '.join(map(str, unknown))}")
        for clip, file in files["fbx"].items():
            if not isinstance(file, str) or "/" in file or "\\" in file:
                problems.append(f"files.fbx.{clip} must be a file name next to the sidecar")
    seen = set()
    for index, clip in enumerate(clips):
        where = f"clips[{index}]"
        if not isinstance(clip, dict):
            problems.append(f"{where}: not an object")
            continue
        name = clip.get("name")
        if not isinstance(name, str) or not CLIP_NAME.match(name):
            problems.append(f"{where}: name must match ^[a-z][a-z0-9_]{{0,47}}$")
        elif name in seen:
            problems.append(f"{where}: duplicate clip name {name}")
        else:
            seen.add(name)
            where = name
        slot = clip.get("slot")
        if slot is not None and slot not in SLOTS:
            problems.append(f"{where}: slot {slot!r} is not a standard slot ({', '.join(SLOTS)})")
        start, end = clip.get("start"), clip.get("end")
        if not _int(start) or not _int(end) or start < 0:
            problems.append(f"{where}: start and end must be integer frames >= 0")
        elif end < start:
            problems.append(f"{where}: end {end} before start {start}")
        for key in ("loop", "root_motion"):
            if not isinstance(clip.get(key), bool):
                problems.append(f"{where}: {key} must be a boolean")
        if clip.get("priority") is not None and clip["priority"] not in PRIORITIES:
            problems.append(f"{where}: priority must be an Enum.AnimationPriority name ({', '.join(PRIORITIES)})")
        weight = clip.get("weight")
        if weight is not None and (not _num(weight) or weight <= 0):
            problems.append(f"{where}: weight must be > 0")
        markers = clip.get("markers")
        if not isinstance(markers, list):
            problems.append(f"{where}: markers must be a list (empty when none)")
            continue
        for m_index, marker in enumerate(markers):
            if not isinstance(marker, dict) or not isinstance(marker.get("name"), str) or not LABEL.match(marker["name"]):
                problems.append(f"{where}: markers[{m_index}] needs a label name")
                continue
            frame = marker.get("frame")
            if not _int(frame) or (_int(start) and _int(end) and not start <= frame <= end):
                problems.append(f"{where}: marker {marker['name']} frame {frame} outside {start}..{end}")
            if marker.get("param") is not None and not isinstance(marker["param"], str):
                problems.append(f"{where}: marker {marker['name']} param must be a string")
    shared = {}
    for clip in clips:
        if isinstance(clip, dict) and clip.get("slot"):
            shared.setdefault(clip["slot"], []).append(clip)
    for slot, group in shared.items():
        if len(group) > 1 and not all(_num(c.get("weight")) and c["weight"] > 0 for c in group):
            problems.append(f"slot {slot}: clips sharing a slot need weight > 0 (idle variants)")
    return problems


def clip_duration(clip, fps):
    return (clip["end"] - clip["start"]) / fps


def validate_kit(data, base_tolerance=0.01):
    """kit/1: schema, id, pieces (unique keys, sources, files, bounds around the pivot,
    materials, provenance, sockets, collision, triangles). A base_center pivot must sit at the
    bottom centre of the bounds (the B05 world-origin export rule)."""
    problems = []
    if not isinstance(data, dict) or data.get("schema") != "kit/1":
        return ["schema must be 'kit/1'"]
    if not isinstance(data.get("id"), str) or not LABEL.match(data["id"]):
        problems.append("id must be a label")
    pieces = data.get("pieces")
    if not isinstance(pieces, list) or not pieces:
        return problems + ["pieces must be a non-empty list"]
    seen = set()
    for index, piece in enumerate(pieces):
        where = f"pieces[{index}]"
        if not isinstance(piece, dict):
            problems.append(f"{where}: not an object")
            continue
        key = piece.get("key")
        if not isinstance(key, str) or not LABEL.match(key):
            problems.append(f"{where}: key must be a label")
        elif key in seen:
            problems.append(f"{where}: duplicate key {key}")
        else:
            seen.add(key)
            where = key
        source = piece.get("source")
        if not isinstance(source, str) or not SOURCE.match(source):
            problems.append(f"{where}: source must be procedural, blender_template:<kind> or cc0:<source>:<id>")
        file = piece.get("file")
        if source == "procedural":
            if file is not None:
                problems.append(f"{where}: procedural pieces have file = null")
        elif not isinstance(file, str) or not file or file.startswith("/") or ".." in file.split("/") or "\\" in file:
            problems.append(f"{where}: file must be a path relative to the kit file")
        bounds = piece.get("bounds")
        if not isinstance(bounds, dict) or not _vec3(bounds.get("min")) or not _vec3(bounds.get("max")):
            problems.append(f"{where}: bounds must be {{min = [x, y, z], max = [x, y, z]}}")
        elif any(a > b for a, b in zip(bounds["min"], bounds["max"])):
            problems.append(f"{where}: bounds.min exceeds bounds.max")
        pivot = piece.get("pivot", "base_center")
        if pivot not in PIVOTS:
            problems.append(f"{where}: pivot must be one of {', '.join(PIVOTS)}")
        elif pivot == "base_center" and isinstance(bounds, dict) and _vec3(bounds.get("min")) and _vec3(bounds.get("max")):
            mn, mx = bounds["min"], bounds["max"]
            if abs(mn[1]) > base_tolerance or abs(mn[0] + mx[0]) > 2 * base_tolerance or abs(mn[2] + mx[2]) > 2 * base_tolerance:
                problems.append(f"{where}: pivot base_center but the bounds are not centred on it with min y = 0 ({mn}, {mx})")
        materials = piece.get("materials")
        if not isinstance(materials, list) or not materials or not all(isinstance(m, str) and MATERIAL.match(m) for m in materials):
            problems.append(f"{where}: materials must list library:<name>, builtin:<Enum.Material>, atlas:<file> or vertex_color")
        if not isinstance(piece.get("provenance"), str) or not piece["provenance"]:
            problems.append(f"{where}: provenance is required (local-template or an asset-sources/1 key)")
        sockets = piece.get("sockets")
        if sockets is not None:
            names = set()
            if not isinstance(sockets, list):
                problems.append(f"{where}: sockets must be a list")
                sockets = []
            for socket in sockets:
                if not isinstance(socket, dict) or not isinstance(socket.get("name"), str) or not LABEL.match(socket["name"]):
                    problems.append(f"{where}: socket needs a label name")
                    continue
                if socket["name"] in names:
                    problems.append(f"{where}: duplicate socket {socket['name']}")
                names.add(socket["name"])
                if not _vec3(socket.get("position")) or not _num(socket.get("yaw")):
                    problems.append(f"{where}: socket {socket['name']} needs position [x, y, z] and yaw (degrees)")
        if piece.get("collision") is not None and piece["collision"] not in COLLISIONS:
            problems.append(f"{where}: collision must be one of {', '.join(COLLISIONS)}")
        tris = piece.get("triangles")
        if tris is not None and (not _int(tris) or tris < 0):
            problems.append(f"{where}: triangles must be an integer >= 0")
    return problems


def dumps(data):
    """Canonical JSON (sorted keys, two-space indent, trailing LF)."""
    return json.dumps(data, indent=2, sort_keys=True) + "\n"


def snake(name):
    """CamelCase or mixed names to a lower_snake label: `SM_PlatformSquare` -> `platform_square`."""
    for prefix in ("SM_", "SK_", "RIG_"):
        if name.startswith(prefix):
            name = name[len(prefix):]
    name = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name)
    name = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").lower()
    return name if LABEL.match(name or "") else "piece_" + name
