class_name NdsRom
extends RefCounted
## Nintendo DS cartridge image (.nds): header, NitroFS (FNT + FAT), ARM9 binary, and a rebuild that
## replaces files / the ARM9 and relays the image out like ndstool -c (regions in their original order).
##
## Header fields used (GBATEK "DS Cartridge Header"):
##   0x0C game code, 0x14 device capacity, 0x20/0x24/0x28/0x2C ARM9 rom offset / entry / ram / size,
##   0x30.. ARM7 (same), 0x40/0x44 FNT, 0x48/0x4C FAT, 0x50/0x54 ARM9 overlay table, 0x58/0x5C ARM7 overlay table,
##   0x68 banner offset, 0x80 used ROM size, 0x15E header CRC16 (over 0x000..0x15D).
## The secure area CRC (0x6C) is left as it is, like ndstool does.

const NITROCODE := 0xDEC00621      # first word of the ARM9 module params "nitrocode" pair
const NITROCODE2 := 0x2106C0DE

var data := PackedByteArray()
var path := ""
var error := ""

var game_code := ""
var title := ""


func load_file(p: String) -> bool:
	path = p
	data = FileAccess.get_file_as_bytes(p)
	if data.is_empty():
		error = "cannot read %s" % p
		return false
	return parse()


func parse() -> bool:
	if data.size() < 0x200:
		error = "file too small to be a DS ROM"
		return false
	title = data.slice(0, 12).get_string_from_ascii()
	game_code = data.slice(0x0C, 0x10).get_string_from_ascii()
	var fat_off := u32(0x48)
	var fat_size := u32(0x4C)
	if fat_off + fat_size > data.size() or u32(0x40) + u32(0x44) > data.size():
		error = "bad FNT/FAT offsets: not a DS ROM"
		return false
	if u32(0x20) + u32(0x2C) > data.size():
		error = "bad ARM9 offset: not a DS ROM"
		return false
	return true


func u32(o: int) -> int:
	return data.decode_u32(o)


func file_count() -> int:
	return u32(0x4C) / 8


func file_range(id: int) -> Vector2i:
	var o := u32(0x48) + 8 * id
	return Vector2i(data.decode_u32(o), data.decode_u32(o + 4))


func read_file(id: int) -> PackedByteArray:
	var r := file_range(id)
	return data.slice(r.x, r.y)


## File id of a NitroFS path such as "rom.bin" or "data/foo.bin" (-1 if absent).
func find_file(p: String) -> int:
	var parts := p.trim_prefix("/").split("/")
	var fnt := u32(0x40)
	var dir_id := 0xF000
	for k in parts.size():
		var want: String = parts[k]
		var last := k == parts.size() - 1
		var e := fnt + 8 * (dir_id & 0xFFF)
		var sub := fnt + data.decode_u32(e)
		var fid := data.decode_u16(e + 4)
		var found := false
		while true:
			var ln := data[sub]
			sub += 1
			if ln == 0:
				break
			var is_dir := ln >= 0x80
			var n := ln & 0x7F
			var name := data.slice(sub, sub + n).get_string_from_ascii()
			sub += n
			if is_dir:
				var did := data.decode_u16(sub)
				sub += 2
				if not last and name == want:
					dir_id = did
					found = true
					break
			else:
				if last and name == want:
					return fid
				fid += 1
		if not found:
			return -1
	return -1


# --- ARM9 ----------------------------------------------------------------------------------------------------

func arm9_ram() -> int:
	return u32(0x28)


## ARM9 binary as stored in the ROM (possibly BLZ-compressed), without the 12-byte footer.
func arm9_stored() -> PackedByteArray:
	return data.slice(u32(0x20), u32(0x20) + u32(0x2C))


## Offset of the module params in an ARM9 binary (-1 if not found). The params end with the nitrocode pair:
## +0x14 compressed_static_end, +0x1C nitrocode.
static func module_params(a9: PackedByteArray) -> int:
	# the footer after the ARM9 in the ROM gives it directly; otherwise search the first 0x4000 bytes
	var lim := mini(a9.size() - 8, 0x8000)
	var o := 0
	while o < lim:
		if a9.decode_u32(o) == NITROCODE and a9.decode_u32(o + 4) == NITROCODE2 and o >= 0x1C:
			return o - 0x1C
		o += 4
	return -1


## Decompressed ARM9 (the tools address it at 0x02000000 + offset). Empty on error (see `error`).
func arm9_decompressed() -> PackedByteArray:
	var a9 := arm9_stored()
	var mp := module_params(a9)
	if mp < 0:
		error = "ARM9 module params not found"
		return PackedByteArray()
	var end := a9.decode_u32(mp + 0x14)
	if end == 0:
		return a9
	var clen := end - arm9_ram()
	if clen <= 0 or clen > a9.size():
		error = "ARM9 compressed_static_end out of range"
		return PackedByteArray()
	var dec := Blz.decompress(a9.slice(0, clen))
	if dec.is_empty():
		error = "ARM9 BLZ decompression failed: " + Blz.last_error
		return PackedByteArray()
	dec.encode_u32(mp + 0x14, 0)   # now uncompressed
	return dec


# --- rebuild ---------------------------------------------------------------------------------------------------

## New ROM image. files: {file id: PackedByteArray} replaced NitroFS files. arm9: replacement ARM9 binary
## (uncompressed, compressed_static_end already 0) or an empty array to keep the stored one.
## Every region (ARM9, ARM7, overlay tables, FNT, FAT, banner, files) keeps its original order; a region that grows
## pushes the following ones (gaps are kept, shifts are multiples of 0x200). Unchanged input -> identical output.
## Sets `last_map`: [[new offset, old offset, size]] of the ranges copied unchanged from this image (patch export).
var last_map := []


func rebuild(files: Dictionary, arm9 := PackedByteArray()) -> PackedByteArray:
	var regions := []   # {kind, id, start, size, bytes (new content or null)}
	var a9_off := u32(0x20)
	var a9_size := u32(0x2C)
	var footer := 0
	if a9_off + a9_size + 12 <= data.size() and data.decode_u32(a9_off + a9_size) == NITROCODE:
		footer = 12
	var a9_new = null
	if not arm9.is_empty():
		var b := arm9.duplicate()
		if footer:
			b.append_array(data.slice(a9_off + a9_size, a9_off + a9_size + footer))
		a9_new = b
	regions.append({"kind": "arm9", "start": a9_off, "size": a9_size + footer, "bytes": a9_new})
	for k in [["arm7", 0x30, 0x3C], ["ovt9", 0x50, 0x54], ["ovt7", 0x58, 0x5C], ["fnt", 0x40, 0x44], ["fat", 0x48, 0x4C]]:
		if u32(k[2]) > 0:
			regions.append({"kind": k[0], "start": u32(k[1]), "size": u32(k[2]), "bytes": null})
	if u32(0x68) != 0:
		var ver := data.decode_u16(u32(0x68))
		var bsize: int = {1: 0x840, 2: 0x940, 3: 0xA40, 0x103: 0x23C0}.get(ver, 0x840)
		regions.append({"kind": "banner", "start": u32(0x68), "size": bsize, "bytes": null})
	for id in file_count():
		var r := file_range(id)
		if r.y > r.x:
			regions.append({"kind": "file", "id": id, "start": r.x, "size": r.y - r.x, "bytes": files.get(id)})
	regions.sort_custom(func(a, b): return a.start < b.start)

	# layout pass
	var shift := 0
	var cursor := 0x200
	var pos := {}   # region index -> new start
	for i in regions.size():
		var r: Dictionary = regions[i]
		var new_start: int = r.start + shift
		if new_start < cursor:
			var bump := (cursor - new_start + 0x1FF) & ~0x1FF
			shift += bump
			new_start += bump
		pos[i] = new_start
		var n: int = r.size if r.bytes == null else r.bytes.size()
		cursor = new_start + n
	var used_end := cursor

	# new FAT content
	var fat_i := -1
	for i in regions.size():
		if regions[i].kind == "fat":
			fat_i = i
	var fat := data.slice(u32(0x48), u32(0x48) + u32(0x4C))
	for i in regions.size():
		var r: Dictionary = regions[i]
		if r.kind == "file":
			var n: int = r.size if r.bytes == null else r.bytes.size()
			fat.encode_u32(8 * r.id, pos[i])
			fat.encode_u32(8 * r.id + 4, pos[i] + n)
	# zero-size files point at the end of the previous region (like ndstool): keep their old values unless they
	# would point past the new image
	if fat_i >= 0:
		regions[fat_i].bytes = fat

	var out := PackedByteArray()
	last_map = []
	out.append_array(data.slice(0, regions[0].start))
	for i in regions.size():
		var r: Dictionary = regions[i]
		var target: int = pos[i]
		if out.size() < target:
			# gap: original bytes between the previous region and this one when unchanged in size, else 0xFF
			var gap := target - out.size()
			var prev_end: int = 0
			if i > 0:
				prev_end = regions[i - 1].start + regions[i - 1].size
			var ogap: int = r.start - prev_end
			if i > 0 and ogap == gap and regions[i - 1].bytes == null:
				last_map.append([out.size(), prev_end, gap])
				out.append_array(data.slice(prev_end, r.start))
			else:
				var pad := PackedByteArray()
				pad.resize(gap)
				pad.fill(0xFF)
				out.append_array(pad)
		if r.bytes == null:
			last_map.append([out.size(), r.start, r.size])
			out.append_array(data.slice(r.start, r.start + r.size))
		else:
			out.append_array(r.bytes)

	# header
	for i in regions.size():
		var r: Dictionary = regions[i]
		var n: int = r.size if r.bytes == null else r.bytes.size()
		match r.kind:
			"arm9":
				out.encode_u32(0x20, pos[i])
				out.encode_u32(0x2C, n - footer)
			"arm7":
				out.encode_u32(0x30, pos[i])
			"ovt9":
				out.encode_u32(0x50, pos[i])
			"ovt7":
				out.encode_u32(0x58, pos[i])
			"fnt":
				out.encode_u32(0x40, pos[i])
			"fat":
				out.encode_u32(0x48, pos[i])
			"banner":
				out.encode_u32(0x68, pos[i])
	out.encode_u32(0x80, used_end)
	var cap := 0
	while (0x20000 << cap) < used_end:
		cap += 1
	if used_end > u32(0x80) and out[0x14] < cap:
		out[0x14] = cap
	# RSA signature block after the used area (dumps of retail ROMs), kept if present
	var old_end := u32(0x80)
	if old_end + 0x88 <= data.size() and data[old_end] == 0x61 and data[old_end + 1] == 0x63:
		out.append_array(data.slice(old_end, old_end + 0x88))
	out.encode_u16(0x15E, crc16(out, 0, 0x15E))
	return out


static func crc16(d: PackedByteArray, start: int, end: int) -> int:
	var c := 0xFFFF
	for i in range(start, end):
		c ^= d[i]
		for _k in 8:
			if c & 1:
				c = (c >> 1) ^ 0xA001
			else:
				c >>= 1
	return c
