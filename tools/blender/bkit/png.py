"""Pure-Python PNG and JPEG helpers (no bpy): exact 8-bit PNG writing for baked maps, PNG
decoding for pixel checks, and header reads for texture validation. Writing PNGs here instead
of through Blender keeps the bytes identical on every bpy version (no encoder or metadata
differences) and gives the channel layout Roblox asks for: 24-bit RGB colour and normal maps,
8-bit greyscale roughness, metalness and emissive maps."""
import struct
import zlib
from pathlib import Path

SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}  # PNG colour type -> samples per pixel
MODES = {"L": 0, "RGB": 2, "RGBA": 6}


def _chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write(path, width, height, rows, mode="RGB"):
    """Write an 8-bit PNG. rows: `height` sequences (top row first) of `width * channels` ints
    0..255. mode: L (greyscale), RGB or RGBA. Filter type 0, zlib level 9: deterministic bytes."""
    data = encode(width, height, rows, mode)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(data)
    return Path(path)


def encode(width, height, rows, mode="RGB"):
    """PNG bytes for `write`."""
    channels = {"L": 1, "RGB": 3, "RGBA": 4}[mode]
    raw = bytearray()
    for row in rows:
        if len(row) != width * channels:
            raise ValueError(f"png.write: row has {len(row)} samples, expected {width * channels}")
        raw.append(0)
        raw.extend(bytes(row))
    if len(raw) != height * (width * channels + 1):
        raise ValueError("png.write: wrong row count")
    header = struct.pack(">IIBBBBB", width, height, 8, MODES[mode], 0, 0, 0)
    return SIGNATURE + _chunk(b"IHDR", header) + _chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _chunk(b"IEND", b"")


def header(data):
    """(width, height, bit_depth, colour_type) of PNG bytes, or raise ValueError."""
    if data[:8] != SIGNATURE or data[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    width, height, depth, colour = struct.unpack(">IIBB", data[16:26])
    return width, height, depth, colour


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read(path_or_bytes):
    """Decode an 8-bit, non-interlaced PNG (greyscale, grey+alpha, RGB, RGBA or palette).
    Returns {width, height, channels, colour_type, rows} with rows top-first as lists of ints
    (palette images are expanded to RGB). Raises ValueError for anything else."""
    data = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else Path(path_or_bytes).read_bytes()
    width, height, depth, colour = header(data)
    if depth != 8:
        raise ValueError(f"PNG bit depth {depth}: only 8-bit is decoded")
    if data[28] != 0:
        raise ValueError("interlaced PNG is not decoded")
    pos, idat, palette = 8, bytearray(), None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IDAT":
            idat.extend(body)
        elif kind == b"PLTE":
            palette = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"IEND":
            break
        pos += 12 + length
    channels = CHANNELS[colour]
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows, prev = [], [0] * stride
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], list(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                line[i] = (line[i] + _paeth(a, b, c)) & 255
        rows.append(line)
        prev = line
    if colour == 3:
        rows = [[v for index in row for v in palette[index]] for row in rows]
        channels = 3
    return {"width": width, "height": height, "channels": channels, "colour_type": colour, "rows": rows}


def pixel(image, x, y):
    """Samples of pixel (x, y) of a `read` result, y counted from the top row."""
    c = image["channels"]
    return tuple(image["rows"][y][x * c:(x + 1) * c])


def jpeg_size(data):
    """(width, height, components) from a JPEG's SOF marker, or raise ValueError."""
    if data[:2] != b"\xff\xd8":
        raise ValueError("not a JPEG")
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            raise ValueError("bad JPEG marker")
        marker = data[pos + 1]
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack(">HH", data[pos + 5:pos + 9])
            return width, height, data[pos + 9]
        pos += 2 + length
    raise ValueError("JPEG without a frame header")


def image_info(path):
    """{format, width, height, channels} of a PNG or JPEG file (header only for JPEG)."""
    data = Path(path).read_bytes()
    if data[:8] == SIGNATURE:
        width, height, depth, colour = header(data)
        return {"format": "png", "width": width, "height": height, "channels": CHANNELS.get(colour, 0), "bit_depth": depth, "colour_type": colour}
    if data[:2] == b"\xff\xd8":
        width, height, components = jpeg_size(data)
        return {"format": "jpeg", "width": width, "height": height, "channels": components, "bit_depth": 8}
    raise ValueError(f"{Path(path).name}: not a PNG or JPEG")
