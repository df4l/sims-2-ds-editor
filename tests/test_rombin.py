"""Tests for rom.bin (run: .venv/Scripts/python tests/test_rombin.py)."""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
from rombin import DEFAULT_ROMBIN, build, read_entries  # noqa: E402
from s2cmp import split_blobs  # noqa: E402


def main() -> None:
    data = DEFAULT_ROMBIN.read_bytes()
    entries = read_entries(data)
    assert build(entries) == data, 'archive round-trip'
    print(f'archive round-trip OK ({len(entries)} entries)')

    compressed = nitro = 0
    for i, e in enumerate(entries):
        blobs = split_blobs(e)
        if blobs is None:
            continue
        compressed += 1
        for _typ, start, _end, out in blobs:
            assert len(out) == struct.unpack_from('<I', e, start)[0] >> 8, f'entry {i}: size'
            if len(out) >= 16 and out[4:6] == b'\xff\xfe':
                assert struct.unpack_from('<I', out, 8)[0] == len(out), f'entry {i}: Nitro size field'
                nitro += 1
    print(f'decompression OK: {compressed} compressed entries, {nitro} Nitro files with consistent size')


if __name__ == '__main__':
    main()
