class_name TextBank
extends RefCounted
## Huffman-coded string table, one per language (docs/formats/text.md). Read-only here.
## u32 off_table | node[(off_table - 4) / 4] {u16 left, u16 right}, root = 0x100, child < 0x100 = leaf byte |
## u32 offset[N] at off_table | bitstreams, LSB first, 0 = left; a string ends at a 0 byte that is not the second
## byte of a 2-byte character (lead byte >= 0xF0).

const CHARMAP := {
	0x7B: "©", 0x7C: "œ", 0x7D: "¡", 0x7E: "¿", 0x7F: "À", 0x80: "Á", 0x81: "Â", 0x82: "Ã", 0x83: "Ä", 0x84: "Å",
	0x85: "Æ", 0x86: "Ç", 0x87: "È", 0x88: "É", 0x89: "Ê", 0x8A: "Ë", 0x8B: "Ì", 0x8C: "Í", 0x8D: "Î", 0x8E: "Ï",
	0x8F: "Ñ", 0x90: "Ò", 0x91: "Ó", 0x92: "Ô", 0x93: "Õ", 0x94: "Ö", 0x96: "Ù", 0x97: "Ú", 0x98: "Ü", 0x99: "ß",
	0x9A: "à", 0x9B: "á", 0x9C: "â", 0x9D: "ã", 0x9E: "ä", 0x9F: "å", 0xA0: "æ", 0xA1: "ç", 0xA2: "è", 0xA3: "é",
	0xA4: "ê", 0xA5: "ë", 0xA6: "ì", 0xA7: "í", 0xA8: "î", 0xA9: "ï", 0xAA: "ñ", 0xAB: "ò", 0xAC: "ó", 0xAD: "ô",
	0xAE: "õ", 0xAF: "ö", 0xB1: "ù", 0xB2: "ú", 0xB3: "û", 0xB4: "ü", 0xB5: "°", 0xB7: "…", 0xB8: "®", 0xB9: " ",
}

var data: PackedByteArray
var left := PackedInt32Array()
var right := PackedInt32Array()
var offsets := PackedInt64Array()
var _cache := {}


func _init(d: PackedByteArray) -> void:
	data = d
	if d.size() < 8:
		return
	var tab := d.decode_u32(0)
	var nn := (tab - 4) / 4
	left.resize(nn)
	right.resize(nn)
	for k in nn:
		left[k] = d.decode_u16(4 + 4 * k)
		right[k] = d.decode_u16(6 + 4 * k)
	var first := d.decode_u32(tab)
	var n := (first - tab) / 4
	offsets.resize(n)
	for i in n:
		offsets[i] = d.decode_u32(tab + 4 * i)


func count() -> int:
	return offsets.size()


func string_bytes(i: int) -> PackedByteArray:
	var out := PackedByteArray()
	if i < 0 or i >= offsets.size():
		return out
	var p: int = offsets[i]
	var d := data
	var sz := d.size()
	var cur := d[p] if p < sz else 0
	p += 1
	var bit := 0
	var wide := false
	while out.size() < 4096:
		var n := 0x100
		while n >= 0x100:
			var k := n - 0x100
			if k >= left.size():
				return out
			n = right[k] if (cur >> bit) & 1 else left[k]
			bit += 1
			if bit == 8:
				cur = d[p] if p < sz else 0
				p += 1
				bit = 0
		if n == 0 and not wide:
			return out
		out.append(n)
		wide = not wide and n >= 0xF0
	return out


## Readable form: European code page, 2-byte characters as {fxxx}.
func text(i: int) -> String:
	if _cache.has(i):
		return _cache[i]
	var s := string_bytes(i)
	var out := ""
	var k := 0
	while k < s.size():
		var c := s[k]
		if c >= 0xF0 and k + 1 < s.size():
			out += "{%02x%02x}" % [c, s[k + 1]]
			k += 2
			continue
		if (c >= 0x20 and c < 0x7B) or c == 0x0A:
			out += char(c)
		elif CHARMAP.has(c):
			out += CHARMAP[c]
		else:
			out += "{%02x}" % c
		k += 1
	_cache[i] = out
	return out
