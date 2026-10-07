"""Location layout files (tools/layout.py): round-trip and invariants on every file, model ids resolve."""
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import layout  # noqa: E402


def test_roundtrip_and_models():
    kinds = {int(r['index']): r['kind'] for r in csv.DictReader(open(ROOT / 'rom_bin' / 'catalog.csv'))}
    files = items = models = 0
    for L, idx, d in layout.layouts():
        lay = layout.parse(d)              # raises on any broken invariant
        assert layout.write(lay) == d, idx
        files += 1
        for b in lay.blocks:
            for g in b.groups:
                for it in g.items:
                    items += 1
                    m = layout.model_of(it)
                    if m is not None:
                        assert kinds[m] == 'nitro_model', (idx, it.raw.hex(), m)
                        models += 1
    assert files == 33 and items > 1200 and models > 100
    print(f'{files} layouts, {items} items, {models} model references OK')


def test_waypoint_links():
    """Waypoint links are 1-based item indices of another waypoint in the same group (579/579)."""
    n = 0
    for L, idx, d in layout.layouts():
        for b in layout.parse(d).blocks:
            for g in b.groups:
                for i, it in enumerate(g.items):
                    if it.type == 9:
                        for link in it.fields()['links']:
                            if link:
                                assert 1 <= link <= len(g.items) and link != i + 1, (idx, i, link)
                                assert g.items[link - 1].type == 9, (idx, i, link)
                                n += 1
    assert n > 500


def test_edit_moves_item():
    L, idx, d = next(layout.layouts())
    lay = layout.parse(d)
    it = lay.blocks[0].groups[0].items[0]
    it.set_pos(it.x + 1, it.y, it.z)
    again = layout.parse(layout.write(lay)).blocks[0].groups[0].items[0]
    assert again.x == it.x and len(layout.write(lay)) == len(d)


def test_edit_script():
    """Scripts are parsed and rebuilt: adding an opcode shifts the args and the c4/c5/c6 tables consistently."""
    for L, idx, d in layout.layouts():
        lay = layout.parse(d)
        b = next((b for b in lay.blocks if b.scripts and b.counts[3]), None)
        if b is None:
            continue
        tables = b.tables
        b.scripts[0].append((0x14, bytes([0x7F, 1, 0, 0])))     # set_flag(0x7F, 1)
        b.scripts.append([(0x16, bytes([1, 2, 0, 0]))])          # new script: spawn_run(1, 2)
        again = layout.parse(layout.write(lay))
        b2 = again.blocks[lay.blocks.index(b)]
        assert b2.scripts[0][-1] == (0x14, bytes([0x7F, 1, 0, 0])) and len(b2.scripts) == len(b.scripts)
        assert b2.tables == tables
        return
    raise AssertionError('no block with scripts and c6 table')


def test_actor_anims_and_goals():
    """Op 0x0E: (g 0-based, i 1-based) resolves to an NPC/prop whose list has the animation id (29/33 non-player);
    0x21 starts every one of the 34 mission goals of GOAL_TABLE."""
    import layscript
    ok = bad = 0
    started = []
    for L, idx, d in layout.layouts():
        for b in layout.parse(d).blocks:
            for s in b.scripts:
                for op, a in s:
                    x = layscript.decode_args(op, a)
                    if op == 0x21:
                        started.append(x['goal'])
                    if op == 0x0E and x['g'] != 0xFF:
                        if layscript.actor_anim_name(b, x['g'], x['i'], x['anim']):
                            ok += 1
                        else:
                            bad += 1
    assert (ok, bad) == (29, 4), (ok, bad)   # the 4 misses: jail door (prop 1) id 79
    n = [layscript._a9(layscript.GOAL_TABLE + 0x114 * m, '<BB') for m in range(4)]
    assert n == [(12, 0), (8, 12), (7, 20), (7, 27)]
    assert set(started) == set(range(34))   # goal 8 is started by 3 scripts, the others by 1


def test_npc_moods():
    """Op 0x1C: the mood's walk (0xDD + 4*mood) and idles (+1..+3) exist in the target NPC's animation list,
    for every use whose actor resolves to an NPC (mood 0 = the default ids 3 / 0)."""
    import layscript
    n = 0
    for L, idx, d in layout.layouts():
        for b in layout.parse(d).blocks:
            for s in b.scripts:
                for op, a in s:
                    if op != 0x1C:
                        continue
                    x = layscript.decode_args(op, a)
                    it = layscript.actor_item(b, x['g'], x['i'])
                    if it is None or it.type != 1:
                        continue
                    ids = layscript.anim_list(it)
                    want = [3, 0] if x['mood'] == 0 else [0xDD + 4 * x['mood'] + k for k in range(4)]
                    assert all(i in ids for i in want), (L, x)
                    n += 1
    assert n > 0


def test_location_and_door_ops():
    """Location table 0x0211F9EC (33 x {u16 price, u8 score, u8 parent}): priced = hotel rooms, each reached from
    a lobby (2 Atrium, 3 Basement, 13 Hotel Lobby, 27 2nd Floor Lobby; 33 = none). Location args of the ops are
    valid ids; 0x4D targets door items (type 4 with a door model); 0x25 / 0x41 scripts exist in the block."""
    import layscript
    rooms = [layscript._a9(0x0211F9EC + 4 * k, '<HBB') for k in range(33)]
    assert {k for k, (price, _, _) in enumerate(rooms) if price} == {0, 1, 4, 7, 8, 12, 15, 16, 18, 21, 26, 28, 31, 32}
    assert {par for _, _, par in rooms} <= {2, 3, 13, 27, 33}
    doors = 0
    for L, idx, d in layout.layouts():
        for b in layout.parse(d).blocks:
            for s in b.scripts:
                for op, a in s:
                    x = layscript.decode_args(op, a)
                    if 'location' in x:
                        assert x['location'] < 33, (L, hex(op), x)
                    if op in (0x25, 0x41):
                        assert 0 < x['script'] <= len(b.scripts), (L, x)
                    if op == 0x4D:
                        it = layscript.actor_item(b, x['g'], x['i'])
                        assert it is not None and it.type == 4 and it.fields()['object'] is not None, (L, x)
                        doors += 1
    assert doors == 12


if __name__ == '__main__':
    test_roundtrip_and_models()
    test_waypoint_links()
    test_edit_moves_item()
    test_edit_script()
    test_actor_anims_and_goals()
    test_npc_moods()
    test_location_and_door_ops()
    print('OK')
