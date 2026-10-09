"""Minimal readers for Nitro (NNS G3D) files: model names of a BMD0.

  python tools/nitro.py            # check every nitro_model entry of the catalogue, print a few names

BMD0 = standard Nitro file header ('BMD0', BOM, version, u32 size, u16 header size, u16 block count,
u32 block offsets) with an MDL0 block (+ optional TEX0). Names are stored in a Nitro dictionary:
  u8 0, u8 count, u16 size | u16 ?, u16 8, u32 ? | patricia tree (count + 1) * 4 bytes |
  u16 entry_size, u16 names_offset (from here) | entries | names: count * 16 bytes, NUL-padded
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def dict_names(d: bytes, o: int) -> list:
    count = d[o + 1]
    p = o + 8 + (count + 1) * 4
    _, names_off = struct.unpack_from('<HH', d, p)
    return [d[p + names_off + 16 * i:p + names_off + 16 * (i + 1)].split(b'\0')[0].decode('latin1')
            for i in range(count)]


def bmd0_model_names(d: bytes) -> list:
    """Names of the models in the MDL0 block of a (decompressed) BMD0."""
    if d[:4] != b'BMD0':
        raise ValueError('not a BMD0')
    for i in range(struct.unpack_from('<H', d, 14)[0]):
        bo = struct.unpack_from('<I', d, 16 + 4 * i)[0]
        if d[bo:bo + 4] == b'MDL0':
            return dict_names(d, bo + 8)
    raise ValueError('no MDL0 block')


_cache = {}


def model_name(entry: int) -> str:
    """First MDL0 model name of rom.bin entry `entry` ('' if it cannot be read)."""
    if entry not in _cache:
        p = ROOT / 'rom_bin' / 'dec' / f'{entry:04d}.bin'
        if not p.exists():
            p = ROOT / 'rom_bin' / 'raw' / f'{entry:04d}.bin'
        try:
            _cache[entry] = bmd0_model_names(p.read_bytes())[0]
        except (ValueError, IndexError, struct.error, UnicodeDecodeError):
            _cache[entry] = ''
    return _cache[entry]


# --- BMD0 -> GLB (editor 3D view) -------------------------------------------------------------
# nitrogen (pinned in requirements.txt) does the geometry and texture decoding. Its UVs are
# fixed here instead:
#  - nitrogen writes v = 1 - t/h, but glTF puts v = 0 on the first PNG row (= DS t = 0): flipped;
#  - it applies the material SRT as raw texel offsets around (0, 0). NNS models made with Maya
#    (texMtxMode 0, model header +0x16: all 175 editor models) pivot in UV space instead, see
#    _maya_uv (same maths as noclip.website nns_g3d calcTexMtx_Maya);
#  - it takes the wrap mode from the TEX0 entry, but the repeat/flip bits (16-19) are in the
#    material's teximage_param (+0x14): every texture came out clamped.
# Material record: +0x1E u16 flags (bit 0 SRT used, bit 1 scale = 1, bit 2 no rotation,
# bit 3 no translation), +0x20/+0x22 u16 original width/height, +0x2C optional SRT:
# fx32 scale S, T | s16 sin, cos (fx 4.12) | fx32 translation S, T.

def _fx(v: int) -> float:
    return v / 4096


def _read_srt(buf: bytes, at: int):
    """(scaleS, scaleT, sin, cos, transS, transT) of the material at `at` (identity if unused)."""
    flags = struct.unpack_from('<H', buf, at + 0x1E)[0]
    srt = [1.0, 1.0, 0.0, 1.0, 0.0, 0.0]
    if flags & 1:
        p = at + 0x2C
        if not flags & 2:
            srt[0:2] = [_fx(v) for v in struct.unpack_from('<ii', buf, p)]
            p += 8
        if not flags & 4:
            srt[2:4] = [_fx(v) for v in struct.unpack_from('<hh', buf, p)]
            p += 4
        if not flags & 8:
            srt[4:6] = [_fx(v) for v in struct.unpack_from('<ii', buf, p)]
    return tuple(srt)


def _maya_uv(srt, w: int, h: int):
    """Affine map texel (s, t) -> UV (0, 0 = top-left) of the NNS Maya texture matrix:
    returns (a, b, c, d, e, f) with u = a s + b t + e, v = c s + d t + f."""
    ss, st, sn, cs, ts, tt = srt
    return (ss * cs / w, ss * sn / h, -st * sn / w, st * cs / h,
            ss * (-0.5 * cs - (0.5 * sn - 0.5) - ts),
            st * (-0.5 * cs + (0.5 * sn - 0.5) + tt) + 1.0)


def _wrap(param: int, axis: int) -> str:
    if not param >> (16 + axis) & 1:
        return 'clamp'
    return 'mirror' if param >> (18 + axis) & 1 else 'repeat'


def _swap_texture(cont, tex: bytes) -> bool:
    """Put a prop variant texture (roomfurn.prop_texture: 512-byte palette + 8bpp texels) on the model's 256-colour
    texture of the same size, like Gfx_ReplaceModelTexture 0x020bbee0 does in game. False (model unchanged) if there is none:
    PlasmaTV (prop 104) loads a 32x64 screen strip, not a variant."""
    for t in cont.textures:
        if t.params.format == 4 and len(tex) == 512 + t.params.width * t.params.height:
            t.data1 = tex[512:]
            pals = {m.palette_name for mdl in cont.models for m in mdl.materials if m.texture_name == t.name}
            for p in cont.palettes:
                if p.name in pals:
                    p.pal_block, p.off = tex[:512], 0
            return True
    return False


def bmd0_to_glb(d: bytes, tex: bytes = None) -> bytes | None:
    """First model of a BMD0 (with its own TEX0) as an unlit, nearest-filtered GLB, bind pose.
    tex: optional variant texture swapped in first (see _swap_texture)."""
    import dataclasses
    from nitrogen.core.export.gltf import scene_to_glb
    from nitrogen.platforms.nds.formats import container, model as nmodel
    from nitrogen.platforms.nds.scene import build_scene

    srts = {}
    read = nmodel._read_material

    def read_material(buf, at, raw_name):
        mat = read(buf, at, raw_name)
        srts[id(mat)] = _read_srt(buf, at)
        return mat

    nmodel._read_material = read_material
    try:
        cont = container.read_container(d)
    finally:
        nmodel._read_material = read
    if not cont.models:
        return None
    if tex is not None:
        _swap_texture(cont, tex)
    mdl = cont.models[0]
    textures = {t.name: t for t in cont.textures}
    palettes = {p.name: p for p in cont.palettes}
    wraps = []
    for mat in mdl.materials:
        tex = textures.get(mat.texture_name) if mat.texture_name else None
        if tex is None:
            wraps.append(None)
            continue
        tw, th = tex.params.width, tex.params.height
        ow, oh = mat.width or tw, mat.height or th
        a, b, c, dd, e, f = _maya_uv(srts[id(mat)], ow, oh)
        ku, kv = ow / tw, oh / th            # UV of the original image -> UV of the stored texture
        cw, ch = mat.width or 1, mat.height or 1   # nitrogen divides by these, then does v = 1 - v
        mat.texture_mat = [[a * ku * cw, b * ku * cw, 0.0, e * ku * cw],
                           [-c * kv * ch, -dd * kv * ch, 0.0, (1.0 - f * kv) * ch],
                           [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]]
        param = mat.params.value | tex.params.value
        wraps.append((_wrap(param, 0), _wrap(param, 1)))
    scene = build_scene(mdl, textures, palettes, include_rig=True)
    copies = {}
    for smat, wrap in zip(scene.materials, wraps):   # one scene material per Nitro material, in order
        if smat.texture is None or wrap is None:
            continue
        key = (smat.texture, wrap)
        if key not in copies:
            copies[key] = len(scene.textures)
            scene.textures.append(dataclasses.replace(scene.textures[smat.texture],
                                                      wrap_s=wrap[0], wrap_t=wrap[1]))
        smat.texture = copies[key]
    return scene_to_glb(scene, unlit=True, nearest=True)


def main():
    import csv
    rows = [r for r in csv.DictReader(open(ROOT / 'rom_bin' / 'catalog.csv')) if r['kind'] == 'nitro_model']
    bad = [r['index'] for r in rows if not model_name(int(r['index']))]
    print(f'{len(rows) - len(bad)}/{len(rows)} nitro_model entries have a readable MDL0 name')
    if bad:
        print('unreadable:', ' '.join(bad))
    for r in rows[:10]:
        print(f'  {r["index"]}: {model_name(int(r["index"]))}')
    return not bad


if __name__ == '__main__':
    sys.exit(0 if main() else 1)
