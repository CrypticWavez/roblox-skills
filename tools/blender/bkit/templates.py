"""Neutral starting templates. Each builds a fully-conventioned blockout: collections
(<Kind>/Source, <Kind>/Export), prefixes (SM_ static, SK_ skinned, RIG_ armature, MAT_),
1 BU = 1 stud, front faces -Y, pivot at base-centre (weapons pivot at the grip), and
`rbx_*` validation metadata read by qa.py. They are SETUP_ONLY fixtures, not game art."""
import math

import bpy
from mathutils import Vector

from . import env, ops

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

R15_BONES = [
    # name, head, tail, parent  (studs; character 5.5 tall, feet at z=0, front -Y)
    ("HumanoidRootPart", (0, 0, 2.0), (0, 0, 2.6), None),
    ("LowerTorso", (0, 0, 2.0), (0, 0, 2.7), "HumanoidRootPart"),
    ("UpperTorso", (0, 0, 2.7), (0, 0, 4.0), "LowerTorso"),
    ("Head", (0, 0, 4.0), (0, 0, 5.3), "UpperTorso"),
    ("LeftUpperArm", (-1.0, 0, 3.9), (-1.0, 0, 3.0), "UpperTorso"),
    ("LeftLowerArm", (-1.0, 0, 3.0), (-1.0, 0, 2.2), "LeftUpperArm"),
    ("LeftHand", (-1.0, 0, 2.2), (-1.0, 0, 1.9), "LeftLowerArm"),
    ("RightUpperArm", (1.0, 0, 3.9), (1.0, 0, 3.0), "UpperTorso"),
    ("RightLowerArm", (1.0, 0, 3.0), (1.0, 0, 2.2), "RightUpperArm"),
    ("RightHand", (1.0, 0, 2.2), (1.0, 0, 1.9), "RightLowerArm"),
    ("LeftUpperLeg", (-0.5, 0, 2.0), (-0.5, 0, 1.1), "LowerTorso"),
    ("LeftLowerLeg", (-0.5, 0, 1.1), (-0.5, 0, 0.25), "LeftUpperLeg"),
    ("LeftFoot", (-0.5, 0, 0.25), (-0.5, -0.4, 0.05), "LeftLowerLeg"),
    ("RightUpperLeg", (0.5, 0, 2.0), (0.5, 0, 1.1), "LowerTorso"),
    ("RightLowerLeg", (0.5, 0, 1.1), (0.5, 0, 0.25), "RightUpperLeg"),
    ("RightFoot", (0.5, 0, 0.25), (0.5, -0.4, 0.05), "RightLowerLeg"),
]


def _colls(kind):
    root = env.collection(kind)
    return env.collection(kind + "/Source", root), env.collection(kind + "/Export", root)


def _mat(key):
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
        _part("leg_l", (0.9 * s, 0.9 * s, 2.0 * s), (-0.5 * s, 0, 0), cloth, exp),
        _part("leg_r", (0.9 * s, 0.9 * s, 2.0 * s), (0.5 * s, 0, 0), cloth, exp),
        _part("torso", (2.0 * s, 1.0 * s, 2.0 * s), (0, 0, 2.0 * s), cloth, exp),
        _part("arm_l", (0.8 * s, 0.8 * s, 2.0 * s), (-1.45 * s, 0, 1.95 * s), "skin", exp),
        _part("arm_r", (0.8 * s, 0.8 * s, 2.0 * s), (1.45 * s, 0, 1.95 * s), "skin", exp),
        _part("head", (1.2 * s, 1.2 * s, 1.2 * s), (0, 0, 4.1 * s), "skin", exp),
    ]
    for extra_part in extra or []:
        pieces.append(extra_part(exp, s))
    for p in pieces:
        ops.apply_transforms(p)
    body = ops.join(pieces, "SK_" + kind.capitalize())
    ops.set_origin_base_center(body)
    bones = [(n, Vector(h) * s, Vector(t) * s, p) for n, h, t, p in R15_BONES]
    bones = [(n, h + Vector((0, 0, 0)), t, p) for n, h, t, p in bones]
    rig = ops.armature("RIG_" + kind.capitalize(), bones, coll=exp)
    side = lambda w, sign: (w.x * sign) > 1.02 * s  # noqa: E731
    ops.bind_rigid(body, rig, [
        (lambda w: w.z >= 4.0 * s - 1e-3 and abs(w.x) < 0.7 * s, "Head"),
        (lambda w: side(w, -1) and w.z >= 3.0 * s, "LeftUpperArm"),
        (lambda w: side(w, -1) and w.z >= 2.2 * s, "LeftLowerArm"),
        (lambda w: side(w, -1), "LeftHand"),
        (lambda w: side(w, 1) and w.z >= 3.0 * s, "RightUpperArm"),
        (lambda w: side(w, 1) and w.z >= 2.2 * s, "RightLowerArm"),
        (lambda w: side(w, 1), "RightHand"),
        (lambda w: w.z >= 2.7 * s, "UpperTorso"),
        (lambda w: w.z >= 2.0 * s - 1e-3, "LowerTorso"),
        (lambda w: w.x < 0 and w.z >= 1.1 * s, "LeftUpperLeg"),
        (lambda w: w.x < 0 and w.z >= 0.25 * s, "LeftLowerLeg"),
        (lambda w: w.x < 0, "LeftFoot"),
        (lambda w: w.z >= 1.1 * s, "RightUpperLeg"),
        (lambda w: w.z >= 0.25 * s, "RightLowerLeg"),
        (lambda w: True, "RightFoot"),
    ])
    _finish(body, "humanoid", rigged=True, expected_dims=[round(3.7 * s, 2), round(1.2 * s, 2), round(5.3 * s, 2)], up_axis_longest=True)
    env.set_meta(rig, category="humanoid", bone_names=[b[0] for b in R15_BONES], rig_standard="R15-names")
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
    ops.bind_rigid(column, rig, [(lambda w: w.z >= 4, "Bone3"), (lambda w: w.z >= 2, "Bone2"), (lambda w: True, "Bone1")])
    _finish(column, "test", rigged=True, expected_dims=[1.0, 1.0, 6.0])
    env.set_meta(rig, category="test", bone_names=["Bone1", "Bone2", "Bone3"])
    return [column, rig]


def animation_test():
    column, rig = rig_test()
    ops.keyframe_clip(rig, "Sway", {"Bone2": [(0, (0, 0, 0)), (15, (20, 0, 0)), (30, (0, 0, 0))], "Bone3": [(0, (0, 0, 0)), (15, (30, 0, 0)), (30, (0, 0, 0))]})
    env.set_meta(rig, animated=True)
    return [column, rig]


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
}


def build(kind):
    env.reset()
    objs = TEMPLATES[kind]()
    bpy.context.scene["rbx_template"] = kind
    return objs
