extends SceneTree
## Smoke test of the Arcade tab: Godot --path godot --script res://tests/test_arcade_ui.gd -- rom.nds
## (needs a window: not --headless). Example -> live preview, compile error with its line, sprite pixel and palette
## editors rewriting the text, Apply / undo / Remove, drafts per cabinet, "selected prop -> cabinet".
## The project folder of the input ROM is wiped first and at the end.

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


func _run() -> void:
	var rom: String = OS.get_cmdline_user_args()[0]
	var ui = load("res://scenes/main.tscn").instantiate()
	root.add_child(ui)
	await frames(5)
	ui.open_rom(rom)
	await frames(5)
	ui.proj.discard_all()
	ui.open_location(24)
	ui.msg_dlg.hide()
	var a: ArcadeTab = ui.arcade

	var w0: int = a.get_parent().size.x
	ui.tabs.current_tab = a.get_index()
	await frames(3)
	check(not ui.side_tree.visible and a.get_parent().size.x > w0, "Arcade tab hides the item list and widens (%d -> %d)" % [w0, a.get_parent().size.x])
	check(a.cab_opt.item_count == 3 and a.prop == 174, "3 cabinets, 174 shown")
	check(a.prog.is_empty() and a.info.text.contains("No own game"), "no game yet")

	# example -> preview runs
	a.load_example("Lunar Lander")
	check(not a.prog.is_empty() and a.info.text.begins_with("OK"), "example compiles: " + a.info.text)
	check(a.drafts.has(174) and ui.tabs.get_tab_title(a.get_index()) == "Arcade *", "draft marked")
	for _i in 40:
		a.step(0)
	var lit := 0
	for b in a.vm.screen:
		lit += int(b != 0)
	check(a.vm.vars[ArcadeVM.V_TICK] == 40 and lit > 20, "40 frames run, screen drawn (%d bytes)" % lit)
	check(a._sprites.keys() == ["ship", "flame", "wreck"], "sprites parsed " + str(a._sprites.keys()))

	# sprite editor: pixel -> text -> program
	a.set_sprite_pixel("ship", 0, 0, 2)
	check(a.src.text.contains("sprite ship\n2.....3333......"), "pixel (0,0) = 2 written in the text")
	a.compile_preview()
	check(a.prog.sprites[0] & 3 == 2, "compiled sprite has the pixel")
	a.set_sprite_pixel("flame", 15, 7, 1)
	check(a._sprites["flame"].px[7 * 16 + 15] == 1 and a.src.text.contains("...............1\nend"),
		"row 8 added to a 4-row sprite")
	a.src.undo()
	a.compile_preview()
	check(a._sprites["flame"].px[7 * 16 + 15] == 0, "sprite edit is one undo step")
	var n0: int = a._sprites.size()
	a._new_sprite()
	check(a._sprites.size() == n0 + 1 and a._sprite_sel == "sprite1", "New sprite block")
	a.compile_preview()
	check(a.prog.nsprites == n0 + 1, "new sprite compiles")

	# palette editor
	a.set_palette([Color8(0, 0, 0), Color8(255, 255, 255), Color8(0, 255, 0), Color8(255, 0, 0)])
	check(a.src.text.contains("palette #000000, #F8F8F8, #00F800, #F80000"), "palette line rewritten")
	a.compile_preview()
	check(a.prog.palette[3] == 0x001F, "palette compiled (red = 0x001F)")

	# compile error keeps the line
	var good: String = a.src.text
	a.src.text = good + "\nfunc oops\n  foo\nend\n"
	a.compile_preview()
	check(a.info.text.begins_with("line ") and not a.prog.is_empty(), "error shown, last good program kept: " + a.info.text)
	check(a.apply() != "", "Apply refuses the broken text")
	check(ui.proj.arcade_game(174).is_empty(), "nothing saved")
	a.src.text = good
	a.compile_preview()

	# apply / drafts / undo
	check(a.apply() == "" and ui.proj.arcade_game(174).source == good, "Apply saves the game")
	check(not a.drafts.has(174) and ui.tabs.get_tab_title(a.get_index()) == "Arcade", "draft cleared")
	a.show_cabinet(175)
	check(a.src.text == "" and a.prog.is_empty(), "175 empty")
	a.load_example("Test card")
	a.show_cabinet(174)
	check(a.src.text == good, "174 shows its saved game")
	a.show_cabinet(175)
	check(a.src.text == ArcadeExamples.CARD, "175 keeps its draft")
	check(a.apply() == "" and ui.proj.arcade_games().size() == 2, "2 games")
	ui.do_undo()
	await frames(2)
	check(ui.proj.arcade_games().size() == 1 and a.src.text == "", "undo removes the 175 game and the text follows")

	# selected prop -> cabinet: location 24 item 0/0/23 is a Space Armada (prop 165)
	a.show_cabinet(174)
	check(a.placements(174).is_empty(), "174 placed nowhere")
	ui.select("0/0/23")
	ui.tabs.current_tab = a.get_index()
	a._place_sig = ""
	a.refresh()
	check(a._selected_prop() == [0, 0, 23], "selected prop seen")
	a._use_selected()
	check(a.placements(174) == [[24, "0/0/23"]], "prop is now cabinet 174: " + str(a.placements(174)))

	# export with the game
	var m = ui.proj.arm9_mod()
	check(m.error == "", "ARM9 install with the game: " + m.error)

	# remove
	a.drafts.erase(174)
	ui.proj.set_arcade_game(174, "")
	a.refresh()
	check(ui.proj.arcade_games().is_empty() and a.src.text == "", "removed")
	ui.tabs.current_tab = 0
	await frames(2)
	check(ui.side_tree.visible, "item list back on another tab")

	ui.proj.discard_all()
	print("FAILS: ", fails)
	quit(1 if fails else 0)
