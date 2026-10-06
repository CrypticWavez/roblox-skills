"""Neutral starting templates. Each builds a fully-conventioned blockout: collections
(<Kind>/Source, <Kind>/Export), prefixes (SM_ static, SK_ skinned, RIG_ armature, MAT_),
1 BU = 1 stud, front faces -Y, pivot at base-centre (weapons pivot at the grip), and
`rbx_*` validation metadata read by qa.py. They are SETUP_ONLY fixtures, not game art."""
import math

import bpy
from mathutils import Color, Vector

from . import env, ops, r15

PALETTE = {
    "neutral": (0.62, 0.62, 0.62, 1),
    "dark": (0.18, 0.18, 0.2, 1),
    "accent": (0.85, 0.55, 0.15, 1),
    "skin": (0.8, 0.66, 0.52, 1),
    "cloth": (0.25, 0.4, 0.62, 1),
    "enemy": (0.55, 0.18, 0.18, 1),
    "metal": (0.7, 0.72, 0.75, 1),
    "wood": (0.45, 0.3, 0.18, 1),
    "foliage": (0.25, 0.5, 0.22, 1),
    "rock": (0.42, 0.4, 0.38, 1),
}

# The R15 Motor6D pose tree (bkit/r15.py `r15_pose`): Left* bones at +X, because a character
# facing -Y has its left side at +X. Before 2026-10-06 this table had the sides swapped (a
# mirrored rig: R15 clips would have moved the opposite limbs); `rig_profile` now checks it.
R15_BONES = r15.POSE_LAYOUT


def _colls(kind):
    root = env.collection(kind)
    return env.collection(kind + "/Source", root), env.collection(kind + "/Export", root)


# Gameplay-template colours, chosen in sRGB (what Studio shows from a baked colour map) and
# converted to the linear values Principled inputs take. Function names, no theme.
GAME_SRGB = {
    "g_base": (0.24, 0.25, 0.28),
    "g_body": (0.72, 0.73, 0.75),
    "g_light": (0.93, 0.93, 0.9),
    "g_accent": (0.96, 0.6, 0.14),
    "g_signal": (0.27, 0.74, 0.38),
    "g_hazard": (0.86, 0.24, 0.17),
    "g_info": (0.22, 0.52, 0.9),
    "g_metal": (0.66, 0.68, 0.72),
    "g_pet": (0.9, 0.66, 0.42),
    "g_glow": (1.0, 0.86, 0.32),
}


def _linear(srgb):
    return (*Color(srgb).from_srgb_to_scene_linear(), 1.0)


def _mat(key):
    if key in GAME_SRGB:
        color = _linear(GAME_SRGB[key])
        metal = key == "g_metal"
        # Emission at half strength: the baked emissive mask stays mid-grey, so the colour shows.
        emission = tuple(c * 0.5 for c in color[:3]) + (1.0,) if key == "g_glow" else None
        return ops.pbr_material("MAT_" + key, color, roughness=0.35 if metal else 0.65, metallic=0.9 if metal else 0.0, emission=emission)
    return ops.pbr_material("MAT_" + key, PALETTE[key], roughness=0.35 if key == "metal" else 0.7, metallic=0.9 if key == "metal" else 0.0)


def _finish(obj, category, **meta):
    ops.box_uv(obj)
    env.set_meta(obj, category=category, template=True, **meta)
    return obj


def _part(name, size, loc, mat, coll):
    obj = ops.box(name, size=size, location=loc, coll=coll)
    ops.assign(obj, _mat(mat))
    return obj


def humanoid(kind="humanoid", height_scale=1.0, cloth="cloth", extra=None):
    src, exp = _colls(kind)
    s = height_scale
    pieces = [
        # Facing -Y, the character's left is +X (bkit/r15.py).
        _part("leg_l", (0.9 * s, 0.9 * s, 2.0 * s), (0.5 * s, 0, 0), cloth, exp),
        _part("leg_r", (0.9 * s, 0.9 * s, 2.0 * s), (-0.5 * s, 0, 0), cloth, exp),
        _part("torso", (2.0 * s, 1.0 * s, 2.0 * s), (0, 0, 2.0 * s), cloth, exp),
        _part("arm_l", (0.8 * s, 0.8 * s, 2.0 * s), (1.45 * s, 0, 1.95 * s), "skin", exp),
        _part("arm_r", (0.8 * s, 0.8 * s, 2.0 * s), (-1.45 * s, 0, 1.95 * s), "skin", exp),
        _part("head", (1.2 * s, 1.2 * s, 1.2 * s), (0, 0, 4.1 * s), "skin", exp),
    ]
    for extra_part in extra or []:
        pieces.append(extra_part(exp, s))
    for p in pieces:
        ops.apply_transforms(p)
    body = ops.join(pieces, "SK_" + kind.capitalize())
    ops.set_origin_base_center(body)
    bones = [(n, Vector(h) * s, Vector(t) * s, p) for n, h, t, p in R15_BONES]
    rig = ops.armature("RIG_" + kind.capitalize(), bones, coll=exp)
    side = lambda w, sign: (w.x * sign) > 1.02 * s  # noqa: E731
    ops.bind_rigid(body, rig, [
        (lambda w: w.z >= 4.0 * s - 1e-3 and abs(w.x) < 0.7 * s, "Head"),
        (lambda w: side(w, 1) and w.z >= 3.0 * s, "LeftUpperArm"),
        (lambda w: side(w, 1) and w.z >= 2.2 * s, "LeftLowerArm"),
        (lambda w: side(w, 1), "LeftHand"),
        (lambda w: side(w, -1) and w.z >= 3.0 * s, "RightUpperArm"),
        (lambda w: side(w, -1) and w.z >= 2.2 * s, "RightLowerArm"),
        (lambda w: side(w, -1), "RightHand"),
        (lambda w: w.z >= 2.7 * s, "UpperTorso"),
        (lambda w: w.z >= 2.0 * s - 1e-3, "LowerTorso"),
        (lambda w: w.x > 0 and w.z >= 1.1 * s, "LeftUpperLeg"),
        (lambda w: w.x > 0 and w.z >= 0.25 * s, "LeftLowerLeg"),
        (lambda w: w.x > 0, "LeftFoot"),
        (lambda w: w.z >= 1.1 * s, "RightUpperLeg"),
        (lambda w: w.z >= 0.25 * s, "RightLowerLeg"),
        (lambda w: True, "RightFoot"),
    ])
    _finish(body, "humanoid", rigged=True, expected_dims=[round(3.7 * s, 2), round(1.2 * s, 2), round(5.3 * s, 2)], up_axis_longest=True)
    env.set_meta(rig, category="humanoid", bone_names=[b[0] for b in R15_BONES], rig_standard="R15-names", rig_profile="r15_pose")
    return [body, rig]


def npc():
    return humanoid("npc", 1.0, cloth="accent")


def enemy():
    def spikes(coll, s):
        spike = ops.cylinder("shoulder", radius=0.3 * s, depth=0.6 * s, segments=8, location=(1.3 * s, 0, 3.95 * s), coll=coll)
        ops.assign(spike, _mat("dark"))
        ops.apply_transforms(spike)  # mirror about the body centre, not the spike's own origin
        ops.mirror(spike, "X", merge=False)
        ops.apply_modifiers(spike)
        return spike
    return humanoid("enemy", 1.2, cloth="enemy", extra=[spikes])


def creature():
    src, exp = _colls("creature")
    parts = [
        _part("body", (2.0, 4.0, 1.6), (0, 0, 1.6), "rock", exp),
        _part("head", (1.4, 1.4, 1.2), (0, -2.6, 2.4), "rock", exp),
        _part("tail", (0.4, 2.0, 0.4), (0, 2.8, 2.6), "dark", exp),
    ]
    for x in (-0.7, 0.7):
        for y in (-1.4, 1.4):
            parts.append(_part("leg", (0.5, 0.5, 1.6), (x, y, 0), "dark", exp))
    for p in parts:
        ops.apply_transforms(p)
    body = ops.join(parts, "SK_Creature")
    ops.set_origin_base_center(body)
    bones = [
        ("Root", (0, 0, 1.6), (0, 0, 2.2), None),
        ("Spine", (0, 1.8, 2.4), (0, -1.8, 2.4), "Root"),
        ("Head", (0, -1.8, 2.4), (0, -3.2, 2.4), "Spine"),
        ("Tail", (0, 1.8, 2.6), (0, 3.8, 2.6), "Spine"),
        ("LegFL", (-0.7, -1.4, 1.6), (-0.7, -1.4, 0), "Root"),
        ("LegFR", (0.7, -1.4, 1.6), (0.7, -1.4, 0), "Root"),
        ("LegBL", (-0.7, 1.4, 1.6), (-0.7, 1.4, 0), "Root"),
        ("LegBR", (0.7, 1.4, 1.6), (0.7, 1.4, 0), "Root"),
    ]
    rig = ops.armature("RIG_Creature", bones, coll=exp)
    ops.bind_rigid(body, rig, [
        (lambda w: w.y < -1.95, "Head"),
        (lambda w: w.y > 2.05, "Tail"),
        (lambda w: w.z < 1.6 - 1e-3 and w.x < 0 and w.y < 0, "LegFL"),
        (lambda w: w.z < 1.6 - 1e-3 and w.x > 0 and w.y < 0, "LegFR"),
        (lambda w: w.z < 1.6 - 1e-3 and w.x < 0, "LegBL"),
        (lambda w: w.z < 1.6 - 1e-3, "LegBR"),
        (lambda w: True, "Spine"),
    ])
    _finish(body, "creature", rigged=True)
    env.set_meta(rig, category="creature", bone_names=[b[0] for b in bones])
    return [body, rig]


def weapon():
    src, exp = _colls("weapon")
    blade = _part("blade", (0.25, 0.08, 3.0), (0, 0, 0.9), "metal", exp)
    ops.extrude(blade, (0, 0, 1), 0.4)  # tip extension
    guard = _part("guard", (1.0, 0.25, 0.2), (0, 0, 0.7), "dark", exp)
    grip = ops.cylinder("grip", radius=0.1, depth=0.8, segments=12, location=(0, 0, -0.1), coll=exp)
    ops.assign(grip, _mat("wood"))
    pommel = ops.sphere("pommel", radius=0.15, segments=12, rings=6, location=(0, 0, -0.15), coll=exp)
    ops.assign(pommel, _mat("dark"))
    for p in (blade, guard, grip, pommel):
        ops.apply_transforms(p)
    sword = ops.join([blade, guard, grip, pommel], "SM_Sword")
    _finish(sword, "weapon", pivot="custom", grip_offset=[0, 0, 0.3], expected_dims=[1.0, 0.3, 4.6])
    return [sword]


def prop():
    src, exp = _colls("prop")
    crate = _part("crate", (4, 4, 4), (0, 0, 0), "wood", exp)
    ops.inset(crate, ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1)), thickness=0.35, depth=-0.15)
    ops.bevel(crate, width=0.06, segments=1)
    crate.name = "SM_Crate"
    _finish(crate, "prop", expected_dims=[4.0, 4.0, 4.0])
    return [crate]


def vehicle():
    src, exp = _colls("vehicle")
    chassis = _part("chassis", (6, 10, 1.5), (0, 0, 1.2), "accent", exp)
    cabin = _part("cabin", (5, 4, 3), (0, 0.5, 2.7), "accent", exp)
    window = ops.box("cut_window", size=(6, 2.5, 1.4), location=(0, 0.5, 3.8), coll=src)
    ops.boolean(cabin, window)
    ops.apply_modifiers(cabin)
    wheels = []
    for x in (-3.2, 3.2):
        for y in (-3.2, 3.2):
            w = ops.cylinder("wheel", radius=1.1, depth=0.8, segments=16, location=(x - 0.4 if x < 0 else x + 0.4, y, 1.1), coll=exp, base_pivot=False, axis="X")
            ops.assign(w, _mat("dark"))
            wheels.append(w)
    for p in [chassis, cabin, *wheels]:
        ops.apply_transforms(p)
    cart = ops.join([chassis, cabin, *wheels], "SM_Cart")
    ops.set_origin_base_center(cart)
    _finish(cart, "vehicle", allow_open=True)
    return [cart]


def building():
    src, exp = _colls("building")
    shell = _part("shell", (16, 12, 10), (0, 0, 0), "neutral", exp)
    ops.solidify(shell, 0.8)
    door = ops.box("cut_door", size=(4, 3, 7), location=(0, -6, 0), coll=src)
    window = ops.box("cut_window", size=(14, 3, 3), location=(0, 6, 4), coll=src)
    ops.boolean(shell, door)
    ops.boolean(shell, window)
    ops.apply_modifiers(shell)
    roof_l = _part("roof_l", (17, 7.5, 0.6), (0, -3.0, 10.6), "dark", exp)
    roof_l.rotation_euler = (math.radians(30), 0, 0)
    roof_r = _part("roof_r", (17, 7.5, 0.6), (0, 3.0, 10.6), "dark", exp)
    roof_r.rotation_euler = (math.radians(-30), 0, 0)
    for p in (shell, roof_l, roof_r):
        ops.apply_transforms(p)
    house = ops.join([shell, roof_l, roof_r], "SM_House")
    ops.set_origin_base_center(house)
    _finish(house, "building", allow_open=True)
    return [house]


def modular():
    """Modular kit on a 4-stud grid: wall, door wall, window wall, floor, corner pillar."""
    src, exp = _colls("modular")
    out = []
    def wall(name, cut=None):
        w = _part(name, (8, 1, 12), (0, 0, 0), "neutral", exp)
        if cut:
            c = ops.box("cut_" + name, size=cut[0], location=cut[1], coll=src)
            ops.boolean(w, c)
            ops.apply_modifiers(w)
        _finish(w, "modular", grid=4, expected_dims=[8, 1, 12], allow_open=False)
        return w
    out.append(wall("SM_Wall"))
    out.append(wall("SM_WallDoor", ((4, 3, 8), (0, 0, 0))))
    out.append(wall("SM_WallWindow", ((4, 3, 4), (0, 0, 4))))
    floor = _part("SM_Floor", (8, 8, 1), (0, 0, 0), "wood", exp)
    _finish(floor, "modular", grid=4, expected_dims=[8, 8, 1])
    pillar = _part("SM_Pillar", (1.5, 1.5, 12), (0, 0, 0), "dark", exp)
    _finish(pillar, "modular", grid=4, expected_dims=[1.5, 1.5, 12])
    out += [floor, pillar]
    for index, obj in enumerate(out):
        obj.location.x = index * 12
    # Preview assembly: arrayed walls (kept as a non-exported reference).
    preview = _part("REF_WallRun", (8, 1, 12), (0, 20, 0), "neutral", src)
    ops.array(preview, count=4, offset=(1, 0, 0))
    env.set_meta(preview, qa="skip")
    return out


def environment():
    src, exp = _colls("environment")
    rock = ops.sphere("SM_Rock", radius=3, segments=12, rings=8, coll=exp)
    for v in rock.data.vertices:  # deterministic lumpy displacement
        n = v.co.normalized()
        bump = 1 + 0.18 * math.sin(n.x * 7.1) * math.cos(n.y * 5.3) + 0.1 * math.sin(n.z * 9.7)
        v.co = v.co * bump
        v.co.z *= 0.6
    ops.set_origin_base_center(rock)
    ops.assign(rock, _mat("rock"))
    _finish(rock, "environment")
    trunk = ops.cylinder("trunk", radius=0.6, depth=7, segments=10, coll=exp)
    ops.assign(trunk, _mat("wood"))
    crown = [ops.sphere("crown", radius=r, segments=10, rings=6, location=loc, coll=exp) for r, loc in ((3, (0, 0, 8)), (2.2, (1.6, 0.6, 9.5)), (2.0, (-1.4, -0.8, 9.8)))]
    for c in crown:
        ops.assign(c, _mat("foliage"))
    for p in [trunk, *crown]:
        ops.apply_transforms(p)
    tree = ops.join([trunk, *crown], "SM_Tree")
    tree.location.x = 10
    _finish(tree, "vegetation", allow_open=True)
    return [rock, tree]


def material_test():
    src, exp = _colls("material_test")
    out = []
    for i, rough in enumerate((0.1, 0.5, 0.9)):
        for j, metal in enumerate((0.0, 1.0)):
            ball = ops.sphere(f"SM_Mat_r{int(rough*10)}_m{int(metal)}", radius=1, location=(i * 3, j * 3, 1), coll=exp)
            mat = ops.pbr_material(f"MAT_r{int(rough*10)}_m{int(metal)}", (0.7, 0.3, 0.2, 1), roughness=rough, metallic=metal)
            ops.assign(ball, mat)
            ops.shade_smooth(ball)
            ops.set_origin_base_center(ball)
            _finish(ball, "test", allow_open=False)
            out.append(ball)
    return out


def rig_test():
    src, exp = _colls("rig_test")
    column = ops.cylinder("SK_RigColumn", radius=0.5, depth=6, segments=12, coll=exp)
    bm_cut = 12
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(column.data)
    edges = [e for e in bm.edges if abs(e.verts[0].co.z - e.verts[1].co.z) > 1]
    bmesh.ops.subdivide_edges(bm, edges=edges, cuts=bm_cut, use_grid_fill=True)
    bm.to_mesh(column.data)
    bm.free()
    ops.assign(column, _mat("accent"))
    rig = ops.armature("RIG_Chain", [("Bone1", (0, 0, 0), (0, 0, 2), None), ("Bone2", (0, 0, 2), (0, 0, 4), "Bone1"), ("Bone3", (0, 0, 4), (0, 0, 6), "Bone2")], coll=exp)
    # One continuous mesh bending along a chain: smooth (bone heat) weights, not rigid bands.
    ops.bind_auto(column, rig)
    _finish(column, "test", rigged=True, expected_dims=[1.0, 1.0, 6.0])
    env.set_meta(rig, category="test", bone_names=["Bone1", "Bone2", "Bone3"])
    return [column, rig]


def animation_test():
    column, rig = rig_test()
    ops.keyframe_clip(rig, "Sway", {"Bone2": [(0, (0, 0, 0)), (15, (20, 0, 0)), (30, (0, 0, 0))], "Bone3": [(0, (0, 0, 0)), (15, (30, 0, 0)), (30, (0, 0, 0))]})
    env.set_meta(rig, animated=True)
    return [column, rig]


# ---------- neutral gameplay templates ----------
# Greybox stand-ins for common gameplay pieces, named by function only. Each single-piece asset
# sits at the world origin with its origin at the base centre (Studio puts an imported model's
# pivot at the file origin) and records `rbx_sockets` (name, position in studs from the pivot in
# Blender axes, yaw in degrees about up) and `rbx_kit_collision` for `factory.py kit` (kit/1).


def _bevelled(name, size, loc, mat, coll, width=0.06):
    obj = _part(name, size, loc, mat, coll)
    ops.bevel(obj, width=width, segments=1)
    ops.apply_modifiers(obj)
    return obj


def _cyl(name, radius, depth, loc, mat, coll, segments=24, axis="Z", base_pivot=True):
    obj = ops.cylinder(name, radius=radius, depth=depth, segments=segments, location=loc, coll=coll, axis=axis, base_pivot=base_pivot)
    ops.assign(obj, _mat(mat))
    return obj


def _assemble(parts, name):
    for p in parts:
        ops.apply_transforms(p)
    return ops.join(parts, name)


def _ground(obj):
    """Origin to the base centre, then the object to the world origin. Returns the pivot offset
    in build coordinates (sockets subtract it)."""
    ops.set_origin_base_center(obj)
    offset = obj.location.copy()
    obj.location = (0, 0, 0)
    return offset


def _kit(obj, offset, collision, sockets=(), **meta):
    env.set_meta(obj, kit_collision=collision, sockets=[{"name": n, "position": [round(c - o, 4) for c, o in zip(p, offset)], "yaw": yaw} for n, p, yaw in sockets], **meta)
    return obj


def pickup():
    """Collectible token: a disc standing upright facing front, emissive core (CanCollide off)."""
    src, exp = _colls("pickup")
    rim = _cyl("rim", 1.0, 0.3, (0, 0, 1.0), "g_accent", exp, segments=24, axis="Y", base_pivot=False)
    core = _cyl("core", 0.68, 0.42, (0, 0, 1.0), "g_glow", exp, segments=24, axis="Y", base_pivot=False)
    token = _assemble([rim, core], "SM_Pickup")
    ops.shade_smooth(token, angle=35)
    offset = _ground(token)
    _finish(token, "gameplay", expected_dims=[2.0, 0.42, 2.0], function="collectible item")
    _kit(token, offset, "none", [("center", (0, 0, 1.0), 0)])
    return [token]


def pad_button():
    """Floor pad button: a plate with a raised round cap (stand on it to press)."""
    src, exp = _colls("pad_button")
    plate = _bevelled("plate", (4, 4, 0.4), (0, 0, 0), "g_base", exp, width=0.08)
    ring = _cyl("ring", 1.65, 0.12, (0, 0, 0.4), "g_light", exp, segments=32)
    cap = _cyl("cap", 1.4, 0.3, (0, 0, 0.4), "g_signal", exp, segments=32)
    pad = _assemble([plate, ring, cap], "SM_PadButton")
    ops.shade_smooth(pad, angle=35)
    offset = _ground(pad)
    _finish(pad, "gameplay", expected_dims=[4.0, 4.0, 0.7], function="press plate")
    _kit(pad, offset, "box", [("press", (0, 0, 0.7), 0)])
    return [pad]


def dropper():
    """Dropper: a post at the back carrying a hopper over the drop point; items leave the nozzle."""
    src, exp = _colls("dropper")
    base = _bevelled("base", (2.0, 2.0, 0.4), (0, 2.0, 0), "g_base", exp)
    post = _bevelled("post", (0.8, 0.8, 6.0), (0, 2.0, 0.4), "g_metal", exp)
    # Arm a little narrower and lower than the post so no faces are coplanar (they z-fight).
    arm = _bevelled("arm", (0.7, 2.4, 0.7), (0, 0.8, 5.6), "g_metal", exp)
    hopper = _bevelled("hopper", (2.4, 2.4, 1.6), (0, 0, 4.2), "g_accent", exp, width=0.1)
    nozzle = _cyl("nozzle", 0.45, 0.8, (0, 0, 3.4), "g_base", exp, segments=16)
    unit = _assemble([base, post, arm, hopper, nozzle], "SM_Dropper")
    offset = _ground(unit)
    _finish(unit, "gameplay", expected_dims=[2.4, 4.2, 6.4], function="spawns items at its drop point")
    _kit(unit, offset, "box", [("drop", (0, 0, 3.4), 0)])
    return [unit]


def conveyor_segment():
    """Conveyor segment on the 4-stud grid: belt between side rails, chevrons point the travel
    direction (front, -Y)."""
    src, exp = _colls("conveyor_segment")
    bed = _part("bed", (3.2, 8, 1.0), (0, 0, 0), "g_body", exp)
    belt = _part("belt", (3.2, 8, 0.3), (0, 0, 1.0), "g_base", exp)
    rails = [_bevelled(f"rail{i}", (0.4, 8, 1.5), (x, 0, 0), "g_metal", exp) for i, x in enumerate((-1.8, 1.8))]
    chevrons = []
    for y in (-2.6, 0.0, 2.6):
        for sign in (-1, 1):
            # The two arms overlap at the apex: lift one a hair so their tops are not coplanar.
            c = _part("chevron", (0.24, 1.3, 0.06), (sign * 0.42, y + 0.1, 1.3 + (0.01 if sign > 0 else 0)), "g_accent", exp)
            c.rotation_euler = (0, 0, math.radians(-sign * 50))  # apex toward the front (-Y)
            chevrons.append(c)
    belt_unit = _assemble([bed, belt, *rails, *chevrons], "SM_ConveyorSegment")
    offset = _ground(belt_unit)
    _finish(belt_unit, "modular", grid=4, expected_dims=[4.0, 8.0, 1.5], budget={"tris": 2000, "materials": 4}, function="moves items toward its front")
    _kit(belt_unit, offset, "box", [("input", (0, 4, 1.3), 0), ("output", (0, -4, 1.3), 0)])
    return [belt_unit]


def tower_base():
    """Defence tower base: octagonal plinth, column and a crenellated platform with a mount."""
    src, exp = _colls("tower_base")
    plinth = _cyl("plinth", 2.2, 0.6, (0, 0, 0), "g_base", exp, segments=8)
    column = _cyl("column", 1.4, 2.0, (0, 0, 0.6), "g_body", exp, segments=8)
    deck = _cyl("deck", 1.8, 0.4, (0, 0, 2.6), "g_accent", exp, segments=8)
    merlons = []
    for i in range(4):
        a = math.radians(45 + 90 * i)
        m = _part("merlon", (0.6, 0.6, 0.5), (1.35 * math.cos(a), 1.35 * math.sin(a), 3.0), "g_body", exp)
        m.rotation_euler = (0, 0, a)
        merlons.append(m)
    tower = _assemble([plinth, column, deck, *merlons], "SM_TowerBase")
    offset = _ground(tower)
    _finish(tower, "gameplay", expected_dims=[4.4, 4.4, 3.5], function="mount for a defence unit")
    _kit(tower, offset, "hull", [("mount", (0, 0, 3.0), 0), ("range_origin", (0, 0, 0), 0)])
    return [tower]


def checkpoint_gate():
    """Checkpoint arch 12 studs wide: posts, a beam with a blank sign band, feet and a floor line.
    The respawn socket is 4 studs in front facing back through the gate (kit/1 example)."""
    src, exp = _colls("checkpoint_gate")
    posts = [_bevelled(f"post{i}", (1.0, 1.4, 8.6), (x, 0, 0.4), "g_body", exp) for i, x in enumerate((-5.4, 5.4))]
    feet = [_bevelled(f"foot{i}", (1.6, 2.4, 0.4), (x, 0, 0), "g_base", exp) for i, x in enumerate((-5.4, 5.4))]
    beam = _bevelled("beam", (12, 1.8, 1.2), (0, 0, 8.8), "g_accent", exp, width=0.08)
    band = _part("band", (9.0, 0.3, 1.1), (0, 0, 7.5), "g_light", exp)
    line = _part("line", (10.0, 0.6, 0.06), (0, 0, 0), "g_signal", exp)
    gate = _assemble([*posts, *feet, beam, band, line], "SM_CheckpointGate")
    offset = _ground(gate)
    _finish(gate, "gameplay", expected_dims=[12.0, 2.4, 10.0], allow_open=False, function="checkpoint trigger and respawn point")
    _kit(gate, offset, "default", [("respawn", (0, -4, 0), 180), ("trigger_center", (0, 0, 4.0), 0)])
    return [gate]


def obby_platform_set():
    """Obstacle-course platforms as separate kit pieces (each at its own base centre, laid out
    along X): square, long, round, step, balance beam and a hazard tile."""
    src, exp = _colls("obby_platform_set")
    specs = [
        ("SM_PlatformSquare", lambda c: _bevelled("p", (4, 4, 1), (0, 0, 0), "g_accent", c, width=0.08), [4, 4, 1], "box"),
        ("SM_PlatformLong", lambda c: _bevelled("p", (4, 12, 1), (0, 0, 0), "g_body", c, width=0.08), [4, 12, 1], "box"),
        ("SM_PlatformRound", lambda c: _cyl("p", 2.5, 1.0, (0, 0, 0), "g_signal", c, segments=32), [5, 5, 1], "hull"),
        ("SM_PlatformStep", lambda c: _bevelled("p", (4, 4, 2), (0, 0, 0), "g_base", c, width=0.08), [4, 4, 2], "box"),
        ("SM_PlatformBeam", lambda c: _bevelled("p", (1, 8, 1), (0, 0, 0), "g_light", c, width=0.05), [1, 8, 1], "box"),
        ("SM_PlatformHazard", lambda c: _bevelled("p", (4, 4, 1), (0, 0, 0), "g_hazard", c, width=0.08), [4, 4, 1], "box"),
    ]
    out, x = [], 0.0
    for name, make, dims, collision in specs:
        piece = make(exp)
        piece.name = piece.data.name = name
        ops.shade_smooth(piece, angle=35)
        ops.apply_transforms(piece)
        offset = _ground(piece)
        piece.location.x = x + dims[0] / 2
        x += dims[0] + 2
        _finish(piece, "modular", grid=1, expected_dims=dims, function="obstacle-course platform" + (" (hazard)" if "Hazard" in name else ""))
        _kit(piece, offset, collision, [("top", (0, 0, dims[2]), 0)])
        out.append(piece)
    return out


def track_segment():
    """Straight track piece, 12 wide and 16 long on the 4-stud grid: road slab, striped kerbs,
    dashed centre line and low side barriers. Travel runs toward the front (-Y)."""
    src, exp = _colls("track_segment")
    parts = [_part("road", (12, 16, 0.5), (0, 0, 0), "g_base", exp)]
    for sign in (-1, 1):
        parts.append(_bevelled("barrier", (0.5, 16, 1.0), (sign * 5.75, 0, 0.5), "g_light", exp, width=0.05))
        for i in range(8):
            parts.append(_part("kerb", (1.0, 2.0, 0.2), (sign * 5.0, -7 + 2 * i, 0.5), "g_hazard" if i % 2 else "g_light", exp))
    for y in (-6, -2, 2, 6):
        parts.append(_part("dash", (0.3, 2.0, 0.04), (0, y, 0.5), "g_light", exp))
    road = _assemble(parts, "SM_TrackSegment")
    offset = _ground(road)
    _finish(road, "modular", grid=4, expected_dims=[12.0, 16.0, 1.5], budget={"tris": 2000, "materials": 4}, function="drivable track piece")
    _kit(road, offset, "default", [("start", (0, 8, 0.5), 0), ("end", (0, -8, 0.5), 0)])
    return [road]


PET_BONES = [
    ("Root", (0, 0, 0.7), (0, 0, 1.2), None),
    ("Body", (0, 0.9, 1.0), (0, -0.9, 1.0), "Root"),
    ("Head", (0, -1.0, 1.3), (0, -1.0, 2.3), "Body"),
    ("Tail", (0, 1.1, 1.2), (0, 1.8, 1.6), "Body"),
    ("LegFL", (0.55, -0.75, 0.7), (0.55, -0.75, 0.0), "Root"),
    ("LegFR", (-0.55, -0.75, 0.7), (-0.55, -0.75, 0.0), "Root"),
    ("LegBL", (0.55, 0.75, 0.7), (0.55, 0.75, 0.0), "Root"),
    ("LegBR", (-0.55, 0.75, 0.7), (-0.55, 0.75, 0.0), "Root"),
]


def pet_follower():
    """Small four-legged follower on a custom rig (rigid parts) with two looping clips in place:
    idle (60 frames: breathing bob, head tilt, tail wag) and walk (30 frames: diagonal leg pairs,
    footstep markers on frames 7 and 22). Front -Y, left +X."""
    src, exp = _colls("pet_follower")
    parts = [
        _bevelled("body", (1.6, 2.2, 1.0), (0, 0, 0.7), "g_pet", exp, width=0.12),
        _bevelled("head", (1.4, 1.2, 1.2), (0, -1.45, 1.2), "g_pet", exp, width=0.12),
        _part("ear_l", (0.3, 0.2, 0.45), (0.45, -1.45, 2.4), "g_base", exp),
        _part("ear_r", (0.3, 0.2, 0.45), (-0.45, -1.45, 2.4), "g_base", exp),
        _part("eye_l", (0.24, 0.08, 0.26), (0.32, -2.07, 1.85), "g_base", exp),
        _part("eye_r", (0.24, 0.08, 0.26), (-0.32, -2.07, 1.85), "g_base", exp),
        _part("nose", (0.3, 0.1, 0.2), (0, -2.08, 1.45), "g_base", exp),
        _part("tail", (0.3, 0.8, 0.3), (0, 1.45, 1.2), "g_base", exp),
    ]
    for x in (-0.55, 0.55):
        for y in (-0.75, 0.75):
            parts.append(_part("leg", (0.45, 0.45, 0.72), (x, y, 0), "g_pet", exp))
    body = _assemble(parts, "SK_PetFollower")
    offset = _ground(body)  # bones and predicates below are in build coordinates, shifted by it
    rig = ops.armature("RIG_PetFollower", [(n, Vector(h) - offset, Vector(t) - offset, p) for n, h, t, p in PET_BONES], coll=exp)
    at = lambda test: (lambda w: test(w + offset))  # noqa: E731
    ops.bind_rigid(body, rig, [
        (at(lambda b: b.y < -0.86), "Head"),
        (at(lambda b: b.y > 1.1), "Tail"),
        (at(lambda b: b.z < 0.7 - 1e-3 and b.x > 0 and b.y < 0), "LegFL"),
        (at(lambda b: b.z < 0.7 - 1e-3 and b.x < 0 and b.y < 0), "LegFR"),
        (at(lambda b: b.z < 0.7 - 1e-3 and b.x > 0), "LegBL"),
        (at(lambda b: b.z < 0.7 - 1e-3), "LegBR"),
        (lambda w: True, "Body"),
    ])
    _finish(body, "creature", rigged=True, budget={"tris": 3000, "materials": 4}, expected_dims=[1.6, 3.98, 2.85], function="pet that follows a player")
    _kit(body, offset, "none", [("head_top", (0, -1.45, 2.85), 0)])
    env.set_meta(rig, category="creature", bone_names=[b[0] for b in PET_BONES])
    from . import clips

    still = (0, 0, 0)
    clips.add_clip(rig, "idle", {
        # Location keys are in the bone's frame: Root points up, so its local Y is world up.
        "Root": [(0, still, (0, 0, 0)), (30, still, (0, 0.06, 0)), (59, still, (0, 0, 0))],
        "Head": [(0, still), (20, (8, 0, 0)), (40, (-4, 0, 6)), (59, still)],
        "Tail": [(0, still), (15, (0, 0, 22)), (30, still), (45, (0, 0, -22)), (59, still)],
    }, fps=30, loop=True, slot="idle", priority="Idle")
    swing = 28
    clips.add_clip(rig, "walk", {
        "Root": [(0, still, (0, 0, 0)), (7, still, (0, 0.08, 0)), (15, still, (0, 0, 0)), (22, still, (0, 0.08, 0)), (29, still, (0, 0, 0))],
        "LegFL": [(0, (swing, 0, 0)), (15, (-swing, 0, 0)), (29, (swing, 0, 0))],
        "LegBR": [(0, (swing, 0, 0)), (15, (-swing, 0, 0)), (29, (swing, 0, 0))],
        "LegFR": [(0, (-swing, 0, 0)), (15, (swing, 0, 0)), (29, (-swing, 0, 0))],
        "LegBL": [(0, (-swing, 0, 0)), (15, (swing, 0, 0)), (29, (-swing, 0, 0))],
        "Tail": [(0, (0, 0, 12)), (15, (0, 0, -12)), (29, (0, 0, 12))],
    }, fps=30, loop=True, slot="walk", priority="Movement", markers=[("footstep", 7, "left"), ("footstep", 22, "right")])
    return [body, rig]


def _dome(name, radius, height, coll):
    """Closed half-ellipsoid: a UV sphere cut at its equator, the bottom capped, scaled in Z."""
    import bmesh

    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=radius)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-5], context="VERTS")
    edges = [e for e in bm.edges if e.is_boundary]
    bmesh.ops.contextual_create(bm, geom=edges)
    bmesh.ops.scale(bm, vec=Vector((1, 1, height / radius)), verts=bm.verts)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    coll.objects.link(obj)
    return obj


def accessory_rigid():
    """Rigid head accessory (one mesh, one attachment, at most 4000 triangles: Roblox accessory
    rules): a dome with a band and a front visor. Its HatAttachment sits at the bottom centre,
    where it meets the head's HatAttachment."""
    src, exp = _colls("accessory_rigid")
    dome = _dome("dome", 1.0, 0.85, exp)
    ops.assign(dome, _mat("g_info"))
    band = _cyl("band", 1.04, 0.22, (0, 0, 0), "g_accent", exp, segments=24)
    visor = _bevelled("visor", (1.5, 0.9, 0.08), (0, -1.2, 0.02), "g_base", exp, width=0.03)
    hat = _assemble([dome, band, visor], "SM_AccessoryRigid")
    ops.shade_smooth(hat, angle=35)
    offset = _ground(hat)
    _finish(hat, "accessory", expected_dims=[2.08, 2.69, 0.85], function="rigid accessory")
    _kit(hat, offset, "none", [("hat_attachment", (0, 0, 0.0), 0)], accessory={"attachment": "HatAttachment", "max_tris": 4000})
    return [hat]


TEMPLATES = {
    "humanoid": humanoid,
    "npc": npc,
    "enemy": enemy,
    "creature": creature,
    "weapon": weapon,
    "prop": prop,
    "vehicle": vehicle,
    "building": building,
    "modular": modular,
    "environment": environment,
    "material_test": material_test,
    "rig_test": rig_test,
    "animation_test": animation_test,
    # Neutral greybox gameplay templates (function names, no theme), 2026-10-06.
    "pickup": pickup,
    "pad_button": pad_button,
    "dropper": dropper,
    "conveyor_segment": conveyor_segment,
    "tower_base": tower_base,
    "checkpoint_gate": checkpoint_gate,
    "obby_platform_set": obby_platform_set,
    "track_segment": track_segment,
    "pet_follower": pet_follower,
    "accessory_rigid": accessory_rigid,
}
GAMEPLAY = ("pickup", "pad_button", "dropper", "conveyor_segment", "tower_base", "checkpoint_gate", "obby_platform_set", "track_segment", "pet_follower", "accessory_rigid")
# Templates whose rig carries clips (bkit.clips): kind -> clips/1 rig kind.
CLIP_RIGS = {"pet_follower": "custom"}


def build(kind):
    env.reset()
    objs = TEMPLATES[kind]()
    bpy.context.scene["rbx_template"] = kind
    return objs
