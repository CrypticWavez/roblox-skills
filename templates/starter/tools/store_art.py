"""Store art: compose, lint and preview icons, thumbnails, pass, product and badge icons and ad creatives.

  python3 tools/store_art.py specs                                   the size and format rules per kind
  python3 tools/store_art.py lint FILE... [--kind K] [--mood dark] [--json]
  python3 tools/store_art.py compose --template T --out FILE [--subject PNG] [--background IMG]
                                     [--title TEXT] [--ribbon TEXT] [--palette P] [--font TTF] [--seed N]
  python3 tools/store_art.py preview FILE... --out sheet.png        how each file reads at its shown size
  python3 tools/store_art.py briefs [--root DIR] [--force]          store/art/briefs.json from the brief and plan
  python3 tools/store_art.py fonts [--fetch]                         the pinned SIL OFL title fonts

Kinds: icon (512x512), thumbnail (16:9, 1920x1080, < 3 MB), pass and product (<= 512, circle crop),
badge (512, circle crop), ad (an Ads Manager sponsored-game creative: a 16:9 thumbnail). lint checks the
hard rules (size, aspect, format by magic bytes, file size: errors) from tools/storekit/art.json and,
with Pillow, readability heuristics (saturation, contrast and clutter at the shown size, content outside
the circle crop: warnings). compose builds an asset from a subject render with transparency (a Blender
render, a Studio capture with the background removed, or a codex-image output), a background or a
gradient, sun rays, an outlined title and a ribbon, then grades it; text never goes in a thumbnail's
bottom 20% (Roblox overlays it). preview writes a contact sheet at the real display sizes (icon 150 and
64 px, thumbnails 480x270 with the overlay band) so variants can be compared before the owner uploads
them. briefs writes one task per asset (icon, five distinct thumbnail concepts for personalization, one
icon per pass and product, the ad creative) with a codex-image prompt, a Blender shot and the overlay
text. Compose, lint and preview need Pillow (python3 -m pip install pillow); specs, briefs and the
size checks do not. Nothing here uploads: the owner uploads art in Creator Hub (release items O07-O10).
"""
import argparse
import hashlib
import json
import math
import random
import re
import struct
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ART = json.loads((HERE / "storekit" / "art.json").read_text(encoding="utf-8"))
SPECS = ART["specs"]
KINDS = tuple(SPECS)
FONT_DIRS = ["assets/fonts", "tools/storekit/fonts"]
SYSTEM_FONTS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


class Refused(Exception):
    pass


def pil():
    try:
        from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps  # noqa: F401
    except ImportError as err:
        raise Refused("this command needs Pillow: python3 -m pip install pillow") from err
    import PIL
    return PIL


# ------------------------------------------------------------------ headers (no Pillow)

def sniff(path):
    """(format, width, height) from the file's magic bytes, or (None, None, None)."""
    data = Path(path).read_bytes()[:64 * 1024]
    if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return "png", w, h
    if data[:3] == b"GIF" and len(data) >= 10:
        w, h = struct.unpack("<HH", data[6:10])
        return "gif", w, h
    if data[:2] == b"BM" and len(data) >= 26:
        w, h = struct.unpack("<ii", data[18:26])
        return "bmp", w, abs(h)
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return "jpg", w, h
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            i += 2 + length
        return "jpg", None, None
    if Path(path).suffix.lower() == ".tga" and len(data) >= 18:
        w, h = struct.unpack("<HH", data[12:16])
        return "tga", w, h
    return None, None, None


def guess_kind(path):
    name = Path(path).name.lower()
    for kind in ("thumbnail", "icon", "pass", "product", "badge", "ad"):
        if kind in name:
            return kind
    return None


def hard_checks(path, kind):
    spec = SPECS[kind]
    errors = []
    fmt, w, h = sniff(path)
    size = Path(path).stat().st_size
    if fmt is None:
        return [f"not an image Roblox accepts ({', '.join(spec['formats'])})"], fmt, w, h
    if fmt not in spec["formats"]:
        errors.append(f"{fmt} is not accepted for {kind} ({', '.join(spec['formats'])})")
    ext = Path(path).suffix.lower().lstrip(".").replace("jpeg", "jpg")
    if ext and ext != fmt:
        errors.append(f"extension .{ext} but the file is {fmt}")
    if w is None:
        errors.append("size unreadable")
    elif "aspect" in spec:
        aw, ah = spec["aspect"]
        if abs(w / h - aw / ah) > 0.005 * (aw / ah):
            errors.append(f"{w}x{h} is not {aw}:{ah}")
        if w < spec.get("min_width", 0):
            errors.append(f"{w}x{h} is below {spec['min_width']} px wide; use {spec['width']}x{spec['height']}")
    else:
        if w != h:
            errors.append(f"{w}x{h} is not square")
        if spec.get("exact") and (w, h) != (spec["width"], spec["height"]):
            errors.append(f"{w}x{h}: must be {spec['width']}x{spec['height']}")
        if spec.get("max_size") and max(w, h) > spec["width"]:
            errors.append(f"{w}x{h}: at most {spec['width']}x{spec['height']}")
    if spec.get("max_bytes") and size >= spec["max_bytes"]:
        errors.append(f"{size} bytes: must be under {spec['max_bytes']} (export as jpg quality 90)")
    return errors, fmt, w, h


# ------------------------------------------------------------------ heuristics (Pillow)

def heuristics(path, kind, mood=None):
    PIL = pil()
    from PIL import Image, ImageFilter, ImageStat
    rules = ART["heuristics"]
    warnings, metrics = [], {}
    spec = SPECS[kind]
    image = Image.open(path).convert("RGB")
    shown = spec.get("shown_at") or [150, 150]
    small = image.resize((shown[0], shown[1] if len(shown) > 1 and kind in ("thumbnail", "ad") else shown[0]), Image.LANCZOS)
    hsv = small.convert("HSV")
    sat = ImageStat.Stat(hsv.split()[1]).mean[0] / 255
    luma = small.convert("L")
    std = ImageStat.Stat(luma).stddev[0] / 255
    edges = luma.filter(ImageFilter.FIND_EDGES).crop((1, 1, small.width - 1, small.height - 1))
    edge_density = sum(edges.histogram()[65:]) / (edges.width * edges.height)
    metrics.update(saturation=round(sat, 3), luma_std=round(std, 3), edge_density=round(edge_density, 3))
    if mood != "dark" and sat < rules["min_saturation"]:
        warnings.append(f"dull at {shown[0]} px: mean saturation {sat:.2f} < {rules['min_saturation']} (top-chart art is bright; --mood dark for horror)")
    if std < rules["min_luma_std"]:
        warnings.append(f"flat at {shown[0]} px: luminance spread {std:.2f} < {rules['min_luma_std']} (add a rim light or a darker background behind the subject)")
    if edge_density > rules["max_edge_density"]:
        warnings.append(f"busy at {shown[0]} px: edge density {edge_density:.2f} > {rules['max_edge_density']} (one focal point, fewer small details)")
    if spec.get("crop") == "circle":
        w, h = image.size
        r = min(w, h) / 2
        cx, cy = w / 2, h / 2
        grey = image.convert("L").filter(ImageFilter.FIND_EDGES)
        inside = outside = 0
        px = grey.load()
        step = max(1, w // 128)
        # FIND_EDGES marks the outermost pixel rows; skip them.
        for y in range(2, h - 2, step):
            for x in range(2, w - 2, step):
                v = px[x, y] if px[x, y] > 40 else 0  # real edges, not gradient noise
                if (x - cx) ** 2 + (y - cy) ** 2 > (r * spec["circle_safe"]) ** 2:
                    outside += v
                else:
                    inside += v
        share = outside / max(1, inside + outside)
        metrics["outside_circle_energy"] = round(share, 3)
        if share > rules["max_outside_circle_energy"]:
            warnings.append(f"{share:.0%} of the detail sits outside the circle crop; Roblox shows {kind} icons as circles")
    return warnings, metrics


def cmd_lint(args):
    results, failed = [], False
    for file in args.files:
        kind = args.kind or guess_kind(file)
        if kind not in SPECS:
            raise Refused(f"{file}: name the kind with --kind ({', '.join(KINDS)})")
        errors, fmt, w, h = hard_checks(file, kind)
        warnings, metrics = [], {}
        if not errors:
            try:
                warnings, metrics = heuristics(file, kind, args.mood)
            except Refused as err:
                warnings.append(f"heuristics skipped: {err}")
        failed = failed or bool(errors)
        results.append({"file": str(file), "kind": kind, "format": fmt, "size": [w, h], "errors": errors, "warnings": warnings, "metrics": metrics})
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in results:
            status = "FAIL" if r["errors"] else ("WARN" if r["warnings"] else "ok")
            print(f"[{status:<4}] {r['file']} ({r['kind']} {r['size'][0]}x{r['size'][1]} {r['format']})")
            for e in r["errors"]:
                print("       error: " + e)
            for w in r["warnings"]:
                print("       warn:  " + w)
    return 1 if failed else 0


# ------------------------------------------------------------------ compose

def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def find_font(explicit, root):
    candidates = [explicit] if explicit else []
    for folder in FONT_DIRS:
        for font in ART["fonts"]:
            candidates.append(str(Path(root) / folder / font["file"]))
    candidates += SYSTEM_FONTS
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def gradient(size, top, bottom, radial=True):
    from PIL import Image
    w, h = size
    small = Image.new("RGB", (64, 64))
    px = small.load()
    a, b = hex_rgb(top), hex_rgb(bottom)
    for y in range(64):
        for x in range(64):
            t = min(1.0, math.hypot(x - 32, y - 26) / 40) if radial else y / 63
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return small.resize((w, h), Image.BICUBIC)


def rays(base, count, colour, rng):
    from PIL import Image, ImageDraw
    if count <= 0:
        return base
    w, h = base.size
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = w * rng.uniform(0.45, 0.55), h * 0.45
    radius = math.hypot(w, h)
    offset = rng.uniform(0, math.pi)
    for i in range(count):
        a0 = offset + i * 2 * math.pi / count
        a1 = a0 + math.pi / count * 0.55
        points = [(cx, cy), (cx + radius * math.cos(a0), cy + radius * math.sin(a0)), (cx + radius * math.cos(a1), cy + radius * math.sin(a1))]
        draw.polygon(points, fill=colour + (46,))
    out = base.convert("RGBA")
    out.alpha_composite(layer)
    return out


def cover(image, size):
    from PIL import ImageOps
    return ImageOps.fit(image.convert("RGBA"), size)


def outlined(subject, width, shadow, stroke_rgb):
    """The subject with a solid outline grown from its alpha and a soft drop shadow."""
    from PIL import Image, ImageFilter
    pad = width + shadow * 2 + 2
    w, h = subject.size
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    alpha = Image.new("L", canvas.size, 0)
    alpha.paste(subject.getchannel("A"), (pad, pad))
    if shadow > 0:
        sh = alpha.filter(ImageFilter.GaussianBlur(shadow))
        shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        shadow_layer.putalpha(sh.point(lambda v: int(v * 0.55)))
        moved = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        moved.alpha_composite(shadow_layer, (0, shadow))
        canvas.alpha_composite(moved)
    if width > 0:
        grown = alpha.filter(ImageFilter.MaxFilter(width * 2 + 1))
        ring = Image.new("RGBA", canvas.size, stroke_rgb + (255,))
        ring.putalpha(grown)
        canvas.alpha_composite(ring)
    canvas.alpha_composite(subject, (pad, pad))
    return canvas


def place(canvas, layer, box, anchor):
    W, H = canvas.size
    bx, by, bw, bh = box[0] * W, box[1] * H, box[2] * W, box[3] * H
    scale = min(bw / layer.width, bh / layer.height)
    from PIL import Image
    fitted = layer.resize((max(1, int(layer.width * scale)), max(1, int(layer.height * scale))), Image.LANCZOS)
    x = int(bx + (bw - fitted.width) / 2)
    y = int(by + bh - fitted.height) if anchor == "bottom" else int(by + (bh - fitted.height) / 2)
    canvas.alpha_composite(fitted, (x, y))


def text_layer(text, font_path, size_px, fill, stroke, stroke_px, max_w):
    from PIL import Image, ImageDraw, ImageFont
    lines = text.split("\\n") if "\\n" in text else [text]
    while size_px > 8:
        font = ImageFont.truetype(font_path, size_px) if font_path else ImageFont.load_default()
        probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
        boxes = [probe.textbbox((0, 0), line, font=font, stroke_width=stroke_px) for line in lines]
        width = max(b[2] - b[0] for b in boxes)
        if width <= max_w or not font_path:
            break
        size_px = int(size_px * 0.92)
        stroke_px = max(1, int(stroke_px * 0.92))
    line_h = max(b[3] - b[1] for b in boxes)
    layer = Image.new("RGBA", (width + stroke_px * 4, int(line_h * 1.1) * len(lines) + stroke_px * 4), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for i, line in enumerate(lines):
        b = boxes[i]
        x = (layer.width - (b[2] - b[0])) / 2 - b[0]
        y = stroke_px * 2 + i * int(line_h * 1.1) - b[1]
        draw.text((x + stroke_px * 0.6, y + stroke_px * 0.9), line, font=font, fill=(0, 0, 0, 120), stroke_width=stroke_px, stroke_fill=(0, 0, 0, 120))
        draw.text((x, y), line, font=font, fill=fill, stroke_width=stroke_px, stroke_fill=stroke)
    return layer


def grade(image, spec):
    from PIL import Image, ImageEnhance
    out = ImageEnhance.Color(image.convert("RGB")).enhance(spec.get("saturation", 1))
    out = ImageEnhance.Contrast(out).enhance(spec.get("contrast", 1))
    strength = spec.get("vignette", 0)
    if strength > 0:
        w, h = out.size
        mask = Image.new("L", (64, 64))
        px = mask.load()
        for y in range(64):
            for x in range(64):
                d = math.hypot((x - 31.5) / 32, (y - 31.5) / 32)
                px[x, y] = int(255 * min(1, max(0, (d - 0.55) / 0.6)) * strength)
        mask = mask.resize((w, h), Image.BICUBIC)
        out = Image.composite(Image.new("RGB", (w, h), (0, 0, 0)), out, mask)
    return out


def compose(template_name, out, subject=None, background=None, title=None, ribbon=None, palette="sunny", font=None, seed=1, root="."):
    pil()
    from PIL import Image
    if template_name not in ART["templates"]:
        raise Refused(f"unknown template {template_name}: {', '.join(ART['templates'])}")
    if palette not in ART["palettes"]:
        raise Refused(f"unknown palette {palette}: {', '.join(ART['palettes'])}")
    t = ART["templates"][template_name]
    spec = SPECS[t["kind"]]
    pal = ART["palettes"][palette]
    size = (spec["width"], spec["height"])
    rng = random.Random(seed)
    canvas = cover(Image.open(background), size) if background else gradient(size, pal["bg"][0], pal["bg"][1]).convert("RGBA")
    canvas = rays(canvas, t.get("rays", 0), (255, 255, 255), rng)
    font_path = find_font(font, root)
    notes = [] if font_path else ["no TTF found: run `python3 tools/store_art.py fonts --fetch` for the title fonts"]
    if subject:
        s = t["subject"]
        img = Image.open(subject).convert("RGBA")
        unit = max(img.size)
        layer = outlined(img, int(unit * s.get("outline", 0)), int(unit * s.get("shadow", 0)), hex_rgb(pal["stroke"]))
        place(canvas, layer, s["box"], s.get("anchor", "center"))
    if title and "title" in t:
        tt = t["title"]
        words = len(title.replace("\\n", " ").split())
        if words > spec.get("max_words", 6):
            notes.append(f"title has {words} words; {t['kind']} art reads best with at most {spec['max_words']}")
        text = "\\n".join(part.upper() if tt.get("upper") else part for part in title.split("\\n"))
        H = canvas.height
        layer = text_layer(text, font_path, int(H * tt["size"]), hex_rgb(pal["title"]), hex_rgb(pal["stroke"]), max(2, int(H * tt["stroke"])), int(canvas.width * tt["box"][2]))
        if tt.get("rotate"):
            layer = layer.rotate(tt["rotate"], resample=Image.BICUBIC, expand=True)
        place(canvas, layer, tt["box"], "center")
    if ribbon and "ribbon" in t:
        rt = t["ribbon"]
        from PIL import ImageDraw
        W, H = canvas.size
        bx, by, bw, bh = int(rt["box"][0] * W), int(rt["box"][1] * H), int(rt["box"][2] * W), int(rt["box"][3] * H)
        band = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
        ImageDraw.Draw(band).rounded_rectangle((0, 0, bw - 1, bh - 1), radius=bh // 3, fill=hex_rgb(pal["ribbon"]) + (255,), outline=hex_rgb(pal["stroke"]) + (255,), width=max(2, bh // 14))
        label = text_layer(ribbon.upper(), font_path, int(bh * 0.62), hex_rgb(pal["ribbon_text"]), hex_rgb(pal["stroke"]), max(1, bh // 20), int(bw * 0.9))
        band.alpha_composite(label.resize((min(label.width, int(bw * 0.9)), min(label.height, bh)), Image.LANCZOS), ((bw - min(label.width, int(bw * 0.9))) // 2, (bh - min(label.height, bh)) // 2))
        band = band.rotate(-3, resample=Image.BICUBIC, expand=True)
        canvas.alpha_composite(band, (bx, by))
    final = grade(canvas, t.get("grade", {}))
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    fmt = out.suffix.lower().lstrip(".")
    if fmt in ("jpg", "jpeg"):
        quality = 92
        while True:
            final.save(out, "JPEG", quality=quality, optimize=True)
            if not spec.get("max_bytes") or out.stat().st_size < spec["max_bytes"] or quality <= 60:
                break
            quality -= 6
    else:
        final.save(out, "PNG", optimize=True)
        if spec.get("max_bytes") and out.stat().st_size >= spec["max_bytes"]:
            notes.append(f"{out.name} is {out.stat().st_size} bytes; save as .jpg to get under {spec['max_bytes']}")
    return notes


def cmd_compose(args):
    notes = compose(args.template, args.out, args.subject, args.background, args.title, args.ribbon, args.palette, args.font, args.seed, args.root)
    print(f"store_art: wrote {args.out}")
    for n in notes:
        print("  note: " + n)
    kind = ART["templates"][args.template]["kind"]
    return cmd_lint(argparse.Namespace(files=[args.out], kind=kind, mood=None, json=False))


# ------------------------------------------------------------------ preview

def cmd_preview(args):
    pil()
    from PIL import Image, ImageDraw
    tiles = []
    for file in args.files:
        kind = args.kind or guess_kind(file) or "icon"
        img = Image.open(file).convert("RGB")
        if kind in ("thumbnail", "ad"):
            t = img.resize((480, 270), Image.LANCZOS).convert("RGBA")
            band = Image.new("RGBA", (480, 54), (0, 0, 0, 150))
            ImageDraw.Draw(band).text((10, 18), "12.3K playing   94%", fill=(255, 255, 255, 230))
            t.alpha_composite(band, (0, 216))
            tiles.append((file, [t.convert("RGB")]))
        else:
            round_ = SPECS.get(kind, {}).get("crop") == "circle"
            views = []
            for px in (150, 64):
                v = img.resize((px, px), Image.LANCZOS)
                mask = Image.new("L", (px, px), 0)
                d = ImageDraw.Draw(mask)
                if round_:
                    d.ellipse((0, 0, px - 1, px - 1), fill=255)
                else:
                    d.rounded_rectangle((0, 0, px - 1, px - 1), radius=px // 8, fill=255)
                bg = Image.new("RGB", (px, px), (35, 37, 41))
                bg.paste(v, (0, 0), mask)
                views.append(bg)
            tiles.append((file, views))
    width = 520
    height = sum(max(v.height for v in views) + 40 for _, views in tiles) + 20
    sheet = Image.new("RGB", (width, height), (25, 27, 31))
    draw = ImageDraw.Draw(sheet)
    y = 10
    for file, views in tiles:
        draw.text((10, y), Path(file).name, fill=(220, 220, 220))
        x = 10
        for v in views:
            sheet.paste(v, (x, y + 18))
            x += v.width + 16
        y += max(v.height for v in views) + 40
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print(f"store_art: wrote {out} ({len(tiles)} assets at their shown sizes)")
    return 0


# ------------------------------------------------------------------ briefs

def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def tbd(value):
    return value in (None, "", "TBD") or (isinstance(value, list) and not value)


def briefs(root):
    root = Path(root)
    brief = read_json(root / "production" / "brief.json") or {}
    plan = read_json(root / "monetization" / "plan.json") or {"products": []}
    name = brief.get("name") if not tbd(brief.get("name")) else "the game"
    style = brief.get("art_direction") if not tbd(brief.get("art_direction")) else "bright, saturated Roblox-style 3D, chunky shapes, soft studio lighting"
    world = brief.get("theme_and_setting") if not tbd(brief.get("theme_and_setting")) else "the game's main world"
    hero = brief.get("characters") if not tbd(brief.get("characters")) else "the game's mascot character"
    genre = (brief.get("genre") or {}).get("primary") if isinstance(brief.get("genre"), dict) else None
    palette = "horror" if genre == "Survival" and "horror" in str(brief).lower() else "sunny"
    shot = {"engine": "Cycles or EEVEE", "lens_mm": 50, "camera": "slightly low, three-quarter, subject fills 70-85%", "lights": "key 45 deg warm, strong cool rim from behind, soft fill; HDRI at 0.3", "outline": "inverted hull or compose --outline", "output": "PNG with transparent background (Film > Transparent), 2048 px", "view_transform": "AgX, look Punchy"}
    tasks = [{
        "id": "icon",
        "kind": "icon",
        "template": "icon_hero",
        "out": "store/art/out/icon.png",
        "subject_out": "store/art/renders/icon_subject.png",
        "concept": f"{hero}, face close up with a big expression, one focal point, from {world}",
        "overlay": None,
        "prompt": f"Roblox game icon subject for {name}: {hero}, extreme close-up of the face with a big excited expression, {style}, isolated on a transparent background, crisp silhouette, no text, no logos, no Roblox UI",
        "blender": shot,
        "palette": palette,
    }]
    for concept in ART["thumbnail_concepts"]:
        tasks.append({
            "id": f"thumbnail_{concept['id']}",
            "kind": "thumbnail",
            "template": concept["template"],
            "out": f"store/art/out/thumbnail_{concept['id']}.jpg",
            "subject_out": f"store/art/renders/thumbnail_{concept['id']}_subject.png",
            "concept": concept["concept"],
            "why": concept["why"],
            "overlay": "UPDATE NAME" if concept["id"] == "update" else (name if concept["id"] == "hero" else None),
            "prompt": f"Key art for the Roblox game {name}: {concept['concept']} Setting: {world}. Style: {style}. 16:9, leave the bottom fifth simple, no text, no logos, no Roblox UI, no real people or brands.",
            "blender": dict(shot, camera="wide 35 mm for action, 85 mm for faces; rule of thirds"),
            "palette": palette,
        })
    for product in plan.get("products", []):
        kind = "pass" if product["kind"] == "gamepass" else ("product" if product["kind"] == "devproduct" else None)
        if kind is None:
            continue
        overlay = None
        match = re.search(r"(\d+x)", product["name"])
        if match:
            overlay = match.group(1).upper()
        tasks.append({
            "id": f"{kind}_{product['key']}",
            "kind": kind,
            "template": f"{kind}_icon",
            "out": f"store/art/out/{kind}_{product['key']}.png",
            "subject_out": f"store/art/renders/{kind}_{product['key']}_subject.png",
            "concept": product["icon_brief"],
            "overlay": overlay,
            "prompt": f"Roblox {('game pass' if kind == 'pass' else 'shop item')} icon object for {name}: {product['icon_brief']}, {style}, centered, fills the middle two thirds, isolated on a transparent background, no text, no Robux symbol",
            "blender": dict(shot, camera="centered, 50 mm, object fills 66%"),
            "palette": "gold" if product["key"] in ("vip", "gift_vip", "vip_subscription") else palette,
        })
    tasks.append({
        "id": "ad_sponsored",
        "kind": "ad",
        "template": "thumbnail_hero",
        "out": "store/art/out/ad_sponsored.jpg",
        "subject_out": "store/art/renders/thumbnail_hero_subject.png",
        "concept": "The best-performing thumbnail concept (pick from personalization results), same art, no claims, no prices.",
        "overlay": name,
        "prompt": "Reuse thumbnail_hero; Ads Manager takes the same 16:9 1920x1080 creative.",
        "blender": shot,
        "palette": palette,
    })
    return {"schema": "store-art-briefs/1", "game": name, "note": "Generate subjects with /codex-image:generate (each costs one Codex turn from the owner's plan; confirm credit auto-reload is off before a large batch), render them in Blender, or capture them in Studio; then compose: python3 tools/store_art.py compose --template T --subject SUBJECT --title OVERLAY --out OUT; then lint and preview. Upload with python3 tools/store_publish.py once the owner has approved store setup.", "tasks": tasks}


def cmd_briefs(args):
    root = Path(args.root)
    out = root / "store" / "art" / "briefs.json"
    if out.exists() and not args.force:
        raise Refused(f"{out} exists; --force replaces it")
    data = briefs(root)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"store_art: wrote {out} ({len(data['tasks'])} tasks)")
    return 0


# ------------------------------------------------------------------ fonts and specs

def cmd_fonts(args):
    target = Path(args.root) / "assets" / "fonts"
    for font in ART["fonts"]:
        path = target / font["file"]
        status = "present" if path.exists() else "missing"
        if args.fetch and not path.exists():
            data = urllib.request.urlopen(font["url"], timeout=30).read()
            digest = hashlib.sha256(data).hexdigest()
            if digest != font["sha256"]:
                raise Refused(f"{font['file']}: sha256 {digest} does not match the pin {font['sha256']}")
            target.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            status = "fetched"
        print(f"{font['name']:<12} {font['license']:<8} {status:<8} {font['use']}")
    if args.fetch:
        (target / "README.md").write_text("Title fonts for store art (tools/store_art.py), SIL Open Font License 1.1, from github.com/google/fonts. The licence allows bundling and embedding in images; keep this note with the files.\n", encoding="utf-8")
    return 0


def cmd_specs(_args):
    for kind, spec in SPECS.items():
        size = f"{spec['width']}x{spec['height']}" + (" max" if spec.get("max_size") else "")
        extra = []
        if spec.get("max_bytes"):
            extra.append(f"< {spec['max_bytes']} bytes")
        if spec.get("crop"):
            extra.append(f"crop {spec['crop']}")
        if spec.get("bottom_no_text"):
            extra.append(f"no text in bottom {int(spec['bottom_no_text'] * 100)}%")
        print(f"{kind:<10} {size:<14} {'/'.join(spec['formats']):<22} {', '.join(extra)}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("specs")
    lint = sub.add_parser("lint")
    lint.add_argument("files", nargs="+")
    lint.add_argument("--kind", choices=KINDS)
    lint.add_argument("--mood", choices=["dark"])
    lint.add_argument("--json", action="store_true")
    comp = sub.add_parser("compose")
    comp.add_argument("--template", required=True)
    comp.add_argument("--out", required=True)
    comp.add_argument("--subject")
    comp.add_argument("--background")
    comp.add_argument("--title")
    comp.add_argument("--ribbon")
    comp.add_argument("--palette", default="sunny")
    comp.add_argument("--font")
    comp.add_argument("--seed", type=int, default=1)
    comp.add_argument("--root", default=".")
    prev = sub.add_parser("preview")
    prev.add_argument("files", nargs="+")
    prev.add_argument("--out", required=True)
    prev.add_argument("--kind", choices=KINDS)
    br = sub.add_parser("briefs")
    br.add_argument("--root", default=".")
    br.add_argument("--force", action="store_true")
    fonts = sub.add_parser("fonts")
    fonts.add_argument("--fetch", action="store_true")
    fonts.add_argument("--root", default=".")
    args = parser.parse_args(argv)
    handlers = {"specs": cmd_specs, "lint": cmd_lint, "compose": cmd_compose, "preview": cmd_preview, "briefs": cmd_briefs, "fonts": cmd_fonts}
    try:
        return handlers[args.cmd](args)
    except Refused as err:
        print(f"store_art: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
