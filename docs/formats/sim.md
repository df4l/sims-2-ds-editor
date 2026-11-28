# Sims and characters (player Sim appearance, NPC models)

Status 2026-11-25: first pass. Code read in arm9 (Ghidra) + overlay 3 (capstone), record edit checked in melonDS.

## 1. Character model table — CONFIRMED (code + data)

`Actor_InitNpc` 0x0200b448 (and the player Sim ctor) call `Unk_0201180c_InitLocModel(actor, kind, id, 0x02118310 + 8*id)`.
Table `0x02118310`, 63 entries (id 0..62), 8 bytes:

```
+0 u32 anim list pointer      records of 3 u16: {anim id, BCA0 rom.bin entry, trs_anim entry or 0xFFFF}
+4 u16 BMD0 rom.bin entry
+6 u16 anim record count
```
Examples: 0 Alien (25 anims), 2 Ara (115), 22 Jebediah (96), 57 FemSim (158), 58 MalSim (156),
59 FemRatSim / 60 MalRatSim (same anim lists as 57 / 58), 61 / 62 = 57 / 58 again. Ids 24..39 are
small variant lists (goons, aliens, Optimum) sharing a model. Every BCA0 of a list is a `nitro_anim_joint`.

NPC models (`Ara`, `Auda`…) are single skinned meshes on a 33-bone `sims_*` skeleton, one 4x4 texture
(`*_Cmp4`), no customisation.

## 2. Player Sim model — CONFIRMED (data, emulator)

`FemSim` (3136) / `MalSim` (4805), model id `G+0x47D0` (57 female, 58 male). 50 nodes:

| node | name | chosen by |
|---|---|---|
| 0 | world_root | |
| 1..8 | Fem/MalHairA..H | mesh byte 0 (base 1) |
| 9 | Head | mesh byte 3 (always 9) |
| 10..13 | LegsA..D | mesh byte 2 (base 10) |
| 14..16 | TorsoA..C | mesh byte 1 (base 14) |
| 17.. | skeleton (Pelvis, Back, Chest, arms, legs…) | |

`Sim_ApplyAppearance` hides every node (`FUN_020b8fa4(actor+0x14C, node, 0)`) then shows the 4 chosen ones
(actor +0x23C..+0x23F). Base table `0x0212FBB8` = {1, 14, 10, 9}.

4 materials / textures, all 64×64 8bpp (format 4), texture slots: **0 hair, 1 head, 2 legs, 3 torso**.
Palettes: hair, head and legs share palette **A** (TEX0 offset 0), torso has palette **B** (offset 512);
256 colours each.

## 3. Appearance record — CONFIRMED (code + emulator)

Game state `G = [0x0213E434]`, record at **G+0x47AC** (0x21 bytes, copied by `Sim_SetAppearanceFromRecord`
0x0200ea74 into actor +0x220..+0x240), used when `G+0` bit 0 is set (`Map_SpawnPlayerSim` 0x020879c8), else
`Sim_ApplyAppearance` on the ctor defaults (`Sim_InitDefaultAppearance` 0x0200dfd0).

| rec | actor | meaning | applied as |
|---|---|---|---|
| +0x00 u16 | +0x220 | head texture (rom.bin entry, 4096 B) | tex slot 1 (`Sim_SetHeadTexture` 0x0200e3ac) |
| +0x02 u16 | +0x222 | torso texture | tex slot 3 (`Sim_SetTorsoTexture` 0x0200e33c) |
| +0x04 u16 | +0x224 | legs texture | tex slot 2 (`Sim_SetLegsTexture` 0x0200e2cc) |
| +0x06 u16 | +0x226 | colour 3 | pal B [80..128) |
| +0x08 u16 | +0x228 | colour 4 | pal A [128..176) |
| +0x0A u16 | +0x22A | colour 5 | pal A [176..208) |
| +0x0C u16 | +0x22C | colour 6 | pal B [208..256) |
| +0x0E u16 | +0x22E | colour 7 | pal A [208..256) |
| +0x10 u16 | +0x230 | colour 8 | pal A [80..128) |
| +0x12 u16 | +0x232 | skin tone A | pal A and B [32..80) |
| +0x14 u16 | +0x234 | skin tone B (overrides A when set) | pal A and B [32..80) |
| +0x16 u16 | +0x236 | colour 0 | pal A [0..32) |
| +0x1C u8 ×3 | +0x23C..E | hair / torso / legs node | node visibility; hair also picks the hair texture |
| +0x20 u8 | +0x240 | outfit mode (0 = normal) | `Sim_ApplyOutfitFemale` 0x0200f6b4 / male 0x0200f1cc |

0xFFFF = keep the model's own colours. Hair texture (slot 0) = table[hair node − 1]: female `0x0212FBE8`
(3082 3078 3081 3084 3077 3083 3080 3079), male `0x0212FC08` (4753 4756 4755 4752 4750 4754 4751 4747).

Colour value → palette (`Sim_UploadPartPalette` 0x0200dc20, uses the hardware divider):

| colour | file | entry size | per file |
|---|---|---|---|
| 0 | 1543 | 0x40 (32 colours) | value × 0x40, 8 per file |
| skin A | 1942 | 0x60 (48) | value % 4 |
| skin B | 1942 / 1943 / 1944 for value < 4 / 4..7 / ≥ 8 | 0x60 | value % 4 |
| 3, 4, 6, 7, 8 | `0x0212FBC4`[value / 5] = 1154..1157 | 0x60 | value % 5 |
| 5 | `0x0212FBBC`[value / 8] = 1938..1941 | 0x40 | value % 8 |

The palette files are 512-byte raw entries (catalogued as `unknown`).

Meaning of the ranges, from the texels of the textures (every hair texture uses only indices 0..31, heads 32..79,
torsos 32..127 of palette B, legs 128..255 of palette A):
- colour 0 = **hair colour** — CONFIRMED in melonDS (value 4 = grey hair, build/sim_test/hair_colour4.png; value 0 =
  orange, 1 = blond: the default female Sim is a redhead, she only looks blond under the night lighting);
- skin A / B = skin tone (head, arms);
- colours 3 / 6 = top colours (palette B 80..127 / 208..255), colours 4 / 5 / 7 = bottom colours — ASSUMED from the
  texel ranges; colour 8 (palette A 80..127) is used by no default texture.

Defaults (`Sim_InitDefaultAppearance`): female head 3085, torso 3324, legs 3104, colours 3 = 8, 4 = 10,
5 = 25, 7 = 9, skin A = 0, colour 0 = 0, nodes {1, 14, 11, 9}; male 4757 / 4988 / 4778, colour 3 = 1.
RAM check (loc5_control_unlocked): G+0x47AC = exactly the female defaults, G+0x47D0 = 57.

**Emulator test** (build/sim_test/record_edit_after.png): record edited in RAM (hair 5, torso 15, legs 12, torso
texture 3326, colour 3 = 3, skin A = 2) then warp 5 → 5: the new Sim actor has +0x220.. = the edited values and
shows another hairdo and outfit.

## 4. Create-a-Sim (overlay 3) — partial

Overlay 3 calls the setters through thin wrappers (0x0214A244..0x0214A474: `setter(sim, value, 0)`) and
`FUN_0200fae4(sim, part, base + v)` for the 3 node choices (`FUN_0200e168(part)` = base table above).
Option lists (u16 rom.bin entries) near 0x0214F884 (9 female + 9 male heads), 0x0214FC2C (male torsos),
0x0214FC7C (female torsos), 0x0214FCAC (male legs), 0x0214FD3C (female legs), interleaved with sprite triplets
(menu icons). How the menu indexes them (per torso / legs style?) is NOT read yet.

## 5. Editor (2026-11-25)
`godot/scripts/core/sim_look.gd` (SimLook): record helpers, `apply` = Sim_ApplyAppearance on a parsed BMD0
(Nsbmd node visibility from the SBC NODE command 0x02, texture slots, palette block), `install` rewrites
Sim_InitDefaultAppearance (0x0200DFD0..0x0200E168) as a 10-instruction copy of a female / male record table placed
right after it; a ROM exported this way is recognised and its looks read back. Edit kind `sim:57` / `sim:58`.
Sims tab (`scripts/ui/sims_tab.gd`): 3D preview, hair / torso / legs style, head / torso / legs texture (Create-a-Sim
lists, with thumbnails), colours with swatches, Reset. Tests: `test_sim` (headless), `test_sims_ui` (window).
CONFIRMED in melonDS: direct-boot ROM with an edited female look (build/sim_test/sim_look.nds) starts with it
(actor +0x220 = the table, build/sim_test/sim_look_boot.png), and on a normal boot Create-a-Sim opens on that
look (skin button 3 selected, same hair / top / skirt as the editor preview: build/sim_test/cas_starts_with_look.png).

## 6. Open questions
- Exact list structure / counts of the Create-a-Sim options; meaning of colours 3..8.
- Outfit mode +0x240 (female: textures 3330/3332 + palettes 3331/3333 at +0xA0; male 0x0200f1cc).
- `FUN_0200e1ac`: per-sex table 0x0211787C (22 u16, entries 630..672).
- BCA0 format (animations), the 4 nodes per frame, and NPC model replacement.
