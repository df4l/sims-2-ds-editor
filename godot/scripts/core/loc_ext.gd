class_name LocExt
extends RefCounted
## New location ids (34+; 33 stays the "no location" sentinel): code hooks that move per-location game-state arrays
## out of the game state S = [0x0213E434] for ids >= 33. See docs/journal.md (2026-11-19, new location ids).
##
## Music override, S+0x449C u8[33] (0x2A = play the location record's music, else a music picked with the stereo
## (prop message 0x5E) or the music picker (overlay 5, state 0x22)). Every access computes S + id + 0x449C, either
## `add rX,rX,#0x4000 ; ldrb/strb rY,[rX,#0x49c]` with rX = S + id (form A) or `ldr rB,=0x449C ; add rB,S,rB ;
## ldrb rV,[rB,rId]` (form B). Each site is replaced by a `b` to a trampoline in the ARM9 extension that keeps the
## original behaviour for id < 33 and uses MUSIC_SLOTS bytes in the extension for 33..63, then branches back. No `bl`
## (lr untouched), flags and every other register preserved (temps pushed). The extension array is not saved: a
## music picked for a new location resets to "record music" on reload.
## MUSIC_A + MUSIC_B are all the accesses (ARM9 + overlays): CONFIRMED by a scan of every literal word
## 0x4498..0x44C4 and every `#0x49c]` operand, 2026-11-19 (the literal at 0x02065C1C is the end bound of the
## S+0x4418 init loop, not an access).

const S_PTR := 0x0213E434
const MUSIC_SLOTS := 64
const MUSIC_DEFAULT := 0x2A
const MUSIC_OVERLAY := 5
const OV_BASE := 0x02149B40

## form A: [site of `add rX,rX,#0x4000`, original word, rX, overlay (-1 = ARM9)]
const MUSIC_A := [
	[0x0201F63C, 0xE2800901, 0, -1],   # Unk_0201f190_PropMsgHandler: strb r1,[r0,#0x49c]
	[0x0201F684, 0xE2811901, 1, -1],   # same: strb r0,[r1,#0x49c]
	[0x0201F6FC, 0xE2811901, 1, -1],   # same: strb r0,[r1,#0x49c]
	[0x02084C64, 0xE2800901, 0, -1],   # Map_LoadLocation: ldrb r0,[r0,#0x49c]
	[0x02084D14, 0xE2800901, 0, -1],   # Map_PlayLocationMusic: ldrb r0,[r0,#0x49c]
	[0x0214A120, 0xE2822901, 2, 5],    # overlay 5 (music picker): strb r0,[r2,#0x49c]
	[0x0214A654, 0xE2800901, 0, 5],    # overlay 5: ldrb r0,[r0,#0x49c]
]
## form B: [site of `ldrb rV,[rB,rId]`, original word, rB, rId, rV, rA (-1 or register that receives the byte's
## address), return address]
const MUSIC_B := [
	# Unk_0201f190_PropMsgHandler: ldrb r1,[r0,r5] ; add r2,r0,r5 (r2 = store address used at 0x0201F6B8/6D0)
	[0x0201F69C, 0xE7D01005, 0, 5, 1, 2, 0x0201F6A4],
	[0x0201FFD8, 0xE7D02002, 0, 2, 2, -1, 0x0201FFDC],   # ldrb r2,[r0,r2]
	[0x02020C94, 0xE7D03003, 0, 3, 3, -1, 0x02020C98],   # ldrb r3,[r0,r3]
]
const MUSIC_B_NEXT := {0x0201F69C: [0x0201F6A0, 0xE0802005]}   # second replaced word (checked only)


static func arm_b(from: int, to: int, cond := 0xE) -> int:
	return (cond << 28) | 0x0A000000 | (((to - from - 8) >> 2) & 0xFFFFFF)


## Two temp registers (r0..r7) not in `used`.
static func _temps(used: Array) -> Array:
	var t := []
	for r in 8:
		if not used.has(r):
			t.append(r)
	return t.slice(0, 2)


## Words of a trampoline at `at`: `body` (list of words; a value < 0 = index into lits, encoded as ldr<cond> from
## the literal pool), then `b ret`, then the literals. Each lit entry: [cond, rd, value].
static func _assemble(at: int, body: Array, lits: Array, ret: int) -> PackedByteArray:
	var n := body.size() + 1
	var out := PackedByteArray()
	out.resize(4 * (n + lits.size()))
	for i in body.size():
		var w: int = body[i]
		if w < 0:
			var k := -w - 1
			var off: int = 4 * (n + k) - (4 * i + 8)
			w = (lits[k][0] << 28) | 0x059F0000 | (lits[k][1] << 12) | off
		out.encode_u32(4 * i, w)
	out.encode_u32(4 * (n - 1), arm_b(at + 4 * (n - 1), ret))
	for k in lits.size():
		out.encode_u32(4 * (n + k), lits[k][2])
	return out


## Install the music override hooks. `ovl` receives {overlay: {address: [old word, new word]}} for the overlay
## sites (same shape as EditProject.ovl_patches). "" or an error.
static func music_hook(m: Arm9Mod, ovl: Dictionary) -> String:
	var slots := PackedByteArray()
	slots.resize(MUSIC_SLOTS)
	slots.fill(MUSIC_DEFAULT)
	var arr := m.add(slots)
	if arr == 0:
		return m.error
	for s in MUSIC_A:
		var at: int = s[0]
		var rx: int = s[2]
		var t := _temps([rx])
		var t0: int = t[0]
		var t1: int = t[1]
		var mask := (1 << t0) | (1 << t1)
		var body := [
			0xE92D0000 | mask,                                   # push {t0,t1}
			0xE10F0000 | (t1 << 12),                             # mrs t1,cpsr
			-1,                                                  # ldr t0,=S_PTR
			0xE5900000 | (t0 << 16) | (t0 << 12),                # ldr t0,[t0]
			0xE0400000 | (rx << 16) | (t0 << 12) | t0,           # sub t0,rX,t0       (id)
			0xE3500021 | (t0 << 16),                             # cmp t0,#33
			0x32800901 | (rx << 16) | (rx << 12),                # addlo rX,rX,#0x4000 (original)
			-2,                                                  # ldrhs rX,=arr-0x49C
			0x20800000 | (rx << 16) | (rx << 12) | t0,           # addhs rX,rX,t0
			0xE128F000 | t1,                                     # msr cpsr_f,t1
			0xE8BD0000 | mask,                                   # pop {t0,t1}
		]
		var lits := [[0xE, t0, S_PTR], [0x2, rx, arr - 0x49C]]
		var e := _hook(m, ovl, at, s[1], s[3], body, lits, at + 4)
		if e != "":
			return e
	for s in MUSIC_B:
		var at: int = s[0]
		var rb: int = s[2]
		var rid: int = s[3]
		var rv: int = s[4]
		var ra: int = s[5]
		if MUSIC_B_NEXT.has(at):
			var nx: Array = MUSIC_B_NEXT[at]
			if m.read_u32(nx[0]) != nx[1]:
				return "music hook: the word at 0x%08X is 0x%08X, not 0x%08X: unsupported game version" % [nx[0], m.read_u32(nx[0]), nx[1]]
		var t := _temps([rb, rid, rv, ra])
		var t0: int = t[0]
		var t1: int = t[1]
		var mask := (1 << t0) | (1 << t1)
		var body := [
			0xE92D0000 | mask,                                   # push {t0,t1}
			0xE10F0000 | (t1 << 12),                             # mrs t1,cpsr
			0xE3500021 | (rid << 16),                            # cmp rId,#33
			0x30800000 | (rb << 16) | (t0 << 12) | rid,          # addlo t0,rB,rId
			-1,                                                  # ldrhs t0,=arr
			0x20800000 | (t0 << 16) | (t0 << 12) | rid,          # addhs t0,t0,rId
		]
		if ra >= 0:
			body.append(0xE1A00000 | (ra << 12) | t0)            # mov rA,t0
		body.append(0xE5D00000 | (t0 << 16) | (rv << 12))        # ldrb rV,[t0]
		body.append(0xE128F000 | t1)                             # msr cpsr_f,t1
		body.append(0xE8BD0000 | mask)                           # pop {t0,t1}
		var e := _hook(m, ovl, at, s[1], -1, body, [[0x2, t0, arr]], s[6])
		if e != "":
			return e
	return ""


## Check the original word at `at`, put the trampoline in the extension and the `b` at `at`.
static func _hook(m: Arm9Mod, ovl: Dictionary, at: int, old: int, ov: int, body: Array, lits: Array, ret: int) -> String:
	if ov < 0 and m.read_u32(at) != old:
		return "music hook: the word at 0x%08X is 0x%08X, not 0x%08X: unsupported game version" % [at, m.read_u32(at), old]
	var size := 4 * (body.size() + 1 + lits.size())
	var tr := m.alloc(size)
	if tr == 0:
		return m.error
	m.write(tr, _assemble(tr, body, lits, ret))
	var jump := arm_b(at, tr)
	if ov < 0:
		m.write_u32(at, jump)
	else:
		if not ovl.has(ov):
			ovl[ov] = {}
		ovl[ov][at] = [old, jump]
	return ""


## Apply {overlay: {address: [old, new]}} to the overlays of `rom`: returns {files, ovt} for NdsRom.rebuild
## (overlays stored uncompressed), or {error}.
static func apply_overlay_patches(rom: NdsRom, ovl: Dictionary) -> Dictionary:
	var files := {}
	var ovt := rom.overlay9_table()
	for ov in ovl:
		var code := rom.overlay9_code(ov)
		if code.is_empty():
			return {"error": rom.error}
		var inf := rom.overlay9_info(ov)
		for at in ovl[ov]:
			var o: int = at - inf.ram
			var pr: Array = ovl[ov][at]
			if o < 0 or o + 4 > code.size() or code.decode_u32(o) != pr[0]:
				return {"error": "overlay %d: the word at 0x%08X is not 0x%08X: unsupported game version" % [ov, at, pr[0]]}
			code.encode_u32(o, pr[1])
		files[inf.file] = code
		ovt.encode_u32(32 * ov + 0x1C, code.size() & 0xFFFFFF)
	return {"files": files, "ovt": ovt}
