extends SceneTree
## Probe of the 4x4 texture VRAM limits (not a pass / fail test; ROMs for the emulator):
##   Godot --headless --path godot --script res://tests/probe_tex4x4.gd -- rom.nds out_dir
## New location 34 = City Hall's geometry and collision; its N largest textures replaced by unique 256x256 noisy
## 2x2 checkers of 128-px squares (no aliasing on repeated UVs; 16 KiB of 4x4 texels each, colours unique per texture), the others by flat colours. Budgets overridden
## so that the writer packs `per_file` big textures per model file. A failed VRAM allocation shows as garbage on the
## whole file's textures. Writes probe_<name>.nds (direct boot into 34).

const LEVELS := [   # name, big textures, big textures per file
	["a_64k_1file", 4, 4],
	["b_128k_1file", 8, 8],
	["c_128k_2files", 8, 4],
	["d_96k_1file", 6, 6],
]


static func probe_image(i: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000 + i
	var ca := Color.from_hsv(fmod(i * 0.137, 1.0), 0.8, 0.9)
	var cb := Color.from_hsv(fmod(i * 0.137 + 0.5, 1.0), 0.6, 0.4)
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var c: Color = ca if ((x >> 7) + (y >> 7)) % 2 == 0 else cb
			var n := rng.randf_range(-0.08, 0.08)
			img.set_pixel(x, y, Color(clampf(c.r + n, 0, 1), clampf(c.g - n, 0, 1), clampf(c.b + n * 0.5, 0, 1)))
	return img


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	# City Hall surfaces + cells
	var base := []
	for m in gd.loc(6).models:
		var a := Nsbmd.new()
		a.parse(gd.rombin.data(m.model))
		var mi := a.build()
		base.append_array(load("res://tests/test_scene.gd").surfaces_of(mi))
		mi.free()
	var brushes := []
	for lp in Bsp.parse(gd.rombin.data(gd.loc(6).bsp)).leaves():
		var planes := []
		for pl in Bsp.cell_planes(lp[1]):
			planes.append([pl[1][0] / 4096.0, pl[1][1] / 4096.0, pl[1][2] / 4096.0, pl[2] / 4096.0])
		brushes.append(planes)
	# distinct images, largest first (by pixel count)
	var imgs := []
	for s in base:
		if s.image != null and not imgs.has(s.image):
			imgs.append(s.image)
	imgs.sort_custom(func(a, b): return a.get_width() * a.get_height() > b.get_width() * b.get_height())
	for lv in LEVELS:
		var nbig: int = lv[1]
		var repl := {}
		for i in imgs.size():
			if i < nbig:
				repl[imgs[i]] = probe_image(i)
			else:
				var f := Image.create(8, 8, false, Image.FORMAT_RGBA8)
				f.fill(Color.from_hsv(fmod(i * 0.21, 1.0), 0.3, 0.8))
				repl[imgs[i]] = f
		var si := SceneImport.new()
		for s in base:
			var c: Dictionary = s.duplicate()
			if s.image != null:
				c.image = repl[s.image]
			si.surfaces.append(c)
		si.brushes = brushes
		NsbmdWriter.FILE4_BUDGET = 16384 * int(lv[2])
		NsbmdWriter.TEX4_BUDGET = 1 << 20
		NsbmdWriter.VRAM_BUDGET = 1 << 20
		gd = GameData.new()   # a project changes its GameData (new locations): fresh one per level
		gd.open(args[0])
		var pr := EditProject.new(gd)
		pr.dir = "user://tests/probe4x4"
		pr.edits.clear()
		pr.undo_stack.clear()
		DirAccess.make_dir_recursive_absolute(pr.dir)
		for f in DirAccess.get_files_at(pr.dir):
			DirAccess.remove_absolute(pr.dir.path_join(f))
		pr._sync_tables()
		pr._sync_newlocs()
		pr.add_new_location(6, "Probe")
		var err := pr.import_scene_from(34, si, 256, true)
		var m: Dictionary = pr.last_import.get("model", {})
		var e34: int = pr.load_layout(34).entry_ids()[0]
		var rom := pr.build_rom([34, e34])
		var p := out_dir.path_join("probe_%s.nds" % lv[0])
		var fa := FileAccess.open(p, FileAccess.WRITE)
		fa.store_buffer(rom)
		fa.close()
		var per := []
		for e in pr.scene_entries(34):
			var b := Nsbmd.new()
			b.parse(pr.current("model", e))
			var d := pr.current("model", e)
			var t0 := d.decode_u32(20)
			per.append([d.decode_u16(t0 + 0x0C) << 3, d.decode_u16(t0 + 0x1C) << 3, d.decode_u16(t0 + 0x30) << 3])
		print("%s: %s files [plain, 4x4, palette] %s, total 4x4 %d, palettes %d, downscaled %s" % [lv[0],
			err if err != "" else "ok", per, m.get("tex4_bytes", 0), m.get("pal_bytes", 0), m.get("downscaled", [])])
	quit(0)
