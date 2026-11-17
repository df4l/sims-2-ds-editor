extends SceneTree
## Layout script editing: Godot --headless --path godot --script res://tests/test_scripts.gd -- rom.nds out_dir
## Text round-trip of every script of every layout, reference checks, edits (change / add a script), refusals,
## undo, export + reopen. Writes out_dir/scripts_test.nds and out_dir/loc5_block1.txt (disassembly of the edit).
## The project folder of the input ROM is wiped first.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func same_scripts(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for k in a.size():
		if a[k].size() != b[k].size():
			return false
		for j in a[k].size():
			if a[k][j][0] != b[k][j][0] or a[k][j][1] != b[k][j][1]:
				return false
	return true


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var p := EditProject.new(gd)
	p.discard_all()

	# --- round-trip over every layout -------------------------------------------------------------------------
	var seen := {}
	var n_scripts := 0
	var n_ops := 0
	var bad := []
	var ref_errs := []
	for L in gd.locations:
		var nav: int = L.nav
		if nav == GameData.NONE or seen.has(nav):
			continue
		seen[nav] = true
		var raw := gd.rombin.raw_entry(nav)
		var lay := Layout.parse(raw, gd.arg_size)
		for b in lay.blocks.size():
			var blk: Layout.Block = lay.blocks[b]
			for lang in ["en", "fr"]:
				var txt := LayScript.disassemble(blk.scripts, gd, lang, blk)
				var r := LayScript.assemble(txt, gd.arg_size)
				if r.error != "" or not same_scripts(r.scripts, blk.scripts):
					bad.append("nav %d block %d %s: %s (line %d)" % [nav, b, lang, r.error, r.line])
			var plain := LayScript.assemble(LayScript.disassemble(blk.scripts), gd.arg_size)
			if plain.error != "" or not same_scripts(plain.scripts, blk.scripts):
				bad.append("nav %d block %d: plain text" % [nav, b])
			blk.scripts = LayScript.assemble(LayScript.disassemble(blk.scripts, gd, "en", blk), gd.arg_size).scripts
			n_scripts += blk.scripts.size()
			for s in blk.scripts:
				n_ops += s.size()
		if lay.write() != raw:
			bad.append("nav %d: layout rebuilt from the assembled text differs" % nav)
		for e in p.script_ref_errors(lay):
			ref_errs.append("nav %d: %s" % [nav, e])
	for x in bad.slice(0, 10):
		print("    ", x)
	check(bad.is_empty(), "%d layouts, %d scripts, %d ops: text -> assemble byte-identical (en + fr comments, plain)" % [seen.size(), n_scripts, n_ops])
	for x in ref_errs:
		print("    original data: ", x)
	print("  info %d broken references in the original data" % ref_errs.size())

	# --- assembler errors -------------------------------------------------------------------------------------
	var A := gd.arg_size
	check(LayScript.assemble("script 1\n  nope(1)\n", A).line == 2, "unknown opcode refused with its line")
	check(LayScript.assemble("script 1\n  spawn_run(group=1)\n", A).error.find("missing script") >= 0, "missing field refused")
	check(LayScript.assemble("script 1\n  spawn_run(1, 300)\n", A).error.find("out of range") >= 0, "u8 out of range refused")
	check(LayScript.assemble("script 1\n  money_add(-40000)\n", A).error != "", "s16 out of range refused")
	check(LayScript.assemble("script 2\n", A).error != "", "script numbering checked")
	check(LayScript.assemble("  sfx(3)\n", A).error != "", "op before a header refused")
	check(LayScript.assemble("script 1\n  sfx(sound=1, sound=2)\n", A).error != "", "field twice refused")
	var ok := LayScript.assemble("script 1 ; c\n  spawn_run(2, script=0x3)  ; comment\n  money_add(-20)\n  op_0b()\nscript 2:\n", A)
	check(ok.error == "" and ok.scripts.size() == 2 and ok.scripts[0].size() == 3, "positional, named, hex, negative, op_XX, comments")
	check(ok.error == "" and ok.scripts[0][0][1].slice(0, 2) == PackedByteArray([2, 3]) and ok.scripts[0][0][1].size() == A[0x16],
		"spawn_run args bytes + ARG_SIZE padding")
	check(ok.error == "" and ok.scripts[0][1][1].decode_s16(0) == -20, "s16 encoded")
	var tp := LayScript.assemble("script 1\n  actor_teleport(x=-5, y=6, z=7, g=255, i=0, dir=2)\n", A)
	check(tp.error == "" and tp.scripts[0][0][1].decode_s16(0) == -5, "actor_teleport x field (was hidden as unused before)")

	# --- edits on location 5 ----------------------------------------------------------------------------------
	var loc := 5
	var EB := 1   # a variant block: block 0 refs point into the variant blocks
	var lay := p.load_layout(loc)
	var blk: Layout.Block = lay.blocks[EB]
	var ns := blk.scripts.size()
	var ng := blk.groups.size()
	print("  info location 5 block %d: %d groups, %d scripts, %d blocks" % [EB, ng, ns, lay.blocks.size()])
	var txt := LayScript.disassemble(blk.scripts, gd, "en", blk)
	# new script n+1: a message and money; script 1 gets a call to it at the end
	var lines := txt.split("\n")
	var s2 := lines.find("script 2")
	if s2 < 0:
		s2 = lines.size()
	var add := "  spawn_run(group=0, script=%d)  ; added" % (ns + 1)
	var lines2 := lines.slice(0, s2 - 1)
	lines2.append(add)
	lines2.append_array(lines.slice(s2 - 1))
	var edited := "\n".join(lines2) + "\nscript %d\n  money_add(amount=500)\n  sfx(sound=1)\n" % (ns + 1)
	var r := LayScript.assemble(edited, A)
	check(r.error == "", "edited text assembles (%s)" % r.error)
	check(p.set_scripts(loc, EB, r.scripts) == "", "set_scripts: new script + call to it")
	lay = p.load_layout(loc)
	blk = lay.blocks[EB]
	check(blk.scripts.size() == ns + 1, "block has %d scripts" % (ns + 1))
	var last: Array = blk.scripts[0].back()
	check(last[0] == 0x16 and last[1][1] == ns + 1, "script 1 ends with spawn_run(0, %d)" % (ns + 1))
	check(blk.scripts[ns][0][0] == 0x20 and blk.scripts[ns][0][1].decode_s16(0) == 500, "new script holds money_add(500)")
	var f := FileAccess.open(out_dir.path_join("loc5_block%d.txt" % EB), FileAccess.WRITE)
	f.store_string(LayScript.disassemble(blk.scripts, gd, "en", blk))
	f.close()

	# refusals
	var e := p.set_scripts(loc, EB, LayScript.assemble("script 1\n  spawn_run(group=%d, script=1)\n" % (ng + 5), A).scripts)
	check(e.find("broken references") >= 0, "group past the block refused")
	var short: Array = r.scripts.slice(0, ns)
	e = p.set_scripts(loc, EB, short)
	check(e.find("broken references") >= 0, "dropping script %d while script 1 still calls it refused" % (ns + 1))
	print("    ", e.split("\n")[1] if e.find("\n") >= 0 else e)
	e = p.set_scripts(loc, EB, LayScript.assemble("script 1\n  conversation(conv=250, group=0, script=0)\n", A).scripts)
	check(e != "", "conversation past the table refused")
	check(p.load_layout(loc).blocks[EB].scripts.size() == ns + 1, "refused edits changed nothing")

	# undo
	check(p.undo() == "" and p.load_layout(loc).blocks[EB].scripts.size() == ns and not p.is_edited("layout", p.nav_of(loc)),
		"undo restores the original scripts")
	check(p.set_scripts(loc, EB, r.scripts) == "", "edit again")

	# export + reopen
	var out := out_dir.path_join("scripts_test.nds")
	check(p.export_rom(out) == "", "export")
	var g2 := GameData.new()
	check(g2.open(out), "exported ROM opens (%s)" % g2.error)
	var l2 := Layout.parse(g2.rombin.raw_entry(gd.locations[loc].nav), g2.arg_size)
	check(l2.error == "" and same_scripts(l2.blocks[EB].scripts, blk.scripts), "exported layout has the edited scripts")
	print("fails: ", fails)
	quit(1 if fails else 0)
