# rom.bin asset catalogue (phase 2)

Tool: `tools/catalog.py` (rules), `tools/s2data.py` (cached access to `rom_bin/`), `tools/s2gfx.py` (PNG previews).
Outputs: `rom_bin/catalog.csv` (one row per entry: kind, evidence, sizes, details), `rom_bin/locations.csv`,
`rom_bin/preview/<kind>/` (PNG), `rom_bin/by_kind/<kind>/` (decompressed files, Nitro ones with `.nsbmd`/`.nsbca`…).
Test: `tests/test_catalog.py`.

`evidence`: **code** = layout read in the ARM9 code · **struct** = exact invariant checked on every file of the kind ·
**heur** = heuristic (plausible, not proven). Nothing here is a format field telling the type: rom.bin has no types,
the type is implied by the index the caller asks for.

## Summary (8866 entries)

| kind | count | unpacked bytes | evidence | what |
|---|---:|---:|---|---|
| nitro_anim_joint (BCA0) | 2818 | 28.4 M | struct | skeletal animations (Sims, NPCs) |
| sprite_tiles | 1192 | 1.8 M | struct (1188) | 4bpp OBJ tiles of a sprite |
| sprite_def | 1192 | 75 K | struct (1188) + **code** (header) | sprite frames + OBJ pieces |
| sprite_pal | 1184 | 38 K | struct | 16-colour palette following a sprite_def |
| bg_composite | 512 | 2.4 M | struct (header layout) | 2D screen: palette + tilemap + coded tiles |
| trs_anim | 501 | 0.9 M | struct (459) / heur (41) | keyframe transform tracks (camera, object placement?) |
| img8_pal256 | 408 | 0.9 M | heur (visual check OK) | 256-colour palette + 8bpp square image (furniture textures, minigame frames) |
| nitro_model (BMD0) | 329 | 9.3 M | struct | 3D models (incl. location scenes) |
| img8_nopal | 131 | 0.5 M | heur (visual check OK) | 64×64 8bpp, palette elsewhere (Sim skin/face/clothes textures) |
| pal16 | 107 | 46 K | heur | other 16-colour palettes |
| img8_hdr | 88 | 0.4 M | heur (visual check OK) | 64×64 textures with 12-byte header (thought-bubble icons) |
| nitro_anim_srt (BTA0) | 63 | 81 K | struct | texture SRT animations (water, screens…) |
| bsp | 32 | 0.6 M | struct | **location** BSP tree (collision / visibility?) |
| gmd1 | 32 | 1.8 M | struct | **location** data, 16-byte records |
| nitro_anim_vis (BVA0) | 9 | 2 K | struct | visibility animations |
| text_bank | 6 | 0.65 M | **code** | Huffman string tables, one per language (docs/formats/text.md) |
| stored0 | 1 | 1.5 K | struct | type-0x00 stored blob, content unknown |
| loc_nav | 32 | 38 K | **code** | location nav/variant file (docs/formats/location.md) |
| **unknown** | **229** | **1.1 M** | | see the end of this file |

No BTX0/BTP0/BMA0: textures are inside the BMD0 files or in the `img8_*` entries.

## Assets come in bundles (CONFIRMED by data)
Consecutive indices belong together: the game loads groups of entries. Two patterns are systematic:

### Sprite triplet `[sprite_tiles][sprite_def][sprite_pal]`
- 1188/1195 `sprite_def` are right after a compressed entry whose size matches the def (`u32@8`), and 1184 are
  followed by a 32-byte palette. Visual check: tiles + palette give correct images (plumbob = entries 0/1/2).
- **Multi-blob entries are streamed sprite frames**: one compressed blob per frame. `u32@8 & 0xFFFFFF` = size of
  the largest frame (= buffer size); bit 24 = flag (meaning unknown). Validated on all 194 such sprites.

### Location bundle `[bsp][trs_anim][gmd1][nitro_model = scene][nitro_anim_srt]…` (see docs/formats/location.md)
32 locations, listed in `rom_bin/locations.csv`. Every `bsp` is followed, within 1–2 entries, by a `gmd1`, itself
immediately followed by a BMD0 (the scene mesh) in 31/32 cases (location 21: a BCA0 sits in between).
Between `bsp` and `gmd1` there is (30/32) a `trs_anim` with **1 frame and N tracks** (N up to 45) = a list of
static transforms. Phase 3 correction: this trs_anim belongs to the scene model (anim list of the arm9 location
table), it is NOT an object placement list. The authoritative list is the arm9 table: `tools/locations.py`.

## Formats

### sprite_def (raw) — CONFIRMED (code for the header, data + visual check for frames/pieces)
Parser/renderer: `tools/s2sprite.py`. 1188/1192 definitions parse fully, with every OBJ piece inside its tile data.
```
u8 w, u8 h (bounding box), u16 0, u16 ?, u16 frame_count (code: u16@6)
u32 tiles_size      bits 0-23: bytes (streamed: largest frame), bit 24: extended frame header
u16 frame_offset[frame_count]       (code: table at +0xC, offsets relative to +0xC)
frame: u8 piece_count | 0x80 flag, u8 0, u8 w, u8 h, u16 tile_offset, s16 x0, s16 y0,
       [bit 24 set: 6 more bytes, e.g. 00 17 00 1f 01 00 — bbox + ?],
       u32 piece[piece_count]
piece (u32, same fields as the OAM attributes): bits 0-8 x (signed), 9-17 y (signed), 18-19 size, 20-21 shape,
       22-31 first tile (32-byte 4bpp tiles, 1D mapping). (shape,size) -> w,h is the hardware OBJ table.
tile_offset: single-blob tiles -> byte offset in the decompressed tiles;
             streamed (multi-blob) -> byte offset of the frame's compressed blob in the RAW tiles entry
             (several frames can share one blob: e.g. 6155, 9 frames / 5 blobs).
```
4 definitions (674, 5583, 6019, 6022) have a nonzero byte at +0xA and another, variable frame header: not parsed
(evidence `heur`, flat tile-sheet preview). Entries 3593 (text bank) and 4330 were wrongly taken for sprites before
the full parse; fixed.

### bg_composite (compressed, or type-0 stored) — header layout CONFIRMED by data (509 files)
```
u16 flags        bit0: palette   bit3: tilemap   bits4-6: tiles section (always set so far)   bit7: ?
[bit0] u16 palette[256]          (16 palettes x 16 colours; map entries use palette bank 0..15)
[bit3] u16 w, u16 h  (in tiles, 32x24 = one 256x192 screen) ; u16 map[w*h] (standard BG screen entries)
tiles: u16 count, u16 table_len, u16 ?, u8 table[table_len], coded stream
```
The tile section uses an **unknown codec** (the table lists byte values such as `cc 66 99 77 dd ff 00 33…`,
i.e. pairs of 4bpp pixels). To decode it, the code is needed (callers FUN_020bbcf0 / FUN_020bbde8 from
FUN_0200f1cc). 0xC1 = palette only; 0x71 (6 files, 2217…2227) = no map, the map is the next entry (`c:0010`).

### trs_anim (raw) — CONFIRMED by data (459 exact)
```
u8 ? (0x08/0x0F/0x18/0x1E: frame rate?), u8 frames, u16 tracks, u16 flags (4|5), u16 ?
flags=4: frames*tracks records of 48 bytes ; flags=5: 36 bytes ; +4 bytes per extra track
record (flags=4): s32 tx,ty,tz ; s32 rx,ry,rz ; s32 sx,sy,sz (0x1000 = 1.0) ; u32 1 ; ... (fx20.12, ASSUMED)
```
41 files (most of the location ones) have the same header but variable-size records (`heur`).

### gmd1 (raw) — layout CONFIRMED by data (32 files)
```
"GMD1" u8 1 u8 2 u16 0 ; u32 count ; u32 1
"XFRM" + 36 bytes (transform / bounds, fx32?)
"FRAM" + count * 16-byte records        (len == 64 + 16*count on all 32 files)
```
Record content unknown (phase 3).

### bsp (compressed) — header CONFIRMED by data (32 files)
```
"BSP\0" u32 version=5 ; u32 0 ; u32 total_size (== len, all files) ; u32 0x14 ; u32 0x30 ; u32 ? (offset/size)
u32 0x0012FC2x ; ...
```

### img8_* (compressed)
- `img8_pal256`: 512-byte palette + square 8bpp bitmap (len − 512 ∈ {32², 64², …}).
- `img8_nopal`: 4096 bytes = 64×64 8bpp, palette elsewhere (skin tones?).
- `img8_hdr`: `u16 w=64, u16 h=64, u16 4 (format?), u16 0, 4 bytes` + 4096 bytes.
Visual check of 48 random samples per kind: all are coherent images.

### text_bank (raw) — CONFIRMED (phase 3, see docs/formats/text.md)
Huffman tree + u32 offset table + byte-aligned bitstreams, 3127 strings each. 123 en, 3496 fr, 3593 de, 4184 it,
7599 es (language table 0x0211E7D4), 4214 ja (not referenced). `tools/text.py`, round-trip 6/6.

### Type 0x00 "stored" blobs — CONFIRMED by data
`u32 0x00 | size<<8` + data: 15 raw entries are such blobs (14 bg_composite, 1 unknown). They are plain copies
in `Cmp_Decompress` (method 0) → **the game reads uncompressed blobs on the decompression path**, which makes
the type-6 compressor optional for phase 4 (to be confirmed per caller).

## Unknown (260 entries, 1.1 MB)
Largest groups (leading bytes, `r` = raw, `c` = compressed): `r:0000` ×43 (mostly zero-filled, 512…7680 bytes:
empty maps/buffers?), `r:0201` ×19 (often right after a scene model), `r:0001` ×14, `r:2000` ×10 (font-like,
offset table + 1bpp/2bpp glyphs, e.g. 7381), `c:00f0`/`r:00f0` ×11 (4331–4335: offset table + glyph-like data =
fonts?), `r:0f0f` ×5 (grids of small values, 6480 bytes), `c:0010` ×6 (tilemaps of the 0x71 screens).
