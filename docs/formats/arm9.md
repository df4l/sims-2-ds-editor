# ARM9 memory layout, extension area (The Sims 2 DS, ASJP)

How the ARM9 binary is laid out in RAM, and how the editor adds new data or code to it without moving anything.
Code: `godot/scripts/core/arm9_mod.gd` (`Arm9Mod`), test `godot/tests/test_foundations.gd`.

## 1. Layout — CONFIRMED (module params + overlay table + crt0 disassembly)

Module params at arm9+0xAFC (found by the `0xDEC00621 0x2106C0DE` nitrocode pair, +0x1C):

| field | value | meaning |
|---|---|---|
| +0x00 / +0x04 | 0x02141760 / 0x02141778 | autoload list (2 entries) |
| +0x08 | 0x02139220 | autoload data start (= end of static code/data) |
| +0x0C / +0x10 | 0x02139220 / 0x02149B40 | static .bss |
| +0x14 | 0x020BF5F8 | compressed_static_end (0 once decompressed) |

Autoloads: ITCM 0x01FF8000 (0x6460 bytes), DTCM 0x027E0000 (0x20E0 bytes). Overlays 0–18 all load at
0x02149B40; the largest (10) ends at **0x02152F00**. ARM7 loads at 0x02380000.

Boot order in crt0 (0x02000800): BLZ decompression (MIi_UncompressBackward, if +0x14 ≠ 0) → autoload copy
(0x020009B8: for each list entry, copy `size` words from a running source pointer, then clear `bss`) → clear the
static .bss → OS init.

`OS_GetInitArenaLo` (0x020FAF54, switch on the arena id): id 0 (main) returns the literal at **0x020FB024** =
0x02152F00, i.e. the end of the largest overlay. Every other id returns other literals of the same pool.
In RAM, a NitroSDK expanded heap header ("EXPH") sits exactly at the main arena start.

## 2. Extension area — CONFIRMED (emulator)

The card boot loader copies the whole ARM9 binary (header size field) to 0x02000000, and nothing writes
0x02152F00+ before the arena is set up. So:

1. pad the (decompressed) binary with zeros up to 0x02152F00 - 0x02000000 = 0x152F00;
2. append the new data there (the extension);
3. set the literal at 0x020FB024 to 0x02152F00 + size (rounded up to 32).

The padding covers .bss and the overlay area, which are cleared / loaded later anyway. A ROM exported this way
reopens with its extension (an ARM9 longer than 0x152F00 bytes).

Checks (2026-11-16, `build/foundations_test/`, fresh boot → Create-a-Sim → in game):
- 64 KiB and 512 KiB extensions with markers at both ends: markers present after boot and still intact in game; the
  "EXPH" heap header moves to the new arena start (0x02162F00 for 64 KiB).
- 512 KiB: the intro plays, warps to the three biggest locations (9, 30, 2) load and render, markers intact.

**ASSUMED**: 512 KiB (`Arm9Mod.EXT_MAX`) leaves enough heap for every screen (only the intro and 3 locations were
tried). The free heap size has not been measured.

## 3. Finding pointers to a table — tool, not a proof

`Arm9Mod.pointers_into(lo, hi)` lists the aligned words of the static image whose value falls inside a table. ARM and
Thumb code load addresses from word-aligned literal pools, so the base of a table shows up this way; an address
built by arithmetic (base + constant) does not, and a data word can be a false hit. `relocate()` copies a table
(possibly grown) to the extension and rewrites the words equal to its base; it returns the other hits for review.
Example: the default room furniture table 0x0211FA70 has exactly one reference, the literal at 0x02073F68.
Any relocation must still be checked in the code and in the emulator, table by table.

## 4. rom.bin new entries — CONFIRMED (boot)

The game reads the rom.bin offset table one entry at a time (`Arc_GetEntrySize`, `Arc_ReadEntryRaw`: seek idx*4,
read 8 bytes) and keeps no entry count, so entries can be appended (`RomBin.build(replacements, added)`). A ROM with
one extra entry (8866) boots and plays. Using such an entry needs code or a table that points at its index.

## 5. Direct boot into a location (test ROMs) — CONFIRMED (code + emulator)

Code: `EditProject.boot_patch` (godot/scripts/core/project.gd), test `godot/tests/test_boot.gd`. Used by **Test ▶**
only (File > "Test starts in this location"); a normal export never has it.

Boot flow (code):
- Startup code 0x02000DF4..0x02000EF0 (before the main loop calls Game_UpdateStateMachine): error cases request
  state 0x2E; the normal case requests state **0x26** (movie 3 "Sims1", then state 0x18 = title) on slot 0 and state
  **0x2B** step 3 (logo / copyright screens, State2B_LogoUpdate 0x02054178) on slot 1.
- State 0x2B step 4 (same two requests) only runs after the ready flag G+0x19, i.e. not at power on.
- End of Create-a-Sim (overlay 3, 0x0214BD14): `[0x0213E434]+0x68 = choice`, then
  `Game_RequestStateOtherSlot(G, 2, 5, 5, 8)` (slot 0: state 2, mode 5, location 5, entry id 8) and
  `FUN_0204818c(G, 0xC, 0, 0, 0)` (own slot 1: state 0xC = in-game UI).
- State 2 mode 5 = new game: State2_LocationEnter calls Game_InitNewGame, then places the Sim at the entry id.

Patch: the `bl Game_RequestState` of the 0x2B step change (0x0205440C, step N → N−1) branches to a 24-word routine in
the extension (§2) that requests state 2 (5, location, entry) on slot 0 and state 0xC (0, 0, 0) on slot 1.
So the game shows the first copyright screen, then starts a new game in the chosen place.

Emulator checks (2026-11-17, `build/boot_test/`, `build/boot_test9/`, cold boot, no RAM writes):
- location 6 entry 0: City Hall at frame ~400, bottom UI complete, City Hall welcome popup, $2000; the Sim walks, the
  exit door loads location 5 and the new-game intro conversation (Jebediah) plays.
- location 9 entry 0: Desert, UI complete.
- **Rejected first version**: patching the startup requests themselves (state 2 + 0xC at power on, 0x2B never runs)
  starts the game but the bottom-screen UI has no icons; injecting the same requests in RAM before 0x2B starts gives
  the same missing icons and a dark bottom screen. Something done by state 0x2B is needed (not identified).
- The Sim is the default one (no Create-a-Sim); `[0x0213E434]+0x68` is left at 0 (its meaning is unknown).

## 6. Music override hooks for new location ids — CONFIRMED (code; emulator: read path)

`LocExt.music_hook` (godot/scripts/core/loc_ext.gd). The per-location music override S+0x449C u8[33]
(S = [0x0213E434]; 0x2A = record music) has no room for ids 33+ (byte S+0x44C0 = +36 is the "outdoor" value of
Map_UpdateLocationAmbience). All 12 accesses (a scan of every literal word 0x4498..0x44C4 and every `#0x49c]`
operand in the ARM9 and the 19 overlays):

| site | instruction(s) | function |
|------|----------------|----------|
| 0x0201F63C / F640 | `add r0,r0,#0x4000` ; `strb r1,[r0,#0x49c]` | Unk_0201f190_PropMsgHandler (msg 0x5E, stereo) |
| 0x0201F684 / F688 | `add r1,r1,#0x4000` ; `strb r0,[r1,#0x49c]` | same |
| 0x0201F69C / F6A0 | `ldrb r1,[r0,r5]` ; `add r2,r0,r5` (r2 = store address at F6B8 / F6D0) | same |
| 0x0201F6FC / F700 | `add r1,r1,#0x4000` ; `strb r0,[r1,#0x49c]` | same |
| 0x0201FFD8 | `ldrb r2,[r0,r2]` (r0 = S+0x449C) | prop update (state 0x69) |
| 0x02020C94 | `ldrb r3,[r0,r3]` | prop update |
| 0x02084C64 / C68 | `add r0,r0,#0x4000` ; `ldrb r0,[r0,#0x49c]` | Map_LoadLocation |
| 0x02084D14 / D18 | same | Map_PlayLocationMusic |
| ov05 0x0214A120 / A124 | `add r2,r2,#0x4000` ; `strb r0,[r2,#0x49c]` | music picker (state 0x22) |
| ov05 0x0214A654 / A658 | `add r0,r0,#0x4000` ; `ldrb r0,[r0,#0x49c]` | music picker |

(The literal 0x449C at 0x02065C1C is the end bound of the S+0x4418 init loop, not an access.)
Each first word is replaced by a `b` to a trampoline in the extension, which branches back (no `bl`: lr untouched;
two temps pushed, flags saved with mrs / msr). The trampoline keeps the original code for id < 34 (id 33, the
"no location" sentinel, included since 2026-11-20) and uses a 64-byte array in the extension (init 0x2A) for 34..63. Overlay 5 is stored decompressed (like overlay 15).
Emulator (build/newloc_proto/loc34_m.nds, without the old `mov r0,#0x2a` patch at 0x02084C68): id 34 loads and
plays music track 5 (the City Hall record music, sound state 0x021424F8+10), S+0x449C+33.. unchanged; control id 6
with the hooks: same. The write paths and Map_PlayLocationMusic were not triggered in the emulator (same trampoline
shape, checked by disassembly). The extension array is not saved: a stereo music picked in a new location resets.

## 7. New location ids 34..63 (LocExt.install) — CONFIRMED (code + emulator, 2026-11-20)

`LocExt.install` (godot/scripts/core/loc_ext.gd), called at export when the project has new locations
(EditProject "newloc:0", Locations tab). Every hook replaces one word with a `b` to a trampoline in the extension that
redoes the original instruction(s) for **id < 34** and takes the new path for ids 34..63, then branches back. Id 33
(the "no location" sentinel) keeps the original path; the moved tables keep the original word 33 (what the game read
past the end of the 33-entry tables). Every trampoline was disassembled with capstone from the exported extension
(build/newloc_test/arm9_ext.bin + hooks.txt) and checked against the original code around the site (registers live
after the site, flags, branch targets into replaced words).

| what | where | new path (ids >= 34) |
|------|-------|----------------------|
| location table (33 pointers, 7 references) | moved: 64 entries in the extension | own record (template copy, own nav / bsp entries appended to rom.bin) |
| layout variant rows (Map_LoadLocation) | literal 0x02084CEC + row count `cmp r2,#0xc` 0x02084C20 | template's rows copied with the new id |
| price entry {u16 price, u8 score, u8 parent} | literal 0x02073F78 (Coll_PriceEntry) | 64-entry table; Coll_GetScore keeps the old one |
| dust table | literals 0x0205F108 / F26C / F344 / F380 | 64 entries (0 = no dust) |
| Map_UpdateLocationAmbience id | 0x0207625C `ldr r4,[r1,#0xf4]` | id -> alias ("behaves like": indoor fog list, ambient sounds) |
| State2_LocationEnter id lists | 0x02076F4C (r4 = real id) ... 0x02077104 (r5 restored) | lists see the alias |
| Map_SetLocationLightKeys | 0x02085E04 `cmp r1,#0x21` (ids > 33) | alias |
| Hotel_DustOnLocationEnter | 0x0205EFA4..EFB0 (4 words) | count 0 |
| LocStateSpawnProps record S+0x88+id*0xFC | 0x02083890 `mla` | 0xFC records in the extension |
| prop pick-up (same records, +0x95) | 0x0208D698 `mla` | same records |
| construction timer S+0x4418[id] (u32[33]) | Door_TryEnter 0x02064430; **door warp FUN_0209b838 0x0209B88C**; ov01 menu 0x02149C68 | a single word 0x80000000 ("none") |
| Coll_IsOwned | 0x0207355C | price 0 -> 1 (always open); else the owned bitset (bits 0..63 in RAM) |
| Coll_IsOffered | 0x020735A8 | per-id flag -> 1; else the bitset |
| ov01 purchase | 0x02149F68 `cmp r1,#4` | Coll_SetOwned(Coll, id, 1), like id 4; no timer, no construction record |
| ov01 menu loop | 0x02149CA0 `cmp r5,#0x21` -> `#0x28` (only when a location is sold) | ids up to 39 listed |
| name text 0x43 + id | 15 `add rD,rS,#0x43` sites (ARM9 4, ov01 10, ov08 1) | u16 text id per location |

S+0x4418 accesses, complete (scan of every literal 0x4400..0x449C and every `#0x4xx]` operand, ARM9 + 19
overlays): 0x02064438 (Door_TryEnter), 0x0209B898 / B8A4 (door warp: > now -> "room being built" 22 / 23),
0x02065C14 (init loop, 33 entries), ov01 0x02149C74 (menu), ov01 0x0214A07C (purchase write, bypassed for ids >= 34).
The Coll +0x220 loops (0x02073254, 0x020732FC, 0x02073EF4) are bounded to 0..32. The 0x0209B88C hook was missing at
first: a door to id 34 read S+0x44A0 (inside the music array, bytes 0x2A) as a timer and warped to RoomBeingBuilt2.

Limits: only ids 34..39 can be sold (the save keeps the owned / offered bits 0..39); the ov01 list has 33 slots
(obj+0x4C) and at most 14 original + 6 new locations are for sale. Not saved for ids >= 34: the stereo music choice,
the picked-up random props (extension arrays).

**Emulator (build/newloc_test/, cold boots)**: newloc_34.nds boots into 34 (world+0xF4 = 34, City Hall copy, its
welcome text); newloc_35.nds into 35 (Saloon copy); newloc_6.nds (control, same hooks) into City Hall. Saved in 35:
the save slot shows "Test Saloon" (ov08 hook), the load screen too (0x0206EA28 / ED98), loading puts the Sim back in
35, its door leads to 5. door_5_34.nds: both Saloon door items of location 5 ([0,0,0] model, [0,0,18] trigger box)
-> 34: walking in loads 34. Construction menu (story flag 0x13 set in RAM): "Test Saloon (Town Square) §500" listed,
bought: money 2000 -> 1500, owned bit 35 set (Coll+0x21C = 8), gone from the list.

### Own scene records (2026-11-20)
`LocExt.install` accepts `self_ptrs` per location: [[pointer offset, target offset]] inside the record, written as
absolute addresses once the record is placed in the extension. Used by own scenes: every model's anim_list pointer
targets the dummy anim entry stored after the model list (docs/formats/location.md §5, bmd0.md §3).
