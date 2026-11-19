"""Scan the ARM9 overlays for code that uses location ids (new location study).

Usage: python tools/ovscan.py [build/overlays]
Reports, per overlay: calls to location-related ARM9 functions, compares / movs with
0x20..0x22, literals pointing to location-indexed tables or to the game state pointer,
and loads at offset 0xF4 (world+0xF4 = current location id).
"""
import struct, sys, pathlib
from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB

BASE = 0x02149B40
FUNCS = {
    0x02084894: 'Map_LoadLocation', 0x020852f8: 'Map_FreeLocation', 0x02084cf8: 'Map_PlayLocationMusic',
    0x020844c4: 'Unk_LocField12', 0x02088200: 'Map_GetLocModelRec', 0x02088218: 'Map_GetLocField12',
    0x0208822c: 'Map_GetLocSpecialModel', 0x02088240: 'Map_GetLocModelCount', 0x02088254: 'Map_GetLocMusic',
    0x0208826c: 'Map_GetLocNavEntry', 0x02088280: 'Map_GetLocBspEntry', 0x02088048: 'Map_EnterLocation',
    0x02085548: 'Map_CreateLocationObject', 0x02076f00: 'State2_LocationEnter',
    0x02048108: 'Game_RequestState', 0x02048128: 'Game_RequestStateOtherSlot',
    0x020733f0: 'Coll_GetScore', 0x020734a0: 'Coll_SetOwned', 0x02073580: 'Coll_SetSeen',
    0x02073444: 'Coll_LinkStoryFlag', 0x0207355c: 'Coll_IsOwned', 0x02064f18: 'Game_InitNewGame',
    0x020643fc: 'Door_TryEnter', 0x0205f2d0: 'Hotel_AddDust', 0x02063c68: 'Fire_StartInLocation',
    0x02087df4: 'Map_SpawnRoomFurniture', 0x02073f8c: 'Room_SlotFromLocation',
    0x02085df8: 'Map_SetLocationLightKeys', 0x0205ee88: 'Hotel_DustOnLocationEnter',
    0x020637bc: 'Fire_OnLocationEnter', 0x0208387c: 'LocStateSpawnProps', 0x02076230: 'Map_UpdateLocationAmbience',
}
TABLES = {
    0x021332E0: 'loc table', 0x02121EFC: 'light keys', 0x02121EB4: 'variant table', 0x0211F9EC: 'price/score',
    0x02131F34: 'dust table', 0x0211F9D4: 'room slot table', 0x0213E434: 'S/G pointer',
}

SIZES = {0x021332E0: 33 * 4, 0x02121EFC: 34 * 16, 0x02121EB4: 12 * 6, 0x0211F9EC: 33 * 4,
         0x02131F34: 33, 0x0211F9D4: 6, 0x0213E434: 4}

def lits(data):
    for off in range(0, len(data) - 3, 4):
        v = struct.unpack_from('<I', data, off)[0]
        for t, name in TABLES.items():
            if t <= v < t + SIZES.get(t, 0x100):
                yield off, v, name

def scan(name, data, mode):
    md = Cs(CS_ARCH_ARM, mode); md.skipdata = True
    out = []
    for ins in md.disasm(data, BASE):
        if ins.mnemonic == '.byte':
            continue
        m, ops = ins.mnemonic, ins.op_str
        if m.startswith(('bl', 'blx')) and ops.startswith('#'):
            t = int(ops[1:], 16) & ~1
            if t in FUNCS:
                out.append((ins.address, f'{m} {FUNCS[t]}'))
        elif m.startswith(('cmp', 'mov', 'movs', 'cmn')) and ops.endswith(('#0x21', '#0x20', '#0x22', '#33')):
            out.append((ins.address, f'{m} {ops}'))
        elif m.startswith('ldr') and '#0xf4]' in ops:
            out.append((ins.address, f'{m} {ops}'))
    return out

def main():
  d = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/overlays')
  for f in sorted(d.glob('ov*.bin')):
      data = f.read_bytes()
      print(f'== {f.stem} ({len(data)} bytes)')
      for off, v, nm in lits(data):
          print(f'   lit  {BASE+off:08x}: {v:08x} ({nm})')
      for mode, tag in ((CS_MODE_ARM, 'arm'), (CS_MODE_THUMB, 'thumb')):
          for a, s in scan(f.stem, data, mode):
              if tag == 'thumb' and not s.startswith('bl'):
                  continue  # thumb compares are noise unless confirmed
              print(f'   {tag:5} {a:08x}: {s}')

if __name__ == '__main__':
    main()
