# BMD0 scene models — writing them (own scenes of new locations)

Reader: `godot/scripts/core/nsbmd.gd` (port of nitrogen / apicula, see location.md §5). Writer:
`godot/scripts/core/nsbmd_write.gd` (`NsbmdWriter`). glTF import: `godot/scripts/core/scene_import.gd`.
Tests: `godot/tests/test_bmd0.gd` (dictionaries, read → write → read), `godot/tests/test_scene.gd` (import, export,
ROMs for the emulator).

## 1. What the game's scene models use — CONFIRMED (data, 65 scene models)
Survey of every scene model of the 33 locations (script in the 2026-11-20 journal entry):
- display lists: `0x40/0x41` BEGIN/END_VTXS, `0x20` COLOR (baked lighting, most models), `0x21` NORMAL (a few
  lit models: CityExterior, Desert…), `0x22` TEXCOORD, `0x23..0x28` vertices. No `0x14` (matrix restore) or `0x1B`
  (scale) inside the lists;
- textures: 4x4-compressed (fmt 5, 533) and 8bpp palette (fmt 4, 337), a few 4bpp / 2bpp / direct / A3I5;
- 500 to 3 800 polygons per location; up to 3 scene models per location (record model list).

Small model taken as the pattern: Jail_Ext (entry 4213, 9 332 bytes):
```
BMD0 FF FE 02 00 size | 10 00 02 00 | MDL0 offset, TEX0 offset
MDL0: dict(models; entry u32 = model offset from the MDL0 start)
model: +0 size, +4 render cmds, +8 materials, +0xC shapes, +0x10 envelope matrices (= size: none)
       +0x14 info: sbcType 0, scalingRule 0, texMtxMode 0, nodes, materials, shapes, firstUnusedMtxStack 0, 0
       +0x1C posScale fx32 (16.0), +0x20 1/posScale, +0x24 u16 vertices, polygons, triangles, quads
       +0x2C fx16 box x, y, z, w, h, d (in boxPosScale units), +0x38 boxPosScale, +0x3C 1/boxPosScale
       +0x40 node dict (entry u32 = node offset from the dict start) + nodes
node 0: u16 flag 0xF807 (translation 0, rotation 0, scale 1, matrix stack 0x1F = none), u16 _00 = 0x1000
render cmds: 06 00 00 00 (NODEDESC 0, parent 0) | 02 00 01 (NODE 0 visible) | 0B (POSSCALE) |
             04 m 05 s (MAT, SHP) ... | 2B (INVPOSSCALE) | 01 (RET)
materials block: u16 tex dict offset, u16 palette dict offset | material dict (entry u32 = record offset from the
             block start) | tex -> material dict (entry: u16 list offset, u8 count, u8 0) | palette dict (same) |
             material index lists | records
material (0x2C): u16 0, u16 0x2C | diffAmb 0x0000E739 | specEmi 0 | polyAttr 0x001F008F (lit) / 0x001F0080 (unlit)
             | mask 0x3F1FF8FF | texImageParam 0x00030000 (repeat S/T; the TEX0 entry fills the rest at bind time)
             | mask 0xFFFFFFFF | u16 palette base 0 | u16 flag 0x1FCE | u16 width, height | fx32 1.0, 1.0
shapes block: dict (entry u32 = header offset from the block start) | header {u16 0, u16 0x10, u32 flag
             (1 normal, 2 colour, 4 texcoord), u32 list offset (from the header), u32 list size} | lists
TEX0: header 0x3C: +0x0C u16 texel size >> 3, +0x0E texture dict, +0x14 texel data | +0x1C 4x4 size >> 3,
      +0x1E dict, +0x24 4x4 texels, +0x28 4x4 indices | +0x30 palette size >> 3, +0x34 palette dict, +0x38 data
      texture dict entry: u32 param (offset >> 3, size codes, format, colour 0 transparent), u32 w | h << 11 | 1 << 31
      palette dict entry: u16 offset >> 3, u16 flag (1 = 4-colour palette)
```

## 2. Dictionaries — CONFIRMED (byte-identical on all 2 626 dictionaries of the 329 BMD0 in rom.bin)
`u8 0, u8 n, u16 size | u16 8, u16 entries offset (= 8 + 4 (n + 1)) | tree (n + 1) × {u8 refBit, u8 left,
u8 right, u8 entry} | u16 entry size, u16 names offset (from the entry header) | entries | names (16 bytes)`.
The tree is the NNS patricia tree the runtime searches by name (texture / palette binding): root = node 0, refBit 127,
zero key; keys = the 16 name bytes as 4 little-endian words, bit b = word b >> 5, bit b & 31; entries inserted in
index order; **nodes numbered in preorder** (downward links, left first). Inserting in order and numbering by
insertion matched only 1 738 / 2 626 (multi-node dictionaries differ) — the preorder renumbering makes all match.

## 3. Loading — CONFIRMED (code + emulator)
- `Map_LoadLocation` (0x02084894): anim_count 0 is supported (`if (rec+6 != 0)`), but it reads
  `anim_list[0].trs` (`*(u16 *)(*rec + 4)`) for every model: own scenes point every model at a dummy entry
  `{0xFFFF, 0xFFFF, 0xFFFF}` (kind 0xFFFF = no animation, `Unk_0201180c_InitLocModel`).
- `Gfx_LoadModelResource` (0x020bc1a8): `Arc_LoadDecompressedArea1` (any blob type, stored type 0 included), then
  `Gfx_AllocModelTexVram` (0x020bd468, NNS default setup): **one** VRAM allocation for the file's plain texels, one
  for its 4x4 texels (+ indices), one for its palettes; any failure → returns 0, the textures are never uploaded
  (garbage on screen, geometry fine). Then binds the model to TEX0 and shrinks the heap block to the texel offset.
- No name lookups of scene models / nodes in the location code (the record gives the entries).

## 4. Texture memory budget — CONFIRMED limits (emulator), exact values ASSUMED
Evidence (City Hall's 3 models merged and re-encoded in 8bpp as location 35, build/scene_test*/):
| plain texels | files | result |
|---|---|---|
| 232 704 | 1 | textures garbage |
| 183 552 | 1 | textures garbage |
| 149 760 | 1 | textures garbage |
| 50 944 | 1 | OK |
| 149 760 | 2 (≤ 116 480 each) | **OK** (`scene_35_split.png`, same as the original) |
So the limit is per file (one allocation), not only per location. The DS texture VRAM slots are 128 KiB; one
allocation presumably cannot straddle two slots (ASSUMED, NNS frame VRAM manager). Originals: largest plain block
in one file 116 480 (CultRoom), largest per location 151 552 (Gym, two files), palettes ≤ 17 120 (Store), 4x4
texels ≤ 67 584 (Atrium).
Writer budgets (values the game is known to handle): `FILE_BUDGET` 116 480 per file, `TEX_BUDGET` 151 552 per
location, `PAL_BUDGET` 17 120. `build_split` packs textures into ≤ 4 files (the location object has 6 model slots,
obj+8..obj+0x1C); over budget, the largest texture is halved, the largest palettes drop to 16 colours.

## 5. Writer output (NsbmdWriter) — CONFIRMED (emulator)
Per file: one identity node, one material + one shape per surface, the render commands of §1; unlit materials
(polyAttr 0x001F0080, +0x40 double-sided, alpha from the material), diffuse 0x7FFF as the vertex colour default;
display lists BEGIN_VTXS triangles, COLOR / TEXCOORD when they change, VTX_16, END_VTXS (packed 4 commands per
word). posScale = smallest power of two with |v| / posScale < 8. UVs are shifted per triangle by whole repeats
(texture repeat on) so that TEXCOORD fits s16 (1/16 texel). Textures: 4bpp (≤ 16 colours) or 8bpp (exact up to 256
colours, else median cut), colour 0 transparent when the image has alpha < 0.5, sizes rounded to powers of two
(8 .. 256 by default), or 4x4-compressed (§6, option on by default in the editor). Not used: normals / lights,
animations.
Checks: read → write → read of the 65 scene models gives the same triangles (within one VTX_16 step) and colours;
in game, the room of test_scene.gd (location 34) and City Hall re-encoded (location 35) render as expected.

## 6. 4x4-compressed textures (format 5) — writer CONFIRMED (emulator)
Encoder `godot/scripts/core/tex4x4.gd` (`Tex4x4`), used by `NsbmdWriter` when `tex4x4` is on for textures of more
than 16 colours (≤ 16 stay 4bpp, exact).
- **Format** (GBATEK, reader `Nsbmd._decode_4x4`): per 4x4 block a u32 of 2-bit texels (bit 2 (4y + x)) in the 4x4
  texel block (TEX0 +0x24, size +0x1C) and a u16 in the index block (+0x28, at texel offset / 2): bits 0..13 =
  palette offset in 4-byte units from the material's palette base, bits 14..15 = mode (0: 3 colours + transparent,
  1: c0, c1, (c0+c1)/2, transparent, 2: 4 colours, 3: c0, c1, (5c0+3c1)/8, (3c0+5c1)/8). Texture param offset =
  offset in the 4x4 texel block >> 3. TEX0 order like the originals: dicts, plain texels, 4x4 texels, 4x4 indices,
  palettes.
- **The game's own 4x4 textures share colour pairs** (CONFIRMED, survey of 326 TEX0 blocks): 197 037 blocks in mode
  3, 10 720 in mode 1, 8 899 in mode 0, no mode 2; e.g. one file has 9 632 blocks on 276 palette slots. So the
  encoder builds a codebook of colour PAIRS (one index step = 2 colours = 4 bytes): mode 3 for opaque blocks, mode 1
  for blocks with transparent texels (alpha < 128). Steps: best pair per block (principal axis + least squares) →
  median cut of the pairs (6-D) into ≤ `pairs` boxes → least-squares refit per box → 2 passes of "each block takes
  the best of its 6 nearest pairs, pairs refitted".
- **Quality** (tests/test_tex4x4.gd): the game's 4x4 textures decoded and re-encoded with the game's own pair
  count come back at RMS 0.61 / 255 (52.5 dB, 40 textures; the game's encoder = 0); the game's 8bpp textures as 4x4
  (one pair per 8 blocks): RMS 4.39 (35.3 dB), better than 16-colour palettes (4.56). ~150 ms per 128×128 texture.
- **Budgets** (emulator probes, `godot/tests/probe_tex4x4.gd`, City Hall geometry with unique 256×256 textures,
  `build/scene_test/probe_*.png`): 64 KiB of 4x4 texels in one file render; 96 KiB in one file → garbage; 128 KiB in
  one file → garbage; 2 files × 64 KiB → the second file's textures garbage. So the 4x4 space left to a location's
  scene is between 64 and 96 KiB **per location** (the Sim, NPCs and props use the rest, ASSUMED). Writer:
  `FILE4_BUDGET` 65 536 per file, `TEX4_BUDGET` 67 584 per location (Atrium, the most an original uses),
  `VRAM_BUDGET` plain + 1.5 × 4x4 ≤ 190 784 (Store). Over the 4x4 budget the largest 4x4 texture goes 8bpp when the
  plain budgets have room, else is halved; over the palette budget the largest 4x4 palette halves its pairs.
- **In game**: City Hall re-encoded in 4x4 (location 36, `test_scene.gd`, 49 textures, 56 960 B of 4x4 texels in
  one file, none halved; 8bpp needed 2 files and halved 10 textures) renders like the original
  (`build/scene_test/scene_36_4x4_1file.png`).

## 7. Open points
- Exact VRAM limits (between 50 944 and 149 760 for one file; how much the Sims / NPCs / props take).
- Lit materials (normals) and texture animations (BTA0) for own scenes.
- The location's "special model" (record +0x10: flag 0x10000 + material flag 0x400 cleared; City Hall's is the
  door frame CityHall_Ext, drawn differently) — own scenes set none.
