"""Hotel room furniture: default lists (arm9), room grid files (rom.bin) and the grid -> world placement.
Format: docs/formats/roomfurn.md

  python tools/roomfurn.py dump            # default furniture of the 6 rooms with world positions
  python tools/roomfurn.py verify          # parse every room grid, check sizes / invariants

Code (CONFIRMED, Ghidra + emulator 2026-10-07):
  Room_SlotFromLocation 0x02073f8c   location -> room slot through ROOM_LOCS (u32[6]), -1 elsewhere
  Room_InitDefaultFurniture 0x02073d48  new game: DEFAULTS (6 x 6 entries) -> G+0x41F8 + 0x58*slot, count 6
  Map_SpawnRoomFurniture 0x02087df4  on every room entry: loads GRID_ENTRIES[slot], spawns each entry
  Room_PlacePropOnGrid 0x020c1eb4  entry (prop, x, z, rot) + grid -> actor position / angle
Room list in the game state (saved with it, ASSUMED): 14 x {u8 prop, u8 x, u8 z, u8 rot}, 7 x u32, u32 count.
"""
import argparse
import math
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
ARM9_BASE = 0x02000000
ROOM_LOCS = 0x0211F9D4      # u32[6] location ids, index = room slot
DEFAULTS = 0x0211FA70       # [6 slots][6 entries] {u8 prop, u8 x, u8 z, u8 rot}
GRID_ENTRIES = 0x02127754   # u16[6] rom.bin entry of the room grid (read via FUN_020c3fc8)
PROP_MODELS = 0x0211CD2C    # {u32 anim_list, u16 BMD0, u16 anim_count} per prop id
N_SLOTS, N_DEFAULT, MAX_ITEMS = 6, 6, 14
N_PROPS = 331               # entries of PROP_MODELS (prop ids used by layouts and rooms)
CELL = 2.0                  # 0x2000 fx32 per grid cell

# Per-prop placement object (actor+0x130), built by Prop_CreatePlacementObject (jump table 0x02011e2c, one case
# per prop id). Only the furniture classes (22 ctors, all calling Furn_InitPlacementBase 0x0208bb98) give a
# placement object that Room_PlacePropOnGrid can use; any other prop id in a room list would read garbage.
# Wall flag = 4th argument of Furn_InitPlacementBase, a constant per class except: class 0x02091098 (flag passed
# by the case: 94, 101, 160, 162, 163 wall), class 0x02099ce4 (wall when prop >= 9). Decoded from the code
# (2026-10-07), ranges inclusive:
FLOOR_PROPS = [(6, 8), (36, 36), (57, 61), (64, 67), (70, 70), (92, 93), (95, 100), (102, 159), (164, 184)]
WALL_PROPS = [(9, 11), (62, 63), (68, 69), (83, 91), (94, 94), (101, 101), (160, 160), (162, 163), (185, 244)]
NODE_KINDS = {0: (28, 18), 3: (32, 22), 4: (48, 38), 5: (36, 26)}   # kind: (bytes per frame, offset of u16 class)


def _in(ranges, p):
    return any(a <= p <= b for a, b in ranges)


def is_furniture(prop: int) -> bool:
    """True if this prop id can be placed in a room list (it gets a furniture placement object)."""
    return _in(FLOOR_PROPS, prop) or _in(WALL_PROPS, prop)

_arm9 = None


def arm9() -> bytes:
    global _arm9
    if _arm9 is None:
        _arm9 = (ROOT / 'rom' / 'arm9.bin').read_bytes()
    return _arm9


def room_locations(a9: bytes = None) -> list:
    a9 = a9 or arm9()
    return list(struct.unpack_from('<6I', a9, ROOM_LOCS - ARM9_BASE))


def grid_entries(a9: bytes = None) -> list:
    a9 = a9 or arm9()
    return list(struct.unpack_from('<6H', a9, GRID_ENTRIES - ARM9_BASE))


def read_defaults(a9: bytes = None) -> list:
    """[slot] -> list of (prop, x, z, rot)."""
    a9 = a9 or arm9()
    o = DEFAULTS - ARM9_BASE
    return [[tuple(a9[o + 24 * s + 4 * i:o + 24 * s + 4 * i + 4]) for i in range(N_DEFAULT)] for s in range(N_SLOTS)]


def write_defaults(a9: bytearray, table: list) -> None:
    o = DEFAULTS - ARM9_BASE
    for s, items in enumerate(table):
        if len(items) != N_DEFAULT:
            raise ValueError(f'room slot {s}: {len(items)} items, the game copies exactly {N_DEFAULT}')
        for i, it in enumerate(items):
            if not all(0 <= v <= 255 for v in it):
                raise ValueError(f'room slot {s} item {i}: {it} out of u8 range')
            a9[o + 24 * s + 4 * i:o + 24 * s + 4 * i + 4] = bytes(it)


@dataclass
class Grid:
    """Room grid file. Header: u32 cells_size (width * depth rounded up to 4), fx32 origin_x, origin_z,
    u16 width, depth, u16 ?, ?, u8 n_heights, u8 n_walls, u16 ?, u32 0 | fx32 heights[n_heights] |
    u8 cells[depth][width] (height index, 0xFF = none) + pad | wall slots[n_walls] {s32 pos (fx32), u8 orient,
    u8 height index, u8 ?, u8 ?} | u8 layer2[depth][width] (unknown, mostly 0xFF) + pad to 4."""
    raw: bytes

    def __post_init__(self):
        r = self.raw
        self.cells_size, ox, oz, self.width, self.depth = struct.unpack_from('<IiiHH', r, 0)
        self.origin = (ox / 4096, oz / 4096)
        self.n_heights = r[0x14]
        self.heights = [v / 4096 for v in struct.unpack_from(f'<{self.n_heights}i', r, 0x1C)]
        self.cells_at = 0x1C + 4 * self.n_heights
        self.walls_at = self.cells_at + self.cells_size
        self.n_walls = r[0x15]
        self.layer2_at = self.walls_at + 8 * self.n_walls

    def problems(self) -> list:
        p = []
        n = self.width * self.depth
        if self.cells_size != (n + 3) & ~3:
            p.append(f'cells_size {self.cells_size} != {self.width}x{self.depth} rounded to 4')
        if len(self.raw) != (self.layer2_at + n + 3) & ~3:
            p.append(f'size {len(self.raw)} != layer2 end {self.layer2_at + n} rounded to 4')
        bad = {c for c in self.raw[self.cells_at:self.cells_at + n] if c != 0xFF and c >= self.n_heights}
        if bad:
            p.append(f'cell height indexes out of range: {sorted(bad)}')
        for i in range(self.n_walls):
            pos, orient, h = self.wall(i)
            if orient > 3 or h >= self.n_heights:
                p.append(f'wall {i}: orient {orient} height {h}')
        return p

    def cell(self, x: int, z: int) -> int:
        return self.raw[self.cells_at + z * self.width + x]

    def wall(self, i: int) -> tuple:
        pos, orient, h = struct.unpack_from('<iBB', self.raw, self.walls_at + 8 * i)
        return pos / 4096, orient, h


def load_grid(entry: int) -> Grid:
    return Grid((ROOT / 'rom_bin' / 'raw' / f'{entry:04d}.bin').read_bytes())


def _entry(e: int) -> bytes:
    p = ROOT / 'rom_bin' / 'dec' / f'{e:04d}.bin'
    return (p if p.exists() else ROOT / 'rom_bin' / 'raw' / f'{e:04d}.bin').read_bytes()


def _fx(v: int, s: int) -> int:   # fx32 multiply as the game does it (round half up)
    return (v * s + 0x800) >> 12


def model_box_fx(prop: int) -> tuple:
    """Model info box of the prop model: (box_x, box_z, box_w, box_d, box_pos_scale), raw fx16 / fx32
    (BMD0 model +0x2C box_x, +0x30 box_z, +0x32 box_w, +0x36 box_d, +0x38 scale)."""
    bmd = struct.unpack_from('<H', arm9(), PROP_MODELS + 8 * prop + 4 - ARM9_BASE)[0]
    d = _entry(bmd)
    for k in range(struct.unpack_from('<H', d, 14)[0]):
        bo = struct.unpack_from('<I', d, 16 + 4 * k)[0]
        if d[bo:bo + 4] == b'MDL0':
            break
    else:
        raise ValueError(f'prop {prop}: no MDL0')
    o = bo + 8
    p = o + 8 + (d[o + 1] + 1) * 4
    m = bo + struct.unpack_from('<I', d, p + 4)[0]
    bx, _, bz, bw, _, bd = struct.unpack_from('<6h', d, m + 0x2C)
    return bx, bz, bw, bd, struct.unpack_from('<i', d, m + 0x38)[0]


def model_box(prop: int) -> tuple:
    """(|box_x|, |box_z|) of the prop model, world units."""
    bx, bz, _, _, s = model_box_fx(prop)
    return _fx(abs(bx), s) / 4096, _fx(abs(bz), s) / 4096


def read_nodes(raw: bytes) -> list:
    """Node file (anim list entry +4 of a prop, read by FUN_02044690 / Node_ReadRecord 0x01ffafdc / FUN_02044a8c):
    u8 flags?, u8 n_frames, u16 n_nodes | per node: u16 kind, u16 id, n_frames x frame. Frame: fx32 x, y, z then
    kind 0: fx32 | 3: fx32 x2 | 4: fx32 x6 | 5: fx32 x3; then u16 ?, u16 class, u32 ?, u32 ?.
    Returns [(kind, id, x, y, z, class)] of frame 0 (fx32)."""
    nf, n = raw[1], struct.unpack_from('<H', raw, 2)[0]
    o, out = 4, []
    for _ in range(n):
        kind, nid = struct.unpack_from('<HH', raw, o)
        o += 4
        size, co = NODE_KINDS[kind]
        x, y, z = struct.unpack_from('<3i', raw, o)
        out.append((kind, nid, x, y, z, struct.unpack_from('<H', raw, o + co)[0]))
        o += size * nf
    if o != len(raw):
        raise ValueError(f'node file: parsed {o} of {len(raw)} bytes')
    return out


def node_file(prop: int):
    """rom.bin entry of the prop's node file (u16 [2] of its first anim list entry {u16 id, u16 anim, u16 nodes}),
    None when the prop has no anim list."""
    lst, _, cnt = struct.unpack_from('<IHH', arm9(), PROP_MODELS + 8 * prop - ARM9_BASE)
    return struct.unpack_from('<H', arm9(), lst + 4 - ARM9_BASE)[0] if cnt else None


def placement(prop: int):
    """(wall, off_x, off_z) of the prop's placement object, as Furn_InitPlacementBase computes it; None if the prop
    is not furniture. The offsets push the footprint so that the first class-2 node (where the Sim stands to use
    it) lies inside: off = max(0, -((box_w*s - |box_x|*s) + node)) on each axis."""
    if not is_furniture(prop):
        return None
    bx, bz, bw, bd, s = model_box_fx(prop)
    ax = az = 0
    nf = node_file(prop)
    if nf is not None:
        n2 = [n for n in read_nodes(_entry(nf)) if n[5] == 2]
        if n2:
            ax, az = n2[0][2], n2[0][4]
    ix = _fx(bw, s) - _fx(abs(bx), s) + ax
    iz = _fx(bd, s) - _fx(abs(bz), s) + az
    return int(_in(WALL_PROPS, prop)), max(0, -ix) / 4096, max(0, -iz) / 4096


def place(grid: Grid, prop: int, x: int, z: int, rot: int):
    """World (X, Y, Z, angle_rad, exact) of a room entry, as Room_PlacePropOnGrid computes it.
    exact = False when the prop is not furniture (the game would read a wrong placement object; drawn as a floor
    prop with no offset)."""
    pl = placement(prop)
    wall, off_x, off_z = pl or (0, 0.0, 0.0)
    bx, bz = model_box(prop)
    ox, oz = grid.origin
    if wall:   # x = wall slot, z = cell along the wall; rot unused
        if x >= grid.n_walls:
            return None
        pos, orient, h = grid.wall(x)
        a = orient * math.pi / 2
        along = (z + 1) * CELL + bx
        X, Z = (ox + along, pos) if orient & 1 == 0 else (pos, oz + along)
        X, Z = X - 0.5 * math.sin(a), Z - 0.5 * math.cos(a)
        Y = grid.heights[h] if h < grid.n_heights else 0.0
        return X, Y, Z, a, pl is not None
    ex, ez = bx, bz
    if rot & 1:   # odd rotation: box extents AND offsets are swapped
        ex, ez, off_x, off_z = bz, bx, off_z, off_x
    if rot >= 2:   # the code negates the offsets then clamps them to >= 0
        off_x, off_z = max(0.0, -off_x), max(0.0, -off_z)
    X = ox + (x + 1) * CELL + ex + off_x
    Z = oz + (z + 1) * CELL + ez + off_z
    c = grid.cell(x, z) if x < grid.width and z < grid.depth else 0xFF
    Y = grid.heights[c] if c < grid.n_heights else 0.0
    return X, Y, Z, rot * math.pi / 2, pl is not None


def room_furniture(loc: int, a9: bytes = None, items: list = None):
    """Default furniture of location `loc` (or the given (prop, x, z, rot) list) as dicts, None if not a room."""
    locs = room_locations(a9)
    if loc not in locs:
        return None
    slot = locs.index(loc)
    grid = load_grid(grid_entries(a9)[slot])
    out = []
    for i, (prop, x, z, rot) in enumerate(items or read_defaults(a9)[slot]):
        r = place(grid, prop, x, z, rot)
        out.append({'index': i, 'prop': prop, 'x': x, 'z': z, 'rot': rot, 'wall': (placement(prop) or (0,))[0],
                    'pos': r[:3] if r else None, 'angle': r[3] if r else 0.0, 'exact': bool(r and r[4])})
    return {'slot': slot, 'grid_entry': grid_entries(a9)[slot], 'items': out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['dump', 'verify'])
    args = ap.parse_args()
    from nitro import model_name
    if args.cmd == 'verify':
        bad = 0
        for slot, e in enumerate(grid_entries()):
            g = load_grid(e)
            p = g.problems()
            bad += bool(p)
            print(f'slot {slot} entry {e}: {g.width}x{g.depth} origin {g.origin} heights {g.heights} '
                  f'walls {g.n_walls} {"OK" if not p else p}')
        sys.exit(1 if bad else 0)
    for loc in room_locations():
        r = room_furniture(loc)
        print(f'location {loc} (slot {r["slot"]}, grid {r["grid_entry"]})')
        for it in r['items']:
            bmd = struct.unpack_from('<H', arm9(), PROP_MODELS + 8 * it['prop'] + 4 - ARM9_BASE)[0]
            if it['pos'] is None:
                print(f'  {it["prop"]:3d} {model_name(bmd):16s} cell ({it["x"]}, {it["z"]}): wall slot out of range')
                continue
            X, Y, Z = it['pos']
            print(f'  {it["prop"]:3d} {model_name(bmd):16s} cell ({it["x"]:3d},{it["z"]:3d}) rot {it["rot"]} '
                  f'{"wall " if it["wall"] else "floor"} -> ({X:8.3f}, {Y:6.2f}, {Z:8.3f}) {math.degrees(it["angle"]):5.0f} deg')


if __name__ == '__main__':
    main()
