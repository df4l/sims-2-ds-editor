extends SceneTree
## Text bank editing: Godot --headless --path godot --script res://tests/test_text.gd -- rom.nds out_dir
## Round-trip of the 6 banks, string edits with and without a Huffman tree rebuild, revert, undo, export + reopen.
## Writes out_dir/en_bank.bin (English bank after the edits below, to compare with tools/text.py edit) and
## out_dir/text_test.nds (exported ROM for an emulator check). The project folder of the input ROM is wiped first.

const EDITS := [
	[0x0005, "Touch to start (édité)"],
	[0x0007, "Load-a-Sim ¿À É Î Õ Ü ñ ç ß œ ° …"],
	[0x049F, "Hello there, stranger!\nThis line was written by the Godot editor."],
]
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

	# --- round-trip ---------------------------------------------------------------------------------------------
	for l in GameData.LANGS:
		var d := gd.rombin.raw_entry(GameData.BANKS[l])
		var b := TextBank.new(d)
		var t0 := Time.get_ticks_msec()
		var w := b.write()
		check(w == d, "%s: %d strings, %d symbols, re-encode byte-identical (%d ms)" % [l, b.count(), b.codes().size(),
			Time.get_ticks_msec() - t0])
		var miss := 0
		for i in b.count():
			var s := b.string_bytes(i)
			var enc := TextBank.from_str(TextBank.to_str(s))
			if enc.error != "" or enc.bytes != s:
				miss += 1
		check(miss == 0, "%s: to_str -> from_str gives the same bytes for every string (%d differ)" % [l, miss])

	# --- encoder errors -----------------------------------------------------------------------------------------
	check(TextBank.from_str("snow ☃").error != "", "character outside the code page refused")
	check(TextBank.from_str("bad {zz}").error != "", "bad escape refused")
	check(TextBank.from_str("x".repeat(TextBank.MAX_BYTES)).error != "", "string over the 0x400 buffer refused")
	check(TextBank.from_str("x".repeat(TextBank.MAX_BYTES - 1)).error == "", "string of 0x3FF bytes accepted")

	# --- edits --------------------------------------------------------------------------------------------------
	var p := EditProject.new(gd)
	p.discard_all()
	var en: int = GameData.BANKS["en"]
	var orig_7 := p.text_of("en", 0x0007)
	check(p.set_text("en", 0x0007, "Load-a-Sim (edited)") == "" and not p.last_tree_rebuilt,
		"ASCII edit keeps the tree")
	check(p.text_of("en", 0x0007) == "Load-a-Sim (edited)", "edited string visible through GameData")
	check(p.edited_text_ids("en") == [0x0007], "edited ids = [0x0007]")
	check(p.set_text("en", 0x0007, orig_7) == "" and not p.is_edited("text", en), "putting the text back drops the edit")
	for e in EDITS:
		check(p.set_text("en", e[0], e[1]) == "", "set 0x%04X" % e[0])
	check(p.last_tree_rebuilt or TextBank.new(p.current("text", en)).codes().size() > TextBank.new(p.original("text", en)).codes().size(),
		"tree rebuilt for the accented characters")
	for e in EDITS:
		check(p.text_of("en", e[0]) == e[1], "0x%04X reads back" % e[0])
	check(p.text_of("en", 0x04A0) == p.original_text("en", 0x04A0), "untouched string unchanged")
	check(p.set_text("en", 0x0005, "snow ☃") != "", "invalid character refused")
	check(p.text_of("en", 0x0005) == EDITS[0][1], "refused edit changed nothing")
	var bank_after := p.current("text", en)
	check(p.set_text("en", 0x04A0, "temp") == "" and p.undo() == "", "edit + undo")
	check(p.current("text", en) == bank_after and p.text_of("en", 0x04A0) == p.original_text("en", 0x04A0), "undo restored the bank")
	check(p.set_text("fr", 0x0007, "Charger un Sim (modifié)") == "", "French edit")
	var f := FileAccess.open(out_dir.path_join("en_bank.bin"), FileAccess.WRITE)
	f.store_buffer(bank_after)
	f.close()

	# --- export + reopen ----------------------------------------------------------------------------------------
	var out_rom := out_dir.path_join("text_test.nds")
	check(p.export_rom(out_rom) == "", "export")
	var g2 := GameData.new()
	check(g2.open(out_rom), "exported ROM opens (%s)" % g2.error)
	for e in EDITS:
		check(g2.text(e[0], "en") == e[1], "0x%04X in the exported ROM" % e[0])
	check(g2.text(0x0007, "fr") == "Charger un Sim (modifié)", "French edit in the exported ROM")
	check(g2.rombin.raw_entry(en) == bank_after, "exported bank = project bank")
	var same := 0
	for i in gd.rombin.count():
		if i != en and i != GameData.BANKS["fr"] and g2.rombin.raw_entry(i) == gd.rombin.raw_entry(i):
			same += 1
	check(same == gd.rombin.count() - 2, "every other rom.bin entry unchanged (%d)" % same)
	check(g2.rom.data.decode_u16(0x15E) == NdsRom.crc16(g2.rom.data, 0, 0x15E), "header CRC")
	p.discard_all()
	check(gd.text(0x0007, "en") == orig_7, "discard restores the ROM's text")
	print("FAILURES: %d" % fails)
	quit(1 if fails else 0)
