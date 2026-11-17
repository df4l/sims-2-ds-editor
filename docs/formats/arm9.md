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
