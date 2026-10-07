"""Location layout files (rec+4 of the location table, formerly called "nav"). Format: docs/formats/layout.md

  python tools/layout.py verify            # parse + write every layout file, byte-identical check, invariants
  python tools/layout.py dump 5            # human-readable dump of the layout of location 5
  python tools/layout.py csv               # every placed item of every location -> rom_bin/layout_items.csv
  python tools/layout.py doors             # door graph (type 4: destination location + entry point) -> rom_bin/doors.csv

Read by Map_LoadNav (0x02053128) / Map_ParseNavBlock (0x020528c0); items spawned by Nav_SpawnGroup
(0x020525f0) through the per-type constructor table at 0x0211E7E0 (Nav_SpawnEntity 0x0203a700, type 9:
Nav_AddWaypoint 0x02053e38). Entry points looked up by Nav_FindEntryPoint (0x02052cd0).

File:   u8 n_blocks, u8 n_entries, u16 entries_size (= 16 * n_entries), entry[n_entries], block[n_blocks]
Block:  u16 size, u8 n_groups, u8 n_scripts, u8 n_c4, u8 n_c5, u8 n_c6, u8 pad,
        u16 off_scripts, u16 off_c4, u16 off_c5, u16 off_c6   (relative to block+0x10)
        group[n_groups] at +0x10, then the script / table area (kept raw here)
Group:  u16 size, u8 items_offset (= 4 + n + pad), u8 n, u8 item_size[n], pad to 4, items
Item:   s16 x, y, z (whole world units, the code does << 12), u8 type, u8 ?, type-specific payload
Only block 0 and the block selected at load time (Map_LoadNav param 3) are parsed by the game.
"""
import argparse
import csv
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from locations import read_table, NONE, PLACES  # noqa: E402
from nitro import model_name  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / 'rom_bin' / 'raw'

# item size per type, CONFIRMED by data (1290 items, one size per type) and by the readers in Nav_SpawnEntity
ITEM_SIZE = {0: 12, 1: 16, 2: 16, 3: 16, 4: 24, 5: 16, 7: 12, 8: 12, 9: 20, 10: 12, 11: 12}
ITEM_NAME = {0: 'none', 1: 'npc', 2: 'prop', 3: 'box13', 4: 'object_box', 5: 'zone5', 7: 'box', 8: 'unk8',
             9: 'waypoint', 10: 'timed_prop', 11: 'sound'}

# model tables used by the actor constructors: 8-byte records {u32 anim_list, u16 BMD0 entry, u16 anim_count}
NPC_MODELS = 0x02118310      # FUN_0200b448 (type 1)
PROP_MODELS = 0x0211CD2C     # FUN_02014c30 (types 2 and 10)
OBJECT_MODELS = 0x0211CC3C   # FUN_02010cb4 (type 4)


_ARM9 = None


def model_of(item) -> int | None:
    """BMD0 rom.bin entry drawn for an npc / prop / object / timed_prop item (None for the other types)."""
    global _ARM9
    f, t = item.fields(), item.type
    tbl, i = {1: (NPC_MODELS, f.get('id')), 2: (PROP_MODELS, f.get('id')), 10: (PROP_MODELS, f.get('prop')),
              4: (OBJECT_MODELS, f.get('object'))}.get(t, (None, None))
    if tbl is None or i is None:
        return None
    if _ARM9 is None:
        _ARM9 = (ROOT / 'rom' / 'arm9.bin').read_bytes()
    return struct.unpack_from('<H', _ARM9, tbl + 8 * i + 4 - 0x02000000)[0]


@dataclass
class Item:
    raw: bytearray

    x = property(lambda s: struct.unpack_from('<h', s.raw, 0)[0])
    y = property(lambda s: struct.unpack_from('<h', s.raw, 2)[0])
    z = property(lambda s: struct.unpack_from('<h', s.raw, 4)[0])
    type = property(lambda s: s.raw[6])

    def set_pos(self, x, y, z):
        struct.pack_into('<3h', self.raw, 0, x, y, z)

    def fields(self) -> dict:
        """Type-specific fields, as read by Nav_SpawnEntity / Nav_AddWaypoint."""
        r, t = self.raw, self.raw[6]
        s16 = lambda o: struct.unpack_from('<h', r, o)[0]
        if t in (1, 2):
            return {'angle_deg': s16(8), 'id': r[0xE]}
        if t == 3:   # Nav_SetTriggerBoxEvent / Nav_FireTriggerBox; group and script 1-based, 0 = none
            return {'half_size': (r[9] / 2, r[10] / 2, r[11] / 2), 'repeat': r[8], 'group': r[0xC], 'script': r[0xD]}
        if t == 4:   # Nav_SetDoorBoxTarget: destination location + entry point there
            return {'angle_deg': s16(8), 'dest': r[0xE], 'half_size': (r[0xF] / 2, r[0x10] / 2, r[0x11] / 2),
                    'entry': r[0x12], 'object': None if r[0x13] == 0x1E else r[0x13]}
        if t == 5:
            return {'size': (r[0xB], r[0xC], r[0xD]), 'radius': struct.unpack_from('<H', r, 8)[0]}
        if t == 7:
            return {'kind': r[8], 'half_size': (r[9] / 2, r[10] / 2, r[11] / 2)}
        if t == 8:
            return {'a': r[8], 'b': r[9], 'c': r[10]}
        if t == 9:
            return {'radius': r[8], 'links': [r[10], r[12], r[14], r[16]]}
        if t == 10:
            return {'prop': r[8] + 0x47, 'hour_slot': r[9], 'value': r[10], 'flag': r[11]}
        if t == 11:
            return {'sound_slot': r[8]}
        return {}


@dataclass
class Group:
    b2: int
    items: list


@dataclass
class Block:
    counts: tuple          # n_scripts, n_c4, n_c5, n_c6 (n_groups / n_scripts come from the lists)
    pad: int               # byte at +7
    offs: tuple            # off_scripts, off_c4, off_c5, off_c6 as stored
    groups: list
    scripts: list          # script = list of (opcode, args bytes); args size per opcode = ARG_SIZE
    tables: bytes          # c4 / c5 / c6 tables after the script area, up to the end of the block (raw)
    tables_at: int         # block-relative offset of `tables` in the original file (to move their offsets)


# argument size per script opcode: table at 0x021229AC used by Nav_RunScript (CONFIRMED: in all 93 blocks the
# args of all scripts are contiguous, in script order, and end exactly where the next table starts)
_A9 = (ROOT / 'rom' / 'arm9.bin').read_bytes()
ARG_SIZE = _A9[0x021229AC - 0x02000000:][:0x52]


def parse_scripts(t: bytes, n: int):
    """Script area (Nav_ParseScripts): u16 arg_offset[n] (relative to the area), then per script u8 count,
    u8 opcode[count]; zero padding to 4 (block-relative); then the args. Returns (scripts, area length)."""
    offs = struct.unpack_from(f'<{n}H', t, 0)
    q, lists = 2 * n, []
    for _ in range(n):
        lists.append(t[q + 1:q + 1 + t[q]])
        q += 1 + t[q]
    scripts, end = [], q
    for o, ops in zip(offs, lists):
        s, p = [], o
        for op in ops:
            s.append((op, bytes(t[p:p + ARG_SIZE[op]])))
            p += ARG_SIZE[op]
        scripts.append(s)
        end = max(end, p)
    return scripts, (end if n else 0)


def write_scripts(scripts, start: int) -> bytes:
    """Inverse of parse_scripts; start = block-relative offset of the area (for the 4-byte alignment)."""
    if not scripts:
        return b''
    lists = b''.join(bytes([len(s)]) + bytes(op for op, _ in s) for s in scripts)
    head = 2 * len(scripts) + len(lists)
    head += -(start + head) & 3
    offs, args = [], bytearray()
    for s in scripts:
        offs.append(head + len(args))
        args += b''.join(a for _, a in s)
    area = struct.pack(f'<{len(offs)}H', *offs) + lists
    return area + bytes(head - len(area)) + args


@dataclass
class Layout:
    entries: list          # 16-byte entry points (raw bytearrays)
    blocks: list = field(default_factory=list)


def _u16(d, o):
    return struct.unpack_from('<H', d, o)[0]


def parse(d: bytes) -> Layout:
    nb, ne, es = d[0], d[1], _u16(d, 2)
    if es != 16 * ne:
        raise ValueError(f'entries_size {es} != 16 * {ne}')
    lay = Layout([bytearray(d[4 + 16 * i:20 + 16 * i]) for i in range(ne)])
    p = 4 + es
    for _ in range(nb):
        size = _u16(d, p)
        ng = d[p + 2]
        counts = tuple(d[p + 3:p + 7])
        offs = struct.unpack_from('<4H', d, p + 8)
        base, q, groups = p + 0x10, p + 0x10, []
        for _ in range(ng):
            gs, b2, n = _u16(d, q), d[q + 2], d[q + 3]
            lens = d[q + 4:q + 4 + n]
            if b2 != 4 + n + (-n & 3):
                raise ValueError(f'group at 0x{q:X}: items offset {b2} != {4 + n + (-n & 3)}')
            it, items = q + b2, []
            for L in lens:
                item = Item(bytearray(d[it:it + L]))
                if ITEM_SIZE.get(item.type) != L:
                    raise ValueError(f'item at 0x{it:X}: type {item.type} size {L}')
                items.append(item)
                it += L
            if it - q != gs:
                raise ValueError(f'group at 0x{q:X}: size {gs} != {it - q}')
            groups.append(Group(b2, items))
            q += gs
        if q - base != offs[0]:
            raise ValueError(f'block at 0x{p:X}: groups end 0x{q - base:X} != off_scripts 0x{offs[0]:X}')
        tail = bytes(d[q:p + size])
        scripts, area = parse_scripts(tail, counts[0])
        lay.blocks.append(Block(counts, d[p + 7], offs, groups, scripts, tail[area:], offs[0] + area))
        p += size
    if p != len(d):
        raise ValueError(f'blocks end at 0x{p:X}, file is 0x{len(d):X}')
    return lay


def write(lay: Layout) -> bytes:
    out = bytearray(struct.pack('<BBH', len(lay.blocks), len(lay.entries), 16 * len(lay.entries)))
    for e in lay.entries:
        out += e
    for b in lay.blocks:
        body = bytearray()
        for g in b.groups:
            n = len(g.items)
            hdr = 4 + n + (-n & 3)
            gbody = bytes(len(i.raw) for i in g.items) + bytes(-n & 3) + b''.join(i.raw for i in g.items)
            body += struct.pack('<HBB', hdr + len(gbody) - n - (-n & 3), hdr, n) + gbody
        off_scripts = len(body)
        body += write_scripts(b.scripts, off_scripts)
        # the c4 / c5 / c6 tables move with the end of the script area (stored offsets of empty tables too)
        delta = len(body) - b.tables_at
        offs = [off_scripts] + [o + delta for o in b.offs[1:]]
        body += b.tables
        counts = (len(b.scripts),) + tuple(b.counts[1:])
        out += struct.pack('<HB4BB4H', 0x10 + len(body), len(b.groups), *counts, b.pad, *offs) + body
    return bytes(out)


def layouts():
    """(location record, layout entry index, bytes) for every location with a layout file."""
    for L in read_table():
        if L['nav'] != NONE:
            yield L, L['nav'], (RAW / f'{L["nav"]:04d}.bin').read_bytes()


def cmd_verify(_):
    ok = bad = 0
    seen = set()
    for L, idx, d in layouts():
        if idx in seen:
            continue
        seen.add(idx)
        try:
            same = write(parse(d)) == d
        except ValueError as e:
            print(f'{idx:04d} (location {L["location"]}): PARSE ERROR {e}')
            bad += 1
            continue
        ok += same
        bad += not same
        if not same:
            print(f'{idx:04d} (location {L["location"]}): round-trip differs')
    print(f'{ok} layout files byte-identical, {bad} failures')
    return bad == 0


def cmd_dump(a):
    L = read_table()[a.location]
    lay = parse((RAW / f'{L["nav"]:04d}.bin').read_bytes())
    print(f'location {a.location}: layout entry {L["nav"]}, {len(lay.blocks)} blocks')
    for e in lay.entries:
        x, y, z, ang = struct.unpack_from('<4h', e)
        print(f'  entry point id {e[12]:2d}: pos ({x}, {y}, {z}) angle 0x{ang & 0xFFFF:04X}  rest {e[8:12].hex()} {e[13:].hex()}')
    for bi, b in enumerate(lay.blocks):
        print(f'  block {bi}: {len(b.groups)} groups, scripts={b.counts[0]} c4={b.counts[1]} c5={b.counts[2]} '
              f'c6={b.counts[3]}, {len(b.scripts)} scripts, tables {len(b.tables)} bytes')
        for gi, g in enumerate(b.groups):
            print(f'    group {gi}: {len(g.items)} items')
            for it in g.items:
                m = model_of(it)
                label = f' [{model_name(m)}]' if m else ''
                print(f'      {ITEM_NAME.get(it.type, it.type):>10} ({it.x:5d},{it.y:4d},{it.z:5d}){label} {it.fields()}')


def cmd_csv(_):
    path = ROOT / 'rom_bin' / 'layout_items.csv'
    with open(path, 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['location', 'layout', 'block', 'group', 'item', 'type', 'name', 'x', 'y', 'z', 'model', 'model_name', 'fields', 'raw'])
        n = 0
        for L, idx, d in layouts():
            for bi, b in enumerate(parse(d).blocks):
                for gi, g in enumerate(b.groups):
                    for ii, it in enumerate(g.items):
                        w.writerow([L['location'], idx, bi, gi, ii, it.type, ITEM_NAME.get(it.type, '?'),
                                    it.x, it.y, it.z, model_of(it), model_name(model_of(it)) if model_of(it) else '',
                                    it.fields(), it.raw.hex()])
                        n += 1
    print(f'{n} items -> {path}')


def cmd_doors(_):
    """Type 4 boxes: +0xE = destination location id, +0x12 = entry point id there (CONFIRMED: 145/147 targets
    exist, 142 have a door back; walking through DoorCityHall in location 5 loads location 6 entry 0)."""
    lays = {L['location']: (idx, parse(d)) for L, idx, d in layouts()}
    entries = {loc: {e[12] for e in lay.entries} for loc, (_, lay) in lays.items()}
    path = ROOT / 'rom_bin' / 'doors.csv'
    n = bad = 0
    with open(path, 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['location', 'place', 'block', 'group', 'item', 'door_model', 'x', 'y', 'z', 'dest', 'dest_place',
                    'entry', 'entry_exists'])
        for loc, (idx, lay) in sorted(lays.items()):
            for bi, b in enumerate(lay.blocks):
                for gi, g in enumerate(b.groups):
                    for ii, it in enumerate(g.items):
                        if it.type != 4:
                            continue
                        dest, entry = it.raw[0xE], it.raw[0x12]
                        m = model_of(it)
                        ok = entry in entries.get(dest, set())
                        w.writerow([loc, PLACES[loc], bi, gi, ii, model_name(m) if m else '', it.x, it.y, it.z, dest,
                                    PLACES[dest] if dest < len(PLACES) else '?', entry, ok])
                        n += 1
                        bad += not ok
    print(f'{n} door boxes -> {path} ({bad} with a missing entry point)')


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('verify').set_defaults(f=cmd_verify)
    p = sub.add_parser('dump')
    p.add_argument('location', type=int)
    p.set_defaults(f=cmd_dump)
    sub.add_parser('csv').set_defaults(f=cmd_csv)
    sub.add_parser('doors').set_defaults(f=cmd_doors)
    a = ap.parse_args()
    r = a.f(a)
    if r is False:
        sys.exit(1)


if __name__ == '__main__':
    main()
