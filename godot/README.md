# Sims 2 DS Map Editor (Godot)

Standalone rewrite of the map editor in Godot 4.7 (GDScript only). No Python, no ndstool, no unpacked ROM:
the editor opens a `.nds` file you pick, reads everything from it, and exports a new `.nds`.

## Run

- Windows: put `Godot_v4.7.x-stable_win64.exe` (standard build, not .NET) in this folder and double-click
  `Lancer l'editeur.bat`. Or `Godot_v4.7.2-stable_win64.exe --path <this folder>`.
- Linux: put `Godot_v4.7.x-stable_linux.x86_64` in this folder (or have `godot` / `godot4` in the PATH) and run
  `sh lancer_editeur.sh` (or `./lancer_editeur.sh` once made executable).
- Any OS: open this folder with Godot 4.7 and press F5, or `godot --path <this folder>`.
- A ROM path can be given: `godot --path . -- path/to/sims2.nds`.
- Single executable: install the Godot export templates (Editor > Manage Export Templates), then
  `godot --headless --path . --export-release "Windows Desktop" export/Sims2DSMapEditor.exe`
  (the preset embeds the project in the exe).

The Godot binaries are not committed (see `.gitignore`).

## Use

1. Start screen: **Open a ROM** (or drop a `.nds` on the window). Recent ROMs are listed.
   Made on the European ROM `ASJP` v0x00: other versions open with a warning (data tables are at fixed ARM9 addresses).
2. Pick a location and a variant (block 0 + one variant block, as the game loads them). Top-down or 3D view.
3. Edit: same features as the former web editor (milestones 1–3):
   - items: select (view or list), drag in the top-down view, typed fields with in-game icons/names, raw record,
     duplicate, delete (Del) with script reference renumbering;
   - entry points: move, angle;
   - **Add item** tab: type, target group (with what spawns it), fields, place on map;
   - **Edit collision**: click a cell (again = next cell below), delete / move it, add a box;
   - hotel room default furniture (locations 8, 29, 17, 15, 18, 20): drag on the grid, prop picker (new games only).
   - **Scripts** tab: the scripts of block 0 or of the shown variant as text, one op per line
     (`spawn_run(group=2, script=5)`), dialogue lines as comments. Edit, add `script N` at the end, Apply
     (Ctrl+S). Broken group / script / conversation refs are refused. "Text of line" opens the strings of
     the conversation / message on the caret line in the Text tab; Opcodes… lists every opcode.
   - **Text** tab: search the strings of the selected language (text or `0x49f`), edit one, Apply. Accented
     letters are allowed; the Huffman tree is rebuilt when a new character needs it. The game reads the text once
     at boot: check text edits from a fresh boot, not a savestate.
   - **Locations** tab: new locations (ids 34..63) made from an original one (its scene, music, layout, collision):
     name, "behaves like" (fog, ambient sounds, lights), price in the construction menu, delete. Lead a door or a
     warp script to them.
   - **Own 3D scene** of a new location (Locations tab, "Import .glb / .gltf…"): the glTF scene replaces the
     template's scene models and collision. In Blender: model the place (Y up after export, 1 m = 7 game units
     with the default scale 7; a Sim is about 12.5 units), texture it with the Base Color image of each material
     (power-of-two sizes are kept as is, others are resized; colour textures up to 256 px), optional vertex
     colours for baked lighting, then File > Export > glTF 2.0. Collision: every visible face gets a thin solid slab
     behind it; objects named `…-col` are invisible solid blocks (convex), `…-nocol` are visible but not solid.
     Keep the floor about 1 unit under the entry points (move them with the layout tools). Textures are fitted to
     the game's texture memory automatically (the report says what was reduced). "4x4 textures" (on by default)
     stores textures of more than 16 colours in the DS 4x4 format like most of the game's own: about twice the
     texture detail in the same memory, slightly lossy. No lights / animations yet.
   - Ctrl+Z undo, **Revert location**, File > Discard every edit.
4. **Export ROM…** writes a new `.nds`. The opened ROM is never written.
   - File > **Export as BPS patch…** writes a patch of the opened ROM instead (apply with Flips, ROM Patcher JS…).
     Share the patch, not the ROM.
   - **Test ▶** (F5) builds a scratch ROM in the project folder and opens it in your emulator (chosen once with
     File > Choose emulator…; melonDS recommended). The test ROM skips the intro, the menus and Create-a-Sim and
     starts a new game in the shown location, at the selected entry point (or the first one), with a default Sim.
     Uncheck File > "Test starts in this location" for a normal boot (intro, text shown at boot, saved games).

Edits are autosaved under the Godot user folder (`%APPDATA%/Godot/app_userdata/Sims 2 DS Map Editor/projects/<sha1 of the ROM>/`),
so reopening the same ROM restores them.

## Code

| file | role (port of) |
|---|---|
| `scripts/core/nds_rom.gd` | `.nds` header, NitroFS, ARM9, rebuild with relayout (replaces ndstool) |
| `scripts/core/arm9_mod.gd` | ARM9 patches and extension area for new data/code (`docs/formats/arm9.md`) |
| `scripts/core/bps.gd` | BPS patch encoder / decoder |
| `scripts/core/blz.gd` | ARM9 BLZ decompression (ndspy codeCompression) |
| `scripts/core/s2cmp.gd`, `rombin.gd` | rom.bin entries and their compression (`tools/s2cmp.py`, `rombin.py`) |
| `scripts/core/game_data.gd` | ARM9 tables, locations, model names, text, object info (`locations.py`, `objinfo.py`) |
| `scripts/core/text_bank.gd` | Huffman text banks: read, edit, tree rebuild (`text.py`) |
| `scripts/core/layout.gd`, `layscript.gd` | layout files and script opcodes (`layout.py`, `layscript.py`) |
| `scripts/core/bsp.gd` | collision BSP, cell edits (`bsp.py`) |
| `scripts/core/roomfurn.gd` | hotel room furniture placement, prop variant textures (`roomfurn.py`) |
| `scripts/core/nsbmd.gd` | BMD0 → Godot mesh + textures (nitrogen + `nitro.py` UV fixes) |
| `scripts/core/nsbmd_write.gd` | Godot meshes → BMD0 scene model files, palette textures, VRAM budgets (`docs/formats/bmd0.md`) |
| `scripts/core/tex4x4.gd` | 4x4-compressed texture encoder (colour-pair codebook, `docs/formats/bmd0.md` §6) |
| `scripts/core/bsp_build.gd` | convex brushes → collision BSP (compiler), brushes from meshes |
| `scripts/core/scene_import.gd` | glTF / GLB scene → surfaces + collision brushes |
| `scripts/core/loc_ext.gd` | new location ids 34..63: ARM9 tables and hooks (`docs/formats/arm9.md` §6-7) |
| `scripts/core/sprite.gd` | icon sprites (`s2sprite.py`) |
| `scripts/core/project.gd` | edits, undo, autosave, export (former Python editor) |
| `scripts/ui/*` | start screen, panels, top-down and 3D views |

The formats are documented in `../docs/formats/`.

## Tests (need a ROM, never committed)

```
godot --headless --path . --script res://tests/test_core.gd  -- sims2.nds   # round-trips, models, icons
godot --headless --path . --script res://tests/test_edits.gd -- sims2.nds out.nds   # edits -> export -> reopen
godot --headless --path . --script res://tests/test_foundations.gd -- sims2.nds out_dir [ext_kib]   # ARM9 extension, rom.bin entries, BPS
godot --headless --path . --script res://tests/test_text.gd -- sims2.nds out_dir   # text banks: round-trip, edits, export
godot --headless --path . --script res://tests/test_scripts.gd -- sims2.nds out_dir   # layout scripts: text round-trip, edits, export
godot --headless --path . --script res://tests/test_conversations.gd -- sims2.nds out_dir   # conversation / message tables, new strings, export
godot --headless --path . --script res://tests/test_boot.gd -- sims2.nds out_dir [loc entry]   # direct-boot test ROM patch
godot --headless --path . --script res://tests/test_newloc.gd -- sims2.nds out_dir   # new locations: project, export, ARM9 hooks
godot --headless --path . --script res://tests/test_bmd0.gd -- sims2.nds out_dir   # BMD0 writer: dictionaries, models read -> write -> read
godot --headless --path . --script res://tests/test_bspbuild.gd -- sims2.nds [locs]   # BSP compiler: boxes, original locations recompiled
godot --headless --path . --script res://tests/test_scene.gd -- sims2.nds out_dir [max_tex]   # own scenes: GLB import, export, test ROMs
godot --headless --path . --script res://tests/test_tex4x4.gd -- sims2.nds [n]   # 4x4 texture encoder: quality vs the game's, format
godot --headless --path . --script res://tests/probe_tex4x4.gd -- sims2.nds out_dir   # 4x4 VRAM probe ROMs (emulator, not pass / fail)
godot --path . --script res://tests/test_dialogue_ui.gd -- sims2.nds   # Dialogue tab smoke test (needs a window)
godot --path . --script res://tests/test_locations_ui.gd -- sims2.nds [out_dir/test_room.glb]   # Locations tab (+ scene import)
godot --path . -- sims2.nds --shot=out.png [--loc=N] [--3d] [--sel=b/g/i] [--tab=N] [--cells] [--text=query] [--dlg=id[,1=messages]]   # UI screenshot
```
