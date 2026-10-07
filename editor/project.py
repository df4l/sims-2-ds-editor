"""Editor project: edited layout / BSP entries on top of the original rom.bin, plus the default hotel room furniture
(arm9 table, tools/roomfurn.py), with undo, autosave and ROM build.

  python editor/project.py status          # edited entries
  python editor/project.py build           # build/editor_rom/sims2_edited.nds from the saved edits
  python editor/project.py reset           # drop every edit

Edits are saved as soon as they are made, one file per edited rom.bin entry (decompressed content):
  build/editor_project/layout/NNNN.bin     layout file (stored raw in rom.bin, like the originals)
  build/editor_project/bsp/NNNN.bin        BSP file (stored as an uncompressed type-0x00 blob, bsp.stored_blob)
  build/editor_project/furniture/NNNN.bin  default furniture of room slot NNNN (24 bytes, patched into arm9.bin)
Nothing under /rom/ or rom_bin/ is ever written.

Item indices: scripts address an actor as (g, i) = item i (1-based) of group g (0-based) and waypoints link to
1-based items of their own group (docs/formats/layout.md). Deleting an item shifts the items after it, so those
references are renumbered. Data (all 32 layouts): every (g, i) reference is in a variant block and resolves inside
that block's own groups; block 0 scripts reference no item. But 30 references to group 0 of a variant would also
fit block 0's group 0, so for a block 0 item the references of the variant blocks count too, and a delete that
would have to renumber them refuses (ambiguous) instead.
"""
import argparse
import shutil
import struct
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import bsp  # noqa: E402
import layout  # noqa: E402
import layscript  # noqa: E402
import rebuild_rom  # noqa: E402
import rombin  # noqa: E402
import roomfurn  # noqa: E402
import s2data  # noqa: E402
from locations import read_table, NONE  # noqa: E402

DIR = ROOT / 'build' / 'editor_project'
ROM_DIR = ROOT / 'build' / 'editor_rom'
ROM_OUT = ROM_DIR / 'sims2_edited.nds'
KINDS = ('layout', 'bsp', 'furniture')
UNDO_MAX = 100

# (g, i) argument pairs of the item-addressing script ops (layscript.OPS; 'item' is an inventory item elsewhere)
ITEM_REFS = {}
for _op, (_n, _spec, _s, _d) in layscript.OPS.items():
    _ks = [f.split(':')[0] for f in _spec.split()]
    _pairs = [(a, b) for a, b in (('g', 'i'), ('g2', 'i2')) if a in _ks and b in _ks]
    if _op == 0x00:
        _pairs = [('group', 'item')]
    if _pairs:
        ITEM_REFS[_op] = _pairs

_lock = threading.RLock()
_undo = []          # (kind, entry, previous bytes or None = original)
_db = None


class EditError(ValueError):
    pass


def db():
    global _db
    if _db is None:
        _db = s2data.load()
    return _db


def _path(kind, entry):
    return DIR / kind / f'{entry:04d}.bin'


def original(kind, entry) -> bytes:
    if kind == 'furniture':
        o = roomfurn.DEFAULTS - roomfurn.ARM9_BASE + 24 * entry
        return roomfurn.arm9()[o:o + 24]
    return (layout.RAW / f'{entry:04d}.bin').read_bytes() if kind == 'layout' else db()[entry].data


def current(kind, entry) -> bytes:
    p = _path(kind, entry)
    return p.read_bytes() if p.exists() else original(kind, entry)


def edited() -> list:
    """[(kind, entry)] of the saved edits."""
    return [(k, int(p.stem)) for k in KINDS for p in sorted((DIR / k).glob('*.bin'))]


def _store(kind, entry, data: bytes):
    """Save new content (and push the old one on the undo stack). Content equal to the original drops the file."""
    p = _path(kind, entry)
    _undo.append((kind, entry, p.read_bytes() if p.exists() else None))
    del _undo[:-UNDO_MAX]
    if data == original(kind, entry):
        p.unlink(missing_ok=True)
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


def undo():
    with _lock:
        if not _undo:
            raise EditError('nothing to undo')
        kind, entry, prev = _undo.pop()
        p = _path(kind, entry)
        if prev is None:
            p.unlink(missing_ok=True)
        else:
            p.write_bytes(prev)
        return kind, entry


def revert(kind, entry):
    with _lock:
        if _path(kind, entry).exists():
            _store(kind, entry, original(kind, entry))


def entries_of(loc: int):
    L = read_table()[loc]
    return (None if L['nav'] == NONE else L['nav']), L['bsp']


def shared_with(loc: int) -> list:
    """Other locations that use the same layout / BSP entry (an edit changes them too)."""
    nav, b = entries_of(loc)
    return [L['location'] for L in read_table() if L['location'] != loc and
            ((nav is not None and L['nav'] == nav) or L['bsp'] == b)]


# --- layout edits -----------------------------------------------------------------------------------------------
def load_layout(loc: int):
    nav, _ = entries_of(loc)
    if nav is None:
        raise EditError('this location has no layout')
    return nav, layout.parse(current('layout', nav))


def _save_layout(nav, lay):
    data = layout.write(lay)
    layout.parse(data)                       # every invariant of the parser still holds
    _store('layout', nav, data)


def _item(lay, b, g, i):
    try:
        return lay.blocks[b].groups[g].items[i]
    except IndexError:
        raise EditError(f'no item {b}/{g}/{i}') from None


def _s16(v):
    v = int(round(v))
    if not -0x8000 <= v < 0x8000:
        raise EditError(f'{v} out of the s16 range')
    return v


def edit_item(loc, b, g, i, x=None, y=None, z=None, angle_deg=None, raw=None):
    """Move an item and / or set its angle (types 1, 2, 4: s16 degrees at +8) or its whole raw record
    (same size and type, so the group layout does not change)."""
    with _lock:
        nav, lay = load_layout(loc)
        it = _item(lay, b, g, i)
        if raw is not None:
            new = bytearray(bytes.fromhex(raw))
            if len(new) != len(it.raw) or new[6] != it.type:
                raise EditError(f'raw record must keep size {len(it.raw)} and type {it.type}')
            it.raw[:] = new
        if (x, y, z) != (None, None, None):
            it.set_pos(_s16(it.x if x is None else x), _s16(it.y if y is None else y), _s16(it.z if z is None else z))
        if angle_deg is not None:
            if it.type not in (1, 2, 4):
                raise EditError(f'type {it.type} has no angle')
            struct.pack_into('<h', it.raw, 8, _s16(angle_deg))
        _save_layout(nav, lay)


def duplicate_item(loc, b, g, i, dx=8, dz=8):
    """Copy an item to the end of its group (no index shifts), offset by (dx, dz). Returns its new index."""
    with _lock:
        nav, lay = load_layout(loc)
        it = _item(lay, b, g, i)
        items = lay.blocks[b].groups[g].items
        if len(items) >= 0xFF:
            raise EditError('group is full (255 items)')
        new = layout.Item(bytearray(it.raw))
        new.set_pos(_s16(it.x + dx), it.y, _s16(it.z + dz))
        if new.type == 9:                    # a copied waypoint starts unlinked
            for o in (10, 12, 14, 16):
                new.raw[o] = 0
        items.append(new)
        _save_layout(nav, lay)
        return len(items) - 1


def _blocks_seeing(lay, b):
    """Blocks whose scripts may address block b's items: b itself; for block 0, every block (see the docstring)."""
    return list(enumerate(lay.blocks)) if b == 0 else [(b, lay.blocks[b])]


def references(lay, b, g, i):
    """Script references to item i (0-based) of group g of block b: [(block, script, op index, desc)]."""
    out = []
    for bi, blk in _blocks_seeing(lay, b):
        for si, s in enumerate(blk.scripts):
            for k, (op, args) in enumerate(s):
                a = layscript.decode_args(op, args)
                for gk, ik in ITEM_REFS.get(op, ()):
                    if a[gk] == g and a[ik] == i + 1:
                        out.append((bi, si + 1, k, layscript.describe(op, args, block=blk)))
    return out


def delete_item(loc, b, g, i):
    """Remove an item; renumber the (g, i) script references and waypoint links that pointed after it."""
    with _lock:
        nav, lay = load_layout(loc)
        _item(lay, b, g, i)
        refs = references(lay, b, g, i)
        if refs:
            raise EditError('referenced by scripts: ' + '; '.join(f'block {r[0]} script {r[1]}: {r[3]}' for r in refs[:4]))
        n = len(lay.blocks[b].groups[g].items)
        for bi, blk in _blocks_seeing(lay, b):
            for si, s in enumerate(blk.scripts):
                for k, (op, args) in enumerate(s):
                    a = layscript.decode_args(op, args)
                    for gk, ik in ITEM_REFS.get(op, ()):
                        if a[gk] == g and i + 1 < a[ik] <= n:
                            if bi != b:
                                raise EditError(f'block {bi} script {si + 1} addresses item {a[ik]} of group {g}, '
                                                f'maybe this one: ambiguous, not renumbered (move the item away instead)')
                            off = _arg_offset(op, ik)
                            new = bytearray(args)
                            new[off] -= 1
                            s[k] = (op, bytes(new))
                            args = s[k][1]
        items = lay.blocks[b].groups[g].items
        del items[i]
        for w in items:
            if w.type == 9:
                for o in (10, 12, 14, 16):
                    if w.raw[o] == i + 1:
                        w.raw[o] = 0
                    elif w.raw[o] > i + 1:
                        w.raw[o] -= 1
        _save_layout(nav, lay)


def _arg_offset(op, name):
    p = 0
    for f in layscript.OPS[op][1].split():
        k, t = f.split(':')
        if k == name:
            return p
        p += layscript._FMT[t][1]
    raise KeyError(name)


def edit_entry(loc, k, x=None, y=None, z=None, angle_rad=None):
    """Move an entry point (s16 x, y, z) and / or set its angle (s16, 4096 = 1 radian, as Map_LoadNav reads it)."""
    with _lock:
        nav, lay = load_layout(loc)
        try:
            e = lay.entries[k]
        except IndexError:
            raise EditError(f'no entry point {k}') from None
        ox, oy, oz, oa = struct.unpack_from('<4h', e)
        struct.pack_into('<4h', e, 0, _s16(ox if x is None else x), _s16(oy if y is None else y),
                         _s16(oz if z is None else z), _s16(oa if angle_rad is None else angle_rad * 4096))
        _save_layout(nav, lay)


# --- BSP edits --------------------------------------------------------------------------------------------------
def load_bsp(loc: int):
    _, b = entries_of(loc)
    return b, bsp.parse(current('bsp', b))


def _save_bsp(entry, t):
    data = bsp.write(t)
    errs = bsp.check(bsp.parse(data))
    if errs:
        raise EditError(f'edited BSP breaks an invariant: {errs[0]}')
    _store('bsp', entry, data)


def _cell(t, p):
    r = bsp.find_cell(t, p)
    if r is None:
        raise EditError('no solid cell at that point')
    return r


def bsp_delete(loc, p):
    with _lock:
        entry, t = load_bsp(loc)
        bsp.delete_cell(t, _cell(t, p)[0])
        _save_bsp(entry, t)


def bsp_move(loc, p, delta):
    with _lock:
        entry, t = load_bsp(loc)
        leaf, path = _cell(t, p)
        bsp.move_cell(t, leaf, path, delta)
        _save_bsp(entry, t)


def bsp_box(loc, lo, hi):
    with _lock:
        if any(a >= b for a, b in zip(lo, hi)):
            raise EditError('box: every lo must be < hi')
        entry, t = load_bsp(loc)
        if bsp.add_box(t, lo, hi) == 0:
            raise EditError('the box lies entirely inside existing solid cells')
        _save_bsp(entry, t)


# --- default room furniture -------------------------------------------------------------------------------------
def furniture_slot(loc: int):
    locs = roomfurn.room_locations()
    return locs.index(loc) if loc in locs else None


def furniture_items(slot: int) -> list:
    d = current('furniture', slot)
    return [tuple(d[4 * i:4 * i + 4]) for i in range(roomfurn.N_DEFAULT)]


def edit_furniture(loc, i, prop=None, x=None, z=None, rot=None):
    """Change default furniture entry i of a room: prop id, grid cell (x, z) or wall slot (x) + cell (z), rotation.
    Only new games pick it up (Room_InitDefaultFurniture copies it into the game state)."""
    with _lock:
        slot = furniture_slot(loc)
        if slot is None:
            raise EditError('this location has no default furniture')
        items = furniture_items(slot)
        if not 0 <= i < len(items):
            raise EditError(f'no furniture entry {i}')
        new = [v if n is None else int(n) for v, n in zip(items[i], (prop, x, z, rot))]
        if not 0 <= new[0] < roomfurn.N_PROPS:
            raise EditError(f'prop id {new[0]} out of range 0..{roomfurn.N_PROPS - 1}')
        if not roomfurn.is_furniture(new[0]):
            raise EditError(f'prop {new[0]} is not furniture (no placement object in Prop_CreatePlacementObject); '
                            'room lists only take ' + ', '.join(f'{a}-{b}' if a != b else f'{a}' for a, b in
                                                               sorted(roomfurn.FLOOR_PROPS + roomfurn.WALL_PROPS)))
        if not all(0 <= v <= 255 for v in new[1:]) or new[3] > 3:
            raise EditError('x, z must be 0..255 and rot 0..3')
        grid = roomfurn.load_grid(roomfurn.grid_entries()[slot])
        wall = (roomfurn.placement(new[0]) or (0,))[0]
        if wall and new[1] >= grid.n_walls:
            raise EditError(f'wall-mounted prop: x is a wall slot, this room has {grid.n_walls} (0..{grid.n_walls - 1})')
        if not wall and (new[1] >= grid.width or new[2] >= grid.depth):
            raise EditError(f'cell ({new[1]}, {new[2]}) outside the room grid ({grid.width} x {grid.depth})')
        items[i] = tuple(new)
        _store('furniture', slot, b''.join(bytes(t) for t in items))


def patched_arm9() -> bytes:
    a9 = bytearray(roomfurn.arm9())
    for kind, e in edited():
        if kind == 'furniture':
            o = roomfurn.DEFAULTS - roomfurn.ARM9_BASE + 24 * e
            a9[o:o + 24] = _path(kind, e).read_bytes()
    return bytes(a9)


# --- build ------------------------------------------------------------------------------------------------------
def build_rombin() -> bytes:
    """Original rom.bin entries with the edited ones substituted."""
    entries = rombin.read_entries(rombin.DEFAULT_ROMBIN.read_bytes())
    for kind, e in edited():
        if kind == 'furniture':
            continue
        d = _path(kind, e).read_bytes()
        entries[e] = d + bytes(-len(d) & 3) if kind == 'layout' else bsp.stored_blob(d)
    return rombin.build(entries)


def build_rom(out: Path = ROM_OUT) -> dict:
    """rom.bin with the edits -> copy of the unpacked tree (made once) -> ndstool -> out."""
    with _lock:
        data = build_rombin()
        work = ROM_DIR / 'unpacked'
        if not (work / 'arm9.bin').exists():
            if work.exists():
                shutil.rmtree(work)
            shutil.copytree(ROOT / 'rom', work)
        (work / 'data' / 'rom.bin').write_bytes(data)
        (work / 'arm9.bin').write_bytes(patched_arm9())     # rebuild() then clears compressed_static_end again
        rebuild_rom.rebuild(work, out)
        return {'rom': str(out), 'size': out.stat().st_size, 'edits': [f'{k} {e}' for k, e in edited()]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['status', 'build', 'reset'])
    a = ap.parse_args()
    if a.cmd == 'status':
        for k, e in edited():
            print(k, e)
        print(f'{len(edited())} edited entries')
    elif a.cmd == 'build':
        r = build_rom()
        print(f"built {r['rom']} ({r['size']} bytes), edits: {', '.join(r['edits']) or 'none'}")
    else:
        for k in KINDS:
            shutil.rmtree(DIR / k, ignore_errors=True)
        print('all edits dropped')


if __name__ == '__main__':
    main()
