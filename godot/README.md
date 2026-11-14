# Sims 2 DS Map Editor (Godot)

Standalone rewrite of the map editor in Godot 4.7 (GDScript only). No Python, no ndstool, no unpacked ROM:
the editor opens a `.nds` file you pick, reads everything from it, and exports a new `.nds`.

## Run

- Windows: put `Godot_v4.7.x-stable_win64.exe` (standard build, not .NET) in this folder and double-click
  `Lancer l'editeur.bat`. Or `Godot_v4.7.2-stable_win64.exe --path <this folder>`.
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
3. Edit: same features as the old web editor (milestones 1–3):
   - items: select (view or list), drag in the top-down view, typed fields with in-game icons/names, raw record,
     duplicate, delete (Del) with script reference renumbering;
   - entry points: move, angle;
   - **Add item** tab: type, target group (with what spawns it), fields, place on map;
   - **Edit collision**: click a cell (again = next cell below), delete / move it, add a box;
   - hotel room default furniture (locations 8, 29, 17, 15, 18, 20): drag on the grid, prop picker (new games only).
   - Ctrl+Z undo, **Revert location**, File > Discard every edit.
4. **Export ROM…** writes a new `.nds`. The opened ROM is never written.

Edits are autosaved under the Godot user folder (`%APPDATA%/Godot/app_userdata/Sims 2 DS Map Editor/projects/<sha1 of the ROM>/`),
so reopening the same ROM restores them.

## Code

| file | role (port of) |
|---|---|
| `scripts/core/nds_rom.gd` | `.nds` header, NitroFS, ARM9, rebuild with relayout (replaces ndstool) |
| `scripts/core/blz.gd` | ARM9 BLZ decompression (ndspy codeCompression) |
| `scripts/core/s2cmp.gd`, `rombin.gd` | rom.bin entries and their compression (`tools/s2cmp.py`, `rombin.py`) |
| `scripts/core/game_data.gd` | ARM9 tables, locations, model names, text, object info (`locations.py`, `objinfo.py`) |
| `scripts/core/text_bank.gd` | Huffman text banks, read only (`text.py`) |
| `scripts/core/layout.gd`, `layscript.gd` | layout files and script opcodes (`layout.py`, `layscript.py`) |
| `scripts/core/bsp.gd` | collision BSP, cell edits (`bsp.py`) |
| `scripts/core/roomfurn.gd` | hotel room furniture placement, prop variant textures (`roomfurn.py`) |
| `scripts/core/nsbmd.gd` | BMD0 → Godot mesh + textures (nitrogen + `nitro.py` UV fixes) |
| `scripts/core/sprite.gd` | icon sprites (`s2sprite.py`) |
| `scripts/core/project.gd` | edits, undo, autosave, export (`editor/project.py`) |
| `scripts/ui/*` | start screen, panels, top-down and 3D views |

The formats are documented in `../docs/formats/`.

## Tests (need a ROM, never committed)

```
godot --headless --path . --script res://tests/test_core.gd  -- sims2.nds   # round-trips, models, icons
godot --headless --path . --script res://tests/test_edits.gd -- sims2.nds out.nds   # edits -> export -> reopen
godot --path . -- sims2.nds --shot=out.png [--loc=N] [--3d] [--sel=b/g/i] [--tab=N] [--cells]   # UI screenshot
```
