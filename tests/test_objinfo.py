"""Object info table (tools/objinfo.py): names, icons."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools'))
import objinfo  # noqa: E402
import text  # noqa: E402


def test_npc_records_match_npc_names():
    # NPC names are text 0x143 + id (docs/formats/text.md); Info_Npc gives the same text id for the 56 NPCs it covers
    for n in range(objinfo.N_NPC_INFO):
        assert objinfo.npc(n)['text'] == 0x143 + n
    assert objinfo.npc(objinfo.N_NPC_INFO) is None


def test_prop_names():
    # the 6 default hotel room props (docs/formats/roomfurn.md) and a few couch variants
    names = {86: 'White Fridge', 114: 'Black Mahogany Bed', 133: 'Black Couch', 185: 'White Shower',
             209: 'Off-White Toilet', 233: 'Porcelain Sink', 128: 'Camel Couch'}
    for p, name in names.items():
        assert text.text(objinfo.prop(p)['text']) == name


def test_every_icon_decodes():
    bad = [(k, i) for k, i, r in objinfo.all_records() if r['icon'] and objinfo.render_icon(r) is None]
    assert bad == [('prop', 253)]     # Cellphone: its icon entry 1951 is not a plain sprite (unknown format)


if __name__ == '__main__':
    test_npc_records_match_npc_names()
    test_prop_names()
    test_every_icon_decodes()
    print('OK')
