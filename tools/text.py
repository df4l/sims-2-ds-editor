"""Text banks (Huffman-coded string tables), one per language. Format: docs/formats/text.md

  python tools/text.py verify              # decode + re-encode every bank, byte-identical check
  python tools/text.py dump [lang]         # every string -> rom_bin/text/<lang>.txt (default: all languages)
  python tools/text.py get 0x49f [lang]    # one string
  python tools/text.py edit out.bin [--lang en] 0x49f "new text" [0x4a0 "..."]   # bank with replaced strings
                                           # (the Huffman tree is rebuilt only if a new character needs it)

Reader: Txt_SetBank 0x02045194 (stores the three pointers), Txt_DecodeString 0x0204505c (Huffman walk),
Txt_GetString 0x02052258 (id -> 0x400-byte buffer at 0x0213DFC8).

File:  u32 off_table
       node[(off_table - 4) / 4]   u16 left, u16 right; node k has index 0x100 + k, the root is 0x100,
                                   a child < 0x100 is a leaf (= output byte)
       u32 offset[N]               at off_table, N = (offset[0] - off_table) / 4 = 3127 in all 6 banks;
                                   offsets from the start of the file
       bitstreams                  each string starts on a byte boundary; bits are read LSB first,
                                   0 = left, 1 = right; the string ends at a 0 byte that is not the second
                                   byte of a 2-byte character (lead byte >= 0xF0)
"""
import argparse
import heapq
import struct
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / 'rom_bin' / 'raw'

# rom.bin entry of each language bank (identified by decoding them, see docs/formats/text.md)
BANKS = {'en': 123, 'fr': 3496, 'de': 3593, 'it': 4184, 'ja': 4214, 'es': 7599}

# European code page: Latin-1 letters shifted down, with Ð × Ø Ý Þ ð ÷ ø ý þ ÿ left out.
# CONFIRMED from words in the 5 European banks; ¿ À É Î Õ Ü ñ ç ß œ ° … Ä Ö â ê î ô û æ å è é ï ö à also seen
# rendered in game in the English font (build/text_tree_test/). 0xB9 is still ASSUMED.
CHARMAP = {
    0x7B: '©', 0x7C: 'œ',  # œ: fr "s?ur", glyph seen in game
    0x7D: '¡', 0x7E: '¿', 0x7F: 'À', 0x80: 'Á', 0x81: 'Â', 0x82: 'Ã', 0x83: 'Ä', 0x84: 'Å', 0x85: 'Æ',
    0x86: 'Ç', 0x87: 'È', 0x88: 'É', 0x89: 'Ê', 0x8A: 'Ë', 0x8B: 'Ì', 0x8C: 'Í', 0x8D: 'Î', 0x8E: 'Ï',
    0x8F: 'Ñ', 0x90: 'Ò', 0x91: 'Ó', 0x92: 'Ô', 0x93: 'Õ', 0x94: 'Ö', 0x96: 'Ù', 0x97: 'Ú',
    0x98: 'Ü', 0x99: 'ß', 0x9A: 'à', 0x9B: 'á', 0x9C: 'â', 0x9D: 'ã', 0x9E: 'ä', 0x9F: 'å', 0xA0: 'æ',
    0xA1: 'ç', 0xA2: 'è', 0xA3: 'é', 0xA4: 'ê', 0xA5: 'ë', 0xA6: 'ì', 0xA7: 'í', 0xA8: 'î', 0xA9: 'ï',
    0xAA: 'ñ', 0xAB: 'ò', 0xAC: 'ó', 0xAD: 'ô', 0xAE: 'õ', 0xAF: 'ö', 0xB1: 'ù', 0xB2: 'ú', 0xB3: 'û',
    0xB4: 'ü', 0xB5: '°',
    0xB7: '…',  # pause mark ("Ouais… ça va", "rätselhaft … Diese"), glyph seen in game
    0xB8: '®', 0xB9: ' ',  # non-breaking space (fr "vendre ?", "Drahtlos DS")
}


class Bank:
    def __init__(self, data: bytes):
        self.data = data
        tab = struct.unpack_from('<I', data, 0)[0]
        self.nodes = [struct.unpack_from('<2H', data, 4 + 4 * k) for k in range((tab - 4) // 4)]
        first = struct.unpack_from('<I', data, tab)[0]
        self.offsets = list(struct.unpack_from(f'<{(first - tab) // 4}I', data, tab))
        self.strings = [self._decode(o) for o in self.offsets]

    def _decode(self, p: int) -> bytes:
        """Same walk as Txt_DecodeString: returns the bytes before the terminating 0."""
        d, nodes = self.data, self.nodes
        cur, p, bit, out, wide = d[p], p + 1, 0, bytearray(), False
        while True:
            n = 0x100
            while n >= 0x100:
                n = nodes[n - 0x100][(cur >> bit) & 1]
                bit += 1
                if bit == 8:
                    cur, p, bit = (d[p] if p < len(d) else 0), p + 1, 0
            if n == 0 and not wide:
                return bytes(out)
            out.append(n)
            wide = not wide and n >= 0xF0

    def codes(self) -> dict:
        """symbol -> list of bits (0/1), from the tree."""
        res, stack = {}, [(0x100, [])]
        while stack:
            n, path = stack.pop()
            if n < 0x100:
                res[n] = path
                continue
            # one child in every bank points back to the root (0x100): the decoder just restarts the walk,
            # so that branch emits nothing and is never used by the encoder
            l, r = self.nodes[n - 0x100]
            stack += [(c, path + [b]) for b, c in ((0, l), (1, r)) if c != 0x100]
        return res

    def rebuild_tree(self) -> None:
        """New Huffman tree from the byte frequencies of the current strings (terminator included).
        Only Txt_DecodeString reads the tree and it has no size limit: the root must be node 0 and leaves < 0x100.
        Like the original banks, one slot points back to the root (a weight-0 dummy leaf), so there are as many
        nodes as symbols."""
        freq = Counter(c for s in self.strings for c in s + b'\x00')
        heap = [(w, k, s) for k, (s, w) in enumerate(sorted(freq.items()))] + [(0, -1, 0x100)]
        heapq.heapify(heap)
        nodes, tick = [None], len(heap)
        while len(heap) > 1:
            w1, _, a = heapq.heappop(heap)
            w2, _, b = heapq.heappop(heap)
            if not heap:
                nodes[0] = (a, b)       # the last merge is the root, node 0 = 0x100
                break
            nodes.append((a, b))
            heapq.heappush(heap, (w1 + w2, tick, 0xFF + len(nodes)))
            tick += 1
        self.nodes = nodes

    def write(self) -> bytes:
        """Re-encode every string with the existing tree (the tree is kept as is)."""
        codes = self.codes()
        tab = 4 + 4 * len(self.nodes)
        body = bytearray()
        offs = []
        base = tab + 4 * len(self.strings)
        for s in self.strings:
            offs.append(base + len(body))
            bits = [b for c in s + b'\x00' for b in codes[c]]
            for i in range(0, len(bits), 8):
                body.append(sum(b << k for k, b in enumerate(bits[i:i + 8])))
        out = struct.pack('<I', tab) + b''.join(struct.pack('<2H', *n) for n in self.nodes)
        out += struct.pack(f'<{len(offs)}I', *offs) + body
        return out + b'\x00' * (-len(out) % 4)


def to_str(s: bytes) -> str:
    """Readable form: European code page, 2-byte characters (Japanese glyph indices) as {fxxx}."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c >= 0xF0 and i + 1 < len(s):
            out.append(f'{{{c:02x}{s[i + 1]:02x}}}')
            i += 2
            continue
        out.append(chr(c) if 0x20 <= c < 0x7B or c == 0x0A else CHARMAP.get(c, f'{{{c:02x}}}'))
        i += 1
    return ''.join(out)


_REVERSE = {v: k for k, v in CHARMAP.items()}


def from_str(t: str) -> bytes:
    """Inverse of to_str: European code page, {xx} / {xxxx} escapes for raw codes."""
    out, i = bytearray(), 0
    while i < len(t):
        c = t[i]
        if c == '{':
            j = t.index('}', i)
            out += bytes.fromhex(t[i + 1:j])
            i = j + 1
            continue
        if c == '\n' or 0x20 <= ord(c) < 0x7B:
            out.append(ord(c))
        elif c in _REVERSE:
            out.append(_REVERSE[c])
        else:
            raise ValueError(f'character {c!r} has no code in the European code page')
        i += 1
    return bytes(out)


def set_string(b: Bank, i: int, t: str, rebuild=False) -> bool:
    """Replace string i. The tree is kept when it already has every byte; otherwise it is rebuilt if
    rebuild=True, else ValueError. Returns True if the tree was rebuilt."""
    s = from_str(t)
    missing = sorted(set(s) - set(b.codes()))
    if missing and not rebuild:
        raise ValueError(f'string 0x{i:x}: codes {[hex(c) for c in missing]} are not in the tree')
    b.strings[i] = s
    if missing:
        b.rebuild_tree()
    return bool(missing)


_cache = {}


def bank(lang='en') -> Bank:
    if lang not in _cache:
        _cache[lang] = Bank((RAW / f'{BANKS[lang]:04d}.bin').read_bytes())
    return _cache[lang]


def text(i: int, lang='en') -> str:
    return to_str(bank(lang).strings[i])


def cmd_verify(_):
    bad = 0
    for lang, e in BANKS.items():
        d = (RAW / f'{e:04d}.bin').read_bytes()
        b = Bank(d)
        same = b.write() == d
        bad += not same
        print(f'{lang} ({e:04d}): {len(b.strings)} strings, {len(b.codes())} symbols, round-trip '
              f'{"OK" if same else "DIFFERS"}')
    return bad == 0


def cmd_dump(a):
    out = ROOT / 'rom_bin' / 'text'
    out.mkdir(parents=True, exist_ok=True)
    for lang in [a.lang] if a.lang else BANKS:
        b = bank(lang)
        lines = [f'{i:04x}\t' + to_str(s).replace('\n', '\\n') for i, s in enumerate(b.strings)]
        (out / f'{lang}.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        print(f'{lang}: {len(lines)} strings -> {out / (lang + ".txt")}')


def cmd_get(a):
    print(text(int(a.id, 0), a.lang or 'en'))


def cmd_edit(a):
    if len(a.pairs) % 2:
        raise SystemExit('edit: expected id/text pairs')
    b = Bank((RAW / f'{BANKS[a.lang]:04d}.bin').read_bytes())
    rebuilt = False
    for k in range(0, len(a.pairs), 2):
        rebuilt |= set_string(b, int(a.pairs[k], 0), a.pairs[k + 1].replace('\\n', '\n'), rebuild=True)
    data = b.write()
    assert [x for x in Bank(data).strings] == b.strings
    Path(a.out).write_bytes(data)
    print(f'{a.lang}: {len(a.pairs) // 2} string(s) replaced{", Huffman tree rebuilt" if rebuilt else ""}, '
          f'{len(b.data)} -> {len(data)} bytes -> {a.out}')


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('verify').set_defaults(f=cmd_verify)
    p = sub.add_parser('dump')
    p.add_argument('lang', nargs='?')
    p.set_defaults(f=cmd_dump)
    p = sub.add_parser('get')
    p.add_argument('id')
    p.add_argument('lang', nargs='?')
    p.set_defaults(f=cmd_get)
    p = sub.add_parser('edit')
    p.add_argument('out')
    p.add_argument('pairs', nargs='+', help='id text [id text ...]; "\\n" = new line')
    p.add_argument('--lang', default='en')
    p.set_defaults(f=cmd_edit)
    a = ap.parse_args()
    if a.f(a) is False:
        sys.exit(1)


if __name__ == '__main__':
    main()
