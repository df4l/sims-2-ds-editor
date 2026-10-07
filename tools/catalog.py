"""Asset catalogue of rom.bin (The Sims 2 DS) — phase 2. Format notes: docs/formats/catalog.md

  python tools/catalog.py                 # classify every entry -> rom_bin/catalog.csv + summary
  python tools/catalog.py --previews      # also write PNG previews to rom_bin/preview/<kind>/NNNN.png
  python tools/catalog.py --export        # also write decompressed files to rom_bin/by_kind/<kind>/ (.nsbmd...)
  python tools/catalog.py --show 0 709    # print the classification of some entries

Every rule is structural (a size/offset invariant checked on the data); the `evidence` column says how
strong it is: 'code' = layout confirmed in the ARM9 code, 'struct' = exact structural invariant,
'heur' = heuristic. Entries matching no rule are 'unknown' and grouped by leading bytes / size.
"""
import argparse
import collections
import csv
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s2data  # noqa: E402
import s2sprite  # noqa: E402
from s2cmp import split_blobs  # noqa: E402

ROOT = s2data.ROOT
NITRO = {b'BMD0': 'nitro_model', b'BCA0': 'nitro_anim_joint', b'BTA0': 'nitro_anim_srt',
         b'BVA0': 'nitro_anim_vis', b'BTX0': 'nitro_texture', b'BTP0': 'nitro_anim_pattern',
         b'BMA0': 'nitro_anim_material'}


def u16(d, o):
    return struct.unpack_from('<H', d, o)[0]


def u32(d, o):
    return struct.unpack_from('<I', d, o)[0]


# ---------------------------------------------------------------- structural tests

def sprite_def(d: bytes):
    """Sprite animation definition, read by FUN_02050014 (OBJ loader):
    u16@6 = frame count, u16 table at 0xC of frame offsets (relative to 0xC); frame: u16 ?, u8 w, u8 h, u16 tile offset.
    Returns the frame count or None."""
    if len(d) < 0x10 or not d[0] or not d[1] or u16(d, 2):
        return None
    n = u16(d, 6)
    if n == 0 or 0xC + 2 * n > len(d):
        return None
    for o in struct.unpack_from(f'<{n}H', d, 0xC):
        if 0xC + o + 6 > len(d):
            return None
    return n


def sprite_blobs(tiles_entry) -> list:
    """(offset in the raw entry, decompressed data) of each blob of a sprite_tiles entry."""
    return [(b[1], b[3]) for b in split_blobs(tiles_entry.raw)]


def is_pal16(d: bytes) -> bool:
    return 0 < len(d) <= 512 and len(d) % 32 == 0 and all(u16(d, i) < 0x8000 for i in range(0, len(d), 2))


def trs_anim(d: bytes):
    """Keyframe transform animation: u8 ?, u8 frames, u16 tracks, u16 flags (4|5), u16 ?,
    then frames*tracks records (48 bytes if flags=4, 36 if flags=5), 4 extra bytes per additional track."""
    if len(d) < 8:
        return None
    nf, nt, fl = d[1], u16(d, 2), u16(d, 4)
    rec = {4: 48, 5: 36}.get(fl)
    if not rec or nf == 0 or nt == 0:
        return None
    return (nf, nt, fl) if len(d) == 8 + nf * nt * rec + 4 * (nt - 1) else None


def gmd1(d: bytes):
    """'GMD1' u8 1 u8 2 u16 0, u32 count, u32 1, 'XFRM' + 36 bytes, 'FRAM', count * 16-byte records."""
    n = u32(d, 8)
    return n if d[16:20] == b'XFRM' and d[60:64] == b'FRAM' and len(d) == 64 + 16 * n else None


def bg_composite(d: bytes):
    """u16 flags; bit0: 16x16-colour palette (512 bytes); bit3: u16 w, u16 h (in tiles) + w*h u16 tilemap;
    then the tile section (u16 count, u16 table length, u16 ?, table, coded stream: codec unknown).
    Returns a description or None if the layout does not fit."""
    fl = u16(d, 0)
    if fl & 0xFF06 or not fl & 0x79:
        return None
    p = 2 + (512 if fl & 1 else 0)
    if p > len(d):
        return None
    det = f'flags=0x{fl:02X}'
    if fl & 8:
        if p + 4 > len(d):
            return None
        w, h = u16(d, p), u16(d, p + 2)
        p += 4 + 2 * w * h
        if not (0 < w <= 256 and 0 < h <= 256 and p <= len(d)):
            return None
        det += f' map={w}x{h}'
    if p + 6 <= len(d):
        det += f' tiles: n={u16(d, p)} table={u16(d, p + 2)}'
    return det


def trs_anim_loose(d: bytes):
    """Same header as trs_anim, records of variable size (36..64 bytes on average)."""
    if len(d) < 8:
        return None
    nf, nt, fl = d[1], u16(d, 2), u16(d, 4)
    if fl not in (4, 5) or nf == 0 or nt == 0:
        return None
    body = len(d) - 8
    if not 36 * nf * nt <= body <= 64 * nf * nt:
        return None
    return nf, nt, fl, body // (nf * nt)


def locations(cls: list) -> list:
    """Data-only view of the location bundles: every 'bsp' entry opens [bsp][trs_anim?][gmd1][nitro_model]...
    The authoritative list is the arm9 table (tools/locations.py); tests check that both agree."""
    out = []
    kinds = [c[0] for c in cls]
    for b, k in enumerate(kinds):
        if k != 'bsp':
            continue
        g = next(i for i in range(b + 1, b + 4) if kinds[i] == 'gmd1')
        m = g + 1 if kinds[g + 1] == 'nitro_model' else next(i for i in range(g + 1, g + 6) if kinds[i] == 'nitro_model')
        anim = [i for i in range(b + 1, g) if kinds[i] in ('trs_anim', 'unknown')]
        out.append({'location': len(out), 'bsp': b, 'gmd1': g, 'scene_model': m,
                    'pre_gmd1': ' '.join(f'{i}:{kinds[i]}' for i in anim)})
    return out


def stored0(d: bytes):
    """Blob of method 0 (plain copy in Cmp_Decompress): u32 0x00 | size<<8, then size bytes (+ <4 padding)."""
    if len(d) < 8 or d[0] != 0:
        return None
    size = u32(d, 0) >> 8
    return d[4:4 + size] if 4 < size <= len(d) - 4 < size + 4 else None


def text_bank(d: bytes):
    """Text bank (guess, 5 files ~100 KB = one per language?): u32 ?, u16 a, u16 a+1, then a strictly increasing
    list of u16 character codes (0x0A, 0x22.., Latin-1) closed by 0x100, then further sorted groups
    (canonical-Huffman-like symbol table); the rest is probably coded strings. Returns the first group length."""
    if len(d) < 1024 or u16(d, 2) != 0 or u16(d, 6) != u16(d, 4) + 1:
        return None
    k = 1
    while 8 + 2 * k + 2 <= len(d) and u16(d, 8 + 2 * k) > u16(d, 8 + 2 * k - 2):
        k += 1
    # the first sorted run ends with 0x100 (groups of symbols, like a canonical Huffman table)
    return k if k >= 16 and u16(d, 8 + 2 * (k - 1)) == 0x100 else None


SQUARES = {32 * 32: 32, 64 * 64: 64, 128 * 128: 128, 32 * 64: 32, 64 * 32: 64, 16 * 16: 16}


# ---------------------------------------------------------------- classification

def classify(db: list) -> list:
    n = len(db)
    out = [None] * n  # (kind, evidence, details)

    def put(i, kind, ev, det=''):
        if out[i] is None:
            out[i] = (kind, ev, det)

    for e in db:
        d = e.data
        if d[:4] in NITRO:
            put(e.index, NITRO[d[:4]], 'struct', f'size field={u32(d, 8)}')
        elif d[:4] == b'GMD1':
            r = gmd1(d)
            put(e.index, 'gmd1', 'struct' if r else 'heur', f'records={r}' if r else 'layout mismatch')
        elif d[:4] == b'BSP\0':
            ok = len(d) >= 0x18 and u32(d, 0xC) == len(d)
            put(e.index, 'bsp', 'struct' if ok else 'heur', f'version={u32(d, 4)}')

    for e in db:  # before the sprite rule: text banks also pass the loose sprite_def test
        if out[e.index] is None and not e.blobs and text_bank(e.data):
            put(e.index, 'text_bank', 'heur', f'alphabet={text_bank(e.data)} codes')

    # sprite triplets: [tiles (compressed)] [definition (raw)] [palette 32 bytes (raw), optional]
    for e in db:
        i = e.index
        if out[i] or e.blobs or i == 0:
            continue
        nf = sprite_def(e.data)
        prev = db[i - 1]
        if nf is None or not prev.blobs or out[i - 1]:
            continue
        gsize = u32(e.data, 8)
        tot = sum(len(b) for b in prev.blobs)
        if len(prev.blobs) == 1:
            ev = 'struct' if tot == gsize else 'heur'
            det = f'frames={nf} tiles={tot}' + ('' if tot == gsize else f' (def says {gsize})')
        else:
            # one compressed blob per frame; u32@8 & 0xFFFFFF = largest frame (buffer size), bit 24 = flag (?)
            ok = max(len(b) for b in prev.blobs) == gsize & 0xFFFFFF
            ev = 'struct' if ok else 'heur'
            det = f'frames={nf} streamed blobs={len(prev.blobs)} max={max(len(b) for b in prev.blobs)} flag={gsize >> 24}'
        try:  # full frame/piece parse: every OBJ piece must lie inside its tile data
            s2sprite.check(s2sprite.parse(e.data), sprite_blobs(prev))
            det += ' pieces OK'
        except ValueError as ex:
            ev, det = 'heur', det + f' (frame layout variant: {ex})'
        put(i, 'sprite_def', ev, det)
        put(i - 1, 'sprite_tiles', ev, det)
        if i + 1 < n and not db[i + 1].blobs and is_pal16(db[i + 1].data) and out[i + 1] is None:
            put(i + 1, 'sprite_pal', 'struct', f'{len(db[i + 1].data) // 32} x 16 colours')

    for e in db:
        if out[e.index] or e.blobs:
            continue
        r = trs_anim(e.data)
        if r:
            put(e.index, 'trs_anim', 'struct', 'frames=%d tracks=%d flags=%d' % r)
        elif trs_anim_loose(e.data):
            put(e.index, 'trs_anim', 'heur', 'frames=%d tracks=%d flags=%d ~%d bytes/record (variable records)'
                % trs_anim_loose(e.data))
        elif is_pal16(e.data):
            put(e.index, 'pal16', 'heur', f'{len(e.data) // 32} x 16 colours')

    for e in db:
        if out[e.index] or not e.blobs or len(e.blobs) != 1:
            continue
        d = e.data
        if len(d) > 512 and len(d) - 512 in SQUARES:
            put(e.index, 'img8_pal256', 'heur', f'256-colour palette + {SQUARES[len(d) - 512]}px wide 8bpp')
        elif len(d) == 4108 and u16(d, 0) == 64 and u16(d, 2) == 64:
            put(e.index, 'img8_hdr', 'heur', 'w=64 h=64 + 12-byte header')
        elif len(d) == 4096:
            put(e.index, 'img8_nopal', 'heur', '64x64 8bpp, palette elsewhere')
        elif d[1] == 0 and d[0] in (0x78, 0x79, 0xF9, 0x71, 0xC1) and len(d) > 32:
            r = bg_composite(d)
            put(e.index, 'bg_composite', 'struct' if r else 'heur', r or f'flags=0x{d[0]:02X} layout mismatch')

    for e in db:
        if out[e.index] or e.blobs:
            continue
        d = e.data
        inner = stored0(d)
        if inner is not None:
            r = bg_composite(inner) if len(inner) > 2 and inner[1] == 0 else None
            if r:
                put(e.index, 'bg_composite', 'struct', r + ' (stored blob, type 0x00)')
            else:
                put(e.index, 'stored0', 'struct', f'type-0x00 blob, {len(inner)} bytes: {inner[:2].hex()}')
        elif text_bank(d):
            put(e.index, 'text_bank', 'heur', f'alphabet={text_bank(d)} codes')

    # location nav files: referenced by the location table in arm9 (Map_LoadLocation -> Map_LoadNav)
    import locations as loctab
    for L in loctab.read_table():
        if L['nav'] != loctab.NONE and out[L['nav']] is None:
            d = db[L['nav']].data
            put(L['nav'], 'loc_nav', 'code', f'location {L["location"]}: variants={d[0]} records={d[1]}')

    for i in range(n):
        if out[i] is None:
            e = db[i]
            put(i, 'unknown', '', f'{"c" if e.blobs else "r"}:{e.data[:2].hex()}')
    return out


def summarize(db, cls):
    by = collections.defaultdict(list)
    for e, (k, ev, _) in zip(db, cls):
        by[k].append(e)
    print(f'{"kind":<18} {"count":>6} {"stored":>10} {"unpacked":>10}  evidence')
    for k, es in sorted(by.items(), key=lambda kv: -len(kv[1])):
        evs = collections.Counter(cls[e.index][1] for e in es)
        print(f'{k:<18} {len(es):6} {sum(len(e.raw) for e in es):10} {sum(sum(map(len, e.blobs)) or len(e.raw) for e in es):10}'
              f'  {dict(evs)}')
    unk = collections.Counter(cls[e.index][2] for e in by.get('unknown', []))
    print('\nunknown, top groups:', unk.most_common(25))


def write_csv(path, db, cls):
    with open(path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['index', 'kind', 'evidence', 'stored', 'unpacked', 'blobs', 'details'])
        for e, (k, ev, det) in zip(db, cls):
            w.writerow([e.index, k, ev, len(e.raw), sum(map(len, e.blobs)) or len(e.raw), len(e.blobs), det])


def sprite_preview(db, cls, i: int, max_frames: int = 8):
    """Frames of the sprite whose tiles are entry i, side by side (pieces assembled as on the OBJ layer).
    Falls back to a flat tile sheet when the definition uses the unparsed frame-layout variant."""
    import s2gfx as g
    from PIL import Image
    pal_e = db[i + 2] if i + 2 < len(db) and cls[i + 2][0] == 'sprite_pal' else None
    pal = g.palette(pal_e.data) if pal_e else g.grey(16)
    blobs = sprite_blobs(db[i])
    try:
        frames = s2sprite.parse(db[i + 1].data)
        s2sprite.check(frames, blobs)
    except ValueError:
        w = max(1, db[i + 1].data[0] // 8)
        return g.tiles_to_image(b''.join(db[i].blobs), pal, 4, min(w, 16))
    imgs = [s2sprite.render(f, blobs, pal) for f in frames[:max_frames]]
    sheet = Image.new('RGBA', (sum(im.width + 2 for im in imgs), max(im.height for im in imgs)))
    x = 0
    for im in imgs:
        sheet.paste(im, (x, 0))
        x += im.width + 2
    return sheet


def previews(db, cls, out: Path, limit_per_kind: int = 400):
    import s2gfx as g
    count = collections.Counter()
    for e, (k, _, _) in zip(db, cls):
        if count[k] >= limit_per_kind:
            continue
        img = None
        d = e.data
        try:
            if k == 'sprite_tiles':
                img = sprite_preview(db, cls, e.index)
            elif k == 'img8_pal256':
                img = g.bitmap8(d[512:], g.palette(d[:512]), SQUARES[len(d) - 512])
            elif k == 'img8_nopal':
                img = g.bitmap8(d, g.grey(256), 64)
            elif k == 'img8_hdr':
                img = g.bitmap8(d[12:], g.grey(256), 64)
            elif k in ('pal16', 'sprite_pal'):
                img = g.bitmap8(bytes(range(len(d) // 2)), g.palette(d, False), 16)
        except Exception as ex:  # preview only: never fatal
            print(f'preview {e.index}: {ex}', file=sys.stderr)
        if img is not None:
            (out / k).mkdir(parents=True, exist_ok=True)
            g.save_scaled(img, out / k / f'{e.index:04d}.png')
            count[k] += 1


EXT = {'nitro_model': '.nsbmd', 'nitro_anim_joint': '.nsbca', 'nitro_anim_srt': '.nsbta', 'nitro_anim_vis': '.nsbva',
       'nitro_texture': '.nsbtx', 'nitro_anim_pattern': '.nsbtp', 'nitro_anim_material': '.nsbma'}


def export(db, cls, out: Path):
    """Decompressed content sorted by kind: <out>/<kind>/NNNN<ext> (multi-blob entries: NNNN_K<ext>)."""
    for e, (k, _, _) in zip(db, cls):
        d = out / k
        d.mkdir(parents=True, exist_ok=True)
        ext = EXT.get(k, '.bin')
        if len(e.blobs) > 1:
            for j, b in enumerate(e.blobs):
                (d / f'{e.index:04d}_{j}{ext}').write_bytes(b)
        else:
            (d / f'{e.index:04d}{ext}').write_bytes(e.data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--csv', type=Path, default=ROOT / 'rom_bin' / 'catalog.csv')
    ap.add_argument('--previews', action='store_true')
    ap.add_argument('--export', action='store_true', help='write decompressed files to rom_bin/by_kind/<kind>/')
    ap.add_argument('--show', type=int, nargs='*')
    a = ap.parse_args()
    db = s2data.load()
    cls = classify(db)
    if a.show:
        for i in a.show:
            print(i, cls[i])
        return
    write_csv(a.csv, db, cls)
    import locations as loctab
    loctab.write_csv(loctab.read_table(), a.csv.with_name('locations.csv'))
    print(f'{loctab.COUNT} locations (arm9 table) -> {a.csv.with_name("locations.csv")}')
    summarize(db, cls)
    if a.previews:
        previews(db, cls, ROOT / 'rom_bin' / 'preview')
    if a.export:
        export(db, cls, ROOT / 'rom_bin' / 'by_kind')


if __name__ == '__main__':
    main()
