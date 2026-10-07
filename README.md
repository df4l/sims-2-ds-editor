# The Sims 2 (Nintendo DS) — map editor and reverse engineering

A map editor for **The Sims 2** on Nintendo DS. It comes with the Python tools and the format notes it is built on.

You can:
- open any of the 33 locations, in a top-down view and in 3D;
- move, duplicate, delete or edit placed items (NPCs, props, doors, triggers…) and entry points;
- edit the collision (delete or move cells, add boxes);
- edit the default furniture of the 6 hotel rooms;
- read the location scripts with their dialogue text in 6 languages;
- build a playable `.nds` with your changes.

Every format the editor writes was reverse engineered from the game code and checked in an emulator
(see [`docs/`](docs/)).

**No game data is included.** You need your own dump of the game. The project was made on **ASJP (Europe), ROM
version 0x00**. Other versions are not supported: the tools read data tables at fixed arm9 addresses.

## Setup

Requirements:
- Python 3.11 or newer (tested on 3.14) and git;
- `ndstool` 1.24 or newer. On Windows, put `ndstool.exe` at the project root. On Linux, put `ndstool` on the PATH.

```sh
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt     # Linux: .venv/bin/python
.venv/Scripts/python tools/setup_rom.py path/to/sims2.nds
```

`setup_rom.py` does four things:
1. unpacks the ROM into `rom/`;
2. decompresses `arm9.bin`;
3. checks that your dump is the supported version (SHA-1 of `arm9.bin` and `rom.bin`);
4. extracts the `rom.bin` archive into `rom_bin/`, which takes a few minutes.

`rom/` and `rom_bin/` are read-only inputs: nothing ever writes to them.

## Editor

```sh
.venv/Scripts/python editor/server.py        # http://127.0.0.1:8765, opens the browser
```

Edits are saved as you make them in `build/editor_project/`. **Build ROM** writes `build/editor_rom/sims2_edited.nds`.
The first time you open a location, its 3D models are converted and cached in `build/editor_cache/`.

The [editor README](editor/README.md) covers how to use it and what has been checked in the game.

## Layout

| Path | What |
|---|---|
| `editor/` | Editor: stdlib HTTP server + browser UI (plain JS, vendored three.js) |
| `tools/` | Parsers and writers (`rombin.py`, `layout.py`, `bsp.py`, `text.py`, `roomfurn.py`, …), each runnable on its own |
| `tests/` | Tests. Run each one with `python tests/test_xxx.py`. They need `rom/` and `rom_bin/` |
| `docs/formats/` | One page per format: `rom.bin`, locations, layouts, text, hotel room furniture, asset catalogue |
| `docs/ghidra.md` | Functions identified in arm9, with their addresses |
| `docs/journal.md` | Research log: each hypothesis, how it was tested, and the result |

Every page in the docs marks each claim as **confirmed** (by the code, by every file, or in the emulator) or
**assumed**.

## Credits

- [ndspy](https://github.com/RoadrunnerWMC/ndspy) for the DS file formats and decompression.
- [nitrogen](https://github.com/jorgecafe/nitrogen) for the BMD0 → glTF conversion (pinned, MIT).
- [three.js](https://threejs.org/) (vendored, MIT).
- [ndstool](https://github.com/devkitPro/ndstool) for unpacking and rebuilding the ROM.

The Sims is a trademark of Electronic Arts. This project is not affiliated with EA or Nintendo.
