class_name Blz
extends RefCounted
## "Bottom LZ" code compression of DS ARM9 binaries (same algorithm as ndspy codeCompression.decompress).
## Footer (last 8 bytes): u32 bits 0-23 compressed length (from the end), bits 24-31 header length; u32 extra size.
## Decoding runs backwards: flag byte (MSB first), 1 = 2-byte match (len = hi nibble + 3, disp = 12 bits + 3),
## 0 = literal. Bytes before the compressed length are a plain prefix.

static var last_error := ""


static func decompress(d: PackedByteArray) -> PackedByteArray:
	var n := d.size()
	if n < 8:
		last_error = "too short"
		return PackedByteArray()
	var info := d.decode_u32(n - 8)
	var extra := d.decode_u32(n - 4)
	var hdr := info >> 24
	var clen := info & 0xFFFFFF
	if extra == 0 or hdr < 8 or clen > n or hdr > clen:
		last_error = "no BLZ footer"
		return PackedByteArray()
	var out := d.duplicate()
	out.resize(n + extra)
	var src := n - hdr          # next byte to read is src - 1
	var dst := n + extra        # next byte to write is dst - 1
	var limit := n - clen
	while src > limit and dst > limit:
		src -= 1
		var flags := out[src]
		for _b in 8:
			if src <= limit:
				break
			if flags & 0x80:
				if src - 2 < limit:
					last_error = "truncated match"
					return PackedByteArray()
				var b1 := out[src - 1]
				var b2 := out[src - 2]
				src -= 2
				var ln := (b1 >> 4) + 3
				var disp := (((b1 & 0x0F) << 8) | b2) + 3
				if dst + disp - 1 >= n + extra:
					last_error = "match out of range"
					return PackedByteArray()
				for _k in ln:
					dst -= 1
					out[dst] = out[dst + disp]
			else:
				src -= 1
				dst -= 1
				out[dst] = out[src]
			flags = (flags << 1) & 0xFF
			if dst <= limit:
				break
	return out
