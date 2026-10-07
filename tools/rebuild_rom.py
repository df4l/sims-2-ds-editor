"""Rebuild a .nds ROM from an unpacked tree with ndstool.

Usage: python tools/rebuild_rom.py [--src rom] [--work build/unpacked] [--out build/sims2_rebuilt.nds]

The tree in /rom/ is never touched: it is copied to --work first (unless --no-copy),
then the ARM9 module params are fixed and ndstool -c is run on the copy.

Why the ARM9 patch: rom/arm9.bin was decompressed after extraction, but its module
params still hold compressed_static_end != 0. The boot code would then try to
BLZ-decompress already decompressed code. Setting the field to 0 marks it uncompressed.
"""
import argparse
import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def ndstool() -> str:
    """ndstool.exe at the project root, else ndstool on the PATH (Linux)."""
    for p in (ROOT / 'ndstool.exe', ROOT / 'ndstool'):
        if p.exists():
            return str(p)
    found = shutil.which('ndstool')
    if not found:
        raise SystemExit('ndstool not found: put ndstool(.exe) at the project root or on the PATH (see README)')
    return found


NITROCODE = struct.pack('<II', 0xDEC00621, 0x2106C0DE)


def fix_arm9_params(path: Path) -> None:
    data = bytearray(path.read_bytes())
    i = data.find(NITROCODE)
    if i < 0x1C:
        raise SystemExit(f'{path}: module params (nitrocode) not found')
    field = i - 0x1C + 0x14  # compressed_static_end
    old = struct.unpack_from('<I', data, field)[0]
    if old:
        struct.pack_into('<I', data, field, 0)
        path.write_bytes(data)
        print(f'arm9.bin: compressed_static_end 0x{old:08X} -> 0 (offset 0x{field:X})')


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=ROOT / 'rom', type=Path)
    ap.add_argument('--work', default=ROOT / 'build' / 'unpacked', type=Path)
    ap.add_argument('--out', default=ROOT / 'build' / 'sims2_rebuilt.nds', type=Path)
    ap.add_argument('--no-copy', action='store_true', help='reuse an existing (modified) work tree')
    args = ap.parse_args()

    work = args.work.resolve()
    if work == (ROOT / 'rom').resolve():
        raise SystemExit('refusing to work directly in /rom/')
    if not args.no_copy:
        if work.exists():
            shutil.rmtree(work)
        shutil.copytree(args.src, work)
    rebuild(work, args.out)
    print(f'built {args.out} ({args.out.stat().st_size} bytes)')


def rebuild(work: Path, out: Path) -> None:
    """ARM9 params fix + ndstool -c on an unpacked tree (never /rom/ itself)."""
    work = Path(work).resolve()
    if work == (ROOT / 'rom').resolve():
        raise SystemExit('refusing to work directly in /rom/')
    fix_arm9_params(work / 'arm9.bin')
    cmd = [ndstool(), '-c', str(Path(out).resolve()),
           '-9', 'arm9.bin', '-7', 'arm7.bin', '-y9', 'y9.bin', '-y7', 'y7.bin',
           '-d', 'data', '-y', 'overlay', '-t', 'banner.bin', '-h', 'header.bin']
    subprocess.run(cmd, cwd=work, check=True, capture_output=True)


if __name__ == '__main__':
    main()
