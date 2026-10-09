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
/editor/           Map editor code (phase 5)
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

- Current phase: 5 (editor, milestone 3 in progress: "add item" palette done)
- Latest progress (2026-10-09): "add item" palette (all 10 constructed types; named NPC/prop/object lists; door
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
- Editor technology CHOSEN (2026-10-06, user: "most economical, reuse our tools scripts"): Python backend
  (stdlib `http.server`) importing `tools/*.py` directly + browser UI (plain HTML/JS, vendored three.js) for the
  2D/3D views; 3D models via nitrogen BMD0 → GLB (offline cache). No new GUI framework, runs the same on Windows and Linux.
- Phase 5 milestone 1 DONE (read-only editor, `python editor/server.py`, see editor/README.md): 33/33 locations,
  175/175 referenced models convert, top-down + 3D, item details, door links, scripts with text.
- Model textures fixed (2026-10-06): `tools/nitro.py bmd0_to_glb` replaces the nitrogen CLI. It fixes nitrogen's flipped V,
  its lost repeat/mirror wrap (taken from the material teximage_param) and its wrong NNS Maya texture SRT. 175/175 regenerated and
  checked against the game screenshots; the Maya formula itself comes from noclip (not confirmed in arm9).
- Next step: rest of milestone 3 (to agree with the user):
  - drag in 3D;
  - editing scripts and text from the editor;
  - waypoint link display and editing;
  - a sign proof for the facing angle (rotate an NPC by 90° and compare).
- Blockers: none. bg_composite tile codec still unknown (FUN_020bbde8).

## Information to be filled in by the user

- Location of the original `.nds` file (if kept):
- ROM version / region and game code (e.g. `ASIP`, `ASIE`…): `ASJP` (Europe), ROM version 0x00
- System: Windows (Claude Code, Ghidra) + WSL2 Ubuntu (MelonMCP only)
- Preferred language / framework for the editor: Python (reuse tools/) + local web UI in the browser
