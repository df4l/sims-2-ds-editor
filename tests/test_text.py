"""Text banks (tools/text.py) and the dialogue tables used by layout scripts (tools/layscript.py)."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import text  # noqa: E402
import layscript  # noqa: E402


def test_banks_roundtrip():
    """Decode + re-encode every bank with its own tree: byte-identical, 3127 strings each."""
    for lang, e in text.BANKS.items():
        d = (text.RAW / f'{e:04d}.bin').read_bytes()
        b = text.Bank(d)
        assert len(b.strings) == 3127, lang
        assert b.write() == d, lang


def test_edit_string():
    b = text.Bank((text.RAW / '0123.bin').read_bytes())
    b.strings[0x49F] = b'Edited line, longer than the original one to shift every later offset.'
    again = text.Bank(b.write())
    assert again.strings[0x49F] == b.strings[0x49F] and again.strings[0x4A0] == b.strings[0x4A0]


def test_from_str():
    """from_str inverts to_str on every string of the 5 European banks; set_string rejects codes not in the tree."""
    for lang in ('en', 'fr', 'de', 'it', 'es'):
        assert all(text.from_str(text.to_str(s)) == s for s in text.bank(lang).strings), lang
    b = text.Bank((text.RAW / '0123.bin').read_bytes())
    text.set_string(b, 0x49F, 'Two lines\nwith é')
    assert text.Bank(b.write()).strings[0x49F] == text.from_str('Two lines\nwith é')
    try:
        text.set_string(b, 0x49F, '¿Qué?')
        assert False, '¿ (0x7E) is not in the English tree'
    except ValueError:
        pass


def test_rebuild_tree():
    """A rebuilt tree decodes every string of every bank identically; set_string(rebuild=True) adds missing codes."""
    for lang in text.BANKS:
        b = text.Bank((text.RAW / f'{text.BANKS[lang]:04d}.bin').read_bytes())
        old = list(b.strings)
        b.rebuild_tree()
        again = text.Bank(b.write())
        assert again.strings == old and len(again.nodes) == len(again.codes()), lang
        assert sum(n.count(0x100) for n in again.nodes) == 1, lang      # one back-pointer, like the originals
    b = text.Bank((text.RAW / '0123.bin').read_bytes())
    assert not text.set_string(b, 0x49F, 'Plain text', rebuild=True)    # tree kept when nothing is missing
    assert text.set_string(b, 0x49F, '¿Qué? œ…', rebuild=True)
    assert text.Bank(b.write()).strings[0x49F] == text.from_str('¿Qué? œ…')


def test_known_strings():
    assert text.text(0x143 + 22) == 'Jebediah S. Jerky'         # NPC 22, speaks in conversation 0
    assert text.text(0x49F).startswith('Whoa there, slick.')
    assert 'réservés' in text.text(0, 'fr')
    for lang in ('en', 'fr', 'de', 'it', 'es'):                   # European code page fully mapped
        assert not any('{' in text.to_str(s) for s in text.bank(lang).strings if b'{' not in s), lang


def test_conversations():
    """Every conversation line points to an existing string; every speaker is narrator, player or an NPC."""
    n = 0
    for c in range(layscript.N_CONV):
        for t, sp in layscript.conversation(c):
            assert t < 3127 and (sp < 0x3F or sp in layscript.SPEAKER)
            n += 1
    assert layscript.conversation(0)[0] == (0x49F, 22) and n == 501


if __name__ == '__main__':
    test_banks_roundtrip()
    test_edit_string()
    test_from_str()
    test_rebuild_tree()
    test_known_strings()
    test_conversations()
    print('OK')
