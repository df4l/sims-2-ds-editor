extends Control
## Sims 2 DS map editor: start screen (pick a ROM), then the editor (location picker, top-down / 3D views,
## item list, selection form, add-item palette, scripts). Everything is read from the opened ROM; edits are kept
## in user://projects/<rom sha1>/ and written into a new ROM by File > Export ROM.

const View2D := preload("res://scripts/ui/view2d.gd")
const View3D := preload("res://scripts/ui/view3d.gd")
const SETTINGS := "user://settings.cfg"

var gd: GameData
var proj: EditProject

# location state
var loc := -1
var lay: Layout
var block := 0
var lang := "en"
var sel := ""
var mode := "items"        # items | cells
var cell = null            # selected brush dict (cells mode)
var cell_at := Vector2.ZERO
var placing := false
var pal_type := 2
var pal_group := ""
var pal_vals := {}
var items := []            # visible items (dicts)
var brushes := []          # Bsp.brushes() of the current collision
var brushes2d := []        # {poly, col, top, brush}
var furniture := {}        # {slot, grid, items}
var show_bsp := true
var show_scene := true
var show_models := true
var show_labels := false
var view := "2d"

var _brush_cache := {}
var _icons := {}
var _opts := {}            # cached picker options per lang
var _tree_items := {}

# UI
var start_screen: Control
var recent_box: VBoxContainer
var start_msg: Label
var editor: Control
var loc_opt: OptionButton
var block_opt: OptionButton
var lang_opt: OptionButton
var tab2d: Button
var tab3d: Button
var cells_btn: Button
var undo_btn: Button
var status_lbl: Label
var edited_lbl: Label
var view2d: Control
var view3d: SubViewportContainer
var tree: Tree
var tabs: TabContainer
var details: VBoxContainer
var palette: VBoxContainer
var script_edit: CodeEdit
var script_block_opt: OptionButton
var script_info: Label
var ops_dlg: AcceptDialog
var _script_sig := []        # [loc, block, lang, layout hash] of the text in script_edit
var _script_dirty := false
var _script_setting := false
var text_search: LineEdit
var text_only_edited: CheckBox
var text_list: ItemList
var text_edit: TextEdit
var text_info: Label
var text_id := -1
var _text_sig := []
var open_dlg: FileDialog
var save_dlg: FileDialog
var save_kind := "nds"      # what save_dlg writes: "nds" or "bps"
var emu_dlg: FileDialog
var msg_dlg: AcceptDialog
var confirm_dlg: ConfirmationDialog
var _confirm_cb := Callable()


func _ready() -> void:
	_build_dialogs()
	_build_start()
	_build_editor()
	editor.visible = false
	get_window().files_dropped.connect(_on_files_dropped)
	get_window().title = "Sims 2 DS Map Editor"
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and args[0].to_lower().ends_with(".nds"):
		open_rom.call_deferred(args[0])
		for a in args:
			if a.begins_with("--shot="):
				_debug_shot.call_deferred(a.trim_prefix("--shot="), args)


## Test hook: Godot --path godot -- rom.nds --shot=out.png [--loc=N] [--3d] [--sel=key] [--cells]
func _debug_shot(out: String, args: PackedStringArray) -> void:
	for _i in 30:
		await get_tree().process_frame
	for a in args:
		if a.begins_with("--loc="):
			open_location(a.trim_prefix("--loc=").to_int())
		if a == "--3d":
			set_view("3d")
		if a == "--cells":
			set_mode("cells")
	for a in args:
		if a.begins_with("--sel="):
			select(a.trim_prefix("--sel="))
		if a.begins_with("--tab="):
			tabs.current_tab = a.trim_prefix("--tab=").to_int()
		if a.begins_with("--script-line="):
			tabs.current_tab = 2
			var ln := a.trim_prefix("--script-line=").to_int()
			script_edit.set_caret_line(ln)
			script_edit.scroll_vertical = maxi(0, ln - 3)
		if a.begins_with("--text="):
			text_search.text = a.trim_prefix("--text=")
			_refresh_text_list(true)
			if text_list.item_count:
				_select_text(text_list.get_item_metadata(0))
	for _i in 240:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


func _on_files_dropped(files: PackedStringArray) -> void:
	if not files.is_empty():
		open_rom(files[0])


# =================================================================================================================
# dialogs / start screen
# =================================================================================================================

func _build_dialogs() -> void:
	open_dlg = FileDialog.new()
	open_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dlg.access = FileDialog.ACCESS_FILESYSTEM
	open_dlg.use_native_dialog = true
	open_dlg.filters = PackedStringArray(["*.nds ; Nintendo DS ROM"])
	open_dlg.title = "Open a Sims 2 DS ROM"
	open_dlg.file_selected.connect(open_rom)
	add_child(open_dlg)
	save_dlg = FileDialog.new()
	save_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dlg.access = FileDialog.ACCESS_FILESYSTEM
	save_dlg.use_native_dialog = true
	save_dlg.filters = PackedStringArray(["*.nds ; Nintendo DS ROM"])
	save_dlg.title = "Export the edited ROM"
	save_dlg.file_selected.connect(_export_to)
	add_child(save_dlg)
	emu_dlg = FileDialog.new()
	emu_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	emu_dlg.access = FileDialog.ACCESS_FILESYSTEM
	emu_dlg.use_native_dialog = true
	emu_dlg.title = "Choose the emulator program (melonDS…)"
	emu_dlg.file_selected.connect(func(path):
		_set_setting("emulator", path)
		if proj != null:
			_test_in_emulator())
	add_child(emu_dlg)
	msg_dlg = AcceptDialog.new()
	msg_dlg.dialog_autowrap = true
	msg_dlg.min_size = Vector2i(460, 0)
	add_child(msg_dlg)
	confirm_dlg = ConfirmationDialog.new()
	confirm_dlg.dialog_autowrap = true
	confirm_dlg.min_size = Vector2i(460, 0)
	confirm_dlg.confirmed.connect(_on_confirmed)
	add_child(confirm_dlg)


func _on_confirmed() -> void:
	if _confirm_cb.is_valid():
		_confirm_cb.call()


func show_msg(text: String, title := "Sims 2 DS Map Editor") -> void:
	msg_dlg.title = title
	msg_dlg.dialog_text = text
	msg_dlg.popup_centered()


func ask(text: String, cb: Callable) -> void:
	confirm_dlg.dialog_text = text
	_confirm_cb = cb
	confirm_dlg.popup_centered()


func _build_start() -> void:
	start_screen = CenterContainer.new()
	start_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(start_screen)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	start_screen.add_child(panel)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 28)
	panel.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	m.add_child(v)
	var t := Label.new()
	t.text = "Sims 2 DS Map Editor"
	t.add_theme_font_size_override("font_size", 30)
	v.add_child(t)
	v.add_child(W.label("Open your own copy of The Sims 2 (Nintendo DS). Nothing is written to it: edits are saved " +
		"with the editor and exported to a new ROM file. Made on the European ROM (ASJP).", W.MUTED))
	var b := W.button("Open a ROM (.nds)…", func(): open_dlg.popup_centered_ratio(0.6))
	b.custom_minimum_size.y = 40
	v.add_child(b)
	v.add_child(W.label("…or drop a .nds file on this window.", W.MUTED))
	start_msg = W.label("", W.WARN)
	v.add_child(start_msg)
	v.add_child(W.label("Recent ROMs", W.MUTED, false))
	recent_box = VBoxContainer.new()
	v.add_child(recent_box)
	_fill_recent()


func _recent() -> Array:
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	return cf.get_value("main", "recent", [])


func _add_recent(p: String) -> void:
	var r := _recent()
	r.erase(p)
	r.push_front(p)
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("main", "recent", r.slice(0, 8))
	cf.save(SETTINGS)
	_fill_recent()


func _fill_recent() -> void:
	W.clear(recent_box)
	var r := _recent()
	if r.is_empty():
		recent_box.add_child(W.label("none yet", W.MUTED))
	for p in r:
		var b := W.button(p.get_file(), open_rom.bind(p), p)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = not FileAccess.file_exists(p)
		recent_box.add_child(b)


func open_rom(path: String) -> void:
	start_msg.text = "Opening %s…" % path.get_file()
	await get_tree().process_frame
	await get_tree().process_frame
	var g := GameData.new()
	if not g.open(path):
		start_msg.text = "Cannot open %s: %s" % [path.get_file(), g.error]
		if editor.visible:
			show_msg(start_msg.text)
		return
	gd = g
	proj = EditProject.new(gd)
	_brush_cache.clear()
	_icons.clear()
	_opts.clear()
	view3d.meshes.clear()
	_add_recent(path)
	start_msg.text = ""
	start_screen.visible = false
	editor.visible = true
	get_window().title = "Sims 2 DS Map Editor — %s" % path.get_file()
	loc_opt.clear()
	for L in gd.locations:
		loc_opt.add_item("%d · %s%s" % [L.location, L.place, "" if L.nav != GameData.NONE else "  (no layout)"], L.location)
	open_location(5)
	if gd.warning != "":
		show_msg(gd.warning, "Unexpected ROM version")
	if not proj.edits.is_empty():
		status("%s: %d edited file(s) restored from the previous session" % [path.get_file(), proj.edits.size()])


func close_rom() -> void:
	gd = null
	proj = null
	editor.visible = false
	start_screen.visible = true
	view3d.clear_all()
	get_window().title = "Sims 2 DS Map Editor"
	_fill_recent()


# =================================================================================================================
# editor layout
# =================================================================================================================

func _build_editor() -> void:
	editor = VBoxContainer.new()
	editor.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(editor)
	var top := HFlowContainer.new()
	top.add_theme_constant_override("separation", 6)
	var tm := MarginContainer.new()
	for s in ["left", "right", "top"]:
		tm.add_theme_constant_override("margin_" + s, 6)
	tm.add_child(top)
	editor.add_child(tm)

	var file := MenuButton.new()
	file.text = "File"
	file.flat = false
	var pm := file.get_popup()
	pm.add_item("Open ROM…", 0)
	pm.add_item("Export edited ROM…", 1)
	pm.add_item("Export as BPS patch…", 4)
	pm.add_item("Test in emulator (F5)", 5)
	pm.add_item("Choose emulator…", 6)
	pm.add_separator()
	pm.add_item("Discard every edit…", 2)
	pm.add_item("Close ROM", 3)
	pm.id_pressed.connect(_on_file_menu)
	top.add_child(file)
	top.add_child(W.label("Location", W.MUTED, false))
	loc_opt = OptionButton.new()
	loc_opt.custom_minimum_size.x = 250
	loc_opt.item_selected.connect(func(i): open_location(loc_opt.get_item_id(i)))
	top.add_child(loc_opt)
	top.add_child(W.label("Variant", W.MUTED, false))
	block_opt = OptionButton.new()
	block_opt.item_selected.connect(func(i):
		block = block_opt.get_item_id(i)
		_rebuild_view(false))
	top.add_child(block_opt)
	top.add_child(W.label("Text", W.MUTED, false))
	lang_opt = OptionButton.new()
	for l in GameData.LANGS:
		lang_opt.add_item(l)
	lang_opt.item_selected.connect(func(i):
		lang = GameData.LANGS[i]
		_rebuild_view(false))
	top.add_child(lang_opt)
	top.add_child(VSeparator.new())
	tab2d = W.button("Top-down", set_view.bind("2d"))
	tab2d.toggle_mode = true
	tab3d = W.button("3D", set_view.bind("3d"))
	tab3d.toggle_mode = true
	top.add_child(tab2d)
	top.add_child(tab3d)
	top.add_child(VSeparator.new())
	top.add_child(W.toggle("Collision", true, _set_flag.bind("show_bsp")))
	top.add_child(W.toggle("Scene", true, _set_flag.bind("show_scene")))
	top.add_child(W.toggle("Item models", true, _set_flag.bind("show_models")))
	top.add_child(W.toggle("Labels", false, _set_flag.bind("show_labels")))
	top.add_child(VSeparator.new())
	cells_btn = W.button("Edit collision", func(): set_mode("items" if mode == "cells" else "cells"),
		"Click collision cells instead of items (top-down view)")
	cells_btn.toggle_mode = true
	top.add_child(cells_btn)
	undo_btn = W.button("Undo", do_undo, "Ctrl+Z")
	top.add_child(undo_btn)
	top.add_child(W.button("Revert location", _revert_location, "Drop every edit of this location's layout, collision and room furniture"))
	top.add_child(W.button("Export ROM…", _export_dialog, "Write a new .nds with every edit"))
	top.add_child(W.button("Test ▶", _test_in_emulator, "Export to a temporary ROM and open it in the emulator (F5)"))
	edited_lbl = W.label("", W.MUTED, false)
	top.add_child(edited_lbl)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = -460
	editor.add_child(split)
	var views := Control.new()
	views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	views.clip_contents = true
	split.add_child(views)
	view2d = View2D.new()
	view2d.ed = self
	view2d.set_anchors_preset(Control.PRESET_FULL_RECT)
	views.add_child(view2d)
	view3d = View3D.new()
	view3d.ed = self
	view3d.set_anchors_preset(Control.PRESET_FULL_RECT)
	views.add_child(view3d)
	view3d.set_active(false)

	var side := VSplitContainer.new()
	side.custom_minimum_size.x = 440
	side.split_offset = 0
	split.add_child(side)
	var tbox := VBoxContainer.new()
	tbox.custom_minimum_size.y = 220
	tbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tbox.add_child(W.label("Items", W.MUTED, false))
	tree = Tree.new()
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.item_selected.connect(_on_tree_selected)
	tbox.add_child(tree)
	side.add_child(tbox)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size.y = 360
	side.add_child(tabs)
	details = _scroll_tab("Selection")
	palette = _scroll_tab("Add item")
	_build_scripts_tab()
	_build_text_tab()

	var bottom := MarginContainer.new()
	bottom.add_theme_constant_override("margin_left", 8)
	status_lbl = W.label("", W.MUTED, false)
	status_lbl.clip_text = true
	bottom.add_child(status_lbl)
	editor.add_child(bottom)
	set_view("2d")


func _build_text_tab() -> void:
	var m := MarginContainer.new()
	m.name = "Text"
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 8)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	m.add_child(v)
	text_search = LineEdit.new()
	text_search.placeholder_text = "Search text, or an id (0x49f)"
	text_search.clear_button_enabled = true
	text_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_search.text_changed.connect(func(_t): _refresh_text_list(true))
	text_only_edited = W.toggle("Edited only", false, func(_on): _refresh_text_list(true))
	v.add_child(W.hbox([text_search, text_only_edited]))
	text_list = ItemList.new()
	text_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_list.custom_minimum_size.y = 120
	text_list.item_selected.connect(func(i): _select_text(text_list.get_item_metadata(i)))
	v.add_child(text_list)
	text_edit = TextEdit.new()
	text_edit.custom_minimum_size.y = 110
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text_edit.text_changed.connect(_text_counter)
	v.add_child(text_edit)
	text_info = W.label("", W.MUTED)
	v.add_child(text_info)
	v.add_child(W.hbox([
		W.button("Apply", _apply_text, "Save this string into the text bank of the current language"),
		W.button("Original", _revert_text, "Put back the ROM's version of this string")]))
	v.add_child(W.label("Accented letters À…ü, © ® ° … ¿ ¡ are available; {xx} / {xxxx} write raw codes; @1, @2… are "
		+ "the game's placeholders (Sim name, numbers). The game reads the text once at boot: check edits from a fresh boot, not a savestate.", W.MUTED))
	tabs.add_child(m)


## Rebuild the string list when the language / bank changed (or `force`).
func _refresh_text_list(force := false) -> void:
	if gd == null or text_list == null:
		return
	var bank := gd.bank(lang)
	var sig := [lang, bank.get_instance_id()]
	if not force and sig == _text_sig:
		return
	var bank_changed := sig != _text_sig
	_text_sig = sig
	var q := text_search.text.strip_edges()
	var want_id := -1
	if q.to_lower().begins_with("0x") and q.substr(2).is_valid_hex_number():
		want_id = q.substr(2).hex_to_int()
	var ql := q.to_lower()
	text_list.clear()
	var edited := {}
	if proj.is_edited("text", GameData.BANKS[lang]):
		for i in proj.edited_text_ids(lang):
			edited[i] = true
	for i in bank.count():
		if text_only_edited.button_pressed and not edited.has(i):
			continue
		var t := bank.text(i)
		if want_id >= 0:
			if i != want_id:
				continue
		elif ql != "" and t.to_lower().find(ql) < 0:
			continue
		var one := t.replace("\n", " ⏎ ")
		if one.length() > 100:
			one = one.substr(0, 100) + "…"
		var row := text_list.add_item("%04X  %s" % [i, one])
		text_list.set_item_metadata(row, i)
		if edited.has(i):
			text_list.set_item_custom_fg_color(row, W.WARN)
		if i == text_id:
			text_list.select(row)
	if bank_changed and text_id >= 0:
		_select_text(text_id)


func _select_text(id: int) -> void:
	text_id = id
	if id < 0 or id >= gd.bank(lang).count():
		text_edit.text = ""
		return
	text_edit.text = proj.text_of(lang, id)
	_text_counter()


func _text_counter() -> void:
	if text_id < 0:
		text_info.text = "Select a string."
		return
	var enc := TextBank.from_str(text_edit.text)
	var head := "%s 0x%04X%s · " % [lang, text_id, " (edited)" if proj.is_text_edited(lang, text_id) else ""]
	if enc.error != "":
		text_info.text = head + enc.error
		text_info.add_theme_color_override("font_color", W.WARN)
	else:
		text_info.text = head + "%d / %d bytes" % [enc.bytes.size(), TextBank.MAX_BYTES - 1]
		text_info.add_theme_color_override("font_color", W.MUTED)


func _apply_text() -> void:
	if text_id < 0:
		return
	if not apply(proj.set_text(lang, text_id, text_edit.text)):
		return
	_opts.clear()
	_text_counter()
	status("String %s 0x%04X saved%s. The game reads the text at boot: test from a fresh boot." % [lang, text_id,
		" (Huffman tree rebuilt for new characters)" if proj.last_tree_rebuilt else ""])


func _revert_text() -> void:
	if text_id < 0:
		return
	text_edit.text = proj.original_text(lang, text_id)
	_apply_text()


func _scroll_tab(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 8)
	sc.add_child(m)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	m.add_child(v)
	tabs.add_child(sc)
	return v


func status(t: String) -> void:
	status_lbl.text = t


func _on_file_menu(id: int) -> void:
	match id:
		0: open_dlg.popup_centered_ratio(0.6)
		1: _export_dialog()
		4: _export_dialog("bps")
		5: _test_in_emulator()
		6: emu_dlg.popup_centered_ratio(0.6)
		2: ask("Drop every edit of this ROM (layouts, collision, room furniture, text)? This cannot be undone.", func():
			proj.discard_all()
			_reload())
		3: close_rom()


func set_view(v: String) -> void:
	view = v
	tab2d.set_pressed_no_signal(v == "2d")
	tab3d.set_pressed_no_signal(v == "3d")
	view2d.visible = v == "2d"
	view3d.set_active(v == "3d")
	view2d.queue_redraw()


func set_mode(m: String) -> void:
	mode = m
	cell = null
	cells_btn.set_pressed_no_signal(m == "cells")
	if m == "cells":
		set_view("2d")
		show_bsp = true
		select_cell(null, Vector2.ZERO)
	else:
		render_details()
	view2d.queue_redraw()


func _set_flag(on: bool, prop: String) -> void:
	set(prop, on)
	_redraw_views()


func _redraw_views() -> void:
	view2d.queue_redraw()
	view3d.update_visibility()


func _unhandled_key_input(e: InputEvent) -> void:
	if gd == null or not e.is_pressed() or e.is_echo():
		return
	var k := e as InputEventKey
	if k.keycode == KEY_ESCAPE and placing:
		placing = false
		render_palette()
		status("Placing cancelled")
		view2d.queue_redraw()
	elif k.keycode == KEY_Z and k.ctrl_pressed:
		do_undo()
	elif k.keycode == KEY_F5:
		_test_in_emulator()
	elif k.keycode == KEY_DELETE and mode == "items":
		var it = _find(sel)
		if it != null and it.kind == "item":
			_delete_item(it)


# =================================================================================================================
# location loading
# =================================================================================================================

func open_location(id: int, keep := false) -> void:
	var cam2 := [view2d.cx, view2d.cz, view2d.scale_px]
	loc = id
	for i in loc_opt.item_count:
		if loc_opt.get_item_id(i) == id:
			loc_opt.select(i)
	lay = proj.load_layout(loc)
	if lay != null and lay.error != "":
		show_msg("Layout of location %d does not parse: %s" % [loc, lay.error])
		lay = null
	if not keep:
		sel = ""
		cell = null
		placing = false
		block = 1 if lay != null and lay.blocks.size() > 1 else 0
	if lay == null or block >= lay.blocks.size():
		block = 0
	block_opt.clear()
	var nb := lay.blocks.size() if lay != null else 1
	for k in nb:
		block_opt.add_item("block 0 only" if k == 0 else "block 0 + %d" % k, k)
	block_opt.select(block)
	# collision (cached by content)
	var bd := proj.current("bsp", gd.locations[loc].bsp)
	var h := hash(bd)
	if not _brush_cache.has(h):
		var t := Bsp.parse(bd)
		_brush_cache[h] = t.brushes() if t.error == "" else []
		if t.error != "":
			show_msg("Collision of location %d does not parse: %s" % [loc, t.error])
	brushes = _brush_cache[h]
	_prepare2d()
	_rebuild_view(not keep)
	if keep:
		view2d.cx = cam2[0]
		view2d.cz = cam2[1]
		view2d.scale_px = cam2[2]
	if mode == "cells":
		select_cell(null, Vector2.ZERO)


func _reload() -> void:
	open_location(loc, true)


func _rebuild_view(refit: bool) -> void:
	_build_items()
	_render_tree()
	_render_scripts()
	_refresh_text_list()
	if _find(sel) == null:
		sel = ""
	if mode == "items":
		render_details()
	render_palette()
	if refit:
		view2d.fit.call_deferred()
	view2d.queue_redraw()
	view3d.load_location(refit)
	_show_edited()


func _visible_blocks() -> Array:
	if lay == null:
		return []
	return [0] if block == 0 else [0, block]


func model_of(it: Layout.Item) -> int:
	match it.type:
		1:
			return gd.npc_model(it.raw[0xE]) if it.raw[0xE] < GameData.N_NPCS else -1
		2:
			return gd.prop_model(it.raw[0xE]) if it.raw[0xE] < GameData.N_PROPS else -1
		10:
			var p: int = it.raw[8] + Layout.TIMED_PROP_BIAS
			return gd.prop_model(p) if p < GameData.N_PROPS else -1
		4:
			return gd.object_model(it.raw[0x13]) if it.raw[0x13] < GameData.N_OBJECTS else -1
	return -1


func _build_items() -> void:
	items.clear()
	for b in _visible_blocks():
		var blk: Layout.Block = lay.blocks[b]
		for g in blk.groups.size():
			for i in blk.groups[g].items.size():
				var it: Layout.Item = blk.groups[g].items[i]
				var m := model_of(it)
				var prop := -1
				if it.type == 2:
					prop = it.raw[0xE]
				elif it.type == 10:
					prop = it.raw[8] + Layout.TIMED_PROP_BIAS
				var ad = it.angle_deg()
				var mname := gd.model_name(m) if m >= 0 else ""
				items.append({"key": "%d/%d/%d" % [b, g, i], "kind": "item", "type": it.type, "block": b, "group": g,
					"index": i, "x": float(it.x), "y": float(it.y), "z": float(it.z),
					"angle": deg_to_rad(ad) if ad != null else null, "half_size": it.half_size(), "model": m,
					"model_tex": proj.furn.prop_texture(prop) if prop >= 0 else -1, "model_name": mname,
					"label": mname if mname != "" else str(W.NAMES.get(it.type, it.type)), "item": it})
	if lay != null:
		for k in lay.entries.size():
			var e: PackedByteArray = lay.entries[k]
			items.append({"key": "e/%d" % k, "kind": "entry", "type": "entry", "index": k, "id": e[0xC],
				"x": float(e.decode_s16(0)), "y": float(e.decode_s16(2)), "z": float(e.decode_s16(4)),
				"angle": e.decode_s16(6) / 4096.0, "half_size": null, "model": -1, "model_tex": -1,
				"label": "entry %d" % e[0xC]})
	furniture = {}
	var slot := proj.furniture_slot(loc)
	if slot >= 0:
		var grid := proj.furn.grid(slot)
		furniture = {"slot": slot, "grid": grid, "items": proj.furn.room_items(slot, proj.furniture_list(slot))}
		for f in furniture.items:
			if not f.placed:
				continue
			var m := gd.prop_model(f.prop)
			var nm := gd.model_name(m)
			items.append({"key": "f/%d" % f.index, "kind": "furniture", "type": "furniture", "index": f.index,
				"x": f.pos.x, "y": f.pos.y, "z": f.pos.z, "angle": f.angle, "half_size": null, "model": m,
				"model_tex": proj.furn.prop_texture(f.prop), "model_name": nm, "label": nm, "prop": f.prop,
				"cell": Vector2i(f.x, f.z), "rot": f.rot, "wall": f.wall, "along": f.along, "exact": f.exact})


func _find(key: String):
	for it in items:
		if it.key == key:
			return it
	return null


static func _hull(pts: Array) -> PackedVector2Array:
	pts.sort_custom(func(a, b): return a.x < b.x or (a.x == b.x and a.y < b.y))
	if pts.size() < 3:
		return PackedVector2Array(pts)
	var cross := func(o: Vector2, a: Vector2, b: Vector2) -> float:
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	var lo := []
	for p in pts:
		while lo.size() >= 2 and cross.call(lo[-2], lo[-1], p) <= 0:
			lo.pop_back()
		lo.append(p)
	var hi := []
	for k in range(pts.size() - 1, -1, -1):
		var p: Vector2 = pts[k]
		while hi.size() >= 2 and cross.call(hi[-2], hi[-1], p) <= 0:
			hi.pop_back()
		hi.append(p)
	lo.pop_back()
	hi.pop_back()
	return PackedVector2Array(lo + hi)


func _prepare2d() -> void:
	brushes2d.clear()
	var ylo := INF
	var yhi := -INF
	for b in brushes:
		ylo = minf(ylo, b.lo.y)
		yhi = maxf(yhi, b.hi.y)
	for b in brushes:
		var top: float = b.hi.y
		var hgt: float = b.hi.y - b.lo.y
		var t := (top - ylo) / maxf(yhi - ylo, 1)
		var col: Color
		if hgt < 8:
			col = Color8(int(60 + 150 * t), int(90 + 120 * t), 200)
		else:
			col = Color8(int(170 + 80 * t), int(80 + 60 * t), 60)
		var pts := []
		for v in b.verts:
			var p := Vector2(snappedf(v.x, 0.001), snappedf(v.z, 0.001))
			if not p in pts:
				pts.append(p)
		brushes2d.append({"top": top, "col": col, "brush": b, "poly": _hull(pts)})
	brushes2d.sort_custom(func(a, b): return a.top < b.top)


func _show_edited() -> void:
	var here := []
	var nav := proj.nav_of(loc)
	if nav >= 0 and proj.is_edited("layout", nav):
		here.append("layout")
	if proj.is_edited("bsp", gd.locations[loc].bsp):
		here.append("collision")
	var slot := proj.furniture_slot(loc)
	if slot >= 0 and proj.is_edited("furniture", slot):
		here.append("furniture")
	edited_lbl.text = "%d edited file(s)%s" % [proj.edits.size(), (" · here: " + " + ".join(here)) if not here.is_empty() else ""]
	undo_btn.disabled = proj.undo_stack.is_empty()
	status("%s · layout %s · BSP %d · %d solid cells" % [gd.locations[loc].place, str(nav) if nav >= 0 else "—",
		gd.locations[loc].bsp, brushes.size()])


# =================================================================================================================
# item list / scripts
# =================================================================================================================

func _render_tree() -> void:
	tree.clear()
	_tree_items.clear()
	var root := tree.create_item()
	var groups := {}
	for it in items:
		var gname: String
		match it.kind:
			"entry": gname = "Entry points"
			"furniture": gname = "Room furniture (default, arm9)"
			_: gname = "Block %d · group %d" % [it.block, it.group]
		if not groups.has(gname):
			var gi := tree.create_item(root)
			gi.set_text(0, gname)
			gi.set_selectable(0, false)
			gi.set_custom_color(0, W.MUTED)
			groups[gname] = gi
		var ti := tree.create_item(groups[gname])
		ti.set_text(0, "%s   (%s, %s, %s)" % [it.label, W.fmt(it.x), W.fmt(it.y), W.fmt(it.z)])
		ti.set_icon(0, _dot(W.color_of(it.type)))
		ti.set_metadata(0, it.key)
		_tree_items[it.key] = ti


var _dots := {}


func _dot(c: Color) -> Texture2D:
	if _dots.has(c):
		return _dots[c]
	var img := Image.create_empty(10, 10, false, Image.FORMAT_RGBA8)
	for y in 10:
		for x in 10:
			if Vector2(x - 4.5, y - 4.5).length() <= 4.5:
				img.set_pixel(x, y, c)
	_dots[c] = ImageTexture.create_from_image(img)
	return _dots[c]


func _on_tree_selected() -> void:
	var ti := tree.get_selected()
	if ti == null or ti.get_metadata(0) == null:
		return
	var key: String = ti.get_metadata(0)
	if key == sel:
		return
	select(key, true)
	var it = _find(key)
	if it != null:
		view2d.center_on(it.x, it.z)
		view3d.focus(it)


func _build_scripts_tab() -> void:
	var m := MarginContainer.new()
	m.name = "Scripts"
	for k in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + k, 8)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	m.add_child(v)
	script_block_opt = OptionButton.new()
	script_block_opt.clip_text = true
	script_block_opt.custom_minimum_size.x = 120
	script_block_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	script_block_opt.item_selected.connect(func(_i): _change_script_block())
	v.add_child(W.hbox([W.label("Block", W.MUTED, false), script_block_opt,
		W.button("Apply", _apply_scripts, "Assemble the text and save it into the layout (Ctrl+S)"),
		W.button("Reload", func(): _load_scripts(true), "Drop the unapplied text and show the layout's scripts again")]))
	v.add_child(W.hbox([
		W.button("Opcodes…", func(): ops_dlg.popup_centered_ratio(0.7), "Every opcode with its fields"),
		W.button("Text of line", _script_line_text, "Open the strings of the conversation / message / NPC on the caret line in the Text tab")]))
	script_edit = CodeEdit.new()
	script_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	script_edit.custom_minimum_size.y = 200
	script_edit.gutters_draw_line_numbers = true
	script_edit.indent_automatic = true
	script_edit.indent_use_spaces = true
	script_edit.indent_size = 2
	script_edit.code_completion_enabled = true
	script_edit.highlight_current_line = true
	script_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	script_edit.syntax_highlighter = _script_highlighter()
	script_edit.text_changed.connect(_on_script_changed)
	script_edit.code_completion_requested.connect(_script_completion)
	script_edit.gui_input.connect(func(e):
		if e is InputEventKey and e.pressed and e.keycode == KEY_S and e.ctrl_pressed:
			_apply_scripts()
			script_edit.accept_event())
	v.add_child(script_edit)
	script_info = W.label("", W.MUTED)
	v.add_child(script_info)
	v.add_child(W.label("Ctrl+S apply · type 2 letters for opcodes · syntax in Opcodes…", W.MUTED))
	tabs.add_child(m)

	ops_dlg = AcceptDialog.new()
	ops_dlg.title = "Script opcodes"
	var t := TextEdit.new()
	t.editable = false
	t.custom_minimum_size = Vector2(700, 420)
	var lines := PackedStringArray()
	for h in ["One op per line: name(field=value, ...), values in decimal or 0x hex; named fields can also be given in order.",
			"'; ...' is a comment: names and dialogue lines are regenerated from the data, edits to them are ignored.",
			"Scripts are 'script 1', 'script 2'... headers; add one at the end to make a new script.",
			"group / script = 1-based index in the variant block, 0 = none. (g, i) = item i (1-based) of group g (0-based), g = 255 = the player.",
			"_N=... are bytes the game never reads (or padding). Apply refuses broken group / script / conversation / location refs.",
			"Popup ops (goal_start, goal_done, message) run their script when the popup is closed: keep those chains or the player stays locked.", ""]:
		lines.append(h)
	var ops := LayScript.OPS.keys()
	ops.sort()
	for op in ops:
		var o: Array = LayScript.OPS[op]
		lines.append("0x%02X  %s   [%s] %s" % [op, LayScript.signature(op, 20), "confirmed" if o[2] == "C" else "assumed", o[3]])
	t.text = "\n".join(lines)
	ops_dlg.add_child(t)
	add_child(ops_dlg)


func _script_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = Color("#b5cea8")
	h.symbol_color = Color(0.75, 0.77, 0.82)
	h.function_color = Color("#4fc3f7")
	h.member_variable_color = Color(0.85, 0.85, 0.9)
	h.add_keyword_color("script", Color("#ffb74d"))
	for op in LayScript.OPS:
		var o: Array = LayScript.OPS[op]
		if o[0].begins_with("if_") or o[0] in ["spawn_run", "timer", "random_script", "switch_2f9c"]:
			h.add_keyword_color(o[0], Color("#ce93d8"))
		elif o[0] in ["conversation", "phone_conversation", "npc_set_talk", "message"]:
			h.add_keyword_color(o[0], Color("#81c784"))
	h.add_color_region(";", "", W.MUTED, true)
	return h


func _script_completion() -> void:
	var ops := LayScript.OPS.keys()
	ops.sort()
	for op in ops:
		var parts := []
		for f in LayScript.arg_fields(op, gd.arg_size[op]):
			if not f[0].begins_with("_"):
				parts.append(f[0] + "=0")
		var ins: String = "%s(%s)" % [LayScript.op_name(op), ", ".join(parts)]
		script_edit.add_code_completion_option(CodeEdit.KIND_FUNCTION, LayScript.signature(op, gd.arg_size[op]), ins)
	script_edit.update_code_completion_options(false)


func _on_script_changed() -> void:
	if _script_setting:
		return
	if not _script_dirty:
		_script_dirty = true
		_script_tab_title()
	# a word of 2+ letters alone before the caret: offer the opcodes
	var line := script_edit.get_line(script_edit.get_caret_line()).substr(0, script_edit.get_caret_column())
	var w := line.strip_edges()
	if w.length() >= 2 and w.is_valid_ascii_identifier() and not w.begins_with("script"):
		script_edit.request_code_completion()


func _script_tab_title() -> void:
	for i in tabs.get_tab_count():
		if tabs.get_tab_control(i).name == "Scripts":
			tabs.set_tab_title(i, "Scripts *" if _script_dirty else "Scripts")


func _script_block() -> int:
	return W.option_value(script_block_opt) if script_block_opt.item_count else -1


func _change_script_block() -> void:
	if _script_dirty and not _script_sig.is_empty():
		status("Unapplied script edits of block %d dropped" % _script_sig[1])
	_load_scripts(true)


## Show the scripts of the selected block. Unapplied text survives reloads of the same location and block
## (item edits, language change) unless `force`.
func _render_scripts() -> void:
	_load_scripts(false)


func _load_scripts(force: bool) -> void:
	if script_edit == null:
		return
	if lay == null:
		script_block_opt.clear()
		if _script_dirty and not _script_sig.is_empty():
			status("Unapplied script edits of location %d dropped" % _script_sig[0])
		_set_script_text("; this location has no layout")
		script_edit.editable = false
		_script_sig = []
		_script_dirty = false
		_script_tab_title()
		script_info.text = ""
		return
	# block list: block 0 and the variant shown in the views
	var want := _script_block()
	if not _script_sig.is_empty() and _script_sig[0] != loc:
		want = -1
	script_block_opt.clear()
	var vis := _visible_blocks()
	for b in vis:
		var n: int = lay.blocks[b].scripts.size()
		script_block_opt.add_item(("block %d (%d scripts)" % [b, n]) if b else ("block 0 (%d scripts, every variant)" % n), b)
	var sb: int = want if want in vis else (block if block in vis else 0)
	script_block_opt.select(vis.find(sb))
	script_edit.editable = true
	var sig := [loc, sb, lang, hash(proj.current("layout", proj.nav_of(loc)))]
	var same_place: bool = not _script_sig.is_empty() and _script_sig[0] == loc and _script_sig[1] == sb
	if _script_dirty and not force:
		if same_place:
			if sig[3] != _script_sig[3]:
				script_info.text = "The layout changed since this text was loaded (item edits can renumber (g, i) refs): Reload to see the current scripts."
				script_info.add_theme_color_override("font_color", W.WARN)
			_script_sig = sig
			return
		status("Unapplied script edits of location %d block %d dropped" % [_script_sig[0], _script_sig[1]])
	if sig == _script_sig and not force and not _script_dirty:
		return
	var blk: Layout.Block = lay.blocks[sb]
	var caret := [script_edit.get_caret_line(), script_edit.get_caret_column(), script_edit.scroll_vertical]
	_set_script_text(LayScript.disassemble(blk.scripts, gd, lang, blk))
	if same_place:
		script_edit.set_caret_line(mini(caret[0], script_edit.get_line_count() - 1))
		script_edit.set_caret_column(caret[1])
		script_edit.scroll_vertical = caret[2]
	_script_sig = sig
	_script_dirty = false
	_script_tab_title()
	var targets: Array = EditProject.target_blocks(lay, sb).map(func(x): return str(x))
	script_info.text = "Block %d: %d groups, %d scripts. Its group / script numbers point into block %s." % [sb,
		blk.groups.size(), blk.scripts.size(), ", ".join(targets)]
	script_info.add_theme_color_override("font_color", W.MUTED)


func _set_script_text(t: String) -> void:
	_script_setting = true
	script_edit.text = t
	script_edit.clear_undo_history()
	_script_setting = false


func _script_error(msg: String, line: int) -> void:
	script_info.text = ("line %d: " % line if line > 0 else "") + msg
	script_info.add_theme_color_override("font_color", W.WARN)
	if line > 0:
		script_edit.set_caret_line(line - 1)
		script_edit.set_line_background_color(line - 1, Color(0.6, 0.15, 0.15, 0.45))
		script_edit.center_viewport_to_caret()
	status("Scripts not applied: " + msg.split("\n")[0])


func _apply_scripts() -> void:
	if lay == null or _script_sig.is_empty():
		return
	for i in script_edit.get_line_count():
		script_edit.set_line_background_color(i, Color(0, 0, 0, 0))
	var sb: int = _script_sig[1]
	var r := LayScript.assemble(script_edit.text, gd.arg_size)
	if r.error != "":
		_script_error(r.error, r.line)
		return
	var e := proj.set_scripts(loc, sb, r.scripts)
	if e != "":
		_script_error(e, 0)
		return
	_script_dirty = false
	_reload()
	status("Scripts of block %d saved (%d scripts)." % [sb, r.scripts.size()])


## Text ids used by the op on the caret line (conversation lines, message strings, NPC name), shown in the Text tab.
func _script_line_text() -> void:
	var line := script_edit.get_line(script_edit.get_caret_line())
	var sc := line.find(";")
	if sc >= 0:
		line = line.substr(0, sc)
	if line.strip_edges() == "":
		status("Put the caret on an op line")
		return
	var r = LayScript.assemble_op(line, gd.arg_size)
	if r is String:
		status("Caret line: " + r)
		return
	var a := LayScript.decode_args(r[0], r[1])
	var ids := []
	if a.has("conv") and a.conv < GameData.N_CONV:
		for l in gd.conversation(a.conv):
			ids.append(l[0])
	elif a.has("msg"):
		var m := gd.message(a.msg)
		ids.append(m[0])
		if m[1] >= 0:
			ids.append(m[1])
	elif a.has("npc") and a.npc < 0x3F:
		ids.append(GameData.NPC_NAME_BASE + a.npc)
	if ids.is_empty():
		status("This op uses no text")
		return
	for i in tabs.get_tab_count():
		if tabs.get_tab_control(i).name == "Text":
			tabs.current_tab = i
	text_search.text = "0x%x" % ids[0]
	_refresh_text_list(true)
	_select_text(ids[0])
	status("Text ids of this line: " + ", ".join(ids.map(func(x): return "0x%04X" % x)) + " (type one in the Text tab search)")


# =================================================================================================================
# selection
# =================================================================================================================

func select(key: String, from_tree := false) -> void:
	sel = key
	if not from_tree:
		tree.deselect_all()
		if _tree_items.has(key):
			var ti: TreeItem = _tree_items[key]
			ti.select(0)
			tree.scroll_to_item(ti)
	if mode == "items":
		render_details()
		if key != "":
			tabs.current_tab = 0
	view2d.queue_redraw()
	view3d.set_selection(key)


func render_details() -> void:
	W.clear(details)
	var it = _find(sel)
	if it == null:
		details.add_child(W.label("Click an item in the top-down view, the 3D view or the list.", W.MUTED))
		return
	if it.kind == "furniture":
		_render_furniture(it)
		return
	var rows := []
	var ent: bool = it.kind == "entry"
	rows.append(["kind", "entry point" if ent else "%s (type %d)" % [W.NAMES.get(it.type, "?"), it.type]])
	rows.append(["position", "%s, %s, %s" % [W.fmt(it.x), W.fmt(it.y), W.fmt(it.z)]])
	var item: Layout.Item = null
	if ent:
		rows.append(["entry id", it.id])
		rows.append(["angle", "%.1f°" % rad_to_deg(it.angle)])
	else:
		item = it.item
		rows.append(["block / group / item", "%d / %d / %d" % [it.block, it.group, it.index + 1]])
		if it.model >= 0:
			rows.append(["model", "%s (rom.bin %d)" % [it.model_name, it.model]])
		var f := item.fields()
		for k in f:
			var v = f[k]
			rows.append([k, "—" if v == null else (W.fmt(v.x) + ", " + W.fmt(v.y) + ", " + W.fmt(v.z) if v is Vector3 else str(v))])
		if item.type == 4:
			var dest: int = item.raw[0xE]
			rows.append(["→ destination", "%d %s, entry %d" % [dest, GameData.PLACES[dest], item.raw[0x12]] if dest < GameData.LOC_COUNT else "?"])
	details.add_child(W.kv_table(rows))

	# edit form
	details.add_child(HSeparator.new())
	var px := W.spin(-32768, 32767, it.x)
	var py := W.spin(-32768, 32767, it.y)
	var pz := W.spin(-32768, 32767, it.z)
	details.add_child(W.hbox([W.label("x, y, z", W.MUTED, false), px, py, pz]))
	var pa: SpinBox = null
	if ent:
		pa = W.spin(-360, 360, snappedf(rad_to_deg(it.angle), 0.1), 0.1)
		details.add_child(W.hbox([W.label("angle °", W.MUTED, false), pa]))
	var getters := {}
	var raw_edit: LineEdit = null
	if not ent:
		var ff := build_fields(item.type, item.typed(), true)
		details.add_child(ff[0])
		getters = ff[1]
		raw_edit = LineEdit.new()
		raw_edit.text = item.raw.hex_encode()
		raw_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		raw_edit.tooltip_text = "Whole record (hex). A changed raw record wins over the fields above; size and type must stay."
		details.add_child(W.hbox([W.label("raw", W.MUTED, false), raw_edit]))
	var btns := HBoxContainer.new()
	btns.add_child(W.button("Apply", func():
		var x = px.value if px.value != it.x else null
		var y = py.value if py.value != it.y else null
		var z = pz.value if pz.value != it.z else null
		if ent:
			var a = deg_to_rad(pa.value) if not is_equal_approx(pa.value, snappedf(rad_to_deg(it.angle), 0.1)) else null
			apply(proj.edit_entry(loc, it.index, x, y, z, a))
			return
		var raw: String = raw_edit.text.strip_edges().to_lower()
		if raw != item.raw.hex_encode():
			var rb := raw.hex_decode()
			apply(proj.edit_item(loc, it.block, it.group, it.index, x, y, z, null, rb))
			return
		var typed := item.typed()
		var changed := {}
		for k in getters:
			var v: int = getters[k].call()
			if v != typed.get(k):
				changed[k] = v
		apply(proj.edit_item(loc, it.block, it.group, it.index, x, y, z, null, null, changed))))
	if not ent:
		btns.add_child(W.button("Duplicate", func():
			var e := proj.duplicate_item(loc, it.block, it.group, it.index)
			if apply(e):
				select("%d/%d/%d" % [it.block, it.group, proj.last_index]), "Copy to the end of the group (no index shift)"))
		btns.add_child(W.button("Delete", _delete_item.bind(it), "Del"))
		if item.type == 4 and item.raw[0xE] < GameData.LOC_COUNT:
			var dest: int = item.raw[0xE]
			btns.add_child(W.button("Open destination", func(): open_location(dest)))
	details.add_child(btns)
	var shared := []
	for l in proj.shared_with(loc):
		if gd.locations[l].nav == gd.locations[loc].nav:
			shared.append(str(l))
	if not shared.is_empty():
		details.add_child(W.label("This layout is shared with location %s: edits change it too." % ", ".join(shared), W.WARN))
	details.add_child(W.label("Drag the selected item in the top-down view to move it.", W.MUTED))
	details.add_child(W.label("Assumed, not verified: facing direction (sign of the angle) and box placement (centred on the item position, not rotated).", W.MUTED))


func _delete_item(it: Dictionary) -> void:
	if apply(proj.delete_item(loc, it.block, it.group, it.index)):
		select("")


func _render_furniture(it: Dictionary) -> void:
	var g: RoomFurn.Grid = furniture.grid
	var rows := [["kind", "default room furniture (arm9 0x0211FA70, not in the layout)"],
		["model", "%s (prop %d, rom.bin %d)" % [it.model_name, it.prop, it.model]],
		["placement", "wall-mounted: wall slot %d, cell %d along it (rot unused)" % [it.cell.x, it.cell.y] if it.wall
			else "floor: cell (%d, %d), rot %d = %d°" % [it.cell.x, it.cell.y, it.rot, it.rot * 90]],
		["world x, y, z", "%.2f, %.2f, %.2f" % [it.x, it.y, it.z]], ["angle", "%d°" % roundi(rad_to_deg(it.angle))],
		["room grid", "rom.bin %d: %d x %d cells of %s, %d wall slots" % [proj.furn.grid_entries()[furniture.slot], g.width, g.depth, RoomFurn.CELL, g.n_walls]]]
	details.add_child(W.kv_table(rows))
	details.add_child(HSeparator.new())
	var picker := W.IconPicker.new("prop ", _furniture_options(it.prop), it.prop)
	details.add_child(picker)
	var sr := W.spin(0, 3, it.rot)
	var sx := W.spin(0, 255, it.cell.x)
	var sz := W.spin(0, 255, it.cell.y)
	details.add_child(W.hbox([W.label("rot", W.MUTED, false), sr, W.label("wall, cell" if it.wall else "cell x, z", W.MUTED, false), sx, sz]))
	details.add_child(W.hbox([W.button("Apply", func():
		apply(proj.edit_furniture(loc, it.index, picker.value, int(sx.value), int(sz.value), int(sr.value))))]))
	details.add_child(W.label("Drag it in the top-down view: it snaps to the grid (wall props slide along their wall).", W.MUTED))
	details.add_child(W.label("Only a new game uses this table: it is copied into the game state (and so into the save) at new game.", W.WARN))
	if not it.exact:
		details.add_child(W.label("This prop is not furniture: the game has no placement object for it. Pick one from the list.", W.WARN))


func select_cell(b, at: Vector2) -> void:
	cell = b
	cell_at = at
	W.clear(details)
	tabs.current_tab = 0
	if b != null:
		details.add_child(W.kv_table([["solid cell", "%d vertices" % b.verts.size()],
			["min x, y, z", "%.1f, %.1f, %.1f" % [b.lo.x, b.lo.y, b.lo.z]],
			["max x, y, z", "%.1f, %.1f, %.1f" % [b.hi.x, b.hi.y, b.hi.z]]]))
		var dx := W.spin(-4096, 4096, 0, 0.5)
		var dy := W.spin(-4096, 4096, 0, 0.5)
		var dz := W.spin(-4096, 4096, 0, 0.5)
		details.add_child(W.hbox([W.label("move by", W.MUTED, false), dx, dy, dz]))
		var inside: Vector3 = b.inside
		details.add_child(W.hbox([
			W.button("Move cell", func():
				if apply(proj.bsp_move(loc, inside, Vector3(dx.value, dy.value, dz.value))):
					select_cell(null, at)),
			W.button("Delete cell", func():
				if apply(proj.bsp_delete(loc, inside)):
					select_cell(null, at))]))
	else:
		details.add_child(W.label("Click a collision cell in the top-down view. No cell selected (empty space).", W.MUTED))
	details.add_child(HSeparator.new())
	details.add_child(W.label("Add an axis-aligned solid box:", W.MUTED))
	var top: float = b.hi.y if b != null else 0.0
	var lx := W.spin(-32768, 32767, roundf(at.x - 5), 0.5)
	var ly := W.spin(-32768, 32767, roundf(top), 0.5)
	var lz := W.spin(-32768, 32767, roundf(at.y - 5), 0.5)
	var hx := W.spin(-32768, 32767, roundf(at.x + 5), 0.5)
	var hy := W.spin(-32768, 32767, roundf(top + 10), 0.5)
	var hz := W.spin(-32768, 32767, roundf(at.y + 5), 0.5)
	details.add_child(W.hbox([W.label("min", W.MUTED, false), lx, ly, lz]))
	details.add_child(W.hbox([W.label("max", W.MUTED, false), hx, hy, hz]))
	details.add_child(W.hbox([W.button("Add box", func():
		apply(proj.bsp_box(loc, Vector3(lx.value, ly.value, lz.value), Vector3(hx.value, hy.value, hz.value))))]))
	details.add_child(W.label("Click the same spot again to pick the next cell below. Moving a cell = delete it + add its planes shifted.", W.MUTED))
	view2d.queue_redraw()


# =================================================================================================================
# typed fields + pickers
# =================================================================================================================

func icon_tex(kind: String, id: int) -> Texture2D:
	var k := "%s:%d" % [kind, id]
	if _icons.has(k):
		return _icons[k]
	var rec := gd.info_npc(id) if kind == "npc" else gd.info_prop(id)
	var img := S2Sprite.render_icon(gd, rec)
	var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_icons[k] = tex
	return tex


func _options(kind: String) -> Array:
	var k := kind + ":" + lang
	if _opts.has(k):
		return _opts[k]
	var out := []
	match kind:
		"npc":
			for i in GameData.N_NPCS:
				var nm := gd.npc_name(i, lang)
				var md := gd.model_name(gd.npc_model(i))
				out.append({"id": i, "label": nm, "tip": "%d %s (%s)" % [i, nm, md], "icon": icon_tex("npc", i)})
		"prop":
			for i in GameData.N_PROPS:
				var nm := gd.prop_game_name(i, lang)
				var md := gd.model_name(gd.prop_model(i))
				out.append({"id": i, "label": nm if nm != "" else md, "tip": "%d %s (%s)" % [i, nm, md], "icon": icon_tex("prop", i)})
	_opts[k] = out
	return out


func _picker_opts(kind: String, lo := 0, hi := 1 << 30) -> Array:
	var out := []
	for o in _options(kind):
		if o.id >= lo and o.id <= hi:
			out.append(o.duplicate())
	return out


func _furniture_options(cur: int) -> Array:
	var out := []
	for o in _options("prop"):
		if RoomFurn.is_furniture(o.id) or o.id == cur:
			var d: Dictionary = o.duplicate()
			d.tip += " — " + ("wall" if RoomFurn.is_wall(o.id) else "floor") if RoomFurn.is_furniture(o.id) else " — not furniture"
			out.append(d)
	return out


## [Control, {field name: Callable -> int}] for the typed fields of item type t.
func build_fields(t: int, vals: Dictionary, pick := true) -> Array:
	var box := VBoxContainer.new()
	var grid := GridContainer.new()
	grid.columns = 4
	var getters := {}
	var entry_opt: OptionButton = null
	var dest_opt: OptionButton = null
	for f in Layout.FIELDS.get(t, []):
		var name: String = f[0]
		var lo: int = f[3]
		var hi: int = f[4]
		var v: int = vals.get(name, lo)
		if pick and (name == "npc" or name == "prop"):
			var p := W.IconPicker.new(name + " ", _picker_opts(name, lo, hi) if name == "npc" else _picker_opts("prop", lo, hi), v)
			box.add_child(p)
			getters[name] = func() -> int: return p.value
			continue
		var lbl := W.label(name.replace("_", " "), W.MUTED, false)
		lbl.tooltip_text = "%d..%d" % [lo, hi]
		var ctl: Control
		match name:
			"object":
				var os := []
				for i in GameData.N_OBJECTS:
					os.append([i, "%d %s" % [i, gd.model_name(gd.object_model(i))]])
				os.append([GameData.N_OBJECTS, "%d (box only)" % GameData.N_OBJECTS])
				var o := W.option(os, v)
				ctl = o
				getters[name] = func() -> int: return W.option_value(o)
			"dest":
				var os := []
				for L in gd.locations:
					os.append([L.location, "%d %s%s" % [L.location, L.place, "" if L.nav != GameData.NONE else " (no layout)"]])
				dest_opt = W.option(os, v)
				ctl = dest_opt
				var d := dest_opt
				getters[name] = func() -> int: return W.option_value(d)
			"entry":
				entry_opt = OptionButton.new()
				entry_opt.custom_minimum_size.x = 120
				entry_opt.set_meta("cur", v)
				ctl = entry_opt
				var e := entry_opt
				getters[name] = func() -> int: return W.option_value(e)
			_:
				var s := W.spin(lo, hi, v)
				ctl = s
				getters[name] = func() -> int: return int(s.value)
		grid.add_child(lbl)
		grid.add_child(ctl)
	if grid.get_child_count() > 0:
		box.add_child(grid)
	if entry_opt != null and dest_opt != null:
		var fill := func(cur: int) -> void:
			entry_opt.clear()
			var ids := proj.entry_ids(W.option_value(dest_opt))
			var seen := {}
			for e in ids:
				if seen.has(e):
					continue
				seen[e] = true
				entry_opt.add_item("entry %d" % e, e)
			if cur >= 0 and not seen.has(cur):
				entry_opt.add_item("entry %d (missing!)" % cur, cur)
			for i in entry_opt.item_count:
				if entry_opt.get_item_id(i) == cur:
					entry_opt.select(i)
		fill.call(entry_opt.get_meta("cur"))
		dest_opt.item_selected.connect(func(_i): fill.call(-1))
	return [box, getters]


# =================================================================================================================
# add item palette
# =================================================================================================================

func render_palette() -> void:
	W.clear(palette)
	if lay == null:
		palette.add_child(W.label("This location has no layout file.", W.MUTED))
		return
	var types := []
	for t in Layout.FIELDS:
		types.append([t, "%d %s" % [t, W.NAMES.get(t, Layout.ITEM_NAME.get(t, "?"))]])
	var topt := W.option(types, pal_type)
	topt.item_selected.connect(func(_i):
		pal_type = W.option_value(topt)
		pal_vals = {}
		placing = false
		render_palette())
	palette.add_child(W.hbox([W.label("type", W.MUTED, false), topt]))
	# target groups: block 0 + the variant
	var groups := []
	for b in _visible_blocks():
		var info := _group_info(b)
		for g in lay.blocks[b].groups.size():
			groups.append({"key": "%d/%d" % [b, g], "b": b, "g": g, "n": lay.blocks[b].groups[g].items.size(),
				"permanent": info[g].permanent, "spawned_by": info[g].spawned_by})
	var have := false
	for x in groups:
		if x.key == pal_group:
			have = true
	if not have:
		pal_group = groups[0].key if not groups.is_empty() else ""
		for x in groups:
			if x.b == block:
				pal_group = x.key
				break
	var gopts := []
	var gi := 0
	var G = null
	for x in groups:
		gopts.append([gi, "block %d · group %d (%d items)" % [x.b, x.g, x.n]])
		if x.key == pal_group:
			G = x
		gi += 1
	var gopt := W.option(gopts, groups.find(G))
	gopt.item_selected.connect(func(i):
		pal_group = groups[i].key
		render_palette())
	palette.add_child(W.hbox([W.label("group", W.MUTED, false), gopt]))
	var hint: String
	if G == null:
		hint = "This block has no group."
	elif G.permanent:
		hint = "Group 0 of block 0: always there (permanent content)."
	elif not G.spawned_by.is_empty():
		hint = "Spawned by " + ", ".join(G.spawned_by) + "."
	else:
		hint = "No script or trigger of this block spawns this group: the item will not appear in game."
	palette.add_child(W.label(hint, W.MUTED if G != null and (G.permanent or not G.spawned_by.is_empty()) else W.WARN))
	if pal_vals.is_empty():
		pal_vals = Layout.new_item(pal_type).typed()
		if pal_type == 10:
			pal_vals["collect_bit"] = proj.free_collect_bit()
	var ff := build_fields(pal_type, pal_vals, true)
	palette.add_child(ff[0])
	var getters: Dictionary = ff[1]
	var read := func() -> Dictionary:
		var out := {}
		for k in getters:
			out[k] = getters[k].call()
		return out
	var place_btn := W.button("Click on the map… (Esc)" if placing else "Place on map", func():
		pal_vals = read.call()
		placing = not placing
		if placing:
			set_view("2d")
			status("Click in the top-down view to place the new item (Esc cancels)")
		render_palette()
		view2d.queue_redraw())
	place_btn.toggle_mode = true
	place_btn.set_pressed_no_signal(placing)
	palette.add_child(W.hbox([place_btn, W.button("Add at view centre", func():
		pal_vals = read.call()
		on_2d_place(view2d.cx, view2d.cz))]))
	palette.add_child(W.label("Variant %d: parse arena %d / %d bytes (8 per item), waypoints %d / %d." % [block,
		lay.arena_size(block), Layout.ARENA, lay.waypoint_count(block), Layout.MAX_WAYPOINTS], W.MUTED))
	if pal_type == 10:
		palette.add_child(W.label("Collect bit: one per timed prop (0..49 used by the game). Bits 50..63 are assumed free.", W.MUTED))
	if pal_type == 4:
		palette.add_child(W.label("Door: walking into the box loads the destination at that entry point. Object = door model, or box only.", W.MUTED))
	palette.add_child(W.label("The new item is appended to the group (no index shift). Its y is that of the nearest item: edit it after if needed.", W.MUTED))


func _group_info(b: int) -> Array:
	var blk: Layout.Block = lay.blocks[b]
	var out := []
	for g in blk.groups.size():
		out.append({"permanent": b == 0 and g == 0, "spawned_by": []})
	for si in blk.scripts.size():
		for op in blk.scripts[si]:
			if op[0] == 0x00:
				continue
			var a := LayScript.decode_args(op[0], op[1])
			for k in ["group", "else_group"]:
				var v: int = a.get(k, 0)
				if v > 0 and v <= out.size():
					var s := "script %d (%s)" % [si + 1, LayScript.op_name(op[0])]
					if not s in out[v - 1].spawned_by:
						out[v - 1].spawned_by.append(s)
	for grp in blk.groups:
		for it in grp.items:
			if it.type == 3:
				var v: int = it.get_field("group")
				if v > 0 and v <= out.size() and not "trigger box" in out[v - 1].spawned_by:
					out[v - 1].spawned_by.append("trigger box")
	return out


# =================================================================================================================
# view callbacks / edits
# =================================================================================================================

## Show an edit error, or reload the location. True when the edit was applied.
func apply(err: String) -> bool:
	if err != "":
		status("Edit refused: " + err)
		show_msg(err, "Edit refused")
		return false
	_reload()
	return true


func do_undo() -> void:
	var e := proj.undo()
	if e != "":
		status(e)
		return
	_reload()
	status("Undone")


func on_2d_place(x: float, z: float) -> void:
	placing = false
	if pal_group == "":
		return
	var bg := pal_group.split("/")
	var b := bg[0].to_int()
	var g := bg[1].to_int()
	var y := 0.0
	var bd := INF
	for it in items:
		var d := Vector2(it.x - x, it.z - z).length()
		if d < bd:
			bd = d
			y = it.y
	if apply(proj.add_item(loc, b, g, pal_type, x, y, z, pal_vals)):
		pal_vals = {}
		render_palette()
		select("%d/%d/%d" % [b, g, proj.last_index])
	else:
		render_palette()


func on_2d_moved(it: Dictionary, ghost: Dictionary) -> void:
	if it.kind == "furniture":
		var st: Vector2i = ghost.step
		if st == Vector2i.ZERO:
			view2d.queue_redraw()
			return
		apply(proj.edit_furniture(loc, it.index, null, it.cell.x + st.x, it.cell.y + st.y, null))
		return
	var nx := roundi(ghost.x)
	var nz := roundi(ghost.z)
	if nx == roundi(it.x) and nz == roundi(it.z):
		view2d.queue_redraw()
		return
	if it.kind == "entry":
		apply(proj.edit_entry(loc, it.index, nx, null, nz, null))
	else:
		apply(proj.edit_item(loc, it.block, it.group, it.index, nx, null, nz))


func on_2d_cell(x: float, z: float) -> void:
	var hits := []
	for b in brushes2d:
		if b.poly.size() >= 3 and Geometry2D.is_point_in_polygon(Vector2(x, z), b.poly):
			hits.append(b)
	var k := -1
	for i in hits.size():
		if hits[i].brush == cell:
			k = i
	var pick = null
	if not hits.is_empty():
		pick = hits[k - 1] if k > 0 else hits[-1]
	select_cell(pick.brush if pick != null else null, Vector2(x, z))


func _revert_location() -> void:
	ask("Drop every edit of %s (layout, collision, room furniture)?" % gd.locations[loc].place, func():
		var nav := proj.nav_of(loc)
		if nav >= 0:
			proj.revert("layout", nav)
		proj.revert("bsp", gd.locations[loc].bsp)
		var slot := proj.furniture_slot(loc)
		if slot >= 0:
			proj.revert("furniture", slot)
		_reload())


func _setting(k: String, default = null):
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	return cf.get_value("main", k, default)


func _set_setting(k: String, v) -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS)
	cf.set_value("main", k, v)
	cf.save(SETTINGS)


func _export_dialog(kind := "nds") -> void:
	if proj == null:
		return
	save_kind = kind
	var p := gd.rom.path
	save_dlg.current_dir = p.get_base_dir()
	if kind == "bps":
		save_dlg.filters = PackedStringArray(["*.bps ; BPS patch (Flips, ROM Patcher JS…)"])
		save_dlg.title = "Export the edits as a BPS patch of the opened ROM"
		save_dlg.current_file = p.get_file().get_basename() + "_edited.bps"
	else:
		save_dlg.filters = PackedStringArray(["*.nds ; Nintendo DS ROM"])
		save_dlg.title = "Export the edited ROM"
		save_dlg.current_file = p.get_file().get_basename() + "_edited.nds"
	save_dlg.popup_centered_ratio(0.6)


## Export to a scratch ROM in the user folder and open it with the emulator chosen in the settings.
func _test_in_emulator() -> void:
	if proj == null:
		return
	var emu: String = _setting("emulator", "")
	if emu == "" or not FileAccess.file_exists(emu):
		show_msg("Choose the emulator program first (melonDS recommended). It is remembered.", "Test in emulator")
		emu_dlg.popup_centered_ratio(0.6)
		return
	var path := ProjectSettings.globalize_path(proj.dir.path_join("test.nds"))
	DirAccess.make_dir_recursive_absolute(proj.dir)
	status("Building the test ROM…")
	await get_tree().process_frame
	await get_tree().process_frame
	var e := proj.export_rom(path)
	if e != "":
		show_msg("Export failed: " + e)
		status("Export failed")
		return
	var pid := OS.create_process(emu, [path])
	if pid < 0:
		show_msg("Could not start %s" % emu)
		status("Emulator failed to start")
		return
	status("Testing %s in %s%s" % [path.get_file(), emu.get_file(),
		" (room furniture edits only show in a NEW game)" if proj.has_furniture_edits() else ""])


func _export_to(path: String) -> void:
	var ext := "." + save_kind
	if not path.to_lower().ends_with(ext):
		path += ext
	status("Exporting %s…" % path.get_file())
	await get_tree().process_frame
	await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var e := proj.export_rom(path) if save_kind == "nds" else proj.export_patch(path)
	if e != "":
		show_msg("Export failed: " + e)
		status("Export failed")
		return
	var msg := "Exported %s (%.1f MB, %d edited file(s), %d ms)." % [path.get_file(),
		FileAccess.get_file_as_bytes(path).size() / 1048576.0, proj.edits.size(), Time.get_ticks_msec() - t0]
	status(msg)
	show_msg(msg + ("\nRoom furniture edits only show in a NEW game." if proj.has_furniture_edits() else ""),
		"ROM exported" if save_kind == "nds" else "Patch exported")
