# Sims2DS-RE — Reverse engineering The Sims 2 (Nintendo DS)

## Project goals

1. **Short term**: understand the format of the `rom.bin` archive (stored in the ROM's NitroFS) and write a tool that **lists, then extracts** every file it contains.
2. **Medium term**: identify which of those files describe the **maps** (terrain, tiles, placed objects, collisions, triggers) and document their format.
3. **Long term**: build a **map editor** able to read, modify and write those files back, then rebuild a playable ROM.

The project moves forward in phases. Do not move on to the next phase until the current one has a verified deliverable.

## Available tools

### Ghidra (via MCP)
- `arm9.bin` is open in Ghidra. It is the game's main code (ARM946E-S CPU, ARMv5TE, mixed ARM and Thumb code).
- Usual ARM9 load address: `0x02000000` (confirm against the ROM header: `arm9_ram_address` and `arm9_entry_address` fields).
- The `arm9.bin` imported into Ghidra is **already decompressed** upstream: no need to check or reprocess it.
- **Overlays**: part of the code may live in overlays (`overlay/overlay_XXXX.bin`, `y9.bin` table). If a function you are looking for cannot be found in the ARM9, think of the overlays and import them into Ghidra as additional memory blocks at their load address.
- As soon as a function is understood, **rename** it in Ghidra and add a comment. Suggested prefixes:
  - `FS_`: file system / rom.bin access
  - `Arc_`: archive parsing
  - `Map_`: map loading and logic
  - `Gfx_`: graphics, tiles, palettes
  - `Cmp_`: decompression
  - `Unk_`: partially understood function (keep the address in the name, e.g. `Unk_020345A0_readHeader`)

### MelonMCP (MCP-driven melonDS emulator) — if installed
- Repository: https://github.com/claudeopusworkspace/MelonMCP
- Installed in **WSL2** (Ubuntu), under `~/MelonMCP`. Claude Code and Ghidra run on **Windows**; the server is launched through `wsl.exe`.
- **Paths**: the emulator lives on the Linux side. Any path passed to MelonMCP (ROM, savestates, dumps) must be a Linux path: `C:\Projets\Sims2DS\build\sims2_rebuilt.nds` becomes `/mnt/c/Projets/Sims2DS/build/sims2_rebuilt.nds`. Files produced by the emulator that matter to the project must be written under `/mnt/c/...` so they are visible from Windows.
- The emulator viewer can be opened from a Windows browser at `http://localhost:8090`.
- Intended uses:
  - run the game up to a given map, then take a **savestate** to get back to that point quickly;
  - **read RAM** to find a map structure once loaded and compare it with the source file;
  - set **watches** on addresses identified in Ghidra (e.g. the rom.bin read buffer) to find out which file is loaded and when;
  - take screenshots to visually validate a modification.
- Before using it, list the tools the MCP server actually exposes instead of guessing their names.
- If MelonMCP is not available, say so clearly and continue with static analysis (Ghidra + Python).

### Python / CLI tools
- Python 3 in a venv at the project root (`.venv/`).
- **`ndstool.exe`** is available at the project root. It is the reference tool for unpacking (`-x`) and rebuilding (`-c`) the ROM. Run `ndstool.exe` with no arguments to see its exact options before using it.
- Recommended Python library: `ndspy` (NitroFS, LZ10/LZ11/BLZ decompression, standard Nintendo formats), useful for scripting.

## Project layout

```
/ndstool.exe       CLI tool to unpack / rebuild the ROM
/rom/              Unpacked ROM contents: arm9.bin, arm7.bin, header, overlays,
                   NitroFS data (incl. rom.bin)… (READ-ONLY, never modified)
/rom_bin/          Files extracted from rom.bin
/tools/            Python scripts (extractor, parsers, rebuilder)
/tests/            Tests (extraction → rebuild round-trip, etc.)
/docs/formats/     One .md sheet per understood format (rom.bin, maps, tiles…)
/docs/ghidra.md    Table of identified functions (address, name, role)
/docs/journal.md   Log of hypotheses, tests and results
/build/            Modified ROMs and rebuilt archives
/godot/            Map editor (phase 5, Godot 4.7 GDScript, the only editor)
```

## Working rules

- **Never modify the original ROM or anything inside `/rom/`.** To modify files, copy the unpacked tree to `/build/`, work on the copy, and rebuild the ROM there with `ndstool.exe` under a new name.
- **Hypothesis → verification → documentation.** Every claim about a format must be verified (through the code in Ghidra, through a script that tests it against all files, or through the emulator). Record in `docs/journal.md` what was assumed, how it was tested, and the result.
- In the documentation, clearly separate what is **confirmed** from what is **assumed**.
- Prefer evidence from the code (Ghidra) over statistical guesses on raw data. The two approaches complement each other: hex analysis gives leads, the code confirms them.
- Scripts must work on **all** relevant files, not just on one sample. Explicitly report files that do not match the expected format.
- The success criterion for any parser is the **round-trip**: reading then writing back a file must produce a byte-for-byte identical file.
- Keep `docs/ghidra.md` in sync with the renames made in Ghidra.
- When stuck, stop and summarize: what is known, what was tried, the remaining leads. Do not go around in circles.

## Phases

### Phase 0 — Setup
- The ROM is already unpacked in `/rom/`: no extraction needed. Inventory its contents (file names, sizes, location of `rom.bin`, overlays and their table).
- Read the header (`ndstool.exe -i` on the original `.nds`, or the header file in `/rom/`): game code, ARM9/ARM7 addresses, presence of overlays.
- Check that the `arm9.bin` loaded in Ghidra is at the correct base address.
- Record the inventory in `docs/journal.md`.
- Check that the unpacked tree rebuilds cleanly: rebuild an unmodified ROM into `/build/` with `ndstool.exe -c` and confirm it boots in the emulator. This validates the rebuild pipeline before any modification.

### Phase 1 — Understand rom.bin
Data-driven approach:
- Examine the first bytes of `rom.bin`: signature (magic), entry count, offset/size table, possible name or hash table.
- Look for known signatures inside it (`LZ` 0x10/0x11, `NCGR`, `NCLR`, `NSCR`, `NSBMD`, `NSBTX`, `SDAT`…) to locate where sub-files begin.

Code-driven approach:
- In Ghidra, search for the string `"rom.bin"` (or `"/rom.bin"`, `"data/rom.bin"`) and its references.
- Trace back to the NitroSDK calls `FS_OpenFile` / `FS_ReadFile` / `FS_SeekFile` (or their equivalents) to find the function that reads the rom.bin header.
- Determine how the game requests a file: by index, by name, by hash? Deduce the table structure from that.
- Locate any decompression routine applied after reading.

**Deliverable**: `tools/rombin.py` supporting `list` (index, offset, size, name/hash, detected type) and `extract`, plus `docs/formats/rombin.md`.

### Phase 2 — Asset catalogue
- Extract every file from rom.bin, decompressing when needed.
- Sort by type (2D graphics, 3D models, textures, sounds, text, unknown data).
- Group unknown files by signature / size / structure.

### Phase 3 — Identify the maps
- Start from in-game locations (town, hotel, etc.): find the code that loads a map in Ghidra (`Map_*`), or use the emulator to spot which file is read during an area transition.
- Compare the in-RAM structure after loading with the file on disk.
- Document: dimensions, tiles/models, objects and their positions, collisions, doors/transitions, possible scripts.

### Phase 4 — Reliable read/write
- Parser + serializer for each map format, round-trip tested on every map.
- Rebuilder for `rom.bin`, then full ROM rebuild with `ndstool.exe -c` from the copy in `/build/`, first round-trip tested with no modification.
- End-to-end test: small change (move an object) → rebuilt ROM → check in the emulator.

### Phase 5 — Map editor
- Technology to be decided with the user before starting.
- Minimum features: open a map, display it, move/add/delete objects, edit collisions, save, rebuild the ROM.

## Current status

> Update this section at the end of every session.

- Current phase: 5 (editor; modding features: text, scripts, dialogue, new locations, own 3D scenes)
- 2026-11-25 (latest): arcade sounds DONE: `sfx` ids of the original cabinets decoded (Snd_PlaySoundEvent
  0x020D5680, block 0x1F..0x30, docs/formats/arcade_vm.md §2b), built-in names SFX_… in the language, looping /
  out-of-table ids refused by the compiler and ignored by both VMs. CONFIRMED in melonDS (build/arcade_test/sfx/, run
  without crash; not heard). Next: from the backlog (Blender round-trip, Sims / characters…).
- 2026-11-24: Arcade tab DONE (godot/scripts/ui/arcade_tab.gd): cabinet choice, source editor, live preview
  (ArcadeVM + shader), palette / 16×8 sprite editors rewriting the source, examples, Apply / Remove, "Placed in" +
  "Selected prop → cabinet". Test: test_arcade_ui (31/31, window). Next: try it by hand (keyboard play), then pick
  from the backlog (sfx id list for `sfx`, Blender round-trip, Sims / characters…).
- 2026-11-24: own arcade games, step 2 DONE: arcade VM. Language compiler (arcade_script.gd), reference VM
  (arcade_vm.gd, preview), ARM copy in the extension (arcade_vm_asm.gd, ~3.2 KiB), game block + thunks per game
  (ArcadeExt.install_script_game), docs/formats/arcade_vm.md. CONFIRMED in melonDS: self-test script = reference VM
  byte for byte (screen, palette, 256 vars, with and without keys); Lunar Lander example plays. A stops the session
  (Sims UI) → games use B/X/Y/D-pad. Tests: test_arcade_vm (no ROM), test_arcade. Next: Arcade tab in the editor
  (source editor, live preview, sprite / palette editing, cabinet choice).
- 2026-11-23: own arcade games, step 1 DONE. ArmAsm (godot/scripts/core/arm_asm.gd, ARM assembler in GDScript,
  57/57 encodings = capstone) + ArcadeExt (arcade_ext.gd: table moved to the extension, cabinets 174/175/176 get own
  types 10..; edit kind `arcade:<prop>`). Test card on 174 CONFIRMED in melonDS (build/arcade_test/card/: shown on the
  cabinet, scrolls, input inverts it byte-exact, Stop frees). Tests: test_armasm (+ tools/check_armasm.py), test_arcade.
  Agreed plan (user: "option 2"): a small VM (bytecode interpreter written in ArmAsm in the extension, same VM in
  GDScript for an in-editor preview), games authored in the editor (script + 16×8 sprites + 4-colour palette). No UI yet.
- 2026-11-23: arcade machines reverse-engineered (docs/formats/arcade.md). Each cabinet runs a software
  mini-game into a 128×128 2bpp buffer uploaded over the model's screen texture every frame
  (Gfx_UploadModelTexImage 0x020bbde8 — NOT a bg_composite codec, that lead is reopened). Table 0x0211E200 = 10 ×
  {Init, Update, Free}; prop → type in the prop cases; props 174–176 (Lunar Lander, Space Gunner, Log Jump) were never
  implemented (fall back to Space Armada), type 9 is a stub. CONFIRMED in melonDS (build/arcade_test/). Next: own arcade
  games (choose: native ARM code vs a small VM interpreted in the ARM9 extension, authored in the editor).
- 2026-11-20 (latest): 4x4 texture encoder DONE (godot/scripts/core/tex4x4.gd, docs/formats/bmd0.md §6): colour-pair
  codebook like the game's own 4x4 textures (re-encodes them at 52-58 dB); scene import option "4x4 textures" (on by
  default). CONFIRMED in melonDS: City Hall in 4x4 (location 36) = City Hall, 49 textures none halved (8bpp: 10
  halved). VRAM probes: 64 KiB of 4x4 per location renders, 96 KiB does not → budgets 65 536 / file, 67 584 /
  location. Tests: test_tex4x4, test_scene (+36); probe ROMs: tests/probe_tex4x4.gd. Next ideas: lit materials,
  per-location camera, texture animations.
- 2026-11-20 (latest): own 3D scenes for new locations DONE. glTF / GLB → BMD0 files (NsbmdWriter,
  docs/formats/bmd0.md) + compiled BSP (BspBuild, docs/formats/location.md §3); Locations tab "Import .glb / .gltf".
  CONFIRMED in melonDS (build/scene_test/): test room drawn and solid as designed (34); City Hall re-encoded (35)
  looks and collides like City Hall (same Sim position to the bit). Limits found: one VRAM allocation per BMD0 file
  (≤ 116 480 B plain texels per file, scenes split into ≤ 4 files), BSP trace stack ~40 levels, floor ~1 unit under
  the entry points. Tests: test_bmd0 (2 626/2 626 dictionaries byte-identical), test_bspbuild, test_scene,
  test_locations_ui (+ all other suites pass). Next ideas: 4x4 texture encoder, lit materials, per-location camera.
- 2026-11-20 (latest): new location ids 34..63 DONE. LocExt.install (godot/scripts/core/loc_ext.gd, docs/formats/arm9.md §7):
  64-entry location table + own records, "behaves like" alias, name text table (15 sites), price / offered tables,
  dust, 0xFC prop records, construction timer (3 sites incl. the door warp 0x0209B88C), ov01 purchase / menu.
  Ids <= 33 keep the original code path. Trampolines checked with capstone; emulator CONFIRMED (build/newloc_test/):
  boot into 34 / 35 / 6, save + load in 35 (names in save / load screens), door 5 -> 34, construction menu buy of 35.
  Editor: Locations tab (create from a template, behaves like, price, menu parent, offered, name, delete).
  Tests: godot/tests/test_newloc.gd, test_locations_ui.gd (+ all other suites pass). Prototype proto_newloc.gd removed.
- 2026-11-19: new location ids (34+, 33 stays "no location") — feasibility study, prototype
  godot/tests/proto_newloc.gd, docs/journal.md. Id 34 = City Hall record loads and plays once the location table,
  music read (0x02084C68), State2 render defaults, layout variant table and the "indoor" id list of
  Map_UpdateLocationAmbience (fog, 0x020766CC) are patched: pixel-identical to City Hall. Overlays scanned
  (tools/ovscan.py): only ov05 (music picker, writes S+0x449C[loc]) needs work; ov01 construction menu stops at id 32.
  Music override S+0x449C: all 12 accesses hooked (LocExt.music_hook, docs/formats/arm9.md §6), ids 33..63 use a
  64-byte extension array; id 34 boots with record music CONFIRMED (build/newloc_proto/loc34_m.nds).
  (Resolved 2026-11-20:) other per-location game-state arrays (timers, dust, S+0x4418, 0xFC records…) have no room for ids 34+;
  indoor list of Map_UpdateLocationAmbience still a test patch.
- 2026-11-17 (latest): Test ▶ boots straight into the shown location (new game at the selected / first entry point):
  hook of the logo state 0x2B step change (0x0205440C) → ARM9 extension routine requesting state 2 mode 5 + state 0xC
  (docs/formats/arm9.md §5, godot/tests/test_boot.gd). CONFIRMED cold boot in melonDS (locations 6 and 9,
  build/boot_test*/). Patching the startup requests instead loses the UI icons (0x2B must run first).
- 2026-11-17 (latest): conversation / message tables in the Godot editor (Dialogue tab: lines, speakers, new
  conversations 217..255, new messages, new strings appended to the 6 banks). Moved tables live in the ARM9 extension;
  overlay 15 is patched (stored decompressed). godot/tests/test_conversations.gd + test_dialogue_ui.gd; new
  conversation + message + strings CONFIRMED in game (build/conv_test/). Message op after a conversation needs queued=1.
- 2026-11-17 (later): script editing in the Godot editor (Scripts tab: text form `op(field=value)`, assembler
  byte-identical on 659/659 scripts, ref checks, new scripts). godot/tests/test_scripts.gd; new script run in game
  CONFIRMED (build/scripts_test/). Fixed: x coordinate of ops 0x0D / 0x1B was hidden (unused bytes now `_`).
- 2026-11-17: text editing in the Godot editor (Text tab, text_bank.gd: Huffman re-encode + tree rebuild, output
  byte-identical to tools/text.py). godot/tests/test_text.gd; exported ROM checked in melonDS (build/text_godot_test/).
- 2026-11-16 (later): modding foundations in the Godot editor. ARM9 extension area (Arm9Mod: pad to 0x02152F00,
  append, raise the main arena literal 0x020FB024; 64 and 512 KiB CONFIRMED in the emulator), table pointer search /
  relocation helper, appended rom.bin entries (boot CONFIRMED), BPS patch export (checked by an independent decoder),
  Test in emulator (F5). docs/formats/arm9.md, godot/tests/test_foundations.gd.
- 2026-11-16: the Godot editor is now the ONLY editor. `godot-editor` merged into main, the Python/web editor `editor/`
  deleted (its history is in git). New editor features go in GDScript only; `tools/` stays as the Python RE lab.
- Godot rewrite (2026-11-14, folder `godot/`): user rejected the web UI and the Python deps.
  Standalone Godot 4.7 GDScript editor: start screen picks a `.nds`, everything is read from it (NitroFS, BLZ ARM9,
  rom.bin, layouts, BSP, BMD0 -> mesh, icons, text), edits autosaved in user://projects/<rom sha1>/, Export ROM writes
  a new `.nds` (own relayout, no ndstool). Feature parity with milestones 1-3. CONFIRMED: round-trips (32 layouts,
  32 BSP, rom.bin, unchanged ROM byte-identical), 65/65 scene models, furniture positions = tools/roomfurn.py,
  edits -> export -> reopen on a plain and a BLZ-compressed-ARM9 ROM, exported ROM boots in melonDS (build/godot_test/).
  See godot/README.md.
- Fix (2026-10-09, latest): colour-variant props (dirty toilets, couch colours…) showed black. Their shared BMD0 has a blank
  texture. The game swaps in a per-prop texture from a table in the Prop_CreatePlacementObject case
  (roomfurn.prop_texture, docs/formats/roomfurn.md §4b); the editor now does the same. Arcade screens 164–176 are still black.
- Latest progress (2026-10-09, later): NPC / prop pickers show the game's own icons (portraits, buy-mode icons)
  and in-game names. Both come from the arm9 object info table 0x02122A00 (Info_Npc / Info_Prop, docs/formats/objinfo.md,
  tools/objinfo.py), used in the palette, the item edit form and the room furniture form.
- Earlier (2026-10-09): "add item" palette (all 10 constructed types; named NPC/prop/object lists; door
  destination + entry; target group with a "spawned by" hint; click to place) and typed field editors
  (`layout.FIELDS`, from Nav_SpawnEntity). Checks: door entry exists, trigger group/script, waypoint links, unique orb
  collect bit. Two runtime limits, CONFIRMED by code and checked on every save: Map_LoadNav arena 0x800 bytes
  (8 per item) and 32 waypoints (docs/formats/layout.md §4c). End-to-end CONFIRMED in the emulator: new prop model
  (YetiStatue) + new door 5 → 6 (build/palette_test/).
- Git repository (2026-10-07): github df4l/sims-2-ds-editor, no game data committed; a new clone is set up with
  `tools/setup_rom.py <game.nds>` (README.md).
- Latest progress (2026-10-07): placement data (wall flag + offsets) decoded for all 182 furniture props (jump table +
  node files, docs/formats/roomfurn.md §4), 36 more props checked in the emulator; editor prop picker. Before: hotel room furniture. Not in the layouts: arm9 default table 0x0211FA70 → game state at new
  game → spawned on room entry on a per-room grid file (docs/formats/roomfurn.md, tools/roomfurn.py). Placement reproduced
  36/36 against RAM; the editor shows and edits the defaults (arm9 patch at build), end-to-end CONFIRMED on a new game.
  Before that, editor milestone 2. Items can be moved, duplicated, deleted or edited raw, and entry points moved; deleting
  renumbers script (g, i) refs and waypoint links, and refuses referenced or ambiguous cases. Collision cells can be deleted or moved
  and boxes added. Autosave in build/editor_project/, undo, Build ROM → build/editor_rom/sims2_edited.nds
  (editor/project.py, tests/test_editor_project.py). End-to-end CONFIRMED in the emulator (location 1: duplicated
  frame visible, Sim stops at the new box z −38.17 against −46.86 at the deleted pedestal; build/editor_rom_test/).
  Earlier (2026-10-06): opcodes 82 (8 still assumed), BSP edits, text edit + Huffman rebuild, milestone 1 viewer,
  texture fix (tools/nitro.py bmd0_to_glb).
- (Superseded by the Godot editor) Editor technology chosen (2026-10-06, user: "most economical, reuse our tools scripts"): Python backend
  (stdlib `http.server`) importing `tools/*.py` directly + browser UI (plain HTML/JS, vendored three.js) for the
  2D/3D views; 3D models via nitrogen BMD0 → GLB (offline cache). No new GUI framework, runs the same on Windows and Linux.
- Phase 5 milestone 1 DONE (read-only editor, `python editor/server.py`, see editor/README.md): 33/33 locations,
  175/175 referenced models convert, top-down + 3D, item details, door links, scripts with text.
- Model textures fixed (2026-10-06): `tools/nitro.py bmd0_to_glb` replaces the nitrogen CLI. It fixes nitrogen's flipped V,
  its lost repeat/mirror wrap (taken from the material teximage_param) and its wrong NNS Maya texture SRT. 175/175 regenerated and
  checked against the game screenshots; the Maya formula itself comes from noclip (not confirmed in arm9).
- Backlog (agreed with the user 2026-11-23, "total editor"; in progress: arcade machines):
  - **Blender round-trip**: "Edit in Blender" button (export the location scene to .glb, launch blender.exe chosen once
    like the emulator), watch the file and re-import on save (BMD0 + BSP + 3D view refresh); optional Blender add-on
    ("Send to editor", scale 1 m = 7 units, Sim dummy, -col/-nocol, VRAM budget). Blender cannot be embedded in the window.
  - **Sims / characters**: Create-a-Sim, clothes, hair, NPC models. Known: 131 64×64 8bpp textures, palette elsewhere
    (catalog.md img8_nopal); palettes, models and skeletons not studied.
  - **Animations** (skeletons, BCA?), **2D graphics** (UI, icons, bg_composite codec FUN_020bbde8),
    **sound / music** (SDAT), **gameplay tables** (prices, objects, stats).
  - **Arcade machines** (props 164–176): how the screen / game works, then own arcade games.
- Next step (to agree with the user). Older list from milestone 3:
  - drag in 3D;
  - editing scripts and text from the editor;
  - waypoint link display and editing;
  - a sign proof for the facing angle (rotate an NPC by 90° and compare).
- Blockers: none. bg_composite tile codec still unknown (FUN_020bbde8 turned out to be a model texture upload,
  2026-11-23: bg_composite may be model texture data, to check).

## Information to be filled in by the user

- Location of the original `.nds` file (if kept):
- ROM version / region and game code (e.g. `ASIP`, `ASIE`…): `ASJP` (Europe), ROM version 0x00
- System: Windows (Claude Code, Ghidra) + WSL2 Ubuntu (MelonMCP only)
- Preferred language / framework for the editor: Godot 4.7, GDScript only (standalone, reads the .nds directly)
