extends SceneTree
## BSP compiler checks (BspBuild):
##   Godot --headless --path godot --script res://tests/test_bspbuild.gd -- rom.nds [locations, e.g. 6,24,10]
## 1. two boxes: solid / empty on a grid = union of the boxes; written file parses back identical and passes check();
## 2. original locations: every solid cell becomes a brush, the compiled tree classifies random points like the
##    original (points within 0.01 of a plane skipped), depth and size compared with the original.
## 3. convex_brush / slab_brushes on small meshes.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


static func box(lo: Vector3, hi: Vector3) -> Array:
	return [[1, 0, 0, -hi.x], [-1, 0, 0, lo.x], [0, 1, 0, -hi.y], [0, -1, 0, lo.y], [0, 0, 1, -hi.z], [0, 0, -1, lo.z]]


static func near_plane(bsp: Bsp, p: Vector3, eps: float) -> bool:
	# distance to any node plane on the classification path
	var q := [roundi(p.x * 4096), roundi(p.y * 4096), roundi(p.z * 4096)]
	var n: Bsp.BNode = bsp.root
	while n != null:
		var s: float = (n.normal[0] * p.x + n.normal[1] * p.y + n.normal[2] * p.z) / 4096.0 + n.d / 4096.0
		if absf(s) < eps:
			return true
		var f := n.side(q)
		var c = n.front if f else n.back
		if c == null or c is Bsp.BLeaf:
			return false
		n = c
	return false


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var locs := [6, 24, 10, 22]
	if args.size() > 1:
		locs = Array(args[1].split(",")).map(func(s): return s.to_int())

	# --- 1. boxes ---
	var bb := BspBuild.new()
	var floor_lo := Vector3(-10, -2, -10)
	var floor_hi := Vector3(10, 0, 10)
	var wall_lo := Vector3(-10, 0, -10)
	var wall_hi := Vector3(10, 5, -9)
	var t := bb.compile([box(floor_lo, floor_hi), box(wall_lo, wall_hi)])
	check(t != null, "two boxes compile (%s) %s" % [bb.error, bb.stats])
	if t != null:
		var bytes := t.write()
		var back := Bsp.parse(bytes)
		check(back.error == "" and back.write() == bytes and back.check().is_empty(), "written tree parses back and passes check()")
		var bad := 0
		var n := 0
		for x in range(-12, 13):
			for y in range(-4, 8):
				for z in range(-12, 13):
					var p := Vector3(x + 0.37, y + 0.41, z + 0.29)
					var inside := (p.clamp(floor_lo, floor_hi) == p) or (p.clamp(wall_lo, wall_hi) == p)
					n += 1
					if t.classify(p) != inside:
						bad += 1
		check(bad == 0, "boxes: %d/%d grid points classified like the union" % [n - bad, n])

	# --- 2. original locations ---
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for loc in locs:
		var orig := Bsp.parse(gd.rombin.data(gd.loc(loc).bsp))
		var brushes := []
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for lp in orig.leaves():
			var planes := []
			for pl in Bsp.cell_planes(lp[1]):
				planes.append([pl[1][0] / 4096.0, pl[1][1] / 4096.0, pl[1][2] / 4096.0, pl[2] / 4096.0])
			brushes.append(planes)
		for b in orig.brushes():
			lo = lo.min(b.lo)
			hi = hi.max(b.hi)
		var c := BspBuild.new()
		var nt := c.compile(brushes)
		if nt == null:
			check(false, "location %d: compile failed: %s" % [loc, c.error])
			continue
		var bytes := nt.write()
		var back := Bsp.parse(bytes)
		var bad := 0
		var n := 0
		var skipped := 0
		for k in 4000:
			var p := Vector3(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y), rng.randf_range(lo.z, hi.z))
			if near_plane(orig, p, 0.01) or near_plane(nt, p, 0.01):
				skipped += 1
				continue
			n += 1
			if orig.classify(p) != nt.classify(p):
				bad += 1
		var orig_size := gd.rombin.data(gd.loc(loc).bsp).size()
		print("    location %d: %d cells -> %d nodes %d leaves, depth %d, %d bytes (original %d bytes), %d ms" % [
			loc, brushes.size(), c.stats.nodes, c.stats.leaves, c.stats.depth, bytes.size(), orig_size, c.stats.ms])
		check(back.error == "" and back.check().is_empty() and bad == 0 and c.stats.depth <= BspBuild.MAX_DEPTH,
			"location %d: recompiled, %d/%d points agree (%d near a plane skipped)" % [loc, n - bad, n, skipped])

	# --- 3. brushes from meshes ---
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 2, 6)
	var arr := bm.get_mesh_arrays()
	var planes := BspBuild.convex_brush(arr[Mesh.ARRAY_VERTEX], arr[Mesh.ARRAY_INDEX])
	check(planes.size() == 6, "convex_brush: a box gives 6 planes (%d)" % planes.size())
	var tb := BspBuild.new().compile([planes])
	check(tb != null and tb.classify(Vector3(1.9, 0.9, 2.9)) and not tb.classify(Vector3(2.1, 0, 0)),
		"convex_brush: solid inside, empty outside (outward normals)")
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 8)
	var pa := pm.get_mesh_arrays()
	var slabs := BspBuild.slab_brushes(pa[Mesh.ARRAY_VERTEX], pa[Mesh.ARRAY_INDEX], 0.5)
	var ts := BspBuild.new().compile(slabs)
	check(ts != null and ts.classify(Vector3(1, -0.25, 1)) and not ts.classify(Vector3(1, 0.25, 1))
		and not ts.classify(Vector3(1, -0.75, 1)), "slab_brushes: a floor plane gives a 0.5 slab under its top face")

	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
