# Location layout file (rec+4 of the location table) — phase 3

Formerly called "nav" (catalogue kind `loc_nav`). It holds **everything placed in a location**: entry
points, NPCs, props, interactive objects, trigger boxes, lights (?), waypoints, sounds, and the scripts that
spawn / despawn groups of them. Tool: `tools/layout.py` (`verify`, `dump <loc>`, `csv` →
`rom_bin/layout_items.csv`). Test: `tests/test_layout.py`.

Status summary: layout and round-trip **CONFIRMED** (code + 32/32 byte-identical + emulator). Item types:
roles CONFIRMED by code where a constructor is named below, otherwise ASSUMED.

## 1. File — CONFIRMED (Map_LoadNav 0x02053128)
```
u8  n_blocks            ("variants": block 0 is always spawned, plus the one selected by the caller)
u8  n_entries
u16 entries_size        == 16 * n_entries (32/32)
entry[n_entries]        16 bytes each, see §2
block[n_blocks]         see §3; the blocks end exactly at the end of the file (32/32)
```
Only block 0 and block `param_3` of Map_LoadNav are parsed. In location 5 (start), block 1 was active
(the prop and NPC of block 1 were found spawned in RAM).

## 2. Entry points — CONFIRMED (Nav_FindEntryPoint 0x02052cd0, Map_PlaceAtEntryPoint 0x020845bc)
```
+0x0 s16 x, y, z        world units (actor pos = v << 12, fx32)
+0x6 s16 angle          fx32 radians, written as-is to actor+0x88 (0x3243 = pi, 0x1921 = pi/2)
+0x8 s16 ?, s16 ?       always -3, -3 in location 5
+0xC u8  id             = arg2 of the "enter location" request (state 2); looked up by this byte
+0xD u8, u16            0
```
Emulator: entering location 5 with entry 8 puts the Sim actor at x/z of entry 8 (y snapped to the floor).
With entry 8 moved by +15 in x in a rebuilt ROM, the Sim actor is at x = −360 instead of −375.

## 3. Block — CONFIRMED (Map_ParseNavBlock 0x020528c0)
```
+0x0 u16 size (whole block)    +0x2 u8 n_groups   +0x3 u8 n_scripts  +0x4 u8 n_c4  +0x5 u8 n_c5
+0x6 u8 n_c6   +0x7 u8 0
+0x8 u16 off_scripts  +0xA u16 off_c4  +0xC u16 off_c5  +0xE u16 off_c6     (relative to block+0x10)
+0x10 group[n_groups]  (they end exactly at off_scripts, 32/32)
then the script area and tables (kept raw by tools/layout.py and moved as one piece)
```
- **group** (Nav_ParseGroup 0x020523fc): `u16 size, u8 items_offset (= 4+n+pad), u8 n, u8 item_size[n],
  pad to 4, items`. A group is a spawn unit: Nav_SpawnGroup (0x020525f0) creates every item of group
  k−1 through the constructor table at **0x0211E7E0** indexed by the item type; Nav_DespawnGroupItem
  deletes them again. Group 0 of block 0 is the permanent content of the location.
- **scripts** (`off_scripts`, Nav_ParseScripts / Nav_RunScript 0x02052800) — CONFIRMED, parsed and rebuilt by
  `tools/layout.py` (`Block.scripts`):
  ```
  u16 arg_offset[n]          relative to the start of the script area
  per script: u8 count, u8 opcode[count]
  zero padding to a 4-byte boundary (block-relative)
  args                       per script, per opcode, ARG_SIZE[op] bytes (table 0x021229AC: 4, 8, 12 or 20)
  ```
  In all 93 blocks the args are contiguous, in script order, and end exactly where the next table starts, so the
  area can be rebuilt from the opcode list alone. Nav_RunScript runs script k−1 (1-based; the very first call
  of a block always runs script 1). 659 scripts in the 32 files. Opcodes: §4b.
- **c6** (`off_c6`), **c4** (`off_c4`): `u16 offset[n], u8 tag[n]`; c6 records seen are 12 bytes
  `s16 x,y,z, s16 ?, 0x3243 0x3243`. c6 = **camera points**: script op 0x37 places the camera at c6 record
  `point` (Cam_FromLayoutPoint) — CONFIRMED by code; the tag byte is passed along (script to run when done?).
  c4 is rare (2 files). Kept raw (`Block.tables`), moved as one piece.
- **c5** (`off_c5`): consecutive records starting with u16 size. Never used (count 0 in 32/32).

## 4. Items — header CONFIRMED (1290/1290 items, one size per type)
```
+0x0 s16 x, y, z   world units (<< 12 in every constructor)     +0x6 u8 type   +0x7 u8 (0)
```
| type | size | name | constructor / evidence | fields after +8 |
|---|---|---|---|---|
| 1 | 16 | **NPC** | Actor_InitNpc 0x0200b448 (CONFIRMED: NPC 22 found in RAM at its file position) | s16 angle (degrees) @+8, u8 npc id @+0xE. id < 0x39 also stores the current location id in the NPC table [0x0213E434]+0x21E0+0x2C*id |
| 2 | 16 | **prop** | Actor_InitProp 0x02014c30 (CONFIRMED: moved in a rebuilt ROM, the actor moved) | s16 angle (deg) @+8, u8 prop id @+0xE |
| 3 | 16 | **trigger box** (kind 0x13) | FUN_0209b488(pos, half-size, 0x13) + Nav_SetTriggerBoxEvent; fired by Nav_FireTriggerBox (code) | u8 repeat @+8 (0 = fires once), u8 size x/y/z @+9..+0xB (half-size = v/2), u8 **group** @+0xC, u8 **script** @+0xD (1-based, 0 = none; selected variant block) |
| 4 | 24 | **door** (box kind 0x12 + optional door model) | FUN_0209b488 + Nav_SetDoorBoxTarget(+0xE, +0x12), then Actor_InitObject 0x02010cb4 unless +0x13 == 0x1E | s16 angle (deg) @+8, u8 **destination location** @+0xE, u8 size x/y/z @+0xF..+0x11, u8 **entry point** @+0x12, u8 door model id @+0x13 (0x1E = box only). CONFIRMED: 145/147 destinations have that entry point, 142 have a door back; walking through DoorCityHall (5 → 6, entry 0) in the emulator loads location 6, request args (6, 0). `layout.py doors` → rom_bin/doors.csv |
| 5 | 16 | light? | FUN_0204bff0(pos, (r,g,b) @+0xB..+0xD, u16 @+8 << 12, (u16 @+8 >> 1) << 12) — values 0..31 = 5-bit colour, then radius (ASSUMED) | |
| 7 | 12 | box | FUN_0209b488(pos, half-size, kind) | u8 kind @+8, u8 size x/y/z @+9..+0xB |
| 8 | 12 | event watcher | FUN_02015914(+9, +0xA), FUN_02015904(+8); update = Unk_02015770_EventWatcherUpdate: mode 1 = when a story flag is set run a script, mode 2 = countdown then spawn group + run script | 3 bytes (mode / ids, exact mapping not checked) |
| 9 | 20 | **waypoint** | Nav_AddWaypoint 0x02053e38, list at world+0x6C (count world+0xEC) | u8 radius @+8, u16 link[4] @+0xA..+0x10 = **1-based item index of another waypoint in the same group** (579/579 links; 542 two-way), 0 = none. Inserting/deleting items requires renumbering the links |
| 10 | 12 | timed prop | Actor_InitProp(+8 + 0x47) only if flag bit (+0xB) is clear and a game value == (+0xA) and the hour falls in slot (+9)*8 .. +8 | u8 prop−0x47, u8 hour slot, u8 value, u8 flag |
| 11 | 12 | sound? | FUN_020d5680(u16 table 0x0212FCC8[+8], pos) (ASSUMED sound emitter) | u8 slot @+8 |
| 0, 6 | 12 / – | none | no constructor (table entry 0) | |

Bytes the constructors never read (Nav_SpawnEntity, CONFIRMED by code): NPC/prop +0xF (0..4 in the data), door +0x14
(0..4), trigger +0xE/+0xF, type 8 +0xB (always 1). Id ranges (model tables scanned until a record is not a BMD0): NPC
0..62, object 0..29 (30 = box only: the prop table starts right after), prop 0..330; type 2 stores a u8 (0..255),
type 10 stores id − 0x47 (0x47..0x146). Waypoint links are u16 but Nav_AddWaypoint reads the low byte only.
**Type 10 +0xB is a collect bit**: bit +0xB of the u32 array at [G]+4; the spawn is skipped once it is set. The 50 orbs
use bits 0..49, each once. Editable fields + ranges: `layout.FIELDS`.

Actor angles: the file stores **degrees**; the constructors convert to fx32 radians (180° → 12867 = π).
Verified in RAM on the 6 objects of location 5 (−180 → −12867, 90 → 6433).

## 4b. Layout scripts — CONFIRMED (all 82 handlers read in Ghidra)
Full opcode table with argument fields, status and evidence: **`tools/layscript.py` (`OPS`)**. Disassembler:
`python tools/layscript.py <location> [--lang fr]` (conversation lines and NPC names inlined), usage statistics:
`--stats`. Handler table 0x0211E4F0; handlers renamed `NavOpXX_*` in Ghidra (docs/ghidra.md part 5).

Conventions (code): groups and scripts are **1-based indices in the selected variant block, 0 = none**; an
actor is `(g, i)` = item **i (1-based, 0 = none)** of group **g (0-based**, i.e. the group spawned by
`group = g + 1`), `g = 0xFF` = the player Sim (Nav_GetGroupActor; CONFIRMED by code, by RAM — slot (2,2) of
location 5 is empty after `despawn_item(2, 2)` — and by the 0x0E animation ids below); story flags are bits of
[0x0213E434]+0x4814 (0x58 is used as "no flag").

Families (in decreasing use; C = role confirmed by code or emulator, A = mechanism read but meaning assumed):
| family | opcodes |
|---|---|
| flow | 0x16 spawn_run (C), 0x09 timer (C: delay in update ticks = frames), 0x32 random_script (C), 0x3D switch on [G]+0x2F9C (C) |
| conditions → (group, script) or (else_group, else_script) | 0x15 flag, 0x31 two flags and/or/nor/xor, 0x2D location open, 0x2E/0x2F/0x30 goal started/done/active, 0x3B game clock window, 0x46 has item, 0x2B hotel score, 0x2C/0x3E stat ≥, 0x34 counter ≥, 0x42 next goal ready (all C except 0x2C A, never used) |
| story state | 0x14 set_flag (C), 0x21/0x22 mission goal start/done (C, see below), 0x33/0x35 counter (C), 0x4A location_open / 0x48 link flag (C), 0x47 location_offer (A) |
| dialogue | **0x17 conversation (C)**, **0x2A phone_conversation (C)**, **0x19 npc_set_talk (C)**: what an NPC says when talked to (71/79 point to a conversation spoken by that NPC), 0x45 message popup (C), 0x49 phone gate (A), 0x3C npc_met (C: phonebook) |
| actors | 0x00/0x01/0x02/0x0A spawn control (C), 0x0D teleport, 0x0C face, 0x1B walk to point, 0x23 walk to actor (C), 0x0E animation (C), 0x1E hold_idle / 0x1D resume_ai (C), 0x1C mood (C), 0x36 NPC status (C), 0x4E hold prop (C), 0x4D door_open (C), 0x51 Alfred fly sequence (C), 0x4C NPC brain byte (A) |
| camera | 0x1A look at actor, 0x37 from layout c6 point, 0x29 close-up, 0x1F reset, 0x26 shake (C); 0x1A/0x26 store a script run when the camera move ends (chains seen: 12 → 17 → 18 in location 5) |
| player / world | 0x12 player_control (C: 0 = cutscene start, 1 = end), 0x0F warp (C), 0x10 request state (C), 0x20 money (C, clamp 999 999), 0x38/0x39 inventory (C, 6 slots), 0x25 NPC asks money / 0x41 NPC wants item (C), 0x40 shop item (A), 0x24 hotel dust (C), 0x3A fire (C), 0x43 weather (C), 0x4B per-location setup (C), 0x44 [G] bit 2 (A) |
| sound | 0x05 / 0x50 music channel 0 / 1, 0x06 sfx, 0x03 / 0x04 pause / resume (C); 0x07 / 0x08 sound engine bytes (A, never used) |
| no-op | 0x0B 0x11 0x13 0x18 0x27 0x28 (empty handlers, never used) |

**Popup scripts — CONFIRMED.** 0x21 goal_start, 0x22 goal_done and 0x45 message store their second byte in the
UI object ([0x02139FA4]+0x18); that script is run when the player closes the popup. Emulator (location 5,
new game): `goal_start(0, 24)` → popup 0x990 "New Mission Goal unlocked!" with +0x18 = 24; on close script 24 runs
(`timer(5)` → script 4 → script 26 = `message(3, 12)` "Time to explore!", +0x18 = 12); on close script 12 =
`camera_reset`, `player_control(1)`. With +0x18 forced to 0 before closing, no message follows and the player
stays locked (soft-lock) — so editors must keep these chains intact.

**Mission goals — CONFIRMED (code + texts).** 34 goals (ids 0..33, each started by a 0x21 — goal 8 by 3 scripts, the others by 1) in 4 missions,
table 0x0211FB68, 0x114 bytes per mission: u8 goal count (12, 8, 7, 7), u8 first goal (0, 12, 20, 27); goal k:
u32 ? at +4+8k (values 3..92, not the NPC of the 0x21/0x22 calls), s32 delay at +8+8k (all 0). Goal record
[G]+0x2F78: u8 mission (4 = all done), per-goal byte at +1+goal (bit 1 started, bit 2 done), +0x24 goals done in
the mission, +0x28 clock of the last completion. goal_done pops 0x991 "Mission Goal completed!", or 0x992
"Mission Completed!" when every goal of the mission is done (the mission index then goes up).

**player_control — CONFIRMED (emulator).** 0 sets bits 6 and 7 of the first word of [0x0213E434] (and cancels the
Sim's tasks 0x11–0x13), 1 clears them. Same savestate, D-pad right for 60 frames: Sim x −375 → −387 with the bits
clear, unchanged with the bits set by hand. Use: 0 first in 50 scripts, 1 last in 26.

**actor_anim (0x0E) — CONFIRMED (data).** `anim` is an animation **id** looked up in the actor's model list
(record {u32 list, u16 BMD0, u16 count}, entries {u16 id, u16 BCA0 entry, u16 BCA0 entry or 0xFFFF}); the BCA0 JNT0
name names the move. 29/33 non-player uses resolve, e.g. Jebediah 82 `JebGenericUse` (at the broken car),
Tristan 18/19/20 `TrisCowerIn` / `TrisCower` / `TrisCowerOut`, prop StatPanel 135/136 `StatPanelOpen` / `Close`.
Read as an index instead, 82 would be `JebHiFiveHit`. The 4 others: jail door (prop 1) id 79 with b5 = 1, not in its
1-entry list. The 18 player-Sim uses are not resolved (Sim animation table not found). `layscript.py` prints names.

**NPC behaviour ops 0x1E / 0x1D / 0x1C — CONFIRMED (code + emulator).** Every NPC gets task 5 at spawn; for most
NPCs it starts task 10, **roaming** around the spawn point (idle rand(100)+15 frames, walk to a new point). So the
NPCs walk around by default, and the old names were wrong:
- `0x1E actor_hold_idle(g, i)`: adds task 0x18 mode 3 exclusively. The roaming task is suspended and the mood's idle
  animation loops in place. Used at the start of cutscenes and talks (Jebediah in script 2 of location 5).
- `0x1D actor_resume_ai(g, i)`: removes task 0x18 and gives back task 5 if it is missing, so the NPC roams again.
- `0x1C npc_mood(g, i, mood)`: NPC record +0x1A. Animation ids walk = 0xDD + 4·mood, idles +1..+3 (mood 0 = the
  model defaults 3 / 0). BCA0 names, identical for every NPC: 1 Angry, 2 Rom(antic), 3 Sad, 4 Drunk, 5 Imp, 6 CowStare,
  7–11 the social mini-game sets (HiFive, DGuns, Joke, Punch, Scream; In / Loop / Hit / Miss). All 12 uses resolve.
  Example: the location 7 cultists get mood 6 + `actor_hold_idle` → they stare at the cow.
Emulator (Jebediah, actor 0x021554F0): `intro_conv0` (after 0x1E) shows task 10 inactive and task 0x18 mode 3 active,
animation 0; `loc5_control_unlocked` (after 0x1D) shows no task 0x18, task 10 active, a walk of ~8 units in
300 frames. Mood 4 written while he roams → animation 238 JebDrunkIdle1 (the walk stays 3); mood 6 under task 0x18
→ 246 JebCowStare. Only the idle animations were seen to change; the mood walk is used elsewhere (not checked).

**Location state (ops 0x2D / 0x4A / 0x48 / 0x47 / 0x2B) — CONFIRMED (code + RAM + emulator).** What looked like a
"collection" is the state of the **33 locations** (ids of docs/formats/location.md §7, text name 0x43 + id). Table
0x0211F9EC, 4 bytes per location: u16 build price, u8 hotel score, u8 parent location (33 = none). The 14 priced
entries are the hotel rooms (Gov Lab 2000, Art Gallery 1000, Casino 1500, … Vault 3000), each reached from a
lobby: 2 Atrium, 3 Basement, 13 Hotel Lobby, 27 2nd Floor Lobby. [G]+0x41F8 holds two bitsets:
- +0x218 **open**: Door_TryEnter lets the Sim through only if the destination is open (else sound 0xCC). New game
  opens 2, 3, 5, 6, 10, 11, 13, 14, 19, 24, 25, 27, 29, 30 (RAM of `loc5_control_unlocked` = exactly these bits).
  Emulator: City Hall bit cleared → the Sim walks into the City Hall door and stays outside; bit set → City Hall
  loads (build/opcode_test/door_locked.png, door_open.png). `if_hotel_score` sums the score of the open locations
  ("raise this hotel up to a score of 20 percent").
- +0x210 **offered** (ASSUMED meaning: rooms shown for construction): new game sets the 11 priced rooms minus
  4/7/32, plus 2/3/10/19; scripts add 4 Casino, 7 Bovine Shrine, 32 Vault right after an NPC asks for that room.

**NPC status (op 0x36) — CONFIRMED (code + data).** Initial values from the NPC table 0x02132900 (20 bytes per NPC,
status at +4): 0 townies, 3 Mamma Hogg / Honest Jackson / Jebediah / Tristan, 4 Ava / Frankie / Optimum Alfred,
6 not around yet (Alien, Bigfoot, Lord Mole, Horus, Penelope, 56), 7 shop and staff NPCs (clerk, concierge,
dealers, sheriff…), 8 animals / ghost / ninja / grim cowboy, 9 aliens, goons and robots. Readers: NPC socials start
only with status 0/1/3/5/10 (FUN_02025c80, FUN_020241ec); the phone's Phonebook (Phone_DrawPhonebook) lists the 5
hotel guests (status 5) and the met NPCs (op 0x3C) except 7/8/9; status 9 is tested by a proximity check
(FUN_02034f90). Scripts set 6 for the length of a scene and restore the old value after.

**NPC requests — CONFIRMED (code + texts).** `npc_ask_money(amount, npc, script)` adds the menu entry 7
"Pay ($amount)" (text 0x735 + 7) to the NPC; paying runs `script` (Giuseppi 250 → script 9 "You got the cash…
the Super Drencher is all yours", Frankie 1000 → script 8 "Thanks for the cash"). `npc_want_item(npc, item,
script)`: giving the item runs the script (Honest Jackson, item 78 → "From Frankie Fusilli? … give him my thanks").

**World ops — CONFIRMED (code + data).** `door_open(g, i)` (all 12 uses target a door item) plays the door model's
animation 135; `hotel_dust_add` +5 dust (max 9) in the current room, hotel rooms only (table 0x02131F34; used for
the dusty lobby of the intro); `start_fire(location)` raises the fire counter of one of 7 locations and spawns the
`Fire` prop (260) there (location 5: City Hall fire, then Honest Jackson "WATER! I need water"); `set_weather(m)`
0 = by date, 1 = off, 2 = on; `location_setup(e, arg)` hard-coded hooks run on load: 0x11 Manager's Suite license
plate display (24 bits [G]+0x20), 0x15 Rat Cave prop, 0x1E Store item of the day (RTC weekday).

Example (location 5, block 1, script 3): `conversation(conv=0, group=1, script=25)` → Jebediah's intro lines;
script 9: `set_flag(0xf)`, `conversation(0x1b)` ("You got the cash… The deluxe Super Drencher… is all yours"),
`goal_done(10)`. The emulator showed conversation 0 played on entering location 5 (docs/formats/text.md §5).

### Models of NPCs / props / objects — CONFIRMED
Each constructor calls Unk_0201180c_InitLocModel with a record `{u32 anim_list, u16 BMD0, u16 anim_count}`
(same layout as the location models) taken from:
- NPC: **0x02118310** + 8*id (94–116 animations each: characters)
- prop: **0x0211CD2C** + 8*id
- object: **0x0211CC3C** + 8*id
`layout.model_of(item)` resolves them: all 357 references in the 32 files point to a `nitro_model` entry.
`tools/nitro.py` reads the MDL0 model name of a BMD0 (329/329 models readable), shown by `layout.py dump`
and in the `model_name` column of `rom_bin/layout_items.csv`. Location 5 for example: doors `DoorSaloon`,
`DoorStore`, `DoorCityHall`, `DoorJail`, `DoorHotel` (type 4 objects); NPCs `cow`, `Bull`, `Jebediah`; props
`Car`, `LicensePlate`, `Hubcap`, `Letter`, `Stool`; timed props `SkillCreativity` / `SkillBusiness` /
`SkillBody` (the aspiration orbs — hence the hour slot and the "collected" flag). Type 4 objects seen so
far are all doors; the door model is optional (box-only doors are the walk-in triggers and the town edges).

## 4c. Runtime limits — CONFIRMED (code), checked by `layout.limit_errors`
- **Parse arena**: Map_LoadNav allocates 0x800 bytes and parses block 0 + the selected block into it. Every non-empty
  array costs `n * record + 8`: entry points 4, the 2 block slots 0x24 (always), and per parsed block groups 8,
  items of each group 8 (Nav_ParseGroup), scripts 8 (Nav_ParseScripts), c6 8, c4 8, c5 12 (Map_ParseNavBlock).
  Originals: at most 1628 bytes (location 13, variant 1). **Each added item costs 8 bytes.**
- **Waypoints**: Nav_AddWaypoint appends to a 32-pointer array at world+0x6C (count byte at +0xEC) with no bound check,
  so a 33rd waypoint would overwrite the count. Originals: at most 20 (location 2).

Emulator (2026-10-09): a prop of a new model (102 YetiStatue) and a box-only door to location 6 were appended to
location 5 group 0 with the editor. The prop spawns (y snapped to the floor), and the door takes the Sim to location 6
(journal).

## 5. Evidence log
- Parsing per the decompiled code on 32/32 files: every size/offset invariant holds, write(parse(f)) == f.
- RAM (location 5, savestate first_ingame): every block-0 box / object / light / waypoint is present as
  fx32 `x<<12, y<<12, z<<12`; object actors (vtable 0x0212FC90) have their position at +0x78.
- Rebuilt ROM `build/layout_test/sims2_layout_test.nds` (prop 41 of block 1 moved +15 x): after a warp to
  location 5 the modified layout is the resident copy and the prop actor (vtable 0x0212FD44) is at x = −357
  instead of −372. `sims2_entry_test.nds` (entry 8 moved +15 x): Sim actor at x = −360.
  The top screen did not change because a dialogue cutscene with a fixed camera was running.
- **Visual check** (savestate `free_roam_loc5`, warp to 5/entry 8, same 9 taps, frame 1090 on both ROMs):
  the car (prop 41 = `Car`) is behind the Sim on the original ROM and 15 units to the right on the edited
  ROM — `build/layout_test/car_original_vs_moved.png`. Editing a layout item moves the object on screen.

## 6. Open questions
- Assumed-only opcodes (A in `layscript.OPS`, 8 left, 3 of them never used: 0x07 0x08 0x2C; used: 0x40 shop item, 0x44, 0x47 location_offer, 0x49 phone gate, 0x4C), music track names (custom sound container `data/SoundData.rom`, no SDAT), b3–b5 of 0x0E, the c6 tag byte, the c4 table, the exact byte mapping of type 8.
- Type 7 box kinds (4, 9, 12, 14, 15…) — no-walk zones, camera zones?
- Why NPCs 53/54 and prop 24 of block 0 were not found in RAM (probably spawned conditionally / moved).
- Names of prop / object ids (NPC names: text 0x143 + id, docs/formats/text.md).
