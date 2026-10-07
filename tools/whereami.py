"""Identify the loaded 3D location from a main-RAM dump (4 x 1 MB files from MelonMCP dump_memory).

  python tools/whereami.py build/ram/g1        # reads g1_0.bin .. g1_3.bin (0x02000000..0x023FFFFF)

1. Pointer chain (code, see docs/formats/location.md §6): world = [0x0213E580]; id = world+0xF4,
   location object = world+0xFC (its +4 is the id again).
2. Cross-check by content: every BSP / GMD1 / nav entry of the 33 records is searched verbatim in RAM.
"""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from locations import read_table  # noqa: E402
from s2data import load  # noqa: E402

BASE = 0x02000000
WORLD_PTR = 0x0213E580      # static: -> world struct (FUN_02088048 writes +0xF4 / +0xFC)
GAME_PTR = 0x02139FA4       # static: -> game object (state machine, pending request at +0xDF0)


def read_ram(prefix: str) -> bytes:
    return b''.join(Path(f'{prefix}_{k}.bin').read_bytes() for k in range(4))


def main():
    ram = read_ram(sys.argv[1])
    u32 = lambda a: struct.unpack_from('<I', ram, a - BASE)[0]

    world = u32(WORLD_PTR)
    if BASE <= world < BASE + len(ram):
        obj = u32(world + 0xFC)
        oid = u32(obj + 4) if BASE <= obj < BASE + len(ram) else None
        print(f'world 0x{world:08X}: location id {u32(world + 0xF4)}, object 0x{obj:08X} (obj+4 = {oid})')
    else:
        print('world pointer not set (not in a 3D location)')
    game = u32(GAME_PTR)
    if BASE <= game < BASE + len(ram):
        st = u32(game + 0xDA8)
        if BASE <= st < BASE + len(ram):
            print(f'game 0x{game:08X}: slot-0 state {u32(st + 4)} args {[u32(st + 8 + 4 * i) for i in range(3)]}')

    db = load()
    locs = read_table()
    for field in ('bsp', 'gmd1', 'nav'):
        for idx in sorted({loc[field] for loc in locs}):
            data = db[idx].data
            pos = ram.find(data[:64])
            if pos >= 0:
                ids = [l['location'] for l in locs if l[field] == idx]
                full = ram[pos:pos + len(data)] == data
                print(f'{field:4} entry {idx:5} (loc {ids}) at 0x{BASE + pos:08X} full_match={full}')


if __name__ == '__main__':
    main()
