class_name Arm9Mod
extends RefCounted
## Changes to the decompressed ARM9: byte patches in the static code/data, and an extension area for NEW data or code
## that does not fit in place (grown tables, new records, hooks).
##
## Extension area (docs/formats/arm9.md): the boot loader copies the whole ARM9 binary to 0x02000000, and nothing
## touches RAM past the overlay area before OS_InitArena. So the binary is padded with zeros up to EXT_BASE (the
## original start of the main arena, right after the largest overlay) and the extension is appended there; the main
## arena start returned by OS_GetInitArenaLo (literal ARENA_LO_LITERAL) is raised past it, so the heap never covers it.
## A ROM exported with an extension reopens with it (the binary is longer than EXT_BASE - BASE).

const BASE := 0x02000000
const EXT_BASE := 0x02152F00          # OS_GetInitArenaLo(OS_ARENA_MAIN) in the original ASJP ARM9
const ARENA_LO_LITERAL := 0x020FB024  # literal pool word of OS_GetInitArenaLo (0x020FAF54) holding the main arena start
const EXT_MAX := 0x80000              # cap on the extension (heap room left to the game; see docs/formats/arm9.md)
const ARM7_RAM := 0x02380000          # ARM7 load address: the ARM9 image must end before it

var img := PackedByteArray()   # static image (without extension), patched in place
var ext := PackedByteArray()
var error := ""


func _init(a9: PackedByteArray) -> void:
	var lim := EXT_BASE - BASE
	if a9.size() > lim:
		img = a9.slice(0, lim)
		ext = a9.slice(lim)
	else:
		img = a9.duplicate()
	var lit := img.decode_u32(ARENA_LO_LITERAL - BASE)
	var want := EXT_BASE + _align(ext.size(), 32)
	if lit != want:
		error = "unexpected main arena start 0x%08X at 0x%08X (want 0x%08X): unsupported ARM9" % [lit, ARENA_LO_LITERAL, want]


static func _align(n: int, a: int) -> int:
	return (n + a - 1) & ~(a - 1)


func static_end() -> int:
	return BASE + img.size()


func ext_end() -> int:
	return EXT_BASE + ext.size()


## Where `addr` lives in our buffers: [buffer, offset] or [] when outside the static image and the extension.
func _locate(addr: int, n: int) -> Array:
	if addr >= BASE and addr + n <= static_end():
		return [img, addr - BASE]
	if addr >= EXT_BASE and addr + n <= ext_end():
		return [ext, addr - EXT_BASE]
	return []


func read(addr: int, n: int) -> PackedByteArray:
	var l := _locate(addr, n)
	if l.is_empty():
		return PackedByteArray()
	var b: PackedByteArray = l[0]
	return b.slice(l[1], l[1] + n)


func read_u32(addr: int) -> int:
	return read(addr, 4).decode_u32(0)


## Overwrite bytes at a RAM address of the static image or of the extension. "" or the reason.
func write(addr: int, data: PackedByteArray) -> String:
	if addr >= BASE and addr + data.size() <= static_end():
		for i in data.size():
			img[addr - BASE + i] = data[i]
		return ""
	if addr >= EXT_BASE and addr + data.size() <= ext_end():
		for i in data.size():
			ext[addr - EXT_BASE + i] = data[i]
		return ""
	return "0x%08X..0x%08X is outside the ARM9 static image and the extension" % [addr, addr + data.size()]


func write_u32(addr: int, v: int) -> String:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return write(addr, b)


## Reserve `size` zeroed bytes in the extension; returns their RAM address, or 0 when full (see `error`).
func alloc(size: int, align := 4) -> int:
	var start := _align(ext.size(), align)
	if start + size > EXT_MAX or EXT_BASE + start + size > ARM7_RAM:
		error = "ARM9 extension full: %d + %d bytes > %d" % [start, size, EXT_MAX]
		return 0
	ext.resize(start + size)   # new bytes are zero
	return EXT_BASE + start


## Append data to the extension; returns its RAM address (0 when full).
func add(data: PackedByteArray, align := 4) -> int:
	var a := alloc(data.size(), align)
	if a:
		write(a, data)
	return a


## Aligned 32-bit words of the static image whose value is in [lo, hi): [{at, value}]. These are the candidate
## pointers (literal pools, data tables) to a table living at lo..hi. ARM and Thumb code load addresses from
## word-aligned literal pools, so a table base is found this way; an address built by arithmetic is not.
func pointers_into(lo: int, hi: int) -> Array:
	var out := []
	var o := 0
	var n := img.size() - 3
	while o < n:
		var v := img.decode_u32(o)
		if v >= lo and v < hi:
			out.append({"at": BASE + o, "value": v})
		o += 4
	return out


## Move a table to the extension: copy `new_data` (the table, possibly grown) there and rewrite every static word
## equal to old_addr + k for k in `rewrite_offsets` (default: the table base only) to the new address.
## Returns {addr, rewritten: [at], other: [{at, value}]} (other = remaining words pointing inside the old table,
## to review: fields addressed directly, or false hits), or {} when the extension is full.
func relocate(old_addr: int, old_size: int, new_data: PackedByteArray, rewrite_offsets := [0]) -> Dictionary:
	var hits := pointers_into(old_addr, old_addr + old_size)
	var a := add(new_data)
	if a == 0:
		return {}
	var rewritten := []
	var other := []
	for h in hits:
		var k: int = h.value - old_addr
		if k in rewrite_offsets:
			write_u32(h.at, a + k)
			rewritten.append(h.at)
		else:
			other.append(h)
	return {"addr": a, "rewritten": rewritten, "other": other}


## The ARM9 binary to store in the ROM (uncompressed).
func build() -> PackedByteArray:
	var out := img.duplicate()
	var arena := EXT_BASE + _align(ext.size(), 32)
	out.encode_u32(ARENA_LO_LITERAL - BASE, arena)
	if not ext.is_empty():
		out.resize(EXT_BASE - BASE)   # zero padding over bss / overlay area, never read before being overwritten
		out.append_array(ext)
		while out.size() % 4:
			out.append(0)
	return out
