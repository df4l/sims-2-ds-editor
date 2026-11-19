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
two temps pushed, flags saved with mrs / msr). The trampoline keeps the original code for id < 33 and uses a 64-byte
array in the extension (init 0x2A) for 33..63. Overlay 5 is stored decompressed (like overlay 15).
Emulator (build/newloc_proto/loc34_m.nds, without the old `mov r0,#0x2a` patch at 0x02084C68): id 34 loads and
plays music track 5 (the City Hall record music, sound state 0x021424F8+10), S+0x449C+33.. unchanged; control id 6
with the hooks: same. The write paths and Map_PlayLocationMusic were not triggered in the emulator (same trampoline
shape, checked by disassembly). The extension array is not saved: a stereo music picked in a new location resets.
