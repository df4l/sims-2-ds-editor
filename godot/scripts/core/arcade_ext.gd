class_name ArcadeExt
extends RefCounted
## Own arcade games (docs/formats/arcade.md §6).
##
## The game table 0x0211E200 (10 × {Init(actor, attract), Update(), Free()}) moves to the ARM9 extension with room for
## new types (10..). The 9 literal words that address it (base, +4, +8) are rewritten. The unimplemented cabinets
## 174 / 175 / 176 (Lunar Lander, Space Gunner, Log Jump: their prop case sets type 0) get the type of a new game.
## A game is ARM assembly (ArmAsm syntax) defining the labels `init`, `update` and `free`; it is assembled in the
## extension with the symbols of SYMS.

const TABLE := 0x0211E200
const OLD_TYPES := 10
const MAX_TYPES := 32
# the literal-pool words that hold TABLE + 0 / +4 / +8 (Arc_Controller*), CONFIRMED by a scan of the ARM9
const TABLE_LITERALS := [0x02029414, 0x02029418, 0x02029960, 0x02029964, 0x02029970, 0x02029A60, 0x02029A64,
	0x02029C60, 0x02029CF0]
# prop -> address of `mov r3,#0` (type byte of the task params) in its Prop_CreatePlacementObject case
const FREE_PROPS := {174: 0x020143BC, 175: 0x02014428, 176: 0x02014494}
const MOV_R3_0 := 0xE3A03000

## Game API for the assembly (all CONFIRMED from the original games, docs/formats/arcade.md).
const SYMS := {
	"ALLOC": 0x02046880,        # (size, 3, 4) -> ptr  (screen buffers of the original games)
	"FREE": 0x0204681C,         # (ptr)
	"MEMSET": 0x02046384,       # (ptr, byte, size)
	"UPLOAD_TEX": 0x020BBDE8,   # Gfx_UploadModelTexImage(actor + 0x1A4, 1, buf, 0x1000, [sp] 0)
	"UPLOAD_PAL": 0x020BBCF0,   # Gfx_UploadModelTexPalette(actor + 0x1A4, 1, pal, 8, [sp] 0, [sp+4] 0)
	"KEYS": 0x02139E8C,         # -> key struct: +2 held, +6 pressed (u16)
	"RAND": 0x0204CBB4,         # (lo, hi) -> random in [lo, hi)
	"PLAY_SFX": 0x020D5680,     # (sound id, position) as the games do with actor + 0x78
	"SCREEN_SIZE": 0x1000,
	"MODEL": 0x1A4,             # cabinet actor -> model instance
}


## Install `games` = [{prop: 174..176, lang: "script" | "asm", source: String, name: String}]. "" or an error.
## Script games share one copy of the VM (VM_ASM); each gets a game block (header, variables, sprites, bytecode) and
## three thunks.
static func install(m: Arm9Mod, games: Array) -> String:
	if games.is_empty():
		return ""
	if games.size() > MAX_TYPES - OLD_TYPES:
		return "arcade: too many games"
	for at in TABLE_LITERALS:
		var v := m.read_u32(at)
		if v - TABLE not in [0, 4, 8]:
			return "arcade: the word at 0x%08X is 0x%08X, not the game table: unsupported game version (or an already exported ROM: open the original)" % [at, v]
	# moved table: the 10 original entries, then ours
	var tab := m.read(TABLE, 12 * OLD_TYPES)
	tab.resize(12 * (OLD_TYPES + games.size()))
	var used := {}
	var vm := {}
	for k in games.size():
		var g: Dictionary = games[k]
		var prop: int = g.prop
		if not FREE_PROPS.has(prop):
			return "arcade: cabinet %d is not a free slot (174, 175, 176)" % prop
		if used.has(prop):
			return "arcade: two games on cabinet %d" % prop
		used[prop] = true
		var site: int = FREE_PROPS[prop]
		if m.read_u32(site) != MOV_R3_0:
			return "arcade: the word at 0x%08X is 0x%08X, not mov r3,#0: unsupported game version" % [site, m.read_u32(site)]
		var r := {}
		if g.get("lang", "asm") == "script":
			if vm.is_empty():
				vm = install_vm(m)
				if vm.has("error"):
					return "arcade VM: " + vm.error
			r = install_script_game(m, vm, g.source)
		else:
			r = assemble_game(m, g.source)
		if r.has("error"):
			return "arcade game '%s': %s" % [g.get("name", str(prop)), r.error]
		var t := OLD_TYPES + k
		tab.encode_u32(12 * t, r.init)
		tab.encode_u32(12 * t + 4, r.update)
		tab.encode_u32(12 * t + 8, r.free)
		var e := m.write_u32(site, MOV_R3_0 | t)
		if e != "":
			return e
	var a := m.add(tab)
	if a == 0:
		return m.error
	for at in TABLE_LITERALS:
		var e := m.write_u32(at, a + m.read_u32(at) - TABLE)
		if e != "":
			return e
	return ""


## Assemble ArmAsm source in the extension: {addr, size, labels} or {error}.
static func assemble_at(m: Arm9Mod, src: String, syms: Dictionary) -> Dictionary:
	var asm := ArmAsm.new()
	var probe := asm.assemble(src, Arm9Mod.EXT_BASE, syms)
	if asm.error != "":
		return {"error": asm.error}
	if probe.is_empty():
		return {"error": "empty program"}
	var a := m.alloc(probe.size())
	if a == 0:
		return {"error": m.error}
	var bin := asm.assemble(src, a, syms)
	if asm.error != "" or bin.size() != probe.size():
		return {"error": "internal: size changed with the address (%s)" % asm.error}
	m.write(a, bin)
	return {"addr": a, "size": bin.size(), "labels": asm.labels}


## Assemble a game into the extension: {init, update, free, addr, size} or {error}.
static func assemble_game(m: Arm9Mod, src: String) -> Dictionary:
	var asm := ArmAsm.new()
	asm.assemble(src, Arm9Mod.EXT_BASE, SYMS)
	if asm.error == "":
		for l in ["init", "update", "free"]:
			if not asm.labels.has(l):
				return {"error": "label '%s' missing" % l}
	var r := assemble_at(m, src, SYMS)
	if r.has("error"):
		return r
	return {"init": r.labels.init, "update": r.labels.update, "free": r.labels.free, "addr": r.addr, "size": r.size}


## The VM, once per ROM: {vm_init, vm_update, vm_free, addr, size} or {error}.
static func install_vm(m: Arm9Mod) -> Dictionary:
	var r := assemble_at(m, vm_source(), vm_syms())
	if r.has("error"):
		return r
	return {"vm_init": r.labels.vm_init, "vm_update": r.labels.vm_update, "vm_free": r.labels.vm_free,
		"addr": r.addr, "size": r.size, "labels": r.labels}


static func vm_syms() -> Dictionary:
	var s := SYMS.duplicate()
	s["BUDGET"] = ArcadeVM.BUDGET
	s["NOPS"] = ArcadeVM.NOPS
	return s


static func vm_source() -> String:
	var f := ArcadeVM.font()
	var lines := PackedStringArray()
	for i in range(0, 64, 8):
		var row := PackedStringArray()
		for k in 8:
			row.append("0x%04X" % f[i + k])
		lines.append("\t.hword " + ", ".join(row))
	return ArcadeVmAsm.SOURCE.replace("\t; FONT\n", "\n".join(lines) + "\n")


## Game block of a compiled program at address `g` (layout: VM_ASM header comment).
static func game_block(prog: Dictionary, g: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(BLOCK_VARS + 4 * ArcadeVM.NVARS)
	var spr := g + b.size()
	b.append_array(prog.sprites)
	while b.size() % 4:
		b.append(0)
	var code := g + b.size()
	b.append_array(prog.code)
	b.encode_u32(0x00, code)
	b.encode_u32(0x04, spr)
	b.encode_u16(0x08, prog.init)
	b.encode_u16(0x0A, prog.frame)
	b.encode_u16(0x0C, prog.nsprites)
	for i in 4:
		b.encode_u16(0x10 + 2 * i, prog.palette[i])
		b.encode_u16(0x18 + 2 * i, prog.palette[i])
	for i in ArcadeVM.NVARS:
		b.encode_s32(BLOCK_VARS + 4 * i, prog.vars[i])
	return b


## A script game: compile, game block, thunks. {init, update, free, block, size} or {error}.
static func install_script_game(m: Arm9Mod, vm: Dictionary, src: String) -> Dictionary:
	var prog := ArcadeScript.compile(src)
	if prog.has("error"):
		return {"error": "line %d: %s" % [prog.line, prog.error]}
	var size := game_block(prog, 0).size()
	var g := m.alloc(size)
	if g == 0:
		return {"error": m.error}
	m.write(g, game_block(prog, g))
	var syms := {"G": g, "VM_INIT": vm.vm_init, "VM_UPDATE": vm.vm_update, "VM_FREE": vm.vm_free}
	var r := assemble_at(m, THUNKS, syms)
	if r.has("error"):
		return r
	return {"init": r.labels.init, "update": r.labels.update, "free": r.labels.free, "block": g, "size": size}


const BLOCK_VARS := 0x30

const THUNKS := """
init:
	ldr r2, =G
	b VM_INIT
update:
	ldr r0, =G
	b VM_UPDATE
free:
	ldr r0, =G
	b VM_FREE
	.pool
"""


## Test card ("mire"): animated colour checker, white border, colours inverted while a key is held.
const TEST_CARD := """
; ArcadeExt test card. Screen: 128x128, 2 bpp, 32 bytes per row, pixel x = bits (x & 3) * 2 of byte y*32 + x/4.
init:                       ; r0 = cabinet actor, r1 = 1 for the attract screen
	push {r4, lr}
	sub sp, sp, #8
	ldr r4, =state
	str r0, [r4]            ; actor
	mov r0, #0
	str r0, [r4, #8]        ; frame
	mov r0, #SCREEN_SIZE
	mov r1, #3
	mov r2, #4
	bl ALLOC
	str r0, [r4, #4]        ; screen buffer
	mov r1, #0
	mov r2, #SCREEN_SIZE
	bl MEMSET
	mov r0, #0
	str r0, [sp]
	str r0, [sp, #4]
	ldr r0, [r4]
	add r0, r0, #MODEL
	mov r1, #1
	ldr r2, =palette
	mov r3, #8
	bl UPLOAD_PAL
	add sp, sp, #8
	pop {r4, pc}

update:
	push {r4-r10, lr}
	sub sp, sp, #8
	ldr r4, =state
	ldr r5, [r4, #8]
	add r5, r5, #1
	str r5, [r4, #8]        ; frame + 1
	ldr r6, [r4, #4]        ; write pointer
	ldr r0, =KEYS
	ldr r0, [r0]
	ldrh r9, [r0, #2]       ; held keys
	mov r10, #0x55
	mov r7, #0              ; y
yloop:
	mov r8, #0              ; x / 4
xloop:
	mov r0, r8, lsr #2      ; colour = (x/16 + y/16 + frame/8) & 3
	add r0, r0, r7, lsr #4
	add r0, r0, r5, lsr #3
	and r0, r0, #3
	cmp r9, #0
	eorne r0, r0, #3        ; a key held: inverted
	cmp r7, #4              ; 4-pixel border in colour 3
	movlo r0, #3
	cmp r7, #124
	movhs r0, #3
	cmp r8, #1
	movlo r0, #3
	cmp r8, #31
	movhs r0, #3
	mul r1, r0, r10         ; 4 pixels of the same colour
	strb r1, [r6], #1
	add r8, r8, #1
	cmp r8, #32
	blt xloop
	add r7, r7, #1
	cmp r7, #128
	blt yloop
	mov r0, #0
	str r0, [sp]
	ldr r0, [r4]
	add r0, r0, #MODEL
	mov r1, #1
	ldr r2, [r4, #4]
	mov r3, #SCREEN_SIZE
	bl UPLOAD_TEX
	add sp, sp, #8
	pop {r4-r10, pc}

free:
	push {r4, lr}
	ldr r4, =state
	ldr r0, [r4, #4]
	cmp r0, #0
	blne FREE
	mov r0, #0
	str r0, [r4, #4]
	pop {r4, pc}

	.pool
palette:
	.hword 0x0000, 0x001F, 0x03E0, 0x7FFF   ; black, red, green, white (RGB555)
state:
	.word 0, 0, 0                           ; actor, buffer, frame
"""
