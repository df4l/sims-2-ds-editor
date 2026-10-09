"""Object info table (arm9): in-game name, icon sprite and price of every NPC and prop. Format: docs/formats/objinfo.md

  python tools/objinfo.py dump              # one line per NPC / prop: icon entries, name, price
  python tools/objinfo.py sheet out.png     # contact sheet of every NPC / prop icon (visual check)

Code (CONFIRMED, Ghidra 2026-10-09): 18-byte records at INFO = 0x02122A00, three accessors:
  Info_ByIndex 0x0208b000  INFO + 18*i              (State0E_ShowNextLine: narrator / player lines)
  Info_Npc     0x0208afe8  INFO + 18*(npc + 2)      (State0E_ShowNextLine: the speaker's portrait)
  Info_Prop    0x0208afd0  INFO + 18*(prop + 0x3B)  (Furn_InitPlacementBase: prop id = actor +10)
Record: u16 icon tiles, u16 icon def, u16 icon palette (rom.bin entries of a sprite triplet), u16 0, u16 text id,
        u16 picture, u16 picture (rom.bin, 0xFFFF = none), u16 price (ASSUMED), s16 +0x10 (read by
        Furn_InitPlacementBase, meaning unknown).
"""
import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
ARM9_BASE = 0x02000000
INFO = 0x02122A00
REC = 18
NPC_BASE, PROP_BASE = 2, 0x3B
N_NPC_INFO = 56             # NPCs 0..55 have their own record; 56.. (unused, player Sims) land on prop records
N_PROPS = 331
NO_ICON = 6180              # generic placeholder sprite shared by the records without an icon of their own

_arm9 = None


def arm9() -> bytes:
    global _arm9
    if _arm9 is None:
        _arm9 = (ROOT / 'rom' / 'arm9.bin').read_bytes()
    return _arm9


def record(i: int) -> dict:
    t, d, p, _, txt, pic, _, price, x10 = struct.unpack_from('<5H2HHh', arm9(), INFO - ARM9_BASE + REC * i)
    return {'tiles': t, 'def': d, 'pal': p, 'text': txt, 'picture': None if pic == 0xFFFF else pic,
            'price': price, 'x10': x10, 'icon': t != NO_ICON}


def npc(n: int) -> dict | None:
    """Info record of an NPC id, None for the ids without one (56 and up)."""
    return record(n + NPC_BASE) if 0 <= n < N_NPC_INFO else None


def prop(p: int) -> dict:
    return record(p + PROP_BASE)


def render_icon(r: dict):
    """PIL RGBA image of the first frame of the record's icon sprite, None if it does not decode."""
    import s2data
    import s2gfx
    import s2sprite
    from s2cmp import split_blobs
    db = s2data.load()
    try:
        blobs = [(b[1], b[3]) for b in split_blobs(db[r['tiles']].raw) or []]
        frames = s2sprite.parse(db[r['def']].data)
        s2sprite.check(frames[:1], blobs)
        return s2sprite.render(frames[0], blobs, s2gfx.palette(db[r['pal']].data[:32]))
    except (ValueError, IndexError):
        return None


def all_records():
    """(kind, id, record) for every NPC and prop that has a record."""
    return [('npc', n, npc(n)) for n in range(N_NPC_INFO)] + [('prop', p, prop(p)) for p in range(N_PROPS)]


def cmd_dump(_):
    import text
    for kind, i, r in all_records():
        print(f'{kind:4} {i:3}  icon {r["tiles"]:4} {r["def"]:4} {r["pal"]:4}{"" if r["icon"] else " (none)"}  '
              f'price {r["price"]:5}  {text.text(r["text"])}')


def cmd_sheet(a):
    from PIL import Image, ImageDraw
    cell, cols = 72, 16
    recs = all_records()
    sheet = Image.new('RGB', (cols * cell, -(-len(recs) // cols) * cell), (60, 60, 70))
    dr = ImageDraw.Draw(sheet)
    bad = []
    for k, (kind, i, r) in enumerate(recs):
        x, y = (k % cols) * cell, (k // cols) * cell
        im = render_icon(r) if r['icon'] else None
        if r['icon'] and im is None:
            bad.append((kind, i, r['tiles']))
        if im is not None:
            im.thumbnail((cell - 2, cell - 12))
            sheet.paste(im, (x + 1, y + 11), im)
        dr.text((x + 1, y), f'{kind[0]}{i}', fill=(255, 255, 0) if im else (255, 120, 120))
    sheet.save(a.out)
    print(f'{len(recs)} records, {sum(r["icon"] for _, _, r in recs)} with an icon, not decoded: {bad}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('dump').set_defaults(fn=cmd_dump)
    s = sub.add_parser('sheet')
    s.add_argument('out', type=Path)
    s.set_defaults(fn=cmd_sheet)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
