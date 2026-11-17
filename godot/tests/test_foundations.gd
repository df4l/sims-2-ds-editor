extends SceneTree
## Checks of the low-level mod tools (ARM9 patches and extension, new rom.bin entries, BPS patches):
##   Godot --headless --path godot --script res://tests/test_foundations.gd -- rom.nds out_dir [ext_kib]
## Writes to out_dir: ext_test.nds (ARM9 extension of ext_kib KiB, default 64, with markers + one new rom.bin entry)
## and edits.bps (patch of a small edit set) for checks in an emulator / another patcher.

const MARK := 0x4D4F4421   # "!DOM"
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
	var ext_kib := 64 if args.size() < 3 else args[2].to_int()

	# --- ARM9 -------------------------------------------------------------------------------------------------
	var m := Arm9Mod.new(gd.a9)
	check(m.error == "", "ARM9 accepted (%s)" % m.error)
	check(m.build() == gd.a9, "unchanged ARM9 builds byte-identical")
	var furn_ptrs := m.pointers_into(RoomFurn.DEFAULTS, RoomFurn.DEFAULTS + 6 * 24)
	print("  words pointing into the furniture table: ", furn_ptrs.map(func(h): return "%08X->%08X" % [h.at, h.value]))
	var n := ext_kib * 1024
	var a := m.alloc(n)
	check(a == Arm9Mod.EXT_BASE, "first allocation at the extension base (0x%08X)" % a)
	m.write_u32(a, MARK)
	m.write_u32(a + n - 4, MARK + 1)
	check(m.write_u32(Arm9Mod.EXT_BASE + n, 0) != "", "write past the extension refused")
	check(m.alloc(Arm9Mod.EXT_MAX) == 0, "over-allocation refused")
	var b := m.build()
	check(b.decode_u32(Arm9Mod.ARENA_LO_LITERAL - Arm9Mod.BASE) == Arm9Mod.EXT_BASE + n, "arena start raised")
	var m2 := Arm9Mod.new(b)
	check(m2.error == "" and m2.ext.size() == n and m2.read_u32(a) == MARK, "extension survives a re-parse")
	check(m2.build() == b, "re-parsed ARM9 builds byte-identical")

	# --- rom.bin --------------------------------------------------------------------------------------------
	var entry := PackedByteArray()
	entry.resize(256)
	entry.encode_u32(0, MARK)
	var rb := gd.rombin.build({}, [entry])
	var r2 := RomBin.new()
	check(r2.load_bytes(rb), "rom.bin with a new entry parses (%s)" % r2.error)
	check(r2.count() == gd.rombin.count() + 1 and r2.raw_entry(r2.count() - 1) == entry, "new entry is the last one")
	var same := true
	for i in range(0, gd.rombin.count(), 97):
		same = same and r2.raw_entry(i) == gd.rombin.raw_entry(i)
	check(same, "old entries unchanged (1 in 97 checked)")
	check(gd.rombin.build({}) == gd.rombin.raw, "unchanged rom.bin builds byte-identical")

	var rom := gd.rom.rebuild({gd.rombin_file_id: rb}, b)
	var g2 := GameData.new()
	var p := out_dir.path_join("ext_test.nds")
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(rom)
	f.close()
	check(g2.open(p), "extension ROM reopens (%s)" % g2.error)
	check(g2.rombin.count() == gd.rombin.count() + 1, "reopened rom.bin has the new entry")
	check(Arm9Mod.new(g2.a9).read_u32(a + n - 4) == MARK + 1, "reopened ARM9 has the extension")

	# --- BPS ------------------------------------------------------------------------------------------------
	var pr := EditProject.new(gd)
	pr.discard_all()
	check(pr.edit_item(5, 0, 0, 1, -301, null, 5) == "", "layout edit")
	check(pr.bsp_box(5, Vector3(-310, 17, -5), Vector3(-300, 27, 5)) == "", "collision edit")
	check(pr.edit_furniture(8, 2, 134, null, null, null) == "", "furniture edit (ARM9)")
	var t0 := Time.get_ticks_msec()
	var full := pr.build_rom()
	var t1 := Time.get_ticks_msec()
	var patch := Bps.encode(gd.rom.data, full, pr.last_hints)
	var t2 := Time.get_ticks_msec()
	var back := Bps.apply(gd.rom.data, patch)
	var t3 := Time.get_ticks_msec()
	check(back == full, "BPS round-trip (%s)" % Bps.last_error)
	print("  ROM %d bytes, patch %d bytes; build %d ms, encode %d ms, apply %d ms" % [full.size(), patch.size(), t1 - t0, t2 - t1, t3 - t2])
	check(patch.size() < 2 * 1024 * 1024, "patch is small (hints used)")
	var bad := gd.rom.data.slice(0, 0x1000)
	check(Bps.apply(bad, patch).is_empty(), "patch refused on another source (%s)" % Bps.last_error)
	check(pr.export_patch(out_dir.path_join("edits.bps")) == "", "export_patch")
	check(pr.export_rom(out_dir.path_join("edits.nds")) == "", "export_rom")
	pr.discard_all()

	print("FAILURES: ", fails)
	quit(1 if fails else 0)
