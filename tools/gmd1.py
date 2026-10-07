"""GMD1 = location triangle mesh (collision / walkable geometry?) of The Sims 2 DS. Format: docs/formats/location.md

  python tools/gmd1.py verify                 # parse -> write round-trip on every GMD1 entry
  python tools/gmd1.py obj  IDX [-o out.obj]  # export one mesh (world coordinates) to Wavefront OBJ
  python tools/gmd1.py png  IDX [-o out.png]  # top-down + perspective-free shaded render

Layout (all LE):
  "GMD1" u8 1 u8 2 u16 0 | u32 vertex_count (multiple of 3) | u32 1
  "XFRM" s32 centre[3] s32 half_size[3] (fx32 20.12) | 16 bytes (00.. 00 00 2c cf 00 00 2c cf)
  "FRAM" vertex[vertex_count]
  vertex (16 bytes): s16 x,y,z (normalised: +-32767 = +-half_size) ; s16 nx,ny,nz (fx 4.12 unit face normal,
                     identical for the 3 vertices of a triangle) ; u32 0
"""
import argparse
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

FX = 4096.0


@dataclass
class Gmd1:
    version: bytes          # 4 bytes after the magic (01 02 00 00)
    flag: int               # u32 after the count (1)
    centre: tuple           # 3 x s32 fx32
    half: tuple             # 3 x s32 fx32
    xfrm_tail: bytes        # 16 bytes, meaning unknown
    verts: list             # (x, y, z, nx, ny, nz, tail_u32)

    def triangles(self):
        return [self.verts[i:i + 3] for i in range(0, len(self.verts), 3)]

    def world(self, v):
        return tuple(self.centre[i] / FX + v[i] / 32767.0 * self.half[i] / FX for i in range(3))


def parse(d: bytes) -> Gmd1:
    if d[:4] != b'GMD1' or d[16:20] != b'XFRM' or d[60:64] != b'FRAM':
        raise ValueError('not a GMD1 file')
    n, flag = struct.unpack_from('<II', d, 8)
    if len(d) != 64 + 16 * n or n % 3:
        raise ValueError('bad vertex count')
    vals = struct.unpack_from('<6i', d, 20)
    verts = [struct.unpack_from('<6hI', d, 64 + 16 * k) for k in range(n)]
    return Gmd1(d[4:8], flag, vals[:3], vals[3:], d[44:60], verts)


def write(g: Gmd1) -> bytes:
    out = bytearray(b'GMD1' + g.version + struct.pack('<II', len(g.verts), g.flag))
    out += b'XFRM' + struct.pack('<6i', *g.centre, *g.half) + g.xfrm_tail + b'FRAM'
    for v in g.verts:
        out += struct.pack('<6hI', *v)
    return bytes(out)


def to_obj(g: Gmd1) -> str:
    lines = ['# GMD1 mesh, world units (fx32 / 4096)']
    for v in g.verts:
        lines.append('v %.4f %.4f %.4f' % g.world(v))
    for t in range(len(g.verts) // 3):
        nx, ny, nz = (c / FX for c in g.verts[3 * t][3:6])
        lines.append('vn %.4f %.4f %.4f' % (nx, ny, nz))
    for t in range(len(g.verts) // 3):
        a = 3 * t + 1
        lines.append(f'f {a}//{t + 1} {a + 1}//{t + 1} {a + 2}//{t + 1}')
    return '\n'.join(lines) + '\n'


def render(g: Gmd1, size: int = 512):
    """Two views side by side: top-down (x right, z down) and front (x right, y up), flat shaded by normal,
    painter's algorithm. Floor-like faces (normal mostly +y) are tinted green."""
    from PIL import Image, ImageDraw
    pts = [g.world(v) for v in g.verts]
    img = Image.new('RGB', (2 * size, size), (25, 25, 30))
    dr = ImageDraw.Draw(img)
    for view, ox in ((('x', 'z', 'y'), 0), (('x', 'y', 'z'), size)):
        ia, ib, idep = ('xyz'.index(c) for c in view)
        lo_a, hi_a = min(p[ia] for p in pts), max(p[ia] for p in pts)
        lo_b, hi_b = min(p[ib] for p in pts), max(p[ib] for p in pts)
        s = (size - 20) / max(hi_a - lo_a, hi_b - lo_b, 1e-6)
        flip = ib == 1  # y up in the front view
        tris = []
        for t in range(len(pts) // 3):
            P = pts[3 * t:3 * t + 3]
            depth = sum(p[idep] for p in P) / 3
            tris.append((depth if view[2] == 'y' else -depth, t, P))
        for depth, t, P in sorted(tris):
            nx, ny, nz = (c / FX for c in g.verts[3 * t][3:6])
            light = max(0.15, 0.35 + 0.65 * abs(ny if view[2] == 'y' else nz))
            col = (int(90 * light), int(200 * light), int(90 * light)) if ny > 0.7 else \
                  (int(200 * light), int(170 * light), int(140 * light))
            poly = [(ox + 10 + (p[ia] - lo_a) * s,
                     10 + ((hi_b - p[ib]) if flip else (p[ib] - lo_b)) * s) for p in P]
            dr.polygon(poly, fill=col, outline=(0, 0, 0))
    return img


def _entries():
    import s2data
    return [e for e in s2data.load() if e.data[:4] == b'GMD1']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['verify', 'obj', 'png'])
    ap.add_argument('index', type=int, nargs='?')
    ap.add_argument('-o', '--out', type=Path)
    a = ap.parse_args()
    if a.cmd == 'verify':
        ok = 0
        for e in _entries():
            if write(parse(e.data)) != e.data:
                print(f'{e.index}: round-trip FAILED')
            else:
                ok += 1
        print(f'{ok} GMD1 files: byte-identical round-trip')
        return
    import s2data
    g = parse(s2data.load()[a.index].data)
    if a.cmd == 'obj':
        out = a.out or Path(f'{a.index:04d}.obj')
        out.write_text(to_obj(g))
    else:
        out = a.out or Path(f'{a.index:04d}.png')
        render(g).save(out)
    print(f'wrote {out}')


if __name__ == '__main__':
    main()
