class_name TextBank
extends RefCounted
## Huffman-coded string table, one per language (docs/formats/text.md). Port of tools/text.py (read + write).
## u32 off_table | node[(off_table - 4) / 4] {u16 left, u16 right}, root = 0x100, child < 0x100 = leaf byte |
## u32 offset[N] at off_table | bitstreams, LSB first, 0 = left; a string ends at a 0 byte that is not the second
## byte of a 2-byte character (lead byte >= 0xF0).
## Read only by Txt_DecodeString 0x0204505c, which has no limit on node count or depth. Txt_GetString 0x02052258
## decodes into a 0x400-byte buffer, so a string (terminator included) must fit in 0x400 bytes.

const MAX_BYTES := 0x400

const CHARMAP := {
	0x7B: "©", 0x7C: "œ", 0x7D: "¡", 0x7E: "¿", 0x7F: "À", 0x80: "Á", 0x81: "Â", 0x82: "Ã", 0x83: "Ä", 0x84: "Å",
	0x85: "Æ", 0x86: "Ç", 0x87: "È", 0x88: "É", 0x89: "Ê", 0x8A: "Ë", 0x8B: "Ì", 0x8C: "Í", 0x8D: "Î", 0x8E: "Ï",
	0x8F: "Ñ", 0x90: "Ò", 0x91: "Ó", 0x92: "Ô", 0x93: "Õ", 0x94: "Ö", 0x96: "Ù", 0x97: "Ú", 0x98: "Ü", 0x99: "ß",
	0x9A: "à", 0x9B: "á", 0x9C: "â", 0x9D: "ã", 0x9E: "ä", 0x9F: "å", 0xA0: "æ", 0xA1: "ç", 0xA2: "è", 0xA3: "é",
	0xA4: "ê", 0xA5: "ë", 0xA6: "ì", 0xA7: "í", 0xA8: "î", 0xA9: "ï", 0xAA: "ñ", 0xAB: "ò", 0xAC: "ó", 0xAD: "ô",
	0xAE: "õ", 0xAF: "ö", 0xB1: "ù", 0xB2: "ú", 0xB3: "û", 0xB4: "ü", 0xB5: "°", 0xB7: "…", 0xB8: "®",
	0xB9: char(0xA0),  # non-breaking space (ASSUMED), not a plain space: it must round-trip
}
static var _reverse := {}

var data: PackedByteArray
var left := PackedInt32Array()
var right := PackedInt32Array()
var offsets := PackedInt64Array()
var strings := []     # PackedByteArray per id, filled by all_strings() (the bytes before the terminator)
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
	if not strings.is_empty():
		return strings[i] if i >= 0 and i < strings.size() else PackedByteArray()
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


## Decode every string once (needed before set_string / write).
func all_strings() -> Array:
	if strings.is_empty() and count() > 0:
		var tmp := []
		for i in count():
			tmp.append(string_bytes(i))
		strings = tmp
	return strings


## Readable form: European code page, 2-byte characters as {fxxx}.
func text(i: int) -> String:
	if _cache.has(i):
		return _cache[i]
	var out := to_str(string_bytes(i))
	_cache[i] = out
	return out


static func to_str(s: PackedByteArray) -> String:
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
	return out


## Inverse of to_str: {"bytes": PackedByteArray, "error": ""}. {xx} / {xxxx} are raw codes.
static func from_str(t: String) -> Dictionary:
	if _reverse.is_empty():
		for k in CHARMAP:
			_reverse[CHARMAP[k]] = k
	var out := PackedByteArray()
	var i := 0
	while i < t.length():
		var c := t[i]
		if c == "{":
			var j := t.find("}", i)
			var hx := t.substr(i + 1, j - i - 1) if j > 0 else ""
			if j < 0 or hx.is_empty() or hx.length() % 2 or not hx.is_valid_hex_number():
				return {"bytes": out, "error": "bad escape at character %d: use {xx} or {xxxx} (hex)" % i}
			out.append_array(hx.hex_decode())
			i = j + 1
			continue
		var u := t.unicode_at(i)
		if c == "\n" or (u >= 0x20 and u < 0x7B):
			out.append(u)
		elif _reverse.has(c):
			out.append(_reverse[c])
		else:
			return {"bytes": out, "error": "character '%s' has no code in the game's code page" % c}
		i += 1
	if out.size() + 1 > MAX_BYTES:
		return {"bytes": out, "error": "string too long: %d bytes, the game's buffer holds %d (terminator included)" % [out.size(), MAX_BYTES - 1]}
	return {"bytes": out, "error": ""}


## symbol -> PackedByteArray of bits (0/1), from the tree. The child pointing back to the root (dead branch in
## every original bank) is skipped.
func codes() -> Dictionary:
	var res := {}
	var stack := [[0x100, PackedByteArray()]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: int = e[0]
		if n < 0x100:
			res[n] = e[1]
			continue
		var k := n - 0x100
		if k >= left.size():
			continue
		for b in 2:
			var c: int = right[k] if b else left[k]
			if c != 0x100:
				var p: PackedByteArray = e[1].duplicate()
				p.append(b)
				stack.append([c, p])
	return res


## Bytes used by the current strings (terminator included) that the tree cannot encode.
func missing_symbols() -> Array:
	var have := codes()
	var miss := {}
	for s in all_strings():
		for c in s:
			if not have.has(c):
				miss[c] = true
	if not have.has(0):
		miss[0] = true
	var out := miss.keys()
	out.sort()
	return out


## New Huffman tree from the byte frequencies of the current strings, same algorithm and tie-breaks as
## text.py rebuild_tree (Python heapq on (weight, order, symbol)): root = node 0, plus a weight-0 dummy leaf 0x100
## that reproduces the original "one child points back to the root" quirk.
func rebuild_tree() -> void:
	var freq := {}
	for s in all_strings():
		for c in s:
			freq[c] = freq.get(c, 0) + 1
		freq[0] = freq.get(0, 0) + 1
	var syms := freq.keys()
	syms.sort()
	var heap := []
	for k in syms.size():
		heap.append([freq[syms[k]], k, syms[k]])
	heap.append([0, -1, 0x100])
	var nodes := [[0, 0]]
	var tick := heap.size()
	while heap.size() > 1:
		var a: Array = _pop_min(heap)
		var b: Array = _pop_min(heap)
		if heap.is_empty():
			nodes[0] = [a[2], b[2]]
			break
		nodes.append([a[2], b[2]])
		heap.append([a[0] + b[0], tick, 0xFF + nodes.size()])
		tick += 1
	left.resize(nodes.size())
	right.resize(nodes.size())
	for k in nodes.size():
		left[k] = nodes[k][0]
		right[k] = nodes[k][1]


static func _pop_min(h: Array) -> Array:
	var best := 0
	for k in range(1, h.size()):
		if h[k][0] < h[best][0] or (h[k][0] == h[best][0] and h[k][1] < h[best][1]):
			best = k
	var e: Array = h[best]
	h.remove_at(best)
	return e


## Re-encode every string with the current tree. Empty if a byte has no code (call rebuild_tree first).
func write() -> PackedByteArray:
	var cd := codes()
	var strs := all_strings()
	var tab := 4 + 4 * left.size()
	var out := PackedByteArray()
	out.resize(tab + 4 * strs.size())
	out.encode_u32(0, tab)
	for k in left.size():
		out.encode_u16(4 + 4 * k, left[k])
		out.encode_u16(6 + 4 * k, right[k])
	for i in strs.size():
		out.encode_u32(tab + 4 * i, out.size())
		var acc := 0
		var nb := 0
		var s: PackedByteArray = strs[i]
		for j in s.size() + 1:
			var c: int = s[j] if j < s.size() else 0
			if not cd.has(c):
				return PackedByteArray()
			for b in cd[c]:
				acc |= b << nb
				nb += 1
				if nb == 8:
					out.append(acc)
					acc = 0
					nb = 0
		if nb:
			out.append(acc)
	while out.size() % 4:
		out.append(0)
	return out


## Replace string i (bytes). The tree is rebuilt only if it lacks a byte. Returns true if it was rebuilt.
func set_string(i: int, b: PackedByteArray) -> bool:
	all_strings()
	strings[i] = b
	_cache.erase(i)
	var have := codes()
	for c in b:
		if not have.has(c):
			rebuild_tree()
			return true
	return false
