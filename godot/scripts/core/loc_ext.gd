class_name LocExt
extends RefCounted
## New location ids (34..63; 33 stays the "no location" sentinel). install() puts everything a new location needs in
## the ARM9 extension and hooks the code that would read past the 33-entry per-location arrays. Ids <= 33 keep the
## original code path (id 33 included: its reads past the arrays, e.g. name text 0x64, stay as in the original game).
## docs/formats/arm9.md §6 and §7, docs/journal.md (2026-11-19, new location ids).
##
## Every hook replaces one instruction with a `b` to a trampoline in the extension, which redoes the original
## instruction for id < FIRST and does the new-location variant for id >= FIRST, then branches back. No `bl` at the site
## (lr untouched). Temps are pushed when no free register is known; flags are kept (mrs / msr) when the code after the
## site might use them.
##
## What a new location gets (one entry per id, 64-entry tables in the extension):
##  - location table (64 pointers) and its own record (copy of the template's, nav / bsp changed);
##  - "behaves like" id (`alias`): the hard-coded id lists of Map_UpdateLocationAmbience (indoor list = fog, ambient
##    sounds, weather), State2_LocationEnter (render depth defaults) and Map_SetLocationLightKeys see the alias id;
##  - name text id (the game uses text 0x43 + id: 15 sites hooked);
##  - layout variant rows (copied from the template, Map_LoadLocation);
##  - price entry {u16 price, u8 score, u8 menu parent location}: price 0 = always open (Coll_IsOwned returns 1),
##    price > 0 = sold in the construction menu (overlay 1), ids <= SALE_MAX only (the owned / offered bitsets are
##    saved with 5 bytes: bits 0..39). Built at once (no construction timer); `offered` = in the menu from the start;
## Per-location game state of ids >= FIRST: music override (64-byte array, init "record music"), random prop records
## of LocStateSpawnProps (0xFC bytes each), no dust, construction timer S+0x4418 = "none" (0x80000000). The
## extension is not saved: music picked with the stereo and picked-up random props reset on reload.

const S_PTR := 0x0213E434
const COLL := 0x41F8                 # Coll = S + 0x41F8 (bitsets +0x210 offered, +0x218 owned, +0x220 timers)
const FIRST := 34
const MAX_ID := 63
const N := 64                        # entries of the new per-location tables
const SALE_MAX := 39
const NONE_TIME := 0x80000000
const REC := 0xFC

const LOC_TABLE := 0x021332E0
const NAME_BASE := 0x43
const PRICE_TABLE := 0x0211F9EC
const PRICE_LITERAL := 0x02073F78    # Coll_PriceEntry (0x02073F6C); Coll_GetScore keeps the old table (ids < 33)
const DUST_TABLE := 0x02131F34
const DUST_LITERALS := [0x0205F108, 0x0205F26C, 0x0205F344, 0x0205F380]
const VARIANT_LITERAL := 0x02084CEC
const VARIANT_COUNT := 0x02084C20    # cmp r2,#0xc
const COLL_SET_OWNED := 0x020734A0
const OV01_LOOP := 0x02149CA0        # cmp r5,#0x21 (construction menu list)
const OV01_LOOP_WORD := 0xE3550021

# condition codes
const EQ := 0x0
const NE := 0x1
const HS := 0x2
const LO := 0x3
const GT := 0xC
const AL := 0xE

## name sites `add rD,rS,#0x43` before Txt_GetString: [address, original word, rD, rS, overlay (-1 = ARM9)]
const NAME_SITES := [
	[0x0205AD38, 0xE2814043, 4, 1, -1],   # NPC location (relationship panel)
	[0x0206EA28, 0xE2800043, 0, 0, -1],   # save slot location (load screen)
	[0x0206ED98, 0xE2800043, 0, 0, -1],   # same
	[0x020C384C, 0xE2840043, 0, 4, -1],   # current location (world+0xF4)
	[0x0214A1E8, 0xE2810043, 0, 1, 1],    # construction menu: location
	[0x0214A218, 0xE2800043, 0, 0, 1],    # construction menu: parent (price entry byte 3)
	[0x0214A3FC, 0xE2810043, 0, 1, 1],
	[0x0214A430, 0xE2800043, 0, 0, 1],
	[0x0214A604, 0xE2810043, 0, 1, 1],
	[0x0214A634, 0xE2800043, 0, 0, 1],
	[0x0214A804, 0xE2810043, 0, 1, 1],
	[0x0214A834, 0xE2800043, 0, 0, 1],
	[0x0214AAE4, 0xE2810043, 0, 1, 1],
	[0x0214AB14, 0xE2800043, 0, 0, 1],
	[0x0214A79C, 0xE2800043, 0, 0, 8],    # save menu: location of the save
]

# --- ARM encodings ------------------------------------------------------------------------------------------------

static func arm_b(from: int, to: int, cond := AL) -> int:
	return (cond << 28) | 0x0A000000 | (((to - from - 8) >> 2) & 0xFFFFFF)


static func arm_bl(from: int, to: int, cond := AL) -> int:
	return (cond << 28) | 0x0B000000 | (((to - from - 8) >> 2) & 0xFFFFFF)


static func cmpi(rn: int, imm: int, c := AL) -> int:
	return (c << 28) | 0x03500000 | (rn << 16) | imm


static func addr(rd: int, rn: int, rm: int, lsl := 0, c := AL) -> int:
	return (c << 28) | 0x00800000 | (rn << 16) | (rd << 12) | (lsl << 7) | rm


static func subr(rd: int, rn: int, rm: int, lsl := 0, c := AL) -> int:
	return (c << 28) | 0x00400000 | (rn << 16) | (rd << 12) | (lsl << 7) | rm


static func addi(rd: int, rn: int, imm: int, c := AL) -> int:
	return (c << 28) | 0x02800000 | (rn << 16) | (rd << 12) | imm


static func movr(rd: int, rm: int, c := AL) -> int:
	return (c << 28) | 0x01A00000 | (rd << 12) | rm


static func movi(rd: int, imm: int, c := AL) -> int:
	return (c << 28) | 0x03A00000 | (rd << 12) | imm


static func ldr0(rd: int, rn: int, c := AL) -> int:
	return (c << 28) | 0x05900000 | (rn << 16) | (rd << 12)


static func ldrbr(rd: int, rn: int, rm: int, c := AL) -> int:
	return (c << 28) | 0x07D00000 | (rn << 16) | (rd << 12) | rm


static func ldrbi(rd: int, rn: int, imm: int, c := AL) -> int:
	return (c << 28) | 0x05D00000 | (rn << 16) | (rd << 12) | imm


static func ldrh0(rd: int, rn: int, c := AL) -> int:
	return (c << 28) | 0x01D000B0 | (rn << 16) | (rd << 12)


static func mla(rd: int, rm: int, rs: int, rn: int, c := AL) -> int:
	return (c << 28) | 0x00200090 | (rd << 16) | (rn << 12) | (rs << 8) | rm


static func tsti(rn: int, imm: int, c := AL) -> int:
	return (c << 28) | 0x03100000 | (rn << 16) | imm


static func bx_lr(c := AL) -> int:
	return (c << 28) | 0x012FFF1E


static func push(mask: int) -> int:
	return 0xE92D0000 | mask


static func pop(mask: int) -> int:
	return 0xE8BD0000 | mask


static func mrs(rd: int) -> int:
	return 0xE10F0000 | (rd << 12)


static func msr_f(rm: int) -> int:
	return 0xE128F000 | rm


## Two temp registers (r0..r7) not in `used`.
static func _temps(used: Array) -> Array:
	var t := []
	for r in 8:
		if not used.has(r):
			t.append(r)
	return t.slice(0, 2)


## Words of a trampoline at `at`. Body entries: int >= 0 = instruction word; int < 0 = `ldr<cond> rd,=value` with
## lits[-v - 1] = [cond, rd, value] (pool after the code); ["b", cond, address] / ["bl", cond, address] = branch to an
## absolute address; ["j", cond, k] = branch to body entry k. Then `b ret` unless ret < 0, then the literal pool.
static func _assemble(at: int, body: Array, lits: Array, ret: int) -> PackedByteArray:
	var n := body.size() + (1 if ret >= 0 else 0)
	var out := PackedByteArray()
	out.resize(4 * (n + lits.size()))
	for i in body.size():
		var e = body[i]
		var pc := at + 4 * i
		var w := 0
		if e is Array:
			match e[0]:
				"b": w = arm_b(pc, e[2], e[1])
				"bl": w = arm_bl(pc, e[2], e[1])
				"j": w = arm_b(pc, at + 4 * e[2], e[1])
		elif e < 0:
			var k: int = -e - 1
			var off: int = 4 * (n + k) - (4 * i + 8)
			w = (lits[k][0] << 28) | 0x059F0000 | (lits[k][1] << 12) | off
		else:
			w = e
		out.encode_u32(4 * i, w)
	if ret >= 0:
		out.encode_u32(4 * (n - 1), arm_b(at + 4 * (n - 1), ret))
	for k in lits.size():
		out.encode_u32(4 * (n + k), lits[k][2])
	return out


## Check the original word at `at` (ARM9 or overlay `ov`), put the trampoline in the extension and the `b` at `at`.
## Overlay sites go to `ovl` ({overlay: {address: [old word, new word]}}).
static func _hook(m: Arm9Mod, ovl: Dictionary, at: int, old: int, ov: int, body: Array, lits: Array, ret: int) -> String:
	if ov < 0 and m.read_u32(at) != old:
		return "new locations: the word at 0x%08X is 0x%08X, not 0x%08X: unsupported game version (or a ROM already exported with new locations: open the original)" % [at, m.read_u32(at), old]
	var size := 4 * (body.size() + (1 if ret >= 0 else 0) + lits.size())
	var tr := m.alloc(size)
	if tr == 0:
		return m.error
	m.write(tr, _assemble(tr, body, lits, ret))
	return _patch(m, ovl, at, old, ov, arm_b(at, tr))


## Replace one word (ARM9 directly, overlay through `ovl`).
static func _patch(m: Arm9Mod, ovl: Dictionary, at: int, old: int, ov: int, new_word: int) -> String:
	if ov < 0:
		if m.read_u32(at) != old:
			return "new locations: the word at 0x%08X is 0x%08X, not 0x%08X: unsupported game version" % [at, m.read_u32(at), old]
		return m.write_u32(at, new_word)
	if not ovl.has(ov):
		ovl[ov] = {}
	ovl[ov][at] = [old, new_word]
	return ""


# --- music override (S+0x449C u8[33]) -----------------------------------------------------------------------------
## Every access computes S + id + 0x449C, either `add rX,rX,#0x4000 ; ldrb/strb rY,[rX,#0x49c]` with rX = S + id
## (form A) or `ldr rB,=0x449C ; add rB,S,rB ; ldrb rV,[rB,rId]` (form B). 0x2A = play the location record's music.
## MUSIC_A + MUSIC_B are all the accesses (ARM9 + overlays): CONFIRMED by a scan of every literal word
## 0x4498..0x44C4 and every `#0x49c]` operand, 2026-11-19 (the literal at 0x02065C1C is the end bound of the
## S+0x4418 init loop, not an access).

const MUSIC_DEFAULT := 0x2A

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


## Install the music override hooks. "" or an error.
static func music_hook(m: Arm9Mod, ovl: Dictionary) -> String:
	var slots := PackedByteArray()
	slots.resize(N)
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
			push(mask),
			mrs(t1),
			-1,                                    # ldr t0,=S_PTR
			ldr0(t0, t0),                          # t0 = S
			0xE0400000 | (rx << 16) | (t0 << 12) | t0,   # sub t0,rX,t0  (id)
			cmpi(t0, FIRST),
			addi(rx, rx, 0x901, LO),               # addlo rX,rX,#0x4000 (original)
			-2,                                    # ldrhs rX,=arr-0x49C
			addr(rx, rx, t0, 0, HS),               # addhs rX,rX,t0
			msr_f(t1),
			pop(mask),
		]
		var e := _hook(m, ovl, at, s[1], s[3], body, [[AL, t0, S_PTR], [HS, rx, arr - 0x49C]], at + 4)
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
			push(mask),
			mrs(t1),
			cmpi(rid, FIRST),
			addr(t0, rb, rid, 0, LO),              # addlo t0,rB,rId
			-1,                                    # ldrhs t0,=arr
			addr(t0, t0, rid, 0, HS),              # addhs t0,t0,rId
		]
		if ra >= 0:
			body.append(movr(ra, t0))              # mov rA,t0
		body.append(ldrbi(rv, t0, 0))              # ldrb rV,[t0]
		body.append(msr_f(t1))
		body.append(pop(mask))
		var e := _hook(m, ovl, at, s[1], -1, body, [[HS, t0, arr]], s[6])
		if e != "":
			return e
	return ""


# --- everything ---------------------------------------------------------------------------------------------------

## Install the new locations. `locs`: [{id, src, record (PackedByteArray, the new record), alias, name_text, price,
## score, parent, offered}] with ids FIRST..MAX_ID. "" or an error. Overlay words go to `ovl`.
static func install(m: Arm9Mod, ovl: Dictionary, locs: Array) -> String:
	if locs.is_empty():
		return ""
	var by_id := {}
	for L in locs:
		var id: int = L.id
		if id < FIRST or id > MAX_ID or by_id.has(id):
			return "new location id %d: must be %d..%d and unique" % [id, FIRST, MAX_ID]
		if L.price > 0 and id > SALE_MAX:
			return "location %d: only ids %d..%d can be sold (the game saves the owned bits 0..39)" % [id, FIRST, SALE_MAX]
		if L.alias < 0 or L.alias > 32 or L.src < 0 or L.src > 32:
			return "location %d: template and 'behaves like' must be original locations (0..32)" % id
		by_id[id] = L
	if m.read_u32(PRICE_LITERAL) != PRICE_TABLE:
		return "new locations: this ROM already has them (the price table moved): open the original ROM"

	# location table and records
	var tab := PackedByteArray()
	tab.resize(4 * N)
	var old := m.read(LOC_TABLE, FIRST * 4)   # word 33 = what the original game reads for id 33
	for i in N:
		tab.encode_u32(4 * i, old.decode_u32(4 * (i if i < FIRST else 6)))   # unused ids -> a valid record
	for id in by_id:
		var a := m.add(by_id[id].record)
		if a == 0:
			return m.error
		tab.encode_u32(4 * id, a)
	var r := m.relocate(LOC_TABLE, 33 * 4, tab)
	if r.is_empty():
		return m.error
	if r.rewritten.size() != 7:
		return "new locations: %d pointers to the location table, 7 expected: unsupported game version" % r.rewritten.size()

	# per-id tables: alias, name text, price entries, flags
	var alias := PackedByteArray()
	alias.resize(N)
	var names := PackedByteArray()
	names.resize(2 * N)
	var prices := m.read(PRICE_TABLE, FIRST * 4)
	prices.resize(4 * N)
	var flags := PackedByteArray()
	flags.resize(N)
	for i in N:
		alias[i] = i if i < FIRST else 6
		names.encode_u16(2 * i, NAME_BASE + (i if i < FIRST else 6))
	for id in by_id:
		var L: Dictionary = by_id[id]
		alias[id] = L.alias
		names.encode_u16(2 * id, L.name_text)
		prices.encode_u32(4 * id, (L.price & 0xFFFF) | ((L.score & 0xFF) << 16) | ((L.parent & 0xFF) << 24))
		flags[id] = 1 if L.offered else 0
	var a_alias := m.add(alias)
	var a_names := m.add(names)
	var a_price := m.add(prices)
	var a_flags := m.add(flags)
	var timer := PackedByteArray()
	timer.resize(4)
	timer.encode_u32(0, NONE_TIME)
	var a_timer := m.add(timer)
	var dust := m.read(DUST_TABLE, FIRST)
	dust.resize(N)
	var a_dust := m.add(dust)
	var a_rec := m.alloc(REC * (N - 33))
	if 0 in [a_alias, a_names, a_price, a_flags, a_timer, a_dust, a_rec]:
		return m.error

	var e := music_hook(m, ovl)
	if e == "":
		e = _variants(m, by_id)
	if e == "":
		e = _patch(m, ovl, PRICE_LITERAL, PRICE_TABLE, -1, a_price)
	for lit in DUST_LITERALS:
		if e == "":
			e = _patch(m, ovl, lit, DUST_TABLE, -1, a_dust)
	var hooks := [
		# Map_UpdateLocationAmbience: ldr r4,[r1,#0xf4] (id) -> alias (r3 is set right after)
		[0x0207625C, 0xE59140F4, -1, [0xE59140F4, cmpi(4, FIRST), -1, ldrbr(4, 3, 4, HS)], [[HS, 3, a_alias]], 0x02076260],
		# State2_LocationEnter: id lists on r5 -> alias, real id kept in r4 (free until 0x020771A4)...
		[0x02076F4C, 0xE355001A, -1, [movr(4, 5), cmpi(5, FIRST), -1, ldrbr(5, 0, 5, HS), 0xE355001A], [[HS, 0, a_alias]], 0x02076F50],
		# ... and put back after the lists (ldr r0,=0x0213F98C)
		[0x02077104, 0xE59F04C8, -1, [movr(5, 4), -1], [[AL, 0, 0x0213F98C]], 0x02077108],
		# Map_SetLocationLightKeys: cmp r1,#0x21 ; id > 33 -> alias (r0 free)
		[0x02085E04, 0xE3510021, -1, [cmpi(1, 0x21), -1, ldrbr(1, 0, 1, GT), cmpi(1, 0x21)], [[GT, 0, a_alias]], 0x02085E08],
		# Hotel_DustOnLocationEnter: dust count of the current id (ids >= FIRST: 0, no dust)
		[0x0205EFA4, 0xE59A1000, -1, [0xE59A1000, movi(9, 0), cmpi(1, FIRST), addr(1, 10, 1, 0, LO), ldrbi(1, 1, 8, LO),
			movi(1, 0, HS)], [], 0x0205EFB4],
		# LocStateSpawnProps: record = S+0x18+0x70+id*0xFC -> extension for ids >= FIRST
		[0x02083890, 0xE0292091, -1, [cmpi(1, FIRST), mla(9, 1, 0, 2, LO), -1, mla(9, 1, 0, 2, HS)],
			[[HS, 2, a_rec - 33 * REC]], 0x02083894],
		# prop pick-up: S + id*0xFC (+0x95 + slot*16) -> extension (r2 = 1 afterwards)
		[0x0208D698, 0xE0203091, -1, [cmpi(1, FIRST), mla(0, 1, 0, 3, LO), -1, mla(0, 1, 0, 2, HS), movi(2, 1)],
			[[HS, 2, a_rec - 33 * REC - 0x88]], 0x0208D69C],
		# Door_TryEnter: construction timer S+0x4418[id] -> NONE_TIME for ids >= FIRST
		[0x02064430, 0xE0850103, -1, [cmpi(3, FIRST), addr(0, 5, 3, 2, LO), -1], [[HS, 0, a_timer - 0x4418]], 0x02064434],
		# door warp (FUN_0209b838): ip = S+0x4418 (timer array base), read at [ip, dest lsl 2]: ids >= FIRST ->
		# a_timer - 4 * dest (flags: cmp at 0x0209B89C). Without it id 34 reads the music bytes -> "room being built"
		[0x0209B88C, 0xE08EC001, -1, [cmpi(5, FIRST), addr(12, 14, 1, 0, LO), -1, subr(12, 12, 5, 2, HS)],
			[[HS, 12, a_timer]], 0x0209B890],
		# overlay 1 menu list: same timer
		[0x02149C68, 0xE0810105, 1, [cmpi(5, FIRST), addr(0, 1, 5, 2, LO), -1], [[HS, 0, a_timer - 0x4418]], 0x02149C6C],
		# Coll_IsOwned: ids >= FIRST with price 0 are always open
		[0x0207355C, 0xE1A022C1, -1, [cmpi(1, FIRST), ["j", LO, 8], -1, addr(2, 2, 1, 2), ldrh0(2, 2), cmpi(2, 0),
			movi(0, 1, EQ), bx_lr(EQ), 0xE1A022C1], [[AL, 2, a_price]], 0x02073560],
		# Coll_IsOffered (bitset +0x210): ids >= FIRST offered from the start
		[0x020735A8, 0xE1A022C1, -1, [cmpi(1, FIRST), ["j", LO, 7], -1, ldrbr(2, 2, 1), tsti(2, 1), movi(0, 1, NE),
			bx_lr(NE), 0xE1A022C1], [[AL, 2, a_flags]], 0x020735AC],
		# overlay 1 purchase: ids >= FIRST owned at once (like id 4), no timer, no construction record
		[0x02149F68, 0xE3510004, 1, [cmpi(1, FIRST), ["j", LO, 9], -1, ldr0(0, 0), -2, addr(0, 0, 2), movi(2, 1),
			["bl", AL, COLL_SET_OWNED], ["b", AL, 0x0214A09C], 0xE3510004], [[AL, 0, S_PTR], [AL, 2, COLL]], 0x02149F6C],
	]
	for h in hooks:
		if e != "":
			break
		e = _hook(m, ovl, h[0], h[1], h[2], h[3], h[4], h[5])
	var sale := false
	for id in by_id:
		sale = sale or by_id[id].price > 0
	if e == "" and sale:
		e = _patch(m, ovl, OV01_LOOP, OV01_LOOP_WORD, 1, cmpi(5, SALE_MAX + 1))
	for s in NAME_SITES:
		if e != "":
			break
		var rd: int = s[2]
		var rs: int = s[3]
		var t := _temps([rd, rs])
		var t0: int = t[0]
		var t1: int = t[1]
		var mask := (1 << t0) | (1 << t1)
		var body := [push(mask), mrs(t1), cmpi(rs, FIRST), addi(rd, rs, NAME_BASE, LO), -1, addr(t0, t0, rs, 1, HS),
			ldrh0(rd, t0, HS), msr_f(t1), pop(mask)]
		e = _hook(m, ovl, s[0], s[1], s[4], body, [[HS, t0, a_names]], s[0] + 4)
	return e


## Layout variant table (Map_LoadLocation): 12 rows {u8 loc, u8 variant[5] by chapter}; a new location gets a copy
## of its template's rows.
static func _variants(m: Arm9Mod, by_id: Dictionary) -> String:
	var vt := m.read_u32(VARIANT_LITERAL)
	if m.read_u32(VARIANT_COUNT) != 0xE352000C:
		return "new locations: unexpected variant row count at 0x%08X" % VARIANT_COUNT
	var rows := m.read(vt, 72)
	var out := rows.duplicate()
	for id in by_id:
		for k in 12:
			if rows[6 * k] == by_id[id].src:
				var row := rows.slice(6 * k, 6 * k + 6)
				row[0] = id
				out.append_array(row)
	if out.size() == rows.size():
		return ""
	if out.size() / 6 > 255:
		return "too many layout variant rows"
	var a := m.add(out)
	if a == 0:
		return m.error
	m.write_u32(VARIANT_LITERAL, a)
	m.write_u32(VARIANT_COUNT, 0xE3520000 | (out.size() / 6))
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
