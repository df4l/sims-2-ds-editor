extends SceneTree
## Checks of the player Sim appearance (SimLook, docs/formats/sim.md):
##   Godot --headless --path godot --script res://tests/test_sim.gd -- rom.nds out_dir
## Uses its own project folder (user://tests/sim). Reads the original starting looks, builds both Sims, edits the
## female starting look and writes out_dir/sim_look.nds (direct boot into location 5) + out_dir/sim_default.bin
## (the rewritten Sim_InitDefaultAppearance, for capstone) and PNG renders are left to the UI test.

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
	var pr := EditProject.new(gd)
	pr.dir = "user://tests/sim"
	pr.edits.clear()
	pr.undo_stack.clear()
	DirAccess.make_dir_recursive_absolute(pr.dir)
	for f in DirAccess.get_files_at(pr.dir):
		DirAccess.remove_absolute(pr.dir.path_join(f))

	# --- original data -------------------------------------------------------------------------------------------
	check(gd.npc_model(SimLook.FEMALE) == 3136 and gd.npc_model(SimLook.MALE) == 4805, "model entries 3136 / 4805")
	check(not SimLook.is_installed(gd.a9), "original Sim_InitDefaultAppearance")
	check(gd.u32(SimLook.DEFAULT_FN) == 0xE92D4030, "push {r4, r5, lr} at 0x0200DFD0")
	var fem := SimLook.rom_default(gd, SimLook.FEMALE)
	var mal := SimLook.rom_default(gd, SimLook.MALE)
	# RAM after Create-a-Sim with default choices (loc5_control_unlocked, 2026-11-25)
	var ram := PackedByteArray([0x0D, 0x0C, 0xFC, 0x0C, 0x20, 0x0C, 8, 0, 10, 0, 25, 0, 0xFF, 0xFF, 9, 0, 0xFF, 0xFF,
		0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 1, 14, 11, 9, 0])
	check(fem == ram, "female default = RAM record " + fem.hex_encode())
	check(SimLook.u16(mal, 0) == 4757 and SimLook.u16(mal, 2) == 4988 and SimLook.u16(mal, 4) == 4778,
		"male textures 4757 / 4988 / 4778")
	check(SimLook.check(fem) == "" and SimLook.check(mal) == "", "defaults pass the checks")
	for m in [SimLook.FEMALE, SimLook.MALE]:
		var t := SimLook.cas_textures(gd, m)
		var ok := true
		for k in t:
			for e in t[k]:
				ok = ok and gd.rombin.data(e).size() == 4096
		check(ok and t.head.size() == 9, "Create-a-Sim lists of %d: %d / %d / %d textures of 4096 bytes"
			% [m, t.head.size(), t.torso.size(), t.legs.size()])
		check(t.head.has(SimLook.u16(SimLook.rom_default(gd, m), 0)), "default head in the list (%d)" % m)
	for c in SimLook.COLORS:
		var n := 0
		for v in c[2]:
			n += 1 if SimLook.color_bytes(gd, c, v).size() in [0x40, 0x60] else 0
		check(n == c[2], "%s: %d / %d values have a palette" % [c[1], n, c[2]])

	# --- model ----------------------------------------------------------------------------------------------------
	var nb := Nsbmd.new()
	check(nb.parse(gd.rombin.data(3136)), "FemSim parses")
	check(nb.tex_names.size() == 4 and nb.pal_block.size() == 1024, "4 textures, 1 KiB of palettes")
	var nodes := 0
	for op in nb.model.ops:
		nodes += 1 if op[0] == "node" else 0
	check(nodes >= 16, "%d NODE commands" % nodes)
	var full := nb.build()
	var mi := SimLook.build(gd, SimLook.FEMALE, fem)
	check(mi != null and full != null, "Sim builds")
	if mi and full:
		var vf := 0
		var vd := 0
		for s in full.mesh.get_surface_count():
			vf += full.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size()
		for s in mi.mesh.get_surface_count():
			vd += mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size()
		check(vd > 0 and vd < vf, "hidden nodes drop vertices (%d of %d)" % [vd, vf])
		var r2 := fem.duplicate()
		SimLook.set_style(r2, 0, 4)
		var mi2 := SimLook.build(gd, SimLook.FEMALE, r2)
		var v2 := 0
		for s in mi2.mesh.get_surface_count():
			v2 += mi2.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size()
		check(v2 != vd, "another hair style changes the mesh (%d)" % v2)
	var nb2 := Nsbmd.new()
	nb2.parse(gd.rombin.data(3136))
	var before := nb2.pal_block.duplicate()
	SimLook.apply(gd, nb2, SimLook.FEMALE, fem)
	check(nb2.pal_block.slice(0x40, 0xA0) == SimLook.color_bytes(gd, SimLook.COLORS[0], 0), "skin in palette A")
	check(nb2.pal_block.slice(512 + 0x40, 512 + 0xA0) == SimLook.color_bytes(gd, SimLook.COLORS[0], 0), "skin in palette B")
	check(nb2.pal_block.slice(512 + 0xA0, 512 + 0x100) == SimLook.color_bytes(gd, SimLook.COLORS[7], 8), "colour 3 in B")
	check(nb2.pal_block != before, "palette changed")
	check(nb2.textures[nb2.tex_names[1]].data1 == gd.rombin.data(3085), "head texture slot 1")

	# --- project + install -------------------------------------------------------------------------------------------
	var bad := fem.duplicate()
	bad[0x1C] = 9
	check(pr.set_sim_look(SimLook.FEMALE, bad) != "", "hair node 9 refused")
	bad = fem.duplicate()
	SimLook.set_u16(bad, 0x0A, 32)
	check(pr.set_sim_look(SimLook.FEMALE, bad) != "", "colour 5 = 32 refused")
	check(pr.set_sim_look(56, fem) != "", "model 56 refused")
	check(not pr.has_arm9_edits(), "no edit yet")
	var look := fem.duplicate()
	SimLook.set_style(look, 0, 4)            # HairE
	SimLook.set_style(look, 1, 1)            # TorsoB
	SimLook.set_style(look, 2, 2)            # LegsC
	SimLook.set_u16(look, 0x02, 3326)        # torso texture
	SimLook.set_u16(look, 0x06, 3)           # colour 3
	SimLook.set_u16(look, 0x12, 2)           # skin
	check(pr.set_sim_look(SimLook.FEMALE, look) == "", "female look saved")
	check(pr.is_edited("sim", SimLook.FEMALE) and not pr.is_edited("sim", SimLook.MALE), "only the female look is edited")
	check(pr.has_arm9_edits(), "counts as an ARM9 edit")
	var m := pr.arm9_mod()
	check(m.error == "", "install: " + m.error)
	var a9 := m.build()
	check(SimLook.is_installed(a9), "installed code recognised")
	var at := SimLook.DEFAULT_FN - 0x02000000
	check(a9.slice(at + SimLook.FEM_AT, at + SimLook.FEM_AT + SimLook.SIZE) == look, "female table")
	check(a9.slice(at + SimLook.MAL_AT, at + SimLook.MAL_AT + SimLook.SIZE) == mal, "male table = original values")
	check(a9.slice(SimLook.DEFAULT_FN_END - 0x02000000, SimLook.DEFAULT_FN_END - 0x02000000 + 64)
		== gd.a9.slice(SimLook.DEFAULT_FN_END - 0x02000000, SimLook.DEFAULT_FN_END - 0x02000000 + 64), "next function untouched")
	var f := FileAccess.open(out_dir.path_join("sim_default.bin"), FileAccess.WRITE)
	f.store_buffer(a9.slice(at, SimLook.DEFAULT_FN_END - 0x02000000))
	f.close()
	# reopening the exported ROM reads the installed looks back
	var e := pr.export_rom(out_dir.path_join("sim_look.nds"), [5, 8])
	check(e == "", "export " + e)
	e = pr.export_rom(out_dir.path_join("sim_look_cas.nds"))   # normal boot, for the Create-a-Sim check
	check(e == "", "export (normal boot) " + e)
	var gd2 := GameData.new()
	if gd2.open(out_dir.path_join("sim_look.nds")):
		check(SimLook.rom_default(gd2, SimLook.FEMALE) == look and SimLook.rom_default(gd2, SimLook.MALE) == mal,
			"exported ROM: looks read back from the installed table")
	else:
		check(false, "exported ROM opens: " + gd2.error)
	pr.undo()
	check(not pr.is_edited("sim", SimLook.FEMALE), "undo")
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)
