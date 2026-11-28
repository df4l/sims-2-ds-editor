extends SceneTree
## Smoke test of the Sims tab: Godot --path godot --script res://tests/test_sims_ui.gd -- rom.nds [out_dir]
## (needs a window: not --headless). Shows the female Sim, changes hair / texture / colour, undo, male Sim, Reset.
## Saves preview PNGs in out_dir. The project folder of the input ROM is wiped first and at the end.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func _init() -> void:
	_run.call_deferred()


func frames(n: int) -> void:
	for _i in n:
		await process_frame


func shot(s: SimsTab, path: String) -> void:
	if path == "":
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	s.vp.get_texture().get_image().save_png(path)


func verts(s: SimsTab) -> int:
	var n := 0
	for mi in s.holder.get_children():
		if mi is MeshInstance3D and not mi.is_queued_for_deletion():
			for k in mi.mesh.get_surface_count():
				n += mi.mesh.surface_get_arrays(k)[Mesh.ARRAY_VERTEX].size()
	return n


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var rom: String = args[0]
	var out: String = args[1] if args.size() > 1 else ""
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var ui = load("res://scenes/main.tscn").instantiate()
	root.add_child(ui)
	await frames(5)
	ui.open_rom(rom)
	await frames(5)
	ui.proj.discard_all()
	ui.msg_dlg.hide()
	var s: SimsTab = ui.sims
	ui.tabs.current_tab = s.get_index()
	await frames(3)
	check(not ui.side_tree.visible, "Sims tab hides the item list")
	check(s.model == SimLook.FEMALE and s.holder.get_child_count() == 1, "female Sim shown")
	var v0 := verts(s)
	check(v0 > 0, "preview mesh (%d vertices)" % v0)
	check(s.style_opts[0].item_count == 8 and s.style_opts[0].selected == 0, "8 hair styles, A selected")
	check(s.tex_opts[0].item_count == 9 and s.tex_opts[0].get_item_id(s.tex_opts[0].selected) == 3085, "9 heads, 3085")
	check(s.tex_opts[0].get_item_icon(0) != null, "head thumbnails")
	check(s.col_opts[0].item_count == 5 and s.col_opts[0].selected == 1, "skin: own + 4, value 0")
	check(not ui.proj.is_edited("sim", SimLook.FEMALE), "not edited")
	await shot(s, out.path_join("sims_ui_female.png") if out != "" else "")

	s.style_opts[0].select(4)
	s.style_opts[0].item_selected.emit(4)
	await frames(2)
	check(ui.proj.is_edited("sim", SimLook.FEMALE) and SimLook.style(ui.proj.sim_look(SimLook.FEMALE), 0) == 4,
		"hair E saved")
	check(verts(s) != v0, "preview rebuilt (%d vertices)" % verts(s))
	var ti: int = s.tex_opts[1].get_item_index(3326)
	s.tex_opts[1].select(ti)
	s.tex_opts[1].item_selected.emit(ti)
	s.col_opts[7].select(4)
	s.col_opts[7].item_selected.emit(4)
	s.style_opts[2].select(2)
	s.style_opts[2].item_selected.emit(2)
	await frames(2)
	var r: PackedByteArray = ui.proj.sim_look(SimLook.FEMALE)
	check(SimLook.u16(r, 2) == 3326 and SimLook.u16(r, 6) == 3 and SimLook.style(r, 2) == 2,
		"torso 3326, colour 3 = 3, legs C saved")
	check(s.info.text.begins_with("Edited"), "info says edited")
	await shot(s, out.path_join("sims_ui_edited.png") if out != "" else "")
	ui.proj.undo()
	s.refresh()
	check(SimLook.style(ui.proj.sim_look(SimLook.FEMALE), 2) == 1, "undo restores legs B")

	s.sex_opt.select(1)
	s.sex_opt.item_selected.emit(1)
	await frames(2)
	check(s.model == SimLook.MALE and s.tex_opts[0].get_item_id(s.tex_opts[0].selected) == 4757, "male Sim, head 4757")
	await shot(s, out.path_join("sims_ui_male.png") if out != "" else "")
	s.sex_opt.select(0)
	s.sex_opt.item_selected.emit(0)
	s._reset()
	await frames(2)
	check(not ui.proj.is_edited("sim", SimLook.FEMALE), "Reset = original look")

	ui.proj.discard_all()
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)
