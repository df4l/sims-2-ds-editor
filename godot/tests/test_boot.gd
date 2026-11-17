extends SceneTree
## Checks of the direct-boot test ROM (EditProject.boot_patch, docs/formats/arm9.md §5):
##   Godot --headless --path godot --script res://tests/test_boot.gd -- rom.nds out_dir [location entry]
## Writes out_dir/boot_test.nds (new game in `location` at entry id `entry`, default 6 0 = City Hall) and
## out_dir/boot_routine.bin (the extension routine, for a disassembler) for a check in an emulator.
## The project's own edits (if any) are kept and exported too.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func u32(a9: PackedByteArray, at: int) -> int:
	return a9.decode_u32(at - Arm9Mod.BASE)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var loc := 6 if args.size() < 4 else args[2].to_int()
	var entry := 0 if args.size() < 4 else args[3].to_int()
	var H := EditProject.BOOT_HOOK

	check(u32(gd.a9, H) == EditProject.BOOT_HOOK_WORD, "opened ARM9 has the original logo step call")
	check(EditProject.arm_bl_target(H, EditProject.BOOT_HOOK_WORD) == EditProject.REQUEST_STATE,
		"bl decoding: the hooked call goes to Game_RequestState")
	check(EditProject.arm_bl(H, EditProject.REQUEST_STATE) == EditProject.BOOT_HOOK_WORD, "bl encoding")

	# --- the patch itself -------------------------------------------------------------------------------------
	var m := Arm9Mod.new(gd.a9)
	var ext0 := m.ext.size()
	check(EditProject.boot_patch(m, loc, entry) == "", "patch applies")
	var b := m.build()
	var routine := EditProject.arm_bl_target(H, u32(b, H))
	check(routine >= Arm9Mod.EXT_BASE + ext0 and routine < Arm9Mod.EXT_BASE + m.ext.size(), "hook branches into the new extension code (0x%08X)" % routine)
	var r := m.read(routine, 96)
	check(r.decode_u32(8) == (0xE3A0C000 | loc) and r.decode_u32(16) == (0xE3A0C000 | entry), "location / entry immediates")
	check(r.decode_u32(92) == EditProject.GAME_PTR, "G literal")
	check(6 * 4 + 8 + (r.decode_u32(24) & 0xFFF) == 92 and 15 * 4 + 8 + (r.decode_u32(60) & 0xFFF) == 92, "both ldr reach the literal")
	check(EditProject.arm_bl_target(routine + 44, r.decode_u32(44)) == EditProject.REQUEST_STATE
		and EditProject.arm_bl_target(routine + 76, r.decode_u32(76)) == EditProject.REQUEST_STATE, "both calls go to Game_RequestState")
	var diff := 0
	for i in gd.a9.size():
		if b[i] != gd.a9[i]:
			diff += 1
	print("  static bytes changed: ", diff)
	var f := FileAccess.open(out_dir.path_join("boot_routine.bin"), FileAccess.WRITE)
	f.store_buffer(r)
	f.close()
	var m2 := Arm9Mod.new(b)
	check(m2.error == "" and EditProject.boot_patch(m2, 30, 3) == "", "an already patched ARM9 can be re-patched")
	var r2 := EditProject.arm_bl_target(H, m2.read_u32(H))
	check(m2.read(r2, 12).decode_u32(8) == 0xE3A0C01E, "re-patch uses the new location")
	check(EditProject.boot_patch(Arm9Mod.new(gd.a9), 33, 0) != "", "location 33 refused")
	check(EditProject.boot_patch(Arm9Mod.new(gd.a9), 5, 256) != "", "entry 256 refused")
	var bad := gd.a9.duplicate()
	bad.encode_u32(H - Arm9Mod.BASE, 0xE1A00000)
	check(EditProject.boot_patch(Arm9Mod.new(bad), 5, 8) != "", "unknown code refused")

	# --- through the project export ---------------------------------------------------------------------------
	var p := EditProject.new(gd)
	var out := out_dir.path_join("boot_test.nds")
	check(p.export_rom(out, [loc, entry]) == "", "test ROM export (%s)" % p.build_error)
	var g2 := GameData.new()
	check(g2.open(out), "test ROM opens (%s)" % g2.error)
	if g2.a9.size():
		var t := EditProject.arm_bl_target(H, u32(g2.a9, H))
		check(t >= Arm9Mod.EXT_BASE and u32(g2.a9, t + 8) == (0xE3A0C000 | loc), "test ROM has the boot patch")
	var normal := out_dir.path_join("normal.nds")
	check(p.export_rom(normal) == "", "normal export")
	var g3 := GameData.new()
	check(g3.open(normal) and u32(g3.a9, H) == EditProject.BOOT_HOOK_WORD, "normal export keeps the original boot")
	DirAccess.remove_absolute(normal)

	print("%d failure(s)" % fails)
	quit(1 if fails else 0)
