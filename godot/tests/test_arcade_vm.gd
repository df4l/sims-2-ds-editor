extends SceneTree
## Checks of the arcade language compiler and the reference VM (docs/formats/arcade_vm.md):
##   Godot --headless --path godot --script res://tests/test_arcade_vm.gd
## No ROM needed.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


## Compile `body` inside `func frame`, run init + one frame, return the VM (or null + FAIL).
func run(src: String, keys := 0) -> ArcadeVM:
	var p := ArcadeScript.compile(src)
	if p.has("error"):
		check(false, "compile: line %d: %s\n%s" % [p.line, p.error, src])
		return null
	var vm := ArcadeVM.new()
	vm.load(p)
	vm.start(false)
	vm.frame(keys, keys)
	if vm.stopped != "":
		check(false, "stopped: " + vm.stopped)
	return vm


## value of variable `r` after running `body` in frame
func val(body: String, decl := "") -> int:
	var vm := run("var r\n%s\nfunc frame\n%s\nend\n" % [decl, body])
	return vm.vars[2] if vm else -999999


func _init() -> void:
	# --- expressions / folding / runtime agree ---------------------------------------------------------------------
	var exprs := {"1 + 2 * 3": 7, "(1 + 2) * 3": 9, "7 / 2": 3, "-7 / 2": -3, "7 % -2": 1, "-7 % 2": -1, "5 / 0": 0,
		"5 % 0": 0, "1 << 4": 16, "-16 >> 2": -4, "1 << 33": 2, "0x7FFFFFFF + 1": -2147483648, "~0": -1,
		"3 & 5 | 8": 9, "6 ^ 3": 5, "2 < 3": 1, "3 <= 2": 0, "4 == 4 and 1": 1, "0 or 0": 0, "not 5": 0,
		"min(3, -2)": -2, "max(3, -2)": 3, "abs(-9)": 9, "1 + 2 == 3": 1, "-2147483648 / -1": -2147483648,
		"#FF0000": 31, "#00FF00": 31 << 5, "'A'": 65, "LEFT | A": 0x21, "1 < 2 == 1": 1, "true + true": 2}
	for e in exprs:
		check(val("r = " + e) == exprs[e], "folded   %s = %d" % [e, exprs[e]])
		# same computed by the VM (no folding in the body)
		var p0 := ArcadeScript.compile("var r\nfunc frame\nr = %s\nend\n" % e, false)
		var vm0 := ArcadeVM.new()
		vm0.load(p0)
		vm0.start(false)
		vm0.frame()
		check(vm0.vars[2] == exprs[e], "runtime  %s" % e)
	# operators on variables (no folding at all)
	check(val("a = 7\nb = -2\nr = a / b * 10 + a % b", "var a, b") == -29, "vars: 7 / -2 * 10 + 7 % -2 = -29")
	check(val("a = 0\nr = a and 1 / a", "var a") == 0, "and short-circuits")
	check(val("a = 1\nr = a or rnd(0)", "var a") == 1, "or short-circuits")
	check(val("a = 3\nr = hit(a, 0, 4, 4, 6, 3, 2, 2)", "var a") == 1, "hit overlap")
	check(val("a = 3\nr = hit(a, 0, 4, 4, 7, 3, 2, 2)", "var a") == 0, "hit touching = no hit")

	# --- statements ---------------------------------------------------------------------------------------------------
	check(val("for i = 1 to 10\nr += i\nend", "var i") == 55, "for 1..10")
	check(val("for i = 10 to 1 step -3\nr += i\nend", "var i") == 22, "for step -3 (10 7 4 1)")
	check(val("for i = 1 to 10\nif i == 4\ncontinue\nend\nif i == 7\nbreak\nend\nr += i\nend", "var i") == 17,
		"for continue / break")
	check(val("while r < 100\nr = r * 2 + 1\nend") == 127, "while")
	check(val("a = 5\nif a < 3\nr = 1\nelif a < 6\nr = 2\nelse\nr = 3\nend", "var a") == 2, "if / elif / else")
	check(val("a = 9\nif a < 3\nr = 1\nelif a < 6\nr = 2\nelse\nr = 3\nend", "var a") == 3, "else")
	check(val("for i = 0 to 7\nt[i] = i * i\nend\nr = t[3] + t[7] + t[8] + t[-1]\nt[2] += 5\nr += t[2] * 100", "var i, t[8]") == 958,
		"arrays, out of range reads 0, a[i] += e")
	check(val("add3\nadd3\nr += 1", "func add3\nr += 3\nreturn\nr = 99\nend") == 7, "user functions, return")
	check(val("r = SIZE * 2", "const SIZE = 3 + 4") == 14, "const")
	var vm := run("var r = 5\nkeep k = 40\nfunc init\nr += 1\nk += 1\nend\nfunc frame\nend\n")
	check(vm.vars[2] == 6 and vm.vars[3] == 41, "init resets var (5+1), keep starts at its value")
	vm.start(false)
	check(vm.vars[2] == 6 and vm.vars[3] == 42, "second init: var reset, keep kept")
	vm.frame()
	vm.frame()
	check(vm.vars[1] == 2, "tick counts frames")
	vm = run("var r\nfunc frame\nr = held(A) + pressed(LEFT)\nend\n", 0x21)
	check(vm.vars[2] == 0x21, "held / pressed")

	# --- budget / recursion -------------------------------------------------------------------------------------------
	var p := ArcadeScript.compile("func frame\nwhile 1\nend\nend\n")
	vm = ArcadeVM.new()
	vm.load(p)
	vm.start(false)
	vm.frame()
	check(vm.stopped.contains("budget") and vm.ops == ArcadeVM.BUDGET - 1, "endless loop stopped by the budget (%d ops)" % vm.ops)
	p = ArcadeScript.compile("func f\nf\nend\nfunc frame\nf\nend\n")
	vm.load(p)
	vm.start(false)
	vm.frame()
	check(vm.stopped.contains("depth"), "endless recursion stopped")

	# --- drawing ------------------------------------------------------------------------------------------------------
	vm = run("sprite s\n3.......\n.2\n..1\nend\nfunc frame\ncls 1\nrect 10, 10, 3, 2, 2\nrect -5, 120, 10, 20, 3\npix 127, 0, 3\npix 128, 0, 0\nspr s, 50, 50\nspr s, 70, 50, 1\nspr s, 90, 50, 2\nend\n")
	check(vm.pixel(0, 0) == 1 and vm.pixel(10, 10) == 2 and vm.pixel(12, 11) == 2 and vm.pixel(13, 11) == 1, "cls + rect")
	check(vm.pixel(0, 127) == 3 and vm.pixel(4, 127) == 3 and vm.pixel(5, 127) == 1, "rect clipped")
	check(vm.pixel(127, 0) == 3, "pix")
	check(vm.pixel(50, 50) == 3 and vm.pixel(51, 51) == 2 and vm.pixel(52, 52) == 1 and vm.pixel(51, 50) == 1, "sprite, 0 transparent")
	check(vm.pixel(85, 50) == 3 and vm.pixel(84, 51) == 2, "sprite flipped horizontally")
	check(vm.pixel(90, 57) == 3 and vm.pixel(91, 56) == 2, "sprite flipped vertically")
	vm = run("func frame\ntext \"A1\", 0, 0, 3\ntext \"-\", 0, 10, 2, 2\nnum -305, 0, 20, 1\nend\n")
	check(vm.pixel(1, 0) == 3 and vm.pixel(0, 0) == 0 and vm.pixel(0, 1) == 3 and vm.pixel(4, 0) == 0 and vm.pixel(5, 0) == 3, "text 'A1'")
	check(vm.pixel(0, 14) == 2 and vm.pixel(5, 15) == 2 and vm.pixel(6, 14) == 0 and vm.pixel(0, 13) == 0, "text size 2")
	check(vm.pixel(0, 22) == 1 and vm.pixel(4, 20) == 1 and vm.pixel(5, 20) == 1, "num -305")
	check(vm.pal[0] == 0 and vm.pal[1] == 0x7FFF, "default palette")
	vm = run("palette #000000, #FF0000, 2, 3\nfunc frame\npal 2, #0000FF\nsfx 0x15C\nend\n")
	check(vm.pal[1] == 31 and vm.pal[2] == 31 << 10 and vm.pal[3] == 3 and vm.sounds == [0x15C], "palette, pal, sfx")
	vm.start(false)
	check(vm.pal[2] == 2, "init restores the palette")
	check(val("pix 5, 6, 2\nr = peek(5, 6) * 10 + peek(-1, 0)") == 20, "peek")

	# --- errors -------------------------------------------------------------------------------------------------------
	var bad := {"func init\nend\n": "no 'func frame'", "func frame\nx = 1\nend\n": "unknown name 'x'",
		"var a\nvar a\nfunc frame\nend\n": "already defined", "func frame\nif 1\nend\n": "no end",
		"func frame\nbreak\nend\n": "outside a loop", "sprite s\n4\nend\nfunc frame\nend\n": "bad pixel",
		"func frame\ntext \"x\", 1\nend\n": "text \"...\"", "func frame\nrect 1, 2\nend\n": "rect takes 5",
		"var big[300]\nfunc frame\nend\n": "array size", "var r\nfunc frame\nr = (1 +\nend\n": "expected a value",
		"var a\nfunc frame\nа = 1\nend\n": "bad character", "func frame\ncls 0\n": "no end"}
	for src in bad:
		var r := ArcadeScript.compile(src)
		check(r.has("error") and r.error.contains(bad[src]), "error '%s' -> %s (line %d)" % [bad[src], r.get("error", "none"), r.get("line", 0)])
	var r2 := ArcadeScript.compile("var a\n\nfunc frame\n  a = 1\n  b = 2\nend\n")
	check(r2.get("line", 0) == 5, "error line number (%d)" % r2.get("line", 0))

	# --- the bundled examples compile and run ----------------------------------------------------------------------
	for ex in ArcadeExamples.ALL:
		p = ArcadeScript.compile(ArcadeExamples.ALL[ex])
		check(not p.has("error"), "example %s compiles %s" % [ex, "" if not p.has("error") else "line %d: %s" % [p.line, p.error]])
		if p.has("error"):
			continue
		vm = ArcadeVM.new()
		vm.load(p)
		vm.start(true)
		vm.frame()
		vm.start(false)
		for f in 300:
			vm.frame(0x10 if f % 40 < 20 else 0x21, 0x2 if f % 7 == 0 else 0)
			if vm.stopped != "":
				break
		check(vm.stopped == "", "example %s runs 300 frames %s (max stack %d, code %d bytes)" % [ex, vm.stopped, p.max_stack, p.code.size()])
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)
