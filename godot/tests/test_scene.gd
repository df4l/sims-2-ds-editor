extends SceneTree
## Own scene for a new location (SceneImport + NsbmdWriter + BspBuild, EditProject.import_scene):
##   Godot --headless --path godot --script res://tests/test_scene.gd -- rom.nds out_dir [max_tex of 35]
## Uses its own project folder (user://tests/scene). Writes to out_dir, for the emulator:
##   test_room.glb      the room below (built in code, exported with Godot's glTF writer, then imported back);
##   scene_34.nds       direct boot into 34 (copy of City Hall) with that room: floor top 1 under the entry, coloured
##                      walls (one textured with a checker), a red pillar drawn but not solid (-nocol), an invisible
##                      solid block (-col) next to the entry;
##   scene_35.nds       direct boot into 35 (copy of City Hall) whose own scene = City Hall's models re-encoded by
##                      NsbmdWriter and collision = City Hall's cells recompiled by BspBuild (must look and collide
##                      like City Hall, minus its texture animations);
##   scene_6.nds        control: direct boot into City Hall (6), same build path.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


static func box_mesh(size: Vector3, color: Color, uv_repeat := 1.0) -> ArrayMesh:
	var bm := BoxMesh.new()
	bm.size = size
	var a := bm.get_mesh_arrays()
	var C := PackedColorArray()
	var UV: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	for i in (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
		C.append(color.srgb_to_linear())   # glTF vertex colours are linear
		UV[i] = UV[i] * uv_repeat
	a[Mesh.ARRAY_COLOR] = C
	a[Mesh.ARRAY_TEX_UV] = UV
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return m


static func add_box(root: Node3D, name: String, center: Vector3, size: Vector3, color: Color, tex: Texture2D = null,
		uv_repeat := 1.0) -> void:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = box_mesh(size, color, uv_repeat)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	if tex != null:
		mat.albedo_texture = tex
	mi.mesh.surface_set_material(0, mat)
	mi.position = center
	root.add_child(mi)
	mi.owner = root


## Room around p (entry point): floor top 1 below p.y (like the original locations: City Hall entry y = 1, floor 0;
## a floor top at the entry height puts the Sim's feet inside the slab and it falls through), walls 8 high, 32 x 32.
static func room(entry: Vector3) -> Node3D:
	var p := entry + Vector3(0, -1, 0)
	var root := Node3D.new()
	root.name = "TestRoom"
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			img.set_pixel(x, y, Color(1, 1, 1) if ((x / 8) + (y / 8)) % 2 == 0 else Color(0.2, 0.3, 0.9))
	var checker := ImageTexture.create_from_image(img)
	add_box(root, "Floor", p + Vector3(0, -1, 0), Vector3(32, 2, 32), Color(0.85, 0.75, 0.55), checker, 8.0)
	add_box(root, "WallN", p + Vector3(0, 4, -16.5), Vector3(32, 8, 1), Color(0.9, 0.4, 0.3))
	add_box(root, "WallS", p + Vector3(0, 4, 16.5), Vector3(32, 8, 1), Color(0.3, 0.8, 0.4))
	add_box(root, "WallE", p + Vector3(16.5, 4, 0), Vector3(1, 8, 32), Color(0.3, 0.4, 0.9), checker, 2.0)
	add_box(root, "WallW", p + Vector3(-16.5, 4, 0), Vector3(1, 8, 32), Color(0.9, 0.9, 0.3))
	add_box(root, "Pillar-nocol", p + Vector3(6, 3, 6), Vector3(2, 6, 2), Color(1, 0, 0))
	add_box(root, "Block-col", p + Vector3(-5, 1, 0), Vector3(2, 2, 2), Color.WHITE)
	return root


static func surfaces_of(mi: MeshInstance3D) -> Array:
	var out := []
	var mesh: ArrayMesh = mi.mesh
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var sm: ShaderMaterial = mesh.surface_get_material(s)
		var img: Image = null
		if sm.get_shader_parameter("use_tex"):
			img = (sm.get_shader_parameter("tex") as Texture2D).get_image()
		out.append({"verts": a[Mesh.ARRAY_VERTEX], "indices": a[Mesh.ARRAY_INDEX], "uvs": a[Mesh.ARRAY_TEX_UV],
			"colors": a[Mesh.ARRAY_COLOR], "image": img})
	return out


func _save(p: String, d: PackedByteArray) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(d)
	f.close()


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
	pr.dir = "user://tests/scene"
	pr.edits.clear()
	pr.undo_stack.clear()
	DirAccess.make_dir_recursive_absolute(pr.dir)
	for f in DirAccess.get_files_at(pr.dir):
		DirAccess.remove_absolute(pr.dir.path_join(f))
	pr._sync_tables()
	pr._sync_newlocs()
	var n0 := gd.rombin.count()

	check(pr.add_new_location(6, "Test Room") == "" and pr.last_index == 34, "new location 34 from City Hall")
	check(pr.add_new_location(6, "Hall Rewritten") == "" and pr.last_index == 35, "new location 35 from City Hall")
	var lay := pr.load_layout(34)
	var e0: PackedByteArray = lay.entries[0]
	var p := Vector3(e0.decode_s16(0), e0.decode_s16(2), e0.decode_s16(4))
	var e34: int = lay.entry_ids()[0]
	print("    entry point %d at %s" % [e34, p])

	# --- 34: room from a GLB file ---
	var root := room(p)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var glb := out_dir.path_join("test_room.glb")
	check(doc.append_from_scene(root, st) == OK and doc.write_to_filesystem(st, glb) == OK, "test room written to %s" % glb)
	root.free()
	check(pr.import_scene(34, ProjectSettings.globalize_path(glb) if glb.begins_with("user://") else glb) == "",
		"import_scene(34) (%s)" % pr.last_import)
	var rep: Dictionary = pr.last_import
	print("    model ", rep.get("model"), "\n    collision ", rep.get("collision"), "\n    warnings ", rep.get("warnings"))
	check(rep.get("col_objects", 0) == 1, "one collision object (Block-col)")
	check(pr.has_scene(34) and gd.loc(34).models.size() == 1 and gd.loc(34).models[0].model == EditProject.SCENE + 34,
		"34 uses its own scene model")
	var nb := Nsbmd.new()
	check(nb.parse(pr.current("model", EditProject.SCENE + 34)) and nb.model.materials.size() == 6,
		"own model parses, 6 materials (Block-col not drawn)")
	var bsp := Bsp.parse(pr.current("bsp", gd.loc(34).bsp))
	check(bsp.error == "" and bsp.check().is_empty(), "own collision parses and passes check()")
	var f := p + Vector3(0, -1, 0)   # floor top
	check(bsp.classify(f + Vector3(3, -0.25, 3)) and not bsp.classify(f + Vector3(3, 0.5, 3)), "floor: solid just under its top, empty above")
	check(bsp.classify(f + Vector3(0, 4, -16.2)) and not bsp.classify(f + Vector3(0, 4, -15.5)), "north wall: solid behind its face only (slab)")
	check(bsp.classify(f + Vector3(-5, 1, 0)), "Block-col is solid")
	check(not bsp.classify(f + Vector3(6, 3, 6)), "Pillar-nocol is not solid")
	# undo / clear
	pr.undo()
	check(not pr.has_scene(34) and gd.loc(34).models.size() == gd.loc(6).models.size(), "undo: back to City Hall's models")
	check(pr.current("bsp", gd.loc(34).bsp) == gd.rombin.data(gd.loc(6).bsp), "undo: back to City Hall's collision")
	check(pr.import_scene(34, glb) == "" and pr.has_scene(34), "re-import")

	# --- 35: City Hall re-encoded ---
	var si := SceneImport.new()
	for m in gd.loc(6).models:
		var a := Nsbmd.new()
		a.parse(gd.rombin.data(m.model))
		var mi := a.build()
		si.surfaces.append_array(surfaces_of(mi))
		mi.free()
	var orig := Bsp.parse(gd.rombin.data(gd.loc(6).bsp))
	for lp in orig.leaves():
		var planes := []
		for pl in Bsp.cell_planes(lp[1]):
			planes.append([pl[1][0] / 4096.0, pl[1][1] / 4096.0, pl[1][2] / 4096.0, pl[2] / 4096.0])
		si.brushes.append(planes)
	var tex35 := 256 if args.size() < 3 else args[2].to_int()   # optional 3rd argument: texture size limit of 35
	check(pr.import_scene_from(35, si, tex35) == "", "35: City Hall models + cells imported (%s)" % pr.last_import.get("model"))

	# --- build ---
	var rom := pr.build_rom([34, e34])
	check(not rom.is_empty(), "build 34 (%s)" % pr.build_error)
	var p34 := out_dir.path_join("scene_34.nds")
	_save(p34, rom)
	_save(out_dir.path_join("scene_35.nds"), pr.build_rom([35, e34]))
	_save(out_dir.path_join("scene_6.nds"), pr.build_rom([6, e34]))
	var g2 := GameData.new()
	check(g2.open(p34), "exported ROM reopens")
	var nf35 := pr.scene_entries(35).size()
	check(nf35 == 2, "35: textures over one file's VRAM block -> split into %d model files" % nf35)
	check(g2.rombin.count() == n0 + 5 + nf35, "appended entries: 2 layouts, 2 collisions, 1 + %d models (%d)" % [nf35, g2.rombin.count() - n0])
	var m := Arm9Mod.new(g2.a9)
	# record 34 in the extension: the one whose model entry is n0 + 2
	var found := false
	for a in range(Arm9Mod.EXT_BASE, Arm9Mod.EXT_BASE + m.ext.size() - 0x24, 4):
		var r := m.read(a, 0x22)
		if r.decode_u16(0x0E) == 1 and r.decode_u16(0x18) == n0 + 2 and r.decode_u32(0x14) == a + 0x1C:
			found = r.decode_u16(0) == n0 + 1 and r.decode_u16(4) == n0 and r.decode_u16(0x10) == 0xFFFF \
				and r.decode_u16(0x12) == 0xFFFF and r.decode_u16(0x1A) == 0 \
				and r.slice(0x1C, 0x22) == PackedByteArray([255, 255, 255, 255, 255, 255])
			break
	check(found, "record 34: bsp %d, nav %d, 1 model = entry %d, no animation, anim list -> dummy {FFFF x3}" % [n0 + 1, n0, n0 + 2])
	var bm := Nsbmd.new()
	check(bm.parse(g2.rombin.data(n0 + 2)), "appended model entry is a BMD0")

	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
