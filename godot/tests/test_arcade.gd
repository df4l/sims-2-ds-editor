extends SceneTree
## Checks of own arcade games (ArcadeExt, docs/formats/arcade.md §6):
##   Godot --headless --path godot --script res://tests/test_arcade.gd -- rom.nds out_dir
## Uses its own project folder (user://tests/arcade). Puts the test card on cabinet 174 (Lunar Lander) and turns the
## Space Armada cabinet of location 24 (layout item 0/0/23, prop 165) into a 174. Writes out_dir/arcade_card.nds
## (direct boot into location 24) and out_dir/arcade_ext.bin + arcade_ext.txt (extension and addresses, for capstone).

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
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var pr := EditProject.new(gd)
	pr.dir = "user://tests/arcade"
	pr.edits.clear()
	pr.undo_stack.clear()
	DirAccess.make_dir_recursive_absolute(pr.dir)
	for f in DirAccess.get_files_at(pr.dir):
		DirAccess.remove_absolute(pr.dir.path_join(f))

	# --- original ARM9 ------------------------------------------------------------------------------------------
	var m0 := Arm9Mod.new(gd.a9)
	for at in ArcadeExt.TABLE_LITERALS:
		check(m0.read_u32(at) - ArcadeExt.TABLE in [0, 4, 8], "literal 0x%08X -> table" % at)
	var hits := m0.pointers_into(ArcadeExt.TABLE, ArcadeExt.TABLE + 12 * ArcadeExt.OLD_TYPES)
	check(hits.size() == ArcadeExt.TABLE_LITERALS.size(), "no other word points into the table (%d hits)" % hits.size())
	for p in ArcadeExt.FREE_PROPS:
		check(m0.read_u32(ArcadeExt.FREE_PROPS[p]) == ArcadeExt.MOV_R3_0, "prop %d case sets type 0" % p)
	check(gd.prop_game_name(174).contains("Lunar"), "174 = " + gd.prop_game_name(174))

	# --- project ------------------------------------------------------------------------------------------------
	check(pr.set_arcade_game(173, ArcadeExt.TEST_CARD) != "", "cabinet 173 refused (has a game)")
	check(pr.set_arcade_game(174, "init:\nupdate:\n\tfoo r0\nfree:\n") != "", "assembly error reported")
	check(pr.set_arcade_game(174, "init:\nupdate:\n") != "", "missing free label reported")
	check(pr.set_arcade_game(174, ArcadeExt.TEST_CARD) == "", "test card on 174")
	check(pr.arcade_games().size() == 1 and pr.has_arm9_edits(), "listed, ARM9 edit")
	# moved into the view of the start camera (Sim at (28, 0, 40) looking to -z), screen towards the camera
	var ee := pr.edit_item(24, 0, 0, 23, 28, null, 22, 180, null, {"prop": 174})
	check(ee == "", "location 24 cabinet -> 174 " + ee)

	var m := pr.arm9_mod()
	check(m.error == "", "install: " + m.error)
	var tab := m.read_u32(ArcadeExt.TABLE_LITERALS[0]) - 4   # 0x02029414 holds TABLE + 0 ... check below
	var base := -1
	for at in ArcadeExt.TABLE_LITERALS:
		var v := m.read_u32(at)
		check(v >= Arm9Mod.EXT_BASE, "literal 0x%08X moved (0x%08X)" % [at, v])
		if base < 0 or v < base:
			base = v
	tab = base
	for t in ArcadeExt.OLD_TYPES:
		check(m.read(tab + 12 * t, 12) == m0.read(ArcadeExt.TABLE + 12 * t, 12), "type %d entry kept" % t)
	check(m.read_u32(ArcadeExt.FREE_PROPS[174]) == (ArcadeExt.MOV_R3_0 | 10), "prop 174 -> type 10")
	check(m.read_u32(ArcadeExt.FREE_PROPS[175]) == ArcadeExt.MOV_R3_0, "prop 175 untouched")
	var init := m.read_u32(tab + 120)
	var upd := m.read_u32(tab + 124)
	var fre := m.read_u32(tab + 128)
	check(init >= Arm9Mod.EXT_BASE and upd > init and fre > upd, "type 10 functions in the extension")

	# for capstone: the whole extension + where things are
	var f := FileAccess.open(out_dir.path_join("arcade_ext.bin"), FileAccess.WRITE)
	f.store_buffer(m.ext)
	f.close()
	f = FileAccess.open(out_dir.path_join("arcade_ext.txt"), FileAccess.WRITE)
	f.store_string("base 0x%08X\ntable 0x%08X\ninit 0x%08X\nupdate 0x%08X\nfree 0x%08X\n" % [Arm9Mod.EXT_BASE, tab, init, upd, fre])
	f.close()

	# --- test ROM -----------------------------------------------------------------------------------------------
	var e := pr.export_rom(out_dir.path_join("arcade_card.nds"), [24, 0])
	check(e == "", "test ROM export " + e)
	var gd2 := GameData.new()
	check(gd2.open(out_dir.path_join("arcade_card.nds")), "test ROM opens")
	var m2 := Arm9Mod.new(gd2.a9)
	check(m2.read_u32(ArcadeExt.FREE_PROPS[174]) == (ArcadeExt.MOV_R3_0 | 10), "exported ARM9 has the 174 patch")
	check(pr.set_arcade_game(174, "") == "" and pr.arcade_games().is_empty(), "game removed")
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)
