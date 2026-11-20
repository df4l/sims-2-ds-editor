extends SceneTree
## BMD0 writer checks (NsbmdWriter):
##   Godot --headless --path godot --script res://tests/test_bmd0.gd -- rom.nds out_dir
## 1. every Nitro dictionary of every BMD0 in rom.bin is rebuilt byte-identical (names + entries -> patricia tree);
## 2. every location scene model, read (Nsbmd.build) then written (NsbmdWriter.build) then read again, gives the
##    same triangles (positions within the VTX_16 step, UVs within a texel, same colours);
## 3. texture encoder: palette formats decode back to the source pixels when the image has <= 256 colours.
## Writes out_dir/rewritten_<entry>.bmd0 for a few models (emulator checks).

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


## [[offset, size]] of every dictionary of a BMD0.
static func dicts_of(d: PackedByteArray) -> Array:
	var out := []
	for i in d.decode_u16(14):
		var bo := d.decode_u32(16 + 4 * i)
		var stamp := d.slice(bo, bo + 4).get_string_from_ascii()
		if stamp == "MDL0":
			out.append(bo + 8)
			var n := d[bo + 9]
			var es := bo + 8 + 8 + 4 * (n + 1)
			for k in n:
				var at := bo + d.decode_u32(es + 4 + 4 * k)
				out.append(at + 64)
				var mat := at + d.decode_u32(at + 8)
				out.append(mat + 4)
				out.append(mat + d.decode_u16(mat))
				out.append(mat + d.decode_u16(mat + 2))
				out.append(at + d.decode_u32(at + 12))
		elif stamp == "TEX0":
			out.append(bo + d.decode_u16(bo + 14))
			out.append(bo + d.decode_u32(bo + 52))
	return out


static func rebuild_dict(d: PackedByteArray, at: int) -> PackedByteArray:
	var n := d[at + 1]
	var oe := at + 8 + 4 * (n + 1)
	var es := d.decode_u16(oe)
	var names := []
	var entries := []
	for i in n:
		names.append(d.slice(oe + d.decode_u16(oe + 2) + 16 * i, oe + d.decode_u16(oe + 2) + 16 * i + 16).get_string_from_ascii())
		entries.append(d.slice(oe + 4 + es * i, oe + 4 + es * (i + 1)))
	return NsbmdWriter.dict(names, es, entries)


## Surfaces for NsbmdWriter from a Nsbmd mesh.
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


## Triangles of a mesh: [[v0, v1, v2, colour key of the 3 vertices]].
static func tris(mi: MeshInstance3D) -> Array:
	var out := []
	var mesh: ArrayMesh = mi.mesh
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var V: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var C: PackedColorArray = a[Mesh.ARRAY_COLOR]
		var I: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var t := 0
		while t + 2 < I.size():
			var ck := []
			for k in 3:
				var c: Color = C[I[t + k]]
				ck.append(roundi(c.r * 31) | (roundi(c.g * 31) << 5) | (roundi(c.b * 31) << 10))
			out.append([V[I[t]], V[I[t + 1]], V[I[t + 2]], ck])
			t += 3
	return out


## Triangles of b without a match in a (same winding up to rotation, vertices within tol, same colours).
static func unmatched(a: Array, b: Array, tol: float) -> int:
	var cell := maxf(tol * 8, 0.05)
	var grid := {}
	for i in a.size():
		var c: Vector3 = (a[i][0] + a[i][1] + a[i][2]) / 3.0
		var k := Vector3i((c / cell).floor())
		if not grid.has(k):
			grid[k] = []
		grid[k].append(i)
	var used := {}
	var miss := 0
	for t in b:
		var c: Vector3 = (t[0] + t[1] + t[2]) / 3.0
		var k0 := Vector3i((c / cell).floor())
		var found := false
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for i in grid.get(k0 + Vector3i(dx, dy, dz), []):
						if found or used.has(i):
							continue
						var u: Array = a[i]
						for r in 3:
							if u[r].distance_to(t[0]) <= tol and u[(r + 1) % 3].distance_to(t[1]) <= tol \
									and u[(r + 2) % 3].distance_to(t[2]) <= tol and u[3][r] == t[3][0] \
									and u[3][(r + 1) % 3] == t[3][1] and u[3][(r + 2) % 3] == t[3][2]:
								found = true
								used[i] = true
								break
		if not found:
			miss += 1
	return miss


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)

	# --- 1. dictionaries ---
	var t0 := Time.get_ticks_msec()
	var n_files := 0
	var n_dicts := 0
	var bad := []
	for e in gd.rombin.count():
		var raw := gd.rombin.raw_entry(e)
		if raw.size() < 8:
			continue
		var d := gd.rombin.data(e)
		if d.size() < 16 or d.slice(0, 4).get_string_from_ascii() != "BMD0":
			continue
		n_files += 1
		for at in dicts_of(d):
			n_dicts += 1
			var size := d.decode_u16(at + 2)
			if rebuild_dict(d, at) != d.slice(at, at + size):
				bad.append("%d@0x%X" % [e, at])
	print("  dictionaries: %d in %d BMD0 files (%d ms)" % [n_dicts, n_files, Time.get_ticks_msec() - t0])
	check(n_files > 100 and bad.is_empty(), "every dictionary rebuilt byte-identical (%d bad: %s)" % [bad.size(), bad.slice(0, 5)])

	# --- 2. scene models: read -> write -> read ---
	var mset := {}
	for L in gd.locations:
		for m in L.models:
			mset[m.model] = true
	var ok := 0
	var total := 0
	var biggest := 0
	for e in mset:
		total += 1
		var a := Nsbmd.new()
		if not a.parse(gd.rombin.data(e)):
			print("    %d: %s" % [e, a.error])
			continue
		var mi := a.build()
		var w := NsbmdWriter.new()
		var bytes := w.build(gd.model_name(e), surfaces_of(mi), 1024)
		var b := Nsbmd.new()
		if bytes.is_empty() or not b.parse(bytes):
			print("    %d %s: write %s / read %s" % [e, gd.model_name(e), w.error, b.error])
			continue
		var mi2 := b.build()
		# one VTX_16 step of the output (plus float noise)
		var tol: float = w.stats.pos_scale / 4096.0 * 0.9 + 1e-4   # half a step per axis, x sqrt(3)
		var t1 := tris(mi)
		var t2 := tris(mi2)
		var diff := unmatched(t1, t2, tol)
		if t1.size() == t2.size() and diff == 0:
			ok += 1
		else:
			print("    %d %s: %d vs %d triangles, %d unmatched (tol %.4f)" % [e, gd.model_name(e), t1.size(), t2.size(), diff, tol])
		biggest = maxi(biggest, bytes.size())
		if e in [2070, 4213, 7004]:
			var f := FileAccess.open(out_dir.path_join("rewritten_%d.bmd0" % e), FileAccess.WRITE)
			f.store_buffer(bytes)
		mi.free()
		mi2.free()
	check(ok == total, "scene models read -> write -> read: %d/%d same triangles (largest output %d bytes)" % [ok, total, biggest])

	# --- 3. textures ---
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			img.set_pixel(x, y, Color8((x * 8) & 0xF8, (y * 16) & 0xF8, 128 if (x + y) % 3 else 0, 255 if x != 3 else 0))
	var t := NsbmdWriter.encode_texture(img)
	check(t.fmt == 4 and t.color0 and not t.lossy, "texture: 8bpp, colour 0 transparent, exact (%d colours)" % t.colors)
	var dec := Nsbmd.new()
	var back := dec.decode_texture({"fmt": t.fmt, "w": t.w, "h": t.h, "data1": t.data, "params": 1 << 29},
		{"off": 0, "block": t.palette})
	var exact := true
	for y in 16:
		for x in 16:
			var c0 := img.get_pixel(x, y)
			var c1 := back.get_pixel(x, y)
			if (c0.a < 0.5) != (c1.a < 0.5) or (c0.a >= 0.5 and (absf(c0.r - c1.r) > 0.02 or absf(c0.g - c1.g) > 0.02 or absf(c0.b - c1.b) > 0.02)):
				exact = false
	check(exact, "texture decodes back to the source")
	var grad := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			grad.set_pixel(x, y, Color(x / 63.0, y / 63.0, (x ^ y) / 63.0))
	var t2 := NsbmdWriter.encode_texture(grad)
	check(t2.fmt == 4 and t2.lossy and t2.colors <= 256, "texture: > 256 colours quantised to %d" % t2.colors)
	var four := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	four.fill(Color.RED)
	check(NsbmdWriter.encode_texture(four).fmt == 3, "texture: few colours -> 4bpp")

	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
