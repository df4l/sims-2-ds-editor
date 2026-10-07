"""BSP = location collision (solid-leaf plane tree) of The Sims 2 DS. Format: docs/formats/location.md Â§3

  python tools/bsp.py verify                    # parse -> write round-trip + invariants on every BSP entry
  python tools/bsp.py info  LOC                 # node / leaf / brush statistics of a location
  python tools/bsp.py point LOC X Y Z           # solid or empty at a world position (layout units)
  python tools/bsp.py png   LOC [-o out.png]    # top-down render of the solid brushes + entry points
  python tools/bsp.py walk  LOC [-o out.png]    # walkability map: floor height per column, red = blocked
  python tools/bsp.py obj   LOC [-o out.obj]    # solid brushes as a Wavefront OBJ (layout units)
  python tools/bsp.py cell  LOC X Y Z           # the solid cell at a point: bounding box and facet planes
  python tools/bsp.py delete LOC X Y Z -o out.bin            # BSP with that cell made empty
  python tools/bsp.py move  LOC X Y Z DX DY DZ -o out.bin    # BSP with that cell moved by (DX, DY, DZ)
  python tools/bsp.py box   LOC X0 Y0 Z0 X1 Y1 Z1 -o out.bin # BSP with an added solid box
     (edited BSPs are raw files; store them in rom.bin with stored_blob(), see docs/formats/location.md §3)

Layout (all LE, read in the trace routine Clsn_TraceBoxBsp 0x01ffc558, ITCM):
  "BSP\\0" u32 5 | u32 0 | u32 file_size | u32 root_offset (0x14)
  node (0x1C): s32 front, s32 back, u32 flags, s32 normal[3] (fx 20.12, unit), s32 d (fx32)
     side: n.p/4096 + d <= 0 -> front, else back
     front: > 0 node offset, < 0 -> leaf at offset -front (front is never 0)
     back:  > 0 node offset, 0 = empty space (back is never a leaf)
     flags: bit0 = sign of the normal on the axis, bits1-2 = axis (0 x, 1 y, 2 z, 3 = arbitrary plane),
            bit3 = ? (only ever set when back == 0, not read by the trace), root: upper bits 0x0012FC2x
  leaf: u32 count, u32 node_offset[count] = the ancestor planes that are faces of this solid cell
  Storage order is preorder: node, its front child (node subtree or leaf) at node + 0x1C, then the back subtree.
"""
import argparse
import math
import struct
import sys
from dataclasses import dataclass, field
from itertools import combinations
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

FX = 4096
HEADER = 0x14


@dataclass(eq=False)
class Leaf:
    faces: list                 # Node objects (ancestors) whose planes bound this solid cell


@dataclass(eq=False)
class Node:
    flags: int
    normal: tuple               # 3 x s32 fx 20.12
    d: int                      # s32 fx32
    front: object = None        # Node or Leaf
    back: object = None         # Node or None (= empty space)

    @property
    def axis(self):
        return (self.flags & 7) >> 1

    def side(self, p) -> bool:
        """True = front (solid side), p in fx32."""
        return sum(a * b for a, b in zip(self.normal, p)) // FX + self.d <= 0


@dataclass
class Bsp:
    root: Node
    version: int = 5
    field8: int = 0

    def nodes(self):
        out, st = [], [self.root]
        while st:
            n = st.pop()
            out.append(n)
            if n.back is not None:
                st.append(n.back)
            if isinstance(n.front, Node):
                st.append(n.front)
        return out

    def leaves(self):
        """(leaf, path) with path = [(node, took_front)] from the root."""
        out, st = [], [(self.root, [])]
        while st:
            n, path = st.pop()
            if n.back is not None:
                st.append((n.back, path + [(n, False)]))
            if isinstance(n.front, Leaf):
                out.append((n.front, path + [(n, True)]))
            else:
                st.append((n.front, path + [(n, True)]))
        return out

    def classify(self, p) -> str:
        """'solid' or 'empty' for a point in fx32."""
        n = self.root
        while True:
            c = n.front if n.side(p) else n.back
            if c is None:
                return 'empty'
            if isinstance(c, Leaf):
                return 'solid'
            n = c


def parse(d: bytes) -> Bsp:
    if d[:4] != b'BSP\0':
        raise ValueError('not a BSP file')
    ver, f8, size, root = struct.unpack_from('<4I', d, 4)
    if size != len(d) or root != HEADER:
        raise ValueError(f'header: size {size} (file {len(d)}), root 0x{root:X}')
    nodes, pending = {}, []
    covered = HEADER

    def node(o):
        nonlocal covered
        if o in nodes or o + 0x1C > len(d):
            raise ValueError(f'node 0x{o:X} shared or out of range')
        f, b, fl, nx, ny, nz, dd = struct.unpack_from('<iiI4i', d, o)
        n = nodes[o] = Node(fl, (nx, ny, nz), dd)
        covered += 0x1C
        if f == 0 or b < 0:
            raise ValueError(f'node 0x{o:X}: front {f} back {b}')
        if f > 0:
            if f != o + 0x1C:
                raise ValueError(f'node 0x{o:X}: front 0x{f:X} not at node + 0x1C')
            n.front = node(f)
        else:
            if -f != o + 0x1C:
                raise ValueError(f'node 0x{o:X}: leaf 0x{-f:X} not at node + 0x1C')
            cnt = struct.unpack_from('<I', d, -f)[0]
            refs = struct.unpack_from(f'<{cnt}I', d, -f + 4)
            n.front = Leaf([])
            pending.append((n.front, refs))
            covered += 4 + 4 * cnt
        if b:
            if b != covered:
                raise ValueError(f'node 0x{o:X}: back 0x{b:X}, expected 0x{covered:X}')
            n.back = node(b)
        return n

    sys.setrecursionlimit(max(10000, sys.getrecursionlimit()))
    bsp = Bsp(node(root), ver, f8)
    if covered != len(d):
        raise ValueError(f'tree covers 0x{covered:X} of 0x{len(d):X} bytes')
    for leaf, refs in pending:
        leaf.faces = [nodes[r] for r in refs]
    return bsp


def write(bsp: Bsp) -> bytes:
    order, offs = [], {}
    pos = HEADER

    def place(n):
        nonlocal pos
        offs[n] = pos
        order.append(n)
        pos += 0x1C
        if isinstance(n.front, Leaf):
            offs[n.front] = pos
            order.append(n.front)
            pos += 4 + 4 * len(n.front.faces)
        else:
            place(n.front)
        if n.back is not None:
            place(n.back)

    place(bsp.root)
    out = bytearray(b'BSP\0' + struct.pack('<4I', bsp.version, bsp.field8, pos, HEADER))
    for x in order:
        if isinstance(x, Leaf):
            out += struct.pack(f'<I{len(x.faces)}I', len(x.faces), *(offs[f] for f in x.faces))
        else:
            front = -offs[x.front] if isinstance(x.front, Leaf) else offs[x.front]
            back = offs[x.back] if x.back is not None else 0
            out += struct.pack('<iiI4i', front, back, x.flags, *x.normal, x.d)
    return bytes(out)


def check(bsp: Bsp) -> list:
    """Invariants that hold on all 32 files; returns a list of problems."""
    errs = []
    for n in bsp.nodes():
        ax, s = n.axis, n.flags & 1
        if ax < 3:
            exp = [0, 0, 0]
            exp[ax] = FX if s else -FX
            if list(n.normal) != exp:
                errs.append(f'axial node flags 0x{n.flags:X} normal {n.normal}')
        if n.flags & 8 and n.back is not None:
            errs.append('bit3 set with a back child')
    for leaf, path in bsp.leaves():
        anc = {id(p) for p, _ in path}
        if not all(id(f) in anc for f in leaf.faces):
            errs.append('leaf face is not an ancestor')
    return errs


def brush(leaf: Leaf, path) -> list:
    """Vertices (float, layout units) of the convex solid cell bounded by the leaf's face planes."""
    took = {id(n): t for n, t in path}
    planes = []                 # a.p <= b  (layout units)
    for f in leaf.faces:
        n = [c / FX for c in f.normal]
        dd = f.d / FX
        if took[id(f)]:         # front: n.p + d <= 0
            planes.append((n, -dd))
        else:                   # back: n.p + d > 0  ->  -n.p <= d
            planes.append(([-c for c in n], dd))
    verts = []
    for (a1, b1), (a2, b2), (a3, b3) in combinations(planes, 3):
        p = _solve3(a1, a2, a3, b1, b2, b3)
        if p and all(sum(x * y for x, y in zip(a, p)) <= b + 1e-3 for a, b in planes):
            if not any(sum((x - y) ** 2 for x, y in zip(p, q)) < 1e-6 for q in verts):
                verts.append(p)
    return verts


def _solve3(a1, a2, a3, b1, b2, b3):
    det = (a1[0] * (a2[1] * a3[2] - a2[2] * a3[1]) - a1[1] * (a2[0] * a3[2] - a2[2] * a3[0])
           + a1[2] * (a2[0] * a3[1] - a2[1] * a3[0]))
    if abs(det) < 1e-9:
        return None
    r = []
    for k in range(3):
        m = [list(a1), list(a2), list(a3)]
        m[0][k], m[1][k], m[2][k] = b1, b2, b3
        r.append((m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                  + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])) / det)
    return tuple(r)


def _hull2(pts):
    pts = sorted(set(pts))
    if len(pts) < 3:
        return pts

    def half(ps):
        h = []
        for p in ps:
            while len(h) >= 2 and ((h[-1][0] - h[-2][0]) * (p[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0])) <= 0:
                h.pop()
            h.append(p)
        return h
    return half(pts)[:-1] + half(pts[::-1])[:-1]


def render(bsp: Bsp, points=(), size: int = 768):
    from PIL import Image, ImageDraw
    brushes = [b for b in (brush(l, p) for l, p in bsp.leaves()) if len(b) >= 4]
    xs = [v[0] for b in brushes for v in b]
    zs = [v[2] for b in brushes for v in b]
    ys = [v[1] for b in brushes for v in b]
    lo_x, hi_x, lo_z, hi_z = min(xs), max(xs), min(zs), max(zs)
    lo_y, hi_y = min(ys), max(ys)
    s = (size - 20) / max(hi_x - lo_x, hi_z - lo_z, 1)
    img = Image.new('RGB', (int((hi_x - lo_x) * s) + 20, int((hi_z - lo_z) * s) + 20), (24, 24, 32))
    dr = ImageDraw.Draw(img)
    to = lambda x, z: (10 + (x - lo_x) * s, 10 + (z - lo_z) * s)
    for b in sorted(brushes, key=lambda b: max(v[1] for v in b)):
        top = max(v[1] for v in b)
        h = top - min(v[1] for v in b)
        t = (top - lo_y) / max(hi_y - lo_y, 1)
        col = (int(60 + 150 * t), int(90 + 120 * t), 200) if h < 8 else (int(170 + 80 * t), int(80 + 60 * t), 60)
        poly = [to(x, z) for x, z in _hull2([(round(v[0], 3), round(v[2], 3)) for v in b])]
        if len(poly) >= 3:
            dr.polygon(poly, fill=col, outline=(0, 0, 0))
    for label, (x, z) in points:
        cx, cy = to(x, z)
        dr.ellipse((cx - 3, cy - 3, cx + 3, cy + 3), fill=(255, 255, 0))
        dr.text((cx + 4, cy - 6), label, fill=(255, 255, 255))
    return img


def to_obj(bsp: Bsp) -> str:
    lines, base = [], 1
    for i, (leaf, path) in enumerate(bsp.leaves()):
        vs = brush(leaf, path)
        if len(vs) < 4:
            continue
        lines.append(f'o leaf{i}')
        lines += [f'v {x:.3f} {y:.3f} {z:.3f}' for x, y, z in vs]
        # faces: for each plane, the vertices lying on it, ordered around their centroid
        took = {id(n): t for n, t in path}
        for f in leaf.faces:
            n = [c / FX for c in f.normal]
            on = [k for k, v in enumerate(vs) if abs(sum(a * b for a, b in zip(n, v)) + f.d / FX) < 1e-2]
            if len(on) < 3:
                continue
            c = [sum(vs[k][j] for k in on) / len(on) for j in range(3)]
            u = [vs[on[0]][j] - c[j] for j in range(3)]
            w = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]]
            import math
            on.sort(key=lambda k: math.atan2(sum((vs[k][j] - c[j]) * w[j] for j in range(3)),
                                             sum((vs[k][j] - c[j]) * u[j] for j in range(3))))
            if not took[id(f)]:
                on.reverse()
            lines.append('f ' + ' '.join(str(base + k) for k in on))
        base += len(vs)
    return '\n'.join(lines) + '\n'


def entries():
    import s2data
    return [e for e in s2data.load() if e.data[:4] == b'BSP\0']


# ---- editing -------------------------------------------------------------------------------------------------
# A plane is (flags, normal fx 20.12, d fx32) with the file's meaning: solid side = n.p + d <= 0.
# The trace (Clsn_TraceBoxBsp) never accepts front == 0 (offset 0 would be read as a node) and
# Clsn_TraceWorld copies the hit node's normal as is, so new faces always have their solid cell on the front side.

BIG = 1 << 14                   # half size of the starting cube for polytope clipping (layout units)


def _cube(lo, hi):
    (x0, y0, z0), (x1, y1, z1) = lo, hi
    v = [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    return [[v[i] for i in q] for q in quads]


def _clip(poly, normal, d, eps=1e-6):
    """Convex polyhedron (list of polygons, layout units) cut to the side normal.p + d <= 0 (normal, d in fx)."""
    n = [c / FX for c in normal]
    dd = d / FX
    dist = lambda v: n[0] * v[0] + n[1] * v[1] + n[2] * v[2] + dd
    out, cut = [], []
    for f in poly:
        g = []
        for a, b in zip(f, f[1:] + f[:1]):
            sa, sb = dist(a), dist(b)
            if sa <= eps:
                g.append(a)
            if abs(sa) <= eps:
                cut.append(a)
            elif (sa < -eps and sb > eps) or (sa > eps and sb < -eps):
                t = sa / (sa - sb)
                x = tuple(a[k] + t * (b[k] - a[k]) for k in range(3))
                g.append(x)
                cut.append(x)
        if len(g) >= 3:
            out.append(g)
    cap = []
    for x in cut:
        if not any(sum((x[k] - y[k]) ** 2 for k in range(3)) < 1e-12 for y in cap):
            cap.append(x)
    if len(cap) >= 3 and out:
        c = [sum(x[k] for x in cap) / len(cap) for k in range(3)]
        u = [cap[0][k] - c[k] for k in range(3)]
        w = [n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]]
        cap.sort(key=lambda x: math.atan2(sum((x[k] - c[k]) * w[k] for k in range(3)),
                                          sum((x[k] - c[k]) * u[k] for k in range(3))))
        out.append(cap)
    return out


def _volume(poly):
    if len(poly) < 4:
        return 0.0
    vs = [v for f in poly for v in f]
    c = [sum(v[k] for v in vs) / len(vs) for k in range(3)]
    vol = 0.0
    for f in poly:
        for a, b in zip(f[1:], f[2:]):
            p, q, r = ([f[0][k] - c[k] for k in range(3)], [a[k] - c[k] for k in range(3)],
                       [b[k] - c[k] for k in range(3)])
            vol += abs(p[0] * (q[1] * r[2] - q[2] * r[1]) - p[1] * (q[0] * r[2] - q[2] * r[0])
                       + p[2] * (q[0] * r[1] - q[1] * r[0])) / 6
    return vol


def _flip(n: Node):
    """Same plane, other side: the front and back half-spaces swap."""
    n.normal = tuple(-c for c in n.normal)
    n.d = -n.d
    if n.axis < 3:
        n.flags ^= 1


def axial_plane(axis: int, value: float, solid_below: bool):
    """Plane x/y/z = value; solid_below: the solid side is coordinate <= value."""
    nrm = [0, 0, 0]
    nrm[axis] = FX if solid_below else -FX
    v = int(round(value * FX))
    return ((axis << 1) | int(solid_below), tuple(nrm), -v if solid_below else v)


def find_cell(bsp: Bsp, p):
    """(leaf, path) of the solid cell holding point p (layout units), or None if p is empty."""
    q = [int(round(c * FX)) for c in p]
    n, path = bsp.root, []
    while True:
        f = n.side(q)
        path.append((n, f))
        c = n.front if f else n.back
        if c is None:
            return None
        if isinstance(c, Leaf):
            return c, path
        n = c


def cell_polytope(path):
    """Exact convex region of a cell (intersection of every ancestor half-space), as polygons."""
    poly = _cube((-BIG,) * 3, (BIG,) * 3)
    for n, took in path:
        poly = _clip(poly, n.normal, n.d) if took else _clip(poly, [-c for c in n.normal], -n.d)
    return poly


def cell_planes(path):
    """Planes (front-side form) that carry a facet of the cell; redundant ancestor planes are left out."""
    poly = cell_polytope(path)
    out = []
    for n, took in path:
        if took:
            fl, nrm, d = n.flags & 7, n.normal, n.d
        else:
            fl, nrm, d = (n.flags & 7) ^ (n.axis < 3), tuple(-c for c in n.normal), -n.d
        nf = [c / FX for c in nrm]
        on = {v for f in poly for v in f if abs(sum(a * b for a, b in zip(nf, v)) + d / FX) < 1e-3}
        if len(on) >= 3 and not any(o[1] == nrm and o[2] == d for o in out):
            out.append((fl, nrm, d))
    return out


def _parents(bsp: Bsp):
    par = {}
    for n in bsp.nodes():
        par[id(n.front)] = (n, True)
        if n.back is not None:
            par[id(n.back)] = (n, False)
    return par


def delete_cell(bsp: Bsp, leaf: Leaf) -> None:
    """Make a solid cell empty. Its parent P must keep a non-zero front: if P has a back subtree, P's plane is
    flipped so that subtree becomes the front child; otherwise P itself is removed (and so on upwards).
    Faces that pointed at a flipped node keep it (same plane; for those cells the normal now points outward)."""
    par = _parents(bsp)
    n = par[id(leaf)][0]
    while True:
        if n.back is not None:
            _flip(n)
            n.front, n.back = n.back, None
            return
        if n is bsp.root:
            raise ValueError('deleting the last solid cell would leave an empty tree')
        q, was_front = par[id(n)]
        if not was_front:
            q.back = None
            return
        n = q


def add_brush(bsp: Bsp, planes) -> int:
    """Add the convex solid {p : n.p + d <= 0 for every plane}. The brush is pushed down the tree and clipped:
    parts that land in an existing solid cell are dropped, every empty `back` slot reached gets a chain of the
    brush planes (front -> front -> ... -> leaf listing them all). Returns the number of slots filled."""
    poly0 = _cube((-BIG,) * 3, (BIG,) * 3)
    for _, nrm, d in planes:
        poly0 = _clip(poly0, nrm, d)
    if _volume(poly0) < 1e-6:
        raise ValueError('empty brush')
    filled = 0

    def chain():
        ns = [Node(fl, tuple(nrm), d) for fl, nrm, d in planes]
        for a, b in zip(ns, ns[1:]):
            a.front = b
        ns[-1].front = Leaf(list(ns))
        return ns[0]

    def push(n, poly):
        nonlocal filled
        nf = [c / FX for c in n.normal]
        s = [sum(a * b for a, b in zip(nf, v)) + n.d / FX for f in poly for v in f]
        if min(s) < -1e-6 and isinstance(n.front, Node):
            fr = _clip(poly, n.normal, n.d)
            if _volume(fr) > 1e-6:
                push(n.front, fr)
        if max(s) > 1e-6:
            bk = _clip(poly, [-c for c in n.normal], -n.d)
            if _volume(bk) > 1e-6:
                if n.back is None:
                    n.back = chain()
                    n.flags &= ~8          # bit3 only ever appears with back == 0 (not read by the trace)
                    filled += 1
                else:
                    push(n.back, bk)

    push(bsp.root, poly0)
    return filled


def add_box(bsp: Bsp, lo, hi) -> int:
    """Axis-aligned solid box (layout units); see add_brush."""
    return add_brush(bsp, [axial_plane(ax, v, below) for ax in range(3)
                           for v, below in ((hi[ax], True), (lo[ax], False))])


def move_cell(bsp: Bsp, leaf: Leaf, path, delta) -> int:
    """Move a solid cell by delta (layout units): delete it, then add its facet planes shifted by delta.
    The old region becomes empty. Returns add_brush's slot count."""
    t = [int(round(c * FX)) for c in delta]
    planes = [(fl, nrm, d - sum(a * b for a, b in zip(nrm, t)) // FX) for fl, nrm, d in cell_planes(path)]
    delete_cell(bsp, leaf)
    return add_brush(bsp, planes)


def stored_blob(data: bytes) -> bytes:
    """rom.bin entry holding `data` uncompressed (blob type 0x00 = raw copy in Cmp_Decompress)."""
    return struct.pack('<I', len(data) << 8) + data + bytes(-len(data) & 3)


def classify_many(bsp: Bsp, x, y, z):
    """Vectorised classify: numpy arrays of layout units -> bool array (True = solid)."""
    import numpy as np
    nodes = bsp.nodes()
    ix = {id(n): i for i, n in enumerate(nodes)}
    SOLID, EMPTY = -1, -2
    N = np.array([n.normal for n in nodes], dtype=np.int64)
    D = np.array([n.d for n in nodes], dtype=np.int64)
    F = np.array([SOLID if isinstance(n.front, Leaf) else ix[id(n.front)] for n in nodes])
    B = np.array([EMPTY if n.back is None else ix[id(n.back)] for n in nodes])
    p = [np.asarray(c * FX, dtype=np.int64).ravel() for c in (x, y, z)]
    cur = np.zeros(p[0].shape, dtype=np.int64)
    act = np.ones(cur.shape, dtype=bool)
    while act.any():
        i = cur[act]
        s = (N[i, 0] * p[0][act] + N[i, 1] * p[1][act] + N[i, 2] * p[2][act]) // FX + D[i]
        cur[act] = np.where(s <= 0, F[i], B[i])
        act = cur >= 0
    return (cur == SOLID).reshape(np.shape(x))


def walkmap(bsp: Bsp, points=(), scale: float = 2.0, body: int = 12):
    """Top-down walkability raster: per column, the highest floor (solid below, `body` units of empty above)."""
    import numpy as np
    from PIL import Image, ImageDraw
    vs = [v for l, p in bsp.leaves() for v in brush(l, p)]
    lo = [min(v[k] for v in vs) for k in range(3)]
    hi = [max(v[k] for v in vs) for k in range(3)]
    xs = np.arange(lo[0], hi[0], 1 / scale) + 0.25
    zs = np.arange(lo[2], hi[2], 1 / scale) + 0.25
    X, Z = np.meshgrid(xs, zs)
    ys = np.arange(int(lo[1]) - 1, int(hi[1]) + 2)
    solid = np.stack([classify_many(bsp, X, np.full(X.shape, y + 0.5), Z) for y in ys])   # [y, z, x]
    # floor at ys[k] if solid at k and empty for k+1 .. k+body
    empty = ~solid
    run = np.zeros_like(solid, dtype=np.int32)          # empty cells above (consecutive), from the top
    for k in range(len(ys) - 2, -1, -1):
        run[k] = np.where(empty[k + 1], run[k + 1] + 1, 0)
    floor_ok = solid & (run >= body)
    top = np.where(floor_ok.any(0), len(ys) - 1 - np.argmax(floor_ok[::-1], 0), -1)
    h = np.where(top >= 0, ys[np.clip(top, 0, None)] + 1, np.nan)
    blocked = solid.any(0) & (top < 0)
    img = np.zeros(X.shape + (3,), dtype=np.uint8)
    img[:] = (24, 24, 32)
    hmin, hmax = np.nanmin(h), np.nanmax(h)
    t = (h - hmin) / max(hmax - hmin, 1)
    ok = ~np.isnan(h)
    img[ok] = np.stack([60 + 160 * t[ok], 110 + 120 * t[ok], 200 - 60 * t[ok]], -1).astype(np.uint8)
    img[blocked] = (200, 70, 50)
    # outline height steps so walls / curbs read clearly
    edge = np.zeros(X.shape, dtype=bool)
    hh = np.nan_to_num(h, nan=-999)
    edge[:, 1:] |= np.abs(np.diff(hh, axis=1)) > 1.5
    edge[1:, :] |= np.abs(np.diff(hh, axis=0)) > 1.5
    img[edge & ok] = (20, 20, 20)
    im = Image.fromarray(img)
    dr = ImageDraw.Draw(im)
    for label, (x, z) in points:
        cx, cy = (x - xs[0]) * scale, (z - zs[0]) * scale
        dr.ellipse((cx - 3, cy - 3, cx + 3, cy + 3), fill=(255, 255, 0))
        dr.text((cx + 4, cy - 6), label, fill=(255, 255, 255))
    return im, (hmin, hmax)


def load_location(loc: int):
    import s2data
    from locations import read_table
    L = read_table()[loc]
    return L, parse(s2data.load()[L['bsp']].data)


def _entry_points(L):
    import layout
    lay = layout.parse((layout.RAW / f"{L['nav']:04d}.bin").read_bytes())
    out = []
    for e in lay.entries:
        x, y, z = struct.unpack_from('<3h', e, 0)
        out.append((str(e[0xC]), (x, z)))
    return out


def _save(b: Bsp, out):
    if out is None:
        raise SystemExit('-o out.bin is required')
    data = write(b)
    errs = check(parse(data))
    if errs:
        raise SystemExit(f'edited BSP breaks an invariant: {errs[0]}')
    out.write_bytes(data)
    print(f'wrote {out} ({len(data)} bytes, {len(b.nodes())} nodes)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['verify', 'info', 'point', 'png', 'walk', 'obj', 'cell', 'delete', 'move', 'box'])
    ap.add_argument('loc', type=int, nargs='?')
    ap.add_argument('xyz', type=float, nargs='*')
    ap.add_argument('-o', '--out', type=Path)
    a = ap.parse_args()
    if a.cmd == 'verify':
        ok = 0
        for e in entries():
            b = parse(e.data)
            errs = check(b)
            if write(b) != e.data:
                print(f'{e.index}: round-trip FAILED')
            elif errs:
                print(f'{e.index}: {len(errs)} invariant failures, e.g. {errs[0]}')
            else:
                ok += 1
        print(f'{ok}/{len(entries())} BSP files: byte-identical round-trip, invariants OK')
        return
    from locations import PLACES
    L, b = load_location(a.loc)
    if a.cmd == 'info':
        lv = b.leaves()
        nb = [len(brush(l, p)) for l, p in lv]
        print(f"location {a.loc} {PLACES[a.loc]}: BSP entry {L['bsp']}, {len(b.nodes())} nodes, {len(lv)} solid cells, "
              f"{sum(1 for n in nb if n >= 4)} bounded (vertices min {min(nb)} max {max(nb)})")
    elif a.cmd == 'point':
        x, y, z = a.xyz
        print(b.classify([int(x * FX), int(y * FX), int(z * FX)]))
    elif a.cmd == 'png':
        out = a.out or Path(f'bsp_loc{a.loc:02d}.png')
        render(b, _entry_points(L)).save(out)
        print(f'wrote {out}')
    elif a.cmd == 'walk':
        out = a.out or Path(f'walk_loc{a.loc:02d}.png')
        im, (h0, h1) = walkmap(b, _entry_points(L))
        im.save(out)
        print(f'wrote {out} (floor heights {h0:.0f}..{h1:.0f}, red = blocked)')
    elif a.cmd in ('cell', 'delete', 'move'):
        r = find_cell(b, a.xyz[:3])
        if r is None:
            raise SystemExit('no solid cell at that point')
        leaf, path = r
        if a.cmd == 'cell':
            vs = [v for f in cell_polytope(path) for v in f]
            print('cell box', [round(min(v[k] for v in vs), 3) for k in range(3)],
                  [round(max(v[k] for v in vs), 3) for k in range(3)], f'{len(leaf.faces)} faces in the leaf')
            for fl, nrm, d in cell_planes(path):
                print(f'  flags {fl:X} normal {tuple(c / FX for c in nrm)} d {d / FX:g}')
            return
        if a.cmd == 'delete':
            delete_cell(b, leaf)
        else:
            move_cell(b, leaf, path, a.xyz[3:6])
        _save(b, a.out)
    elif a.cmd == 'box':
        add_box(b, a.xyz[:3], a.xyz[3:6])
        _save(b, a.out)
    else:
        out = a.out or Path(f'bsp_loc{a.loc:02d}.obj')
        out.write_text(to_obj(b))
        print(f'wrote {out}')


if __name__ == '__main__':
    main()
