"""Editor backend: turns the parsers of tools/ into JSON for the browser UI. No format logic lives here.

  location_json(loc, lang)  location table record + layout (entry points, blocks, items, scripts)
  bsp_json(loc)             collision brushes (tools/bsp.py to_obj, parsed back into vertices + faces)
  model_glb(entry)          BMD0 rom.bin entry converted to GLB by nitro.bmd0_to_glb (cached in build/editor_cache/models)
Layout and BSP are read through editor/project.py: the saved edit if there is one, else the original entry.
"""
import hashlib
import json
import struct
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'editor'))
import bsp  # noqa: E402
import layout  # noqa: E402
import project  # noqa: E402
import roomfurn  # noqa: E402
import layscript  # noqa: E402
import nitro  # noqa: E402
import s2data  # noqa: E402
import text  # noqa: E402
from locations import read_table, NONE, PLACES  # noqa: E402

CACHE = ROOT / 'build' / 'editor_cache'
FX = 4096

_db = None
_table = None
_lock = threading.Lock()


def db():
    global _db
    if _db is None:
        _db = s2data.load()
    return _db


def table():
    global _table
    if _table is None:
        _table = read_table()
    return _table


def locations_json():
    return [{'id': L['location'], 'place': PLACES[L['location']], 'bsp': L['bsp'],
             'nav': None if L['nav'] == NONE else L['nav']} for L in table()]


def _item_json(it):
    m = layout.model_of(it)
    f = it.fields()
    return {'type': it.type, 'type_name': layout.ITEM_NAME.get(it.type, str(it.type)),
            'x': it.x, 'y': it.y, 'z': it.z, 'angle_deg': f.get('angle_deg'), 'fields': f, 'typed': it.typed(),
            'model': m, 'model_name': nitro.model_name(m) if m is not None else None, 'raw': it.raw.hex()}


def _model_entry(tbl, i):
    return struct.unpack_from('<H', roomfurn.arm9(), tbl + 8 * i + 4 - roomfurn.ARM9_BASE)[0]


_palette = {}


def palette_json(lang='en'):
    """What the "add item" palette and the typed field editors offer: field specs + templates per type, the NPC /
    prop / object ids with names, and the locations with their entry point ids (door targets, edited layouts)."""
    if lang not in _palette:
        _palette[lang] = {
            'types': [{'type': t, 'name': layout.ITEM_NAME[t], 'size': layout.ITEM_SIZE[t],
                       'fields': [{'name': n, 'min': lo, 'max': hi} for n, _, _, lo, hi, _ in spec],
                       'template': layout.new_item(t).typed()} for t, spec in layout.FIELDS.items()],
            'npcs': [{'id': i, 'name': layscript.npc_name(i, lang), 'model': nitro.model_name(_model_entry(layout.NPC_MODELS, i))}
                     for i in range(layout.N_NPCS)],
            'props': [{'id': i, 'name': nitro.model_name(_model_entry(layout.PROP_MODELS, i))} for i in range(layout.N_PROPS)],
            'objects': [{'id': i, 'name': nitro.model_name(_model_entry(layout.OBJECT_MODELS, i))}
                        for i in range(layout.N_OBJECTS)] + [{'id': layout.N_OBJECTS, 'name': '(box only)'}],
            'limits': {'arena': layout.ARENA, 'waypoints': layout.MAX_WAYPOINTS}}
    return {**_palette[lang], 'entry_ids': [project.entry_ids(L['location']) for L in table()],
            'free_collect_bit': project.free_collect_bit()}


def _group_info(lay, b):
    """Per group of block b: the scripts that spawn it ((group, script) pairs of the script ops, 1-based group),
    the trigger boxes that do, and whether it is the permanent group (block 0 group 0)."""
    blk = lay.blocks[b]
    out = [{'permanent': b == 0 and g == 0, 'spawned_by': []} for g in range(len(blk.groups))]
    for si, s in enumerate(blk.scripts):
        for op, args in s:
            if op == 0x00:                           # despawn_item: its 'group' is a 0-based actor group
                continue
            a = layscript.decode_args(op, args)
            for k in ('group', 'else_group'):
                if 0 < a.get(k, 0) <= len(out):
                    out[a[k] - 1]['spawned_by'].append(f'script {si + 1} ({layscript.OPS[op][0]})')
    for grp in blk.groups:
        for it in grp.items:
            if it.type == 3 and 0 < it.get('group') <= len(out):
                out[it.get('group') - 1]['spawned_by'].append('trigger box')
    for o in out:
        o['spawned_by'] = list(dict.fromkeys(o['spawned_by']))   # script order, no repeats
    return out


def location_json(loc: int, lang='en'):
    L = table()[loc]
    ed = set(project.edited())
    out = {'id': loc, 'place': PLACES[loc], 'bsp': L['bsp'], 'nav': None if L['nav'] == NONE else L['nav'],
           'scene_models': [{'entry': m['model'], 'name': nitro.model_name(m['model'])} for m in L['models']],
           'entries': [], 'blocks': [], 'shared_with': project.shared_with(loc),
           'edited': {'layout': ('layout', L['nav']) in ed, 'bsp': ('bsp', L['bsp']) in ed}}
    slot = project.furniture_slot(loc)
    out['furniture'] = None if slot is None else furniture_json(loc, slot)
    out['edited']['furniture'] = slot is not None and ('furniture', slot) in ed
    if L['nav'] == NONE:
        return out
    lay = layout.parse(project.current('layout', L['nav']))
    for e in lay.entries:
        x, y, z, ang = struct.unpack_from('<4h', e)
        out['entries'].append({'id': e[0xC], 'x': x, 'y': y, 'z': z, 'angle_rad': ang / FX})
    for bi, b in enumerate(lay.blocks):
        out['blocks'].append({
            'groups': [[_item_json(it) for it in g.items] for g in b.groups], 'group_info': _group_info(lay, bi),
            'scripts': [[layscript.describe(op, args, lang, b) for op, args in s] for s in b.scripts]})
    out['limits'] = [{'variant': v, 'arena': layout.arena_size(lay, v), 'waypoints': layout.waypoint_count(lay, v)}
                     for v in range(len(lay.blocks))]
    return out


def furniture_json(loc: int, slot: int):
    """Default room furniture (arm9 table, edited copy if any) placed on the room grid like the game does."""
    r = roomfurn.room_furniture(loc, items=project.furniture_items(slot))
    g = roomfurn.load_grid(r['grid_entry'])
    out = {'slot': slot, 'grid_entry': r['grid_entry'], 'grid': {'width': g.width, 'depth': g.depth,
           'origin': g.origin, 'cell': roomfurn.CELL, 'walls': g.n_walls}, 'items': []}
    for it in r['items']:
        m = struct.unpack_from('<H', roomfurn.arm9(), roomfurn.PROP_MODELS + 8 * it['prop'] + 4 - roomfurn.ARM9_BASE)[0]
        pos = it['pos'] or (None, None, None)
        out['items'].append({'index': it['index'], 'prop': it['prop'], 'cell': [it['x'], it['z']], 'rot': it['rot'],
                             'wall': bool(it['wall']), 'exact': it['exact'], 'placed': it['pos'] is not None,
                             'x': pos[0], 'y': pos[1], 'z': pos[2], 'angle_rad': it['angle'],
                             'along': (('z' if g.wall(it['x'])[1] & 1 else 'x') if it['wall'] and it['pos'] else None),
                             'model': m, 'model_name': nitro.model_name(m)})
    out['props'] = furniture_props()
    return out


_furn_props = None


def furniture_props():
    """Every prop id a room list can take: [{prop, name, wall}] (tools/roomfurn.py is_furniture / placement)."""
    global _furn_props
    if _furn_props is None:
        _furn_props = []
        for p in range(roomfurn.N_PROPS):
            if roomfurn.is_furniture(p):
                m = struct.unpack_from('<H', roomfurn.arm9(), roomfurn.PROP_MODELS + 8 * p + 4 - roomfurn.ARM9_BASE)[0]
                _furn_props.append({'prop': p, 'name': nitro.model_name(m), 'wall': bool(roomfurn.placement(p)[0])})
    return _furn_props


def _obj_to_brushes(obj: str):
    brushes, cur, base = [], None, 1
    for line in obj.splitlines():
        k, _, rest = line.partition(' ')
        if k == 'o':
            if cur:
                base += len(cur['verts'])
            cur = {'leaf': int(rest[4:]), 'verts': [], 'faces': []}
            brushes.append(cur)
        elif k == 'v':
            cur['verts'].append([float(c) for c in rest.split()])
        elif k == 'f':
            cur['faces'].append([int(c) - base for c in rest.split()])
    return brushes


def bsp_json(loc: int):
    """Solid brushes in layout units, each with its leaf index and an inside point (centroid, used to address
    the cell in edits). Cached on disk by content hash: the polytope computation takes seconds on big maps."""
    L = table()[loc]
    d = project.current('bsp', L['bsp'])
    path = CACHE / 'bsp' / f'{L["bsp"]:04d}_{hashlib.sha1(d).hexdigest()[:12]}.json'
    if path.exists():
        return path.read_text()
    brushes = _obj_to_brushes(bsp.to_obj(bsp.parse(d)))
    for b in brushes:
        b['inside'] = [round(sum(v[k] for v in b['verts']) / len(b['verts']), 4) for k in range(3)]
    data = json.dumps({'bsp': L['bsp'], 'brushes': brushes})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    return data


def model_glb(entry: int) -> bytes | None:
    """GLB of a BMD0 entry (nitro.bmd0_to_glb: nitrogen geometry, NNS UVs/wrap; bind pose, no animations)."""
    path = CACHE / 'models' / f'{entry:04d}.glb'
    if path.exists():
        return path.read_bytes()
    d = db()[entry].data
    if d[:4] != b'BMD0':
        return None
    with _lock:
        glb = nitro.bmd0_to_glb(d)
    if glb is None:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(glb)
    return glb


LANGS = list(text.BANKS)
