# Text banks and dialogue tables — phase 3

Editor: Godot `godot/scripts/core/text_bank.gd` (same encoder and tree rebuild, output byte-identical to
`text.py edit`), Text tab of the editor. Python lab tool: `tools/text.py` (`verify`, `dump [lang]` → `rom_bin/text/<lang>.txt`, `get <id> [lang]`,
`edit out.bin [--lang xx] <id> <text> ...` → a new bank with replaced strings; `from_str` / `set_string` in Python).
Dialogue / message tables: `tools/layscript.py` (`conversation()`, `message()`, `npc_name()`).
Tests: `tests/test_text.py`.

Status: bank format **CONFIRMED** (code + 6/6 byte-identical re-encode + emulator: re-encoded lines shown by the
game). Character map: CONFIRMED for the European letters, 1 code ASSUMED (see §3). Tree rebuild: CONFIRMED (§2).

## 1. Banks — CONFIRMED (Txt_LoadLanguage 0x02052298)
One rom.bin entry per language. `Txt_LoadLanguage` reads the DS firmware language, clamps 0 (Japanese) and ≥ 6 to
1 (English), and loads the entry given by the u16 table at **0x0211E7D4**:

| firmware language | entry | file |
|---|---|---|
| 0 (ja → en), 1 en | 123 | English |
| 2 fr | 3496 | French |
| 3 de | 3593 | German |
| 4 it | 4184 | Italian |
| 5 es | 7599 | Spanish |
| — | 4214 | Japanese bank: same 3127 ids, **not referenced** by this ROM (ASJP, Europe) |

The bank is loaded **once** (language setup); warps do not reload it. In RAM (savestate `first_ingame`) the English
bank is at 0x021816DC, byte-identical to entry 123.

## 2. File — CONFIRMED (Txt_SetBank 0x02045194, Txt_DecodeString 0x0204505c)
```
u32  off_table
node[(off_table - 4) / 4]   u16 left, u16 right     node k has index 0x100 + k; root = 0x100
u32  offset[N]              at off_table; N = (offset[0] - off_table) / 4 = 3127 in all 6 banks;
                            offsets from the start of the file, strictly increasing
bitstreams                  one per string, each starting on a byte boundary; zero padding to 4 at the end
```
Decoding (Txt_DecodeString): start at node 0x100, read bits **LSB first**, 0 = left, 1 = right; a child < 0x100
is an output byte, then restart at the root. A byte ≥ 0xF0 starts a 2-byte character (Japanese glyph index); the
string ends at a 0 byte that is not the second byte of a 2-byte character. `Txt_GetString` (0x02052258) decodes
into a 0x400-byte buffer at 0x0213DFC8.
Quirk: in every bank one child points back to the root 0x100 (a dead branch: the walk restarts, nothing is
emitted). The encoder never uses it.

Round-trip: `Bank.write()` re-encodes every string with the bank's own tree → **byte-identical for 6/6 banks**.
By default the bank's own tree is kept (93–106 symbols in the European banks). If a new string needs a byte that
is not a leaf (e.g. `¿` or `é` in English), `set_string(..., rebuild=True)` / `text.py edit` rebuilds the tree.

**Tree rebuild — CONFIRMED** (`Bank.rebuild_tree`). The tree is read only by Txt_DecodeString (the 3 globals set by
Txt_SetBank, 0x02139E80/84/88, have no other reader), and the decoder has no limit on node count or depth. Rules:
root = node 0, u16 children, leaves < 0x100. The builder is a plain Huffman over the byte frequencies of all
strings (terminator 0 included) plus a weight-0 dummy leaf 0x100, which reproduces the "one child points back to
the root" quirk and keeps node count = symbol count like the original banks. Rebuilding all 6 banks: every string
decodes identically, banks get 264–4220 bytes smaller (so the original tool did not use these exact frequencies;
the original tree layout is not reproduced byte for byte, which is not needed). In game (build/text_tree_test/):
English bank with 0x0005 / 0x0007 / 0x049F using 26 accented or symbol characters absent from the original English
tree → tree rebuilt (93 → 119 symbols, 102 444 → 102 144 bytes) → all shown correctly after a fresh boot; untouched
strings (0x0A1C, NPC name, 0x04A0) correct; edited bank byte-identical in RAM at 0x021816DC.
Length is free: the offset table is rebuilt, and a longer bank loads fine (tested +84 bytes, §5).

## 3. Character map (European banks)
ASCII 0x20–0x7A as is, `\n` = 0x0A, `@1`… = placeholders (Sim name, numbers). Accented letters follow Latin-1
order shifted down, with Ð × Ø Ý Þ ð ÷ ø ý þ ÿ left out: À = 0x7F … Ü = 0x98, ß = 0x99, à = 0x9A … ü = 0xB4.
Other codes: 0x7B ©, 0x7D ¡, 0x7E ¿, 0xB5 °, 0xB8 ®. All CONFIRMED by words in the 5 banks (e.g. de
"ZERSTÖREN", "Außerirdische", "Überraschung"; es "¿Qué"; fr "Paramètres").
0x7C œ (fr "s?ur") and 0xB7 … (pause between words): CONFIRMED by their glyphs in game (tree rebuild test, §2),
like ¿ À É Î Õ Ü ñ ç ß ° Ä Ö â ê î ô û æ å è é ï ö à — the English font has them.
ASSUMED: 0xB9 non-breaking space (fr before "?", "Drahtlos DS").
After mapping, no unknown code remains in the 5 European banks.
String length: `Txt_GetString` decodes into a 0x400-byte buffer, so the editor refuses strings over 0x3FF bytes
(limit from the buffer size, not tested in game).

## 4. Names and dialogue tables (arm9)
- **NPC names**: text `0x143 + npc id` (FUN_02082810 with the NPC record). CONFIRMED: Jebediah S. Jerky = 22,
  Cow = 53, Bull = 54 (the NPCs placed in location 5); the conversation box shows "Jebediah S. Jerky" for NPC 22.
- **Conversations** (state 0xE, overlay 15, `State0E_ShowNextLine`): table **0x0211F16C**, 216 records
  `{u32 lines*, u8 count, 3 bytes 0}` (id 67 is null), 501 lines in total.
  Line = `{u16 text id, u8 speaker, u8 0}`; speaker 0x3F = narrator (no portrait), 0x40 = the player, else an NPC
  id (its "met" bit, NPC record +0x14, is set when it speaks). Started by layout script ops 0x17 / 0x2A and by
  talking to an NPC (op 0x19 sets which conversation an NPC offers).
  When the last line is closed: spawn group `arg1`, run script `arg2`, set story flag (0x58 = none).
  Conversations 3, 0x23, 0xA6 go to state 0x21 (overlay 11) instead.
  **References to the table — CONFIRMED (scan of every aligned word of arm9 + the 19 overlays, 2026-11-17)**: only the
  base address, in 3 literal pools: 0x0204209C (NavOp17_Conversation), 0x020412FC (NavOp2A_PhoneConversation) and
  ov15 0x0214A144 (State0E_ShowNextLine; overlay 15 is BLZ-compressed in the ROM). The line arrays (0x0211E9AC ..
  0x0211F16C) are only reached through the table; one array (0x0211E9F4, 1 line) is shared by 6 conversations.
  The conversation id is a u8 in the script ops and a u16 in the state; `Npc_SetTalkConversation` treats **0xD8 as
  "none"**, so 0xD8 must never be a real id. Conversation 0xBC has a fixed speaker (prop 0x1B name / portrait,
  text DAT_0214a160) whatever its lines say. State 0xE reads `lines[0].speaker` before checking the count: a
  conversation needs >= 1 line.
- **Editing (Godot editor, `EditProject` conversations section)**: a changed conversation is rewritten in place when
  its array is not shared and does not grow, otherwise appended to the ARM9 extension (docs/formats/arm9.md). New
  ids (217..255, 216 = 0xD8 skipped) move the table to the extension as **256 records** and rewrite the 3 literals;
  overlay 15 is then stored decompressed (overlay table flag cleared). A moved table is recognised on reopening
  because the literal no longer points at 0x0211F16C. CONFIRMED in the emulator (§5).
  CONFIRMED in the emulator: conversation 0 = lines 0x49F, 0x4A0, 0x4A1… spoken by NPC 22 in that order.
- **Messages** (popups, `Ui_ShowMessageBox` 0x0205871c, script op 0x45, goals): table **0x0211E8C0**,
  `{u32 text id, s32 second text id or -1}`, **26 records** (0x0211E990 is other data, referenced by FUN_02059088).
  Only reference: literal 0x02040720 (NavOp45_Message). Op 0x45 `queued=0` opens the popup at once, `queued=1`
  stores the two texts in G+0xE38 for later. The `script` argument (UI+0x18) runs when the popup is closed.
  CONFIRMED in the emulator: run from a conversation's end script, `queued=0` sets UI+0x18 but no popup ever shows
  (so its script never runs); `queued=1` shows it once back on the map. The game itself uses `queued=1` in 20 of 22 ops.
  Editor: changed in place; new ids move the table to the extension as 256 records (unused text id 0xFFFFFFFF).
- **New strings**: `Txt_DecodeString` does not bound-check the id (offset table at bank + u32 0, count implicit), so
  strings can be appended. The editor appends the same text to the 6 banks (ids stay aligned across languages).

## 5. Evidence log
- **New conversation / message / strings — CONFIRMED (2026-11-17)**, `build/conv_test/` (exported by
  `godot/tests/test_conversations.gd`, fresh boot, new game): location 5 block 1 script 3 plays the NEW conversation
  217 (table moved to 0x02152F00, overlay 15 literal patched): line 1 new string 0xC37 by Jebediah (name + portrait),
  line 2 new string 0xC38 by the player (box "???" with a "?" portrait, the unnamed player of the intro), line 3 the
  original 0x4A1; its end script runs a new script that opens the NEW message 26 (new string 0xC39, `queued=1`);
  closing it runs script 25 and the intro goes on with the next original conversation ("Shoot, kid…").
  Screenshots `conv217_line1.png`, `conv217_line2_player.png`, `msg26_queued.png`, `after_msg_script25.png`.
- `text.py verify`: 6/6 banks byte-identical after decode + re-encode; 3127 strings each.
- Emulator (savestate `first_ingame`, ROM build/sims2_rebuilt.nds): the 22 words of the English bank holding
  lines 0x49F / 0x4A0 were replaced in RAM by `text.py`-encoded strings (same slots, zero-padded), then a warp
  to location 5 (entry 8) replayed conversation 0: the game displayed both new lines, then the original 0x4A1
  (`build/text_test/conv0_line1_edited.png`, `conv0_line2_edited.png`).
- **Rebuilt ROM + fresh boot — CONFIRMED (2026-10-06)**, `build/text_rom_test/`: `text.py edit` replaced 0x0005
  (title prompt), 0x0007 (menu "Load-a-Sim (edited)") and 0x049F (190 chars with a `
`, ~3× the original); entry
  123 swapped in rom.bin (102 444 → 102 528 bytes, every other entry identical), ROM rebuilt with
  `rebuild_rom.py`. Fresh boot (load_rom, no savestate): the title screen and menu show the new strings; Create-a-Sim →
  conversation 0 shows the long line in full (6 lines, the `
` honoured), then the unedited 0x4A0 correctly
  (shifted offset). RAM dump: the edited bank is byte-identical at 0x021816DC, the original is absent.
  Screenshots: `title_0005_edited.png`, `menu_0007_edited.png`, `conv0_049f_long.png`, `conv0_04a0_shifted.png`.
