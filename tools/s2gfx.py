"""Minimal Nintendo DS 2D graphics decoding for previews (The Sims 2 DS).

Formats are the standard hardware ones (GBATEK): BGR555 palettes, 4bpp/8bpp 8x8 tiles, 8bpp linear bitmaps.
"""
import struct

from PIL import Image


def palette(data: bytes, transparent0: bool = True) -> list:
    """BGR555 u16 -> list of RGBA tuples. Bit 15 is ignored (alpha bit of direct-colour bitmaps)."""
    out = []
    for i in range(0, len(data) - 1, 2):
        c = struct.unpack_from('<H', data, i)[0]
        r, g, b = c & 31, (c >> 5) & 31, (c >> 10) & 31
        out.append((r * 255 // 31, g * 255 // 31, b * 255 // 31, 255))
    if transparent0 and out:
        out[0] = out[0][:3] + (0,)
    return out


def grey(n: int) -> list:
    return [(i * 255 // (n - 1),) * 3 + (255,) for i in range(n)]


def tiles_to_image(data: bytes, pal: list, bpp: int = 4, width_tiles: int = 16) -> Image.Image:
    """Linear sequence of 8x8 tiles laid out width_tiles per row."""
    tsize = 8 * bpp
    n = len(data) // tsize
    if n == 0:
        return Image.new('RGBA', (8, 8))
    w = min(width_tiles, n)
    h = (n + w - 1) // w
    img = Image.new('RGBA', (w * 8, h * 8))
    px = img.load()
    for t in range(n):
        tx, ty = (t % w) * 8, (t // w) * 8
        base = t * tsize
        for y in range(8):
            for x in range(8):
                if bpp == 4:
                    b = data[base + y * 4 + x // 2]
                    v = (b >> 4) if x & 1 else (b & 15)
                else:
                    v = data[base + y * 8 + x]
                px[tx + x, ty + y] = pal[v] if v < len(pal) else (255, 0, 255, 255)
    return img


def bitmap8(data: bytes, pal: list, width: int) -> Image.Image:
    h = len(data) // width
    img = Image.new('RGBA', (width, h))
    img.putdata([pal[v] if v < len(pal) else (255, 0, 255, 255) for v in data[:width * h]])
    return img


def save_scaled(img: Image.Image, path, min_size: int = 128) -> None:
    s = max(1, min_size // max(img.width, img.height, 1))
    if s > 1:
        img = img.resize((img.width * s, img.height * s), Image.NEAREST)
    img.save(path)
