class_name SimLook
extends RefCounted
## Player Sim appearance (docs/formats/sim.md): the 0x21-byte record (game state G+0x47AC, actor +0x220), the Sim
## model built like Sim_ApplyAppearance 0x0200eb18 does in game (node visibility, textures, palette ranges), and the
## starting look of a new game (Sim_InitDefaultAppearance 0x0200dfd0, rewritten in place by `install`).
##
## Record (byte offsets):
##   +0x00 u16 head texture  +0x02 u16 torso texture  +0x04 u16 legs texture   (rom.bin entries, 64×64 8bpp)
##   +0x06.. u16 colours 3, 4, 5, 6, 7, 8, skin A, skin B, colour 0   (0xFFFF = the model's own colours)
##   +0x1C u8 hair node, +0x1D torso node, +0x1E legs node, +0x1F head node   +0x20 u8 outfit mode (0 = normal)

const FEMALE := 57          # FemSim (model id 0x39)
const MALE := 58            # MalSim (0x3A)
const SIZE := 0x21
const NONE := 0xFFFF

const DEFAULT_FN := 0x0200dfd0       # Sim_InitDefaultAppearance(model id, record)
const DEFAULT_FN_END := 0x0200e168   # end of its literal pool
const DEFAULT_LITS := 0x0200e154     # female head, torso; male head, torso, legs (u32 each)
const NODE_BASES := 0x0212FBB8       # u8 {hair 1, torso 14, legs 10, head 9}
const HAIR_TEX := {FEMALE: 0x0212FBE8, MALE: 0x0212FC08}   # u16[8] hair texture per hair node
const COLOR_FILES := 0x0212FBC4      # u16[4] palette files of colours 3, 4, 6, 7, 8 (5 entries of 0x60 each)
const COLOR5_FILES := 0x0212FBBC     # u16[4] palette files of colour 5 (8 entries of 0x40 each)
const COLOR0_FILE := 0x607           # colour 0: 8 entries of 0x40
const SKIN_FILES := [0x796, 0x797, 0x798]   # skin: 4 entries of 0x60 per file
## Create-a-Sim option lists in overlay 3 (u16 rom.bin entries). The menu's own indexing is not read yet: these are
## the head / torso / legs texture runs found there (docs/formats/sim.md §4).
const CAS_OVERLAY := 3
const CAS_LISTS := {
	FEMALE: {"head": [0x0214F884, 9], "torso": [0x0214FC7C, 21], "legs": [0x0214FD38, 25]},
	MALE: {"head": [0x0214F896, 9], "torso": [0x0214FC2C, 19], "legs": [0x0214FCA8, 23]},
}

## Colour fields: [record offset, label, count, palette (0 = A: hair / head / legs, 1 = B: torso), byte offset].
## Skin goes to both palettes. Names: hair = CONFIRMED (emulator); top / bottom = which textures use the range
## (torso textures: B 80..128 and 208..256; legs textures: A 128..256), ASSUMED.
const COLORS := [
	[0x12, "Skin", 4, -1, 0x40],
	[0x14, "Skin (extended)", 12, -1, 0x40],
	[0x16, "Hair colour", 8, 0, 0x00],
	[0x10, "Colour 8 (unused?)", 20, 0, 0xA0],
	[0x08, "Bottom colour 1", 20, 0, 0x100],
	[0x0A, "Bottom colour 2", 32, 0, 0x160],
	[0x0E, "Bottom colour 3", 20, 0, 0x1A0],
	[0x06, "Top colour 1", 20, 1, 0xA0],
	[0x0C, "Top colour 2", 20, 1, 0x1A0],
]
const NODES := [[0x1C, "Hair", 8, 0], [0x1D, "Torso", 3, 1], [0x1E, "Legs", 4, 2]]   # [offset, label, count, base index]
const TEXTURES := [[0x00, "Head", 1], [0x02, "Torso", 3], [0x04, "Legs", 2]]       # [offset, label, texture slot]

## Code written over Sim_InitDefaultAppearance: copy the female (model 0x39) or male record.
const INSTALL_SRC := """
	cmp r0, #0x39
	adreq r2, fem
	adrne r2, mal
	mov r3, #0
loop:
	ldrb r0, [r2, r3]
	strb r0, [r1, r3]
	add r3, r3, #1
	cmp r3, #0x21
	blt loop
	bx lr
fem:
	.space 0x24
mal:
	.space 0x24
"""
const FEM_AT := 40          # byte offset of `fem` in INSTALL_SRC (10 instructions)
const MAL_AT := 40 + 0x24


static func u16(r: PackedByteArray, o: int) -> int:
	return r.decode_u16(o)


static func set_u16(r: PackedByteArray, o: int, v: int) -> void:
	r.encode_u16(o, v & 0xFFFF)


## The starting record of model FEMALE / MALE in this ARM9: read back from an installed table, or the original values
## of Sim_InitDefaultAppearance (code read 2026-11-25; checked against RAM after Create-a-Sim with default choices).
static func rom_default(gd: GameData, model: int) -> PackedByteArray:
	var r := PackedByteArray()
	if is_installed(gd.a9):
		var at := DEFAULT_FN - 0x02000000 + (FEM_AT if model == FEMALE else MAL_AT)
		return gd.a9.slice(at, at + SIZE)
	r.resize(SIZE)
	for o in range(0, 0x18, 2):
		set_u16(r, o, NONE)
	set_u16(r, 0x12, 0)
	set_u16(r, 0x16, 0)
	var fem := model == FEMALE
	set_u16(r, 0x00, gd.u32(DEFAULT_LITS + (0 if fem else 8)))
	set_u16(r, 0x02, gd.u32(DEFAULT_LITS + (4 if fem else 12)))
	set_u16(r, 0x04, 0xC20 if fem else gd.u32(DEFAULT_LITS + 16))
	set_u16(r, 0x06, 8 if fem else 1)
	set_u16(r, 0x08, 10)
	set_u16(r, 0x0A, 0x19)
	set_u16(r, 0x0E, 9)
	r[0x1C] = gd.u8(NODE_BASES)
	r[0x1D] = gd.u8(NODE_BASES + 1)
	r[0x1E] = gd.u8(NODE_BASES + 2) + 1
	r[0x1F] = gd.u8(NODE_BASES + 3)
	return r


static func is_installed(a9: PackedByteArray) -> bool:
	var code := _install_code()
	var at := DEFAULT_FN - 0x02000000
	return a9.size() > at + FEM_AT and a9.slice(at, at + FEM_AT) == code.slice(0, FEM_AT)


static func _install_code() -> PackedByteArray:
	return ArmAsm.new().assemble(INSTALL_SRC, DEFAULT_FN)


## Rewrite Sim_InitDefaultAppearance so a new game (and the direct-boot test) starts with these records.
static func install(m: Arm9Mod, fem: PackedByteArray, mal: PackedByteArray) -> String:
	var a := ArmAsm.new()
	var code := a.assemble(INSTALL_SRC, DEFAULT_FN)
	if code.is_empty():
		return "Sim install: " + a.error
	if a.labels["fem"] != DEFAULT_FN + FEM_AT or a.labels["mal"] != DEFAULT_FN + MAL_AT:
		return "Sim install: unexpected layout"
	for i in SIZE:
		code[FEM_AT + i] = fem[i]
		code[MAL_AT + i] = mal[i]
	if code.size() > DEFAULT_FN_END - DEFAULT_FN:
		return "Sim install: code too long"
	code.resize(DEFAULT_FN_END - DEFAULT_FN)   # zero the rest of the old body
	return m.write(DEFAULT_FN, code)


## Check a record against what the game can apply. "" = fine.
static func check(r: PackedByteArray) -> String:
	if r.size() != SIZE:
		return "record size %d" % r.size()
	for n in NODES:
		var v: int = r[n[0]] - _base(n[3])
		if v < 0 or v >= n[2]:
			return "%s style %d out of range" % [n[1], v]
	for c in COLORS:
		var v := u16(r, c[0])
		if v != NONE and v >= c[2]:
			return "%s %d out of range 0..%d" % [c[1], v, c[2] - 1]
	return ""


static func _base(k: int) -> int:
	return [1, 14, 10, 9][k]


## Style index (0-based) of node field k (0 hair, 1 torso, 2 legs).
static func style(r: PackedByteArray, k: int) -> int:
	return r[NODES[k][0]] - _base(NODES[k][3])


static func set_style(r: PackedByteArray, k: int, v: int) -> void:
	r[NODES[k][0]] = _base(NODES[k][3]) + v


## Texture options of a sex: {"head": [entries], "torso": …, "legs": …} from the Create-a-Sim lists in overlay 3.
static func cas_textures(gd: GameData, model: int) -> Dictionary:
	var ov := gd.rom.overlay9_code(CAS_OVERLAY)
	var base: int = gd.rom.overlay9_info(CAS_OVERLAY).ram
	var out := {}
	var lists: Dictionary = CAS_LISTS[MALE if model == MALE else FEMALE]
	for k in lists:
		var at: int = lists[k][0] - base
		var v := []
		for i in lists[k][1]:
			if at + 2 * i + 2 <= ov.size():
				v.append(ov.decode_u16(at + 2 * i))
		out[k] = v
	return out


## 0x60 / 0x40 bytes of palette for colour field `c` (COLORS row) at value v; empty when v = NONE.
static func color_bytes(gd: GameData, c: Array, v: int) -> PackedByteArray:
	if v == NONE:
		return PackedByteArray()
	var file := 0
	var size := 0x60
	var at := 0
	match c[0]:
		0x16:
			file = COLOR0_FILE
			size = 0x40
			at = v * 0x40
		0x12:
			file = SKIN_FILES[0]
			at = (v % 4) * 0x60
		0x14:
			file = SKIN_FILES[0 if v < 4 else (1 if v < 8 else 2)]
			at = (v % 4) * 0x60
		0x0A:
			file = gd.u16(COLOR5_FILES + 2 * (v / 8))
			size = 0x40
			at = (v % 8) * 0x40
		_:
			file = gd.u16(COLOR_FILES + 2 * (v / 5))
			at = (v % 5) * 0x60
	var d := gd.rombin.data(file)
	return d.slice(at, at + size) if at + size <= d.size() else PackedByteArray()


## The Sim model `model` (FEMALE / MALE) dressed with record `r`, as a MeshInstance3D (null if it cannot be built).
static func build(gd: GameData, model: int, r: PackedByteArray) -> MeshInstance3D:
	var nb := Nsbmd.new()
	if not nb.parse(gd.rombin.data(gd.npc_model(model))):
		return null
	apply(gd, nb, model, r)
	return nb.build()


## Sim_ApplyAppearance on a parsed model (outfit mode not reproduced).
static func apply(gd: GameData, nb: Nsbmd, model: int, r: PackedByteArray) -> void:
	var shown := [r[0x1C], r[0x1D], r[0x1E], r[0x1F]]
	for i in range(1, 17):   # hair, head, legs, torso nodes; the skeleton nodes draw nothing
		if not shown.has(i):
			nb.hidden_nodes[i] = true
	var hair_tab: int = HAIR_TEX[MALE if model == MALE else FEMALE]
	var hair: int = r[0x1C] - gd.u8(NODE_BASES)
	if hair >= 0 and hair < 8:
		_tex(gd, nb, 0, gd.u16(hair_tab + 2 * hair))
	for t in TEXTURES:
		if u16(r, t[0]) != NONE:
			_tex(gd, nb, t[2], u16(r, t[0]))
	var block := nb.pal_block.duplicate()
	var skin_a := u16(r, 0x12)
	for c in COLORS:
		var v := u16(r, c[0])
		if c[0] == 0x14 and skin_a == NONE:
			continue   # the game reads skin B only when skin A is set
		if c[0] == 0x12 and u16(r, 0x14) != NONE:
			continue   # skin B wins
		var d := color_bytes(gd, c, v)
		if d.is_empty():
			continue
		for pal in ([0, 1] if c[3] < 0 else [c[3]]):
			var o: int = pal * 512 + c[4]
			if o + d.size() <= block.size():
				for i in d.size():
					block[o + i] = d[i]
	nb.set_pal_block(block)


static func _tex(gd: GameData, nb: Nsbmd, slot: int, entry: int) -> void:
	var d := gd.rombin.data(entry)
	if d.size() == 4096:
		nb.set_texels(slot, d)


## Colours of value v of colour field c (for swatches).
static func swatch(gd: GameData, c: Array, v: int) -> Array:
	var d := color_bytes(gd, c, v)
	var out := []
	for i in range(0, d.size(), 2):
		var x := d.decode_u16(i)
		out.append(Color((x & 31) / 31.0, ((x >> 5) & 31) / 31.0, ((x >> 10) & 31) / 31.0))
	return out


## 64×64 image of rom.bin texture `entry` in texture slot `slot` of an applied model (its current palettes), for
## thumbnails. null if the entry is not a 4096-byte texture.
static func texture_image(gd: GameData, nb: Nsbmd, slot: int, entry: int) -> Image:
	var d := gd.rombin.data(entry)
	if d.size() != 4096 or slot >= nb.tex_names.size():
		return null
	var t: Dictionary = nb.textures[nb.tex_names[slot]].duplicate()
	t.data1 = d
	return nb.decode_texture(t, nb.palettes.get(nb.pal_names[slot]) if slot < nb.pal_names.size() else null)
