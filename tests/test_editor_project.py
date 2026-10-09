"""Editor edit layer (editor/project.py): edits, index renumbering, undo, rom.bin assembly. Uses a temp project dir."""
import shutil
import struct
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'editor'))
import project  # noqa: E402
import bsp  # noqa: E402
import layout  # noqa: E402
import rombin  # noqa: E402


project.DIR = Path(tempfile.mkdtemp(prefix='editor_project_'))   # never the real build/editor_project


def fresh(f):
    """Each test starts with no edit and an empty undo stack."""
    def run():
        shutil.rmtree(project.DIR, ignore_errors=True)
        project._undo.clear()
        f()
    run.__name__ = f.__name__
    return run


def raises(f, match=''):
    try:
        f()
    except project.EditError as e:
        assert match in str(e), e
        return
    raise AssertionError('EditError expected')


def lay(loc):
    return project.load_layout(loc)[1]


@fresh
def test_no_edits_rombin_identical():
    assert project.build_rombin() == rombin.DEFAULT_ROMBIN.read_bytes()


@fresh
def test_move_angle_undo():
    it0 = lay(5).blocks[0].groups[0].items[0]
    project.edit_item(5, 0, 0, 0, x=it0.x + 10, z=-3)
    it = lay(5).blocks[0].groups[0].items[0]
    assert (it.x, it.y, it.z) == (it0.x + 10, it0.y, -3)
    assert project.edited() == [('layout', project.entries_of(5)[0])]
    project.undo()
    assert project.edited() == [] and lay(5).blocks[0].groups[0].items[0].raw == it0.raw


@fresh
def test_entry_point():
    project.edit_entry(5, 0, x=1, y=2, z=3)
    assert struct.unpack_from('<3h', lay(5).entries[0]) == (1, 2, 3)
    raises(lambda: project.edit_entry(5, 0, x=40000))


@fresh
def test_duplicate_then_delete_is_identity():
    for loc in range(33):
        nav, _ = project.entries_of(loc)
        if nav is None:
            continue
        for b, blk in enumerate(lay(loc).blocks):
            for g, grp in enumerate(blk.groups):
                if not grp.items:
                    continue
                n = len(grp.items)
                assert project.duplicate_item(loc, b, g, 0) == n
                project.delete_item(loc, b, g, n)
                assert project.current('layout', nav) == project.original('layout', nav)


@fresh
def test_delete_renumbers_script_refs_and_waypoints():
    """Every deletable item of every layout: the result parses, and each (g, i) reference / waypoint link that
    pointed at an item after the deleted one now points at the same item."""
    done = refused = 0
    for loc in range(33):
        nav, _ = project.entries_of(loc)
        if nav is None or loc == 23:      # 23 shares its layout with 22
            continue
        orig = layout.parse(project.original('layout', nav))
        for b, blk in enumerate(orig.blocks):
            for g, grp in enumerate(blk.groups):
                for i in range(len(grp.items)):
                    try:
                        project.delete_item(loc, b, g, i)
                    except project.EditError:
                        refused += 1
                        continue
                    new = lay(loc)
                    old_items = grp.items[:i] + grp.items[i + 1:]
                    assert [x.raw[:8] for x in new.blocks[b].groups[g].items] == [x.raw[:8] for x in old_items]
                    for bi, (ob, nb) in enumerate(zip(orig.blocks, new.blocks)):
                        if bi != b:                     # other blocks are never renumbered
                            assert ob.scripts == nb.scripts
                            continue
                        for os_, ns in zip(ob.scripts, nb.scripts):
                            for (op, oa), (_, na) in zip(os_, ns):
                                for gk, ik in project.ITEM_REFS.get(op, ()):
                                    o = project.layscript.decode_args(op, oa)
                                    n = project.layscript.decode_args(op, na)
                                    want = o[ik] - 1 if o[gk] == g and i + 1 < o[ik] <= len(grp.items) else o[ik]
                                    assert n[ik] == want
                    project.undo()
                    done += 1
                assert project.current('layout', nav) == project.original('layout', nav)
    print(f'{done} deletes checked, {refused} refused (referenced)')
    assert done > 1000


@fresh
def test_delete_refuses_referenced_item():
    nav, L = project.entries_of(5)[0], lay(5)
    for b, blk in enumerate(L.blocks):
        for g, grp in enumerate(blk.groups):
            for i in range(len(grp.items)):
                if project.references(L, b, g, i):
                    raises(lambda: project.delete_item(5, b, g, i), 'referenced')
                    assert project.edited() == []
                    return
    raise AssertionError('no referenced item in location 5')


@fresh
def test_bsp_edits_and_rombin():
    entry, t = project.load_bsp(5)
    leaf, path = t.leaves()[0]
    vs = bsp.brush(leaf, path)
    p = [sum(v[k] for v in vs) / len(vs) for k in range(3)]
    project.bsp_move(5, p, (0, 10, 0))
    assert bsp.check(project.load_bsp(5)[1]) == []
    project.bsp_box(5, (-2000, -2000, -2000), (-1990, -1990, -1990))
    project.edit_item(5, 0, 0, 0, x=0)
    nav = project.entries_of(5)[0]
    entries = rombin.read_entries(project.build_rombin())
    assert entries[nav] == project.current('layout', nav)
    d = project.current('bsp', entry)
    assert entries[entry] == bsp.stored_blob(d) and entries[entry][:4] == struct.pack('<I', len(d) << 8)
    orig = rombin.read_entries(rombin.DEFAULT_ROMBIN.read_bytes())
    assert sum(a != b for a, b in zip(orig, entries)) == 2 and len(orig) == len(entries)


@fresh
def test_furniture_edit_validate_undo_arm9():
    import roomfurn
    orig = project.patched_arm9()
    assert orig == roomfurn.arm9()                           # no edit: arm9 untouched
    assert project.furniture_slot(5) is None and project.furniture_slot(8) == 0
    raises(lambda: project.edit_furniture(5, 0, x=1), 'no default furniture')
    raises(lambda: project.edit_furniture(8, 1, x=200), 'outside the room grid')     # bed: floor prop, grid 142 x 112
    raises(lambda: project.edit_furniture(8, 0, x=13), 'wall slot')                  # fridge: wall prop, 13 slots
    raises(lambda: project.edit_furniture(8, 1, rot=4), 'rot 0..3')
    project.edit_furniture(8, 1, x=20, z=6, rot=2)
    assert project.furniture_items(0)[1] == (114, 20, 6, 2)
    a9 = project.patched_arm9()
    o = roomfurn.DEFAULTS - roomfurn.ARM9_BASE
    diff = [k for k in range(len(a9)) if a9[k] != orig[k]]
    assert diff and all(o + 4 <= k < o + 8 for k in diff), diff
    project.undo()
    assert project.edited() == [] and project.patched_arm9() == orig


def test_typed_fields_round_trip_all_items():
    """Every item of the 32 files: writing back each typed field's own value leaves the record byte-identical."""
    n = 0
    for _, _, d in layout.layouts():
        for blk in layout.parse(d).blocks:
            for grp in blk.groups:
                for it in grp.items:
                    raw = bytes(it.raw)
                    for k, v in it.typed().items():
                        it.set(k, v)
                    assert bytes(it.raw) == raw, raw.hex()
                    n += 1
    assert n == 1290                     # 33 layouts (22 and 23 share one), as tests/test_layout.py


@fresh
def test_add_every_type_then_undo():
    nav = project.entries_of(5)[0]
    n0 = len(lay(5).blocks[0].groups[0].items)
    for t in layout.FIELDS:
        i = project.add_item(5, 0, 0, t, 10, 0, -20)
        it = lay(5).blocks[0].groups[0].items[i]
        assert (i, it.type, it.x, it.z, len(it.raw)) == (n0, t, 10, -20, layout.ITEM_SIZE[t])
        tpl = layout.new_item(t).typed()
        if t == 10:
            assert it.get('collect_bit') == 50                       # 0..49 used by the game
            tpl['collect_bit'] = 50
        assert it.typed() == tpl
        project.undo()
    assert project.current('layout', nav) == project.original('layout', nav)


@fresh
def test_add_typed_fields_and_refusals():
    i = project.add_item(5, 1, 0, 1, 0, 0, 0, {'npc': 22, 'angle_deg': 90})
    assert lay(5).blocks[1].groups[0].items[i].typed() == {'npc': 22, 'angle_deg': 90}
    raises(lambda: project.add_item(5, 0, 0, 1, 0, 0, 0, {'npc': 63}), '0..62')
    raises(lambda: project.add_item(5, 0, 0, 2, 0, 0, 0, {'prop': 256}), '0..255')
    raises(lambda: project.add_item(5, 0, 0, 6, 0, 0, 0), 'no constructor')
    raises(lambda: project.add_item(5, 0, 9, 2, 0, 0, 0), 'no group')
    ids = project.entry_ids(6)
    project.add_item(5, 0, 0, 4, 0, 0, 0, {'dest': 6, 'entry': ids[0]})
    raises(lambda: project.add_item(5, 0, 0, 4, 0, 0, 0, {'dest': 6, 'entry': 99}), 'no entry point 99')
    raises(lambda: project.add_item(5, 0, 0, 4, 0, 0, 0, {'dest': 40}), 'no such location')
    n_scripts = len(lay(5).blocks[1].scripts)
    raises(lambda: project.add_item(5, 1, 0, 3, 0, 0, 0, {'script': n_scripts + 1}), 'scripts')
    g = lay(5).blocks[0].groups[0].items
    not_wp = next(k for k, x in enumerate(g) if x.type != 9) + 1
    raises(lambda: project.add_item(5, 0, 0, 9, 0, 0, 0, {'link1': not_wp}), 'another waypoint')
    raises(lambda: project.add_item(5, 0, 0, 10, 0, 0, 0, {'collect_bit': 3}), 'already used')
    # editing a typed field goes through the same checks
    raises(lambda: project.edit_item(5, 1, 0, i, fields={'npc': 99}), '0..62')
    project.edit_item(5, 1, 0, i, fields={'npc': 23})
    assert lay(5).blocks[1].groups[0].items[i].get('npc') == 23


@fresh
def test_add_runtime_limits():
    """Location 13 variant 1 uses 1628 / 2048 arena bytes: 52 more items fit (8 bytes each), the 53rd is refused.
    Location 2 has 20 waypoints: 12 more fit in the 32-slot list."""
    for _ in range(52):
        project.add_item(13, 0, 0, 7, 0, 0, 0)
    assert layout.arena_size(lay(13), 1) == 2044
    raises(lambda: project.add_item(13, 0, 0, 7, 0, 0, 0), 'arena')
    for _ in range(12):
        project.add_item(2, 0, 0, 9, 0, 0, 0)
    raises(lambda: project.add_item(2, 0, 0, 9, 0, 0, 0), 'waypoints')


def test_room_furniture_matches_emulator():
    """World positions measured in RAM (actor +0x78/+0x7C/+0x80, +0x88) on 2026-10-07, fridge (wall) + bed (floor) per room."""
    import math
    import roomfurn
    seen = {8: [(-133.500, 0.0, -173.538, 3), (-94.463, 0.0, -169.097, 1)],
            29: [(-0.485, 0.0, 33.500, 0), (19.956, 0.0, 18.537, 0)],
            17: [(-1.483, 0.0, 55.497, 0), (-47.816, -3.0, 40.459, 3)],
            15: [(-4.565, 3.0, 84.612, 0), (-64.124, 0.0, 24.181, 2)],
            18: [(49.500, 0.0, 43.514, 1), (-88.044, 0.0, -16.819, 2)],
            20: [(-48.485, 0.0, 79.500, 0), (65.956, 0.0, 25.537, 0)]}
    for loc, exp in seen.items():
        items = roomfurn.room_furniture(loc)['items']
        for it, (x, y, z, q) in zip(items, exp):
            assert all(abs(a - b) < 2e-3 for a, b in zip(it['pos'], (x, y, z))), (loc, it)
            assert abs(it['angle'] - q * math.pi / 2) < 1e-9


if __name__ == '__main__':
    for t in [test_no_edits_rombin_identical, test_move_angle_undo, test_entry_point, test_duplicate_then_delete_is_identity,
              test_delete_renumbers_script_refs_and_waypoints, test_delete_refuses_referenced_item,
              test_bsp_edits_and_rombin, test_furniture_edit_validate_undo_arm9, test_typed_fields_round_trip_all_items,
              test_add_every_type_then_undo, test_add_typed_fields_and_refusals, test_add_runtime_limits,
              test_room_furniture_matches_emulator]:
        t()
        print(t.__name__, 'OK')
    shutil.rmtree(project.DIR, ignore_errors=True)
    print('OK')
