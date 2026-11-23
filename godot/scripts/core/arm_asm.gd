class_name ArmAsm
extends RefCounted
## Small two-pass ARM (ARMv5TE, ARM state only) assembler for code placed in the ARM9 extension.
##
##   var a := ArmAsm.new()
##   var bin := a.assemble(source, 0x02153000, {"ALLOC": 0x02046880})   # empty + a.error on failure
##   a.labels["name"] -> address
##
## Syntax (GNU-like, pre-UAL and UAL suffix order both accepted for conditions):
##   label:            ; comment   @ comment   // comment
##   mov/mvn/add/adc/sub/sbc/rsb/rsc/and/orr/eor/bic{cond}{s} rd, rn, op2   (op2 = #expr | rm | rm, lsl #n | rm, lsl rs)
##   cmp/cmn/tst/teq{cond} rn, op2     lsl/lsr/asr/ror{cond}{s} rd, rm, #n|rs
##   mul/mla, umull/smull/umlal/smlal, clz
##   ldr/str/ldrb/strb{cond} rd, [rn] | [rn, #e] | [rn, #e]! | [rn], #e | [rn, {-}rm{, lsl #n}] | =expr | label
##   ldrh/strh/ldrsb/ldrsh{cond} rd, [rn] | [rn, #e] | [rn, {-}rm] (+ ! and post-index)
##   ldm/stm{ia|ib|da|db|fd|ed|fa|ea}{cond} rn{!}, {r0-r3, lr}     push/pop {list}
##   b/bl{cond} label|expr    bx/blx{cond} rm    blx label|expr    adr{cond} rd, label    nop
##   .word e, ...  .hword e, ...  .byte e, ...  .ascii "s"  .asciz "s"  .space n  .align n (bytes)  .pool / .ltorg
##   .equ name, expr
## Immediates that do not fit an operand2 switch to the complementary opcode (mov<->mvn, add<->sub, cmp<->cmn,
## and<->bic) when that one fits. `ldr rd, =expr` puts the value in the next literal pool (.pool, or the end).
## Expressions: numbers (dec, 0x, 0b, 'c'), symbols, `.` (current address), + - * << >> & | and parentheses.

const CONDS := {"eq": 0, "ne": 1, "cs": 2, "hs": 2, "cc": 3, "lo": 3, "mi": 4, "pl": 5, "vs": 6, "vc": 7,
	"hi": 8, "ls": 9, "ge": 10, "lt": 11, "gt": 12, "le": 13, "al": 14}
const DP := {"and": 0, "eor": 1, "sub": 2, "rsb": 3, "add": 4, "adc": 5, "sbc": 6, "rsc": 7, "tst": 8, "teq": 9,
	"cmp": 10, "cmn": 11, "orr": 12, "mov": 13, "bic": 14, "mvn": 15}
const SHIFTS := {"lsl": 0, "asl": 0, "lsr": 1, "asr": 2, "ror": 3}
const REGS := {"sp": 13, "lr": 14, "pc": 15, "ip": 12, "fp": 11, "sl": 10, "sb": 9}
const LDM_MODES := {"ia": 1, "ib": 3, "da": 0, "db": 2}   # bit 24 P, bit 23 U  -> (P << 1) | U
const LDM_STACK := {"fd": ["ia", "db"], "ed": ["ib", "da"], "fa": ["da", "ib"], "ea": ["db", "ia"]}  # [ldm, stm]
# base mnemonics, longest first (a mnemonic is base + suffix; the first base whose suffix parses wins)
const BASES := ["ldrsb", "ldrsh", "umull", "smull", "umlal", "smlal", "ldrb", "ldrh", "strb", "strh", "push",
	"pop", "and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", "tst", "teq", "cmp", "cmn", "orr", "mov", "bic",
	"mvn", "mul", "mla", "clz", "ldr", "str", "ldm", "stm", "lsl", "lsr", "asr", "ror", "adr", "nop", "blx", "bx", "bl", "b"]

var error := ""
var labels := {}
var _syms := {}
var _pc := 0
var _pass := 1
var _pools := []        # per pool: Array of expression strings (deduped), in order
var _pool_addr := []    # per pool: address of its first word (pass 2)
var _pool_i := 0        # current pool index


## Machine code for `src` loaded at `base`. `syms`: external names (function addresses, constants).
func assemble(src: String, base: int, syms := {}) -> PackedByteArray:
	error = ""
	labels = {}
	_syms = syms
	var lines := _clean(src)
	var out := PackedByteArray()
	for p in [1, 2]:
		_pass = p
		_pc = base
		_pool_i = 0
		if p == 1:
			_pools = [[]]
			_pool_addr = []
		out = PackedByteArray()
		for ln in lines:
			var r := _line(ln[1], out)
			if r != "":
				error = "line %d: %s  (%s)" % [ln[0], r, ln[1]]
				return PackedByteArray()
		var r2 := _flush_pool(out)
		if r2 != "":
			error = r2
			return PackedByteArray()
	return out


func _clean(src: String) -> Array:
	var out := []
	var n := 0
	for raw in src.split("\n"):
		n += 1
		var s := raw
		var in_str := false
		for i in s.length():
			var c := s[i]
			if c == '"':
				in_str = not in_str
			elif not in_str and (c == ";" or c == "@" or (c == "/" and i + 1 < s.length() and s[i + 1] == "/")):
				s = s.substr(0, i)
				break
		s = s.strip_edges()
		if s != "":
			out.append([n, s])
	return out


func _emit(out: PackedByteArray, w: int) -> void:
	var i := out.size()
	out.resize(i + 4)
	out.encode_u32(i, w & 0xFFFFFFFF)
	_pc += 4


func _line(s: String, out: PackedByteArray) -> String:
	# labels (several allowed on one line)
	while true:
		var m := _label_re().search(s)
		if m == null:
			break
		var name := m.get_string(1)
		if _pass == 1:
			if labels.has(name):
				return "label '%s' defined twice" % name
			labels[name] = _pc
		elif labels[name] != _pc:
			return "internal: label '%s' moved between passes" % name
		s = s.substr(m.get_end()).strip_edges()
	if s == "":
		return ""
	var sp := s.find(" ")
	var mn := (s if sp < 0 else s.substr(0, sp)).to_lower()
	var args := "" if sp < 0 else s.substr(sp + 1).strip_edges()
	if mn.begins_with("."):
		return _directive(mn, args, out)
	for b in BASES:
		if mn.begins_with(b):
			var r = _instr(b, mn.substr(b.length()), args, out)
			if r != null:
				return r
	return "unknown instruction '%s'" % mn


static var _lre: RegEx
static func _label_re() -> RegEx:
	if _lre == null:
		_lre = RegEx.new()
		_lre.compile("^([A-Za-z_.$][A-Za-z0-9_.$]*):")
	return _lre


# --- directives ---------------------------------------------------------------------------------------------------

func _directive(mn: String, args: String, out: PackedByteArray) -> String:
	match mn:
		".word", ".hword", ".short", ".byte":
			var n := 4 if mn == ".word" else (1 if mn == ".byte" else 2)
			for e in _split(args):
				var v = _eval(e)
				if v is String:
					return v
				var i := out.size()
				out.resize(i + n)
				if n == 4:
					out.encode_u32(i, v & 0xFFFFFFFF)
				elif n == 2:
					out.encode_u16(i, v & 0xFFFF)
				else:
					out[i] = v & 0xFF
				_pc += n
			return ""
		".ascii", ".asciz":
			if not (args.begins_with('"') and args.ends_with('"')):
				return "string expected"
			var b := args.substr(1, args.length() - 2).c_unescape().to_utf8_buffer()
			if mn == ".asciz":
				b.append(0)
			out.append_array(b)
			_pc += b.size()
			return ""
		".space", ".skip":
			var v = _eval(args)
			if v is String:
				return v
			out.resize(out.size() + v)
			_pc += v
			return ""
		".align", ".balign":
			var v = _eval(args) if args != "" else 4
			if v is String:
				return v
			while _pc % v:
				out.append(0)
				_pc += 1
			return ""
		".pool", ".ltorg":
			return _flush_pool(out)
		".equ", ".set":
			var p := _split(args)
			if p.size() != 2:
				return ".equ name, value"
			var v = _eval(p[1])
			if v is String:
				return v
			_syms[p[0]] = v
			return ""
	return "unknown directive " + mn


func _flush_pool(out: PackedByteArray) -> String:
	while _pc % 4:
		out.append(0)
		_pc += 1
	var pool: Array = _pools[_pool_i]
	if _pass == 1:
		_pool_addr.append(_pc)
		_pools.append([])
	for e in pool:
		var v = 0
		if _pass == 2:
			v = _eval(e)
			if v is String:
				return v
		_emit(out, v)
	_pool_i += 1
	return ""


## Address of the literal for expression `e` (pass 2), registering it in the current pool (pass 1).
func _literal(e: String) -> int:
	var pool: Array = _pools[_pool_i]
	if _pass == 1:
		if not pool.has(e):
			pool.append(e)
		return 0
	return _pool_addr[_pool_i] + 4 * pool.find(e)


# --- expressions --------------------------------------------------------------------------------------------------

func _split(s: String) -> Array:
	var out := []
	var depth := 0
	var cur := ""
	for c in s:
		if c in "([{":
			depth += 1
		elif c in ")]}":
			depth -= 1
		if c == "," and depth == 0:
			out.append(cur.strip_edges())
			cur = ""
		else:
			cur += c
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out


## int, or a String error. Unknown symbols are 0 in pass 1.
func _eval(e: String):
	var toks = _tokens(e)
	if toks is String:
		return toks
	var st := {"t": toks, "i": 0}
	var v = _ex_or(st)
	if v is String:
		return v
	if st.i != toks.size():
		return "bad expression '%s'" % e
	return v


func _tokens(e: String):
	var out := []
	var i := 0
	while i < e.length():
		var c := e[i]
		if c == " " or c == "\t":
			i += 1
		elif c == "<" or c == ">":
			if i + 1 < e.length() and e[i + 1] == c:
				out.append(c + c)
				i += 2
			else:
				return "bad operator in '%s'" % e
		elif c in "+-*&|()~":
			out.append(c)
			i += 1
		elif c == "'":
			if i + 2 >= e.length() or e[i + 2] != "'":
				return "bad character constant"
			out.append(e.unicode_at(i + 1))
			i += 3
		else:
			var j := i
			while j < e.length() and not (e[j] in " \t+-*&|()<>~'"):
				j += 1
			var w := e.substr(i, j - i)
			i = j
			if w.is_valid_int():
				out.append(w.to_int())
			elif w.to_lower().begins_with("0x") and w.substr(2).is_valid_hex_number():
				out.append(w.substr(2).hex_to_int())
			elif w.to_lower().begins_with("0b"):
				out.append(w.substr(2).bin_to_int())
			elif w == ".":
				out.append(_pc)
			elif labels.has(w):
				out.append(labels[w])
			elif _syms.has(w):
				out.append(_syms[w])
			elif _pass == 1:
				out.append(0)
			else:
				return "unknown symbol '%s'" % w
	return out


func _peek(st: Dictionary):
	return st.t[st.i] if st.i < st.t.size() else null


func _ex_or(st: Dictionary):
	var a = _ex_and(st)
	while not (a is String) and str(_peek(st)) == "|":
		st.i += 1
		var b = _ex_and(st)
		if b is String:
			return b
		a = a | b
	return a


func _ex_and(st: Dictionary):
	var a = _ex_shift(st)
	while not (a is String) and str(_peek(st)) == "&":
		st.i += 1
		var b = _ex_shift(st)
		if b is String:
			return b
		a = a & b
	return a


func _ex_shift(st: Dictionary):
	var a = _ex_add(st)
	while not (a is String) and str(_peek(st)) in ["<<", ">>"]:
		var op = _peek(st)
		st.i += 1
		var b = _ex_add(st)
		if b is String:
			return b
		a = (a << b) if op == "<<" else (a >> b)
	return a


func _ex_add(st: Dictionary):
	var a = _ex_mul(st)
	while not (a is String) and str(_peek(st)) in ["+", "-"]:
		var op = _peek(st)
		st.i += 1
		var b = _ex_mul(st)
		if b is String:
			return b
		a = (a + b) if op == "+" else (a - b)
	return a


func _ex_mul(st: Dictionary):
	var a = _ex_un(st)
	while not (a is String) and str(_peek(st)) == "*":
		st.i += 1
		var b = _ex_un(st)
		if b is String:
			return b
		a = a * b
	return a


func _ex_un(st: Dictionary):
	var t = _peek(st)
	if t == null:
		return "expression ends too early"
	st.i += 1
	if t is int:
		return t
	match t:
		"-":
			var v = _ex_un(st)
			return v if v is String else -v
		"+":
			return _ex_un(st)
		"~":
			var v = _ex_un(st)
			return v if v is String else (~v) & 0xFFFFFFFF
		"(":
			var v = _ex_or(st)
			if v is String:
				return v
			if str(_peek(st)) != ")":
				return "missing )"
			st.i += 1
			return v
	return "unexpected '%s'" % str(t)


# --- operands -----------------------------------------------------------------------------------------------------

static func reg(s: String) -> int:
	s = s.strip_edges().to_lower()
	if REGS.has(s):
		return REGS[s]
	if s.begins_with("r") and s.substr(1).is_valid_int():
		var n := s.substr(1).to_int()
		if n >= 0 and n <= 15:
			return n
	return -1


## Rotated 8-bit immediate encoding of v, or -1.
static func imm8r(v: int) -> int:
	v &= 0xFFFFFFFF
	for rot in 16:
		var r := ((v << (2 * rot)) | (v >> (32 - 2 * rot))) & 0xFFFFFFFF if rot else v
		if r <= 0xFF:
			return (rot << 8) | r
	return -1


## Parse `#imm`, `rm`, `rm, <shift> #n` or `rm, <shift> rs` from parts. [is_imm, value_or_field] or String error.
func _op2(parts: Array):
	if parts.is_empty():
		return "operand missing"
	var p0: String = parts[0]
	if p0.begins_with("#"):
		if parts.size() != 1:
			return "extra operands"
		var v = _eval(p0.substr(1))
		if v is String:
			return v
		return [true, v]
	var rm := reg(p0)
	if rm < 0:
		return "register expected, got '%s'" % p0
	if parts.size() == 1:
		return [false, rm]
	if parts.size() != 2:
		return "extra operands"
	return _shifted(rm, parts[1])


func _shifted(rm: int, sh: String):
	sh = sh.strip_edges()
	var sp := sh.find(" ")
	if sh.to_lower() == "rrx":
		return [false, (3 << 5) | rm]
	if sp < 0:
		return "bad shift '%s'" % sh
	var t := sh.substr(0, sp).to_lower()
	if not SHIFTS.has(t):
		return "bad shift '%s'" % sh
	var arg := sh.substr(sp + 1).strip_edges()
	if arg.begins_with("#"):
		var n = _eval(arg.substr(1))
		if n is String:
			return n
		if n == 0:
			return [false, rm]
		if n < 0 or n > 32 or (n == 32 and SHIFTS[t] in [0, 3]):
			return "shift amount out of range"
		return [false, ((n & 31) << 7) | (SHIFTS[t] << 5) | rm]
	var rs := reg(arg)
	if rs < 0:
		return "bad shift amount '%s'" % arg
	return [false, (rs << 8) | (SHIFTS[t] << 5) | 0x10 | rm]


## Condition + flags suffix: [cond, rest] where rest is what is left after removing a condition (either order).
func _cond_split(suf: String, allowed: Array) -> Array:
	# allowed: extra suffixes accepted besides the condition ("" always ok), e.g. ["s"]
	for extra in allowed:
		for order in [0, 1]:
			var c := ""
			if order == 0 and suf.begins_with(extra):
				c = suf.substr(extra.length())
			elif order == 1 and suf.ends_with(extra):
				c = suf.substr(0, suf.length() - extra.length())
			else:
				continue
			if c == "":
				return [14, extra]
			if CONDS.has(c):
				return [CONDS[c], extra]
	return []


# --- instructions -------------------------------------------------------------------------------------------------

## null = this base does not match the suffix (try the next one), "" = ok, else an error.
func _instr(base: String, suf: String, args: String, out: PackedByteArray):
	var ops := _split(args)
	if DP.has(base):
		var cs := _cond_split(suf, ["s", ""])
		if cs.is_empty():
			return null
		return _dp(base, cs[0], cs[1] == "s", ops, out)
	if base in ["lsl", "lsr", "asr", "ror"]:
		var cs := _cond_split(suf, ["s", ""])
		if cs.is_empty():
			return null
		if ops.size() != 3:
			return "%s rd, rm, #n|rs" % base
		return _dp("mov", cs[0], cs[1] == "s", [ops[0], ops[1], base + " " + ops[2]], out)
	match base:
		"nop":
			if suf != "":
				return null
			_emit(out, 0xE1A00000)
			return ""
		"b", "bl":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			if ops.size() != 1:
				return "one target expected"
			var t = _eval(ops[0])
			if t is String:
				return t
			var off: int = t - (_pc + 8)
			if _pass == 2 and (off & 3 or off < -0x2000000 or off >= 0x2000000):
				return "branch target out of range / misaligned"
			_emit(out, (cs[0] << 28) | (0x0B000000 if base == "bl" else 0x0A000000) | ((off >> 2) & 0xFFFFFF))
			return ""
		"bx", "blx":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			if ops.size() != 1:
				return "one operand expected"
			var rm := reg(ops[0])
			if rm >= 0:
				_emit(out, (cs[0] << 28) | (0x012FFF30 if base == "blx" else 0x012FFF10) | rm)
				return ""
			if base == "bx" or cs[0] != 14:
				return "register expected"
			var t = _eval(ops[0])     # blx imm: switch to Thumb
			if t is String:
				return t
			var off: int = t - (_pc + 8)
			_emit(out, 0xFA000000 | (((off >> 1) & 1) << 24) | ((off >> 2) & 0xFFFFFF))
			return ""
		"mul", "mla":
			var cs := _cond_split(suf, ["s", ""])
			if cs.is_empty():
				return null
			var n := 3 if base == "mul" else 4
			if ops.size() != n:
				return "%d registers expected" % n
			var r := []
			for o in ops:
				r.append(reg(o))
				if r[-1] < 0:
					return "register expected, got '%s'" % o
			var w: int = (cs[0] << 28) | (0x00100000 if cs[1] == "s" else 0) | (r[0] << 16) | (r[2] << 8) | 0x90 | r[1]
			if base == "mla":
				w |= 0x00200000 | (r[3] << 12)
			_emit(out, w)
			return ""
		"umull", "smull", "umlal", "smlal":
			var cs := _cond_split(suf, ["s", ""])
			if cs.is_empty():
				return null
			if ops.size() != 4:
				return "rdlo, rdhi, rm, rs expected"
			var r := []
			for o in ops:
				r.append(reg(o))
				if r[-1] < 0:
					return "register expected, got '%s'" % o
			var op := {"umull": 0x00800090, "umlal": 0x00A00090, "smull": 0x00C00090, "smlal": 0x00E00090}[base] as int
			_emit(out, (cs[0] << 28) | op | (0x00100000 if cs[1] == "s" else 0) | (r[1] << 16) | (r[0] << 12) | (r[3] << 8) | r[2])
			return ""
		"clz":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			if ops.size() != 2 or reg(ops[0]) < 0 or reg(ops[1]) < 0:
				return "clz rd, rm"
			_emit(out, (cs[0] << 28) | 0x016F0F10 | (reg(ops[0]) << 12) | reg(ops[1]))
			return ""
		"adr":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			if ops.size() != 2 or reg(ops[0]) < 0:
				return "adr rd, label"
			var t = _eval(ops[1])
			if t is String:
				return t
			var off: int = t - (_pc + 8)
			var enc := imm8r(abs(off))
			if _pass == 2 and enc < 0:
				return "adr target too far"
			_emit(out, (cs[0] << 28) | (0x02800000 if off >= 0 else 0x02400000) | (15 << 16) | (reg(ops[0]) << 12) | max(enc, 0))
			return ""
		"push", "pop":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			var l = _reglist(args)
			if l is String:
				return l
			_emit(out, (cs[0] << 28) | (0x092D0000 if base == "push" else 0x08BD0000) | l)
			return ""
		"ldm", "stm":
			return _ldm(base, suf, ops, args, out)
		"ldr", "str", "ldrb", "strb":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				# pre-UAL ldreqb / streqb
				if suf.ends_with("b") and base.length() == 3:
					cs = _cond_split(suf.substr(0, suf.length() - 1), [""])
					if cs.is_empty():
						return null
					base += "b"
				else:
					return null
			return _ldr(base, cs[0], ops, out)
		"ldrh", "strh", "ldrsb", "ldrsh":
			var cs := _cond_split(suf, [""])
			if cs.is_empty():
				return null
			return _ldrh(base, cs[0], ops, out)
	return null


func _dp(base: String, cond: int, s: bool, ops: Array, out: PackedByteArray) -> String:
	var opc: int = DP[base]
	var test := opc >= 8 and opc <= 11
	var single := base in ["mov", "mvn"]
	var rd := 0
	var rn := 0
	var rest: Array
	if test:
		if ops.size() < 2:
			return "%s rn, op2" % base
		rn = reg(ops[0])
		rest = ops.slice(1)
		s = true
	elif single:
		if ops.size() < 2:
			return "%s rd, op2" % base
		rd = reg(ops[0])
		rest = ops.slice(1)
	else:
		if ops.size() < 2:
			return "%s rd, rn, op2" % base
		rd = reg(ops[0])
		if ops.size() == 2:          # add rd, op2  ==  add rd, rd, op2
			rn = rd
			rest = ops.slice(1)
		else:
			rn = reg(ops[1])
			rest = ops.slice(2)
	if rd < 0 or rn < 0:
		return "register expected"
	var o = _op2(rest)
	if o is String:
		return o
	var w := (cond << 28) | (0x00100000 if s else 0) | (rn << 16) | (rd << 12)
	if o[0]:
		var v: int = o[1] & 0xFFFFFFFF
		var enc := imm8r(v)
		if enc < 0:
			var alt := {13: [15, ~v], 15: [13, ~v], 4: [2, -v], 2: [4, -v], 10: [11, -v], 11: [10, -v], 0: [14, ~v], 14: [0, ~v]}
			if alt.has(opc):
				var e2 := imm8r(alt[opc][1] & 0xFFFFFFFF)
				if e2 >= 0:
					opc = alt[opc][0]
					enc = e2
		if enc < 0:
			if _pass == 1:
				enc = 0
			else:
				return "immediate 0x%X does not fit an operand2 (use ldr =)" % v
		w |= 0x02000000 | (opc << 21) | enc
	else:
		w |= (opc << 21) | o[1]
	_emit(out, w)
	return ""


func _reglist(s: String):
	s = s.strip_edges()
	if not (s.begins_with("{") and s.ends_with("}")):
		return "register list {..} expected"
	var mask := 0
	for part in s.substr(1, s.length() - 2).split(","):
		part = part.strip_edges()
		var d := part.find("-")
		if d > 0:
			var a := reg(part.substr(0, d))
			var b := reg(part.substr(d + 1))
			if a < 0 or b < a:
				return "bad register range '%s'" % part
			for r in range(a, b + 1):
				mask |= 1 << r
		else:
			var r := reg(part)
			if r < 0:
				return "bad register '%s'" % part
			mask |= 1 << r
	return mask


func _ldm(base: String, suf: String, ops: Array, args: String, out: PackedByteArray):
	var mode := "ia"
	var c := suf
	for m in ["ia", "ib", "da", "db", "fd", "ed", "fa", "ea"]:
		if suf.begins_with(m) or suf.ends_with(m):
			mode = m
			c = suf.substr(2) if suf.begins_with(m) else suf.substr(0, suf.length() - 2)
			break
	var cs := _cond_split(c, [""])
	if cs.is_empty():
		return null
	if LDM_STACK.has(mode):
		mode = LDM_STACK[mode][0 if base == "ldm" else 1]
	var b := args.find("{")
	if b < 0:
		return "register list expected"
	var rn_s := args.substr(0, b).strip_edges().trim_suffix(",").strip_edges()
	var wb := rn_s.ends_with("!")
	var rn := reg(rn_s.trim_suffix("!"))
	if rn < 0:
		return "base register expected"
	var l = _reglist(args.substr(b))
	if l is String:
		return l
	var pu: int = LDM_MODES[mode]
	_emit(out, (cs[0] << 28) | 0x08000000 | (pu << 23) | (0x00200000 if wb else 0) | (0x00100000 if base == "ldm" else 0) | (rn << 16) | l)
	return ""


## [rn, p, u, w, kind, value]: kind "imm" (value = offset) or "reg" (value = shifted rm field). String = error.
func _addr(ops: Array):
	var s: String = ops[1]
	if not s.begins_with("["):
		return "[address] expected"
	var post := ops.size() > 2
	var inner: String
	var wb := false
	if post:
		if not s.ends_with("]"):
			return "bad address"
		inner = s.substr(1, s.length() - 2)
	else:
		if s.ends_with("]!"):
			wb = true
			inner = s.substr(1, s.length() - 3)
		elif s.ends_with("]"):
			inner = s.substr(1, s.length() - 2)
		else:
			return "bad address"
	var parts := _split(inner)
	var rn := reg(parts[0])
	if rn < 0:
		return "base register expected"
	var rest: Array = ops.slice(2) if post else parts.slice(1)
	if rest.is_empty():
		return [rn, 1, 1, 0, "imm", 0]
	var r0: String = rest[0]
	if r0.begins_with("#"):
		if rest.size() != 1:
			return "extra operands"
		var v = _eval(r0.substr(1))
		if v is String:
			return v
		return [rn, 0 if post else 1, 1 if v >= 0 else 0, 0 if post else int(wb), "imm", abs(v)]
	var u := 1
	if r0.begins_with("-"):
		u = 0
		r0 = r0.substr(1)
	elif r0.begins_with("+"):
		r0 = r0.substr(1)
	var rm := reg(r0)
	if rm < 0:
		return "offset register expected, got '%s'" % r0
	var field := rm
	if rest.size() == 2:
		var sh = _shifted(rm, rest[1])
		if sh is String:
			return sh
		field = sh[1]
		if field & 0x10:
			return "register-shifted offsets are not allowed"
	elif rest.size() > 2:
		return "extra operands"
	return [rn, 0 if post else 1, u, 0 if post else int(wb), "reg", field]


func _ldr(base: String, cond: int, ops: Array, out: PackedByteArray):
	if ops.size() < 2:
		return "%s rd, address" % base
	var rd := reg(ops[0])
	if rd < 0:
		return "register expected, got '%s'" % ops[0]
	var load := base.begins_with("ldr")
	var byte := base.ends_with("b")
	var w := (cond << 28) | 0x04000000 | (0x00100000 if load else 0) | (0x00400000 if byte else 0) | (rd << 12)
	var a0: String = ops[1]
	if a0.begins_with("="):
		if not load or byte:
			return "=literal only with ldr"
		var la := _literal(a0.substr(1).strip_edges())
		return _pcrel(w, la, out)
	if not a0.begins_with("["):
		var t = _eval(a0)       # ldr rd, label
		if t is String:
			return t
		return _pcrel(w, t, out)
	var a = _addr(ops)
	if a is String:
		return a
	if a[4] == "imm":
		if a[5] > 0xFFF:
			return "offset out of range (±4095)"
		w |= a[5]
	else:
		w |= 0x02000000 | a[5]
	_emit(out, w | (a[0] << 16) | (a[1] << 24) | (a[2] << 23) | (a[3] << 21))
	return ""


func _pcrel(w: int, target: int, out: PackedByteArray) -> String:
	var off := target - (_pc + 8)
	if _pass == 2 and abs(off) > 0xFFF:
		return "literal / label too far (%d bytes): add a .pool closer" % off
	_emit(out, w | (15 << 16) | (1 << 24) | ((1 << 23) if off >= 0 else 0) | (abs(off) & 0xFFF))
	return ""


func _ldrh(base: String, cond: int, ops: Array, out: PackedByteArray):
	if ops.size() < 2:
		return "%s rd, address" % base
	var rd := reg(ops[0])
	if rd < 0:
		return "register expected"
	var sh := {"ldrh": 0xB0, "strh": 0xB0, "ldrsb": 0xD0, "ldrsh": 0xF0}[base] as int
	var load := base != "strh"
	var a = _addr(ops)
	if a is String:
		return a
	var w: int = (cond << 28) | (0x00100000 if load else 0) | (a[0] << 16) | (rd << 12) | sh | (a[1] << 24) | (a[2] << 23) | (a[3] << 21)
	if a[4] == "imm":
		if a[5] > 0xFF:
			return "offset out of range (±255)"
		w |= 0x00400000 | ((a[5] & 0xF0) << 4) | (a[5] & 0xF)
	else:
		if a[5] > 15:
			return "no shift allowed here"
		w |= a[5]
	_emit(out, w)
	return ""
