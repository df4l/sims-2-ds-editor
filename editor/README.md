# Sims 2 DS map editor (phase 5)

Python backend reusing `tools/` + browser UI. Same on Windows and Linux.

```
.venv/Scripts/python -m pip install -r requirements.txt           # Linux: .venv/bin/python (first-time setup: ../README.md)
.venv/Scripts/python editor/server.py                             # opens http://127.0.0.1:8765
```

- `server.py`: stdlib HTTP server, JSON API (see its docstring).
- `project.py`: edit layer (see below). `python editor/project.py status|build|reset`.
- `backend.py`: calls `layout`, `bsp`, `layscript`, `nitro`, `s2data` and `locations` from `tools/`. It holds no format logic of its own.
- `static/`: `index.html`, `app.js` (sidebar + top-down canvas), `view3d.js` (three.js).
- `static/vendor/three/`: three.js r170, vendored with its MIT licence so the editor works offline.
- Generated caches go in `build/editor_cache/`: GLB per BMD0 entry and brush JSON per BSP. Delete the folder to regenerate it.
- Models are converted by `tools/nitro.py` `bmd0_to_glb`. It uses nitrogen for the geometry and textures but fixes the texture coordinates: V axis, NNS Maya texture SRT, and repeat/mirror from the material. It hooks a nitrogen internal (`_read_material`), so keep nitrogen pinned.

The URL hash keeps the view: `#loc=5&block=1&item=0/0/3&view=3d`. The item key is block/group/item, 0-based.

## Milestone 1 (read-only) — done 2026-10-06
Shows any of the 33 locations:
- collision from the BSP;
- layout items of block 0 plus a chosen variant block;
- entry points;
- the scene models and item models in 3D;
- item details, door destinations with a link to open them;
- the scripts, with dialogue text in 6 languages.

Assumed, not verified:
- the facing direction (sign of the angle);
- trigger/door boxes drawn centred on the item position, not rotated.

## Milestone 2 (editing) — done 2026-10-07
- **Items**: select, then drag in the top-down view or use the form (x, y, z, angle, raw record of the same size and type). Duplicate appends a copy at the end of the group. Delete (button or Del key):
  - a referenced item is refused (the message names the scripts);
  - references and waypoint links to the items after it are renumbered.
- **Entry points**: move and set the angle.
- **Collision**: "Edit collision", then click a cell. Clicking the same spot again picks the next cell below. Actions: delete the cell, move it by (dx, dy, dz), or add an axis-aligned box.
- **Undo** (Ctrl+Z), **Revert location**, **Build ROM**:
  - edits are saved at once in `build/editor_project/`;
  - the ROM is written to `build/editor_rom/sims2_edited.nds`;
  - `/rom/` and `rom_bin/` are never written.
- A layout shared by two locations (22 and 23) is flagged in the panel.
- Checked in the emulator: an added item, a deleted cell and an added box all behave as edited (journal 2026-10-07).
- The undo stack lives in the server process. `project.py reset` while the server runs does not clear it.

## Hotel room furniture — 2026-10-07
- Locations 8, 29, 17, 15, 18, 20 list their **default furniture** (pink, group "Room furniture"): fridge, bed, couch,
  shower, toilet, sink. It is not in the layout: it comes from the arm9 table 0x0211FA70 (docs/formats/roomfurn.md).
- Positions are computed like the game does (room grid file + model box + placement data); checked 36/36 against the emulator.
- Edit: drag (snaps to grid cells; wall props slide along their wall) or the form (prop id, rot, cell / wall slot).
  Saved in `build/editor_project/furniture/`, written into `arm9.bin` at Build ROM.
- **Only new games** see the change: the table is copied into the game state (and the save) at new game.
- The prop list offers the 182 furniture props (floor or wall, decoded from arm9 + their node files, exact placement).
  Other prop ids are refused: the game has no placement object for them.

## Milestone 3, part 1: "Add item" palette and typed fields (2026-10-09)
- **Add item** (sidebar):
  - pick a type (all 10 types the game constructs) and its fields: NPC, prop and door model from named lists;
    door destination plus an entry point of that location; box sizes; and so on;
  - pick the target group (block 0 or the current variant). The panel says what spawns that group: permanent
    group, scripts, trigger boxes. It warns when nothing does;
  - then **Place on map** (click in the top-down view, Esc cancels) or **Add at view centre**.
  - The item is appended to the group, so no index shifts. Its y is that of the nearest item; the game snaps
    props to the floor.
- **Typed fields** for the selected item replace hand-editing raw hex. Raw stays available.
- Checks done by the server (`project.check_item`; the edit is refused, nothing changes):
  - the door destination has that entry point;
  - a trigger's group/script exist;
  - waypoint links point at waypoints of the same group;
  - an orb's collect bit is unused (new and copied orbs get the first free bit).
- **Runtime limits** are checked on every save: the 0x800-byte parse arena (8 bytes per item) and 32 waypoints.
  The panel shows the current use. See docs/formats/layout.md §4c.
- Checked in the emulator: a new prop model and a new door to location 6 added to location 5 both work in game
  (journal 2026-10-09).
- Assumed, not verified: bits 50..63 are free collect bits.

## Milestone 3, part 2: in-game icons in the pickers (2026-10-09)
- The NPC and prop fields are now **icon grids** with the game's own icons: conversation portraits for NPCs and
  buy-mode / inventory icons for props. They're used in the Add item palette, the item edit form and the hotel room
  furniture form. A search box filters by id, in-game name or model name. The tooltip shows `id name (model)`.
- Source: the arm9 object info table 0x02122A00 (docs/formats/objinfo.md, `tools/objinfo.py`), which also gives the
  in-game names ("Camel Couch" instead of the model name `CouchBasic`).
- Props and NPCs without an icon of their own (effects, unused props, 3 NPCs, Cellphone) show their name instead.
- Icons are rendered once into `build/editor_cache/icons/` (~25 s the first time the palette loads).
- Door models (type 4 `object`) have no record in that table and stay a list.
