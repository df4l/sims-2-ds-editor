# Arcade machines (props 164–176)

Status: framework **CONFIRMED** (Ghidra + melonDS 2026-11-23, `build/arcade_test/`). Individual games: only Space
Armada (type 0) and the type 9 stub are read in detail.

## 1. Overview

An arcade cabinet is a furniture prop with a blank `ArcadeScreen` texture. Each machine runs a small **software-rendered
mini-game**. It draws into a 128×128, 2 bits-per-pixel buffer in RAM and copies that buffer over the cabinet's screen
texture in VRAM every frame. The 4-colour palette is uploaded the same way. No 2D engine is involved, which explains
why the editor shows the screen black (the texture in the BMD0 is blank on purpose).

Two C++ objects (RTTI names in arm9):
- `CInteractableArcade` (vtable 0x02133820, ctor `Arc_InteractableCtor` 0x0208e13c): the interaction menu
  ("Insert Coin ($1)", then "Stop"). It needs money ≥ 1 (G+0x2F60) and sends the controller events 0x33 / 0x34.
- `CArcadeController` (vtable 0x02130c70, ctor `Arc_ControllerCtor` 0x02029a94): actor task id **0x31**, runs the game.

## 2. Prop → game type (CONFIRMED, Prop_CreatePlacementObject jump table 0x02011E2C)

Each case builds the task params with `Arc_ControllerParams` 0x02029cf4, stores the type byte at params+0x10, adds task 0x31
(0x020117d8), then creates `CInteractableArcade`.

| prop | in-game name (objinfo) | type | case |
|---|---|---|---|
| 164 | Arcade: Generic | **random 0..9** (`0x0204cbb4(0,10)`) | 0x02013F6C |
| 165 | Arcade-Space Armada | 0 | 0x02013FE4 |
| 166 | Arcade-Baseball | 1 | 0x02014124 |
| 167 | Arcade-Bustin' Out | 3 | 0x02014194 |
| 168 | Arcade-Copter | 4 | 0x020141F8 |
| 169 | Arcade-X Raider | 2 | 0x02014268 |
| 170 | Arcade-Sisyphus | 5 | 0x02014044 |
| 171 | Arcade-Pie Factory | 6 | 0x020140B4 |
| 172 | Arcade-Billiards | 7 | 0x020142D8 |
| 173 | Arcade-Deluxe Pool | 8 | 0x02014348 |
| 174 | Arcade-Lunar Lander | **0** (Space Armada) | 0x020143AC |
| 175 | Arcade-Space Gunner | **0** (Space Armada) | 0x02014418 |
| 176 | Arcade-Log Jump | **0** (Space Armada) | 0x02014484 |

Lunar Lander, Space Gunner and Log Jump have a name, an icon and a price (1500), but no game: they fall back to
Space Armada. Type 9 can only come from the Generic machine. It is a stub that draws one 16×8 sprite at (25, 50)
(seen in melonDS by forcing type 9: two small crosses on a black screen).

Placed in layouts: location 24 item 23 (prop 165, model Arcade01), location 31 item 24 (prop 169, Arcade05).

## 3. Game table (CONFIRMED)

`0x0211E200`: 10 entries × 12 bytes = `{Init(actor, attract), Update(), Free()}` indexed by the type
(controller +0x28). Ghidra names `ArcN_<Game>_Init/Update/Free`.

| type | game | Init | Update | Free |
|---|---|---|---|---|
| 0 | Space Armada | 0x0209CAE8 | 0x0209C564 | 0x0209C518 |
| 1 | Baseball | 0x020A2B2C | 0x020A29EC | 0x020A29A0 |
| 2 | X Raider | 0x020B8838 | 0x020B8530 | 0x020B84E4 |
| 3 | Bustin' Out | 0x0209F3E4 | 0x0209F204 | 0x0209F1B8 |
| 4 | Copter | 0x020B3EE8 | 0x020B3E30 | 0x020B3DA0 |
| 5 | Sisyphus | 0x020B7090 | 0x020B6DE8 | 0x020B6D9C |
| 6 | Pie Factory | 0x020A39A4 | 0x020A361C | 0x020A35D0 |
| 7 | Billiards | 0x020AF850 | 0x020AF620 | 0x020AF5D4 |
| 8 | Deluxe Pool | 0x020A0E90 | 0x020A0DD8 | 0x020A0D1C |
| 9 | (stub) | 0x0209E870 | 0x0209E7FC | 0x0209E7B0 |

All the game code sits in 0x0209B000–0x020B9000 (about 120 KiB of arm9). The table is read at 5 sites:
0x02029394, 0x0202941c, 0x02029974, 0x02029bcc, 0x02029c64 (literal pools 0x02029410–0x02029418, 0x02029960–0x02029970,
0x02029a60/64, 0x02029c60, 0x02029cf0). The type byte is not range-checked.

## 4. Controller life cycle (CONFIRMED, code + emulator)

Controller fields: +4 cabinet actor, +0x28 type, +0x2C state (0 idle, 2 playing), +0x30 camera target,
+0x98 "attract frame drawn", +0x9C looping sound handle (types 2, 4, 5 start sounds 0x29 / 0x22 / 0x2E).

- **Spawn / Stop → attract screen** (`Arc_ControllerShowAttract` 0x02029394): blank palette (8 zero bytes 0x0211E1F8),
  `Init(actor, 1)`, `Update()` once, +0x98 = 1.
- **Idle, per frame** (`Arc_ControllerUpdate` 0x02029974): types 3, 5, 6 keep calling `Update()` (animated attract
  screen); the others call `Free()` once the frame is drawn (the screen stays frozen in VRAM).
- **Event 0x33 "Insert Coin"** (`Arc_ControllerOnEvent` 0x0202941c): money G+0x2F60 −1 (clamped 0..999 999), counter
  G+0x2F68 +1, sound 0x15C, camera on the cabinet (target pos + 7.0 up; camera struct 0x02139FB4 +0x23C, +0x26C..+0x278),
  `Free()` for 3/5/6, `Init(actor, 0)`, state 2. Then `Update()` every frame.
- **Event 0x34 "Stop"**: `Free()`, blank palette, camera back on the Sim, attract screen again.

## 5. Screen and drawing (CONFIRMED)

- Buffer: **0x1000 bytes = 128×128 texels, 2 bpp**, 32 bytes per row; pixel x is bits `(x & 3) * 2` of byte
  `y*32 + x/4` (DS texture format 2, 4 colours). Checked: the dumped buffer of a running Space Armada game decodes to the
  expected picture (7×4 aliens, cannon, shot; `build/arcade_test/screen0.png`).
- Upload every frame: `Gfx_UploadModelTexImage(actor + 0x1A4, 1, buf, 0x1000, 0)` (0x020bbde8) = copy over texture
  #1 of the cabinet model's TEX0 in VRAM. Palette: `Gfx_UploadModelTexPalette(actor + 0x1A4, 1, pal, 8, 0, 0)` (0x020bbcf0) =
  4 RGB555 colours over palette #1.
- Space Armada helpers: `Arc0_DrawSprite16x8` 0x0209bac8 (8 u16 rows, bit 0 = leftmost pixel, OR'ed with colour c),
  `Arc0_DrawGlyph8x5` 0x0209ba2c (5 bytes, digits '0'..'9' from a 5-byte font). The other games have their own copies
  (ASSUMED, not read).
- Input: Space Armada reads the key struct `[0x02139E8C]` (+2 held: 0x20 left, 0x10 right; +6 pressed: bit 1 = A, fire).
- Space Armada state (0xDC bytes, `[0x0213E598]`): +0xC0 cannon x, +0xBC score, 29 objects of 4 bytes at +0
  (x, y, kind), 16 shots of 3 bytes at +0x74. High score in the save game: G+0x467C (capped at 100 000).

## 6. What this means for own arcade games

- A new game = 3 functions `Init(actor, attract)`, `Update()`, `Free()` that allocate a 0x1000 buffer, draw into it,
  and call the two upload functions. That is the whole contract with the rest of the game.
- Free slots that already have a name, icon, price and cabinet: props **174, 175, 176** (their case only sets the type byte
  — a one-instruction patch each), plus the random pick of prop 164.
- The table has 10 entries and no room after it (other data follows at 0x0211E278): types ≥ 10 need the table moved to the
  ARM9 extension and the 5 literal pools repointed (same technique as the other moved tables, docs/formats/arm9.md).

### 6a. Implementation: ArcadeExt — CONFIRMED (emulator 2026-11-23, `build/arcade_test/card/`)

`godot/scripts/core/arcade_ext.gd`, editor edit kind `arcade:<prop>` (EditProject.set_arcade_game / arcade_games):
- the table is copied to the extension with entries for types 10.. (one per own game) and the 9 literal words are
  rewritten (base + 0 / 4 / 8); the case of each chosen cabinet (174 / 175 / 176) gets `mov r3,#type`;
- a game is ArmAsm source (`godot/scripts/core/arm_asm.gd`, a small ARM assembler checked against capstone by
  `godot/tests/test_armasm.gd` + `tools/check_armasm.py`) defining `init`, `update`, `free`. Symbols: ALLOC 0x02046880,
  FREE 0x0204681C, MEMSET 0x02046384, UPLOAD_TEX, UPLOAD_PAL, KEYS 0x02139E8C, RAND 0x0204CBB4, PLAY_SFX 0x020D5680,
  SCREEN_SIZE, MODEL (ArcadeExt.SYMS).
- Built-in test card (ArcadeExt.TEST_CARD): scrolling 4-colour checker, 4-pixel white border, colours inverted while
  a key is held.

Emulator checks (`godot/tests/test_arcade.gd`: test card on 174, location 24 cabinet changed to prop 174 and moved to
(28, 22) facing the start camera, direct boot):
- the menu reads "Arcade-Lunar Lander" with its own cabinet; the attract frame shows on the cabinet screen at start;
- Insert Coin: money 2000 → 1999, gameplay camera on the screen, the checker scrolls (play_a.png / play_b.png);
  `update` runs every 2nd frame (counter +30 per 60 frames: the games run at 30 Hz);
- with A held, the buffer equals byte for byte the expected card for its frame counter, inverted (input works);
- Stop: attract frame redrawn (counter back to 1), then `free` (buffer pointer 0).
- Note: the cabinet of location 24 stands against the street wall; with the Sim teleported next to it the gameplay
  camera ended up inside the wall (first session). Not a problem of the game code.

### 6b. Script games (arcade VM) — CONFIRMED (emulator 2026-11-24, `build/arcade_test/vm/`)

Games can also be written in the arcade language and run by a bytecode VM installed in the extension: see
[arcade_vm.md](arcade_vm.md). While a session runs, **A presses the bottom-screen Stop** (Sims UI): games must use
B / X / Y / D-pad.

## 7. Open points
- Rules, sprites and high-score slots of games 1–8; per-game sound effects.
- Which cabinet model / texture name goes with which prop (13 props, Arcade01…); whether every cabinet's screen
  texture is 128×128 format 2 (all games upload 0x1000 bytes: ASSUMED yes).
