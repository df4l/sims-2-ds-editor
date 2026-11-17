extends SceneTree
## Conversation / message tables and new strings:
##   Godot --headless --path godot --script res://tests/test_conversations.gd -- rom.nds out_dir
## Table read-back, in-place and grown conversations, new strings in the 6 banks, new conversation ids (table moved to
## the ARM9 extension + overlay 15 literal), messages, undo, export + reopen, second export on top of the first.
## Writes out_dir/conv_test.nds for the emulator: at a new game, location 5 plays the NEW conversation 217 instead of
## conversation 0 (two new strings, then the original line 0x4A1), then shows the NEW message 26, then goes on with
## script 25 like the original. The project folder of the input ROM is wiped first.

const LINE_A := "Howdy, stranger! This is a NEW conversation, made in the Godot editor."
const LINE_B := "And this is the player talking, also a new string."
const MSG_A := "A new message box, added by the editor."
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
	var A := gd.arg_size

	# --- read-back ----------------------------------------------------------------------------------------------
	var cs := gd.rom_conversations()
	var nlines := 0
	var nnull := 0
	for c in cs:
		if c == null:
			nnull += 1
		else:
			nlines += c.size()
	check(cs.size() == 216 and nnull == 1 and cs[67] == null and nlines == 501, "216 conversations, id 67 null, 501 lines")
	check(gd.conversation(0)[0] == [0x49F, 22], "conversation 0 starts with 0x49F spoken by NPC 22")
	check(gd.rom_messages().size() == 26 and gd.message(0) == [0x990, -1] and gd.message(26).is_empty(), "26 messages")
	check(EditProject.decode_convs(EditProject.encode_convs(cs)) == cs, "conversation table encode/decode round-trip")
	check(EditProject.decode_msgs(EditProject.encode_msgs(gd.rom_messages())) == gd.rom_messages(), "message encode/decode round-trip")
	var ov := gd.rom.overlay9_code(GameData.CONV_OV)
	var ovi := gd.rom.overlay9_info(GameData.CONV_OV)
	check(ov.size() == 0xF00 and ov.decode_u32(GameData.CONV_OV_LITERAL - ovi.ram) == GameData.CONV_TABLE,
		"overlay 15 decompresses (compressed=%s) and holds the table base" % ovi.compressed)

	var p := EditProject.new(gd)
	p.discard_all()
	check(p.build_rom() == gd.rom.data, "no edit: identical ROM")

	# --- in place / grown ---------------------------------------------------------------------------------------
	var c0: Array = gd.conversation(0).duplicate(true)
	var c0b := c0.duplicate(true)
	c0b[1][1] = 0x3F
	check(p.set_conversation(0, c0b) == "", "conversation 0: line 2 given to the narrator")
	check(gd.conversation(0)[1][1] == 0x3F, "edit visible through GameData")
	var m := p.arm9_mod()
	var recs := gd.rom_conv_records()
	check(m.error == "" and m.ext.is_empty() and m.read(recs[0].ptr + 6, 1)[0] == 0x3F
		and m.read_u32(GameData.CONV_TABLE) == recs[0].ptr, "same size: rewritten in place, no extension")
	var c1: Array = gd.conversation(1).duplicate(true)
	c1.append([0x4A1, 0x40])
	check(p.set_conversation(1, c1) == "", "conversation 1: one line more")
	m = p.arm9_mod()
	var p1 := m.read_u32(GameData.CONV_TABLE + 8)
	check(m.error == "" and p1 >= Arm9Mod.EXT_BASE and m.read(GameData.CONV_TABLE + 12, 1)[0] == c1.size()
		and m.read(p1 + 4 * (c1.size() - 1), 4) == PackedByteArray([0xA1, 0x04, 0x40, 0]),
		"grown: lines moved to the extension 0x%08X" % p1)
	check(m.read_u32(GameData.CONV_LITERALS[0]) == GameData.CONV_TABLE and p.ovl_patches.is_empty(), "table not moved")
	var shared := -1
	for cid in recs.size():
		if recs[cid].ptr == 0x0211E9F4:
			shared = cid
			break
	var cs2: Array = gd.conversation(shared).duplicate(true)
	cs2[0][0] = 0x4A1
	check(p.set_conversation(shared, cs2) == "", "conversation %d (line array shared by 6) edited" % shared)
	m = p.arm9_mod()
	check(m.read_u32(GameData.CONV_TABLE + 8 * shared) >= Arm9Mod.EXT_BASE and m.read(0x0211E9F4, 2).decode_u16(0) != 0x4A1,
		"shared line array left alone, edited copy in the extension")

	# refusals
	check(p.set_conversation(0, []) != "", "empty conversation refused")
	check(p.set_conversation(0, [[0xFFFF, 22]]) != "", "unknown text id refused")
	check(p.set_conversation(0, [[0x49F, 0x41]]) != "", "speaker 0x41 refused")
	check(p.set_conversation(67, [[0x49F, 22]]) != "", "null conversation 67 refused")
	check(p.delete_conversation(5) != "", "deleting a game conversation refused")

	# --- new strings --------------------------------------------------------------------------------------------
	var n0 := p.text_count()
	check(p.add_string(LINE_A) == "" and p.last_index == n0, "new string 0x%X" % n0)
	var ok := true
	for l in GameData.LANGS:
		ok = ok and gd.bank(l).count() == n0 + 1 and gd.text(n0, l) == LINE_A
	check(ok, "added to the 6 banks")
	check(p.undo() == "" and gd.bank("ja").count() == n0 and gd.bank("en").count() == n0, "one undo removes it from the 6 banks")
	check(p.add_string(LINE_A) == "", "add again")
	check(p.add_string(LINE_B) == "" and p.last_index == n0 + 1, "second new string 0x%X" % (n0 + 1))
	check(p.add_string(MSG_A) == "", "third new string (message)")
	check(p.set_text("fr", n0, "Salut, étranger ! Une NOUVELLE conversation.") == "" and gd.text(n0, "en") == LINE_A,
		"new string translated in fr only")

	# --- new conversation / message -----------------------------------------------------------------------------
	var lines := [[n0, 22], [n0 + 1, 0x40], [0x4A1, 22]]
	check(p.add_conversation(lines) == "" and p.last_index == 217, "new conversation 217 (216 = 0xD8 = none skipped)")
	var cnew := p.last_index
	check(gd.n_conv() == 256 and gd.conversation(cnew) == lines and not gd.conv_exists(216), "table now 256 ids")
	check(p.add_conversation([[0x49F, 22]]) == "" and p.last_index == 218, "another one: 218")
	check(p.delete_conversation(218) == "" and gd.n_conv() == 218 and not gd.conv_exists(218), "218 deleted (trailing ids trimmed)")
	check(p.add_message(n0 + 2, -1) == "" and p.last_index == 26, "new message 26")
	check(p.set_message(26, 0x990, 99999) != "", "message with an unknown second text refused")
	check(p.add_message(0x990, -1) == "" and p.delete_message(27) == "" and gd.n_msg() == 27, "message 27 added and deleted")
	check(p.delete_message(3) != "", "deleting a game message refused")

	m = p.arm9_mod()
	var t := m.read_u32(GameData.CONV_LITERALS[0])
	check(m.error == "" and t >= Arm9Mod.EXT_BASE and m.read_u32(GameData.CONV_LITERALS[1]) == t, "table moved to 0x%08X" % t)
	check(p.ovl_patches.get(GameData.CONV_OV, {}).get(GameData.CONV_OV_LITERAL) == [GameData.CONV_TABLE, t], "overlay 15 patch planned")
	check(m.read_u32(t + 8) == p1 or m.read_u32(t + 8) >= Arm9Mod.EXT_BASE, "conversation 1 record copied")
	check(m.read_u32(t + 8 * 5) == recs[5].ptr and m.read_u32(t + 8 * 216) == 0, "untouched record copied, 216 null")
	var mt := m.read_u32(GameData.MSG_LITERAL)
	check(mt >= Arm9Mod.EXT_BASE and m.read_u32(mt + 8 * 26) == n0 + 2 and m.read_u32(mt + 8 * 27) == GameData.MSG_UNUSED,
		"message table moved to 0x%08X, 27 = unused" % mt)

	# --- game scenario: location 5 block 1 script 3 plays the new conversation then the new message ------------
	var loc := 5
	var EB := 1
	var blk: Layout.Block = p.load_layout(loc).blocks[EB]
	var ns := blk.scripts.size()
	var txt := LayScript.disassemble(blk.scripts, gd, "en", blk)
	check(txt.find("conversation(conv=0, group=1, script=25)") >= 0, "script 3 holds conversation(conv=0, group=1, script=25)")
	txt = txt.replace("conversation(conv=0, group=1, script=25)", "conversation(conv=%d, group=1, script=%d)" % [cnew, ns + 1])
	txt += "\nscript %d\n  message(msg=0x1a, script=25, queued=1)\n" % (ns + 1)
	var r := LayScript.assemble(txt, A)
	check(r.error == "", "edited scripts assemble (%s)" % r.error)
	check(p.set_scripts(loc, EB, r.scripts) == "", "scripts use conversation %d and message 26" % cnew)
	check(p.conv_users(cnew).size() == 1 and p.msg_users(26).size() == 1, "users found")
	check(p.delete_conversation(cnew) != "", "deleting a used conversation refused")
	var bad := LayScript.assemble("script 1\n  conversation(conv=230, group=0, script=0)\n", A)
	check(p.set_scripts(loc, EB, bad.scripts) != "", "script using a missing conversation refused")

	# --- export + reopen ----------------------------------------------------------------------------------------
	var out := out_dir.path_join("conv_test.nds")
	check(p.export_rom(out) == "", "export (%s)" % p.build_error)
	var g2 := GameData.new()
	check(g2.open(out), "exported ROM opens (%s)" % g2.error)
	check(g2.conv_table() == t and g2.n_conv() == 256, "reopened: table in the extension, 256 ids")
	var same := true
	for cid in 216:
		var want = gd.conversation(cid) if gd.conv_exists(cid) else null
		var got = g2.rom_conversations()[cid]
		same = same and want == got
	check(same, "reopened: the 216 original ids read back as edited")
	check(g2.conversation(cnew) == lines and g2.conversation(0)[1][1] == 0x3F and g2.conversation(1) == c1, "new and edited conversations read back")
	check(g2.rom_messages().size() == 27 and g2.message(26) == [n0 + 2, -1], "reopened: 27 messages")
	check(g2.text(n0, "en") == LINE_A and g2.text(n0 + 1, "en") == LINE_B and g2.text(n0, "fr").begins_with("Salut")
		and g2.bank("ja").count() == n0 + 3, "new strings in the reopened banks")
	var ov2 := g2.rom.overlay9_code(GameData.CONV_OV)
	var inf2 := g2.rom.overlay9_info(GameData.CONV_OV)
	check(not inf2.compressed and ov2.size() == 0xF00 and ov2.decode_u32(GameData.CONV_OV_LITERAL - inf2.ram) == t,
		"overlay 15 stored uncompressed, literal = new table")
	var diff := 0
	for i in ov.size():
		if ov[i] != ov2[i]:
			diff += 1
	check(diff <= 4, "overlay 15 differs from the original in %d bytes (the literal only)" % diff)
	var other := 0
	for i in g2.rom.overlay9_count():
		if i != GameData.CONV_OV and gd.rom.overlay9_code(i) != g2.rom.overlay9_code(i):
			other += 1
	check(other == 0, "the other overlays are unchanged")

	# --- second round on top of the exported ROM ----------------------------------------------------------------
	var p2 := EditProject.new(g2)
	p2.discard_all()
	check(p2.build_rom() == g2.rom.data, "reopened, no edit: identical ROM")
	check(p2.add_conversation([[0x4A0, 22]]) == "" and p2.last_index == 218, "new conversation 218 on the exported ROM")
	check(p2.set_conversation(cnew, [[n0, 22]]) == "", "conversation %d shortened" % cnew)
	check(p2.add_message(0x991, -1) == "" and p2.last_index == 27, "message 27")
	var out2 := out_dir.path_join("conv_test2.nds")
	check(p2.export_rom(out2) == "", "second export (%s)" % p2.build_error)
	var g3 := GameData.new()
	check(g3.open(out2), "second export opens")
	check(g3.conv_table() == t and g3.conversation(218) == [[0x4A0, 22]] and g3.conversation(cnew) == [[n0, 22]]
		and g3.conversation(5) == gd.conversation(5), "second export: table not moved again, edits read back")
	check(g3.rom_messages().size() == 28 and g3.message(27) == [0x991, -1], "second export: 28 messages")
	p2.discard_all()

	p.discard_all()
	print("fails: ", fails)
	quit(1 if fails else 0)
