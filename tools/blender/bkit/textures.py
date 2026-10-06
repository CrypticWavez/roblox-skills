"""Texture maps for Roblox: roles, colour spaces, file names, size limits, Principled wiring and
the material-library/1 format (docs/runtime-kits.md section 9.6).

Roblox rules (research blender-animation-pipeline section 2, visual-audio-assets 3e):
- SurfaceAppearance/MaterialVariant maps: ColorMap (sRGB, 24-bit RGB), NormalMap (tangent
  space, OpenGL, Non-Color), RoughnessMap and MetalnessMap (8-bit greyscale, Non-Color) and
  EmissiveMaskContent (8-bit greyscale; material-library/1 tags it sRGB like the colour map).
- One UV set in 0..1. PBR maps at most 1024 px (the SurfaceAppearance budget table's
  "(maximum)"); 2048 only with a written justification (avatar bodies and accessories);
  4096 is the basic-texture ceiling and never a default.
- Studio's Reimport finds maps in the same folder by file-name suffix, so maps are named
  `<Asset>_Color.png`, `_Normal.png`, `_Roughness.png`, `_Metalness.png`, `_Emissive.png`.
Colour spaces are Blender's names: "sRGB" and "Non-Color"."""
import json
import re
from pathlib import Path

ROLES = ("color", "normal", "roughness", "metalness", "emissive")
COLORSPACE = {"color": "sRGB", "emissive": "sRGB", "normal": "Non-Color", "roughness": "Non-Color", "metalness": "Non-Color"}
SUFFIX = {"color": "Color", "normal": "Normal", "roughness": "Roughness", "metalness": "Metalness", "emissive": "Emissive"}
MODE = {"color": "RGB", "normal": "RGB", "roughness": "L", "metalness": "L", "emissive": "L"}  # PNG channels written
# Suffixes Studio's Reimport recognises per map (create.roblox.com art/modeling/reimport, 2026-10-06).
RECOGNISED = {
    "color": ("color", "col", "diffuse", "diff", "albedo", "alb", "base", "basecolor"),
    "metalness": ("metal", "metallic", "metalness", "mtl", "met"),
    "roughness": ("rough", "roughness", "rgh"),
    "normal": ("normal", "nor", "nrm", "nrml", "norm", "normalgl"),
    "emissive": ("emissive", "emission", "emiss", "emit", "glow"),
}
DIRECTX_NORMAL = re.compile(r"(normal_?dx|nor_?dx|_dx$)", re.IGNORECASE)
PBR_MAX = 1024
JUSTIFIED_MAX = 2048
BASIC_MAX = 4096
# Principled BSDF input -> map role (inputs looked up by identifier-stable English names).
SOCKET_ROLES = {"Base Color": "color", "Normal": "normal", "Roughness": "roughness", "Metallic": "metalness", "Emission Color": "emissive", "Emission Strength": "emissive"}
MATERIALS = (  # Enum.Material names a MaterialVariant can use as base_material
    "Plastic", "SmoothPlastic", "Neon", "Wood", "WoodPlanks", "Marble", "Slate", "Concrete", "Granite", "Brick", "Pebble",
    "Cobblestone", "Rock", "Sandstone", "Basalt", "CrackedLava", "Limestone", "Pavement", "CorrodedMetal", "DiamondPlate",
    "Foil", "Metal", "Grass", "LeafyGrass", "Sand", "Fabric", "Snow", "Mud", "Ground", "Asphalt", "Salt", "Ice", "Glacier",
    "Glass", "Cardboard", "Carpet", "CeramicTiles", "ClayRoofTiles", "RoofShingles", "Leather", "Plaster", "Rubber",
)
LABEL = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


def map_name(asset, role, ext="png"):
    return f"{asset}_{SUFFIX[role]}.{ext}"


def suffix_ok(filename, role):
    """True when the file name ends in a suffix Studio's Reimport recognises for `role`."""
    stem = Path(filename).stem.lower()
    token = re.split(r"[_\-. ]", stem)[-1]
    return token in RECOGNISED[role] or any(stem.endswith(s) for s in RECOGNISED[role] if len(s) > 3)


def is_pow2(n):
    return n > 0 and n & (n - 1) == 0


# ---------- Blender side (bpy imported lazily so the format helpers stay pure Python) ----------

def _upstream_images(socket, seen=None):
    """Image Texture nodes feeding `socket`, through any chain of nodes."""
    seen = seen if seen is not None else set()
    found = []
    for link in socket.links:
        node = link.from_node
        if node in seen:
            continue
        seen.add(node)
        if node.type == "TEX_IMAGE":
            found.append(node)
        for inp in node.inputs:
            found += _upstream_images(inp, seen)
    return found


def image_roles(mat):
    """{image: set of roles} for the images wired into mat's Principled BSDF."""
    from . import ops

    out = {}
    if mat is None or mat.node_tree is None:
        return out
    bsdf = ops.principled(mat, create=False)
    if bsdf is None:
        return out
    for socket_name, role in SOCKET_ROLES.items():
        socket = bsdf.inputs.get(socket_name)
        if socket is None:
            continue
        for node in _upstream_images(socket):
            if node.image is not None:
                out.setdefault(node.image, set()).add(role)
    for roles in out.values():
        if "color" in roles:
            roles.discard("emissive")  # a colour map that also tints emission stays the colour map
    return out


def image_size(image):
    return tuple(image.size) if image is not None else (0, 0)


def load_map(path, role, name=None):
    """Load a map into Blender with its role's colour space (sRGB or Non-Color)."""
    import bpy

    image = bpy.data.images.load(str(path), check_existing=False)
    image.name = name or Path(path).name
    image.colorspace_settings.name = COLORSPACE[role]
    return image


def material_from_maps(name, images, constants=None):
    """A material whose Principled BSDF reads `images` ({role: bpy image}, colour spaces as
    loaded by `load_map`). constants: {base_color, roughness, metallic, emission_strength} for
    the inputs no map drives. The emissive map is a greyscale mask (Roblox EmissiveMaskContent)
    wired to Emission Color, so Blender shows it white; Studio's tint and strength are set on the
    SurfaceAppearance (how Import 3D maps it is UNVERIFIED)."""
    import bpy

    from . import ops

    constants = constants or {}
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    tree = ops.node_tree(mat)
    for node in [n for n in tree.nodes if n.type not in ("OUTPUT_MATERIAL",)]:
        tree.nodes.remove(node)
    bsdf = ops.principled(mat)
    bsdf.location = (300, 0)
    links = tree.links
    if "base_color" in constants:
        bsdf.inputs["Base Color"].default_value = constants["base_color"]
    bsdf.inputs["Roughness"].default_value = constants.get("roughness", 0.5)
    bsdf.inputs["Metallic"].default_value = constants.get("metallic", 0.0)
    nodes = {}
    for index, role in enumerate(r for r in ROLES if r in images):
        node = tree.nodes.new("ShaderNodeTexImage")
        node.image = images[role]
        node.label = role
        node.location = (-400, 300 - index * 280)
        node.interpolation = "Closest" if constants.get("closest") else "Linear"
        nodes[role] = node
    if "color" in nodes:
        links.new(nodes["color"].outputs["Color"], bsdf.inputs["Base Color"])
    if "roughness" in nodes:
        links.new(nodes["roughness"].outputs["Color"], bsdf.inputs["Roughness"])
    if "metalness" in nodes:
        links.new(nodes["metalness"].outputs["Color"], bsdf.inputs["Metallic"])
    if "normal" in nodes:
        normal_map = tree.nodes.new("ShaderNodeNormalMap")
        normal_map.space = "TANGENT"
        normal_map.location = (0, -500)
        links.new(nodes["normal"].outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    if "emissive" in nodes:
        # Wired straight in, so both exporters write it (glTF emissiveTexture, FBX EmissiveColor);
        # a multiply with the colour map would be dropped. Roblox tints the mask with EmissiveTint.
        links.new(nodes["emissive"].outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = constants.get("emission_strength", 1.0)
    mat.diffuse_color = tuple(constants.get("base_color", (0.8, 0.8, 0.8, 1)))
    return mat


def image_checks(image, roles, max_size=PBR_MAX):
    """QA checks of one image used for `roles`: size limit, power of two, colour space, suffix.
    Returns check dicts (name, pass, level, value, limit, detail) as qa._check builds them."""
    width, height = image_size(image)
    name = image.name
    file = Path(image.filepath_raw or image.filepath or name).name or name
    roles = sorted(roles)
    checks = []
    biggest = max(width, height)
    checks.append({"name": "texture_size", "pass": biggest <= max_size, "level": "error", "value": [width, height], "limit": max_size,
                   "detail": f"{name}: SurfaceAppearance maps at most {PBR_MAX} px; {JUSTIFIED_MAX} only with rbx_texture_max and a reason"})
    checks.append({"name": "texture_pow2", "pass": width == height and is_pow2(width), "level": "warning", "value": [width, height], "limit": "square power of two", "detail": name})
    wanted = {COLORSPACE[r] for r in roles}
    actual = image.colorspace_settings.name
    ok = len(wanted) == 1 and actual in wanted
    checks.append({"name": "texture_colorspace", "pass": ok, "level": "error", "value": actual, "limit": sorted(wanted),
                   "detail": f"{name} feeds {', '.join(roles)}" + ("" if len(wanted) == 1 else ": one image cannot be both colour and data")})
    suffix = all(suffix_ok(file, r) for r in roles)
    checks.append({"name": "texture_suffix", "pass": suffix, "level": "warning", "value": file, "limit": [f"*_{SUFFIX[r]}" for r in roles],
                   "detail": "Studio's Reimport finds maps by suffix"})
    return checks


# ---------- material-library/1 (pure Python) ----------

def validate_library(data):
    """Problems (strings) in a material-library/1 table; empty when valid (section 9.6)."""
    problems = []
    if not isinstance(data, dict) or data.get("schema") != "material-library/1":
        return ["schema must be 'material-library/1'"]
    materials = data.get("materials")
    if not isinstance(materials, list):
        return ["materials must be a list"]
    seen = set()
    for index, m in enumerate(materials):
        where = f"materials[{index}]"
        if not isinstance(m, dict):
            problems.append(f"{where}: not an object")
            continue
        name = m.get("name")
        if not isinstance(name, str) or not LABEL.match(name):
            problems.append(f"{where}: name must be a label (lower_snake, at most 64)")
        elif name in seen:
            problems.append(f"{where}: duplicate name {name}")
        else:
            seen.add(name)
            where = f"{name}"
        if m.get("base_material") not in MATERIALS:
            problems.append(f"{where}: base_material {m.get('base_material')!r} is not an Enum.Material name a variant can use")
        spt = m.get("studs_per_tile")
        if not isinstance(spt, (int, float)) or isinstance(spt, bool) or not spt > 0:
            problems.append(f"{where}: studs_per_tile must be a number > 0")
        if m.get("pattern") not in ("Regular", "Organic"):
            problems.append(f"{where}: pattern must be Regular or Organic")
        maps = m.get("maps")
        if not isinstance(maps, dict) or set(maps) != set(ROLES):
            problems.append(f"{where}: maps must have exactly {', '.join(ROLES)} (null when absent)")
            maps = maps if isinstance(maps, dict) else {}
        for role, ref in maps.items():
            if ref is None:
                continue
            if not isinstance(ref, str) or not (ref.startswith("build:") or "#" in ref):
                problems.append(f"{where}: maps.{role} must be '<source key>#<file or channel>', 'build:<path>' or null")
            elif role == "normal" and DIRECTX_NORMAL.search(ref.split("#")[-1].rsplit(".", 1)[0]):
                problems.append(f"{where}: maps.normal {ref} names a DirectX normal map; Roblox needs OpenGL (NormalGL / nor_gl)")
        if maps and maps.get("color") is None:
            problems.append(f"{where}: maps.color is required")
        resolution = m.get("resolution")
        if not isinstance(resolution, int) or isinstance(resolution, bool) or not is_pow2(resolution):
            problems.append(f"{where}: resolution must be a power of two")
        elif resolution > JUSTIFIED_MAX:
            problems.append(f"{where}: resolution {resolution} over {JUSTIFIED_MAX}")
        elif resolution > PBR_MAX and not (isinstance(m.get("justify"), str) and m["justify"].strip()):
            problems.append(f"{where}: resolution {resolution} needs a justify reason (default limit {PBR_MAX})")
        if not isinstance(m.get("override_base"), bool):
            problems.append(f"{where}: override_base must be a boolean")
        if not isinstance(m.get("provenance"), str) or not m["provenance"]:
            problems.append(f"{where}: provenance must be an asset-sources/1 key or 'local'")
        roblox = m.get("roblox")
        if not isinstance(roblox, dict) or any(k not in roblox for k in ("color", "normal", "roughness", "metalness")):
            problems.append(f"{where}: roblox must hold color, normal, roughness and metalness ids (0 until uploaded)")
        else:
            for k, v in roblox.items():
                if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                    problems.append(f"{where}: roblox.{k} must be an integer >= 0")
    return problems


def library_names(data):
    return {m["name"] for m in data.get("materials", []) if isinstance(m, dict) and isinstance(m.get("name"), str)}


def library_entry(name, maps, resolution, base_material="SmoothPlastic", studs_per_tile=4, pattern="Regular", provenance="local", justify=None):
    """A material-library/1 entry for factory output. maps: {role: path relative to the repo
    root} for the maps that exist (written as `build:<path>`); the rest are null."""
    entry = {
        "name": name,
        "base_material": base_material,
        "studs_per_tile": studs_per_tile,
        "pattern": pattern,
        "maps": {role: (f"build:{maps[role]}" if role in maps else None) for role in ROLES},
        "resolution": resolution,
        "override_base": False,
        "provenance": provenance,
        "roblox": {"color": 0, "normal": 0, "roughness": 0, "metalness": 0},
    }
    if justify:
        entry["justify"] = justify
    return entry


def dumps(data):
    """Canonical JSON (sorted keys, two-space indent, LF) so equal libraries are equal bytes."""
    return json.dumps(data, indent=2, sort_keys=True) + "\n"


def write_library(entries, path):
    data = {"schema": "material-library/1", "materials": sorted(entries, key=lambda e: e["name"])}
    problems = validate_library(data)
    if problems:
        raise ValueError("material-library/1: " + "; ".join(problems))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(dumps(data))
    return data


def resolve_ref(ref, root, cache=None):
    """Local file for a map reference, or None when it is not on disk: `build:<path>` is relative
    to the repo root; `<source>#<file>` looks in `<cache>/<source>/<file>` (build/asset-cache)."""
    if ref is None:
        return None
    root = Path(root)
    if ref.startswith("build:"):
        path = root / ref[len("build:"):]
        return path if path.is_file() else None
    source, _, file = ref.partition("#")
    cache = Path(cache) if cache else root / "build" / "asset-cache"
    for candidate in (cache / source / file, *(cache / source).glob(file + ".*")):
        if Path(candidate).is_file():
            return Path(candidate)
    return None


def check_map_file(path, role, resolution):
    """Problems with one map file on disk: format, square power of two, at most `resolution`,
    single channel for data maps (8-bit greyscale), three or four for colour and normal."""
    from . import png

    problems = []
    try:
        info = png.image_info(path)
    except (OSError, ValueError) as exc:
        return [f"{Path(path).name}: {exc}"], None
    w, h = info["width"], info["height"]
    if w != h or not is_pow2(w):
        problems.append(f"{Path(path).name}: {w}x{h} is not a square power of two")
    if max(w, h) > resolution:
        problems.append(f"{Path(path).name}: {w}x{h} over the declared resolution {resolution}")
    if MODE[role] == "L" and info["channels"] not in (1, 2):
        grey = None
        if info["format"] == "png" and info.get("bit_depth") == 8:
            decoded = png.read(path)
            c = decoded["channels"]
            grey = all(row[i] == row[i + 1] == row[i + 2] for row in decoded["rows"] for i in range(0, len(row), c))
        problems.append(f"{Path(path).name}: {role} must be 8-bit single-channel greyscale" + (" (RGB with equal channels: convert)" if grey else ""))
    if MODE[role] == "RGB" and info["channels"] not in (3, 4):
        problems.append(f"{Path(path).name}: {role} must be RGB")
    if role == "normal" and DIRECTX_NORMAL.search(Path(path).stem):
        problems.append(f"{Path(path).name}: DirectX normal map; Roblox needs OpenGL")
    return problems, info


def check_library_files(data, root, cache=None):
    """Per material and map: the resolved file and its problems; unresolved maps are listed as
    not checked (never passed)."""
    results = []
    for m in data.get("materials", []):
        for role in ROLES:
            ref = (m.get("maps") or {}).get(role)
            if ref is None:
                continue
            path = resolve_ref(ref, root, cache)
            if path is None:
                results.append({"material": m.get("name"), "role": role, "ref": ref, "checked": False, "problems": [], "detail": "not on disk (fetch it into build/asset-cache or bake it)"})
                continue
            problems, info = check_map_file(path, role, m.get("resolution", PBR_MAX))
            results.append({"material": m.get("name"), "role": role, "ref": ref, "file": str(path), "checked": True, "problems": problems, "info": info, "colorspace": COLORSPACE[role]})
    return results
