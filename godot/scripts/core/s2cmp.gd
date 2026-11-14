class_name S2Cmp
extends RefCounted
## Decompression of rom.bin entries (dispatcher FUN_02042adc, docs/formats/rombin.md).
## Blob header u32: bits 0-7 type, bits 8-31 decompressed size.
##   type >> 4 & 7: 0 raw copy, 1 LZ77 (BIOS), 6 EA custom LZ (ITCM 0x01FF8000); 2/3 never seen.
##   type & 0x80: 16-bit delta filter after decompression.
## An entry is a chain of blobs, each followed by zero padding (4-byte alignment, plus zero words).


## {"type", "out", "end"} for the blob at d[pos], or {} if it is not a valid blob.
static func decompress_blob(d: PackedByteArray, pos: int) -> Dictionary:
	if d.size() - pos < 8:
		return {}
	var hdr := d.decode_u32(pos)
	var typ := hdr & 0xFF
	var size := hdr >> 8
	var method := (typ >> 4) & 7
	if typ & 0x0F:
		return {}
	var res: Array
	if method == 6:
		res = _type6(d, pos + 4, size)
	elif method == 1:
		res = _lz10(d, pos + 4, size)
	elif method == 0:
		# raw copy: used by the editor for edited files (the game supports it)
		if pos + 4 + size > d.size():
			return {}
		res = [d.slice(pos + 4, pos + 4 + size), pos + 4 + size]
	else:
		return {}
	if res.is_empty():
		return {}
	var out: PackedByteArray = res[0]
	if out.size() != size:
		return {}
	if typ & 0x80:
		var prev := 0
		for i in range(0, size - 1, 2):
			var v := (out.decode_u16(i) + prev) & 0xFFFF
			out.encode_u16(i, v)
			prev = v
	return {"type": typ, "out": out, "end": res[1]}


## [{type, start, end, out}] or [] when the entry is not entirely made of blobs (= raw data).
## A type 0 (raw copy) blob is only accepted as the single blob of an entry, exactly filling it.
static func split_blobs(entry: PackedByteArray) -> Array:
	var blobs := []
	var pos := 0
	var n := entry.size()
	while pos < n:
		if not blobs.is_empty() and pos + 4 <= n and entry.decode_u32(pos) == 0:
			pos += 4
			continue
		if pos + 4 <= n and entry[pos] == 0:
			if pos != 0:
				return []
			var size := entry.decode_u32(0) >> 8
			if (4 + size + 3) & ~3 != n:
				return []
		var b := decompress_blob(entry, pos)
		if b.is_empty():
			return []
		blobs.append({"type": b.type, "start": pos, "end": b.end, "out": b.out})
		pos = (b.end + 3) & ~3
	return blobs


## Entry holding `data` uncompressed (blob type 0x00 = raw copy), as the editor stores edited BSPs.
static func stored_blob(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, data.size() << 8)
	out.append_array(data)
	while out.size() % 4:
		out.append(0)
	return out


static func _lz10(d: PackedByteArray, pos: int, out_size: int) -> Array:
	var out := PackedByteArray()
	out.resize(out_size)
	var o := 0
	var n := d.size()
	while o < out_size:
		if pos >= n:
			return []
		var flags := d[pos]
		pos += 1
		for b in 8:
			if o >= out_size:
				break
			if flags & (0x80 >> b):
				if pos + 1 >= n:
					return []
				var x := (d[pos] << 8) | d[pos + 1]
				pos += 2
				var src := o - (x & 0xFFF) - 1
				if src < 0:
					return []
				for k in (x >> 12) + 3:
					if o >= out_size:
						return []
					out[o] = out[src + k]
					o += 1
			else:
				if pos >= n:
					return []
				out[o] = d[pos]
				pos += 1
				o += 1
	return [out, pos]


class _Bits:
	## MSB-first bit reader refilled with 32-bit LE words (the ITCM routine).
	var d: PackedByteArray
	var pos := 0
	var buf := 0
	var n := 0
	var bad := false

	func _init(data: PackedByteArray, p: int) -> void:
		d = data
		pos = p

	func bits(k: int) -> int:
		if k == 0:
			return 0
		if n >= k:
			n -= k
			return (buf >> n) & ((1 << k) - 1)
		var need := k - n
		var v := buf & ((1 << n) - 1)
		if pos + 4 > d.size():
			bad = true
			buf = 0
		else:
			buf = d.decode_u32(pos)
		pos += 4
		n = 32 - need
		return (v << need) | ((buf >> n) & ((1 << need) - 1))

	func gamma() -> int:
		# k ones then a zero -> 1 followed by k bits; 7 ones -> 1 followed by 7 bits (no terminator)
		var k := 0
		while k < 7 and bits(1) == 1:
			k += 1
		return (1 << k) | bits(k)


static func _type6(d: PackedByteArray, pos: int, out_size: int) -> Array:
	if pos + 4 > d.size():
		return []
	var w := d.decode_u32(pos)
	var table_len := w & 0xFF
	var escape := (w >> 8) & 0xFF
	var off_bits := (w >> 16) & 0xFF
	var esc_bits := w >> 24
	if table_len == 0 or table_len % 4 != 0 or esc_bits > 8:
		return []
	var table_at := pos + 4
	if table_at + table_len > d.size():
		return []
	var lit_bits := 8 - esc_bits
	var br := _Bits.new(d, pos + 4 + table_len)
	var out := PackedByteArray()
	out.resize(out_size)
	var o := 0
	while true:
		if br.bad:
			return []
		var code := br.bits(esc_bits)
		if code != escape:
			if o >= out_size:
				return []
			out[o] = ((code << lit_bits) | br.bits(lit_bits)) & 0xFF
			o += 1
			continue
		var g := br.gamma()
		var dist := 0
		var length := 0
		if g >= 2:   # long match
			var g2 := br.gamma()
			if g2 == 0xFF:
				break
			dist = ((((g2 - 1) << off_bits) | br.bits(off_bits)) << 8) | br.bits(8)
			length = g + 1
		elif br.bits(1) == 0:   # short match, length 2
			dist = br.bits(8)
			length = 2
		elif br.bits(1) == 0:   # literal whose high bits equal the escape; becomes the new escape
			var new_escape := br.bits(esc_bits)
			if o >= out_size:
				return []
			out[o] = ((escape << lit_bits) | br.bits(lit_bits)) & 0xFF
			o += 1
			escape = new_escape
			continue
		else:   # run
			var c := br.gamma()
			var hi := 0
			if c >= 0x80:
				c = ((c << 1) | br.bits(1)) & 0xFF
				hi = br.gamma() - 1
			var v := br.gamma()
			if v < 0x20:
				if v - 1 >= table_len:
					return []
				v = d[table_at + v - 1]
			else:
				v = ((v << 3) | br.bits(3)) & 0xFF
			var cnt := c + 1 + (hi << 8)
			if o + cnt > out_size:
				return []
			for _k in cnt:
				out[o] = v
				o += 1
			continue
		var src := o - dist - 1
		if src < 0 or o + length > out_size:
			return []
		for k in length:
			out[o] = out[src + k]
			o += 1
	if br.bad or o != out_size:
		return []
	return [out, br.pos]
