"""Self-test cases for the look, clip, rig, collision, template, kit and intake pipeline (run by
`factory.py qa-selftest` after the QA verdict cases in selftest.py). Each case builds something,
runs the real code path and returns a detail string; an AssertionError (or any exception) fails
it. Pixel checks read the written PNGs back with the pure-Python decoder, so they test the bytes
that ship, and determinism checks compare bytes between two runs."""
import hashlib
import json
from pathlib import Path

import bpy

from . import bake, bakecmd, build, clips, compare, env, expectation, formats, glbfix, icons, intake, kit, ops, png, qa, r15, templates, textures

ROOT = Path(__file__).resolve().parents[3]
FIXTURE_LIBRARY = ROOT / "tools" / "blender" / "fixtures" / "material-library.json"
SRGB = {"MAT_Red": (0.85, 0.2, 0.15), "MAT_Green": (0.25, 0.7, 0.3), "MAT_Steel": (0.6, 0.62, 0.66), "MAT_Glow": (1.0, 0.85, 0.3)}


def _linear(srgb):
    from mathutils import Color

    return (*Color(srgb).from_srgb_to_scene_linear(), 1.0)


def _materials():
    return {
        "MAT_Red": ops.pbr_material("MAT_Red", _linear(SRGB["MAT_Red"]), roughness=0.7),
        "MAT_Green": ops.pbr_material("MAT_Green", _linear(SRGB["MAT_Green"]), roughness=0.7),
        "MAT_Steel": ops.pbr_material("MAT_Steel", _linear(SRGB["MAT_Steel"]), roughness=0.3, metallic=0.9),
        "MAT_Glow": ops.pbr_material("MAT_Glow", _linear(SRGB["MAT_Glow"]), roughness=0.7, emission=(*_linear(SRGB["MAT_Glow"])[:3], 1.0)),
    }


def _painted_box(name="SM_Painted", names=("MAT_Red", "MAT_Green", "MAT_Steel", "MAT_Glow")):
    """A 4-stud box (base-centre at the origin) whose faces cycle through `names`, with the
    sRGB colour each face should end up with. Collections: <name>/Export."""
    coll = env.collection(name + "/Export", env.collection(name))
    obj = ops.box(name, size=(4, 4, 4), coll=coll)
    mats = _materials()
    for n in names:
        obj.data.materials.append(mats[n])
    for poly in obj.data.polygons:
        poly.material_index = poly.index % len(names)
    ops.box_uv(obj)
    env.set_meta(obj, category="prop", budget={"tris": 2000, "materials": 4})
    expected = {poly.index: SRGB[names[poly.index % len(names)]] for poly in obj.data.polygons}
    return obj, expected


def _srgb8(c):
    return tuple(int(round(v * 255)) for v in c)


def _close(a, b, tol):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def _file_hash(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()[:12]


def _summary_ok(summary, allowed_warnings=()):
    assert summary["pass"], f"QA errors {summary['errors']}"
    extra = [w for w in summary["warnings"] if not any(w.endswith(":" + a) for a in allowed_warnings)]
    return extra


# ---------- looks ----------

def case_palette_atlas(out):
    """One material, one colour image, data maps only where materials differ, colours exact per
    face, colour spaces right, a Color attribute fallback, identical bytes on a second run, QA
    clean in the scene and after GLB/FBX re-import (one material, colour map, colour attribute)."""
    digests = []
    for run in range(2):
        env.reset()
        obj, expected = _painted_box()
        result = bake.palette_atlas([obj], out / f"palette{run}", "palette_box")
        digests.append({role: _file_hash(path) for role, path in result["files"].items()})
    assert digests[0] == digests[1], f"palette bytes differ between runs: {digests}"
    assert len(obj.data.materials) == 1 and obj.data.materials[0].name == "MAT_palette_box", [m.name for m in obj.data.materials]
    roles = textures.image_roles(obj.data.materials[0])
    by_role = {r: img for img, rs in roles.items() for r in rs}
    assert set(result["maps"]) == {"color", "roughness", "metalness", "emissive"}, result["maps"]
    assert sorted(by_role) == sorted(result["maps"]), (sorted(by_role), result["maps"])
    for role, image in by_role.items():
        assert image.colorspace_settings.name == textures.COLORSPACE[role], (role, image.colorspace_settings.name)
    assert len(obj.data.uv_layers) == 1
    uv = obj.data.uv_layers.active.data
    assert all(0 <= c <= 1 for d in uv for c in d.uv), "UVs outside 0..1"
    color = result["files"]["color"]
    for face, uvc in bake.face_uv_centres(obj).items():
        got = bake.sample_map(color, uvc)
        assert _close(got, _srgb8(expected[face]), 1), f"face {face}: {got} != {_srgb8(expected[face])}"
    rough = bake.sample_map(result["files"]["roughness"], bake.face_uv_centres(obj)[2])  # face 2 is MAT_Steel
    assert abs(rough[0] - round(0.3 * 255)) <= 1, rough
    attr = obj.data.color_attributes.get("Color")
    assert attr is not None and attr.domain == "CORNER"
    corner = obj.data.polygons[1].loop_indices[0]
    assert _close(_srgb8(attr.data[corner].color_srgb[:3]), _srgb8(expected[1]), 1)
    extra = _summary_ok(qa.run(export_probe=False)["summary"])
    assert not extra, f"warnings {extra}"
    files = {"fbx": ops.export_fbx(out / "palette_box.fbx"), "glb": ops.export_glb(out / "palette_box.glb")}
    for fmt, path in files.items():
        report = qa.check_file(path)
        _summary_ok(report["summary"], allowed_warnings=("texture_suffix",))
        meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
        look = expectation.appearance_of(meshes)
        assert len(look["materials"]) == 1 and "color" in look["maps"], (fmt, look)
        assert look["color_attributes"], (fmt, "colour attribute lost")
    return f"4 materials -> 1 ({result['size'][0]} px, maps {sorted(result['maps'])}), bytes stable {digests[0]['color']}"


def case_vertex_colors(out):
    env.reset()
    obj, expected = _painted_box("SM_Vertex", names=("MAT_Red", "MAT_Green"))
    result = bake.vertex_colors([obj], "vertex_box")
    assert len(obj.data.materials) == 1 and result["palette"] == 2, result
    assert not textures.image_roles(obj.data.materials[0]), "vertex route wrote images"
    extra = _summary_ok(qa.run(export_probe=False)["summary"])
    assert not extra, extra
    path = ops.export_glb(out / "vertex_box.glb")
    env.reset()
    bpy.ops.import_scene.gltf(filepath=str(path))
    mesh = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    colours = {_srgb8(d.color_srgb[:3]) for a in mesh.data.color_attributes for d in a.data}
    want = {_srgb8(SRGB["MAT_Red"]), _srgb8(SRGB["MAT_Green"])}
    assert all(any(_close(c, w, 1) for c in colours) for w in want), (colours, want)
    return f"2 colours in COLOR_0 after GLB re-import: {sorted(colours)}"


def case_bake_maps_flat(out):
    """Cycles bakes of flat materials: base colour within 2/255 per face, metalness and
    roughness values, a flat tangent normal (128, 128, 255), the island margin kept, colour
    spaces tagged, and identical bytes on a second bake."""
    hashes = []
    for run in range(2):
        env.reset()
        obj, expected = _painted_box("SM_Baked", names=("MAT_Red", "MAT_Steel"))
        result = bake.bake_maps(obj, out / f"maps{run}", "baked_box", size=128, margin=4)
        hashes.append({r: _file_hash(p) for r, p in result["files"].items()})
    assert hashes[0] == hashes[1], f"bake not deterministic: {hashes}"
    centres = bake.face_uv_centres(obj)
    for face, uvc in centres.items():
        got = bake.sample_map(result["files"]["color"], uvc)
        assert _close(got, _srgb8(expected[face]), 2), f"face {face} colour {got} != {_srgb8(expected[face])}"
        metal = bake.sample_map(result["files"]["metalness"], uvc)[0]
        want = 0.9 if expected[face] == SRGB["MAT_Steel"] else 0.0
        assert abs(metal - want * 255) <= 2, (face, metal, want)
        rough = bake.sample_map(result["files"]["roughness"], uvc)[0]
        want = 0.3 if expected[face] == SRGB["MAT_Steel"] else 0.7
        assert abs(rough - want * 255) <= 3, (face, rough, want)
        normal = bake.sample_map(result["files"]["normal"], uvc)
        assert _close(normal, (128, 128, 255), 3), (face, normal)
    gap, islands = bake.island_gap(obj)
    assert gap >= 0.5 * 4 / 128, f"islands {gap:.4f} apart, margin {4 / 128:.4f}"
    image = next(iter(textures.image_roles(obj.data.materials[0])))
    roles = {r: img.colorspace_settings.name for img, rs in textures.image_roles(obj.data.materials[0]).items() for r in rs}
    assert roles == {r: textures.COLORSPACE[r] for r in roles}, roles
    assert image is not None and len(obj.data.uv_layers) == 1
    return f"{islands} islands, min gap {gap * 128:.1f} px, bytes stable"


def case_bake_maps_high_to_low(out):
    env.reset()
    coll = env.collection("Bevel/Export", env.collection("Bevel"))
    low = ops.box("SM_Low", size=(2, 2, 2), coll=coll)
    ops.assign(low, ops.pbr_material("MAT_Grey", (0.5, 0.5, 0.5, 1)))
    ops.box_uv(low)
    high = ops.box("SM_High", size=(2, 2, 2))
    ops.bevel(high, width=0.35, segments=6, limit_angle=30)
    ops.apply_modifiers(high)
    ops.shade_smooth(high, angle=180)
    ops.assign(high, ops.pbr_material("MAT_Grey", (0.5, 0.5, 0.5, 1)))
    result = bake.bake_maps(low, out / "high_to_low", "bevel_box", maps=("normal",), size=64, margin=2, high=high, cage_extrusion=0.05)
    image = png.read(result["files"]["normal"])
    flat = sum(1 for row in image["rows"] for i in range(0, len(row), 3) if _close(row[i:i + 3], (128, 128, 255), 6))
    total = image["width"] * image["height"]
    bent = total - flat
    assert bent > total * 0.1, f"only {bent} of {total} normal-map pixels bent: the bevel did not transfer"
    return f"{bent}/{total} pixels carry the bevel"


def case_principled_renamed(out):
    env.reset()
    obj, expected = _painted_box("SM_Renamed", names=("MAT_Red", "MAT_Green"))
    for mat in obj.data.materials:
        node = ops.principled(mat)
        node.name = node.label = "Shader Principe"  # a localised UI renames nodes
    result = bake.palette_atlas([obj], out / "renamed", "renamed_box")
    face = 0
    got = bake.sample_map(result["files"]["color"], bake.face_uv_centres(obj)[face])
    assert _close(got, _srgb8(expected[face]), 1), got
    return "Principled found by type after rename"


def case_appearance_declared(out):
    env.reset()
    obj, _ = _painted_box("SM_Flat", names=("MAT_Red", "MAT_Green"))
    summary = qa.run(export_probe=False)["summary"]
    assert "SM_Flat:appearance_declared" in summary["errors"], summary
    env.reset()
    obj, _ = _painted_box("SM_OneFlat", names=("MAT_Red",))
    summary = qa.run(export_probe=False)["summary"]
    assert summary["pass"] and "SM_OneFlat:appearance_declared" in summary["warnings"], summary
    env.reset()
    obj, _ = _painted_box("SM_Library", names=("MAT_Red", "MAT_Green"))
    for mat in obj.data.materials:
        mat["rbx_library"] = "concrete_a"
    summary = qa.run(export_probe=False)["summary"]
    assert summary["pass"] and not any(w.endswith("appearance_declared") for w in summary["warnings"]), summary
    return "2 flat -> error, 1 flat -> warning, library -> declared"


def case_texture_rules(out):
    """texture_size (2048 without a reason), texture_colorspace (normal map tagged sRGB),
    texture_suffix (warning), uv_single_set and uv_unit_square on a textured mesh."""
    env.reset()
    obj, _ = _painted_box("SM_Tex", names=("MAT_Red",))
    big = bpy.data.images.new("tex_Color.png", 2048, 2048)
    normal = bpy.data.images.new("tex_bump.png", 64, 64)
    normal.colorspace_settings.name = "sRGB"
    for image in (big, normal):
        image.filepath_raw = str(out / image.name)
        image.file_format = "PNG"
        image.save()
    mat = textures.material_from_maps("MAT_Tex", {"color": big, "normal": normal})
    obj.data.materials.clear()
    ops.assign(obj, mat)
    obj.data.uv_layers.new(name="Second")
    obj.data.uv_layers.active.data[0].uv = (1.5, 0.5)
    summary = qa.run(export_probe=False)["summary"]
    for name in ("texture_size", "texture_colorspace", "uv_single_set", "uv_unit_square"):
        assert f"SM_Tex:{name}" in summary["errors"], (name, summary)
    assert "SM_Tex:texture_suffix" in summary["warnings"], summary
    return "size, colour space, UV set and unit-square errors; suffix warning"


def case_library_names(out):
    data = json.loads(FIXTURE_LIBRARY.read_text())
    assert not textures.validate_library(data), textures.validate_library(data)
    names = textures.library_names(data)
    pieces = [{"key": "a", "materials": ["library:concrete_a"]}, {"key": "b", "materials": ["library:not_there", "atlas:x.png"]}]
    problems = kit.library_problems(pieces, names, "fixture")
    assert problems == ["b: library:not_there is not in fixture"], problems
    bad = json.loads(json.dumps(data))
    bad["materials"][0]["maps"]["normal"] = "fixture_source/concrete_a#NormalDX"
    bad["materials"][1]["resolution"] = 2048
    found = textures.validate_library(bad)
    assert any("DirectX" in p for p in found) and any("justify" in p for p in found), found
    return f"{len(names)} names; unknown name, DirectX normal and 2048 without justify rejected"


def _checker_blend(path):
    """A .blend whose material is a procedural checker (4 squares per tile, so it repeats
    seamlessly) driving colour and roughness."""
    env.reset()
    coll = env.collection("Tile/Export", env.collection("Tile"))
    obj = ops.box("SM_Sample", size=(2, 2, 2), coll=coll)
    mat = ops.pbr_material("MAT_Checker", (0.5, 0.5, 0.5, 1))
    tree = ops.node_tree(mat)
    coords = tree.nodes.new("ShaderNodeTexCoord")
    checker = tree.nodes.new("ShaderNodeTexChecker")
    checker.inputs["Scale"].default_value = 4.0
    checker.inputs["Color1"].default_value = _linear((0.9, 0.5, 0.15))
    checker.inputs["Color2"].default_value = _linear((0.2, 0.25, 0.35))
    tree.links.new(coords.outputs["UV"], checker.inputs["Vector"])
    bsdf = ops.principled(mat)
    tree.links.new(checker.outputs["Color"], bsdf.inputs["Base Color"])
    tree.links.new(checker.outputs["Fac"], bsdf.inputs["Roughness"])
    ops.assign(obj, mat)
    ops.box_uv(obj)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))
    return path


def case_bake_command_tile(out):
    """`factory.py bake <file.blend> --mode tile --library`: a procedural material baked to a
    MaterialVariant-ready tile (colour sRGB RGB, roughness 8-bit grey) that repeats with the
    checker's period, a material-library/1 file citing it (`build:` paths) with the base material
    of the fixture entry of the same name, and material-preview rendering it."""
    blend = _checker_blend(out / "tile_source.blend")
    result = bakecmd.run(str(blend), out / "bakecmd", mode="tile", size=128, name="bake_library", library=str(FIXTURE_LIBRARY), previews=False)
    assert result["pass"], result["problems"]
    assert sorted(result["maps"]) == ["color", "roughness"], result["maps"]
    data = json.loads(Path(result["library"]).read_text())
    assert not textures.validate_library(data), textures.validate_library(data)
    entry = data["materials"][0]
    assert entry["name"] == "bake_library" and entry["maps"]["color"].startswith("build:") and entry["studs_per_tile"] == 4, entry
    image = png.read(out / "bakecmd" / "bake_library" / "bake_library_Color.png")
    w = image["width"]
    rows = image["rows"]
    same = sum(1 for row in rows for x in range(w) if row[3 * x:3 * x + 3] == row[3 * ((x + w // 2) % w):3 * ((x + w // 2) % w) + 3])
    assert same >= 0.95 * w * image["height"], f"tile does not repeat with the checker period: {same}/{w * image['height']}"
    rough = png.read(out / "bakecmd" / "bake_library" / "bake_library_Roughness.png")
    assert rough["channels"] == 1, rough["channels"]
    preview = bakecmd.material_preview(result["library"], out / "material-preview")
    assert not preview["problems"] and list(preview["rendered"]) == ["bake_library"], preview
    return f"tile maps {sorted(result['maps'])}, period ok ({same} px); preview {Path(preview['rendered']['bake_library'][0]).name}"


def case_bake_command_maps(out):
    """`factory.py bake <kind> --mode maps`: a template's SurfaceAppearance map set, shipped
    through the QA gate."""
    result = bakecmd.run("pickup", out / "bakecmd", mode="maps", size=256, previews=False)
    assert result["pass"], result["problems"]
    assert {"color", "roughness", "metalness", "normal", "emissive"} == set(result["appearance"]["maps"]), result["appearance"]
    assert "glb" in result["files"] and "fbx" in result["files"], result["files"]
    return f"pickup maps {sorted(result['appearance']['maps'])} shipped"


def case_icon_deterministic(out):
    hashes = []
    for run in range(2):
        env.reset()
        obj, _ = _painted_box("SM_Icon", names=("MAT_Red", "MAT_Green"))
        hashes.append(icons.render_icon([obj], out / f"icon{run}.png", size=64, samples=4)["pixel_hash"])
    assert hashes[0] == hashes[1], hashes
    image = png.read(out / "icon0.png")
    assert image["channels"] == 4 and image["rows"][0][3] == 0, "background not transparent"
    return f"pixel hash {hashes[0]}"


# ---------- clips and rigs ----------

def _clip_rig(name="RIG_Clip"):
    coll = env.collection("Clip/Export", env.collection("Clip"))
    body = ops.box("SK_Clip", size=(1, 1, 4), coll=coll)
    ops.assign(body, ops.pbr_material("MAT_Grey", (0.5, 0.5, 0.5, 1)))
    ops.box_uv(body)
    rig = ops.armature(name, [("Root", (0, 0, 0), (0, 0, 2), None), ("Top", (0, 0, 2), (0, 0, 4), "Root")], coll=coll)
    ops.bind_rigid(body, rig, [(lambda w: w.z > 2, "Top"), (lambda w: True, "Root")])
    return body, rig


def case_clips_export(out):
    """Two clips: multi-clip GLB with 2 animations of the right lengths, one FBX per clip whose
    re-import keeps the frame range and a key on every frame, and a valid clips/1 sidecar."""
    env.reset()
    body, rig = _clip_rig()
    clips.add_clip(rig, "idle", {"Top": [(0, (0, 0, 0)), (30, (0, 8, 0)), (59, (0, 0, 0))]}, slot="idle", priority="Idle")
    clips.add_clip(rig, "walk", {"Top": [(0, (0, 0, 0)), (15, (12, 0, 0)), (29, (0, 0, 0))]}, slot="walk", markers=[("footstep", 7, "left"), ("footstep", 22, "right")])
    checks = clips.clip_checks(rig)
    assert all(c["pass"] for c in checks), [c for c in checks if not c["pass"]]
    data = clips.export_clips(rig, [body], out / "clips", "clip_rig", "custom")
    assert not formats.validate_clips(data), formats.validate_clips(data)
    problems = clips.glb_problems(out / "clips" / data["files"]["glb"], data)
    assert not problems, problems
    assert len(clips.glb_animations(out / "clips" / data["files"]["glb"])) == 2
    for clip in data["clips"]:
        problems += clips.fbx_problems(out / "clips" / data["files"]["fbx"][clip["name"]], clip, data["fps"])
    assert not problems, problems
    return f"GLB {[a[0] for a in clips.glb_animations(out / 'clips' / data['files']['glb'])]}, FBX ranges kept"


def case_clip_qa_failures(out):
    env.reset()
    body, rig = _clip_rig()
    clips.add_clip(rig, "open_loop", {"Top": [(0, (0, 0, 0)), (20, (30, 0, 0))]}, loop=True)
    clips.add_clip(rig, "open_loop", {"Top": [(0, (0, 0, 0)), (10, (0, 0, 0))]}, loop=False)
    clips.add_clip(rig, "late_marker", {"Top": [(0, (0, 0, 0)), (10, (0, 0, 0))]}, loop=False, markers=[("hit", 40)])
    clips.add_clip(rig, "short", {"Top": [(0, (0, 0, 0)), (10, (0, 0, 0))]}, end=5, loop=False)
    summary = qa.run(export_probe=False)["summary"]
    for name in ("clip_names_unique", "marker_in_range", "clip_range"):
        assert f"RIG_Clip:{name}" in summary["errors"], (name, summary["errors"])
    assert "RIG_Clip:clip_loop_closed" in summary["warnings"], summary["warnings"]
    bad = {"schema": "clips/1", "asset": "x", "rig": "custom", "fps": 30, "files": {"glb": "x_clips.glb", "fbx": {}},
           "clips": [{"name": "a", "slot": "dance", "start": 5, "end": 2, "loop": True, "root_motion": False, "markers": [{"name": "m", "frame": 9}]}]}
    found = formats.validate_clips(bad)
    assert len(found) >= 3, found
    return f"duplicate name, marker out of range, keys past end, open loop; sidecar validator: {len(found)} problems"


def _r15_scene(profile="r15_pose", mutate=None):
    env.reset()
    layout = r15.POSE_LAYOUT if profile == "r15_pose" else r15.avatar_layout()
    bones = [list(b) for b in layout]
    if mutate:
        mutate(bones)
    coll = env.collection("R15/Export", env.collection("R15"))
    rig = ops.armature("RIG_R15", [tuple(b) for b in bones], coll=coll)
    env.set_meta(rig, rig_profile=profile)
    return rig


def _errors(checks):
    return sorted(c["name"] for c in checks if not c["pass"] and c["level"] == "error")


def case_r15_profile(out):
    rig = _r15_scene()
    assert not _errors(r15.check(rig, "r15_pose")), _errors(r15.check(rig, "r15_pose"))
    def rename(bones):
        for b in bones:
            b[0] = "LeftArmUpper" if b[0] == "LeftUpperArm" else b[0]
            b[3] = "LeftArmUpper" if b[3] == "LeftUpperArm" else b[3]
    rig = _r15_scene(mutate=rename)
    assert "rig_profile" in _errors(r15.check(rig, "r15_pose"))
    rig = _r15_scene(mutate=lambda b: b[5].__setitem__(3, "UpperTorso"))  # LeftLowerArm under the torso
    assert "rig_profile_hierarchy" in _errors(r15.check(rig, "r15_pose"))

    def mirror(bones):
        for b in bones:
            b[1] = (-b[1][0], b[1][1], b[1][2])
            b[2] = (-b[2][0], b[2][1], b[2][2])
    rig = _r15_scene(mutate=mirror)
    assert "rig_profile_sides" in _errors(r15.check(rig, "r15_pose"))
    rig = _r15_scene("r15_avatar")
    assert not _errors(r15.check(rig, "r15_avatar")), _errors(r15.check(rig, "r15_avatar"))
    assert "rig_profile" in _errors(r15.check(rig, "r15_pose"))  # avatar tree is not the pose tree
    body = ops.box("SK_Avatar", size=(2, 1, 5), coll=bpy.data.collections["R15/Export"])
    ops.assign(body, ops.pbr_material("MAT_Grey", (0.5, 0.5, 0.5, 1)))
    ops.box_uv(body)
    ops.bind_rigid(body, rig, [(lambda w: w.z < 0.3, "Root"), (lambda w: True, "LowerTorso")])
    summary = qa.run(export_probe=False)["summary"]
    assert "SK_Avatar:rig_root_weights" in summary["errors"], summary
    env.reset()
    body, rig = templates.humanoid()
    summary = qa.run(export_probe=False)["summary"]
    assert not [e for e in summary["errors"] if "rig_profile" in e], summary
    return "pose and avatar pass; renamed, reparented, mirrored and Root-weighted fail"


# ---------- collision ----------

def case_collision_proxy(out):
    env.reset()
    coll = env.collection("Rock/Export", env.collection("Rock"))
    rock = ops.icosphere("SM_Rock", radius=2, subdivisions=4, coll=coll)
    ops.noise_displace(rock, strength=0.5, scale=0.6, seed=3)
    ops.assign(rock, ops.pbr_material("MAT_Grey", (0.5, 0.5, 0.5, 1)))
    ops.box_uv(rock)
    hull = ops.collision_proxy(rock, "hull", max_tris=20000)
    # 1e-3 studs: dissolving coplanar hull triangles (0.1 degrees) leaves quads a hair off plane.
    assert env.get_meta(hull)["collision"]["method"] == "hull" and ops.proxy_contains(hull, rock) <= 1e-3, ops.proxy_contains(hull, rock)
    hull_tris = ops.triangles(hull)
    kdop = ops.collision_proxy(rock, "hull", max_tris=150)  # the hull has far more: a 26-DOP replaces it
    method = env.get_meta(kdop)["collision"]["method"]
    assert method == "kdop26" and ops.triangles(kdop) <= 150 and ops.proxy_contains(kdop, rock) <= 1e-3, (method, ops.triangles(kdop))
    box = ops.collision_proxy(rock, "box")
    assert ops.triangles(box) == 12 and ops.proxy_contains(box, rock) <= 1e-3
    for obj in (hull, box):
        bpy.data.objects.remove(obj)
    summary = qa.run(export_probe=False)["summary"]
    assert summary["pass"], summary
    return f"rock {ops.triangles(rock)} tris: hull {hull_tris}, kdop26 {ops.triangles(kdop)}, box 12; all contain it"


# ---------- templates, kit, compare, intake ----------

def case_gameplay_templates(out):
    import gltf_validate

    done = []
    for kind in templates.GAMEPLAY:
        report = build.build_template(kind, out / "templates", previews=False)
        assert report["summary"]["pass"], (kind, report["summary"]["errors"])
        assert not report["summary"]["warnings"], (kind, report["summary"]["warnings"])
        glb = out / "templates" / kind / f"{kind}.glb"
        result = gltf_validate.validate_file(glb)
        assert result["pass"] and not result["warnings"], (kind, result["errors"], result["warnings"])
        if kind in templates.CLIP_RIGS:
            assert report["clips"]["clips"] == ["idle", "walk"] and not report["clips"]["problems"], report["clips"]
        done.append(kind)
    # The shipped clip files pass file QA on their own (fresh data: actions without rbx_clip).
    for kind in templates.CLIP_RIGS:
        folder = out / "templates" / kind
        sidecar = json.loads((folder / f"{kind}_clips.json").read_text())
        for file in [sidecar["files"]["glb"], *sidecar["files"]["fbx"].values()]:
            summary = qa.check_file(folder / file)["summary"]
            assert summary["pass"], (file, summary["errors"])
    exp = json.loads((out / "templates" / "checkpoint_gate" / "checkpoint_gate_expectation.json").read_text())
    files = [out / "templates" / "checkpoint_gate" / f"checkpoint_gate.{f}" for f in ("fbx", "glb")]
    good = compare.compare_files(files, exp)
    assert good["pass"], [c for f in good["files"] for c in f["checks"] if not c["pass"]]
    wrong = dict(exp, size=[v * 3.571 for v in exp["size"]])
    bad = compare.compare_files(files[:1], wrong)
    detail = next(c for c in bad["files"][0]["checks"] if c["name"] == "scale")
    assert not bad["pass"] and detail.get("detail") == "metre/stud mismatch", detail
    return f"{len(done)} templates pass QA, glTF validation and compare-export; clip GLB/FBX pass file QA"


def case_kit(out):
    result = kit.build_kit(["pickup", "obby_platform_set"], out / "kit" / "kit.json", library=str(FIXTURE_LIBRARY))
    assert not result["problems"], result["problems"]
    data = json.loads((out / "kit" / "kit.json").read_text())
    assert not formats.validate_kit(data), formats.validate_kit(data)
    keys = [p["key"] for p in data["pieces"]]
    assert "pickup" in keys and len(keys) == 7, keys
    for piece in data["pieces"]:
        assert (out / "kit" / piece["file"]).is_file(), piece["file"]
        assert abs(piece["bounds"]["min"][1]) <= 0.01, piece
    pickup = next(p for p in data["pieces"] if p["key"] == "pickup")
    assert pickup["collision"] == "none" and pickup["sockets"][0]["name"] == "center", pickup
    return f"{len(keys)} pieces: {', '.join(keys)}"


def case_intake_offline(out):
    """GLB fixture (off origin, rotated and scaled parent, no UVs, two baseColorFactor
    materials) -> structure check -> raw QA (fails) -> normalise -> palette bake -> gated export
    -> kit/1 entry; the atlas carries both fixture colours."""
    fixture = glbfix.intake_fixture(out / "intake" / "fixture.glb")
    result = intake.run(fixture["file"], out / "intake", "intake_crate", height=4.0, source="cc0:fixture:crate_01", previews=False)
    assert result["pass"], result["problems"]
    report = json.loads(Path(result["report"]).read_text())
    assert not report["steps"]["raw_qa"]["pass"], "the raw download should fail QA (pivot, transforms)"
    piece = result["kit"]["pieces"][0]
    assert abs(piece["bounds"]["max"][1] - 4.0) <= 0.01 and abs(piece["bounds"]["min"][1]) <= 0.01, piece["bounds"]
    assert piece["materials"] == ["atlas:intake_crate_Color.png"] and piece["provenance"] == "fixture", piece
    image = png.read(out / "intake" / "intake_crate" / "intake_crate_Color.png")
    colours = {tuple(row[i:i + 3]) for row in image["rows"] for i in range(0, len(row), 3)}
    for want in (fixture["body_srgb"], fixture["cap_srgb"]):
        assert any(_close(c, want, 1) for c in colours), (want, colours)
    refused = intake.run(fixture["file"], out / "intake", "intake_no_source", height=4.0, previews=False)
    assert not refused["pass"] and "source" in refused["problems"][0], refused["problems"]
    return f"scale x{report['steps']['normalise']['scale']}, {piece['triangles']} tris, bounds {piece['bounds']}"


CASES = [
    ("palette_atlas", case_palette_atlas),
    ("vertex_colors", case_vertex_colors),
    ("bake_maps_flat", case_bake_maps_flat),
    ("bake_maps_high_to_low", case_bake_maps_high_to_low),
    ("principled_renamed", case_principled_renamed),
    ("appearance_declared", case_appearance_declared),
    ("texture_rules", case_texture_rules),
    ("library_names", case_library_names),
    ("bake_command_tile", case_bake_command_tile),
    ("bake_command_maps", case_bake_command_maps),
    ("icon_deterministic", case_icon_deterministic),
    ("clips_export", case_clips_export),
    ("clip_qa_failures", case_clip_qa_failures),
    ("r15_profile", case_r15_profile),
    ("collision_proxy", case_collision_proxy),
    ("gameplay_templates", case_gameplay_templates),
    ("kit", case_kit),
    ("intake_offline", case_intake_offline),
]


def run(out_dir):
    """Run every case; returns [{case, pass, detail}]."""
    out = Path(out_dir).resolve()
    results = []
    for name, fn in CASES:
        work = out / name
        work.mkdir(parents=True, exist_ok=True)
        try:
            detail, ok = fn(work), True
        except Exception as exc:  # noqa: BLE001 - every failure is a failed case, the rest still run
            detail, ok = f"{type(exc).__name__}: {exc}"[:1500], False
        results.append({"case": name, "expected": "pipeline behaviour", "pass": ok, "detail": detail})
        print(f"qa-selftest {name:22s} {'OK  ' if ok else 'FAIL'} {detail}")
    return results
