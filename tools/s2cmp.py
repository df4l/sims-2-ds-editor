"""Decompression of rom.bin entries (The Sims 2 DS).

Dispatcher reproduced from FUN_02042adc (arm9), see docs/formats/rombin.md.
Header u32 (LE): bits 0-7 = type byte, bits 8-31 = decompressed size.
  type >> 4 & 7 : 0 = raw, 1 = LZ77 (BIOS), 2 = Huffman (BIOS), 3 = RLE (BIOS), 6 = EA custom (ITCM 0x01FF8000)
  type & 0x80   : 16-bit delta filter applied after decompression
"""
import struct


class _Bits:
    """Bit reader of the ITCM routine: MSB-first, refilled with 32-bit LE words."""

    def __init__(self, data: bytes, pos: int):
        self.d = data
        self.pos = pos
        self.buf = 0
        self.n = 0  # bits remaining in buf

    def bit(self) -> int:
        if self.n == 0:
            self.buf = struct.unpack_from('<I', self.d, self.pos)[0]
            self.pos += 4
            self.n = 32
        self.n -= 1
        return (self.buf >> self.n) & 1

    def bits(self, k: int) -> int:
        v = 0
        for _ in range(k):
            v = (v << 1) | self.bit()
        return v

    def gamma(self) -> int:
        """0x01FF8048: k ones then a 0 -> 1 followed by k bits; 7 ones -> 1 followed by 7 bits, no terminator."""
        k = 0
        while k < 7 and self.bit():
            k += 1
        return (1 << k) | self.bits(k)


def decompress_type6(data: bytes, pos: int = 4, out_size: int | None = None) -> tuple[bytearray, int]:
    """EA custom LZ (ITCM 0x01FF8000). data[pos:] = second header word, table, bit stream.
    Returns (output, input position after the last word consumed)."""
    w = struct.unpack_from('<I', data, pos)[0]
    table_len, escape, off_bits, esc_bits = w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, w >> 24
    if table_len == 0 or table_len % 4:
        raise ValueError(f'bad table length {table_len}')
    if esc_bits > 8:
        raise ValueError(f'bad escape bit count {esc_bits}')
    table = data[pos + 4:pos + 4 + table_len]
    lit_bits = 8 - esc_bits
    br = _Bits(data, pos + 4 + table_len)
    out = bytearray()
    while True:
        if out_size is not None and len(out) > out_size:
            raise ValueError('output overflow')
        code = br.bits(esc_bits)
        if code != escape:
            out.append((code << lit_bits | br.bits(lit_bits)) & 0xFF)
            continue
        g = br.gamma()
        if g >= 2:  # long match
            g2 = br.gamma()
            if g2 == 0xFF:
                break
            dist = ((g2 - 1) << off_bits | br.bits(off_bits)) << 8 | br.bits(8)
            length = g + 1
        elif not br.bit():  # short match, length 2
            dist = br.bits(8)
            length = 2
        elif not br.bit():  # literal whose high bits equal the escape; becomes the new escape
            new_escape = br.bits(esc_bits)
            out.append((escape << lit_bits | br.bits(lit_bits)) & 0xFF)
            escape = new_escape
            continue
        else:  # run
            c = br.gamma()
            hi = 0
            if c >= 0x80:
                c = ((c << 1) | br.bit()) & 0xFF
                hi = br.gamma() - 1
            v = br.gamma()
            v = table[v - 1] if v < 0x20 else ((v << 3) | br.bits(3)) & 0xFF
            out += bytes([v]) * (c + 1 + (hi << 8))
            continue
        src = len(out) - dist - 1
        if src < 0:
            raise ValueError(f'match before start (dist {dist + 1} at {len(out)})')
        for i in range(length):
            out.append(out[src + i])
    return out, br.pos


def _undelta16(buf: bytearray, size: int) -> None:
    for i in range(1, size // 2):
        v = (struct.unpack_from('<H', buf, 2 * i)[0] + struct.unpack_from('<H', buf, 2 * i - 2)[0]) & 0xFFFF
        struct.pack_into('<H', buf, 2 * i, v)


def decompress_lz10(data: bytes, pos: int, out_size: int) -> tuple[bytearray, int]:
    """Standard LZ77 type 0x10 (BIOS SVC). data[pos:] = bytes after the 4-byte header."""
    out = bytearray()
    while len(out) < out_size:
        flags = data[pos]
        pos += 1
        for b in range(8):
            if len(out) >= out_size:
                break
            if flags & (0x80 >> b):
                x = data[pos] << 8 | data[pos + 1]
                pos += 2
                src = len(out) - (x & 0xFFF) - 1
                if src < 0:
                    raise ValueError('LZ10 match before start')
                for k in range((x >> 12) + 3):
                    out.append(out[src + k])
            else:
                out.append(data[pos])
                pos += 1
    if len(out) != out_size:
        raise ValueError('LZ10 size mismatch')
    return out, pos


def decompress_blob(data: bytes, pos: int = 0) -> tuple[int, bytes, int]:
    """Decompress one blob starting at data[pos] (4-byte header included).
    Returns (type byte, output, end position). Raises ValueError if it is not a valid blob."""
    if len(data) - pos < 8:
        raise ValueError('too short')
    hdr = struct.unpack_from('<I', data, pos)[0]
    typ, size = hdr & 0xFF, hdr >> 8
    method = (typ >> 4) & 7
    if typ & 0x0F:
        raise ValueError(f'type 0x{typ:02X}: low nibble set')
    if method == 6:
        out, end = decompress_type6(data, pos + 4, size)
        if len(out) != size:
            raise ValueError(f'size mismatch: header {size}, got {len(out)}')
    elif method == 1:
        out, end = decompress_lz10(data, pos + 4, size)
    else:
        # 0 = raw copy, 2 = Huffman, 3 = RLE: the game supports them, never observed in rom.bin
        raise ValueError(f'method {method} not handled (type 0x{typ:02X})')
    if typ & 0x80:
        _undelta16(out, size)
    return typ, bytes(out), end


def split_blobs(entry: bytes) -> list[tuple[int, int, int, bytes]] | None:
    """Split an entry into a chain of compressed blobs [(type, start, end, output)].
    Blobs follow one another, each optionally followed by zero padding (up to 4-byte alignment
    plus one zero word). Returns None if the entry is not entirely made of blobs (= raw data)."""
    blobs = []
    pos = 0
    while pos < len(entry):
        if blobs and entry[pos:pos + 4] == bytes(4):
            pos += 4
            continue
        try:
            typ, out, end = decompress_blob(entry, pos)
        except (ValueError, IndexError, struct.error):
            return None
        blobs.append((typ, pos, end, out))
        pos = (end + 3) & ~3
    return blobs or None
