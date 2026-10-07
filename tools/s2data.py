"""Fast in-memory access to the extracted rom.bin entries (one pickle cache instead of 16 000 small files).

  from s2data import load
  db = load()           # list of Entry, index = rom.bin index
  db[9].data            # decompressed content (single blob), raw entry if not compressed
  db[9].blobs           # list of decompressed blobs ([] if raw)
"""
import csv
import pickle
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RB = ROOT / 'rom_bin'
CACHE = RB / 'cache.pkl'


@dataclass
class Entry:
    index: int
    raw: bytes
    compression: str
    blobs: list = field(default_factory=list)

    @property
    def data(self) -> bytes:
        """Single-blob decompressed content, or the raw entry. For multi-blob entries: the first blob."""
        return self.blobs[0] if self.blobs else self.raw


def _build() -> list:
    rows = list(csv.DictReader(open(RB / 'index.csv')))
    out = []
    for r in rows:
        i, nb = int(r['index']), int(r['blobs'])
        raw = (RB / 'raw' / f'{i:04d}.bin').read_bytes()
        if nb == 1:
            blobs = [(RB / 'dec' / f'{i:04d}.bin').read_bytes()]
        else:
            blobs = [(RB / 'dec' / f'{i:04d}_{k}.bin').read_bytes() for k in range(nb)]
        out.append(Entry(i, raw, r['compression'], blobs))
    return out


def load(rebuild: bool = False) -> list:
    if CACHE.exists() and not rebuild and CACHE.stat().st_mtime >= (RB / 'index.csv').stat().st_mtime:
        return pickle.loads(CACHE.read_bytes())
    db = _build()
    CACHE.write_bytes(pickle.dumps(db, protocol=pickle.HIGHEST_PROTOCOL))
    return db
