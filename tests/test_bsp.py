"""Location collision BSP (tools/bsp.py): round-trip, invariants, side convention, box insertion, cell edits."""
import random
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import bsp  # noqa: E402
import layout  # noqa: E402
from locations import read_table  # noqa: E402

FX = bsp.FX


def test_roundtrip_and_invariants():
    ents = bsp.entries()
    assert len(ents) == 32
    for e in ents:
        b = bsp.parse(e.data)              # raises on any layout invariant (preorder, coverage)
        assert bsp.write(b) == e.data, e.index
        assert bsp.check(b) == [], e.index


def test_entry_points_stand_on_solid_floor():
    """Front side = n.p + d <= 0 is solid: entry points are in empty space, just below them is solid."""
    above = below = n = 0
    for L in read_table():
        _, b = bsp.load_location(L['location'])
        lay = layout.parse((layout.RAW / f"{L['nav']:04d}.bin").read_bytes())
        for e in lay.entries:
            x, y, z = struct.unpack_from('<3h', e, 0)
            n += 1
            above += b.classify([x * FX, (y + 3) * FX, z * FX]) == 'empty'
            below += b.classify([x * FX, (y - 5) * FX, z * FX]) == 'solid'
    assert above == n and below >= 0.9 * n, (above, below, n)


def test_add_box():
    _, b = bsp.load_location(6)
    bsp.add_box(b, (-25, 0, -42), (-18, 10, -32))
    data = bsp.write(b)
    b2 = bsp.parse(data)
    assert bsp.write(b2) == data and bsp.check(b2) == []
    assert b2.classify([-20 * FX, 5 * FX, -37 * FX]) == 'solid'
    assert b2.classify([-20 * FX, 11 * FX, -37 * FX]) == 'empty'


def _edit_matches(b0, path, b2, delta=None):
    """On a grid around the cell (and its moved copy): after == (before minus cell) [plus the shifted cell].
    Points closer than 1/1024 unit to any plane are skipped (fx32 rounding of n.p / 4096 decides their side)."""
    import numpy as np
    vs = np.array([v for f in bsp.cell_polytope(path) for v in f])
    lo, hi = vs.min(0) - 6, vs.max(0) + 6
    if delta is not None:
        lo, hi = np.minimum(lo, lo + delta), np.maximum(hi, hi + delta)
    X, Y, Z = np.meshgrid(*[np.arange(lo[k], hi[k], 0.71) + 0.137 for k in range(3)], indexing='ij')

    def inside(x, y, z):
        m = np.ones(x.shape, bool)
        for n, took in path:
            s = (n.normal[0] * x + n.normal[1] * y + n.normal[2] * z + n.d) / FX
            m &= (s <= 0) if took else (s > 0)
        return m
    exp = bsp.classify_many(b0, X, Y, Z) & ~inside(X, Y, Z)
    if delta is not None:
        exp |= inside(X - delta[0], Y - delta[1], Z - delta[2])
    near = np.zeros(X.shape, bool)
    for n in b0.nodes() + b2.nodes():
        near |= np.abs((n.normal[0] * X + n.normal[1] * Y + n.normal[2] * Z + n.d) / FX) < 1 / 1024
    return int(((exp != bsp.classify_many(b2, X, Y, Z)) & ~near).sum())


def test_delete_and_move_cells():
    """delete_cell / move_cell on sampled cells of 8 locations: valid file, exact solid/empty change."""
    rnd = random.Random(1)
    for loc in (0, 5, 6, 9, 13, 19, 22, 30):
        _, b0 = bsp.load_location(loc)
        data0 = bsp.write(b0)
        cells = [(l, p) for l, p in b0.leaves() if len(bsp.brush(l, p)) >= 4]
        for leaf, path in rnd.sample(cells, 2):
            import numpy as np
            c = np.array([v for f in bsp.cell_polytope(path) for v in f]).mean(0)
            delta = (rnd.choice([-8, 0, 7]), rnd.choice([3, 12]), rnd.choice([-9, 0, 6]))
            for op in ('delete', 'move'):
                b = bsp.parse(data0)
                lf, pth = bsp.find_cell(b, c)
                if op == 'delete':
                    bsp.delete_cell(b, lf)
                else:
                    bsp.move_cell(b, lf, pth, delta)
                d = bsp.write(b)
                b2 = bsp.parse(d)
                assert bsp.write(b2) == d and bsp.check(b2) == [], (loc, op)
                assert _edit_matches(b0, path, b2, delta if op == 'move' else None) == 0, (loc, op)


def test_edit_city_hall_floor():
    """The two edits tested in game (build/bsp_edit_test/): floor cell under City Hall entry 0."""
    _, b = bsp.load_location(6)
    leaf, path = bsp.find_cell(b, (-20, -2, -37))
    assert [round(x / FX, 3) for _, _, x in bsp.cell_planes(path)] == [16, -19.707, -32, 0, -5, -54]
    bsp.delete_cell(b, leaf)
    assert len(bsp.write(b)) == 11220 and b.classify([-20 * FX, -2 * FX, -37 * FX]) == 'empty'
    _, b = bsp.load_location(6)
    leaf, path = bsp.find_cell(b, (-20, -2, -37))
    bsp.move_cell(b, leaf, path, (0, 10, 0))
    assert len(bsp.write(b)) == 11416
    assert b.classify([-20 * FX, 8 * FX, -37 * FX]) == 'solid' and b.classify([-20 * FX, -2 * FX, -37 * FX]) == 'empty'


if __name__ == '__main__':
    test_roundtrip_and_invariants()
    test_entry_points_stand_on_solid_floor()
    test_add_box()
    test_delete_and_move_cells()
    test_edit_city_hall_floor()
    print('OK')
