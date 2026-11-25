# Arcade VM — own arcade games written in a small language

Own games for the free cabinets 174 / 175 / 176 (Lunar Lander, Space Gunner, Log Jump; see arcade.md §6). A game is a
text script in the **arcade language**, compiled by the editor to bytecode. One copy of an interpreter written in ARM
(installed in the ARM9 extension) runs every script game in the game; a second copy in GDScript runs the same bytecode
for the in-editor preview. The two copies must behave identically (same wrap-around, division, clipping, font, budget).

| Part | File |
|---|---|
| Compiler (script → bytecode) | `godot/scripts/core/arcade_script.gd` (ArcadeScript.compile) |
| Reference VM (GDScript, preview) | `godot/scripts/core/arcade_vm.gd` (ArcadeVM) |
| ARM VM (game) | `godot/scripts/core/arcade_vm_asm.gd` (ArmAsm source), installed by ArcadeExt.install_vm |
| Install (game block + thunks) | `godot/scripts/core/arcade_ext.gd` (install_script_game, game_block) |
| Examples | `godot/scripts/core/arcade_examples.gd` (Lunar Lander, test card) |
| Tests | `godot/tests/test_arcade_vm.gd` (language + VM, no ROM), `godot/tests/test_arcade.gd` (install, ROMs), `godot/tests/arcade_vm_ref.gd` (reference screen for the emulator comparison) |

Status: **CONFIRMED** in melonDS (2026-11-24, §5): the ARM VM gives byte-identical screen, palette and variables to
the reference VM on a self-test script using every opcode.

## 1. The language

Line based; `;` or `//` starts a comment. Names are ASCII letters, digits, `_`. Integers are signed 32-bit and wrap.

Declarations (top level):

```
palette #000000, #FFFFFF, #FF8020, #60C0FF   ; the 4 colours (RGB, stored as BGR555); default black, white, green, red
const GRAV = 1                               ; constant expression
var x, y = 10, t[8]                          ; reset to their value at every init (array: 1..255 slots, start at 0)
keep best = 0                                ; set once when the ROM boots, kept across games (high score)
sprite ship                                  ; 8 rows of up to 16 pixels: . or 0 = transparent, 1..3 = colour
......3333......
end
func init     ; optional: run at Insert Coin / attract screen, after the `var` reset
end
func frame    ; required: run 30 times per second (the game calls Update every 2nd frame)
end
```

Statements: `name = expr`, `name op= expr` (`+= -= *= /= %= &= |= ^=`), `a[i] = expr`, `if / elif / else / end`,
`while expr / end`, `for i = a to b [step k] / end` (constant step, default 1, inclusive bound), `break`, `continue`,
`return`, a call of a user function `name` (no arguments, no result), and the commands:

| Command | Effect |
|---|---|
| `cls c` | fill the screen with colour c |
| `rect x, y, w, h, c` | filled rectangle (clipped) |
| `pix x, y, c` | one pixel |
| `spr s, x, y [, flip]` | sprite s (16×8; colour 0 transparent); flip bit 0 = horizontal, bit 1 = vertical |
| `text "...", x, y, c [, size]` | 3×5 font, 4·size pixels per character, `\n` = new line (x back to the start, +6·size) |
| `num v, x, y, c [, size]` | a number in decimal |
| `pal i, colour` | change palette entry i (uploaded at the end of the frame) |
| `sfx id` | play a game sound (id of the game's sound player; named ids `SFX_…` in §2b) |

Expressions, lowest to highest precedence: `or`, `and` (both short-circuit, result 0/1), `not`, `| ^ &`,
comparisons `== != < <= > >=`, `<< >>` (count & 31, `>>` arithmetic), `+ -`, `* / %` (truncating, `x / 0 = 0`,
`x % 0 = 0`, remainder has the sign of the dividend), unary `- ~`. Constants are folded at compile time with the same
rules. Literals: `123`, `0x7F`, `'A'`, `#RRGGBB` (BGR555), `true` / `false`.

Functions: `held(mask)`, `pressed(mask)` (keys held / newly pressed, masked), `rnd(n)` (0..n−1, 0 if n ≤ 0),
`abs`, `min`, `max`, `hit(x1, y1, w1, h1, x2, y2, w2, h2)` (rectangles overlap, touching = 0), `peek(x, y)` (colour of
a pixel, 0 off screen).

Built-in names: `attract` (1 while the cabinet shows its attract screen, i.e. init without a coin), `tick` (frames since
init), key masks `A B SELECT START RIGHT LEFT UP DOWN R L X Y` (DS key bits).

**Keys in the game (CONFIRMED in melonDS, 2026-11-24):** **A is taken by the Sims UI**: while a cabinet runs, A
activates the selected bottom-screen action, which is *Stop*. The game still sees the press, but the session ends.
Use B, X, Y and the D-pad (none of them stops the game; Space Armada fires with B). L / R / START / SELECT not tested.

Limits: 254 variable slots, call depth 32, operand stack 48 checked at compile time (the ARM stack has 64 slots),
30 000 ops per call of init / frame (beyond that the call stops; the next frame runs normally), strings ≤ 255
characters, jump targets u16 (code ≤ 64 KiB).

## 2. Bytecode

Stack machine, one byte per opcode, operands little-endian. Vars are 256 × s32 (0 = attract, 1 = tick).

| Op | Name | Operands | Stack |
|---|---|---|---|
| 00 | RET | | return (from the entry: end of the call) |
| 01 / 02 / 03 | PUSHB / PUSHH / PUSHW | s8 / s16 / s32 | → v |
| 04 / 05 | LOAD / STORE | u8 slot | → v / v → |
| 06 / 07 | LOADX / STOREX | u8 slot, u8 size | i → v / i, v → (out of range: read 0, write ignored) |
| 08 / 09 / 0A | JMP / JZ / JNZ | u16 target | / v → / v → |
| 0B | CALL | u16 target | |
| 0C / 0D | POP / DUP | | v → / v → v, v |
| 10..22 | ADD SUB MUL DIV MOD AND OR XOR SHL SHR NEG NOT BNOT EQ NE LT LE GT GE | | a, b → r (NEG / NOT / BNOT: a → r) |
| 30 | CLS | | c → |
| 31 | SPR | | s, x, y, flip → |
| 32 | RECT | | x, y, w, h, c → |
| 33 | PIX | | x, y, c → |
| 34 | TEXT | u8 n, n chars | x, y, c, size → |
| 35 | NUM | | v, x, y, c, size → |
| 36 | SFX | | id → |
| 37 | PAL | | i, colour → |
| 38 / 39 | HELD / PRESSED | | mask → keys & mask |
| 3A | RND | | n → r |
| 3B / 3C / 3D | ABS / MIN / MAX | | |
| 3E | HIT | | 8 values → 0/1 |
| 3F | PEEK | | x, y → c |

Any other opcode stops the call ("bad opcode"). Two entries: the **init entry** (offset 0: STOREs resetting the `var`
declarations, CALL init if present, RET) and the **frame entry** (the `frame` function).

Screen: 128×128, 2 bpp, 32 bytes per row, pixel x in bits `(x & 3) * 2` of byte `y * 32 + x / 4` (the cabinet's
screen texture, arcade.md §4).

## 2b. Sounds (`sfx`)

`sfx id` calls the game's sound player `Snd_PlaySoundEvent` 0x020D5680 (id, cabinet position = actor +0x78).
**Confirmed (code)**: id indexes 0x02136CB8 = 672 × {s16 count, u16 first}; a random variant (count is 1 for every
arcade id) is taken from 0x02137738 = {u16 sound, u16 param}. Sound data is in `data/SoundData.rom` (custom
container, not decoded), so the meaning below comes from where the original cabinets call each id.

| Name (built-in constant) | id | sound | original use |
|---|---|---|---|
| SFX_BOUNCE | 0x1F | 411 | Bustin' Out ball on a wall, Space Armada cannon hit, Copter crash |
| SFX_LOST | 0x20 | 412 | Bustin' Out ball lost, Copter reset |
| SFX_BLIP | 0x21 | 413 | Bustin' Out paddle on the edge, Copter pickup |
| (loop) | 0x22 | 414 | Copter cabinet ambience, started by Arc_ControllerCtor |
| SFX_COPTER | 0x23 | 415 | Copter (delivery / landing, assumed) |
| SFX_CATCH | 0x24 | 416 | Pie Factory pie caught |
| SFX_MISS | 0x25 | 417 | Pie Factory pie missed |
| SFX_LAUNCH | 0x26 | 418 | Pie Factory new pie |
| (loop) | 0x2E | 419 | Sisyphus cabinet ambience |
| SFX_PADDLE | 0x2A | 420 | Bustin' Out paddle hit, Space Armada march step |
| SFX_ENEMY_SHOT | 0x2B | 421 | Space Armada invader fires |
| SFX_EXPLODE | 0x2C | 422 | Space Armada invader destroyed |
| SFX_SHOOT | 0x2D | 423 | Space Armada cannon fires |
| SFX_LASER | 0x27 | 424 | X-Raider fires |
| SFX_BREAK | 0x28 | 425 | Bustin' Out brick, X-Raider enemy hit |
| (loop) | 0x29 | 426 | X-Raider cabinet ambience |
| SFX_EXTRA1 / SFX_EXTRA2 | 0x2F / 0x30 | 427 / 428 | **no caller**: arcade block, maybe for the unfinished games 174–176 |
| SFX_COIN | 0x15C | 676 | Insert Coin (Arc_ControllerOnEvent) |
| SFX_CLACK | 0x264 | 455 | billiard ball contact |

Rules (both VMs): ids outside 0..671 (past the table: would read garbage) and the 3 looping ambiences (the
controller only stops the one it started in its handle +0x9C, a game-started loop would never stop) are
**ignored**; with a constant argument the compiler refuses them. Any other id 0..671 is passed through (not
tested: some, like the location ambiences 0x0B / 0x0D / 0x0E, may loop).

## 3. In the ROM

`ArcadeExt.install` (export): the VM is assembled once into the ARM9 extension (≈ 3.2 KiB: code, op table, font,
operand stack, call stack). Each script game adds:

- a **game block** G: +0 code address, +4 sprites address, +8 init entry (u16), +0xA frame entry (u16), +0xC sprite
  count (u16), +0xE flags (bit 0 = palette changed), +0x10 palette now (4 × u16), +0x18 palette at start,
  +0x20 cabinet actor, +0x24 screen buffer (0 when freed), +0x30 vars[256] (s32), then the sprites (32 bytes each)
  and the bytecode;
- three thunks `init: ldr r2, =G; b vm_init`, `update: ldr r0, =G; b vm_update`, `free: ldr r0, =G; b vm_free`,
  written into the moved game table (arcade.md §6a) as the game's {Init, Update, Free}.

`vm_init(actor, attract)`: store actor and attract, tick = 0, palette back to the start palette, allocate the
0x1000 buffer once (ALLOC), clear it, upload the palette, run the init entry. `vm_update`: run the frame entry, tick + 1,
upload the palette if it changed, upload the screen (Gfx_UploadModelTexImage). `vm_free`: free the buffer.
Registers while running: r4 G, r5 pc, r6 operand stack, r7 code, r8 vars, r9 budget, r10 call stack, r11 screen.

## 4. Editor side

Edit kind `arcade:<prop>` stores JSON `{lang: "script" | "asm", source}` (EditProject.set_arcade_game /
arcade_game / arcade_games; plain text = an old asm game). `set_arcade_game` compiles once to report
"line N: message" errors.

**Arcade tab** (`godot/scripts/ui/arcade_tab.gd`, ArcadeTab): cabinet choice (174 / 175 / 176), source editor
(highlighting, Ctrl+S = Apply, error line highlighted), live preview = ArcadeVM at 30 Hz drawn by a shader straight
from the 2 bpp screen bytes (keys from the keyboard while the screen has the focus; sfx ids and the op budget shown,
pressing A warns that it stops the session), Attract / Restart / Step, palette pickers (rewrite the `palette` line)
and a 16×8 sprite pixel editor (rewrites the rows of the `sprite` block, one undo step per pixel). Unapplied text is
kept per cabinet. "Placed in" scans the layouts for prop items of the cabinet; "Selected prop → cabinet" changes the
prop id of the item selected in the location view. While the tab is shown the item list is hidden and the side
panel widened. Test: `godot/tests/test_arcade_ui.gd` (31 checks).

## 5. Verification

- `test_arcade_vm.gd`: every operator folded by the compiler and computed by the VM, statements, arrays, keep / var,
  budget and recursion limits, drawing (clipping, sprite flips, font, size 2), 12 error messages with their line,
  the examples run 300 frames. All pass.
- `test_arcade.gd`: the ARM op table matches the opcodes of ArcadeVM entry by entry; exports `arcade_self.nds`
  (self-test script below, cabinet 174 at location 24) and `arcade_lander.nds`.
- **Emulator** (`build/arcade_test/vm/`, 2026-11-24): `arcade_self.nds`, Insert Coin, game block dumped at tick 105
  (no key) and 113 (A + LEFT held): screen buffer (4 096 bytes), palette and the 256 variables **identical** to
  `arcade_vm_ref.gd` for the same tick and keys. The self-test uses every opcode except RND / SFX (divisions by
  negatives and by 0, shifts, 32-bit overflow, recursion, arrays out of range, clipped sprites / rects, text with every
  glyph, sizes 2 / 3, peek, hit, held, palette changes). Screenshot self_play.png. CONFIRMED.
  Pitfall: a RAM dump can land in the middle of an Update (vars of tick N, tick counter still N − 1): take the dump
  one frame later.
- `arcade_lander.nds`: the lander falls, crashes ("CRASHED!"), restarts, thrust flame shown (lander_play.png). Found
  there: A stops the session (§1). RND used (pad position); SFX not checked by ear.
- `arcade_sfx.nds` (`build/arcade_test/sfx/`, 2026-11-25, test_arcade SFXTEST): every named sound in turn (one per
  30 ticks) and each frame 3 ignored ids (0x29, 0x29 + 700, −0x29). Insert Coin at location 24: after 738 ticks
  n = 25 (all 17 names played, then 8 more), shown id = the expected one, no crash after ~2 200 ignored calls
  (sfx_play.png). CONFIRMED (execution; the sounds themselves not heard).

## 6. Open points

- What 0x2F / 0x30 sound like (no caller), and which non-arcade ids loop. Sounds not checked by ear (no audio capture).
- L / R / START / SELECT during a session.
- Arcade tab done (§4). Keyboard play in the preview checked only by code (the automated test drives
  `step(keys)`), not by hand.
