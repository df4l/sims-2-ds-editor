"""Sprite definitions (OBJ) of The Sims 2 DS — parser and renderer. Format: docs/formats/catalog.md

A sprite is the triplet [tiles entry][definition entry][16-colour palette entry].

definition:
  u8 w, u8 h, u16 0, u16 ?, u16 frame_count, u32 tiles_size (bit 24: streamed), u16 frame_offset[n] (rel. to +0xC)
frame (at 0xC + frame_offset):
  u8 piece_count | 0x80 flag, u8 0, u8 w, u8 h, u16 tile_offset, s16 x0, s16 y0,
  [if tiles_size bit 24: 6 more bytes, e.g. 00 17 00 1f 01 00 (bbox + ?)], u32 piece[piece_count]
  tile_offset: single-blob tiles -> byte offset in the decompressed tiles;
               multi-blob (streamed) tiles -> byte offset of the frame's compressed blob in the raw tiles entry.
piece (u32, same fields as the OAM hardware attributes):
  bits 0-8 x (signed), 9-17 y (signed), 18-19 size, 20-21 shape, 22-31 first tile (32-byte 4bpp tiles)
"""
import struct
from dataclasses import dataclass

# (shape, size) -> (width, height) in pixels, OAM hardware table
OBJ_DIM = {(0, 0): (8, 8), (0, 1): (16, 16), (0, 2): (32, 32), (0, 3): (64, 64),
           (1, 0): (16, 8), (1, 1): (32, 8), (1, 2): (32, 16), (1, 3): (64, 32),
           (2, 0): (8, 16), (2, 1): (8, 32), (2, 2): (16, 32), (2, 3): (32, 64)}


def _s9(v: int) -> int:
    return v - 512 if v & 256 else v


@dataclass
class Piece:
    x: int
    y: int
    w: int
    h: int
    tile: int


@dataclass
class Frame:
    flags: int
    w: int
    h: int
    tile_offset: int
    x0: int
    y0: int
    pieces: list


def parse(d: bytes) -> list:
    """Frames of a definition. Raises ValueError if the data does not fit the format."""
    if len(d) < 0x10:
        raise ValueError('too short')
    n = struct.unpack_from('<H', d, 6)[0]
    if n == 0 or 0xC + 2 * n > len(d):
        raise ValueError('bad frame count')
    hdr = 16 if struct.unpack_from('<I', d, 8)[0] >> 24 & 1 else 10
    frames = []
    for off in struct.unpack_from(f'<{n}H', d, 0xC):
        p = 0xC + off
        if p + hdr > len(d):
            raise ValueError('frame out of range')
        cnt, _, w, h, toff, x0, y0 = struct.unpack_from('<BBBBHhh', d, p)
        k = cnt & 0x7F
        if p + hdr + 4 * k > len(d):
            raise ValueError('pieces out of range')
        pieces = []
        for j in range(k):
            v = struct.unpack_from('<I', d, p + hdr + 4 * j)[0]
            dim = OBJ_DIM.get(((v >> 20) & 3, (v >> 18) & 3))
            if dim is None:
                raise ValueError('bad OBJ shape')
            pieces.append(Piece(_s9(v & 511), _s9((v >> 9) & 511), dim[0], dim[1], v >> 22))
        frames.append(Frame(cnt & 0x80, w, h, toff, x0, y0, pieces))
    return frames


def frame_tiles(frame: Frame, blobs: list) -> bytes:
    """Tile data seen by a frame. blobs = list of (start_in_raw, decompressed) of the tiles entry."""
    if len(blobs) == 1:
        return blobs[0][1][frame.tile_offset:]
    for start, data in blobs:
        if start == frame.tile_offset:
            return data
    raise ValueError(f'no blob at raw offset {frame.tile_offset}')


def check(frames: list, blobs: list) -> None:
    """Every piece must lie inside the tile data of its frame."""
    for f in frames:
        t = frame_tiles(f, blobs)
        for pc in f.pieces:
            if (pc.tile + pc.w * pc.h // 64) * 32 > len(t):
                raise ValueError('piece outside tile data')


def render(frame: Frame, blobs: list, pal: list):
    """PIL image of one frame (pieces placed at their x/y, 1D OBJ mapping, 4bpp)."""
    from PIL import Image
    tiles = frame_tiles(frame, blobs)
    if not frame.pieces:
        return Image.new('RGBA', (8, 8))
    x0 = min(p.x for p in frame.pieces)
    y0 = min(p.y for p in frame.pieces)
    w = max(p.x + p.w for p in frame.pieces) - x0
    h = max(p.y + p.h for p in frame.pieces) - y0
    img = Image.new('RGBA', (w, h))
    px = img.load()
    for pc in frame.pieces:
        tw = pc.w // 8
        for t in range(tw * (pc.h // 8)):
            base = (pc.tile + t) * 32
            ox, oy = pc.x - x0 + (t % tw) * 8, pc.y - y0 + (t // tw) * 8
            for y in range(8):
                for x in range(8):
                    b = tiles[base + y * 4 + x // 2]
                    v = b >> 4 if x & 1 else b & 15
                    if v:
                        px[ox + x, oy + y] = pal[v]
    return img
