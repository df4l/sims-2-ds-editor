extends SceneTree
## Smoke test of the Dialogue tab: Godot --path godot --script res://tests/test_dialogue_ui.gd -- rom.nds
## (needs a window: not --headless). New conversation, new string line, speaker change, apply, undo, new message.
## The project folder of the input ROM is wiped first and at the end.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var rom: String = OS.get_cmdline_user_args()[0]
	var ui = load("res://scenes/main.tscn").instantiate()
	root.add_child(ui)
	for _i in 5:
		await process_frame
	ui.open_rom(rom)
	for _i in 5:
		await process_frame
	ui.proj.discard_all()
	ui.open_location(5)
	ui.msg_dlg.hide()

	ui._dlg_new()
	var cid: int = ui.dlg_id
	check(cid == 217 and ui.gd.conv_exists(217), "New -> conversation 217")
	ui.dlg_new_text.text = "UI smoke test line"
	ui._dlg_add_new_string_line()
	var sid: int = ui.proj.last_index
	check(ui.dlg_work.size() == 2 and ui.dlg_work[1][0] == sid, "new string 0x%X appended as line 2 (not applied yet)" % sid)
	check(ui.gd.conversation(217).size() == 1, "table unchanged before Apply")
	ui.dlg_work[1][1] = 0x40
	ui._dlg_apply()
	check(ui.gd.conversation(217) == [[0x49F, 0x3F], [sid, 0x40]], "Apply saves the lines")
	await process_frame
	check(ui.dlg_list.item_count > 200, "list shows the conversations (%d)" % ui.dlg_list.item_count)
	ui.dlg_search.text = "UI smoke"
	ui._refresh_dialogue(true)
	check(ui.dlg_list.item_count == 1 and ui.dlg_list.get_item_metadata(0) == 217, "search finds it by line text")
	ui.do_undo()
	check(ui.gd.conversation(217).size() == 1, "undo reverts the Apply")
	ui._dlg_select(217)
	ui._dlg_delete()
	check(not ui.gd.conv_exists(217), "Delete removes the new conversation")

	ui.dlg_mode_opt.select(1)
	ui.dlg_id = -1
	ui.dlg_search.text = ""
	ui._refresh_dialogue(true)
	check(ui.dlg_list.item_count == 26, "messages mode lists 26")
	ui._dlg_select(3)
	ui._dlg_new()
	check(ui.dlg_id == 26 and ui.gd.message(26)[0] == ui.gd.message(3)[0], "New message 26 (copies the selected one's text)")
	ui.dlg_work[1] = sid
	ui._dlg_apply()
	check(ui.gd.message(26) == [ui.gd.message(3)[0], sid], "message second text applied")
	await process_frame
	ui.proj.discard_all()
	print("fails: ", fails)
	quit(1 if fails else 0)
