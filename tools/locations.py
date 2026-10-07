"""3D locations of The Sims 2 DS, read from the table in arm9.bin. Format: docs/formats/location.md

  python tools/locations.py            # print the table, write rom_bin/locations.csv
  python tools/locations.py --sheet    # also render every GMD1 mesh (top view) into rom_bin/preview/locations.png

Table (CONFIRMED by code): u32 ptr[33] at 0x021332E0 (accessors FUN_02088200..FUN_02088280, used by the
location loader Map_LoadLocation 0x02084894). Record:
  +0x00 u16 bsp            entry, loaded decompressed (FUN_020d9bb4)
  +0x02 u16 gmd1           entry (no accessor in arm9: user not found yet)
  +0x04 u16 nav            entry, loaded raw, parsed by FUN_02053128 (0xFFFF = none)
  +0x06 u16 music[4]       picked by time of day? (<0x2A, 0x2A, >0x2A: three sound paths)
  +0x0E u16 model_count
  +0x10 u16 special_model  model index that gets flag 0x10000 (0xFFFF = none)
  +0x12 u16 ?              (lo byte, hi byte) passed to FUN_020b8a9c (0xFFFF = none)
  +0x14 model[model_count] 8 bytes: u32 ptr to anim list, u16 BMD0 entry, u16 anim count
anim list entry (6 bytes): u16 kind (200 or 309), u16 BTA0 entry (0xFFFF), u16 trs_anim entry (0xFFFF)
"""
import argparse
import csv
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARM9 = ROOT / 'rom' / 'arm9.bin'
BASE = 0x02000000
TABLE = 0x021332E0
COUNT = 33
NONE = 0xFFFF

# Place of each id = name of its first scene model (MDL0 name of rec model[0], tools/nitro.py), the data
# Map_LoadLocation loads for that id. The ids are sorted alphabetically by these names (dev location list).
# CONFIRMED 2026-10-05: walking through the City Hall door loads id 6 (world+0xF4 = 6, BSP 2067 resident)
# and shows the City Hall lobby. The previous visual labels (warp screenshots build/locations/loc_NN.png)
# were WRONG for several ids: those screenshots do not match their id (e.g. loc_06.png shows the casino = 4).
PLACES = [
    'AlienRoom (Gov Lab)', 'ArtGallery', 'Atrium', 'Basement', 'Casino', 'CityExterior (town, starting place)',
    'CityHall', 'CultRoom', 'DeluxeRoom (hotel)', 'Desert', 'Freezer', 'Furnace', 'Gym', 'HotelLobby', 'Jail',
    'JungleRoom (hotel)', 'LionLounge', 'ManagerSuite', 'ModernRoom (hotel)', 'Observatory', 'Penthouse',
    'RatCave (Cat Cave)', 'RoomBeingBuilt1', 'RoomBeingBuilt2', 'Saloon', 'SaloonRooms', 'SaxLounge',
    'SecondFloorLobby (hotel)', 'SecretWarehouse', 'SmHotelRoom', 'Store', 'SushiBar', 'Vault',
]


class _Mem:
    def __init__(self, data: bytes):
        self.d = data

    def u16(self, a):
        return struct.unpack_from('<H', self.d, a - BASE)[0]

    def u32(self, a):
        return struct.unpack_from('<I', self.d, a - BASE)[0]


def read_table(arm9: bytes = None) -> list:
    m = _Mem(arm9 if arm9 is not None else ARM9.read_bytes())
    out = []
    for loc in range(COUNT):
        p = m.u32(TABLE + 4 * loc)
        f = [m.u16(p + 2 * i) for i in range(10)]
        models = []
        for j in range(f[7]):
            lp, mdl, na = m.u32(p + 0x14 + 8 * j), m.u16(p + 0x18 + 8 * j), m.u16(p + 0x1A + 8 * j)
            anims = [tuple(m.u16(lp + 6 * i + 2 * q) for q in range(3)) for i in range(na)]
            models.append({'model': mdl, 'anims': anims})
        out.append({'location': loc, 'record': p, 'bsp': f[0], 'gmd1': f[1], 'nav': f[2], 'music': f[3:7],
                    'special_model': f[8], 'field12': f[9], 'models': models})
    return out


def write_csv(locs: list, path: Path) -> None:
    with open(path, 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['location', 'place', 'record', 'bsp', 'gmd1', 'nav', 'music', 'special_model', 'field12', 'models',
                    'anims (kind:bta0:trs)'])
        for L in locs:
            w.writerow([L['location'], PLACES[L['location']], f'0x{L["record"]:08X}', L['bsp'], L['gmd1'],
                        '' if L['nav'] == NONE else L['nav'], ' '.join(map(str, L['music'])),
                        '' if L['special_model'] == NONE else L['special_model'], f'0x{L["field12"]:04X}',
                        ' '.join(str(m['model']) for m in L['models']),
                        ' | '.join(' '.join(':'.join('' if x == NONE else str(x) for x in a) for a in m['anims'])
                                   for m in L['models'])])


def sheet(locs: list, out: Path) -> None:
    import s2data
    from gmd1 import parse, render
    from PIL import Image, ImageDraw
    db = s2data.load()
    S, W = 256, 6
    img = Image.new('RGB', (W * S, ((len(locs) + W - 1) // W) * (S + 14)), (40, 40, 40))
    dr = ImageDraw.Draw(img)
    for n, L in enumerate(locs):
        top = render(parse(db[L['gmd1']].data), S).crop((0, 0, S, S))
        x, y = (n % W) * S, (n // W) * (S + 14)
        img.paste(top, (x, y))
        dr.text((x + 3, y + S), f'loc {L["location"]}  gmd1 {L["gmd1"]}  bsp {L["bsp"]}', fill=(255, 255, 0))
    img.save(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sheet', action='store_true')
    a = ap.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    locs = read_table()
    for L in locs:
        print(f'{L["location"]:2} bsp={L["bsp"]:4} gmd1={L["gmd1"]:4} nav={L["nav"]:5} music={L["music"]} '
              f'models={[m["model"] for m in L["models"]]}')
    write_csv(locs, ROOT / 'rom_bin' / 'locations.csv')
    if a.sheet:
        out = ROOT / 'rom_bin' / 'preview' / 'locations.png'
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet(locs, out)
        print(f'wrote {out}')


if __name__ == '__main__':
    main()
