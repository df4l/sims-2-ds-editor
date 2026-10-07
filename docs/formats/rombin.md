# rom.bin format (The Sims 2 DS, ASJP)

NitroFS file `/rom.bin` (FAT id 19), 37 934 164 bytes. Tools: `tools/rombin.py`, `tools/s2cmp.py`.

## 1. Archive: index table — CONFIRMED (code + all files)

```
u32 offsets[N+1]      LE, at the very start of the file, no magic, no names
                      offsets[0]  = table size = 4*(N+1) = 0x8A8C  -> N = 8866 entries
                      offsets[N]  = file size
entry i = rom.bin[offsets[i] : offsets[i+1]]
```
- Code: `Arc_GetEntrySize` (0x0204439c) / `Arc_ReadEntryRaw` (0x02043d38) / `Arc_LoadEntry` (0x02043ea0):
  `FS_SeekFile(f, idx*4)`, `FS_ReadFile(f, buf, 8)` → start, end; size = end − start; seek(start); read.
- **Access by index only** (no names, no hashes).
- The game handles `start == 0xFFFFFFFF` as a special/missing case (debug check). Never observed in the file.
- Every offset is 4-aligned and sorted, with no empty entry. Entries carry their own padding.
- Round-trip `read_entries` → `build`: **byte-identical** (`tools/rombin.py verify`).

## 2. Compression — CONFIRMED (code), the decompressor is validated on all files

**The archive does not mark which entries are compressed**: the caller of `Arc_LoadEntry` passes a
`compressed` flag. Header of a compressed blob (u32 LE):

```
bits 0-7   type byte   (type>>4)&7 = method,  type&0x80 = 16-bit delta filter after decompression
bits 8-31  decompressed size
```
Dispatcher `Cmp_Decompress` (0x02042adc): method 0 = raw copy (DMA), 1 = LZ77 0x10 (BIOS SVC),
2 = Huffman (SVC), 3 = RLE (SVC), **6 = EA custom codec** (`Cmp_DecompressType6`, ITCM 0x01FF8000).
Methods observed in rom.bin: **6 (0x60)** and **1 (0x10)**. No 0xE0/0x90 (delta) blob is actually used.

### Method 6 (EA custom LZ), reimplemented in `s2cmp.decompress_type6`
Hand-written ASM, copied at boot from arm9.bin+0x139220 (autoload) to ITCM 0x01FF8000.
```
u32 hdr        0x60 | size<<8
u8  table_len  (multiple of 4, ≠ 0)          u8 escape   (initial escape code)
u8  off_bits   (extra bits for long offsets)  u8 esc_bits (bits compared against the escape)
u8  table[table_len]                          (bytes frequently used by runs)
bit stream: 32-bit LE words, read MSB first
```
`gamma()` = k ones then a 0 (k<7) → value `1<<k | read(k)`; 7 ones → `1<<7 | read(7)` (range 1..255).

Loop:
- `c = read(esc_bits)`; if `c != escape` → **literal** `c<<(8-esc_bits) | read(8-esc_bits)`.
- otherwise `g = gamma()`:
  - `g ≥ 2`: `g2 = gamma()`; **`g2 == 255` → end**; otherwise **match** of length `g+1`,
    distance `(((g2-1)<<off_bits | read(off_bits))<<8 | read(8)) + 1`.
  - `g == 1`, bit 0 → **short match** of length 2, distance `read(8)+1`.
  - `g == 1`, bits 1,0 → **literal with the escape prefix** `escape<<(8-esc_bits) | read(…)`,
    and the escape becomes the `read(esc_bits)` that precedes it.
  - `g == 1`, bits 1,1 → **run**: `n = gamma()`; if `n ≥ 0x80`: `n = (n<<1|bit)&0xFF`, `hi = gamma()-1`;
    `v = gamma()`, byte = `table[v-1]` if `v < 0x20`, else `(v<<3 | read(3)) & 0xFF`; repeated `n+1+hi*256` times.

Validation: 5577 type-6 blobs decompressed with exact size; all **3219** Nitro files obtained
(BMD0/BCA0/BTA0/BVA0) have their internal size field equal to the decompressed size.

## 3. Multi-blob entries — CONFIRMED by data, use ASSUMED
205 entries are a **chain of blobs**: `[blob][00000000 optional][blob]…` (each blob is 4-aligned).
`Arc_LoadEntry` only decompresses ONE blob, so these entries are read raw and split by the calling code.
Phase 2: **194 of them are streamed sprite frames** (one blob per frame, see docs/formats/catalog.md);
the others are still to be identified.
The trailing `00000000` word appears after 969 single blobs as well (encoder detail, matters for re-compression).

## 4. Entry classification (`tools/rombin.py list`) — DETECTION, not a field
An entry is called "compressed" if it splits exactly into valid blobs (exact size, input fully consumed).
Result: 5601 compressed (5572 ea6 only, 23 lz10 only, 6 mixed), 3265 raw.
Risk: a raw entry that happens to validate as LZ10 (23 cases, to be checked). The true flag is in the callers.

## Remaining questions
- Who calls `Arc_LoadEntry`, with which indices and which `compressed` flag (catalogue by caller).
- How multi-blob entries are consumed.
- Phase 2: 15 raw entries are type-0x00 stored blobs (`00 | size<<8` + data), so method 0 is used by the game.
- Writing back: a type-6 **compressor** will be needed (or store the data raw with type 0x00, if the caller
  goes through `Cmp_Decompress`, which also handles method 0).
