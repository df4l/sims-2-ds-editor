class_name Bps
extends RefCounted
## BPS patches (byuu's format, applied by Flips, beat, ROM Patcher JS…). IPS cannot address past 16 MiB, the ROM
## is bigger.
##
## Layout: "BPS1", vlq source size, vlq target size, vlq metadata size (0), actions, u32 source CRC32,
## u32 target CRC32, u32 patch CRC32 (of everything before it). Action = vlq ((length - 1) << 2 | mode):
##   0 SourceRead  copy `length` bytes of the source at the current output offset
##   1 TargetRead  `length` literal bytes follow
##   2 SourceCopy  vlq signed delta (|d| << 1 | sign) moves the source cursor, then copy `length` bytes from it
##   3 TargetCopy  same with the target cursor (not emitted by this encoder)

const MIN_RUN := 16   # shortest equal run worth a SourceRead between literals

static var last_error := ""


static func _vlq(out: PackedByteArray, v: int) -> void:
	while true:
		var x := v & 0x7F
		v >>= 7
		if v == 0:
			out.append(0x80 | x)
			return
		out.append(x)
		v -= 1


static func _u32(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xFF)
	out.append((v >> 8) & 0xFF)
	out.append((v >> 16) & 0xFF)
	out.append((v >> 24) & 0xFF)


## CRC-32 (IEEE, zlib's): read from the trailer of a gzip stream, the zlib code being native and fast
## (a GDScript loop over 64 MiB takes tens of seconds). Trailer = u32 CRC32, u32 size mod 2^32.
static func crc32(d: PackedByteArray) -> int:
	var gz := d.compress(FileAccess.COMPRESSION_GZIP)
	return gz.decode_u32(gz.size() - 8)


## Patch turning `src` into `tgt`. `hints`: [[target offset, source offset, size]] ranges known to be copies (the
## `last_map` of NdsRom.rebuild / RomBin.build); the rest is compared with the source at the same offset.
static func encode(src: PackedByteArray, tgt: PackedByteArray, hints := []) -> PackedByteArray:
	var hs := hints.duplicate()
	hs.sort_custom(func(a, b): return a[0] < b[0])
	var out := "BPS1".to_ascii_buffer()
	_vlq(out, src.size())
	_vlq(out, tgt.size())
	_vlq(out, 0)
	var st := {"src_rel": 0}
	var t := 0
	for h in hs:
		var hn: int = h[0]
		var ho: int = h[1]
		var hz: int = h[2]
		if hz <= 0 or hn < t:
			continue
		if hn > t:
			_same_offset(out, src, tgt, t, hn)
		if ho == hn:
			_action(out, 0, hz)
		else:
			_action(out, 2, hz)
			var d: int = ho - st.src_rel
			_vlq(out, (absi(d) << 1) | (1 if d < 0 else 0))
			st.src_rel = ho + hz
		t = hn + hz
	if t < tgt.size():
		_same_offset(out, src, tgt, t, tgt.size())
	_u32(out, crc32(src))
	_u32(out, crc32(tgt))
	_u32(out, crc32(out))
	return out


static func _action(out: PackedByteArray, mode: int, length: int) -> void:
	_vlq(out, ((length - 1) << 2) | mode)


static func _literal(out: PackedByteArray, tgt: PackedByteArray, a: int, b: int) -> void:
	if b > a:
		_action(out, 1, b - a)
		out.append_array(tgt.slice(a, b))


## Target range [a, b): SourceRead for runs equal to the source at the same offset, TargetRead for the rest.
static func _same_offset(out: PackedByteArray, src: PackedByteArray, tgt: PackedByteArray, a: int, b: int) -> void:
	var lim := mini(b, src.size())
	var lit := a
	var i := a
	while i < lim:
		if src[i] != tgt[i]:
			i += 1
			continue
		var j := i
		while j < lim and src[j] == tgt[j]:
			j += 1
		if j - i >= MIN_RUN:
			_literal(out, tgt, lit, i)
			_action(out, 0, j - i)
			lit = j
		i = j
	_literal(out, tgt, lit, b)


static func _rvlq(p: PackedByteArray, st: Dictionary) -> int:
	var v := 0
	var shift := 1
	while true:
		var x: int = p[st.i]
		st.i += 1
		v += (x & 0x7F) * shift
		if x & 0x80:
			return v
		shift <<= 7
		v += shift
	return v


## Apply a patch (checks every CRC). Empty array on error (see last_error).
static func apply(src: PackedByteArray, patch: PackedByteArray) -> PackedByteArray:
	last_error = ""
	if patch.size() < 16 or patch.slice(0, 4).get_string_from_ascii() != "BPS1":
		last_error = "not a BPS patch"
		return PackedByteArray()
	var end := patch.size() - 12
	if crc32(patch.slice(0, patch.size() - 4)) != patch.decode_u32(patch.size() - 4):
		last_error = "patch CRC mismatch"
		return PackedByteArray()
	var st := {"i": 4}
	var ssize := _rvlq(patch, st)
	var tsize := _rvlq(patch, st)
	st.i += _rvlq(patch, st)
	if ssize != src.size() or crc32(src) != patch.decode_u32(end):
		last_error = "this patch is for another source file"
		return PackedByteArray()
	var tgt := PackedByteArray()
	var srel := 0
	var trel := 0
	while st.i < end:
		var a := _rvlq(patch, st)
		var mode := a & 3
		var n := (a >> 2) + 1
		var o := tgt.size()
		match mode:
			0:
				tgt.append_array(src.slice(o, o + n))
			1:
				tgt.append_array(patch.slice(st.i, st.i + n))
				st.i += n
			2, 3:
				var d := _rvlq(patch, st)
				d = -(d >> 1) if d & 1 else d >> 1
				if mode == 2:
					srel += d
					tgt.append_array(src.slice(srel, srel + n))
					srel += n
				else:
					trel += d
					for k in n:   # may overlap the bytes being written
						tgt.append(tgt[trel + k])
					trel += n
	if tgt.size() != tsize or crc32(tgt) != patch.decode_u32(end + 4):
		last_error = "result CRC mismatch"
		return PackedByteArray()
	return tgt
