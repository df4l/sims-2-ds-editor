class_name ArcadeVM
extends RefCounted
## Arcade VM, reference interpreter (docs/formats/arcade_vm.md). The ARM copy (ArcadeExt.VM_ASM) runs in the game;
## this one runs the in-editor preview and must behave exactly the same (32-bit wrap, truncating division, op budget,
## clipping, font). A program comes from ArcadeScript.compile().

const SCREEN := 128
const NVARS := 256
const CALL_DEPTH := 32
const BUDGET := 30000          # ops per call of init / frame (the ARM copy counts the same way)
const V_ATTRACT := 0           # built-in variables
const V_TICK := 1

# opcodes
enum {
	RET = 0x00, PUSHB, PUSHH, PUSHW, LOAD, STORE, LOADX, STOREX, JMP, JZ, JNZ, CALL, POP, DUP,
	ADD = 0x10, SUB, MUL, DIV, MOD, AND, OR, XOR, SHL, SHR, NEG, NOT, BNOT, EQ, NE, LT, LE, GT, GE,
	CLS = 0x30, SPR, RECT, PIX, TEXT, NUM, SFX, PAL, HELD, PRESSED, RND, ABS, MIN, MAX, HIT, PEEK,
	NOPS = 0x40,
}

## DS keys, as in the game's key struct (+2 held, +6 pressed), CONFIRMED in melonDS.
const KEYS := {"A": 0x1, "B": 0x2, "SELECT": 0x4, "START": 0x8, "RIGHT": 0x10, "LEFT": 0x20, "UP": 0x40,
	"DOWN": 0x80, "R": 0x100, "L": 0x200, "X": 0x400, "Y": 0x800}

## Sound ids of the game's sound player 0x020D5680 (table 0x02136CB8: 672 ids). The arcade games use the block
## 0x1F..0x30 (docs/formats/arcade_vm.md §2b). Names = built-in constants of the language.
const SFX_COUNT := 672
const SFX_LOOPS := [0x22, 0x29, 0x2E]   # cabinet ambience loops (X-Raider, Copter, Sisyphus): never stopped by a game
const SOUNDS := {
	"SFX_BOUNCE": 0x1F, "SFX_LOST": 0x20, "SFX_BLIP": 0x21, "SFX_COPTER": 0x23, "SFX_CATCH": 0x24,
	"SFX_MISS": 0x25, "SFX_LAUNCH": 0x26, "SFX_LASER": 0x27, "SFX_BREAK": 0x28, "SFX_PADDLE": 0x2A,
	"SFX_ENEMY_SHOT": 0x2B, "SFX_EXPLODE": 0x2C, "SFX_SHOOT": 0x2D, "SFX_EXTRA1": 0x2F, "SFX_EXTRA2": 0x30,
	"SFX_COIN": 0x15C, "SFX_CLACK": 0x264}


## True when `sfx id` plays something (other ids are ignored by both VMs).
static func sfx_ok(id: int) -> bool:
	return id >= 0 and id < SFX_COUNT and not SFX_LOOPS.has(id)


## 3×5 font for ASCII 32..95 (lower case is drawn as upper case). Bit (row * 3 + col), col 0 = left.
const FONT_ROWS := {
	"0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
	"2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", ".##", "..#", "###"],
	"4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
	"6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", "..#", ".#.", ".#."],
	"8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "###"],
	"A": [".#.", "#.#", "###", "#.#", "#.#"], "B": ["##.", "#.#", "##.", "#.#", "##."],
	"C": [".##", "#..", "#..", "#..", ".##"], "D": ["##.", "#.#", "#.#", "#.#", "##."],
	"E": ["###", "#..", "##.", "#..", "###"], "F": ["###", "#..", "##.", "#..", "#.."],
	"G": [".##", "#..", "#.#", "#.#", ".##"], "H": ["#.#", "#.#", "###", "#.#", "#.#"],
	"I": ["###", ".#.", ".#.", ".#.", "###"], "J": ["..#", "..#", "..#", "#.#", ".#."],
	"K": ["#.#", "#.#", "##.", "#.#", "#.#"], "L": ["#..", "#..", "#..", "#..", "###"],
	"M": ["#.#", "###", "###", "#.#", "#.#"], "N": ["##.", "#.#", "#.#", "#.#", "#.#"],
	"O": [".#.", "#.#", "#.#", "#.#", ".#."], "P": ["##.", "#.#", "##.", "#..", "#.."],
	"Q": [".#.", "#.#", "#.#", "##.", ".##"], "R": ["##.", "#.#", "##.", "#.#", "#.#"],
	"S": [".##", "#..", ".#.", "..#", "##."], "T": ["###", ".#.", ".#.", ".#.", ".#."],
	"U": ["#.#", "#.#", "#.#", "#.#", "###"], "V": ["#.#", "#.#", "#.#", "#.#", ".#."],
	"W": ["#.#", "#.#", "###", "###", "#.#"], "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
	"Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["###", "..#", ".#.", "#..", "###"],
	"!": [".#.", ".#.", ".#.", "...", ".#."], "\"": ["#.#", "#.#", "...", "...", "..."],
	"#": ["#.#", "###", "#.#", "###", "#.#"], "$": [".##", "##.", ".#.", ".##", "##."],
	"%": ["#.#", "..#", ".#.", "#..", "#.#"], "&": [".#.", "#.#", ".#.", "#.#", ".##"],
	"'": [".#.", ".#.", "...", "...", "..."], "(": ["..#", ".#.", ".#.", ".#.", "..#"],
	")": ["#..", ".#.", ".#.", ".#.", "#.."], "*": ["...", "#.#", ".#.", "#.#", "..."],
	"+": ["...", ".#.", "###", ".#.", "..."], ",": ["...", "...", "...", ".#.", "#.."],
	"-": ["...", "...", "###", "...", "..."], ".": ["...", "...", "...", "...", ".#."],
	"/": ["..#", "..#", ".#.", "#..", "#.."], ":": ["...", ".#.", "...", ".#.", "..."],
	";": ["...", ".#.", "...", ".#.", "#.."], "<": ["..#", ".#.", "#..", ".#.", "..#"],
	"=": ["...", "###", "...", "###", "..."], ">": ["#..", ".#.", "..#", ".#.", "#.."],
	"?": ["##.", "..#", ".#.", "...", ".#."], "@": [".#.", "#.#", "###", "#..", ".##"],
	"[": ["##.", "#..", "#..", "#..", "##."], "\\": ["#..", "#..", ".#.", "..#", "..#"],
	"]": [".##", "..#", "..#", "..#", ".##"], "^": [".#.", "#.#", "...", "...", "..."],
	"_": ["...", "...", "...", "...", "###"],
}

static var _font := PackedInt32Array()


## 64 glyphs (ASCII 32..95) as 15-bit masks.
static func font() -> PackedInt32Array:
	if _font.is_empty():
		_font.resize(64)
		for ch in FONT_ROWS:
			var rows: Array = FONT_ROWS[ch]
			var g := 0
			for r in 5:
				for c in 3:
					if rows[r][c] == "#":
						g |= 1 << (r * 3 + c)
			_font[ch.unicode_at(0) - 32] = g
	return _font


## The font as the ARM copy stores it (64 × u16).
static func font_bytes() -> PackedByteArray:
	var f := font()
	var b := PackedByteArray()
	b.resize(128)
	for i in 64:
		b.encode_u16(2 * i, f[i])
	return b


static func w32(v: int) -> int:
	return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000


## Signed division as the ARM copy does it: truncated, x / 0 = 0, remainder has the sign of the dividend.
static func div(a: int, b: int) -> int:
	if b == 0:
		return 0
	var q := (absi(a) & 0xFFFFFFFF) / (absi(b) & 0xFFFFFFFF)
	return w32(-q if (a < 0) != (b < 0) else q)


static func mod(a: int, b: int) -> int:
	if b == 0:
		return 0
	var r := (absi(a) & 0xFFFFFFFF) % (absi(b) & 0xFFFFFFFF)
	return w32(-r if a < 0 else r)


## Binary / unary operators shared with the compiler's constant folding.
static func binop(op: int, a: int, b: int) -> int:
	match op:
		ADD: return w32(a + b)
		SUB: return w32(a - b)
		MUL: return w32(a * b)
		DIV: return div(a, b)
		MOD: return mod(a, b)
		AND: return w32(a & b)
		OR: return w32(a | b)
		XOR: return w32(a ^ b)
		SHL: return w32(a << (b & 31))
		SHR: return a >> (b & 31)
		EQ: return int(a == b)
		NE: return int(a != b)
		LT: return int(a < b)
		LE: return int(a <= b)
		GT: return int(a > b)
		GE: return int(a >= b)
		MIN: return mini(a, b)
		MAX: return maxi(a, b)
	return 0


static func unop(op: int, a: int) -> int:
	match op:
		NEG: return w32(-a)
		NOT: return int(a == 0)
		BNOT: return w32(~a)
		ABS: return w32(absi(a))
	return 0


# --- machine ----------------------------------------------------------------------------------------------------------
var code := PackedByteArray()
var sprites := PackedByteArray()
var nsprites := 0
var init_entry := 0
var frame_entry := 0
var pal_start := PackedInt32Array([0, 0, 0, 0])
var pal := PackedInt32Array([0, 0, 0, 0])
var vars := PackedInt32Array()
var screen := PackedByteArray()
var held := 0
var pressed := 0
var sounds: Array = []          # sfx ids played during the last call (preview: shown, not played)
var stopped := ""               # why the last call stopped early ("" = normal end)
var ops := 0                    # ops run by the last call
var _scale := 1
var rng := RandomNumberGenerator.new()


## Load a compiled program (ArcadeScript.compile) and reset the machine as at boot.
func load(prog: Dictionary) -> void:
	code = prog.code
	sprites = prog.sprites
	nsprites = prog.nsprites
	init_entry = prog.init
	frame_entry = prog.frame
	pal_start = PackedInt32Array(prog.palette)
	pal = pal_start.duplicate()
	vars = PackedInt32Array(prog.vars)
	screen = PackedByteArray()
	screen.resize(SCREEN * SCREEN / 4)


## Init(actor, attract): clear screen, palette as at start, run the init entry.
func start(attract: bool) -> void:
	vars[V_ATTRACT] = int(attract)
	vars[V_TICK] = 0
	screen.fill(0)
	pal = pal_start.duplicate()
	_run(init_entry)


## Update(): one frame (30 Hz in the game).
func frame(keys_held := 0, keys_pressed := 0) -> void:
	held = keys_held
	pressed = keys_pressed
	_run(frame_entry)
	vars[V_TICK] = w32(vars[V_TICK] + 1)


func pixel(x: int, y: int) -> int:
	return (screen[y * 32 + (x >> 2)] >> ((x & 3) * 2)) & 3


static func rgb555(c: int) -> Color:
	return Color8(((c & 31) * 255) / 31, (((c >> 5) & 31) * 255) / 31, (((c >> 10) & 31) * 255) / 31)


func image() -> Image:
	var img := Image.create(SCREEN, SCREEN, false, Image.FORMAT_RGB8)
	var cols := [rgb555(pal[0]), rgb555(pal[1]), rgb555(pal[2]), rgb555(pal[3])]
	for y in SCREEN:
		for x in SCREEN:
			img.set_pixel(x, y, cols[pixel(x, y)])
	return img


func _u16(p: int) -> int:
	return code[p] | (code[p + 1] << 8)


func _run(entry: int) -> void:
	sounds.clear()
	stopped = ""
	var st := PackedInt32Array()
	var calls: Array[int] = []
	var pc := entry
	var budget := BUDGET
	ops = 0
	while true:
		budget -= 1
		if budget == 0:
			stopped = "op budget (%d) exceeded" % BUDGET
			return
		if pc < 0 or pc >= code.size():
			stopped = "pc out of the code (%d)" % pc
			return
		var op := code[pc]
		pc += 1
		ops += 1
		match op:
			RET:
				if calls.is_empty():
					return
				pc = calls.pop_back()
			PUSHB:
				st.append(code.decode_s8(pc))
				pc += 1
			PUSHH:
				st.append(code.decode_s16(pc))
				pc += 2
			PUSHW:
				st.append(code.decode_s32(pc))
				pc += 4
			LOAD:
				st.append(vars[code[pc]])
				pc += 1
			STORE:
				vars[code[pc]] = _pop(st)
				pc += 1
			LOADX:
				var i := _pop(st)
				st.append(vars[code[pc] + i] if i >= 0 and i < code[pc + 1] else 0)
				pc += 2
			STOREX:
				var v := _pop(st)
				var i := _pop(st)
				if i >= 0 and i < code[pc + 1]:
					vars[code[pc] + i] = v
				pc += 2
			JMP:
				pc = _u16(pc)
			JZ:
				pc = _u16(pc) if _pop(st) == 0 else pc + 2
			JNZ:
				pc = _u16(pc) if _pop(st) != 0 else pc + 2
			CALL:
				if calls.size() >= CALL_DEPTH:
					stopped = "call depth (%d) exceeded" % CALL_DEPTH
					return
				calls.append(pc + 2)
				pc = _u16(pc)
			POP:
				_pop(st)
			DUP:
				st.append(st[st.size() - 1])
			ADD, SUB, MUL, DIV, MOD, AND, OR, XOR, SHL, SHR, EQ, NE, LT, LE, GT, GE, MIN, MAX:
				var b := _pop(st)
				var a := _pop(st)
				st.append(binop(op, a, b))
			NEG, NOT, BNOT, ABS:
				st.append(unop(op, _pop(st)))
			CLS:
				screen.fill((_pop(st) & 3) * 0x55)
			SPR:
				var a := _popn(st, 4)
				if a[0] >= 0 and a[0] < nsprites:
					_sprite(a[0] * 32, a[1], a[2], a[3])
			RECT:
				var a := _popn(st, 5)
				_fill(a[0], a[1], a[2], a[3], a[4] & 3)
			PIX:
				var a := _popn(st, 3)
				_plot(a[0], a[1], a[2] & 3)
			TEXT:
				var a := _popn(st, 4)
				_set_scale(a[3])
				var n := code[pc]
				_text(a[0], a[1], code.slice(pc + 1, pc + 1 + n), a[2] & 3)
				pc += 1 + n
			NUM:
				var a := _popn(st, 5)
				_set_scale(a[4])
				_text(a[1], a[2], _digits(a[0]), a[3] & 3)
			SFX:
				var id: int = _pop(st)
				if sfx_ok(id):
					sounds.append(id)
			PAL:
				var a := _popn(st, 2)
				pal[a[0] & 3] = a[1] & 0xFFFF
			HELD:
				st.append(_pop(st) & held)
			PRESSED:
				st.append(_pop(st) & pressed)
			RND:
				var n := _pop(st)
				st.append(rng.randi_range(0, n - 1) if n > 0 else 0)
			HIT:
				var a := _popn(st, 8)
				st.append(int(a[0] < w32(a[4] + a[6]) and a[4] < w32(a[0] + a[2])
					and a[1] < w32(a[5] + a[7]) and a[5] < w32(a[1] + a[3])))
			PEEK:
				var a := _popn(st, 2)
				st.append(pixel(a[0], a[1]) if a[0] >= 0 and a[0] < SCREEN and a[1] >= 0 and a[1] < SCREEN else 0)
			_:
				stopped = "bad opcode 0x%02X at %d" % [op, pc - 1]
				return


func _pop(st: PackedInt32Array) -> int:
	var v := st[st.size() - 1]
	st.resize(st.size() - 1)
	return v


func _popn(st: PackedInt32Array, n: int) -> PackedInt32Array:
	var a := st.slice(st.size() - n)
	st.resize(st.size() - n)
	return a


func _set_scale(s: int) -> void:
	_scale = clampi(s, 1, 8)


func _plot(x: int, y: int, c: int) -> void:
	if x < 0 or x >= SCREEN or y < 0 or y >= SCREEN:
		return
	var i := y * 32 + (x >> 2)
	var sh := (x & 3) * 2
	screen[i] = (screen[i] & ~(3 << sh)) | (c << sh)


func _fill(x: int, y: int, w: int, h: int, c: int) -> void:
	var x1 := mini(w32(x + w), SCREEN)
	var y1 := mini(w32(y + h), SCREEN)
	for yy in range(maxi(y, 0), y1):
		for xx in range(maxi(x, 0), x1):
			_plot(xx, yy, c)


func _sprite(at: int, x: int, y: int, flip: int) -> void:
	for r in 8:
		for c in 16:
			var sc := 15 - c if flip & 1 else c
			var sr := 7 - r if flip & 2 else r
			var v := (sprites[at + sr * 4 + (sc >> 2)] >> ((sc & 3) * 2)) & 3
			if v:
				_plot(w32(x + c), w32(y + r), v)


func _digits(v: int) -> PackedByteArray:
	var u := absi(v) & 0xFFFFFFFF
	var s := str(u)
	if v < 0:
		s = "-" + s
	return s.to_ascii_buffer()


func _text(x: int, y: int, chars: PackedByteArray, c: int) -> void:
	var s := _scale
	var f := font()
	var px0 := x
	for ch in chars:
		if ch == 10:
			x = px0
			y = w32(y + 6 * s)
			continue
		var g := ch - 32 if ch < 96 else ch - 64
		if g >= 0 and g < 64:
			var bits := f[g]
			var py := y
			while bits != 0:
				var px := x
				for col in 3:
					if bits & 1:
						_fill(px, py, s, s, c)
					bits >>= 1
					px = w32(px + s)
				py = w32(py + s)
		x = w32(x + 4 * s)
