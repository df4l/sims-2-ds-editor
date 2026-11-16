# The Sims 2 (Nintendo DS) — map editor and reverse engineering

A map editor for **The Sims 2** on Nintendo DS, written in Godot 4 ([`godot/`](godot/)). It comes with the Python
reverse-engineering tools and the format notes it is built on.

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

## Editor

The editor is a standalone Godot 4.7 project: no Python, no ndstool, no unpacked ROM. It opens your `.nds`, reads
everything from it and exports a new `.nds`. See [`godot/README.md`](godot/README.md) for how to run and use it.

## Reverse-engineering tools (optional)

The Python tools in `tools/` are only needed to research the formats, not to use the editor.

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

## Layout

| Path | What |
|---|---|
| `godot/` | Editor (Godot 4.7, GDScript) |
| `tools/` | Parsers and writers (`rombin.py`, `layout.py`, `bsp.py`, `text.py`, `roomfurn.py`, …), each runnable on its own |
| `tests/` | Python tool tests. Run each one with `python tests/test_xxx.py`. They need `rom/` and `rom_bin/` |
| `docs/formats/` | One page per format: `rom.bin`, locations, layouts, text, hotel room furniture, asset catalogue |
| `docs/ghidra.md` | Functions identified in arm9, with their addresses |
| `docs/journal.md` | Research log: each hypothesis, how it was tested, and the result |

Every page in the docs marks each claim as **confirmed** (by the code, by every file, or in the emulator) or
**assumed**.

## Credits

- [ndspy](https://github.com/RoadrunnerWMC/ndspy) for the DS file formats and decompression.
- [nitrogen](https://github.com/jorgecafe/nitrogen) for the BMD0 → glTF conversion used by `tools/nitro.py` (pinned, MIT).
- [ndstool](https://github.com/devkitPro/ndstool) for unpacking and rebuilding the ROM.

The Sims is a trademark of Electronic Arts. This project is not affiliated with EA or Nintendo.
