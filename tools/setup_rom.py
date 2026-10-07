"""Unpack your own copy of the game into rom/ and rom_bin/ (first step after cloning).

Usage: python tools/setup_rom.py path/to/sims2.nds

1. ndstool -x the ROM into rom/ (arm9.bin, arm7.bin, overlays, data/, header, banner).
2. BLZ-decompress arm9.bin if needed (ndspy) and drop the 12-byte footer ndstool keeps after it. The tools read arm9 data tables at fixed addresses.
3. Check arm9.bin and data/rom.bin against the version this project was made on: ASJP (Europe), ROM version 0x00.
   Another version is unpacked anyway but the addresses in tools/ and docs/ will be wrong for it.
4. Extract rom.bin into rom_bin/ (tools/rombin.py extract), then classify it (tools/catalog.py -> catalog.csv).
"""
import argparse
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rebuild_rom import NITROCODE, ndstool  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ROMBIN_SHA1 = 'ee2af3ce6edf26a77cfc17c1b1b942d11cb1431a'
ARM9_SHA1 = '001c348579fe84c14be4e0c9018eafdb57c96539'   # decompressed, compressed_static_end zeroed (a ROM rebuilt by this project then matches too)


def arm9_sha1(data: bytes) -> str:
    d = bytearray(data)
    i = d.find(NITROCODE)
    if i >= 0x1C:
        struct.pack_into('<I', d, i - 0x1C + 0x14, 0)
    return hashlib.sha1(d).hexdigest()


def decompress_arm9(path: Path) -> bool:
    """BLZ-decompress arm9.bin in place if it is compressed. True if it was."""
    from ndspy import codeCompression
    data = path.read_bytes()
    if arm9_sha1(data) == ARM9_SHA1:
        return False
    i = data.find(NITROCODE)
    end = struct.unpack_from('<I', data, i - 0x1C + 0x14)[0] if i >= 0x1C else 0
    if not end:
        return False
    try:
        dec = codeCompression.decompress(data)
    except Exception as e:  # noqa: BLE001
        print(f'arm9.bin: not decompressed ({e})')
        return False
    if len(dec) <= len(data):
        return False
    path.write_bytes(dec)
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('nds', type=Path)
    ap.add_argument('--skip-extract', action='store_true', help='only unpack rom/, do not fill rom_bin/')
    a = ap.parse_args()
    rom = ROOT / 'rom'
    if rom.exists() and any(rom.iterdir()):
        raise SystemExit('rom/ already exists and is not empty: delete it first to unpack again')
    rom.mkdir(exist_ok=True)
    (rom / 'data').mkdir()
    (rom / 'overlay').mkdir()
    subprocess.run([ndstool(), '-x', str(a.nds.resolve()), '-9', 'arm9.bin', '-7', 'arm7.bin', '-y9', 'y9.bin',
                    '-y7', 'y7.bin', '-d', 'data', '-y', 'overlay', '-t', 'banner.bin', '-h', 'header.bin'],
                   cwd=rom, check=True, capture_output=True)
    print(f'unpacked {a.nds} into rom/', flush=True)
    if decompress_arm9(rom / 'arm9.bin'):
        print('arm9.bin: decompressed', flush=True)
    a9 = (rom / 'arm9.bin').read_bytes()
    if a9[-12:-8] == NITROCODE[:4]:     # ndstool -x keeps the 12-byte footer after arm9 (not needed to rebuild)
        (rom / 'arm9.bin').write_bytes(a9[:-12])
    code = (rom / 'header.bin').read_bytes()[0xC:0x10].decode('ascii', 'replace')
    ok = True
    for name, want in (('arm9.bin', ARM9_SHA1), ('data/rom.bin', ROMBIN_SHA1)):
        d = (rom / name).read_bytes()
        got = arm9_sha1(d) if name == 'arm9.bin' else hashlib.sha1(d).hexdigest()
        if got != want:
            ok = False
            print(f'WARNING {name}: sha1 {got}, expected {want}')
    print(f'game code {code}: ' + ('same version as the project (ASJP v0x00)' if ok else
          'NOT the version this project was made on, addresses in tools/ will not match'), flush=True)
    if not a.skip_extract:
        print('extracting rom.bin into rom_bin/ ...', flush=True)
        subprocess.run([sys.executable, str(ROOT / 'tools' / 'rombin.py'), 'extract'], check=True)
        print('classifying entries into rom_bin/catalog.csv ...', flush=True)
        subprocess.run([sys.executable, str(ROOT / 'tools' / 'catalog.py')], check=True)


if __name__ == '__main__':
    main()
