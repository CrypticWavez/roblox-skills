"""R15 rig profiles as data, and the `rig_profile` QA checks built on them.

"R15" names two different trees (research blender-animation-pipeline section 4):
- `r15_pose`: what a Motor6D character's KeyframeSequence drives. The root Pose is
  `HumanoidRootPart`, with `LowerTorso` below it and the other 14 parts below that; each Pose is
  matched to a part by name. Clips exported from a rig with these bone names drive the standard
  character (the factory's humanoid, npc and enemy templates).
- `r15_avatar`: an avatar body (create.roblox.com art/characters/specifications): bones
  `Root > HumanoidRootNode > LowerTorso > ...`, 15 meshes named `<Part>_Geo`, no vertex weighted
  to `Root`, per-part triangle budgets, body-scale ranges and `_Att` attachments.

Factory axes: Z up, front -Y, 1 BU = 1 stud. A character facing -Y has its left side at +X
(left = up x forward = Z x -Y), so every `Left*` bone sits at +X of the root. The same holds in
Roblox after import, because Import 3D turns the asset (front stays front, up stays up; a
mirroring import would also turn faces inside out)."""
SIDES = ("Left", "Right")
LIMBS = {"Arm": ("UpperArm", "LowerArm", "Hand"), "Leg": ("UpperLeg", "LowerLeg", "Foot")}
PARTS = (
    "Head", "UpperTorso", "LowerTorso",
    "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
)


def _part_parents(torso_root):
    parents = {"LowerTorso": torso_root, "UpperTorso": "LowerTorso", "Head": "UpperTorso"}
    for side in SIDES:
        parents[f"{side}UpperArm"] = "UpperTorso"
        parents[f"{side}LowerArm"] = f"{side}UpperArm"
        parents[f"{side}Hand"] = f"{side}LowerArm"
        parents[f"{side}UpperLeg"] = "LowerTorso"
        parents[f"{side}LowerLeg"] = f"{side}UpperLeg"
        parents[f"{side}Foot"] = f"{side}LowerLeg"
    return parents


PROFILES = {
    "r15_pose": {
        "root": "HumanoidRootPart",
        "parents": {"HumanoidRootPart": None, **_part_parents("HumanoidRootPart")},
        "optional": (),
        "no_weights": (),
    },
    "r15_avatar": {
        "root": "Root",
        "parents": {"Root": None, "HumanoidRootNode": "Root", **_part_parents("HumanoidRootNode")},
        # Higher-fidelity optional bones (up to 37 in total); allowed, not required.
        "optional": ("Spine", "Chest", "HeadBase", "LeftClavicle", "RightClavicle", "LeftToeBase", "RightToeBase"),
        "no_weights": ("Root",),
    },
}

# Avatar body specification (create.roblox.com art/characters/specifications, 2026-10-06).
AVATAR_BUDGETS = {"Head": 4000, "torso": 1750, "limb": 1248, "total": 10742}
AVATAR_SCALE = {  # studs: (width, height, depth) ranges per body-scale type
    "Normal": ((1.35, 8.6), (3.6, 9.5), (0.7, 2.25)),
    "Slender": ((1.35, 6.0), (3.6, 9.5), (0.7, 2.0)),
    "Classic": ((1.35, 8.0), (3.6, 9.1), (0.7, 2.0)),
}
AVATAR_ATTACHMENTS = {
    "Head": ("FaceCenter", "FaceFront", "Hat", "Hair"),
    "UpperTorso": ("LeftCollar", "RightCollar", "Neck", "BodyBack", "BodyFront"),
    "LowerTorso": ("Root", "WaistFront", "WaistBack", "WaistCenter"),
    "LeftUpperArm": ("LeftShoulder",), "RightUpperArm": ("RightShoulder",),
    "LeftHand": ("LeftGrip",), "RightHand": ("RightGrip",),
    "LeftFoot": ("LeftFoot",), "RightFoot": ("RightFoot",),
}

# The factory's blocky r15_pose layout (studs; a 5.5-stud character, feet at z = 0, front -Y,
# left at +X): name, head, tail, parent. templates.humanoid builds its rig from this.
POSE_LAYOUT = [
    ("HumanoidRootPart", (0, 0, 2.0), (0, 0, 2.6), None),
    ("LowerTorso", (0, 0, 2.0), (0, 0, 2.7), "HumanoidRootPart"),
    ("UpperTorso", (0, 0, 2.7), (0, 0, 4.0), "LowerTorso"),
    ("Head", (0, 0, 4.0), (0, 0, 5.3), "UpperTorso"),
    ("LeftUpperArm", (1.0, 0, 3.9), (1.0, 0, 3.0), "UpperTorso"),
    ("LeftLowerArm", (1.0, 0, 3.0), (1.0, 0, 2.2), "LeftUpperArm"),
    ("LeftHand", (1.0, 0, 2.2), (1.0, 0, 1.9), "LeftLowerArm"),
    ("RightUpperArm", (-1.0, 0, 3.9), (-1.0, 0, 3.0), "UpperTorso"),
    ("RightLowerArm", (-1.0, 0, 3.0), (-1.0, 0, 2.2), "RightUpperArm"),
    ("RightHand", (-1.0, 0, 2.2), (-1.0, 0, 1.9), "RightLowerArm"),
    ("LeftUpperLeg", (0.5, 0, 2.0), (0.5, 0, 1.1), "LowerTorso"),
    ("LeftLowerLeg", (0.5, 0, 1.1), (0.5, 0, 0.25), "LeftUpperLeg"),
    ("LeftFoot", (0.5, 0, 0.25), (0.5, -0.4, 0.05), "LeftLowerLeg"),
    ("RightUpperLeg", (-0.5, 0, 2.0), (-0.5, 0, 1.1), "LowerTorso"),
    ("RightLowerLeg", (-0.5, 0, 1.1), (-0.5, 0, 0.25), "RightUpperLeg"),
    ("RightFoot", (-0.5, 0, 0.25), (-0.5, -0.4, 0.05), "RightLowerLeg"),
]


def avatar_layout(scale=1.0):
    """POSE_LAYOUT re-rooted as r15_avatar: Root at the origin, HumanoidRootNode at the hips."""
    out = [("Root", (0, 0, 0), (0, 0, 0.5 * scale), None), ("HumanoidRootNode", (0, 0, 2.0 * scale), (0, 0, 2.6 * scale), "Root")]
    for name, head, tail, parent in POSE_LAYOUT[1:]:
        out.append((name, tuple(c * scale for c in head), tuple(c * scale for c in tail), "HumanoidRootNode" if parent == "HumanoidRootPart" else parent))
    return out


def _check(name, ok, value=None, limit=None, level="error", detail=None):
    return {"name": name, "pass": bool(ok), "level": level, "value": value, "limit": limit, "detail": detail}


def rest(rig):
    """{bone: (head, tail)} in world space, rest pose."""
    m = rig.matrix_world
    return {b.name: (m @ b.head_local, m @ b.tail_local) for b in rig.data.bones}


def check(rig, profile_name, tol=None):
    """`rig_profile` checks of armature `rig` against a profile: names, hierarchy, sides (Left at
    +X when facing -Y), symmetry, limb order (head above torso, legs going down, each arm chain
    extending away from its shoulder: I-, A- and T-poses all pass), feet pointing front and
    resting on the ground. tol: studs (default 2% of the rig's height, at least 0.05)."""
    profile = PROFILES.get(profile_name)
    if profile is None:
        return [_check("rig_profile", False, profile_name, sorted(PROFILES), detail="unknown rig profile")]
    bones = {b.name: b for b in rig.data.bones}
    pose = rest(rig)
    zs = [p.z for h, t in pose.values() for p in (h, t)] or [0]
    height = max(zs) - min(zs)
    tol = tol if tol is not None else max(0.05, 0.02 * height)
    checks = []
    missing = [n for n in profile["parents"] if n not in bones]
    checks.append(_check("rig_profile", not missing, len(missing), 0, detail=f"{profile_name}: missing " + ", ".join(missing[:8]) if missing else profile_name))
    extra = [n for n, b in bones.items() if n not in profile["parents"] and n not in profile["optional"] and b.use_deform]
    checks.append(_check("rig_profile_extra_bones", not extra, len(extra), 0, level="warning", detail=", ".join(extra[:8]) or None))
    wrong = []
    for name, parent in profile["parents"].items():
        if name in bones:
            actual = bones[name].parent.name if bones[name].parent else None
            if actual != parent:
                wrong.append(f"{name}<-{actual} (want {parent})")
    checks.append(_check("rig_profile_hierarchy", not wrong, len(wrong), 0, detail="; ".join(wrong[:6]) or None))
    if missing:
        return checks
    root = pose[profile["root"]][0]
    mirrored, asym = [], []
    for part in ("UpperArm", "LowerArm", "Hand", "UpperLeg", "LowerLeg", "Foot"):
        left, right = pose[f"Left{part}"][0], pose[f"Right{part}"][0]
        if not (left.x - root.x > tol and right.x - root.x < -tol):
            mirrored.append(part)
        if abs((left.x - root.x) + (right.x - root.x)) > tol or abs(left.y - right.y) > tol or abs(left.z - right.z) > tol:
            asym.append(part)
    checks.append(_check("rig_profile_sides", not mirrored, mirrored or None, "Left* at +X of the root (character faces -Y)",
                         detail="Left/Right bones on the wrong side: the rig is mirrored and R15 clips will move the opposite limbs" if mirrored else None))
    checks.append(_check("rig_profile_symmetry", not asym, asym or None, f"pairs mirror within {round(tol, 3)} studs", level="warning"))
    order = []
    z = {n: pose[n][0].z for n in PARTS}
    if not z["Head"] > z["UpperTorso"] > z["LowerTorso"] - tol:
        order.append("Head > UpperTorso > LowerTorso")
    for side in SIDES:
        upper, lower, foot = (z[f"{side}{p}"] for p in LIMBS["Leg"])
        if not upper > lower > foot:
            order.append(f"{side} leg not going down")
        shoulder = pose[f"{side}UpperArm"][0]
        elbow = (pose[f"{side}LowerArm"][0] - shoulder).length
        hand = (pose[f"{side}Hand"][0] - shoulder).length
        if not (elbow > tol and hand >= elbow - tol):  # I-, A- and T-poses all extend the chain
            order.append(f"{side} arm chain not extending away from the shoulder")
    checks.append(_check("rig_profile_rest_pose", not order, order or None, "I/A/T rest pose", detail="; ".join(order) or None))
    facing = [s for s in SIDES if (pose[f"{s}Foot"][1] - pose[f"{s}Foot"][0]).y > tol]
    checks.append(_check("rig_profile_facing", not facing, facing or None, "feet point -Y (front)", level="warning",
                         detail="feet point +Y: the rig faces backwards" if facing else None))
    ground = min(p.z for n in ("LeftFoot", "RightFoot") for p in pose[n])
    checks.append(_check("rig_profile_grounded", abs(ground) <= max(tol, 0.1 * height), round(ground, 3), 0, level="warning", detail="lowest foot point (studs) vs the ground plane z = 0"))
    return checks


def root_weighted(mesh_obj, rig, profile_name):
    """Vertices weighted to a bone the profile forbids weights on (r15_avatar: Root)."""
    forbidden = set(PROFILES.get(profile_name, {}).get("no_weights", ()))
    groups = {g.index for g in mesh_obj.vertex_groups if g.name in forbidden}
    return sum(1 for v in mesh_obj.data.vertices if any(g.group in groups and g.weight > 1e-4 for g in v.groups))

