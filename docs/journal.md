# Journal

## 2026-10-04 — Phase 0: setup and inventory

### Environment
- Python 3.14 venv in `.venv/`, `ndspy` installed.
- `ndstool.exe` is **v1.24 (2005)**: old, but it builds a ROM that boots (see below).
- Ghidra MCP: OK. MelonMCP (WSL2): OK, initialized with JIT.
- The original `.nds` is not in the project, only the unpacked tree `/rom/`.

### ROM header (`rom/header.bin`), confirmed
| Field | Value |
|---|---|
| Title / code / maker | `THE SIMS 2` / **`ASJP`** (region P = Europe) / `69` (Electronic Arts) |
| Capacity | 0x09 (512 Mbit) |
| ARM9 | ROM 0x4000, RAM **0x02000000**, entry 0x02000800, size in ROM 0xBF5F8 (compressed) |
| ARM7 | RAM 0x02380000, entry 0x02380000, size 0x26F24 |
| ARM9 overlays | 19 (y9.bin = 0x260 bytes), no ARM7 overlays (y7.bin empty) |

### Inventory of `/rom/`
| File | Size | Notes |
|---|---|---|
| `arm9.bin` | 1 316 728 (0x141778) | **already decompressed** (timestamp 15:13, after the extraction at 15:09) |
| `arm7.bin` | 159 524 | |
| `overlay/overlay_0000..0018.bin` | 616 – 22 140 | **still BLZ-compressed** (on-disk size = csize from y9) |
| `data/rom.bin` | 37 934 164 | target of phase 1 (FAT file id 19) |
| `data/SoundData.rom` | 22 897 964 | sound (id 20) |
| `data/Movies/{Alien,RatFemale,RatMale,Sims1}.bik` | 0.7 – 2.3 MB | Bink videos (ids 21–24) |

NitroFS file ids: 0–18 = overlays, 19–24 = data files (25 FAT entries, FNT 0x5F bytes).

### ARM9 module params (offset 0xAFC in arm9.bin, nitrocode at 0xB18)
`autoload_list=0x02141760 autoload_list_end=0x02141778 autoload_start=0x02139220 static_bss_start=0x02139220 static_bss_end=0x02149B40 compressed_static_end=0x020BF5F8 sdk_version=0x02017532`

→ **Pitfall (confirmed):** `compressed_static_end` ≠ 0 while the binary is decompressed. Rebuilding as-is would make
the boot code decompress it a second time. Fix: set the field to 0 in the copy under `/build/` (done by `tools/rebuild_rom.py`).

### Overlays (y9.bin), confirmed
All 19 overlays load **at the same address 0x02149B40** (= ARM9 `static_bss_end`). They share a single slot and are
mutually exclusive. All are compressed (flag bit 24). Sizes once decompressed: 0x360 (ov07) to 0x93A0 (ov10).
To analyse them in Ghidra: BLZ-decompress (ndspy) and import as overlay memory blocks at 0x02149B40.

### Ghidra
`arm9.bin` program: a single `ram` block at 0x02000000–0x02141777 (= decompressed size), language ARM:LE:32:v5t.
**The base address is correct.** 3474 functions after auto-analysis.

### Rebuild pipeline — validated
- Hypothesis: the unpacked tree + the module params fix rebuilds a ROM that boots.
- Test: `python tools/rebuild_rom.py` → `build/sims2_rebuilt.nds` (67 271 688 bytes). File ids 19–24 identical
  to the original layout. Running the script twice gives a byte-identical output.
- Result: **boots in melonDS**. Reaches the title screen ("Touch the Touch Screen to continue", 3D scene rendered)
  after 900 frames. Screenshot: `build/phase0_boot_title.png`.
- Note: the rebuilt ROM is not byte-identical to the original (the original is unavailable, and the ARM9 is stored
  uncompressed), which is expected.

## 2026-10-04 — Phase 1: rom.bin

### H1: table of u32 offsets at the start, without a header
- Hex: the file starts with increasing u32 values; offsets[0] = 0x8A8C.
- Test (script over the whole file): 8867 offsets, sorted, 4-aligned, last = file size → **confirmed**, 8866 entries.
- Code: `FS_OpenRomBin` (0x0204460c) opens "rom.bin"; `Arc_GetEntrySize`/`Arc_ReadEntryRaw`/`Arc_LoadEntry`
  do seek(idx*4) + read 8 bytes → **confirmed by the code. Access by index only.**

### H2: compression
- No standard Nitro magic in the raw entries; many start with 0x60 + 24 bits that look like a size.
- Code: `Arc_LoadEntry` decompresses only if the caller asks; `Cmp_Decompress` (0x02042adc) dispatches on
  (type>>4)&7; method 6 = routine at 0x01FF8000 (ITCM).
- Unmapped ITCM → autoload list parsed (module params): ITCM = arm9.bin+0x139220 (0x6460 bytes), DTCM =
  +0x13F680. Both added to Ghidra as memory blocks.
- The decompiler is useless on this hand-written ASM → read the disassembly (capstone).
- 1st Python implementation: failed on 100% of the files. Cause: polarity of `blo` (= carry clear, bit 0)
  inverted in the gamma and in the 2 sub-case bits. After the fix: 4403 exact + 969 with a tail `00000000`.
- Large tails = more blobs in a chain (type 6, and LZ10 0x10 in 6 entries). The 96 "errors" = raw
  32-byte palettes starting with 0xE0 (BGR555 0x03E0).
- Strong validation: 3219 Nitro files (BMD0/BCA0/BTA0/BVA0) come out of the decompression, all with
  their internal size field == decompressed size.

### Deliverable
- `tools/s2cmp.py` (EA6 + LZ10 decompression, blob chains), `tools/rombin.py` (list/extract/build/verify).
- `python tools/rombin.py extract` → `rom_bin/raw/` (8866 files), `rom_bin/dec/` (7092 decompressed files),
  `rom_bin/index.csv`. `build` from `rom_bin/raw/` → **byte-identical** to the original rom.bin.
- `tests/test_rombin.py`: archive round-trip + decompression invariants → OK.
- Classification: 5601 compressed / 3265 raw. Caveat: this is a detection; the real flag comes from the caller.

### Open questions
- Type-6 compressor (needed to re-inject modified compressed data) — or check whether raw (type 0x00) is
  accepted wherever the caller goes through Cmp_Decompress.
- Map callers of Arc_LoadEntry → which indices are loaded by which subsystem.

## 2026-10-05 — Phase 2: asset catalogue

### Code (Ghidra, before the MCP server disconnected)
- `Arc_LoadEntry` is only called through 4 wrappers `(idx) -> ptr`: 0x0204456c (p2=0, raw), 0x02044538 (p2=0,
  decompress), 0x020445a0 (p2=1, decompress), 0x020445d8 (p2=1, raw). Param 2 = probably the heap/cache area.
- Almost every call passes an index **read from a structure** (`ldrh r0,[rX,#n]`): indices are stored in data
  tables (u16), not hard-coded. A few constants: 0x128c/0x128d, 0xc04, 0x178c, 0x13ce, 0x21e3..0x21eb, 0xe4c/0xe4d…
- FUN_02050014 = OBJ sprite loader: `{u16 tiles_idx, u16 def_idx}`, def read raw (u16@6 = frames, table at +0xC,
  frame: w,h at +2/+3, tile offset at +4), tiles copied to OBJ VRAM 0x06400000 → sprite_def layout **confirmed**.
- FUN_0200f1cc = BG loader (4 u16 indices: +0/+4 decompressed, +2/+6 raw) → feeds FUN_020bbcf0/FUN_020bbde8.

### Data-driven classification (`tools/catalog.py`)
- Slow file access (≈3 ms per small file, antivirus?) → `tools/s2data.py` caches all of `rom_bin/` in one pickle.
- H: sprite triplets [tiles c][def raw][palette 32]. Test: def size field vs. previous entry size →
  996 exact at first; the 194 others are multi-blob → H': one blob per frame, u32@8 = largest frame.
  Result: 1188/1195 exact, 1184 followed by a palette. **Confirmed** (+ visual: plumbob, objects, Sim parts).
- H: 4096-byte grids `$$$$`/`####` = heightmaps → **rejected**: they are 64×64 8bpp textures (visual check).
- H: 512-byte palette + 8bpp square image (1536, 4608 bytes) → visual check OK on 48 samples.
- H: `0x1E nn` raw = keyframe animation: size = 8 + frames*tracks*rec (+4 per extra track), rec 48 (flags 4) /
  36 (flags 5) → 459 exact. 41 more with the same header and variable records.
- H: bg_composite `u16 flags; [pal 512]; [w,h,map]; tiles` → 509 files fit. Tile section codec unknown.
- Discovery: 15 raw entries are **type-0x00 stored blobs** (`00 | size<<8`), mostly bg_composite → the game does
  use method 0. Not handled by `split_blobs` (phase 1 tool unchanged); handled in the catalogue.
- Discovery: `BSP\0` (32, size field == len) and `GMD1` (32, len == 64 + 16*count) always come together:
  **32 location bundles** `[bsp][trs_anim 1 frame × N tracks][gmd1][scene BMD0][BTA0]` (`rom_bin/locations.csv`).
- Result: 8606/8866 classified, 260 unknown (1.1 MB of 69 MB unpacked). `tests/test_catalog.py` OK.

### Open questions
- bg_composite tile codec (need FUN_020bbde8 in Ghidra).
- trs_anim of the locations: object placement? Which model goes with each track?
- GMD1 16-byte records, BSP content (phase 3).
- Ghidra renames pending (MCP server disconnected during the session), see docs/ghidra.md.

### 2026-10-05 (2) — Sprite previews fixed
- Problem (user): some sprite previews looked like an undone puzzle (e.g. 0039): tiles were drawn as one flat strip.
- H: frame pieces are OAM-like u32 (x 9 bits, y 9 bits, size, shape, tile). Test on 1195 definitions with
  "every piece inside the tile data" → first 1179 OK. Fixes found on the failures: piece count = low 7 bits
  (0x80 = flag); streamed frames: tile_offset = offset of the compressed blob in the raw entry; tiles_size bit 24
  → 16-byte frame header. Result: **1188/1192 parse**, previews assembled correctly (visual check on 40 samples).
- Side effect: 3 entries left the sprite class (3593 → text_bank, 4330/5583 checked separately), stricter rule.

## 2026-10-05 (3) — Phase 3: locations

### Location table (code)
- Searched arm9/overlays for (bsp, gmd1) index pairs → records at 0x021223xx: u16 bsp, gmd1, nav, ...
- Ghidra xrefs: records ← pointer table 0x021332E0 (33 entries) ← 7 accessors ← `Map_LoadLocation`
  (0x02084894). Field roles read in the decompiled loader (BSP, models + anims, nav, music). **Confirmed**.
- Check: `tools/locations.py` parses the 33 records; every index points to the expected kind in the catalogue
  (test_catalog.py). 32 data bundles vs 33 records: 22 and 23 share bsp/gmd1/nav (different scene model).
- Correction of phase 2: the 1-frame trs_anim next to the BSP belongs to the scene model's anim list, it is not
  an object placement list.

### GMD1
- H1: records = unit normals → rejected (y alternates ±32747/−24371: positions).
- H2: vertex = s16 pos[3] + s16 normal[3] + 4 bytes 0, triangle list. Tests on all 32 files: counts % 3 == 0,
  one normal per triangle (38 168/38 168), stored == geometric normal for 95%, extremes ±32747 → **confirmed**.
- XFRM = centre + half-size (fx32). Top-view renders (`rom_bin/preview/locations.png`) = floor plans → role
  "walkable floor / collision" ASSUMED (reader not found: no accessor for rec+2, no magic check in arm9/overlays).
- `tools/gmd1.py verify`: byte-identical round-trip on 32/32.

### BSP
- Nodes of 0x1C bytes from root 0x14: all 17 743 reachable nodes have a unit fx32 normal → plane tree confirmed.
- Negative child values (−(offset+0x1C)) unexplained; data after the tree not decoded.

### nav (rec+4, the former `r:0201` unknowns)
- Top-level layout from `Map_LoadNav` / `Map_ParseNavBlock`; role unknown. 32 entries now `loc_nav` (code).

### Next
- Identify which location id is which in-game place (emulator: read obj+4 of the location object, or break on
  Map_LoadLocation).
- Find the GMD1 reader (overlays not imported in Ghidra yet) and the nav semantics; decode BSP leaves.

## 2026-10-05 (4) — Phase 3: location ids ↔ in-game places (emulator)

### Setup
- MelonMCP OK (WSL), ROM `build/sims2_rebuilt.nds`, no save → Create-a-Sim → first 3D place.
  Savestate `first_ingame` (MelonMCP side). RAM dumps in `build/ram/` (4 x 1 MB).
- Title screen and CAS: no BSP in RAM (CAS = game state 9, world id 33 = none) → not locations.

### Which location is loaded
- H: the BSP of the current location is kept in RAM verbatim. Test: search the 32 BSP entries in a dump of the
  first in-game place → BSP 2048 + nav 2053 found byte-for-byte = **location 5** (starting street). Confirmed.
- Pointer chain from the dump, then code: Map_LoadLocation ← Map_CreateLocationObject ← Map_EnterLocation,
  which writes world+0xF4 = id, world+0xFC = object; [0x0213E580] = world (614 code refs). Confirmed on
  3 dumps (ids 5, 9, none) with `tools/whereami.py`.

### Warp
- Map_EnterLocation ← State2_LocationEnter (vtable 0x02132850) ← Game_CreateState(state 2, mode, id, entry)
  ← Game_UpdateStateMachine, which consumes a pending request at G+0xDF0 (written by Game_RequestState).
- First attempt failed: wrong address (decimal conversion slip, wrote G+0x1F4). With the right address
  (G+0xDF0, slot 0) the request is consumed in ~20 frames and the location loads.
- Result: all 33 ids load; screenshot of each after 300 frames, id read back from world+0xF4 every time.
  Note: MelonMCP screenshots right after load_state show a stale frame; advance a few frames first.

### GMD1 not resident
- H (previous session): GMD1 = floor/collision mesh. Test: search GMD1 header and payload in the dumps of
  locations 5 and 9 → **absent**, while BSP and nav are present. GMD1 is probably not used at run time;
  collision is likely BSP-based. Role of GMD1 downgraded to "unused/editor export?" (ASSUMED).

### Next
- Decode BSP leaves (collision) and the nav file — they are what the game actually uses.
- Placed objects: the Sim on the floor in 23/24 and the props are not part of the scene model → look for an
  object list per location (nav variants? a table indexed by location id elsewhere in arm9?).
- Decode a text bank to get the real place names.

## 2026-10-05 (5) — Phase 3: the "nav" file is the location layout (placed entities)

### Hypotheses and tests
- H: the rec+4 file ("nav") holds the placed objects. Parser written strictly from Map_LoadNav /
  Map_ParseNavBlock / their two helpers. Test on 32 files: all size/offset invariants hold (groups end at
  off_scripts, blocks end at EOF), write(parse) byte-identical 32/32 → **layout confirmed**.
- H: items = `s16 x,y,z, u8 type, ...` with a fixed size per type. Test: 1290/1290 items, each type has one
  size (1:16 2:16 3:16 4:24 5:16 7:12 8:12 9:20 10:12 11:12) → **confirmed**, then explained by the code:
  Nav_SpawnGroup calls ctor table 0x0211E7E0[type]; Nav_SpawnEntity (0x0203a700, was not a function in
  Ghidra) has one case per type; type 9 = Nav_AddWaypoint.
- Types 1/2/4 build actors from model tables (NPC 0x02118310, prop 0x0211CD2C, object 0x0211CC3C): all 357
  references resolve to nitro_model entries (test_layout.py).
- The 16-byte records at the start = **entry points** (Nav_FindEntryPoint by byte +0xC, Map_PlaceAtEntryPoint).
- Angles: degrees in items, converted to fx32 radians (RAM: 180° → 12867 = π). Entry points store radians.

### Emulator
- RAM of location 5: every block-0 box/object/light/waypoint present at file position << 12.
- Edit test 1: prop 41 (block 1) +15 x in a rebuilt ROM → after warp, the resident layout is the modified one
  and the prop actor is at −357 (was −372). Edit test 2: entry point 8 +15 x → Sim actor at −360 (was −375).
  Screenshots identical (dialogue cutscene, fixed camera) — the proof is the RAM read-back.
- Note: load_state of first_ingame works with a different ROM loaded (same game); the warp re-reads rom.bin.

### Deliverables
- `tools/layout.py` (verify / dump / csv → rom_bin/layout_items.csv with model ids), `tests/test_layout.py`,
  `docs/formats/layout.md`. Ghidra renames: docs/ghidra.md part 3.

### Next
- Script opcodes (FUN_0204299c) and box kinds; type 5 (light?) and 11 (sound?).
- Visual check of a moved object outside a cutscene (pick a free-roam savestate).
- BSP leaves (collision) still pending; text banks for NPC / object names.

## 2026-10-05 (6) — Phase 3: visual proof, names, doors, triggers, scripts

### Visual check of a layout edit — CONFIRMED
- New savestate `free_roam_loc5` (intro dialogue dismissed). Same warp + same 9 taps on both ROMs, frame 1090:
  the car (prop 41) is behind the Sim on the original ROM, 15 units to the right on the edited ROM
  (`build/layout_test/car_original_vs_moved.png`).

### Model names
- `tools/nitro.py`: MDL0 name dictionary reader, 329/329 BMD0 readable. Items now show `Car`, `Jebediah`,
  `DoorCityHall`, `cow`, `SkillCreativity`… (layout dump + csv column `model_name`).
- Location scene models are named too, and the ids are in alphabetical order of these names (AlienRoom,
  ArtGallery, Atrium, Basement, casino, CityExterior, CityHall…). → real place names for all 33 ids.

### Doors (item type 4)
- H1: +0xE = destination + 1 (fits a few town doors) → 97/147 entry points exist, 14 reciprocal: rejected.
- H2: +0xE = destination location id, +0x12 = entry point → 145/147 entries exist, 142 reciprocal; code:
  Nav_SetDoorBoxTarget stores them in the box. Emulator: walked through DoorCityHall in town → location 6,
  request args (6, 0), City Hall lobby on screen. **Confirmed**. `layout.py doors` → rom_bin/doors.csv.

### Correction: place labels of session (4) were wrong
- The City Hall lobby is id 6, but loc_06.png showed the casino. Cause: after a warp the top screen keeps
  the previous picture for 400+ frames; the screenshots were taken at +300. Ids were right (read back from
  RAM), the visual labels were not. PLACES in tools/locations.py now = scene model names.

### Triggers, watchers, scripts (code)
- Type 3 = trigger box: repeat flag, group, script (Nav_FireTriggerBox). Type 8 = event watcher (story flag /
  countdown). Groups and scripts are 1-based indices into the *selected variant block*.
- Script VM: 82 opcodes, handler table 0x0211E4F0; 659 scripts parse consistently with the arg-size table.
  Decoded: 0x01/0x02 actor/group commands, 0x15 conditional spawn on story flag, 0x16 spawn+run.

### Side work: MelonMCP HLS stream
- Deadlock between the renderer and ffmpeg 8 (video FIFO full, ffmpeg waiting for audio while probing, then
  again while running). A bigger audio primer got past probing only. Not fixed, patch reverted; the
  screenshot viewer on :8090 works.

### Next
- Decode the most used opcodes (0x12, 0x19, 0x17, 0x14, 0x23, 0x0e) — probably dialogue / text ids.
- Regenerate the location screenshots (≥ 900 frames after each warp).
- BSP leaves (collision); text banks.

## 2026-10-05 (7) — Phase 3: script opcodes, text banks, conversations

### Script area — CONFIRMED
- H: arg offsets are relative to the script area (not block+0x10, which gave garbage). Nav_ParseScripts confirms.
- Test on 93 blocks: offsets, op lists, zero pad to 4, then args contiguous in script order and ending exactly at
  the next table → the area is fully rebuilt by `layout.py` (scripts parsed, tables kept raw). Round-trip 32/32,
  edit test (add op + add script) OK.

### Opcodes
- All 82 handlers decompiled (32 were not functions in Ghidra). Overlays imported as ov00..ov18 to read the game
  states they start. Op table with fields + status in `tools/layscript.py`; disassembler with inlined dialogue.
- Notable: 0x17 = conversation (state 0xE, ov15), 0x19 = conversation an NPC offers when talked to (H "location"
  rejected: values up to 102; H "conversation id" 71/79, 0xD8 = 216 = none), 0x2A = phone call (text), 0x45 =
  message popup, 0x20 money (clamp 999 999), 6-slot inventory, goal and collection systems, camera ops (0x37 uses
  the layout c6 records → c6 = camera points), camera ops store a follow-up script (chains 12 → 17 → 18).

### Text banks — CONFIRMED
- Decoder read in Txt_DecodeString, bank layout in Txt_SetBank. The 6 `text_bank` entries are the languages;
  language table 0x0211E7D4 in Txt_LoadLanguage: en 123, fr 3496, de 3593, it 4184, es 7599; ja 4214 unused.
- One child of each tree points back to the root (dead branch) — first encoder looped on it, fixed.
- `text.py verify`: re-encoding gives byte-identical banks 6/6. Character map built from words (Latin-1 order with
  gaps); 3 codes assumed. NPC names = text 0x143 + id (Jebediah 22, Cow 53, Bull 54 match location 5).

### Emulator check — CONFIRMED
- English bank resident at 0x021816DC (matches entry 123). Lines 0x49F/0x4A0 re-encoded by text.py written into
  their slots in RAM, warp to location 5 entry 8: the game shows "Map editor test: …" then "Second line edited
  too…" then the original line 0x4A1, speaker box "Jebediah S. Jerky". Confirms encoder, conversation table
  order, speaker → name. Screenshots in build/text_test/.
- Not done: longer text through a rebuilt ROM (bank loads only at language setup → needs a fresh boot).

### Next
- BSP leaves (collision); regenerate location screenshots (≥ 900 frames after warp).
- Remaining assumed ops (goal / collection meaning, 0x12, sound ops); prop / object names in the text bank.
- Text edit through a rebuilt ROM + fresh boot (end-to-end).

## 2026-10-06 — Phase 3: BSP = collision, fully decoded and edited in game

### Code
- The location BSP (obj+0x38, holder `{u16 entry, bsp*, s32 offset[3]}`) is read by an ITCM routine reached
  through a veneer at 0x01ffc54c → **Clsn_TraceBoxBsp 0x01ffc558** (not a function in Ghidra before): a
  Quake-style swept AABB trace with an explicit stack of 0x3C-byte frames. Caller chain: Actor_MoveWithCollision
  (0x020877e4: gravity then move) → Clsn_MoveBox → Clsn_MoveBoxGrounded/Air → Clsn_SlideBox → Clsn_TraceWorld
  (actors + BSP). Renames: docs/ghidra.md part 4 (prefix `Clsn_`, `Coll_` = collection).
- Read from the code: root at bsp+0x10; node = front, back, flags, n[3], d; `(flags&7)>>1` = axis (3 = full
  normal), bit0 = sign; negative child = leaf at −child {count, node offsets}; hit only if the crossed plane is
  in the leaf list.

### Data tests (32 files)
- H: header + nodes + leaves cover the file. Result: exact, 32/32 → no other data in the file.
- H: front child is stored at node+0x1C (preorder). 14 225 front nodes + 3 518 leaves all at node+0x1C; back
  subtree right after → **confirmed**, explains the old "−(node+0x1C)" note.
- H: leaf list = faces among the ancestors. 3 518/3 518 leaves: every ref is an ancestor; 3 517 include the
  parent. **Confirmed**. back is never a leaf, front never 0; axial normals match flags on all 17 743 nodes.
- bit3 of flags: only with back == 0, never read by the trace → unknown, preserved.
- Side convention: front ⇔ n.p + d ≤ 0 (from the code). Data check: entry points / waypoints +3 above their y
  are empty (66/66, 257/258) and −2..−5 below are solid (58/66, 236/258); the opposite convention gives "empty"
  for every point → **confirmed**. Floors are thin slabs.
- `tools/bsp.py verify`: byte-identical round-trip 32/32 + invariants. Walk maps (`bsp.py walk`) give
  recognisable floor plans (City Hall rooms/pillars; town street, plaza, ramp).

### Emulator — CONFIRMED
- A/B ROMs (build/bsp_test/): both raise City Hall entry 0 to y = 30. B also adds a box x −25..−18,
  y 0..10, z −42..−32 (`bsp.add_box`, 27/27 sample points solid) and stores the BSP **uncompressed as a
  type-0x00 blob** (`bsp.stored_blob`). free_roam_loc5 + warp (5, 6, 0), Sim actor at 0x0225A1E4 (+0x78 pos):
  A → y = 0.0625 (falls to the floor), B → y = 10.0625 (stands on the new box). Screenshots A_vs_B.png.
- Side result: method-0 stored blobs are accepted where the game expects a compressed entry → no type-6
  compressor needed to write files back (phase 4).
- Note: after a warp screenshots stayed stale even at +1800 frames once; one more advance (600) refreshed it.

### Next
- Regenerate the location screenshots (≥ 900 frames after each warp, check the frame actually changed).
- Text edit through a rebuilt ROM + fresh boot; remaining assumed opcodes.
- Phase 4 prep: an editor needs "move / delete a solid cell" → edit planes `d` / prune subtrees in bsp.py.

## 2026-10-06 — Location screenshots regenerated; "stale screen" was a capture lag

- Hypothesis (earlier): after a warp the game keeps the previous picture for 400–1800 frames while loading.
- Test: warp 3 → 4, advance 300 frames, screenshot (still the Basement, same PNG size as before the warp), then
  advance 1 frame and screenshot again → the Casino. Same pattern on ids 0, 1, 2 (stale after one long advance,
  correct after the next call of any length).
- Result: CONFIRMED, the hypothesis was wrong. The game loads a location in < 300 frames; MelonMCP's screenshot
  after an `advance_frames(N)` call returns a frame from before that call. Recipe: advance N, advance 1, shoot.
- Re-shot all 33 ids from build/sims2_rebuilt.nds + free_roam_loc5, chained warps (mode 5, entry 0, +400 +1
  frames), world+0xF4 read back = id every time. All 33 top screens distinct (md5), and every picture matches
  the §7 scene-model name. build/locations/loc_NN.png (both screens) + sheet_a/b/c.png contact sheets.
- Note: the arrival popup on the bottom screen ("granted clearance…", "You've built the Art Gallery…") shows
  on some ids; dismissed with a tap at (130,138).

## 2026-10-06 — Text edit through a rebuilt ROM + fresh boot (end-to-end) — CONFIRMED

### Tool
- `text.py`: `from_str` (inverse of `to_str`; `{xx}` escapes for raw codes), `set_string` (refuses codes that are
  not leaves of the bank's tree), `edit` command. H: from_str ∘ to_str = identity → **15 635/15 635** European
  strings. `tests/test_text.py::test_from_str` added; `¿` is rejected for English (not in its 93-symbol tree).

### Test (build/text_rom_test/)
- Edited 0x0005, 0x0007 and 0x049F (190 chars incl. `
`); entry 123 102 444 → 102 528 bytes; rom.bin rebuilt
  (all other entries identical, checked), ROM rebuilt with `rebuild_rom.py --no-copy`.
- Fresh boot (load_rom, no savestate). Note: title prompt at boot is not 0x0005 but 0x0A1C ("…to continue.", intro
  screen); 0x0005 is the prompt on the logo screen after it. Result: 0x0005 and 0x0007 shown edited; the copied
  sims2_rebuilt.sav holds no game ("No Data") → Create-a-Sim with defaults (✓, then ✓) → conversation 0 starts at
  once: line 0x049F shown in full (6 box lines, `
` honoured), next line 0x4A0 correct (offset shift OK).
- RAM: edited bank byte-identical at 0x021816DC, original absent.
- Savestate `text_test_menu` (MelonMCP side) = this ROM on the main menu, edited bank loaded.

### Next
- Remaining assumed opcodes; BSP edit ops for the editor (move / delete cells).
- Optional: rebuild the Huffman tree to allow characters missing from a language's tree.

## 2026-10-06 — Assumed script opcodes, part 1 (32 → 26 assumed)

### Hypotheses and tests
- **Popup script byte** (0x21 / 0x22 / 0x45 second arg, written to [0x02139FA4]+0x18). Assumed: script run when
  the popup closes. Emulator (new game, savestates `intro_conv0`, `goal0_popup`): goal_start(0, 24) shows 0x990
  "New Mission Goal unlocked!" with +0x18 = 24; closing runs 24 → timer(5) → 4 → 26 message(3, 12) "Time to
  explore!" (+0x18 = 12) → close → 12 camera_reset + player_control(1). With +0x18 = 0 written before closing,
  nothing follows for 1800 frames and the input stays locked. **CONFIRMED.**
- **Mission goals**: Goal_Start / Goal_Complete / Goal_IsNextGoalReady + table 0x0211FB68 (4 missions, 12/8/7/7
  goals, first 0/12/20/27 = 34 goals = the 34 ids started by 0x21 in the data). Popups 0x990 / 0x991 "Mission Goal
  completed!" / 0x992 "Mission Completed!". The u32 per goal is not the NPC passed to 0x21/0x22 (that byte is the
  popup script). **CONFIRMED** (code + texts + emulator for 0x21).
- **player_control**: bits 6/7 of [0x0213E434]+0. Savestate `loc5_control_unlocked`, right ×60 frames: x −375 →
  −387; same with 0xC1 written: no move. **CONFIRMED.**
- **timer**: Nav_EventWatcherUpdate mode 2 decrements once per update; delay 5 → message 13 frames after the popup
  closed (so not seconds). **CONFIRMED** (unit = update ticks).
- **actor (g, i)**: Nav_GetGroupActor reads slot g of the group array (0-based) and item i − 1. In RAM, slot (2,2)
  of location 5 is empty after despawn_item(2, 2); 0x0E anim ids resolve only with this convention.
  The old docstring ("i 0-based, spawned group g") was wrong. **CONFIRMED.**
- **actor_anim**: anim = animation id in the model list {u16 id, u16 BCA0, u16 BCA0/0xFFFF}; 29/33 non-player uses
  resolve to coherent BCA0 names (JebGenericUse at the car, TrisCowerIn/Cower/Out, StatPanelOpen/Close); the 4
  misses are the jail door id 79 (b5 = 1). **CONFIRMED** (data). Player Sim animation table not found.
- **actor_wander / actor_stop**: Jebediah moves ~6.6 units in 600 frames after actor_stop(2,1); idle AI and op
  effect not separable yet. Still ASSUMED.

### Tool / tests
`layscript.py`: OPS updated (0x09 0x0E 0x12 0x21 0x22 0x42 → C, args renamed `script`), GOAL_TABLE, POPUP_SCRIPT,
`actor_item`, `anim_list`, `actor_anim_name` (dump prints animation names). tests/test_layout.py
`test_actor_anims_and_goals`. Ghidra: Goal_IsNextGoalReady, Nav_GetGroupActor, Nav_EventWatcherUpdate.
Screenshot build/opcodes/goal_start_popup.png.

### Next
0x1E/0x1D (patch a script in RAM to call them on a stopped NPC), 0x36 / 0x1C NPC fields, sound ops (SDAT ids),
the player Sim animation table.

## 2026-10-06 — Huffman tree rebuild (new characters in any language) — CONFIRMED

### Hypotheses
- H1: the tree can be replaced freely: only Txt_DecodeString reads it and nothing limits its size.
- H2: a plain Huffman tree (root = node 0, leaves < 0x100) decodes correctly in game.
- Side question: can the original tree be reproduced byte for byte? The layout is neither creation order by these
  frequencies nor canonical (bottom-up, sorted by symbol): both were tested from the original code lengths and
  failed, and a rebuild from the actual frequencies is 264–4220 bytes smaller per bank, so the original tool used
  other counts. Dropped: not needed, the decoder does not care about the layout.

### Tests
- Ghidra: the 3 globals written by Txt_SetBank (0x02139E80 offsets, 0x02139E84 bank, 0x02139E88 nodes) are only
  read by Txt_DecodeString (literal pools 0x02045188–0x02045190); the decoder walks `nodes[n - 0x100]` until
  n < 0x100, with no count or depth check → H1 CONFIRMED.
- `Bank.rebuild_tree()` (heapq Huffman + weight-0 dummy leaf 0x100 = the original "back to root" quirk): all 6 banks
  rebuilt → every string decodes identically (max depth 16–18). `tests/test_text.py::test_rebuild_tree`.
- Emulator (build/text_tree_test/, fresh boot, no savestate): `text.py edit` with 0x0005 "¿Touché? ÀÉÎÕÜ ñçß œ°…",
  0x0007 "Löad-à-Sîm", 0x049F with "¿Ça va? Ünïcödé tést: âêîôû ÄÖÜ ß œ æ å 40° …" → tree 93 → 119 symbols,
  bank 102 444 → 102 144 bytes. Intro prompt 0x0A1C (unedited) OK; title prompt, menu entry and Jebediah's line
  show every character (title_0005_zoom.png, menu.png, conv0_049f.png); next line 0x04A0 and the NPC name OK;
  edited bank byte-identical in RAM at 0x021816DC, original absent → H2 CONFIRMED.
- Bonus: 0x7C œ and 0xB7 … now CONFIRMED (glyphs seen); only 0xB9 (non-breaking space) stays ASSUMED.

### Result
- `text.py edit` keeps the original tree when it can and rebuilds it only when a new character needs it.
  Any character of the European code page can now be used in any European bank.

## 2026-10-06 — NPC behaviour opcodes 0x1E / 0x1D / 0x1C (assumed 32 → 29)

### Hypotheses
- H1 (from the old names): 0x1E makes an NPC wander and 0x1D stops it. The emulator test of part 1 was inconclusive:
  Jebediah kept moving after `actor_stop`.
- H2 (after reading the code): the reverse. NPCs roam by default, 0x1E holds them in place and 0x1D gives the roaming back.
- H3: 0x1C (NPC record +0x1A) selects the NPC's animation set.

### Code (Ghidra)
- 0x1E: Task_AddExclusive(actor, task 0x18, mode byte 3). Task18_Start mode 3 plays Npc_GetMoodAnim(actor, 1) and
  Task18_Update replays it when it ends. Mode 1 = walk to point then run a script (op 0x1B), mode 2 = task 0x30.
- 0x1D: removes task 0x18; for an NPC (actor type 2) adds task 5 again if it is missing.
- Task 5 (Task05_NpcDefaultCtor, given to every NPC at spawn) → task 0xC → task 10 for most NPC ids:
  Task0A_RoamUpdate = idle rand(100)+15 frames, walk to a new point near home, 1/200 chance of an NPC-NPC social.
- Npc_GetMoodAnim: mood m = record +0x1A; m != 0 → anim id 0xDD + 4m + k (k 0 = walk, 1..3 = idles); m = 0 → 3 / 0.
  The BCA0 names of these ids are the same in every NPC model: Angry, Rom, Sad, Drunk, Imp, CowStare, then the social
  sets HiFive / DGuns / Joke / Punch / Scream.
- 0x36 writes record +0x10. It is read by NPC-NPC socials (only 0/1/3/5/10 qualify), a list menu (skips 7/8/9) and a
  "state 9 near actor" check. Scripts set 6 at scene start, 0 after. Role still ASSUMED.

### Tests
- Data: all 12 uses of 0x1C target an NPC whose animation list has the mood's ids (test_layout `test_npc_moods`).
  The location 7 cultists get mood 6 (CowStare) + 0x1E while worshipping the "Prime Heifer".
- Emulator (ROM build/text_rom_test, Jebediah = NPC 22, record 0x02169648, actor 0x021554F0, task tree actor+0xE0):
  - `intro_conv0` (after 0x1E in script 2): tasks 10 / 0xC / 5 present, task 10 active byte 0; task 0x18 active with
    mode 3; animation (actor+0x1FE) 0 = JebediahIdle1.
  - `loc5_control_unlocked` (after 0x1D in script 4): no task 0x18, task 10 active; he moved (−1779001, −285067) →
    (−1763286, −254183) fx32 in 300 frames (~8 units), animations 3 (walk) then 0 (idle).
  - Mood 4 written into +0x1A while roaming: animation 238 = JebDrunkIdle1 at the next idle (the walk stayed 3).
  - Mood 6 written in `intro_conv0`: animation 246 = JebCowStare after 120 frames.
  - Screenshots were not useful: Jebediah is hidden behind the player in that cutscene, so the evidence is RAM.
- **H2 and H3 CONFIRMED**; H1 rejected. Ops renamed actor_hold_idle (0x1E), actor_resume_ai (0x1D), npc_mood (0x1C);
  0x36 renamed npc_set_status (still A). The "26 assumed" count of part 1 was wrong: it was 32, it is now 29.

### Tool / tests / Ghidra
layscript.py: OPS entries, MOOD names (printed by the dump). tests/test_layout.py `test_npc_moods`. Ghidra: Task_*,
Task05/0A/18, Npc_GetMoodAnim, Npc_SetMood, NavOp1C/1D/1E/36 renamed (docs/ghidra.md part 5).

### Next
Sound ops (SDAT ids), 0x36 status meaning, BSP edit ops for the editor (move / delete cells).

## 2026-10-06 — BSP edit ops: delete / move a solid cell (editor)

### Hypotheses
- H1: a cell can be deleted by setting its parent's `front` to 0. Rejected by the code: Clsn_TraceBoxBsp only
  checks `back` against 0; a 0 front would make it read the file header as a node.
- H2: deleting = flip the parent's plane and promote its back subtree to front (or drop the parent when it has
  no back), with no other change in the tree.
- H3: moving = delete + insert the cell's facet planes shifted, clipping the brush through the tree and filling
  every empty back slot it reaches.
- Hit normal: Clsn_TraceWorld copies node normal/d as is (no side flip). 7 303 / 28 810 leaf faces are back-side
  faces in the original files, so the game tolerates inward normals; new faces are still written front-side.

### Code
tools/bsp.py: find_cell, cell_polytope, cell_planes, delete_cell, add_brush, add_box (now through add_brush),
move_cell, axial_plane; CLI `cell`, `delete`, `move`, `box` (raw BSP out, checked with parse + check).

### Data test
- Script over 31 locations × 4 random cells × (delete, move): files valid; 253/256 edits exact on a dense grid,
  the 3 others differ on 1–24 points, all within 0.0004 unit of a plane (fx32 rounding vs float reference).
- tests/test_bsp.py `test_delete_and_move_cells` (8 locations, near-plane points skipped) and
  `test_edit_city_hall_floor` → OK.

### Emulator — CONFIRMED
build/bsp_edit_test/ (make_roms.py builds both ROMs from /rom/, BSP stored as a type-0x00 blob):
- C: City Hall floor slab under entry 0 deleted → the Sim falls through (y −31.8 → −43.1, void on screen).
- D: entry 0 raised to y 30 and the slab moved +10 → the Sim stands at y = 10.0625 (original: 0.0625).
→ **H2 and H3 confirmed.**

### Next
Remaining assumed opcodes (sound, 0x36 NPC status, collections); editor technology to discuss with the user
(phase 5); bg_composite tile codec.

## 2026-10-06 — Remaining assumed script opcodes (29 → 8)

### Hypotheses
- H1: the "collection" ops (0x2B/0x2D/0x47/0x48/0x4A) handle collectibles. **Rejected**: the 33-entry table
  0x0211F9EC lines up with the 33 location ids (text 0x43 + id; priced entries = hotel rooms, byte 3 = parent
  lobby). H1': they are the location state (+0x218 open, +0x210 offered).
- H2: 0x2D tests a second story-flag set. **Rejected**: FUN_0206462c jumps to Coll_IsOwned(G+0x41F8, arg), so it
  tests the open bit of a location (the args 4, 7, 0x15, 0x20 are location ids).
- H3: 0x36 status values have fixed meanings set by data. Found the NPC initial table 0x02132900 by a strided search
  for the RAM values; categories match the characters (7 staff, 8 animals, 9 aliens/goons/robots…).

### Code (Ghidra)
- Door_TryEnter (0x020643fc): destination closed → sound 0xCC, no warp. Game_InitNewGame (0x02064f18) opens 14
  locations and offers 15.
- 0x25: FUN_02082a94 3-slot {npc, script, amount} + menu entry 7 "Pay ($@1)"; 0x41: 2-slot {npc, script, item};
  0x24: per-location dust (max 9), hotel table 0x02131F34; 0x3A: 7 fire slots, prop 260 = `Fire` (model name);
  0x43: Weather_IsActive (override bytes [G]+0x4650/0x4651, 0 = pseudo-random by date); 0x4D: door actor state
  machine, anim 135 = the door model's only animation; 0x4B: hooks 0x11 / 0x15 / 0x1E used as block-0 script 1
  of locations 17 / 21 / 30; 0x51: Optimum Alfred anims OptiPropFly/PropOut/CallWait/CallExt; 0x3C: the phonebook
  (Phone_DrawPhonebook, texts "Phonebook" / "Exit"); 0x03/0x04 pause/resume channel 0.
- Sound data is `data/SoundData.rom`, a custom container (no SDAT/SSEQ magic): track names not decoded.

### Data / RAM
- RAM `loc5_control_unlocked`: open bits 0x6B086C6C and offered bits 0x942D950F = exactly the Game_InitNewGame
  lists. NPC statuses = table values except the ones scripts changed (Jebediah 6).
- tests/test_layout.py `test_location_and_door_ops`: priced set = 14 hotel rooms, parents ⊂ {2, 3, 13, 27, 33},
  all location args < 33, all 12 `door_open` uses resolve to a door item, 0x25/0x41 scripts exist → OK.

### Emulator — CONFIRMED (build/opcode_test/)
Savestate `loc5_control_unlocked`, Sim placed at (−369, 17, 22), D-pad up 60 frames toward the City Hall door:
- open bit 6 set → City Hall loads ("Welcome to Strangetown City Hall", door_open.png);
- open bit 6 cleared (0x6B086C2C) → after 460 frames the Sim is still outside against the closed door
  (door_locked.png). → **H1' (open bit) and H2 confirmed.**

### Result
layscript.OPS: 21 opcodes moved to C, names changed (if_location_open, location_open, location_offer,
if_hotel_score, npc_ask_money, npc_want_item, door_open, hotel_dust_add, start_fire, set_weather, phone_gate,
npc_met, location_setup, music_pause/resume…). Still A: 0x07 0x08 0x2C (never used), 0x40 shop item, 0x44, 0x47
(offered = construction list), 0x49, 0x4C. Location ops print the place name.

### Next
Choose the editor technology with the user (phase 5). Optional: confirm 0x47 in the City Hall construction menu.

## 2026-10-06 — Evaluation of the `nitrogen` library (github.com/jorgecafe/nitrogen) for the editor

### Hypothesis
nitrogen (MIT, Python ≥ 3.10, NSBMD/NSBTX/NSBCA/NSBTA reader → glTF/OBJ/… + software renderer) can turn our
BMD0 models into a format any editor technology can display.

### Test (sample of 12 out of 329 nitro_model entries, scratch venv, nothing installed in the project)
Scenes 79 AlienRoom, 2051 CityExterior, 2088 CityHall_Ext, 2510 Desert, 4112 HotelLobby_Ext, 6812 RatCave,
7188 SecondFloorLobby; objects 9 AbductFX, 15 Alien, 261 Arcade, 676 Balloon, 893 BluePrints.
`nitrogen info` + `nitrogen convert --unlit --nearest` + `nitrogen gallery`.

### Result
- 12/12 parsed and converted to GLB, no error; MDL0 names identical to tools/nitro.py; 135 textures incl. the
  4×4-compressed `*_cmp4` ones decode correctly (visual check of the thumbnails).
- Thumbnails plausible for 11/12. Arcade (261) shows only the swirl texture + bars, no cabinet body: not
  checked further (may be the model itself or a culling / material flag issue). → ASSUMED OK, to be verified.
- Units / origin: AlienRoom GLB bbox matches the BSP collision bbox (`bsp.py obj 0`) to ~1.5 units on X/Y →
  same space as layout/BSP coordinates (CONFIRMED on 1 location; RatCave mesh extends beyond its BSP, as expected).
- Not tested: BCA0 / BTA0 / BVA0 animations (BVA0 probably unsupported), the remaining 317 models.
- Read-only: no BMD0 writer (fine if the editor never edits meshes).

### Conclusion
Usable as an offline BMD0 → glTF converter for the editor's 3D view; does not help for rom.bin, layout, BSP,
text or bg_composite.

## 2026-10-06 — Phase 5: editor technology chosen

- **Decision (user)**: the most economical option, reusing the existing `tools/` scripts.
- **Choice**: Python backend on the stdlib `http.server`, with no new dependency. It imports `tools/*.py` as libraries: `layout.parse/write`, `bsp.parse/write/add_box/move_cell/delete_cell`, `text.Bank/set_string`, `layscript.describe`, `rombin.read_entries/build` and `rebuild_rom`. The UI is a local web page in the browser, plain HTML/JS with vendored three.js. It shows a 2D top-down view and a 3D view, loading GLB files converted offline by nitrogen. GLTFLoader reads them natively.
- **Why**: every format parser/writer already exists in Python and is round-trip tested, so the editor is mostly UI. Python and a browser run unchanged on Windows and Linux, with no packaging or compiled GUI toolkit. Tkinter (stdlib) was rejected because it has no 3D view.
- **Assumed / to verify**: the GLB placement of layout items, which depends on the item transform → model mapping.

## 2026-10-06 — Phase 5, milestone 1: read-only editor (editor/)

- **Built**:
  - `editor/server.py`, a stdlib HTTP server;
  - `editor/backend.py`, a thin JSON layer over `tools/` (`layout.parse`, `layout.model_of`, `bsp.to_obj`, `layscript.describe`, `nitro.model_name`, `locations.read_table`);
  - the browser UI `editor/static/` (top-down canvas plus three.js r170 3D, vendored).
  - nitrogen is installed in `.venv`, pinned to commit e22879d (`editor/requirements.txt`).
- **Tested**:
  - The backend builds JSON for all 33 locations: layout and BSP brushes, under about 1 s each (Desert is the slowest).
  - nitrogen converts every model the locations reference: 175/175 (65 scene + 110 item models: npc/prop/object/timed_prop), no failure, 32 s in total, cached in `build/editor_cache/models/`.
  - Headless Edge screenshots of location 5 (CityExterior): the top-down view matches the `bsp.py png` orientation. In 3D, the scene models, BSP cells and item positions line up.
  - Selecting DoorCityHall shows dest 6 (CityHall) entry 0, which agrees with the door confirmed in game on 2026-10-05.
- **Assumed (shown as such in the UI)**:
  - Facing direction: angle 0 faces +z and positive angles turn towards +x.
  - Box items (types 3, 4, 7) are drawn centred on the item position, axis-aligned.
  - Both are to be checked against an emulator screenshot.
- **Open**:
  - Waypoint links are not drawn: their index base is unverified.
  - Animations are not loaded (`--no-anim --no-texanim`).

## 2026-10-06 — Editor: model textures / UVs fixed (tools/nitro.py bmd0_to_glb)

- **Symptom (user)**: textures look wrong on every model in the 3D view.
- **Findings** (nitrogen e22879d, GLB path):
  1. **V flipped**: nitrogen stores `v = 1 - t/h`, but glTF (and three.js `GLTFLoader`, `flipY = false`) maps v = 0 to the first PNG row, which is DS t = 0.
     - Tested: a software render of the GLB UVs next to nitrogen's own rasterizer (which re-applies `1 - v`). The atlas of model 0020 (alien) only lines up in the second one.
  2. **Wrap modes lost**: every sampler was `CLAMP_TO_EDGE`. The repeat/flip bits 16-19 are in the material's teximage_param (+0x14, e.g. `0x00030000`), but nitrogen reads them from the TEX0 entry, which has none.
     - Scan of 1261 materials: 991 repeat S+T, 182 mirror on S and/or T, 88 none (untextured).
  3. **Texture SRT applied wrongly**: 219 materials use the material SRT (flags +0x1E bit 0). nitrogen adds the translation in texels and pivots at (0, 0).
     - Values seen: 90°/180° rotations, scales 0.25-12, translations 0.5 / 0.08 / 16, all in UV units.
     - All 175 models have texMtxMode 0 (Maya, model header +0x16). The Maya matrix was taken from noclip.website `nns_g3d` `calcTexMtx_Maya`.
     - Its SRT layout (fx32 scale, 2 × s16 sin/cos, fx32 translation) is confirmed by the record sizes: the next material starts right after 4 rotation bytes. (noclip reads 2 × u32 for the rotation, nitrogen 2 × s16; the data agrees with nitrogen.)
- **Fix**: `tools/nitro.py bmd0_to_glb(d)`, called by `editor/backend.model_glb` instead of the nitrogen CLI.
  - It reads the raw SRT of each material through a hook on `nitrogen…model._read_material`.
  - It replaces each textured material's `texture_mat` with the Maya UV map. That map is pre-compensated for nitrogen's `/ width` and `1 - v`, and rescaled from the material's original size to the stored texture size (only Dinnerware, entry 2070, differs: 44 vs 64).
  - Each material gets a texture copy carrying its own wrap mode (repeat, mirror only together with repeat, clamp).
  - Same options as before: unlit, nearest, bind pose, no animations.
- **Tested**:
  - 175/175 models regenerate (33 s).
  - Against the old GLBs: POSITION/NORMAL/COLOR/JOINTS/WEIGHTS are byte-identical. On textured primitives, 1983 UV sets differ only by `v → 1 - v`, and 257 (SRT) are recomputed.
  - Samplers now: 1860 repeat/repeat, 380 with mirror.
  - Visual checks, against the emulator screenshots `build/locations/loc_08.png` and `loc_18.png`, using a glTF-semantics software render and a headless Edge shot of the editor (ModernRoom):
    - 0020: the alien atlas is coherent;
    - 0079 / 0343: walls and floors tile instead of smearing;
    - 2491: checkerboard floor;
    - 5295: red walls with the light arcs under the lamps, as in the game.
- **Assumed, not code-confirmed**: the exact Maya SRT formula (rotation direction, pivot, translation sign) comes from noclip, not from the game's NNS code in arm9. Lead: find NNS's texture SRT function table (4 modes) in Ghidra.

## 2026-10-07 — Editor milestone 2: editing, save, ROM build (editor/project.py)

- **Built**:
  - `editor/project.py` holds the edit layer, and `server.py` calls it through `POST /api/edit` and `POST /api/build`.
  - Operations: move an item, set its angle or raw record (same size and type), duplicate it (appended at the end of its group, so no index shifts), delete it, move an entry point, and on collision delete a cell, move a cell or add a box.
  - Each edit is saved at once to `build/editor_project/{layout,bsp}/NNNN.bin`, with undo. Content equal to the original drops the file.
  - "Build ROM" substitutes the edited entries into the original rom.bin (layout raw, BSP as a type-0x00 blob), then runs `rebuild_rom.rebuild` on `build/editor_rom/unpacked` → `build/editor_rom/sims2_edited.nds`.
  - UI: edit form, drag the selected item in the top-down view, Delete / Ctrl+Z, "Edit collision" mode (click a cell, click again for the one below), Undo / Revert location / Build ROM.
- **Hypothesis**: deleting an item breaks the scripts and waypoints that address items by index.
  - **Tested** (data, all 32 layouts): all 452 non-player `(g, i)` references sit in variant blocks and resolve inside their own block's groups. Block 0 scripts reference no item. 30 references to group 0 would also fit block 0's group 0, so they are ambiguous.
  - **Rule implemented**:
    - A referenced item cannot be deleted.
    - References to later items of the same group are decremented in the item's own block, and so are waypoint links.
    - For a block 0 item, references from the variant blocks also count, and a delete that would have to renumber them is refused.
  - `tests/test_editor_project.py`: 1214 single deletes checked (71 refused), duplicate + delete gives back the original bytes in every group, no edit → rom.bin byte-identical, BSP edits keep the invariants. Headless Edge UI run (drag, form, duplicate, Delete key, cell delete, add box, undo ×7): no JS error.
- **End-to-end in the emulator — CONFIRMED** (`build/editor_rom_test/`):
  - Edits made through the editor API in location 1 (ArtGallery):
    - duplicated PictureFrame3, moved to (14, 6, −40), angle 0;
    - deleted the pedestal cell (z −44.7..−26.7);
    - added a box x −9..9, y 0..18, z −36..−32.
  - Built with the editor's build, then ROM A (`build/sims2_rebuilt.nds`, unmodified) against ROM B, same steps:
    - `loc5_control_unlocked`, warp (5, 1, 0), 400 frames;
    - player control byte [0x0213E434]+0 is 0xC1 after the warp, so write 1;
    - hold Up.
  - A: the Sim stops at z −46.86 (pedestal face −44.72 minus 2.14). B: it stops at z −38.17 (box face −36 minus 2.14, predicted −38.14). It now walks into the pedestal model, whose collision is gone.
  - B shows the duplicated frame upper left, facing the camera like the original on the back wall: angle 0 = model front towards −z. +x is on screen-left with this camera. This is consistent with the editor's rotation convention, but it is one data point, not the sign proof.
- Fixed in passing: `layout.py dump` used the removed `Block.tail`. `rebuild_rom.py` now exposes `rebuild(work, out)`.

## 2026-10-07 — Where room furniture comes from (beds, couches, toilets…)

- **Question**: hotel rooms show no furniture in the editor. Hypotheses: (a) a default set spawned by code, (b) the save.
- **Data**: the layouts of locations 8/15/18/29 hold no furniture; their scene BMD0 node/material names are room shells only
  (walls, floor, fireplace…). 189 of the 331 prop ids (0x0211CD2C) are never placed by any layout, including CheapBed ×10,
  BedDeluxe ×10, CouchBasic/Dlx ×8, FridgeBasic ×6, dressers, arcades.
- **Code — CONFIRMED** (both hypotheses are part of it):
  - Map_EnterLocation → Map_SpawnRoomFurniture (0x02087df4) spawns the furniture list of the room slot from the game
    state [G]+0x41F8 + slot*0x58 (u8 prop id, u8 cell x, u8 cell z, u8 rot; up to 14 entries; count u32 at +0x54).
  - Room slots (Room_SlotFromLocation, table 0x0211F9D4): 0 DeluxeRoom(8), 1 SmHotelRoom(29), 2 ManagerSuite(17),
    3 JungleRoom(15), 4 ModernRoom(18), 5 Penthouse(20).
  - Game_InitNewGame → Room_InitDefaultFurniture (0x02073d48) fills each slot from the arm9 table 0x0211FA70: the same 6
    items in every room (FridgeBasic 86, CheapBed 114, CouchBasic 133, ShowerBasic 185, Toilet 209, SinkBasic 233) at
    room-specific cells/rotations, count = 6.
- **Assumed, not verified**: the [G]+0x41F8 area is written to the save (the player can buy/move furniture, so it must
  persist); cell → world mapping (grid file loaded by Arc_LoadRawArea1 in Map_SpawnRoomFurniture, Unk_020c1eb4); rot = ×90°;
  CouchBasic at (65,65) in DeluxeRoom/(57,54) in JungleRoom looks out of range — maybe a special/hidden cell.
- **Next**: dump [G]+0x41F8 in RAM in a room, decode the grid file, then show these defaults in the editor (and later edit the
  default table and/or the save).

## 2026-10-07 — Room grid decoded, furniture placement reproduced, shown and editable in the editor

- **Hypothesis**: Room_PlacePropOnGrid (ex Unk_020c1eb4) turns a (prop, x, z, rot) entry into a world position with the
  grid file loaded by Map_SpawnRoomFurniture.
- **Code**: the grid is the 5th argument (rom.bin entry from Room_GridEntryFromSlot, u16 table 0x02127754). Two branches,
  chosen by the flag +0x30 of the prop's placement object (actor+0x130): floor (cell x, z; rot × π/2) and wall (x = wall
  slot, z = cell along the wall, angle from the slot). Formulas and file layout: docs/formats/roomfurn.md.
- **Data**: header fields guessed from the code then checked on the 6 grids (`tools/roomfurn.py verify`): cell area
  width × depth padded to 4, n_walls at +0x15, a second cell layer after the wall slots. First guess (wall table up to
  the end of the file) gave 2001 "walls" and non-multiple-of-8 sizes on 4 files: wrong, corrected.
- **Emulator** (savestate loc5_control_unlocked, warp to each room, RAM dumps in build/furniture/):
  - the room lists in [G]+0x41F8 equal the arm9 table byte for byte;
  - actor angle +0x88 = rot × 6433 (π/2 fx32): rot is in quarter turns, CONFIRMED;
  - placement objects of the 6 props read in RAM (wall flag, offsets); first predictor had odd rotations swap only the box
    extents (bed off by 2.4): the offsets swap too. After the fix, **36/36 items match within 0.001** (fx32 rounding).
  - the "out of range" couch cells (65,65) and (57,54) are fine: those grids are 142×112 and 83×65.
- **Editor**: `furniture` kind in editor/project.py (24 bytes per room slot, patched into arm9.bin at build),
  `op: furniture` in server.py, items in pink in the list / top-down / 3D (snapped drag, form prop/rot/cell).
  Tests: tests/test_editor_project.py (validation, undo, arm9 diff limited to the table, positions vs RAM).
- **End to end — CONFIRMED**: ROM with the DeluxeRoom bed moved to cell (30,20) rot 0 (build/furniture/rom/), fresh boot +
  Create-a-Sim: the new game's [G]+0x41F8 holds 0x00141E72, and in room 8 the bed actor sits at (−72.044, 0, −139.515),
  angle 0, exactly the editor's prediction.
- **Assumed**: save persistence of [G]+0x41F8; placement data of the other 325 props (editor draws them as floor props
  without offsets and says so).

## 2026-10-07 — Placement data of every furniture prop decoded

- **Question**: wall flag and X/Z offsets of the placement object for props other than the 6 measured defaults.
- **Code, wall flag**: decoded the jump table of Prop_CreatePlacementObject (331 `b` entries → 94 handlers) with a small
  ARM scanner. In each handler I took the ctor called after the allocation, then the 4th argument it passes to
  Furn_InitPlacementBase. 22 classes reach that base ctor, which gives 182 furniture props. Two classes take the flag from
  outside: from the case (r3) for Furn_CtorWallFlagArg, and `prop >= 9` for props 6–11. The other ids get non-furniture
  objects. Floor/wall lists are in docs/formats/roomfurn.md §4. The flags of the 6 measured props match.
- **Code, offsets**: Furn_InitPlacementBase walks the actor's node list (actor+0x68, count +0x72) and takes the first node
  of class 2. RAM, bed in room 8: node (0, 0.5, −7.5), class 2. Then off = max(0, −(box_w·s − |box_x|·s + node)) per axis.
  I traced the node list back to a small rom.bin file named by the prop's anim list (u16 [2] of entry 0, e.g. 1987 for
  CheapBed). Its parser is Node_LoadFile → Node_ReadRecord (ITCM, function created) → Node_ReadFrames plus one virtual
  read per kind: the frame sizes are 28/32/48/36 bytes for kinds 0/3/4/5. My first guess (fixed 40-byte records, class
  byte read straight from the file) did not fit 16 files. With the code's layout, all 108 node files parse to their exact
  size. The formula gives back the 6 measured offsets exactly (fx32 integers).
- **Emulator, 36 new props**: build/sims2_rebuilt.nds + free_roam_loc5, then warp to 5 (savestate `furn_measure_loc5`).
  Writing the room list in [G]+0x41F8 does not work: the warp re-copies the arm9 default table into it. I patched the table
  in RAM (0x0211FA70) instead, 6 props per room, warped into the 6 rooms and read actor +0x78…+0x88. The set covers floor
  props in all 4 rotations, wall props, node kinds 0/3/4/5, multi-frame node files (props 9, 178, 183) and props with
  several anim entries. **36/36 match within 0.001** (tests/test_roomfurn.py, data in build/furniture/obs.txt).
- **Editor**: the prop field is now a list of the 182 furniture props (name, floor/wall). edit_furniture refuses any other
  id, and every position is exact.
- **Side observation**: the warp (mode 5) re-runs the default copy, so a RAM edit of [G]+0x41F8 is lost on the next warp.
  It does not tell whether a real save keeps the list (not investigated: the user does not need save editing).

## 2026-10-07 — Published as a git repository

- Repository: `git@github.com:df4l/sims-2-ds-editor.git`. `.gitignore` keeps out all game data (`rom/`, `rom_bin/`,
  `*.nds`), `build/`, the Ghidra project (it holds the disassembled code), `.venv/` and `ndstool.exe`.
- New `tools/setup_rom.py`:
  - unpacks the user's own `.nds` into `rom/` with ndstool;
  - BLZ-decompresses `arm9.bin` (ndspy);
  - drops the 12-byte footer that `ndstool -x` keeps after arm9;
  - checks SHA-1 of `arm9.bin` (module params field `compressed_static_end` zeroed) and `rom.bin`;
  - runs `rombin.py extract`.
- `rebuild_rom.ndstool()` finds `ndstool.exe` or `ndstool` on the PATH (Linux). Requirements are merged into the root
  `requirements.txt`.
- **Test**:
  - built a ROM with a BLZ-compressed arm9 (ndspy compress + `ndstool -c`), like a cartridge dump;
  - cloned the repository into `build/setup_test/clone` and ran `setup_rom.py` on it;
  - result: arm9 decompressed, both hashes match, 8866 entries extracted. In the clone, the 7 tests pass, the editor
    API serves locations and GLB models, and `project.py build` writes a ROM.
  - `test_layout.py` needs `rom_bin/catalog.csv`, so setup now also runs `tools/catalog.py`.
- **Found during the test**: `ndstool -x` writes the arm9 footer `21 06 C0 DE …` (12 bytes) at the end of `arm9.bin`. The
  project's `rom/arm9.bin` never had it. Without stripping it, the hash differs, although the code is identical.

## 2026-10-09 — Editor milestone 3: "add item" palette, typed fields

- **Fields per type** (`layout.FIELDS`), from Nav_SpawnEntity. The constructor never reads these bytes:
  - NPC/prop +0xF (values 0..4 in the data);
  - door +0x14 (0..4);
  - trigger +0xE/+0xF;
  - event watcher +0xB (always 1).

  So the editor keeps them as they are and offers no field for them.
  - Prop ids are a u8: type 2 = 0..255, type 10 = 0x47..0x146.
  - Waypoint links are u16 in the file, but Nav_AddWaypoint reads only the low byte.
- **Model tables** (scan of {u32, u16 BMD0, u16} records until the entry is not a BMD0):
  - NPC: 63 records;
  - object: 30 records, then the prop table starts, so door +0x13 = 30 = box only;
  - prop: 331 records.
- **Timed prop +0xB is a collect bit**, not a flag. Nav_SpawnEntity tests bit +0xB of the u32 array at [G]+4.
  - The 50 orbs use 0..49, each once. Duplicating one would make collecting it hide both.
  - The editor gives a new or copied orb the first free bit (50) and refuses a used one.
  - ASSUMED: bits 50..63 are free (the second u32 word). Not checked in code.
- **Two runtime limits, CONFIRMED by code**, now checked on every layout save (`layout.limit_errors`, also in
  `layout.py verify`):
  - Map_LoadNav parses into a 0x800-byte arena. Each non-empty array costs n·record + 8: entry points 4, the
    2 block slots 0x24, and per parsed block: groups 8, items of each group 8, scripts 8, c6 8, c4 8, c5 12.
    - The originals peak at 1628 bytes (location 13, variant 1), so 52 more items fit there.
  - Nav_AddWaypoint appends to a 32-pointer array at world+0x6C with no bound check. The count byte sits right
    after it, at +0xEC.
    - The originals peak at 20 waypoints (location 2).
- **Location checks** (`project.check_item`):
  - door destination has that entry point;
  - trigger group/script exist in the variant block(s);
  - waypoint links point at another waypoint of the same group;
  - collect bit unused.

  Run on all 1285 original items, they fail only the 2 doors already known to point at a missing entry point
  (location 31 → 2, entry 3).
- **Tests** (`tests/test_editor_project.py`, 13/13):
  - typed get/set round-trip on all 1290 items;
  - adding each of the 10 types, then undo;
  - refusals;
  - both limits: the 53rd item in location 13 and the 33rd waypoint in location 2 are refused.
- **UI test**: headless Edge driven over CDP (stdlib client, scratchpad). It covered:
  - door through "Add at view centre": the entry list follows the destination;
  - typed edit of size and destination;
  - NPC 22 placed by a click on the map;
  - used collect bit refused;
  - all edits undone.
- **Emulator, CONFIRMED** (`build/palette_test/`). Built through `project.add_item` into location 5, block 0 group 0:
  - prop 102 `YetiStatue`, never placed by any layout, at (−355, 15, −48);
  - a box-only door to location 6 entry 0 at (−390, 15, −48), size 10×30×10.

  Then savestate `loc5_control_unlocked`, warp to 5/entry 8:
  - a prop actor (vtable 0x0212FD44) is at x −355, z −48, y snapped to 14.69;
  - the statue is visible, and absent on the reference ROM with the same steps (`yeti_added.png` / `yeti_original.png`);
  - the door box is in RAM (half-size 5/15/5, kind 0x12, dest 6, entry 0);
  - the Sim walked into it and location 6 loaded (`door_to_loc6.png`).

## 2026-10-09 — Object info table: in-game names and icons (editor icon pickers)
- **Goal**: the user asked for the game's icons in the Add item palette instead of the name lists.
- **Hypothesis 1 (data)**: contact sheets of the 1192 sprites (first frame) show NPC portraits (184, 513, 561…)
  and furniture icons (beds 691–740, couches 2255–2346…). In rom.bin each furniture model is followed by one bundle
  per colour variant: `[img8_pal256][sprite triplet][bg_composite]`.
- **Hypothesis 2 (table)**: a search for u16 2255 (Camel Couch icon) in arm9 finds 18-byte records at 0x02123726:
  `{2255, 2256, 2257, 0, 591, 2258, 2258, 75, 0}`, with text 591 = "Camel Couch". Walking the table gives NPC names,
  then props.
- **Code, CONFIRMED**: the only references to 0x02122A00 are 3 accessors (renamed in Ghidra):
  - Info_Prop 0x0208afd0 = base + 18·(prop + 0x3B), called by Furn_InitPlacementBase with the actor's prop id;
  - Info_Npc 0x0208afe8 = base + 18·(npc + 2), called by State0E_ShowNextLine with the speaker id, so the icon is the portrait;
  - Info_ByIndex 0x0208b000.
- **Data, CONFIRMED**:
  - NPCs 0..55 have text id 0x143 + npc, the known NPC names;
  - the 6 default room props give White Fridge, Black Mahogany Bed, Black Couch, White Shower, Off-White Toilet,
    Porcelain Sink;
  - `objinfo.py sheet`: all 329 own icons decode, and each one matches its name on visual check. The exception is
    prop 253 Cellphone (entry 1951, not a plain sprite). Icon entry 6180 is a shared placeholder, treated as no icon.
- **Assumed**: +0x0E is the price, +0x0A is the buy / inventory picture. +0x10 is unknown.
- **Editor**:
  - icon grid + search for the npc / prop fields (palette, item edit form, room furniture form);
  - `/api/icon/<npc|prop>/<id>.png`;
  - in-game names in the prop lists.
- **UI test**: headless Edge (Playwright, temp venv outside the project). It covered:
  - the prop grid, NPC portraits and furniture form are shown;
  - searching "couch" then clicking sets the field to prop 130 "Citron Green Couch";
  - no JS error (only a favicon 404).
- **Tests**: `tests/test_objinfo.py` (names, accessor offsets, icon decoding); all 8 test scripts pass.

## 2026-10-09 — Prop colour variants rendered black in the editor (variant textures)

- **Symptom (user)**: adding prop 212 "Toilet (Dirty)" shows an all-black model.
- **Cause**: BMD0 7881 (shared by toilets 209–220) has a 32×32 8bpp texture `CleanToilet` whose texels and palette are
  all zero. 68 prop ids use such a blank model (beds, couches, dressers, showers, toilets, sinks, arcades).
- **Hypothesis 1 (data)**: the variant's texture is the `img8_pal256` entry just before its icon bundle (icon tiles − 1).
  This holds for the toilets but it is not proof, and the code later shows it is wrong for 126–127 and 150–159.
- **Code, CONFIRMED**: a search for u16 7897 in arm9 finds a u16 table at 0x02117F10. Its literal-pool reference sits
  inside the Prop_CreatePlacementObject jump table, in code Ghidra had not disassembled (0x02013500…, now disassembled).
  The case does `entry = TABLE[prop − BASE]`, then Gfx_LoadTexPal256 0x020bd908, then
  Gfx_ReplaceModelTexture 0x020bbee0 (actor +0x1A4). Both functions were renamed.
- **File layout, CONFIRMED (data)**: palette (512 bytes) first, then the texels. Decoding entry 7897 both ways, only
  this order gives an image (a toilet with green stains).
- **Tool**: `roomfurn.prop_texture(prop)` decodes each case straight from arm9 (pc-relative literals including negative
  offsets, sub #base, ldrh). It finds 123 props. `nitro.bmd0_to_glb(d, tex)` swaps the format-4 texture of the same size
  and its bound palettes.
- **Editor**: `model_tex` in the item / furniture JSON, `/api/model/<e>.glb?tex=<t>` (cache `<e>_t<t>.glb`).
- **Check**: contact sheet of the 122 swapped textures, all plausible. Through the server, 7881 + 7897 gives the dirty
  texture, and 68 objects of the 33 locations now carry `model_tex`. All 8 test scripts pass.
- **Not covered**: arcade screens 164–176 (no texture call in their case) and PlasmaTV 104 (a 32×64 strip, model kept as is).


## 2026-11-14 — Editor rewritten in Godot (branch godot-editor)

User request: no web UI, no Python dependencies, user picks the ROM at runtime, standalone Godot project.
- Ported to GDScript (godot/scripts/core): .nds reader + rebuild (regions kept in order, growing ones push the rest by
  multiples of 0x200, header CRC recomputed, secure-area CRC left as ndstool does), BLZ decompression, rom.bin and its
  blob codecs (type 0 raw copy accepted only as a single blob filling the entry), layout + scripts, BSP (iterative,
  doubles), room furniture, BMD0 -> ArrayMesh (nitrogen port + Maya UV / wrap fixes, winding reversed for Godot), sprites.
- Tests (godot/tests): test_core — rom.bin rebuild identical, unchanged ROM rebuild byte-identical, 32/32 layouts and
  32/32 BSP byte-identical, 65/65 scene models build, BLZ output = ndspy on arm9.bin, furniture positions = Python.
  test_edits — add prop / door, refused door to a missing entry, duplicate, delete, move, entry angle, collision box,
  furniture edit + refused non-furniture prop + undo, export, reopen: all edits present, header CRC OK. Passed on a
  plain-ARM9 ROM and on a ROM whose ARM9 is BLZ-compressed (like the retail one). Export writes the decompressed ARM9
  with compressed_static_end = 0 only when furniture is edited.
- Emulator: the exported BLZ-based test ROM boots and reaches the town intro (build/godot_test/boot.png).
- Not done: in-game check of each edit from the Godot export (same bytes as the Python pipeline produced, checked by reopening).


## 2026-11-16 — Modding foundations: ARM9 extension, new rom.bin entries, BPS patches, test in emulator

Godot is now the only editor. Low-level tools for adding new content rather than only editing existing records.
- **ARM9 layout, CONFIRMED (code)**: module params, autoload list, overlay table and crt0 read from the binary;
  `OS_GetInitArenaLo` (0x020FAF54) returns the main arena start 0x02152F00 (= end of overlay 10) from the literal at
  0x020FB024. Details in docs/formats/arm9.md.
- **Hypothesis**: padding the ARM9 up to 0x02152F00, appending data and raising that literal gives a RAM area loaded
  at boot that the heap never covers. **Test**: ROMs with a 64 KiB and a 512 KiB extension carrying markers, fresh
  boot to in-game, warps to locations 9, 30, 2. **Result, CONFIRMED**: markers present and intact, heap header moved
  to the new arena start, every location loads. Heap headroom past 512 KiB not measured (assumed).
- **rom.bin**: one appended entry → boots and plays (CONFIRMED). Table rebuild of an unchanged archive stays identical.
- **BPS export**: IPS cannot address past 16 MiB (ROM is 64 MiB). BPS encoder uses the rebuild's copy map
  (unchanged regions and rom.bin entries, shifted) as SourceCopy actions. Test edit set: 72 KB patch. Checked by
  the GDScript decoder and by an independent Python decoder (zlib CRCs, result byte-identical to the exported ROM).
- **Test in emulator**: export to the project folder, start the chosen emulator on it (checked with melonDS 1.1 on
  Windows). Direct boot into a given location not done (needs a boot-path patch).
- Tests: godot/tests/test_foundations.gd (25 checks), test_core and test_edits still pass.


## 2026-11-17 — Text editing in the Godot editor

- **Port**: `godot/scripts/core/text_bank.gd` now writes banks: decode every string, `codes()`, Huffman
  `rebuild_tree()` with the same tie-breaks as `text.py` (heap on weight, order, symbol, plus the weight-0 dummy leaf
  0x100), `write()`, `from_str` / `to_str`. Edits are a new project kind `text:<rom.bin entry>` (whole bank),
  autosaved, undoable, exported as a replaced rom.bin entry. The UI shows edited text everywhere (scripts, NPC names).
- **Bug found**: the Godot reader mapped 0xB9 to a plain space instead of U+00A0, so 103 strings per bank did not
  round-trip through text → bytes. Fixed (`char(0xA0)`).
- **Limit added**: strings over 0x3FF bytes are refused (Txt_GetString buffer is 0x400 bytes). From the code's
  buffer size; not tested in game.
- **Tests** (`godot/tests/test_text.gd`, 0 failures): 6/6 banks re-encode byte-identical; text → bytes → text
  identical for every string of the 6 banks; ASCII edit keeps the tree; accented edit rebuilds it; restoring the
  text drops the edit; undo; French edit; export → reopen shows the edits, the other 8864 rom.bin entries unchanged,
  header CRC OK. English bank after edits 0x0005 / 0x0007 / 0x049F is **byte-identical** to `text.py edit` with the
  same strings (102 444 → 102 060 bytes). test_core, test_edits, test_foundations still pass.
- **Emulator, CONFIRMED** (build/text_godot_test/, fresh boot of the exported ROM): logo screen shows
  "Touch to start (édité)" (0x0005), main menu shows "Load-a-Sim ¿À É Î Õ Ü ñ ç ß œ ° …" (0x0007, too wide for the
  button, as expected). 0x049F not replayed in game (same bank bytes as the Python test of 2026-10-06).


## 2026-11-17 — Script editing in the Godot editor

- **Text form of a block's scripts** (`layscript.gd`: `disassemble` / `assemble`): one op per line,
  `name(field=value, …)`, `script N` headers, `;` comments (NPC names, dialogue lines, regenerated on load). Every
  argument byte is covered: named fields from `OPS`, then `_<offset>` for bytes no handler reads and the padding up
  to the ARG_SIZE record, so the text loses nothing.
- **Bug found**: the opcode specs used `x` both for "unused byte" and for the x coordinate of 0x0D actor_teleport and
  0x1B actor_walk_to, so `decode_args` / `describe` silently dropped those x coordinates (Python and Godot). Unused
  bytes are now named `_` in both tables.
- **Edit checks** (`EditProject.set_scripts`): every group / script ref of every script and trigger box must stay in
  its target block (`target_blocks`: the block itself, or every variant block for block 0); conversation < 216,
  location < 33; at least one script (the game runs script 1 when the block loads); u16 block size; runtime limits.
  The original data has **0** broken references (32 layouts), so the rule is strict.
- **Tests** (`godot/tests/test_scripts.gd`, 0 failures): 32 layouts, 659 scripts, 1267 ops: text → assemble gives
  the same bytes (with English and French comments, and without), every layout rebuilt byte-identical; assembler
  errors (unknown op, missing field, range, numbering, duplicates); new script + call, refusals (group past the
  block, dropping a still-called script, conversation 250), undo, export → reopen. test_core, test_edits, test_text,
  test_foundations still pass.
- **Emulator, CONFIRMED** (build/scripts_test/, fresh boot, new game): location 5 block 1 script 3
  `conversation(0, 1, 25)` replaced by `spawn_run(0, 28)` + a new script 28 `conversation(2, 1, 25)`. The intro
  plays Jebediah's conversation 2 ("Hold on now, I'm thinking!", then "Shoot, kid…") instead of conversation 0
  ("Whoa there, slick"): appended scripts are run by the game.
- **UI**: Scripts tab is now an editor (CodeEdit, highlighting, opcode completion, Ctrl+S apply, error line
  highlighted, unapplied text kept across item edits, "Text of line" opens the strings of a conversation / message
  in the Text tab, Opcodes… reference).


## 2026-11-17 (later) — Conversation and message tables in the Godot editor

- **Hypothesis**: the conversation table can grow if every pointer to it is found. **Test**: Ghidra script scanning
  every aligned word of arm9 + overlays 0..18 for values in 0x0211F16C..+0x6C0, and a Python scan for words into the
  line arrays. **Result**: 3 literals, all to the base (2 arm9, 1 in overlay 15); line arrays reached only through
  the table; one array shared by 6 ids. Message table: 1 literal (NavOp45_Message), 26 records. Npc_SetTalkConversation
  uses 0xD8 as "none". Txt_DecodeString has no id bound → strings can be appended. Details: docs/formats/text.md §4.
- **Implementation**: `GameData` reads the tables through the literals (moved tables = 256 records);
  `EditProject` conversations section (set / add / delete conversation, set / add / delete message, `add_string` to
  the 6 banks as one undo step, users of an id across all layouts, checks: >= 1 line, text ids exist, speaker <= 0x40);
  export through `Arm9Mod` (in place / extension / moved table) + `NdsRom` overlay support (decompress, patch,
  store uncompressed, overlay table replaced). Script checks now use the real conversation / message counts.
  UI: Dialogue tab (conversations / messages list with search, line rows: speaker, text id, order, preview,
  "Text" link; new string from a text box; usage list; notes for ids 3 / 0x23 / 0xA6 / 0xBC).
- **Tests**: `test_conversations.gd` (read-back 216 / 501 lines / 26 messages, in place vs extension vs shared array,
  refusals, new strings in 6 banks + undo, new ids 217 / 218, table move + overlay 15 patch, export → reopen,
  second export on top of the first: table not moved again) 0 failures; `test_dialogue_ui.gd` 0 failures;
  test_core / edits / foundations / text / scripts still 0 failures.
- **Emulator, CONFIRMED**: new conversation 217 + new message 26 + 3 new strings play at a new game
  (docs/formats/text.md §5). First try used `message(…, queued=0)` from the conversation's end script: UI+0x18 was
  set to 25 but no popup appeared and the intro stalled; with `queued=1` it works (the game's own choice in 20/22 ops).


## 2026-11-17 (latest) — Direct boot into a location for Test ▶

- **Hypothesis**: requesting state 2 mode 5 (what Create-a-Sim does) at boot starts a playable new game anywhere.
  **Code**: Game_InitNewGame is only called by State2_LocationEnter when arg0 == 5; Create-a-Sim (overlay 3,
  0x0214BD40) requests state 2 (5, 5, 8) on slot 0 and state 0xC on slot 1. Startup code 0x02000EA8 requests the
  movie 0x26 + logo state 0x2B (step 3); 0x2B step 4 is a soft-reset path only.
- **Test 1** (RAM, original ROM, frame 32 while 0x2B runs): write the two requests → City Hall, UI and text OK,
  Sim moves. **CONFIRMED**.
- **Test 2** (ROM patch of the startup requests, 0x2B never runs): game starts but the UI has no icons. Same with a
  RAM injection at frame 21 (before 0x2B starts): no icons, dark bottom screen. → 0x2B must run (cause not found).
- **Final**: hook the 0x2B step-change call (0x0205440C) into a 24-word extension routine issuing both requests.
  `test_boot.gd` 0 failures (routine words, literal / bl targets, re-patch of a test ROM, refusals, normal export
  unchanged). Emulator, cold boot: location 6 entry 0 (UI complete, door to location 5 works, new-game intro script
  plays) and location 9 entry 0. **CONFIRMED**. docs/formats/arm9.md §5.
- **Editor**: Test ▶ uses the selected entry point (else the first one) of the shown location; File menu check
  "Test starts in this location (new game)" (on by default) turns it off.


## 2026-11-19 — New location ids (34+): feasibility study, prototype

Goal (agreed with the user): real new location ids, not the replacement of an existing one. Prototype:
`godot/tests/proto_newloc.gd` (not a test: builds a ROM, options through environment variables), ROMs and
screenshots in `build/newloc_proto/`.

- **Inventory (code)**. 33 is the "no location" sentinel (world+0xF4, Map_FreeLocation, Door_TryEnter +0x4820,
  Coll +0x336 link, Map_SetLocationLightKeys). About 25 ARM9 functions compare a location id with 0x21 (loops
  `< 0x21`, sentinel tests); overlays not scanned yet. Per-location arrays **inside the game state** (fixed size 33,
  followed by other fields): [S]+0x449C u8 music override (0x2A = record music), Coll +0x210/+0x218 bitsets (64 bits:
  ids up to 63 fit), Coll +0x220 u32 timers, dust struct u8[33] +8 / u32[33] +0x2C, S+0x4418 u32[33],
  `Unk_0208387c_LocStateSpawnProps` 0xFC-byte record per location at S+0x18+0x70 (id 34 would write into the NPC
  records at S+0x21DC). S = [0x0213E434]. ARM9 tables: location table 0x021332E0 (only the 7 Map_GetLoc* accessors),
  light keys 0x02121EFC (16 bytes per id, 1 literal), layout variant table 0x02121EB4 (12 rows {loc, variant by
  chapter[5]}, 1 literal, loop bound `cmp r2,#0xc` at 0x02084C20), price/score 0x0211F9EC, dust 0x02131F34; name text
  = 0x43 + id (id 33+ collides with other strings). Hard-coded id lists in State2_LocationEnter (+0x27c depth value,
  FUN_020bc9f8 argument), Fire_OnLocationEnter, Unk_020844c4_LocField12, Map_EnterLocation (id 9).
- **Decision**: keep 33 as the sentinel, number new locations from 34 (the `== 0x21` tests stay right).
- **Test 1**: location table moved to the extension and grown to 64 entries, ids 33..63 → record of location 6
  (City Hall), direct boot into id 34. Control: same ROM booting id 6 → City Hall OK (relocation alone is fine).
  Id 34: **black screen, hang** in Map_LoadLocation (world+0xF4 = 34, location object never stored).
  Cause: [S]+0x449C+34 is past the 33-byte music array and holds 0xFF after Game_InitNewGame → bad music id.
- **Test 2**: + `ldrb r0,[r0,#0x49c]` at 0x02084C68 replaced by `mov r0,#0x2a` → **id 34 loads and plays**
  (UI complete, Sim moves). Scene dark and partly wrong (far geometry missing).
- **Test 3**: + State2_LocationEnter defaults set to the City Hall values (0x02077040 → mov r2,#0x2a000,
  0x02077054 → mov r2,#0x14000): geometry correct. Light keys table moved/grown (0x02085E04 `cmp r1,#64`): used
  (pointers = row 34) but no visible change.
- **Test 4**: + variant table row for 34 (copy of the row of 6): the City Hall welcome popup plays (variant 3 at
  chapter 0 instead of the default 1). **CONFIRMED**: the variant table decides which layout block runs.
- **Open**: the scene is still about half as bright as City Hall (mean pixel 190 vs 418). Not from: light keys
  (world+0x100.. identical to the control), music, variant, +0x27c / FUN_020bc9f8 args, world+0xF4 at run time
  (set to 6 after the load: no change), S+0x4A80 / S+0x4ABC (poked: no change). A full 4 MB RAM diff against a
  control built with the same patches (`loc6_f.nds`, same heap layout) shows only ~24 small differences; none is a
  light value. Leads: GPU state / VRAM written once at load (material, palettes, toon / edge tables), the 2496-byte
  block at 0x02166C90 that differs, statics at 0x0213D790..0x0213D7B0.
- **Brightness solved (same day)**: the 4 MB diff was misleading. The 2496-byte block at 0x02166C90 is the RNG
  state (624 words, index at 0x0213D790), and the 0x8000xxxx values are timestamps. The real lead was the 3D
  register: DISP3DCNT (0x04000060) = **0x699** for id 34 against 0x19 for City Hall, i.e. **fog on** (bit 7, shift 6).
  Chain, from the code: G3X_SetFog (0x020F7F94) ← Amb_UpdateFogAndTint (0x0208A13C, fog off only for ambience
  type 1; per-type rows 16 bytes at 0x02133494) ← Amb_SetType (0x0208AB54) ← Map_UpdateLocationAmbience
  (0x02076230, every frame). In that function the type (r8) defaults to 1, but when S+0x44C0 ≤ 0 it is set to
  **0xA** unless the location id is in a hard-coded list {2, 5, 6, 9, 0xE, 0x13, 0x14, 0x18, 0x19, 0x1C, 0x1E}
  (compares at 0x0207667C..0x020766D0) — in effect the "indoor" list. RAM: controller at S+0x4648, type bytes
  +0x14/+0x15/+0x23 = 0x0A (id 34) vs 0x01 (id 6). (The earlier poke of S+0x4ABC was undone by the next frame.)
- **Test 5**: + `cmp r4,#0x1e` at 0x020766CC replaced by `cmp r4,#0x22` (test only: steals the slot of id 0x1E).
  DISP3DCNT = 0x19, and after closing the welcome popup the top screen is **pixel-identical** to the id-6 control
  (`build/newloc_proto/l34g_open.png` vs `l6_open.png`; without the patch 45 038 pixels differ). **CONFIRMED.**
- Same function, other hard-coded id lists (not yet handled for 34+): ambient sound jump table on id ≤ 0x18 at
  0x0207629C, "no ambient sound" list at 0x0207659C..0x020765E8, ids 5 / 9 / 0x13 / 0x14 special cases.
  Real fix: a per-location "indoor" byte table in the extension, read by a small hook instead of the compare list.
- **Next**: scan the overlays for location ids; per-location game-state arrays for ids 34+ (relocated arrays + save
  format, or a donor slot); per-location ambience flags.


## 2026-11-19 (later) — New location ids: overlay scan

- **Method**: `tools/ovscan.py` (capstone, ARM mode; no Thumb `bl` to a location function in any overlay) on the 19
  BLZ-decompressed overlays (build/overlays/). It reports calls to the ~30 location functions, compares / movs with
  0x20..0x22, literals to the location-indexed tables or to S = [0x0213E434], and offset-0xF4 loads (world+0xF4 =
  current location id). Then I read each hit by hand. Most hits are not about locations: touch coordinates (ov18 `cmp r4,#0x21`),
  item ids (ov02 / ov06 `cmp #0x22`), state object fields (ov13 +0x49C), UI box helpers (ov10 → 0x020840DC).
- **Result, CONFIRMED (code)**. Overlay code that depends on a location id:
  - **ov01** (states 0x20 / 0x36, construction menu): loop over ids 0..32 (`cmp r5,#0x21` at 0x02149CA0), shown if price
    (0x0211F9EC through 0x02073F6C) ≠ 0, offered (0x020735A8), not owned, and S+0x4418[id] < S+0x480C; list
    u32[33] at obj+0x4C (obj+0xD0 is the next field: exactly 33 slots). Shows name 0x43+id and parent 0x43+rec[3].
    Purchase writes S+0x4418[id] and has hard-coded effects for ids 4, 7, 0x1A. → ids 34+ are never listed (safe).
    To sell one: loop bound + list capacity + price table + S+0x4418 array.
  - **ov04** (state 0x29): fixed room list {29, 8, 15, 18, 20} at 0x0214A7A0. Not tied to the 33 count.
  - **ov05** (state 0x22, music picker): **writes** and reads S+0x449C[world+0xF4] (0x0214A124 / 0x0214A658).
  - ov12 (state 0x2C) room furniture through Room_SlotFromLocation (rooms only); ov03 (Create-a-Sim) light keys with
    the sentinel 33 and the new-game request (2, 5, location 5, entry 8); ov11 layout group / script (any id);
    ov04 / ov12 / ov14 / ov15 Coll_GetScore (global). Not tied to the id count.
- **Music override array, complete list of consumers** (S+0x449C, u8[33]; byte 0x44C0 = S+0x449C+36 is the
  "outdoor" value read by Map_UpdateLocationAmbience): reads 0x02084C68 (Map_LoadLocation, patched by the
  prototype), **0x02084D18 (Map_PlayLocationMusic, NOT patched)**, ov05 0x0214A658; writes ARM9 0x0201F640 /
  0x0201F688 / 0x0201F700 (Unk_0201f190_PropMsgHandler, message 0x5E = stereo), ov05 0x0214A124. Map_PlayLocationMusic is
  called from 6 ARM9 sites (0x0201F710, 0x0202856C, 0x0202E244, 0x0207C214, 0x0207CCFC, 0x020B03E4) and ov10
  (states 0x16 / 0x17, on return to state 2).
- **Prediction (not tested in the emulator)**: in prototype id 34, any Map_PlayLocationMusic call reads 0xFF →
  `FUN_020a8068(0xFF − 0x2B)`, and a stereo / music picker write at id 36 would overwrite S+0x44C0.
- **Next**: replace the 7 S+0x449C accesses with a hook that maps id ≥ 33 to a 64-byte array in the ARM9
  extension (not saved: the override resets on reload for new locations). After that, the other per-location
  game-state arrays (Coll bitsets are already 64 bits; timers +0x220, dust, S+0x4418, 0xFC records).


## 2026-11-19 (later) — New location ids: music override hooks

- **Inventory redone** (all literal words 0x4498..0x44C4 and `#0x49c]` operands, ARM9 + overlays): **12 accesses**,
  not 7. Missed earlier: in Unk_0201f190_PropMsgHandler, `ldrb r1,[r0,r5]` + `add r2,r0,r5` at 0x0201F69C (stores
  through r2 at 0x0201F6B8 / 0x0201F6D0), and two prop update reads 0x0201FFD8 / 0x02020C94 (`ldr =0x449C` form).
  Full table: docs/formats/arm9.md §6.
- **Hook**: godot/scripts/core/loc_ext.gd (`LocExt.music_hook`), 10 trampolines (`b` there and back, temps pushed,
  flags kept), id ≥ 33 → 64-byte array in the ARM9 extension. Prototype option NEWLOC_MUSIC=1 (replaces the
  0x02084C68 `mov r0,#0x2a` test patch). Generated code checked with capstone.
- **Test** (melonDS): build/newloc_proto/loc34_m.nds boots into id 34, City Hall welcome popup, music track 5
  (= the record music; sound state [0x020D5560] = 0x021424F8, current track +10), world+0xF4 = 34, S+0x449C+33..
  unchanged (00 FF FF 00). Control loc6_m.nds (same hooks, id 6): same track, scene OK. **CONFIRMED** for the
  read in Map_LoadLocation and the id < 33 path. Not exercised: writes (stereo / picker) and Map_PlayLocationMusic
  (triggered by script sound op 0x2A0/0x2B and state returns; the phone menu does not call it).
- **Next**: other per-location game-state arrays (timers Coll+0x220, dust, S+0x4418, 0xFC records), the hard-coded
  indoor list of Map_UpdateLocationAmbience (a per-location table instead of the 0x020766CC test patch).


## 2026-11-20 — New location ids: full support checked (trampolines, emulator), Locations tab

- **Trampolines (hypothesis: encodings and register use correct)**. Test: capstone disassembly of every trampoline
  of the exported extension (build/newloc_test/arm9_ext.bin, hooks.txt) next to the original code of each site
  (live registers after the site, flags, branches into replaced words, lr before the `bl` of the ov01 purchase hook).
  Result: encodings correct. **One bug found**: the threshold was `cmp id,#33`, so id 33 (the "no location"
  sentinel) took the new path (its name became City Hall's text instead of the original 0x64). Now `cmp id,#34`
  everywhere, and the moved tables keep the original word 33. Test check added (location table word 33).
- **Missing hook (emulator)**. A door 5 -> 34 warped to location 23 (RoomBeingBuilt2). The door warp FUN_0209b838
  reads the construction timer S+0x4418[dest] a second time (0x0209B898 / B8A4); for 34 that is S+0x44A0, inside the
  music array (0x2A bytes) -> "being built". Scan of every S+0x4418 access (literals 0x4400..0x449C, `#0x4xx]`
  operands, ARM9 + overlays): this was the only one left. Hook at 0x0209B88C (ip = timer base). After it: 34 loads.
  CONFIRMED (emulator).
- **Test bugs**. (1) The Saloon door of location 5 is two door items: a model door [0,0,0] and a trigger box
  [0,0,18], both dest 24; the Sim goes through the box. The test now re-targets every door item with dest 24.
  (2) The test called undo once too often after deleting / restoring 36 and so cancelled the door edit; it now
  checks the doors in the exported ROM itself.
- **Emulator, all CONFIRMED (cold boots, build/newloc_test/)**: boot into 34, 35 and control 6; save in 35 -> save
  and load screens show "Test Saloon"; loading puts the Sim back in 35; its door leads to 5; door 5 -> 34; the
  construction menu (needs story flag 0x13, S+0x4814 bit 19; set in RAM for the test) lists "Test Saloon (Town
  Square) §500", buying it takes the money, sets owned bit 35 and removes it from the list. Details:
  docs/formats/arm9.md §7.
- **Editor**: Locations tab (create from a template + name, behaves like, price / score / menu parent / offered,
  name -> Text tab, open, delete; picker refreshed on undo). godot/tests/test_locations_ui.gd (11 checks).
  `open_location` falls back to 5 when the location no longer exists. Prototype godot/tests/proto_newloc.gd removed
  (its ROMs stay in build/newloc_proto/; its history is in git).


## 2026-11-20 (later) — Own 3D scenes for new locations: BMD0 writer, BSP compiler, glTF import

Goal: a new location (34..63) gets its own geometry from a glTF scene instead of its template's models.
- **Survey of the 65 scene models** (hypothesis: a small subset of NNS G3D is enough). Script over every location
  model: GPU commands, texture formats, counts. Result: baked vertex colours (0x20), few normals, no matrix commands
  in the display lists; 4x4 (533) and 8bpp (337) textures; ≤ 3 models per location. Writer target = one node, one
  material + shape per surface, render commands copied from Jail_Ext (docs/formats/bmd0.md §1).
- **Loader** (Ghidra): Map_LoadLocation accepts anim_count 0 but reads anim_list[0].trs → dummy anim entry
  {FFFF, FFFF, FFFF}. No name lookups. CONFIRMED (code + emulator).
- **Dictionaries** (hypothesis: NNS patricia tree, zero-key root, insertion in index order). Test: rebuild every
  dictionary of the 329 BMD0 of rom.bin. First result 1 738 / 2 626: same tree but other node numbers on
  multi-node dictionaries → nodes are numbered in preorder. After the fix 2 626 / 2 626 byte-identical. CONFIRMED.
- **Read → write → read** of the 65 scene models: same triangles within one VTX_16 step, same colours (first test
  compared exact quantised keys: false failures at rounding boundaries; now a tolerance match). CONFIRMED.
- **BSP compiler** (godot/scripts/core/bsp_build.gd). Trace limits from Clsn_TraceBoxBsp: only flags & 7 read;
  explicit stack of 0x3C frames at DTCM 0x027E14AC, 40 frames (ASSUMED from the next symbol); original depth ≤ 29.
  Test: recompile the cells of 8 locations, compare 4 000 random points each: all agree (Desert 986 cells → depth 30,
  171 KB vs 252 KB). One bug found on Desert: a subtree that collapses into one solid leaf ended on a back side
  (not allowed) → children are emitted first, then the plane is oriented. Emulator A/B: City Hall recompiled vs
  original, same input → same Sim position to the bit. CONFIRMED.
- **glTF import + project** (scene_import.gd, EditProject.import_scene, keys model:SCENE+0x100k+id, record with
  self pointers to the dummy anim entry, LocExt.install self_ptrs). godot/tests/test_scene.gd builds a room in code,
  writes it as GLB with Godot's glTF writer and imports it back.
- **Emulator, location 34 (test room)**: rendered (walls, vertex colours, checker texture). First build: the Sim sat
  at y −0.44, inside the floor box: the floor top was at the entry height, the Sim's feet started inside the 0.5
  slab and it fell to the bottom face's slab. Originals keep the floor ~1 unit under the entries (City Hall entry 1,
  floor 0) → room lowered by 1: Sim at y 0.0625 on the floor; east wall stops it at x −6.34 (face −4 − radius),
  the invisible `-col` block at x −21.66 (face −24 + radius), the `-nocol` pillar lets it through. CONFIRMED.
  Design change found on the way: `-col` objects used to replace the automatic collision (the floor vanished as soon
  as one existed); now they add to it (option to turn the automatic part off).
- **Emulator, location 35 (City Hall re-encoded, 8bpp)**: geometry right, textures garbage. Hypotheses: (1) total
  texture budget — originals reach 190 784 texels: 183 552 and 149 760 still broke, so not the total; (2) the
  file size — no; (3) code: Gfx_LoadModelResource → Gfx_AllocModelTexVram makes ONE VRAM allocation per file for
  its plain texels and gives up on failure. Originals: largest plain block in one file 116 480, Gym's 151 552 are
  two files. Test: same 149 760 split into 2 files (≤ 116 480 each) → renders like City Hall
  (build/scene_test/scene_35_split.png). CONFIRMED: per-file limit (exact value between 50 944 and 149 760,
  128 KiB VRAM slots ASSUMED). Writer: budgets 116 480 / file, 151 552 / location, palettes 17 120; textures
  packed into ≤ 4 files, largest halved when over.
- **Editor**: Locations tab, per new location: Import .glb / .gltf (scale, slab depth, automatic collision), report
  (triangles, textures, files, budget, collision depth, warnings), "Use the template's". 3D view shows the
  imported model. godot/tests/test_locations_ui.gd extended (import, report, 3D view, back to template).
- Ghidra: Gfx_LoadModelResource 0x020bc1a8, Gfx_AllocModelTexVram 0x020bd468, Gfx_InitModelInstance 0x020bd700,
  bookmark on Clsn_TraceBoxBsp (trace stack).
- Open: 4x4 texture encoder (2.5× more texture detail, separate VRAM block), lit materials, texture animations,
  camera of a new location (it keeps the template's: in the test room it looked from outside the walls at first).


## 2026-11-20 (latest) — 4x4 texture encoder for own scenes

Goal: more texture detail in imported scenes (8bpp City Hall needed 10 textures halved).
- **Survey of the game's 4x4 textures** (hypothesis: one palette entry per block, as in a naive encoder). Script over
  the 326 TEX0 blocks of rom_bin/dec: per file, blocks vs distinct palette indices, modes. Result: heavy sharing
  (e.g. 9 632 blocks on 276 palette slots), mode 3 for 91 %, mode 2 never. Hypothesis rejected → codebook of colour
  pairs. Also: TEX0 order dicts / plain / 4x4 texels / indices / palettes; per file ≤ 38 528 B of 4x4 texels (≤ 32 768
  in scene models), per location ≤ 67 584 (Atrium); plain + 1.5 × 4x4 ≤ 190 784 (Store).
- **Ghidra**: Gfx_AllocModelTexVram (0x020bd468) makes three allocations through function pointers (plain texels,
  4x4 texels with flag 1, palettes): the limits are runtime state, measured in the emulator instead.
- **Encoder** godot/scripts/core/tex4x4.gd (docs/formats/bmd0.md §6). Test godot/tests/test_tex4x4.gd: the game's
  4x4 textures re-encoded with the game's pair count: RMS 0.30 (20 textures) / 0.61 (40) per 255, PSNR 58.6 / 52.5 dB
  — close to the game's encoder; 8bpp textures as 4x4: 35-36 dB, better than 16-colour palettes; the encoder's own
  error equals the error after Nsbmd._decode_4x4 (format written as read); transparent texels stay transparent.
- **Writer**: textures > 16 colours → 4x4 when `tex4x4` (editor checkbox "4x4 textures", on by default); bins packed
  on both plain and 4x4 sizes. test_scene.gd: new location 36 = City Hall re-encoded in 4x4.
- **Emulator**: 36 renders like City Hall (2 files of 4x4 first, then 1 file of 56 960 B). CONFIRMED.
- **VRAM probes** (godot/tests/probe_tex4x4.gd, City Hall geometry, N unique 256×256 textures): 64 KiB in one file OK;
  96 KiB in one file, 128 KiB in one file, 2 × 64 KiB → garbage (whole file / second file). First probe used 32-px
  checkers: a speckled wall could have been aliasing → redone with 128-px quadrants, still speckled → real garbage.
  Conclusion: the 4x4 space left per location is between 64 and 96 KiB (rest used by Sims / NPCs / props, ASSUMED).
  Budgets: 65 536 per file, 67 584 per location.
- Open: lit materials, texture animations, per-location camera; finer 4x4 limit (64..96 KiB, depends on the NPCs?).

## 2026-11-23 — Arcade machines (props 164–176)

Goal: understand why arcade screens are black and how the games work, toward own arcade games.
- **Lead**: RTTI strings `17CArcadeController` / `19CInteractableArcade` → typeinfo → vtables 0x02130c70 / 0x02133820.
- **Code**: the controller (task 0x31) calls a 10-entry table 0x0211E200 of {Init, Update, Free}. Space Armada Update
  clears a 0x1000 buffer, runs the game, draws 1bpp sprites in 2bpp, then FUN_020bbde8(actor+0x1A4, 1, buf, 0x1000) →
  **FUN_020bbde8 is a model texture upload, FUN_020bbcf0 a palette upload** (renamed Gfx_UploadModelTexImage /
  Gfx_UploadModelTexPalette). Earlier journal entries assumed FUN_020bbde8 was the bg_composite tile codec: reopen that
  lead (bg_composite may be texture data for models; NOT checked).
- **Prop → type**: the 13 Prop_CreatePlacementObject cases (jump table 0x02011E2C) store a type byte: 164 random 0..9,
  165..173 = 0,1,3,4,2,5,6,7,8, and 174 / 175 / 176 (Lunar Lander, Space Gunner, Log Jump) = 0 → unimplemented games.
- **Emulator** (build/arcade_test/loc24, direct boot into location 24, Space Armada at layout item 23): menu
  "Insert Coin ($1)", money 2000 → 1999 (G+0x2F60 confirmed). Screen buffer [0x0213E59C] dumped and decoded as
  128×128 2bpp: aliens 7×4, cannon moved left, shot (screen0.png). CONFIRMED.
  Controller found in RAM by its vtable (0x0215D104); type byte +0x28 forced to 9 after Stop, Insert Coin again →
  type 9 buffer ([0x0213E6C4]) = one small sprite at (25, 50): stub (screen9.png). CONFIRMED.
- Side note: the gameplay camera ended up inside the cabinet (Sim teleported in front of it); not investigated.
- Format sheet: docs/formats/arcade.md. Next: own games in the free slots 174–176 (see the sheet §6).

## 2026-11-23 (later) — Own arcade games: assembler + test card on cabinet 174

Goal (user: option 2 = a VM in the ARM9 extension, start with a test card): validate the whole path before the VM.
- No ARM toolchain on the machine (no gcc/clang/keystone) → **ArmAsm** (godot/scripts/core/arm_asm.gd): two-pass ARM
  assembler (data processing with operand2 auto-swap, mul/long mul, clz, all ldr/str forms, ldm/stm/push/pop, b/bl/bx/blx,
  adr, `ldr =` literal pools, .word/.hword/.byte/.ascii/.align/.pool/.equ, expressions). Test: test_armasm.gd writes 57
  instructions + expected text; tools/check_armasm.py decodes with capstone: 57/57 identical (after fixing 5 wrong
  *expectations*: pc-relative offsets checked by hand, capstone prints a 1-register stmdb as stmdb). Errors refused.
- **ArcadeExt** (godot/scripts/core/arcade_ext.gd): table 0x0211E200 moved to the extension (+ own types 10..), the 9
  literal words rewritten (a scan finds exactly those 9 words pointing into the table), cabinet case `mov r3,#0` →
  `mov r3,#type`. Project edit kind `arcade:<prop>`. Test test_arcade.gd: 54 checks, capstone listing of the
  extension reviewed by hand (calls, pool, table).
- **Emulator** (build/arcade_test/card/arcade_card.nds): cabinet 174 = "Arcade-Lunar Lander", attract frame visible,
  game runs (frame counter at 0x0215304C), buffer = expected card byte for byte with A held (inverted), Stop → Free.
  Update is called every 2nd frame (30 Hz). CONFIRMED.
- Pitfall: a read at 0x0215404C instead of 0x0215304C looked like "update never runs" — compute addresses with
  Python (memory note).
- Next: the VM (bytecode + interpreter in ArmAsm, same interpreter in GDScript for a preview in the editor).

## 2026-11-24 — Arcade VM: script games run in the game

Goal (plan "option 2"): games written in a small language, compiled to bytecode, one VM in ARM in the extension and
the same VM in GDScript for the preview (docs/formats/arcade_vm.md).
- **Written** (session 2026-11-23, finished today): ArcadeScript (compiler), ArcadeVM (reference), ArcadeVmAsm (ARM
  copy, ≈ 3.2 KiB), ArcadeExt.install_vm / install_script_game (game block + thunks), examples (Lunar Lander, card).
  Project edit `arcade:<prop>` now JSON {lang, source}.
- **Tests**: test_arcade_vm.gd all pass (folding = runtime for every operator, limits, drawing, errors, examples).
  test_arcade.gd hung on a missing `Arm9Mod.read_u16` (headless Godot does not quit on a script error: run it with
  output to a file, not piped into tail) → fixed, all pass; the ARM op table matches ArcadeVM opcode by opcode.
- **Hypothesis**: the ARM VM draws exactly what ArcadeVM draws. **Test**: arcade_self.nds (self-test script using every
  opcode except RND / SFX), Insert Coin at location 24, dump the game block (0x02153B58) and the screen buffer, compare
  with tests/arcade_vm_ref.gd for the same tick and keys. Tick 105, no key: screen 4 096 / 4 096 bytes, palette, 256
  vars identical. Tick 113, A + LEFT held: identical. **CONFIRMED.** A first dump at "tick 112" had the vars of tick
  113: the dump landed inside an Update (the game logic spans frames) → re-dump one frame later.
- **Lunar Lander** (arcade_lander.nds): falls, crashes, "CRASHED!", restarts, thrust flame. Sessions ended by
  themselves: tested key by key → **A stops the session** (the Sims UI takes A for the selected bottom-screen action,
  "Stop"); LEFT, RIGHT, UP, B, X, Y do not. Example switched from A to B. Documented in arcade_vm.md §1.
- Next: the Arcade tab in the editor (source, live preview, sprites / palette, cabinet choice).

## 2026-11-24 (later) — Arcade tab in the editor

- `godot/scripts/ui/arcade_tab.gd` (ArcadeTab), wired in main.gd (tab "Arcade", refreshed with the other tabs; while
  shown, the item list is hidden and the side panel widened). Layout: left column = preview 256×256, Pause / Restart /
  Step / Attract, palette, sprite editor, placement; right = the source.
- The source stays the only truth: the sprite grid rewrites the rows of its `sprite` block (CodeEdit remove / insert
  inside one complex operation = one undo step), the palette pickers rewrite the `palette` line (colour shown live,
  text written when the picker closes). Preview recompiles 0.3 s after the last keystroke; on an error the last good
  program keeps running and the line is highlighted.
- Preview drawing: a canvas shader decodes the 2 bpp screen bytes (uploaded as a 32×128 R8 texture) with the 4
  palette colours, so no per-pixel GDScript loop at 30 Hz.
- **Test**: tests/test_arcade_ui.gd (window): example → 40 frames drawn, pixel / new sprite / palette edits reach the
  compiled program, compile error keeps the old program and is refused by Apply, Apply / drafts per cabinet / undo,
  "selected prop → cabinet" on location 24 item 0/0/23, ARM9 install with the game. 31/31 pass; test_dialogue_ui and
  test_locations_ui still pass. Screenshot checked (layout readable at 1600×900). Not done: playing with the keyboard
  in the preview by hand, and an emulator run of a game made through the tab (same path as test_arcade, already
  CONFIRMED).
