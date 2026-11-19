extends SceneTree
## PROTOTYPE (not a test yet): location table moved to the extension and grown to `n` entries; ids 33.. point at the
## record of `src`; direct boot into location `loc`.
##   Godot --headless --path godot --script res://tests/proto_newloc.gd -- rom.nds out.nds src loc [n]
## Full working recipe for 34 = City Hall copy (docs/journal.md, test 5):
##   NEWLOC_LIGHT=1 NEWLOC_RENDER=1 NEWLOC_VARIANT=1 NEWLOC_MUSIC=1 NEWLOC_PATCH=0x020766CC=0xE3540022 ... 6 34
## NEWLOC_MUSIC=1: music override hooks (LocExt.music_hook: 10 hooks for the 12 accesses, 2 in overlay 5); replaces the earlier test
## patch 0x02084C68=0xE3A0002A (mov r0,#0x2a).

const LOC_TABLE := 0x021332E0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var src := args[2].to_int()
	var loc := args[3].to_int()
	var n := 64 if args.size() < 5 else args[4].to_int()
	var m := Arm9Mod.new(gd.a9)
	var t := m.read(LOC_TABLE, 33 * 4)
	var srcp := t.decode_u32(4 * src)
	t.resize(4 * n)
	for i in range(33, n):
		t.encode_u32(4 * i, srcp)
	var r := m.relocate(LOC_TABLE, 33 * 4, t)
	print("table -> 0x%08X, rewritten %s, other %s" % [r.addr, r.rewritten, r.other])
	if OS.get_environment("NEWLOC_LIGHT") != "":
		# lighting: FUN_02085df8, id < 0x21 -> table +16*id, == 0x21 -> special, else default
		var lt := m.read_u32(0x02085F10)
		var sp := m.read_u32(0x02085F14)
		var l := m.read(lt, 33 * 16)
		l.append_array(m.read(sp, 16))
		for i in range(34, n):
			l.append_array(m.read(lt + 16 * src, 16))
		print("light refs ", m.pointers_into(lt, lt + 33 * 16))
		var a := m.add(l)
		m.write_u32(0x02085F10, a)
		m.write_u32(0x02085E04, 0xE3510000 | n)   # cmp r1,#n
		print("light table -> 0x%08X" % a)
	if OS.get_environment("NEWLOC_RENDER") != "":
		# State2_LocationEnter defaults (id not in the lists) -> the City Hall values
		m.write_u32(0x02077040, m.read_u32(0x02077028))   # mov r2,#0x2a000 (+0x27c)
		m.write_u32(0x02077054, m.read_u32(0x02077100))   # mov r2,#0x14000 (FUN_020bc9f8 arg 2)
	if OS.get_environment("NEWLOC_VARIANT") != "":
		# layout variant table (Map_LoadLocation): 12 rows {u8 loc, u8 variant[5] by chapter}, loop cmp r2,#0xc
		var vt := m.read_u32(0x02084CEC)
		var rows := m.read(vt, 72)
		print("variant refs ", m.pointers_into(vt, vt + 72))
		for k in 12:
			if rows[6 * k] == src:
				var row := rows.slice(6 * k, 6 * k + 6)
				row[0] = loc
				rows.append_array(row)
		var a := m.add(rows)
		m.write_u32(0x02084CEC, a)
		m.write_u32(0x02084C20, 0xE3520000 | (rows.size() / 6))   # cmp r2,#rows
		print("variant table -> 0x%08X, %d rows" % [a, rows.size() / 6])
	var ovl := {}
	if OS.get_environment("NEWLOC_MUSIC") != "":
		var me := LocExt.music_hook(m, ovl)
		if me != "":
			print(me)
			quit(1)
			return
		print("music hooks installed, overlay patches ", ovl)
	var e := EditProject.boot_patch(m, 6, 0)
	if e != "":
		print(e)
		quit(1)
		return
	var routine := EditProject.arm_bl_target(EditProject.BOOT_HOOK, m.read_u32(EditProject.BOOT_HOOK))
	m.write_u32(routine + 8, 0xE3A0C000 | loc)
	# experimental code patches: "addr=word" in env NEWLOC_PATCH, comma separated
	for s in OS.get_environment("NEWLOC_PATCH").split(",", false):
		var kv := s.split("=")
		m.write_u32(kv[0].hex_to_int(), kv[1].hex_to_int())
		print("patch ", s)
	var a9 := m.build()
	var files := {}
	var ovt := PackedByteArray()
	if not ovl.is_empty():
		var r2 := LocExt.apply_overlay_patches(gd.rom, ovl)
		if r2.has("error"):
			print(r2.error)
			quit(1)
			return
		files = r2.files
		ovt = r2.ovt
	var out := gd.rom.rebuild(files, a9, ovt)
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_buffer(out)
	f.close()
	print("written ", args[1], " (", out.size(), " bytes)")
	quit(0)
