"""Room furniture placement data (tools/roomfurn.py) against the game."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import roomfurn  # noqa: E402

# (room slot, prop, x, z, rot, game X, Y, Z fx32) measured in RAM on 2026-10-07: arm9 default table patched in RAM
# (0x0211FA70), warp into each room, actor +0x78/+0x7C/+0x80. 36 props none of which is a default prop: floor
# props in the 4 rotations, wall props, node files of kinds 0/3/4/5, multi-frame node files, several anim lists.
SEEN = [
    (0, 57, 108, 56, 0, 315433, 0, -282738), (0, 60, 108, 56, 1, 327680, 0, -303278), (0, 103, 108, 56, 2, 324412, 0, -296471),
    (0, 104, 108, 56, 3, 315682, 0, -282879), (0, 105, 108, 56, 0, 319792, 0, -286851), (0, 116, 108, 56, 1, 346112, 0, -271243),
    (1, 136, 40, 15, 1, 130321, 0, 17008), (1, 9, 1, 2, 0, -188034, 0, 137216), (1, 62, 2, 2, 0, -45157, 0, -122836),
    (1, 89, 3, 2, 0, -180414, 0, 51495), (1, 94, 4, 2, 0, 137216, 0, -111943), (1, 197, 5, 2, 0, -184320, 0, -51200),
    (2, 221, 0, 2, 0, -230576, -12288, 227315), (2, 239, 1, 2, 0, -47088, 0, -211082), (2, 144, 26, 27, 0, -36288, 0, 2509),
    (2, 149, 26, 27, 1, -26527, 0, -4595), (2, 150, 26, 27, 2, -29979, 0, -6121), (2, 155, 26, 27, 3, -36229, 0, 991),
    (3, 164, 74, 31, 3, 290490, 12288, 106496), (3, 179, 74, 31, 0, 310970, 12288, 122981), (3, 180, 74, 31, 1, 320374, 12288, 123634),
    (3, 181, 74, 31, 2, 292600, 12288, 110592), (3, 36, 74, 31, 3, 284970, 12288, 105892), (3, 59, 74, 31, 0, 282339, 12288, 98345),
    (4, 92, 31, 32, 0, -163124, 0, -24136), (4, 177, 31, 32, 1, -162254, 0, -14798), (4, 183, 31, 32, 2, -177936, 0, -21132),
    (4, 160, 3, 2, 0, -423936, 0, -265833), (4, 63, 4, 2, 0, -421847, 0, 202752), (4, 197, 5, 2, 0, 382976, 0, -266243),
    (5, 106, 52, 51, 1, 112792, 0, 48970), (5, 126, 52, 51, 2, 114688, 0, 54820), (5, 99, 52, 51, 3, 107664, 0, 41630),
    (5, 93, 52, 51, 0, 96186, 0, 35024), (5, 178, 52, 51, 1, 96410, 0, 38372), (5, 184, 52, 51, 2, 93232, 0, 28474),
]


def test_every_furniture_prop_has_placement():
    props = [p for p in range(roomfurn.N_PROPS) if roomfurn.is_furniture(p)]
    assert len(props) == 182
    for p in props:
        assert roomfurn.placement(p) is not None, p
    assert roomfurn.placement(0) is None and roomfurn.placement(300) is None


def test_measured_defaults():
    exp = {86: (1, 0, 0), 114: (0, 0, 9650), 133: (0, 0, 8368), 185: (1, 0, 14638), 209: (1, 0, 8464), 233: (1, 0, 8879)}
    for p, (w, ox, oz) in exp.items():
        assert roomfurn.placement(p) == (w, ox / 4096, oz / 4096), p


def test_placement_matches_game():
    grids = [roomfurn.load_grid(e) for e in roomfurn.grid_entries()]
    for s, p, x, z, r, gx, gy, gz in SEEN:
        c = roomfurn.place(grids[s], p, x, z, r)
        assert c[4], p
        assert all(abs(a - b / 4096) < 1e-3 for a, b in zip(c[:3], (gx, gy, gz))), (p, c, (gx, gy, gz))


def test_prop_variant_textures():
    """Colour variants: the jump-table case swaps the model texture (roomfurn.prop_texture). Every model shipped with
    a blank (all-zero) texture gets one, except the arcade machines; every swap fits the model (nitro._swap_texture)."""
    import struct
    import nitro
    from nitrogen.platforms.nds.formats import container
    raw = lambda e: (roomfurn.ROOT / 'rom_bin' / ('dec' if (roomfurn.ROOT / 'rom_bin' / 'dec' / f'{e:04d}.bin').exists()
                                                  else 'raw') / f'{e:04d}.bin').read_bytes()
    tex = {p: roomfurn.prop_texture(p) for p in range(roomfurn.N_PROPS)}
    tex = {p: t for p, t in tex.items() if t is not None}
    assert len(tex) == 123
    assert tex[209] == 7882 and tex[212] == 7897 and tex[150] == 2838   # clean / dirty toilet, Danish dresser
    blank, unfit = [], []
    for p in range(roomfurn.N_PROPS):
        cont = container.read_container(raw(struct.unpack_from('<H', roomfurn.arm9(), roomfurn.PROP_MODELS + 8 * p + 4
                                                                - roomfurn.ARM9_BASE)[0]))
        if any(not any(t.data1) for t in cont.textures) and p not in tex:
            blank.append(p)
        if p in tex and not nitro._swap_texture(cont, raw(tex[p])):
            unfit.append(p)
    assert blank == list(range(164, 177))   # arcade screens: drawn by other code
    assert unfit == [104]                   # PlasmaTV: 32x64 screen strip, not a colour variant


if __name__ == '__main__':
    test_every_furniture_prop_has_placement()
    test_measured_defaults()
    test_placement_matches_game()
    test_prop_variant_textures()
    print('OK')
