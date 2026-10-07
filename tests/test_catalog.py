"""Tests for the asset catalogue (run: .venv/Scripts/python tests/test_catalog.py).

Needs rom_bin/ (python tools/rombin.py extract). Checks the structural invariants the catalogue relies on,
on every entry, and that the counts do not silently drift when a rule is changed.
"""
import collections
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import s2data  # noqa: E402
import s2sprite  # noqa: E402
from gmd1 import parse as gmd1_parse, write as gmd1_write  # noqa: E402
from locations import read_table  # noqa: E402
from catalog import bg_composite, classify, gmd1, locations, sprite_blobs, sprite_def, u32  # noqa: E402


def main() -> None:
    db = s2data.load()
    cls = classify(db)
    assert len(cls) == len(db) and all(c is not None for c in cls), 'every entry classified'
    kinds = collections.Counter(c[0] for c in cls)

    sprites_ok = 0
    # every Nitro file: size field == decompressed size
    for e, (k, _, _) in zip(db, cls):
        if k.startswith('nitro_'):
            assert u32(e.data, 8) == len(e.data), f'{e.index}: Nitro size'
        if k == 'gmd1':
            assert gmd1(e.data), f'{e.index}: GMD1 layout'
            assert gmd1_write(gmd1_parse(e.data)) == e.data, f'{e.index}: GMD1 round-trip'
        if k == 'bsp':
            assert u32(e.data, 0xC) == len(e.data), f'{e.index}: BSP size field'
        if k == 'bg_composite' and e.blobs:
            assert bg_composite(e.data), f'{e.index}: bg layout'
        if k == 'sprite_def':
            assert sprite_def(e.data) and cls[e.index - 1][0] == 'sprite_tiles', f'{e.index}: sprite pair'
            if cls[e.index][1] == 'struct':  # frames + OBJ pieces parsed, every piece inside its tile data
                s2sprite.check(s2sprite.parse(e.data), sprite_blobs(db[e.index - 1]))
                sprites_ok += 1
    assert sprites_ok == 1188, sprites_ok
    print(f'structural invariants OK ({sprites_ok} sprites fully parsed)')

    # 32 bundles found in the data, 33 records in the arm9 table (22 and 23 share bsp/gmd1): they must agree
    locs = locations(cls)
    assert len(locs) == kinds['bsp'] == kinds['gmd1'] == 32
    table = read_table()
    assert len(table) == 33
    assert {L['bsp'] for L in table} == {L['bsp'] for L in locs}
    assert {L['gmd1'] for L in table} == {L['gmd1'] for L in locs}
    for L in table:
        assert cls[L['bsp']][0] == 'bsp' and cls[L['gmd1']][0] == 'gmd1' and cls[L['nav']][0] == 'loc_nav'
        for m in L['models']:
            assert cls[m['model']][0] == 'nitro_model', (L['location'], m['model'])
            for _kind, bta, trs in m['anims']:
                assert bta == 0xFFFF or cls[bta][0] in ('nitro_anim_srt', 'nitro_anim_joint'), (L['location'], bta)
                assert trs == 0xFFFF or cls[trs][0] == 'trs_anim', (L['location'], trs)
        assert gmd1_parse(db[L['gmd1']].data)
    print(f'{len(table)} locations OK (arm9 table agrees with the data)')

    expected = {'nitro_anim_joint': 2818, 'nitro_model': 329, 'sprite_def': 1192, 'bg_composite': 512,
                'trs_anim': 501, 'unknown': 229, 'text_bank': 6, 'loc_nav': 32}
    for k, n in expected.items():
        assert kinds[k] == n, f'{k}: {kinds[k]} != {n} (rule changed? update the expected counts)'
    print('counts OK:', dict(kinds.most_common()))


if __name__ == '__main__':
    main()
