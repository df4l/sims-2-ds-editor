extends SceneTree
## Checks of new locations (EditProject new locations + LocExt.install, docs/formats/arm9.md §7):
##   Godot --headless --path godot --script res://tests/test_newloc.gd -- rom.nds out_dir
## Uses its own project folder (user://tests/newloc), never the ROM's real project. Writes to out_dir, for the
## emulator: newloc_<id>.nds (direct boot into location id: 34 = copy of City Hall, 35 = copy of the Saloon sold in
## the construction menu, 6 = control with the same hooks), door_5_34.nds (normal boot; a door of location 5
## leads to 34), arm9_ext.bin + hooks.txt (extension and hook sites, for a disassembler).

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
	pr.dir = "user://tests/newloc"
	pr.edits.clear()
	pr.undo_stack.clear()
	DirAccess.make_dir_recursive_absolute(pr.dir)
	for f in DirAccess.get_files_at(pr.dir):
		DirAccess.remove_absolute(pr.dir.path_join(f))
	pr._sync_tables()
	pr._sync_newlocs()
	var n0 := gd.rombin.count()
	var t0 := pr.text_count()

	# --- project ------------------------------------------------------------------------------------------------
	check(pr.add_new_location(6, "Test Hall") == "" and pr.last_index == 34, "new location 34 from City Hall")
	check(pr.text_count() == t0 + 1 and gd.place(34) == "Test Hall", "name = new string %d" % t0)
	check(pr.add_new_location(24, "Test Saloon") == "" and pr.last_index == 35, "new location 35 from the Saloon")
	check(pr.add_new_location(6, "") != "", "empty name refused")
	check(pr.set_new_location(35, {"price": 500, "score": 3, "offered": true, "alias": 5}) == "", "35 sold, offered, behaves like 5")
	check(pr.set_new_location(35, {"alias": 34}) != "", "alias must be an original location")
	check(gd.has_location(34) and gd.has_location(35) and not gd.has_location(33), "GameData lists 34, 35, not 33")
	check(pr.nav_of(34) == EditProject.VIRT + 68 and pr.load_layout(34).error == "", "34 has its own (virtual) layout")
	check(pr.current("layout", pr.nav_of(34)) == gd.rombin.raw_entry(gd.locations[6].nav), "34 layout = City Hall's")
	check(pr.entry_ids(34) == pr.entry_ids(6), "same entry points as City Hall")
	# the Saloon door of location 5 leads to 34: every door item of 5 with dest 24 (a model door [0,0,0] and its
	# trigger box [0,0,18]: the Sim goes through the box, so both must change)
	var lay5 := pr.load_layout(5)
	var doors := []
	for b in lay5.blocks.size():
		for g in lay5.blocks[b].groups.size():
			for i in lay5.blocks[b].groups[g].items.size():
				var it = lay5.blocks[b].groups[g].items[i]
				if it.type == 4 and it.get_field("dest") == 24:
					doors.append([b, g, i])
	var e34: int = pr.entry_ids(34)[0]
	var ok := doors.size() == 2
	for d in doors:
		ok = ok and pr.edit_item(5, d[0], d[1], d[2], null, null, null, null, null, {"dest": 34, "entry": e34}) == ""
	check(ok, "Saloon doors %s of location 5 -> 34 entry %d" % [str(doors), e34])
	check(pr.delete_new_location(34) != "", "34 cannot be deleted while a door leads there")
	# an edit of the new layout stays separate from City Hall's
	check(pr.edit_entry(34, 0, 10, null, null) == "" and pr.current("layout", pr.nav_of(34)) != pr.current("layout", gd.locations[6].nav), "edit of 34's layout leaves City Hall's")
	pr.undo()
	# delete / undo
	check(pr.add_new_location(9, "Tmp") == "" and pr.last_index == 36, "new location 36")
	check(pr.delete_new_location(36) == "" and not gd.has_location(36), "36 deleted")
	pr.undo()
	check(gd.has_location(36), "undo brings 36 back")
	pr.undo()
	check(not gd.has_location(36) and pr.text_count() == t0 + 2, "undo of its creation removes it and its name")

	# --- build -------------------------------------------------------------------------------------------------
	var rom := pr.build_rom([34, e34])
	check(not rom.is_empty(), "build (%s)" % pr.build_error)
	var p := out_dir.path_join("newloc_34.nds")
	_save(p, rom)
	var g2 := GameData.new()
	check(g2.open(p), "exported ROM reopens")
	check(g2.warning.find("new locations") >= 0, "reopened ROM is flagged as having new locations")
	check(g2.rombin.count() == n0 + 4, "4 appended rom.bin entries (2 layouts, 2 collisions)")
	check(g2.rombin.raw_entry(n0) == gd.rombin.raw_entry(gd.locations[6].nav), "34 layout entry = City Hall's")
	check(g2.rombin.raw_entry(n0 + 3) == gd.rombin.raw_entry(gd.locations[24].bsp), "35 collision entry = Saloon's")
	var l5 := Layout.parse(g2.rombin.raw_entry(g2.locations[5].nav), g2.arg_size)
	var dd := []
	for d in doors:
		dd.append(l5.blocks[d[0]].groups[d[1]].items[d[2]].get_field("dest"))
	check(dd == [34, 34], "exported ROM: Saloon doors of location 5 lead to %s" % str(dd))
	var m := Arm9Mod.new(g2.a9)
	var lt := _loc_table(m)
	check(lt >= Arm9Mod.EXT_BASE, "location table in the extension (0x%08X)" % lt)
	check(m.read_u32(lt + 4 * 33) == Arm9Mod.new(gd.a9).read_u32(GameData.LOC_TABLE + 4 * 33), "id 33 reads the same word as in the original game")
	var r34 := m.read_u32(lt + 4 * 34)
	var r35 := m.read_u32(lt + 4 * 35)
	check(r34 >= Arm9Mod.EXT_BASE and m.read(r34, 6).decode_u16(4) == n0 and m.read(r34, 2).decode_u16(0) == n0 + 1, "record 34: nav %d, bsp %d" % [n0, n0 + 1])
	check(m.read(r35, 6).decode_u16(4) == n0 + 2 and m.read(r35, 2).decode_u16(0) == n0 + 3, "record 35: nav %d, bsp %d" % [n0 + 2, n0 + 3])
	check(m.read(r34 + 6, 0x0E + 8 * gd.locations[6].models.size()) == gd.a9.slice(gd.locations[6].record - GameData.BASE + 6, gd.locations[6].record - GameData.BASE + 0x14 + 8 * gd.locations[6].models.size()), "record 34 = City Hall's otherwise")
	var price := m.read_u32(LocExt.PRICE_LITERAL)
	check(price >= Arm9Mod.EXT_BASE and m.read_u32(price + 4 * 35) == (500 | (3 << 16) | (5 << 24)) and m.read_u32(price + 4 * 34) & 0xFFFF == 0, "price table moved: 35 = 500, score 3, parent 5; 34 free")
	check(m.read(price, 33 * 4) == gd.a9.slice(LocExt.PRICE_TABLE - GameData.BASE, LocExt.PRICE_TABLE - GameData.BASE + 33 * 4), "original prices kept")
	var sites := [0x0207625C, 0x02076F4C, 0x02077104, 0x02085E04, 0x0205EFA4, 0x02083890, 0x0208D698, 0x02064430,
		0x0207355C, 0x020735A8, 0x0209B88C, 0x0205AD38, 0x0206EA28, 0x0206ED98, 0x020C384C]
	var lines := PackedStringArray()
	var all_b := true
	for s in sites:
		var w := m.read_u32(s)
		var to: int = s + 8 + 4 * ((w & 0xFFFFFF) - (0x1000000 if w & 0x800000 else 0))
		all_b = all_b and (w >> 24) == 0xEA and to >= Arm9Mod.EXT_BASE
		lines.append("%08X %08X -> %08X" % [s, w, to])
	check(all_b, "%d ARM9 sites branch into the extension" % sites.size())
	for ov in [1, 5, 8]:
		var code := g2.rom.overlay9_code(ov)
		var inf := g2.rom.overlay9_info(ov)
		var orig := gd.rom.overlay9_code(ov)
		var diff := []
		for o in range(0, code.size(), 4):
			if code.decode_u32(o) != orig.decode_u32(o):
				diff.append(inf.ram + o)
		for a in diff:
			var w := code.decode_u32(a - inf.ram)
			var to: int = a + 8 + 4 * ((w & 0xFFFFFF) - (0x1000000 if w & 0x800000 else 0))
			lines.append("ov%d %08X %08X -> %08X" % [ov, a, w, to])
		var want: int = {1: 13, 5: 2, 8: 1}[ov]
		check(diff.size() == want, "overlay %d: %d words changed (%d expected)" % [ov, diff.size(), want])
	var f := FileAccess.open(out_dir.path_join("hooks.txt"), FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	f = FileAccess.open(out_dir.path_join("arm9_ext.bin"), FileAccess.WRITE)
	f.store_buffer(m.ext)
	f.close()

	# other test ROMs
	var rom35 := pr.build_rom([35, pr.entry_ids(35)[0]])
	_save(out_dir.path_join("newloc_35.nds"), rom35)
	_save(out_dir.path_join("newloc_6.nds"), pr.build_rom([6, e34]))
	_save(out_dir.path_join("door_5_34.nds"), pr.build_rom())
	check(not rom35.is_empty(), "other test ROMs built")

	# ids past 39 cannot be sold
	var arr := pr.newlocs()
	arr.append({"id": 40, "src": 6, "alias": 6, "name_text": 0x43 + 6, "price": 0, "score": 0, "parent": 5, "offered": false})
	pr._store_newlocs(arr)
	check(pr.set_new_location(40, {"price": 100}) != "", "location 40 cannot be sold")
	pr.undo()

	pr.discard_all()
	print("FAILURES: ", fails)
	quit(1 if fails else 0)


## Location table used by the game: literal of Map_GetLocModelRec (first word after the code that is a pointer
## inside the extension or the original table).
func _loc_table(m: Arm9Mod) -> int:
	for a in range(0x02088200, 0x02088300, 4):
		var v := m.read_u32(a)
		if v == GameData.LOC_TABLE or (v >= Arm9Mod.EXT_BASE and v < m.ext_end() and m.read_u32(v + 4 * 6) == m.read_u32(GameData.LOC_TABLE + 4 * 6)):
			return v
	return 0


func _save(p: String, b: PackedByteArray) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()
