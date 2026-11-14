extends SceneTree
## Headless checks of the format code on a real ROM (never committed):
##   Godot --headless --path godot --script res://tests/test_core.gd -- path/to/sims2.nds [blz_test.bin blz_ref.bin]
## Round-trips: rom.bin, every layout, every BSP, the whole ROM rebuild; model conversion of every location model.

var fails := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		fails += 1
		print("  FAIL ", what)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: -- rom.nds")
		quit(2)
		return
	var t0 := Time.get_ticks_msec()
	var gd := GameData.new()
	check(gd.open(args[0]), "open ROM (%s)" % gd.error)
	if gd.error != "":
		quit(1)
		return
	print("  ROM %s %s, rom.bin %d entries, arm9 %d bytes, %d ms" % [gd.rom.game_code, gd.rom.title, gd.rombin.count(), gd.a9.size(), Time.get_ticks_msec() - t0])
	if gd.warning != "":
		print("  warning: ", gd.warning)

	# rom.bin round trip
	check(gd.rombin.build({}) == gd.rombin.raw, "rom.bin rebuild identical")

	# ROM rebuild with nothing changed
	t0 = Time.get_ticks_msec()
	var same := gd.rom.rebuild({})
	if same != gd.rom.data:
		var f := FileAccess.open(args[0] + ".rebuilt", FileAccess.WRITE)
		f.store_buffer(same)
		f.close()
	check(same == gd.rom.data, "ROM rebuild with no change identical (%d ms)" % (Time.get_ticks_msec() - t0))

	# layouts
	var seen := {}
	var lay_ok := 0
	var lay_n := 0
	for L in gd.locations:
		if L.nav == GameData.NONE or seen.has(L.nav):
			continue
		seen[L.nav] = true
		lay_n += 1
		var raw := gd.rombin.raw_entry(L.nav)
		var lay := Layout.parse(raw, gd.arg_size)
		if lay.error != "":
			print("    layout %d: %s" % [L.nav, lay.error])
			continue
		var w := lay.write()
		if w != raw:
			print("    layout %d: round-trip differs (%d vs %d bytes)" % [L.nav, w.size(), raw.size()])
			continue
		if not lay.limit_errors().is_empty():
			print("    layout %d: ", lay.limit_errors())
			continue
		lay_ok += 1
	check(lay_ok == lay_n, "layouts byte-identical %d/%d" % [lay_ok, lay_n])

	# BSPs
	seen.clear()
	var bsp_ok := 0
	var bsp_n := 0
	t0 = Time.get_ticks_msec()
	var nbrush := 0
	for L in gd.locations:
		if seen.has(L.bsp):
			continue
		seen[L.bsp] = true
		bsp_n += 1
		var d := gd.rombin.data(L.bsp)
		var b := Bsp.parse(d)
		if b.error != "":
			print("    bsp %d: %s" % [L.bsp, b.error])
			continue
		if b.write() != d:
			print("    bsp %d: round-trip differs" % L.bsp)
			continue
		if not b.check().is_empty():
			print("    bsp %d: ", b.check()[0])
			continue
		bsp_ok += 1
	check(bsp_ok == bsp_n, "BSP byte-identical + invariants %d/%d (%d ms)" % [bsp_ok, bsp_n, Time.get_ticks_msec() - t0])
	t0 = Time.get_ticks_msec()
	var b5 := Bsp.parse(gd.rombin.data(gd.locations[5].bsp))
	var br := b5.brushes()
	print("  location 5: %d leaves, %d display brushes, %d ms" % [b5.leaves().size(), br.size(), Time.get_ticks_msec() - t0])

	# text
	print("  text en 0x143+22: ", gd.npc_name(22), " | fr: ", gd.npc_name(22, "fr"))
	print("  text en 0x990: ", gd.text(0x990))

	# scripts of location 5
	var lay5 := Layout.parse(gd.rombin.raw_entry(gd.locations[5].nav), gd.arg_size)
	var nops := 0
	for blk in lay5.blocks:
		for s in blk.scripts:
			for op in s:
				LayScript.describe(gd, op[0], op[1], "en", blk)
				nops += 1
	print("  location 5: %d blocks, %d script ops described" % [lay5.blocks.size(), nops])
	if lay5.blocks.size() > 1 and lay5.blocks[1].scripts.size() > 0:
		for op in lay5.blocks[1].scripts[0]:
			print("    ", LayScript.describe(gd, op[0], op[1], "en", lay5.blocks[1]))

	# models
	t0 = Time.get_ticks_msec()
	var mset := {}
	for L in gd.locations:
		for m in L.models:
			mset[m.model] = true
	var mok := 0
	for e in mset:
		var nb := Nsbmd.new()
		if nb.parse(gd.rombin.data(e)) and nb.build() != null:
			mok += 1
		else:
			print("    model %d %s: %s" % [e, gd.model_name(e), nb.error])
	check(mok == mset.size(), "scene models converted %d/%d (%d ms)" % [mok, mset.size(), Time.get_ticks_msec() - t0])

	# room furniture
	var rf := RoomFurn.new(gd)
	for slot in RoomFurn.N_SLOTS:
		var loc: int = rf.room_locations()[slot]
		var items := rf.room_items(slot, rf.defaults_bytes(slot))
		var parts := []
		for it in items:
			parts.append("%d@%s" % [it.prop, "-" if it.pos == null else "(%.3f,%.2f,%.3f)" % [it.pos.x, it.pos.y, it.pos.z]])
		print("  room loc %d: %s" % [loc, " ".join(parts)])
	var vt := []
	for p in GameData.N_PROPS:
		if rf.prop_texture(p) >= 0:
			vt.append(p)
	print("  props with a variant texture: %d (first %s)" % [vt.size(), vt.slice(0, 6)])

	# icons
	t0 = Time.get_ticks_msec()
	var icons := 0
	for n in GameData.N_NPC_INFO:
		if S2Sprite.render_icon(gd, gd.info_npc(n)) != null:
			icons += 1
	print("  NPC icons rendered: %d / %d (%d ms)" % [icons, GameData.N_NPC_INFO, Time.get_ticks_msec() - t0])

	# BLZ against ndspy
	if args.size() >= 3:
		var comp := FileAccess.get_file_as_bytes(args[1])
		var ref := FileAccess.get_file_as_bytes(args[2])
		t0 = Time.get_ticks_msec()
		var dec := Blz.decompress(comp)
		check(dec == ref, "BLZ decompress matches ndspy (%d -> %d bytes, %d ms) %s" % [comp.size(), dec.size(), Time.get_ticks_msec() - t0, Blz.last_error])

	print("FAILURES: %d" % fails)
	quit(1 if fails else 0)
