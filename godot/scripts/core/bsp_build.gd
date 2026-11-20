class_name BspBuild
extends RefCounted
## Compile convex solid brushes into a location BSP (docs/formats/location.md §3, format in bsp.gd).
## Quake-style solid-leaf compile: a region is split by a face plane of the brush fragments it contains; a region
## becomes a solid leaf once a fragment fills it (all of the fragment's facet planes are on the path), an empty slot
## when no fragment is left. The abstract tree is then mapped to the game's layout, whose front child can be a node or
## a solid leaf and whose back child a node or empty: a plane is flipped when its solid / node side is on the back.
## Leaf lists = the path planes that carry a facet of the cell (the trace only reports a hit on those).
## Limits: depth <= MAX_DEPTH (Clsn_TraceBoxBsp keeps one 0x3C-byte frame per level in a 0x960-byte DTCM buffer,
## 0x027E14AC..0x027E1E0C = 40 frames, ASSUMED from the next referenced symbol; the original trees reach 29).
##
## Brush = Array of planes [nx, ny, nz, d] (floats, unit outward normal, solid where n.p + d <= 0), layout units.

const MAX_DEPTH := 36
const EPS := 1e-4
const FX := Bsp.FX

var error := ""
var stats := {}

var _planes := []        # id -> [ni (3 ints), d (int)], quantised; id ^ 1 = the flipped plane
var _plane_ids := {}     # "nx,ny,nz,d" -> id
var _max_depth := 0


func _pid(n: Array, d: int) -> int:
	var k := "%d,%d,%d,%d" % [n[0], n[1], n[2], d]
	if _plane_ids.has(k):
		return _plane_ids[k]
	var id := _planes.size()
	_planes.append([n, d])
	_planes.append([[-n[0], -n[1], -n[2]], -d])
	_plane_ids[k] = id
	_plane_ids["%d,%d,%d,%d" % [-n[0], -n[1], -n[2], -d]] = id + 1
	return id


## Plane id of a float plane (axial normals snapped exactly).
func _plane(p: Array) -> int:
	var n := [roundi(p[0] * FX), roundi(p[1] * FX), roundi(p[2] * FX)]
	for a in 3:
		if absf(p[a]) > 0.99999:
			n = [0, 0, 0]
			n[a] = FX if p[a] > 0 else -FX
	return _pid(n, roundi(p[3] * FX))


func _side(id: int, v: Array) -> float:
	var pl: Array = _planes[id]
	var n: Array = pl[0]
	return (n[0] * v[0] + n[1] * v[1] + n[2] * v[2]) / float(FX) + pl[1] / float(FX)


func _clip(poly: Array, id: int) -> Array:
	var pl: Array = _planes[id]
	return Bsp.clip(poly, pl[0], pl[1])


## Plane ids (among `ids`) that carry a facet of the polytope (>= 3 vertices on the plane).
func _facets(poly: Array, ids: Array) -> Array:
	var verts := {}
	for f in poly:
		for v in f:
			verts["%.5f,%.5f,%.5f" % v] = v
	var out := []
	for id in ids:
		var on := 0
		for k in verts:
			if absf(_side(id, verts[k])) < EPS * 10:
				on += 1
				if on >= 3:
					out.append(id)
					break
	return out


static func _verts(poly: Array) -> Array:
	var out := []
	for f in poly:
		out.append_array(f)
	return out


## Compile. Returns a Bsp (null + error on failure).
func compile(brushes: Array) -> Bsp:
	error = ""
	_planes.clear()
	_plane_ids.clear()
	_max_depth = 0
	var frags := []
	var t0 := Time.get_ticks_msec()
	for b in brushes:
		var ids := []
		for p in b:
			var id := _plane(p)
			if not id in ids:
				ids.append(id)
		var poly := Bsp._cube(-Bsp.BIG, Bsp.BIG)
		for id in ids:
			poly = _clip(poly, id)
			if poly.is_empty():
				break
		if Bsp.volume(poly) < 1e-4:
			continue
		var faces := _facets(poly, ids)
		if faces.size() < 4:
			continue
		frags.append({"poly": poly, "unused": faces, "verts": _verts(poly)})
	stats = {"brushes": brushes.size(), "used_brushes": frags.size()}
	if frags.is_empty():
		error = "no solid brush (every brush is empty or flat)"
		return null
	var tree = _build(frags, 0)
	if error != "":
		return null
	var bsp := Bsp.new()
	var root = _emit(tree, [])
	if root == null or root is Bsp.BLeaf:
		error = "the collision covers everything or nothing"
		return null
	bsp.root = root
	var bytes := bsp.write()
	stats.nodes = bsp.nodes().size()
	stats.leaves = bsp.leaves().size()
	stats.depth = _max_depth
	stats.bytes = bytes.size()
	stats.ms = Time.get_ticks_msec() - t0
	if _max_depth > MAX_DEPTH:
		error = "collision tree too deep (%d levels, the game handles about %d): simplify the collision" % [_max_depth, MAX_DEPTH]
		return null
	return bsp


## Abstract tree: "E" (empty), {"solid": poly}, or {"plane": id, "front": t, "back": t}.
func _build(frags: Array, depth: int):
	if error != "":
		return "E"
	if frags.is_empty():
		return "E"
	for f in frags:
		if f.unused.is_empty():
			return {"solid": f.poly}
	if depth > MAX_DEPTH + 8:
		error = "collision tree too deep (more than %d levels): simplify the collision" % MAX_DEPTH
		return "E"
	var id := _choose(frags)
	var fr := []
	var bk := []
	var flip := id ^ 1
	for f in frags:
		var smin := INF
		var smax := -INF
		for v in f.verts:
			var s := _side(id, v)
			smin = minf(smin, s)
			smax = maxf(smax, s)
		var un: Array = f.unused.filter(func(x): return x != id and x != flip)
		if smax <= EPS:
			fr.append({"poly": f.poly, "unused": un, "verts": f.verts})
		elif smin >= -EPS:
			bk.append({"poly": f.poly, "unused": un, "verts": f.verts})
		else:
			var pf := _clip(f.poly, id)
			var pb := _clip(f.poly, flip)
			if Bsp.volume(pf) > 1e-6:
				fr.append({"poly": pf, "unused": _facets(pf, un), "verts": _verts(pf)})
			if Bsp.volume(pb) > 1e-6:
				bk.append({"poly": pb, "unused": _facets(pb, un), "verts": _verts(pb)})
	return {"plane": id, "front": _build(fr, depth + 1), "back": _build(bk, depth + 1)}


## Split plane: among the fragments' facet planes, the one with the fewest splits and the best balance; axial planes
## are preferred (cheaper trace, exact).
func _choose(frags: Array) -> int:
	var cands := {}
	for f in frags:
		for id in f.unused:
			cands[id] = cands.get(id, 0) + 1
	var keys := cands.keys()
	# many candidates: keep the most shared ones (cost of the scoring is candidates x fragments)
	if keys.size() > 48:
		keys.sort_custom(func(a, b): return cands[a] > cands[b])
		keys = keys.slice(0, 48)
	var best := -1
	var best_score := INF
	for id in keys:
		var nf := 0
		var nb := 0
		var ns := 0
		for f in frags:
			var smin := INF
			var smax := -INF
			for v in f.verts:
				var s := _side(id, v)
				smin = minf(smin, s)
				smax = maxf(smax, s)
			if smax <= EPS:
				nf += 1
			elif smin >= -EPS:
				nb += 1
			else:
				ns += 1
		var n: Array = _planes[id][0]
		var axial: bool = absi(n[0]) == FX or absi(n[1]) == FX or absi(n[2]) == FX
		var score := 4.0 * ns + absf(nf - nb) + (0.0 if axial else 2.0)
		if score < best_score:
			best_score = score
			best = id
	return best


## Map the abstract tree to Bsp nodes. path: [[BNode, took_front]] of the ancestors. Returns a BNode, a BLeaf
## ("solid" at this place) or null (empty).
func _emit(t, path: Array):
	if t is String:
		return null
	if t.has("solid"):
		_max_depth = maxi(_max_depth, path.size() + 1)
		var leaf := Bsp.BLeaf.new()
		var poly: Array = t.solid
		var vs := _verts(poly)
		for pe in path:
			var n: Bsp.BNode = pe[0]
			var on := 0
			for v in vs:
				if absf((n.normal[0] * v[0] + n.normal[1] * v[1] + n.normal[2] * v[2]) / float(FX) + n.d / float(FX)) < EPS * 10:
					on += 1
			if on >= 3 and not n in leaf.faces:
				leaf.faces.append(n)
		return leaf
	# children first (a subtree can collapse into one solid leaf or into nothing), then orient the plane so that the
	# front child is a node or a solid leaf and the back child a node or empty
	var node := Bsp.BNode.new()
	_set_plane(node, t.plane)
	var sub := path + [[node, true]]
	var fr = _emit(t.front, sub)
	var bk = _emit(t.back, sub)
	if fr == null and bk == null:
		return null
	if fr is Bsp.BLeaf and bk is Bsp.BLeaf:
		# the whole region is solid: one leaf, faces = both leaves' faces except this plane
		var leaf := Bsp.BLeaf.new()
		for l in [fr, bk]:
			for x in l.faces:
				if x != node and not x in leaf.faces:
					leaf.faces.append(x)
		return leaf
	if fr == null or (fr is Bsp.BNode and bk is Bsp.BLeaf):
		_set_plane(node, t.plane ^ 1)
		var tmp = fr
		fr = bk
		bk = tmp
	node.front = fr
	node.back = bk
	_max_depth = maxi(_max_depth, path.size() + 1)
	return node


func _set_plane(node: Bsp.BNode, id: int) -> void:
	var pl: Array = _planes[id]
	node.normal = pl[0].duplicate()
	node.d = pl[1]
	node.flags = 6
	for a in 3:
		if absi(node.normal[a]) == FX:
			node.flags = (a << 1) | (1 if node.normal[a] > 0 else 0)


# --- brushes from geometry ------------------------------------------------------------------------------------------

## Planes of a convex mesh (triangles in Godot winding: clockwise front faces = outward). [] if not convex.
static func convex_brush(verts: PackedVector3Array, indices: PackedInt32Array) -> Array:
	var planes := []
	var t := 0
	while t + 2 < indices.size():
		var a := verts[indices[t]]
		var b := verts[indices[t + 1]]
		var c := verts[indices[t + 2]]
		t += 3
		var n := (c - a).cross(b - a)   # Godot CW front -> outward normal
		if n.length() < 1e-9:
			continue
		n = n.normalized()
		var d := -n.dot(a)
		var dup := false
		for p in planes:
			if absf(p[0] - n.x) < 1e-4 and absf(p[1] - n.y) < 1e-4 and absf(p[2] - n.z) < 1e-4 and absf(p[3] - d) < 1e-3:
				dup = true
				break
		if not dup:
			planes.append([n.x, n.y, n.z, d])
	for p in planes:
		for v in verts:
			if p[0] * v.x + p[1] * v.y + p[2] * v.z + p[3] > 1e-3:
				return []
	return planes


## One thin brush behind each face (thickness along -normal), for collision made from the visible mesh. Coplanar
## triangles sharing an edge are merged into convex polygons first (fewer brushes, smaller tree). Faces smaller than
## min_area are skipped.
static func slab_brushes(verts: PackedVector3Array, indices: PackedInt32Array, thickness := 0.5, min_area := 0.01) -> Array:
	var out := []
	for f in coplanar_polygons(verts, indices, min_area):
		var n: Vector3 = f.n
		var p: Array = f.p
		var a: Vector3 = p[0]
		var planes := [[n.x, n.y, n.z, -n.dot(a)], [-n.x, -n.y, -n.z, n.dot(a) - thickness]]
		var mid := Vector3.ZERO
		for v in p:
			mid += v
		mid /= p.size()
		for k in p.size():
			var e0: Vector3 = p[k]
			var e1: Vector3 = p[(k + 1) % p.size()]
			var en: Vector3 = (e1 - e0).cross(n).normalized()
			if en.dot(mid - e0) > 0:   # outward = away from the polygon
				en = -en
			planes.append([en.x, en.y, en.z, -en.dot(e0)])
		out.append(planes)
	return out


## Faces of a mesh (Godot winding) as convex polygons: coplanar triangles sharing an edge merged while the result
## stays convex. [{n: outward unit normal, p: [Vector3] counter-clockwise around n}].
static func coplanar_polygons(verts: PackedVector3Array, indices: PackedInt32Array, min_area := 0.0) -> Array:
	var groups := {}
	var t := 0
	while t + 2 < indices.size():
		var a := verts[indices[t]]
		var b := verts[indices[t + 1]]
		var c := verts[indices[t + 2]]
		t += 3
		var n := (c - a).cross(b - a)
		if n.length() * 0.5 <= maxf(min_area, 1e-9):
			continue
		n = n.normalized()
		var k := "%d,%d,%d,%d" % [roundi(n.x * 2000), roundi(n.y * 2000), roundi(n.z * 2000), roundi(n.dot(a) * 200)]
		if not groups.has(k):
			groups[k] = []
		groups[k].append({"n": n, "p": [a, c, b]})
	var out := []
	for k in groups:
		var polys: Array = groups[k]
		if polys.size() <= 400:
			_merge_group(polys)
		out.append_array(polys)
	return out


static func _same(a: Vector3, b: Vector3) -> bool:
	return a.distance_squared_to(b) < 1e-8


static func _merge_group(polys: Array) -> void:
	var merged := true
	while merged:
		merged = false
		for i in polys.size():
			for j in range(i + 1, polys.size()):
				var m := _merge2(polys[i], polys[j])
				if not m.is_empty():
					polys[i] = m
					polys.remove_at(j)
					merged = true
					break
			if merged:
				break


## Union of two CCW convex polygons sharing an edge, if convex; {} otherwise.
static func _merge2(P: Dictionary, Q: Dictionary) -> Dictionary:
	var p: Array = P.p
	var q: Array = Q.p
	var n: Vector3 = P.n
	for i in p.size():
		var e: Vector3 = p[i]
		var s: Vector3 = p[(i + 1) % p.size()]
		for j in q.size():
			if _same(q[j], s) and _same(q[(j + 1) % q.size()], e):
				# p rotated to start at s and end at e; q from e (exclusive) round to s (exclusive)
				var r := []
				for k in p.size():
					r.append(p[(i + 1 + k) % p.size()])
				for k in range(2, q.size()):
					r.append(q[(j + k) % q.size()])
				# drop collinear points, check convexity
				var out := []
				for k in r.size():
					var a: Vector3 = r[(k - 1 + r.size()) % r.size()]
					var b: Vector3 = r[k]
					var c: Vector3 = r[(k + 1) % r.size()]
					var cr := (b - a).cross(c - b).dot(n)
					if cr < -1e-6:
						return {}
					if cr > 1e-6:
						out.append(b)
				if out.size() < 3:
					return {}
				return {"n": n, "p": out}
	return {}
