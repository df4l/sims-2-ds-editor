"""rom.bin archive tool (The Sims 2 DS). Format: docs/formats/rombin.md

  python tools/rombin.py list    [--rombin rom/data/rom.bin] [--csv out.csv]
  python tools/rombin.py extract [--rombin ...] [--out rom_bin] [--no-decompress]
  python tools/rombin.py build   [--src rom_bin/raw] [--out build/rom.bin]
  python tools/rombin.py verify  [--rombin ...]    # extract -> build round-trip in memory

extract writes:
  <out>/raw/NNNN.bin          entry exactly as stored (input of `build`)
  <out>/dec/NNNN.bin          decompressed entry (single blob)
  <out>/dec/NNNN_K.bin        K-th blob of a multi-blob entry
  <out>/index.csv             same columns as `list`
"""
import argparse
import csv
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from s2cmp import split_blobs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROMBIN = ROOT / 'rom' / 'data' / 'rom.bin'
TYPE_NAMES = {0x60: 'ea6', 0xE0: 'ea6+delta', 0x10: 'lz10', 0x90: 'lz10+delta'}


def read_entries(data: bytes) -> list[bytes]:
    """offsets[0] = table size = 4 * (N + 1); offsets[N] = file size. Entry i = data[offsets[i]:offsets[i+1]]."""
    first = struct.unpack_from('<I', data, 0)[0]
    if first % 4 or first < 8 or first > len(data):
        raise ValueError(f'bad table size 0x{first:X}')
    count = first // 4
    offs = struct.unpack_from(f'<{count}I', data, 0)
    if offs[-1] != len(data):
        raise ValueError(f'last offset 0x{offs[-1]:X} != file size 0x{len(data):X}')
    for i in range(count - 1):
        if offs[i] > offs[i + 1]:
            raise ValueError(f'offsets not sorted at {i}')
    return [data[offs[i]:offs[i + 1]] for i in range(count - 1)]


def build(entries: list[bytes]) -> bytes:
    """Inverse of read_entries. Entries are 4-aligned in the original; padding is kept inside the entries."""
    table_size = 4 * (len(entries) + 1)
    offs, pos = [], table_size
    for e in entries:
        offs.append(pos)
        pos += len(e)
    offs.append(pos)
    return struct.pack(f'<{len(offs)}I', *offs) + b''.join(entries)


def sniff(data: bytes) -> str:
    """Rough content guess (heuristic, for sorting only)."""
    if len(data) >= 4 and all(0x20 < c < 0x7F for c in data[:4]):
        return 'magic:' + data[:4].decode()
    if len(data) == 32 and all(struct.unpack_from('<H', data, i)[0] < 0x8000 for i in range(0, 32, 2)):
        return 'palette16?'
    return ''


def describe(i: int, entry: bytes, offset: int) -> dict:
    blobs = split_blobs(entry)
    if blobs is None:
        comp, usize, kind = 'raw', len(entry), sniff(entry)
    else:
        comp = '+'.join(TYPE_NAMES.get(b[0], hex(b[0])) for b in blobs)
        usize = sum(len(b[3]) for b in blobs)
        kind = sniff(blobs[0][3])
    return {'index': i, 'offset': f'0x{offset:08X}', 'size': len(entry), 'blobs': 0 if blobs is None else len(blobs),
            'compression': comp, 'unpacked_size': usize, 'guess': kind}


def iter_described(data: bytes):
    pos = struct.unpack_from('<I', data, 0)[0]
    for i, e in enumerate(read_entries(data)):
        yield describe(i, e, pos), e
        pos += len(e)


def cmd_list(args) -> None:
    data = args.rombin.read_bytes()
    rows = [d for d, _ in iter_described(data)]
    if args.csv:
        write_csv(args.csv, rows)
    print(f'{"idx":>5} {"offset":>10} {"size":>8} {"unpacked":>8} {"compression":<20} guess')
    for r in rows:
        print(f'{r["index"]:5} {r["offset"]:>10} {r["size"]:8} {r["unpacked_size"]:8} {r["compression"]:<20} {r["guess"]}')
    print(f'{len(rows)} entries, {sum(r["blobs"] > 0 for r in rows)} compressed, {sum(r["blobs"] == 0 for r in rows)} raw',
          file=sys.stderr)


def write_csv(path: Path, rows: list[dict]) -> None:
    with open(path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


def cmd_extract(args) -> None:
    data = args.rombin.read_bytes()
    raw_dir, dec_dir = args.out / 'raw', args.out / 'dec'
    raw_dir.mkdir(parents=True, exist_ok=True)
    if not args.no_decompress:
        dec_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for d, e in iter_described(data):
        i = d['index']
        (raw_dir / f'{i:04d}.bin').write_bytes(e)
        if not args.no_decompress and d['blobs']:
            blobs = split_blobs(e)
            if len(blobs) == 1:
                (dec_dir / f'{i:04d}.bin').write_bytes(blobs[0][3])
            else:
                for k, b in enumerate(blobs):
                    (dec_dir / f'{i:04d}_{k}.bin').write_bytes(b[3])
        rows.append(d)
    write_csv(args.out / 'index.csv', rows)
    print(f'extracted {len(rows)} entries to {args.out}')


def cmd_build(args) -> None:
    files = sorted(args.src.glob('*.bin'))
    idx = [int(f.stem) for f in files]
    if idx != list(range(len(files))):
        raise SystemExit('raw entries must be named 0000.bin .. NNNN.bin with no gap')
    out = build([f.read_bytes() for f in files])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(out)
    print(f'built {args.out}: {len(files)} entries, {len(out)} bytes')


def cmd_verify(args) -> None:
    data = args.rombin.read_bytes()
    rebuilt = build(read_entries(data))
    if rebuilt != data:
        n = next(i for i in range(min(len(data), len(rebuilt))) if data[i] != rebuilt[i])
        raise SystemExit(f'round-trip FAILED (first difference at 0x{n:X})')
    print(f'round-trip OK: {len(data)} bytes identical')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('list')
    p.add_argument('--rombin', type=Path, default=DEFAULT_ROMBIN)
    p.add_argument('--csv', type=Path)
    p.set_defaults(func=cmd_list)
    p = sub.add_parser('extract')
    p.add_argument('--rombin', type=Path, default=DEFAULT_ROMBIN)
    p.add_argument('--out', type=Path, default=ROOT / 'rom_bin')
    p.add_argument('--no-decompress', action='store_true')
    p.set_defaults(func=cmd_extract)
    p = sub.add_parser('build')
    p.add_argument('--src', type=Path, default=ROOT / 'rom_bin' / 'raw')
    p.add_argument('--out', type=Path, default=ROOT / 'build' / 'rom.bin')
    p.set_defaults(func=cmd_build)
    p = sub.add_parser('verify')
    p.add_argument('--rombin', type=Path, default=DEFAULT_ROMBIN)
    p.set_defaults(func=cmd_verify)
    args = ap.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
