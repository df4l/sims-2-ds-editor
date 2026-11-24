class_name ArcadeScript
extends RefCounted
## Compiler of the arcade game language to ArcadeVM bytecode (docs/formats/arcade_vm.md).
##
##   compile(src) -> {code, init, frame, sprites, nsprites, palette, vars, names, sprite_names}  or  {error, line}

const V := preload("res://scripts/core/arcade_vm.gd")
const MAX_STACK := 48           # the ARM copy has 64 stack slots
const KEYWORDS := ["var", "keep", "const", "sprite", "palette", "func", "end", "if", "elif", "else", "while", "for",
	"to", "step", "break", "continue", "return", "and", "or", "not", "true", "false"]
# statement commands: name -> [opcode, min args, max args, default of the optional last arg]
const COMMANDS := {"cls": [V.CLS, 1, 1, 0], "spr": [V.SPR, 3, 4, 0], "rect": [V.RECT, 5, 5, 0], "pix": [V.PIX, 3, 3, 0],
	"num": [V.NUM, 4, 5, 1], "sfx": [V.SFX, 1, 1, 0], "pal": [V.PAL, 2, 2, 0]}
# expression functions: name -> [opcode, args]
const FUNCS := {"held": [V.HELD, 1], "pressed": [V.PRESSED, 1], "rnd": [V.RND, 1], "abs": [V.ABS, 1],
	"min": [V.MIN, 2], "max": [V.MAX, 2], "hit": [V.HIT, 8], "peek": [V.PEEK, 2]}
const BINOPS := [  # precedence levels, low to high
	{"|": V.OR, "^": V.XOR, "&": V.AND},
	{"==": V.EQ, "!=": V.NE, "<": V.LT, "<=": V.LE, ">": V.GT, ">=": V.GE},
	{"<<": V.SHL, ">>": V.SHR},
	{"+": V.ADD, "-": V.SUB},
	{"*": V.MUL, "/": V.DIV, "%": V.MOD},
]
const ASSIGN_OPS := {"=": -1, "+=": V.ADD, "-=": V.SUB, "*=": V.MUL, "/=": V.DIV, "%=": V.MOD, "&=": V.AND,
	"|=": V.OR, "^=": V.XOR}

var error := ""
var err_line := 0
var _toks: Array = []           # [kind, value, line]; kinds: num id str op nl eof
var _p := 0
var _names := {}                # name -> {kind: var/arr/const/sprite/func, ...}
var _nvars := 2                 # 0 attract, 1 tick
var _vars_init := PackedInt32Array()
var _reset: Array = []          # [slot, value] of the `var` declarations (reset at every init)
var _sprites := PackedByteArray()
var _sprite_names: Array = []
var _palette := PackedInt32Array([0x0000, 0x7FFF, 0x03E0, 0x001F])
var _code := PackedByteArray()
var _fixups: Array = []         # [code offset, func name, line]
var _depth := 0
var _max_depth := 0
var _loops: Array = []          # [continue target, [break fixups]]
var _fold := true
var _in_body := false


## fold = false: no constant folding in function bodies (tests: makes the VM compute everything).
static func compile(src: String, fold := true) -> Dictionary:
	var c := new()
	c._fold = fold
	return c._compile(src)


func _fail(msg: String, line := -1):
	if error == "":
		error = msg
		err_line = line if line >= 0 else _tok()[2]


func _compile(src: String) -> Dictionary:
	_vars_init.resize(V.NVARS)
	_names = {"attract": {"kind": "var", "slot": V.V_ATTRACT}, "tick": {"kind": "var", "slot": V.V_TICK}}
	for k in V.KEYS:
		_names[k] = {"kind": "const", "value": V.KEYS[k]}
	var lines := src.replace("\r", "").split("\n")
	_sprite_pass(lines)
	if error == "":
		_lex("\n".join(lines))
	if error == "":
		_declarations()
	if error == "":
		_functions()
	if error != "":
		return {"error": error, "line": err_line}
	return {"code": _code, "init": _names["@init"].addr, "frame": _names["frame"].addr, "sprites": _sprites,
		"nsprites": _sprite_names.size(), "palette": _palette, "vars": _vars_init, "nvars": _nvars,
		"sprite_names": _sprite_names, "max_stack": _max_depth}


# --- sprites: `sprite NAME`, 8 rows of up to 16 pixels (. or 0-3), `end` ----------------------------------------------
func _sprite_pass(lines: PackedStringArray):
	var re := RegEx.create_from_string("^\\s*sprite\\s+([A-Za-z_]\\w*)\\s*(;.*)?$")
	var i := 0
	while i < lines.size():
		var m := re.search(lines[i])
		if m == null:
			i += 1
			continue
		var name := m.get_string(1)
		var start := i
		lines[i] = ""
		var data := PackedByteArray()
		data.resize(32)
		var rows := 0
		i += 1
		while i < lines.size():
			var t := lines[i].strip_edges()
			var sc := t.find(";")
			if sc >= 0:
				t = t.substr(0, sc).strip_edges()
			lines[i] = ""
			i += 1
			if t == "":
				continue
			if t == "end":
				break
			if rows >= 8:
				return _fail("sprite '%s': more than 8 rows" % name, i)
			if t.length() > 16:
				return _fail("sprite '%s': row longer than 16 pixels" % name, i)
			for x in t.length():
				var ch := t[x]
				var v := 0 if ch == "." else "0123".find(ch)
				if v < 0:
					return _fail("sprite '%s': bad pixel '%s' (use . 0 1 2 3)" % [name, ch], i)
				data[rows * 4 + (x >> 2)] |= v << ((x & 3) * 2)
			rows += 1
		if _names.has(name):
			return _fail("'%s' already defined" % name, start + 1)
		_names[name] = {"kind": "sprite", "value": _sprite_names.size()}
		_sprite_names.append(name)
		_sprites.append_array(data)


# --- lexer --------------------------------------------------------------------------------------------------------------
func _lex(src: String):
	var line := 1
	var i := 0
	var n := src.length()
	var ops3 := ["<<=", ">>="]
	var ops2 := ["==", "!=", "<=", ">=", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^="]
	while i < n:
		var c := src[i]
		if c == "\n":
			_toks.append(["nl", "", line])
			line += 1
			i += 1
		elif c == " " or c == "\t":
			i += 1
		elif c == ";" or src.substr(i, 2) == "//":
			while i < n and src[i] != "\n":
				i += 1
		elif c == "#" and i + 7 <= n and src.substr(i + 1, 6).is_valid_hex_number():
			var rgb := src.substr(i + 1, 6).hex_to_int()
			_toks.append(["num", ((rgb >> 19) & 31) | (((rgb >> 11) & 31) << 5) | (((rgb >> 3) & 31) << 10), line])
			i += 7
		elif c.is_valid_int():
			var j := i
			if src.substr(i, 2).to_lower() == "0x":
				j += 2
				while j < n and src[j].is_valid_hex_number():
					j += 1
				if j == i + 2:
					return _fail("bad number", line)
				_toks.append(["num", src.substr(i + 2, j - i - 2).hex_to_int(), line])
			else:
				while j < n and src[j].is_valid_int():
					j += 1
				_toks.append(["num", src.substr(i, j - i).to_int(), line])
			if _toks[-1][1] > 0xFFFFFFFF:
				return _fail("number too big", line)
			_toks[-1][1] = V.w32(_toks[-1][1])
			i = j
		elif c == "_" or c.to_lower() != c.to_upper() or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			var j := i
			while j < n and (src[j] == "_" or src[j].is_valid_int() or (src[j] >= "a" and src[j] <= "z") or (src[j] >= "A" and src[j] <= "Z")):
				j += 1
			if j == i:
				return _fail("bad character '%s'" % c, line)
			_toks.append(["id", src.substr(i, j - i), line])
			i = j
		elif c == "\"":
			var s := PackedByteArray()
			i += 1
			while true:
				if i >= n or src[i] == "\n":
					return _fail("unterminated string", line)
				var ch := src[i]
				if ch == "\"":
					i += 1
					break
				if ch == "\\" and i + 1 < n:
					i += 1
					ch = {"n": "\n", "\\": "\\", "\"": "\""}.get(src[i], "")
					if ch == "":
						return _fail("bad escape \\%s" % src[i], line)
				var code := ch.unicode_at(0)
				if code > 126:
					return _fail("only ASCII characters in strings", line)
				s.append(code)
				i += 1
			if s.size() > 255:
				return _fail("string longer than 255 characters", line)
			_toks.append(["str", s, line])
		elif c == "'" and i + 2 < n and src[i + 2] == "'":
			_toks.append(["num", src.unicode_at(i + 1), line])
			i += 3
		else:
			var op := ""
			if src.substr(i, 3) in ops3:
				op = src.substr(i, 3)
			elif src.substr(i, 2) in ops2:
				op = src.substr(i, 2)
			elif c in "+-*/%&|^~()[],=<>":
				op = c
			else:
				return _fail("bad character '%s'" % c, line)
			_toks.append(["op", op, line])
			i += op.length()
	_toks.append(["nl", "", line])
	_toks.append(["eof", "", line])


func _tok(k := 0) -> Array:
	return _toks[mini(_p + k, _toks.size() - 1)]


func _is(kind: String, v = null) -> bool:
	var t := _tok()
	return t[0] == kind and (v == null or t[1] == v)


func _accept(kind: String, v = null) -> bool:
	if _is(kind, v):
		_p += 1
		return true
	return false


func _expect(kind: String, v = null, what := "") -> bool:
	if _accept(kind, v):
		return true
	var t := _tok()
	_fail("expected %s, found %s" % [what if what != "" else str(v if v != null else kind), _desc(t)])
	return false


func _desc(t: Array) -> String:
	match t[0]:
		"nl": return "end of line"
		"eof": return "end of file"
		"str": return "a string"
	return "'%s'" % str(t[1])


func _eol() -> bool:
	if _accept("nl"):
		return true
	_expect("nl", null, "end of line")
	return false


func _skip_nl() -> void:
	while _accept("nl"):
		pass


func _ident(what: String) -> String:
	var t := _tok()
	if t[0] != "id" or t[1] in KEYWORDS:
		_fail("expected %s, found %s" % [what, _desc(t)])
		return ""
	_p += 1
	return t[1]


func _new_name(what: String) -> String:
	var line: int = _tok()[2]
	var n := _ident(what)
	if n != "" and (_names.has(n) or FUNCS.has(n) or COMMANDS.has(n) or n == "text"):
		_fail("'%s' already defined" % n, line)
		return ""
	return n


# --- declarations (first pass: everything except function bodies) ------------------------------------------------------
func _declarations():
	_skip_nl()
	while error == "" and not _is("eof"):
		var t := _tok()
		if _accept("id", "var") or _accept("id", "keep"):
			_var_decl(t[1] == "keep")
		elif _accept("id", "const"):
			var n := _new_name("constant name")
			if _expect("op", "=") and n != "":
				var e = _expr()
				if error == "":
					if e[0] != "num":
						return _fail("constant '%s' is not a constant expression" % n, t[2])
					_names[n] = {"kind": "const", "value": e[1]}
					_eol()
		elif _accept("id", "palette"):
			for k in 4:
				if k > 0 and not _expect("op", ","):
					return
				var e = _expr()
				if error != "":
					return
				if e[0] != "num":
					return _fail("palette: constant colours only", t[2])
				_palette[k] = e[1] & 0xFFFF
			_eol()
		elif _accept("id", "func"):
			var n := _new_name("function name")
			if n == "":
				return
			_names[n] = {"kind": "func", "tok": _p, "line": t[2], "addr": -1}
			_eol()
			var depth := 1  # skip the body: blocks open with if/while/for, close with end
			while depth > 0 and not _is("eof"):
				if _tok(-1)[0] == "nl" and _is("id"):
					var w: String = _tok()[1]
					if w in ["if", "while", "for"]:
						depth += 1
					elif w == "end":
						depth -= 1
				_p += 1
			if depth > 0:
				return _fail("function '%s' has no end" % n, t[2])
			_eol()
		else:
			return _fail("expected var, keep, const, palette, sprite or func, found %s" % _desc(t))
		_skip_nl()


func _var_decl(keep: bool):
	while error == "":
		var line: int = _tok()[2]
		var n := _new_name("variable name")
		if n == "":
			return
		var size := 1
		var value := 0
		var arr := false
		if _accept("op", "["):
			arr = true
			var e = _expr()
			if error != "":
				return
			if e[0] != "num" or e[1] < 1 or e[1] > 255:
				return _fail("array size must be a constant 1..255", line)
			size = e[1]
			if not _expect("op", "]"):
				return
		elif _accept("op", "="):
			var e = _expr()
			if error != "":
				return
			if e[0] != "num":
				return _fail("initial value of '%s' is not a constant" % n, line)
			value = e[1]
		if _nvars + size > V.NVARS:
			return _fail("too many variables (%d slots)" % (V.NVARS - 2), line)
		_names[n] = {"kind": "arr" if arr else "var", "slot": _nvars, "size": size}
		for k in size:
			if keep:
				_vars_init[_nvars + k] = value
			else:
				_reset.append([_nvars + k, value])
		_nvars += size
		if not _accept("op", ","):
			break
	_eol()


# --- code generation --------------------------------------------------------------------------------------------------
func _emit(b: int) -> void:
	_code.append(b & 0xFF)


func _op(o: int, d := 0) -> void:
	_emit(o)
	_depth += d
	_max_depth = maxi(_max_depth, _depth)


func _u16(v: int) -> void:
	_emit(v)
	_emit(v >> 8)


func _jump(o: int, target := -1) -> int:  # returns the offset of the u16 to patch
	_op(o, -1 if o in [V.JZ, V.JNZ] else 0)
	var at := _code.size()
	_u16(maxi(target, 0))
	return at


func _patch(at: int, target := -1) -> void:
	var t := _code.size() if target < 0 else target
	_code[at] = t & 0xFF
	_code[at + 1] = t >> 8


func _push(v: int) -> void:
	if v >= -128 and v <= 127:
		_op(V.PUSHB, 1)
		_emit(v)
	elif v >= -32768 and v <= 32767:
		_op(V.PUSHH, 1)
		_u16(v)
	else:
		_op(V.PUSHW, 1)
		var b := PackedByteArray()
		b.resize(4)
		b.encode_s32(0, v)
		_code.append_array(b)


func _functions():
	if not _names.has("frame") or _names["frame"].kind != "func":
		return _fail("no 'func frame' (called 30 times per second)", 1)
	# init entry: reset the `var` declarations, then the script's init
	_names["@init"] = {"addr": 0}
	for r in _reset:
		_push(r[1])
		_op(V.STORE, -1)
		_emit(r[0])
	if _names.has("init") and _names["init"].kind == "func":
		_op(V.CALL)
		_fixups.append([_code.size(), "init", 1])
		_u16(0)
	_op(V.RET)
	for n in _names:
		var f: Dictionary = _names[n]
		if f.get("kind") != "func":
			continue
		f.addr = _code.size()
		_p = f.tok
		_in_body = true
		_depth = 0
		_block(["end"])
		if error != "":
			return
		_op(V.RET)
	for fx in _fixups:
		_patch(fx[0], _names[fx[1]].addr)
	if _code.size() > 0xFFFF:
		_fail("program too big (%d bytes, max 65535)" % _code.size(), 1)
	elif _max_depth > MAX_STACK:
		_fail("expression too deep", 1)


## Statements until one of `enders` (consumed is left to the caller, except "end" which is consumed).
func _block(enders: Array) -> String:
	while error == "":
		_skip_nl()
		var t := _tok()
		if t[0] == "eof":
			_fail("missing end")
			return ""
		if t[0] == "id" and t[1] in enders:
			_p += 1
			return t[1]
		_statement()
	return ""


func _statement():
	var t := _tok()
	if t[0] != "id":
		return _fail("expected a statement, found %s" % _desc(t))
	var w: String = t[1]
	_p += 1
	match w:
		"if":
			var ends: Array = []
			while true:
				_cond()
				var jz := _jump(V.JZ)
				_eol()
				var e := _block(["elif", "else", "end"])
				if error != "":
					return
				if e == "end":
					_patch(jz)
					break
				ends.append(_jump(V.JMP))
				_patch(jz)
				if e == "else":
					_eol()
					_block(["end"])
					break
			for j in ends:
				_patch(j)
		"while":
			var top := _code.size()
			_cond()
			var jz := _jump(V.JZ)
			_eol()
			_loops.append([top, []])
			_block(["end"])
			_jump(V.JMP, top)
			_patch(jz)
			for j in _loops.pop_back()[1]:
				_patch(j)
		"for":
			var line: int = t[2]
			var n := _ident("loop variable")
			if n == "":
				return
			var v: Dictionary = _names.get(n, {})
			if v.get("kind") != "var":
				return _fail("'%s' is not a variable" % n, line)
			if not _expect("op", "="):
				return
			_gen(_expr())
			_op(V.STORE, -1)
			_emit(v.slot)
			if not _expect("id", "to"):
				return
			var lim = _expr()
			var step := 1
			if _accept("id", "step"):
				var s = _expr()
				if error == "" and (s[0] != "num" or s[1] == 0):
					return _fail("step must be a non-zero constant", line)
				if error == "":
					step = s[1]
			_eol()
			var top := _code.size()
			_op(V.LOAD, 1)
			_emit(v.slot)
			_gen(lim)
			_op(V.LE if step > 0 else V.GE, -1)
			var jz := _jump(V.JZ)
			_loops.append([-1, []])
			_block(["end"])
			if error != "":
				return
			var cont := _code.size()
			_op(V.LOAD, 1)
			_emit(v.slot)
			_push(step)
			_op(V.ADD, -1)
			_op(V.STORE, -1)
			_emit(v.slot)
			_jump(V.JMP, top)
			_patch(jz)
			for j in _loops.pop_back()[1]:
				if j < 0:
					_patch(-j, cont)
				else:
					_patch(j)
		"break", "continue":
			if _loops.is_empty():
				return _fail("%s outside a loop" % w, t[2])
			var lp: Array = _loops[-1]
			if w == "break":
				lp[1].append(_jump(V.JMP))
			elif lp[0] >= 0:
				_jump(V.JMP, lp[0])
			else:  # for loop: continue target known at the end, marked negative
				lp[1].append(-_jump(V.JMP))
			_eol()
		"return":
			_op(V.RET)
			_eol()
		"text":
			var s := _tok()
			if not _expect("str", null, "a string"):
				return
			var args := 0
			while _accept("op", ","):
				_gen(_expr())
				args += 1
			if error != "":
				return
			if args < 3 or args > 4:
				return _fail("text \"...\", x, y, colour [, size]", t[2])
			if args == 3:
				_push(1)
			_op(V.TEXT, -4)
			_emit(s[1].size())
			_code.append_array(s[1])
			_eol()
		_:
			if COMMANDS.has(w):
				var c: Array = COMMANDS[w]
				var args := 0
				while error == "":
					_gen(_expr())
					args += 1
					if not _accept("op", ","):
						break
				if error != "":
					return
				if args < c[1] or args > c[2]:
					return _fail("%s takes %s arguments" % [w, str(c[1]) if c[1] == c[2] else "%d or %d" % [c[1], c[2]]], t[2])
				if args < c[2]:
					_push(c[3])
				_op(c[0], -c[2])
				_eol()
				return
			var d: Dictionary = _names.get(w, {})
			match d.get("kind", ""):
				"func":
					if _accept("op", "("):
						_expect("op", ")")
					_op(V.CALL)
					_fixups.append([_code.size(), w, t[2]])
					_u16(0)
					_eol()
				"var":
					var a := _tok()
					if not _accept("op") or not ASSIGN_OPS.has(a[1]):
						return _fail("expected = or an assignment operator after '%s'" % w, t[2])
					var o: int = ASSIGN_OPS[a[1]]
					if o >= 0:
						_op(V.LOAD, 1)
						_emit(d.slot)
					_gen(_expr())
					if o >= 0:
						_op(o, -1)
					_op(V.STORE, -1)
					_emit(d.slot)
					_eol()
				"arr":
					if not _expect("op", "["):
						return
					_gen(_expr())
					if not _expect("op", "]"):
						return
					var a := _tok()
					if not _accept("op") or not ASSIGN_OPS.has(a[1]):
						return _fail("expected = or an assignment operator", t[2])
					var o: int = ASSIGN_OPS[a[1]]
					if o >= 0:
						_op(V.DUP, 1)
						_op(V.LOADX)
						_emit(d.slot)
						_emit(d.size)
					_gen(_expr())
					if o >= 0:
						_op(o, -1)
					_op(V.STOREX, -2)
					_emit(d.slot)
					_emit(d.size)
					_eol()
				"":
					_fail("unknown name '%s'" % w, t[2])
				_:
					_fail("'%s' cannot be assigned" % w, t[2])


func _cond() -> void:
	_gen(_expr())


# --- expressions: parsed to a small tree (constant folded), then generated --------------------------------------------
# nodes: ["num", v] ["load", slot] ["idx", slot, size, e] ["un", op, e] ["bin", op, a, b] ["and", a, b] ["or", a, b]
#        ["fn", op, [args]]
func _expr():
	return _ex_or()


func _ex_or():
	var a = _ex_and()
	while error == "" and _accept("id", "or"):
		var b = _ex_and()
		if a[0] == "num" and b[0] == "num" and _folding():
			a = ["num", int(a[1] != 0 or b[1] != 0)]
		else:
			a = ["or", a, b]
	return a


func _ex_and():
	var a = _ex_not()
	while error == "" and _accept("id", "and"):
		var b = _ex_not()
		if a[0] == "num" and b[0] == "num" and _folding():
			a = ["num", int(a[1] != 0 and b[1] != 0)]
		else:
			a = ["and", a, b]
	return a


func _ex_not():
	if _accept("id", "not"):
		return _fold_un(V.NOT, _ex_not())
	return _ex_bin(0)


func _ex_bin(level: int):
	if level >= BINOPS.size():
		return _ex_unary()
	var a = _ex_bin(level + 1)
	while error == "":
		var t := _tok()
		if t[0] != "op" or not BINOPS[level].has(t[1]):
			break
		_p += 1
		var b = _ex_bin(level + 1)
		var o: int = BINOPS[level][t[1]]
		if a[0] == "num" and b[0] == "num" and _folding():
			a = ["num", V.binop(o, a[1], b[1])]
		else:
			a = ["bin", o, a, b]
	return a


func _folding() -> bool:
	return _fold or not _in_body


func _fold_un(o: int, e):
	if e[0] == "num" and _folding():
		return ["num", V.unop(o, e[1])]
	return ["un", o, e]


func _ex_unary():
	if _accept("op", "-"):
		return _fold_un(V.NEG, _ex_unary())
	if _accept("op", "~"):
		return _fold_un(V.BNOT, _ex_unary())
	if _accept("op", "+"):
		return _ex_unary()
	return _primary()


func _primary():
	var t := _tok()
	if error != "":
		return ["num", 0]
	if t[0] == "num":
		_p += 1
		return ["num", t[1]]
	if _accept("op", "("):
		var e = _expr()
		_expect("op", ")")
		return e
	if t[0] == "id":
		_p += 1
		var n: String = t[1]
		if n == "true" or n == "false":
			return ["num", int(n == "true")]
		if FUNCS.has(n):
			var f: Array = FUNCS[n]
			var args: Array = []
			if not _expect("op", "("):
				return ["num", 0]
			for k in f[1]:
				if k > 0 and not _expect("op", ","):
					return ["num", 0]
				args.append(_expr())
			_expect("op", ")")
			if f[0] in [V.ABS, V.MIN, V.MAX] and _folding() and args.all(func(a): return a[0] == "num"):
				return ["num", V.unop(f[0], args[0][1]) if f[1] == 1 else V.binop(f[0], args[0][1], args[1][1])]
			return ["fn", f[0], args]
		var d: Dictionary = _names.get(n, {})
		match d.get("kind", ""):
			"const", "sprite":
				return ["num", d.value]
			"var":
				return ["load", d.slot]
			"arr":
				if not _expect("op", "["):
					return ["num", 0]
				var e = _expr()
				_expect("op", "]")
				return ["idx", d.slot, d.size, e]
			"func":
				_fail("function '%s' has no value" % n, t[2])
			_:
				_fail("unknown name '%s'" % n, t[2])
		return ["num", 0]
	_fail("expected a value, found %s" % _desc(t))
	return ["num", 0]


func _gen(e) -> void:
	if error != "" or e == null:
		return
	match e[0]:
		"num":
			_push(e[1])
		"load":
			_op(V.LOAD, 1)
			_emit(e[1])
		"idx":
			_gen(e[3])
			_op(V.LOADX)
			_emit(e[1])
			_emit(e[2])
		"un":
			_gen(e[2])
			_op(e[1])
		"bin":
			_gen(e[2])
			_gen(e[3])
			_op(e[1], -1)
		"fn":
			for a in e[2]:
				_gen(a)
			_op(e[1], 1 - e[2].size())
		"and", "or":
			var is_and: bool = e[0] == "and"
			var o := V.JZ if is_and else V.JNZ
			_gen(e[1])
			var j1 := _jump(o)
			_gen(e[2])
			var j2 := _jump(o)
			_push(0 if not is_and else 1)
			var je := _jump(V.JMP)
			_depth -= 1
			_patch(j1)
			_patch(j2)
			_push(1 if not is_and else 0)
			_patch(je)
