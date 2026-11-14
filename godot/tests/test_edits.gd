extends SceneTree
## Edit layer checks: Godot --headless --path godot --script res://tests/test_edits.gd -- rom.nds out.nds
## Makes the edits of the old editor's tests, exports a ROM, reopens it and checks the edits are there.
## The project folder of the input ROM is wiped first (user://projects/<sha1>).

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var p := EditProject.new(gd)
	p.discard_all()
	var loc := 5
	var lay := p.load_layout(loc)
	var n0: int = lay.blocks[0].groups[0].items.size()
	# add a prop (YetiStatue-like: any prop id) and a door 5 -> 6
	check(p.add_item(loc, 0, 0, 2, -300, 17, 0, {"prop": 40, "angle_deg": 90}) == "", "add prop")
	check(p.add_item(loc, 0, 0, 4, -320, 17, 0, {"dest": 6, "entry": 0}) == "", "add door 5 -> 6")
	var e := p.add_item(loc, 0, 0, 4, -320, 17, 0, {"dest": 6, "entry": 77})
	check(e != "", "door to a missing entry refused (%s)" % e)
	lay = p.load_layout(loc)
	check(lay.blocks[0].groups[0].items.size() == n0 + 2, "group grew by 2")
	check(p.duplicate_item(loc, 0, 0, 0) == "", "duplicate")
	check(p.delete_item(loc, 0, 0, n0 + 2) == "", "delete the copy")
	check(p.edit_item(loc, 0, 0, n0, -301, null, 5) == "", "move")
	check(p.edit_entry(loc, 0, null, null, null, 1.0) == "", "entry angle")
	check(p.bsp_box(loc, Vector3(-310, 17, -5), Vector3(-300, 27, 5)) == "", "add collision box")
	var t := p.load_bsp(loc)
	check(t.classify(Vector3(-305, 20, 0)), "box is solid")
	var slot := p.furniture_slot(8)
	check(p.edit_furniture(8, 2, 134, null, null, null) == "", "furniture prop change")
	check(p.edit_furniture(8, 2, 3, null, null, null) != "", "non-furniture prop refused")
	check(p.undo() == "", "undo (the refused edit pushed nothing)")
	check(not p.is_edited("furniture", slot), "undo dropped the furniture edit")
	check(p.edit_furniture(8, 2, 134, null, null, null) == "", "furniture again")
	var t0 := Time.get_ticks_msec()
	check(p.export_rom(args[1]) == "", "export (%d ms)" % (Time.get_ticks_msec() - t0))
	# reopen
	var g2 := GameData.new()
	check(g2.open(args[1]), "exported ROM opens (%s)" % g2.error)
	var p2 := EditProject.new(g2)
	var l2 := p2.load_layout(loc)
	check(l2.error == "" and l2.blocks[0].groups[0].items.size() == n0 + 2, "layout edits in the ROM")
	var it: Layout.Item = l2.blocks[0].groups[0].items[n0]
	check(it.x == -301 and it.z == 5 and it.raw[0xE] == 40, "moved prop in the ROM")
	check(Bsp.parse(g2.rombin.data(g2.locations[loc].bsp)).classify(Vector3(-305, 20, 0)), "collision box in the ROM")
	check(p2.furniture_list(slot)[8] == 134, "furniture in the ROM arm9")
	check(g2.rom.data.decode_u16(0x15E) == NdsRom.crc16(g2.rom.data, 0, 0x15E), "header CRC")
	p.discard_all()
	print("FAILURES: %d" % fails)
	quit(1 if fails else 0)
