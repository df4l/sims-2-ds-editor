extends SceneTree
## Smoke test of the Locations tab: Godot --path godot --script res://tests/test_locations_ui.gd -- rom.nds [room.glb]
## (needs a window: not --headless). Create a new location from the tab, set its price, open it, undo, delete;
## with room.glb (written by tests/test_scene.gd): import it as the scene of a new location, then drop it.
## The project folder of the input ROM is wiped first and at the end.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func _init() -> void:
	_run.call_deferred()


## Buttons of the Locations tab with this text, in order.
func _buttons(ui, text: String) -> Array:
	var out := []
	var stack: Array = [ui.locs_box]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n is Button and not n is CheckBox and n.text == text:
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _first(ui, cls) -> Node:
	var stack: Array = [ui.locs_box]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if is_instance_of(n, cls):
			return n
		stack.append_array(n.get_children())
	return null


func _picker_has(ui, id: int) -> bool:
	for i in ui.loc_opt.item_count:
		if ui.loc_opt.get_item_id(i) == id:
			return true
	return false


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
	ui.open_location(6)
	ui.msg_dlg.hide()
	ui._render_locations(true)

	var name_in: LineEdit = _first(ui, LineEdit)
	check(name_in != null and _buttons(ui, "Create").size() == 1, "tab shows the creation form")
	name_in.text = "UI Test Hall"
	_buttons(ui, "Create")[0].pressed.emit()
	await process_frame
	await process_frame
	check(ui.gd.has_location(34) and ui.gd.place(34) == "UI Test Hall", "Create -> location 34 named")
	check(ui.loc == 34 and ui.lay != null, "new location opened with its layout")
	check(_picker_has(ui, 34), "picker lists 34")
	check(_buttons(ui, "Apply").size() == 1 and _buttons(ui, "Delete").size() == 1, "34 has its edit row")

	# price through the row's spin boxes (first SpinBox = price)
	var sp: SpinBox = _first(ui, SpinBox)
	sp.value = 750
	_buttons(ui, "Apply")[0].pressed.emit()
	await process_frame
	check(ui.proj.newloc(34).price == 750, "Apply sets the price")
	ui.do_undo()
	await process_frame
	check(ui.proj.newloc(34).price == 0, "undo reverts it")

	ui.do_undo()
	for _i in 4:
		await process_frame
	check(not ui.gd.has_location(34) and not _picker_has(ui, 34), "undo of the creation removes 34 from the picker")
	check(ui.loc == 5, "the editor left the removed location")

	# again, then Delete (the confirm dialog's callback is run directly)
	ui.proj.add_new_location(9, "UI Tmp")
	ui._render_locations(true)
	check(_picker_has(ui, 34), "re-created")
	_buttons(ui, "Delete")[0].pressed.emit()
	ui._confirm_cb.call()
	await process_frame
	check(not ui.gd.has_location(34), "Delete removes it")

	# own 3D scene: import the test room written by tests/test_scene.gd (2nd argument), then back to the template
	if OS.get_cmdline_user_args().size() > 1:
		ui.proj.add_new_location(6, "UI Scene")
		ui.open_location(34)
		ui._render_locations(true)
		check(_buttons(ui, "Import .glb / .gltf…").size() == 1 and _buttons(ui, "Use the template's").is_empty(),
			"34 offers the scene import, no 'template' button yet")
		ui._scene_opts = {"id": 34, "scale": 1.0, "thickness": 0.5, "auto": true}
		ui._import_scene(OS.get_cmdline_user_args()[1])
		ui.msg_dlg.hide()
		for _i in 4:
			await process_frame
		ui._render_locations()
		check(ui.proj.has_scene(34) and ui.gd.loc(34).models[0].model == EditProject.SCENE + 34, "import -> own scene")
		check(ui.msg_dlg.dialog_text.find("triangles") >= 0, "import report shown: " + ui.msg_dlg.dialog_text.replace("
", " | "))
		check(_buttons(ui, "Use the template's").size() == 1, "tab re-rendered with the 'template' button")
		check(ui.view3d.get_mesh(EditProject.SCENE + 34, -1) != null, "3D view builds the imported model")
		_buttons(ui, "Use the template's")[0].pressed.emit()
		await process_frame
		check(not ui.proj.has_scene(34), "'Use the template's' drops the own scene")

	ui.proj.discard_all()
	print("FAILURES: ", fails)
	quit(1 if fails else 0)
