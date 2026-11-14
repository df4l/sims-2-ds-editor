class_name Bsp
extends RefCounted
## Location collision: solid-leaf plane tree (docs/formats/location.md §3), traced by Clsn_TraceBoxBsp 0x01ffc558.
## "BSP\0" u32 5 | u32 0 | u32 file_size | u32 root_offset (0x14)
## node (0x1C): s32 front, s32 back, u32 flags, s32 normal[3] (fx 20.12), s32 d (fx32); solid side: n.p/4096 + d <= 0
##   front > 0 node offset, < 0 leaf at -front; back > 0 node offset, 0 = empty space.
##   flags: bit0 sign of the normal on the axis, bits 1-2 axis (3 = arbitrary plane), bit3 only with back == 0.
## leaf: u32 count, u32 node_offset[count] = ancestor planes bounding this solid cell. Storage order: preorder.
## Everything is iterative (GDScript has a shallow call stack). Geometry uses doubles (Arrays), not Vector3.

const FX := 4096
const HEADER := 0x14
const BIG := 16384.0

var root: BNode
var version := 5
var field8 := 0
var error := ""


class BLeaf:
	var faces := []    # BNode


class BNode:
	var flags := 0
	var normal := [0, 0, 0]   # ints fx 20.12
	var d := 0                # int fx32
	var front = null          # BNode or BLeaf
	var back = null           # BNode or null

	func axis() -> int:
		return (flags & 7) >> 1

	func side(p: Array) -> bool:
		var s: int = normal[0] * p[0] + normal[1] * p[1] + normal[2] * p[2]
		return Bsp.fdiv(s, Bsp.FX) + d <= 0


static func fdiv(a: int, b: int) -> int:
	var q := a / b
	if a % b != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q


static func parse(data: PackedByteArray) -> Bsp:
	var t := Bsp.new()
	if data.size() < HEADER or data.slice(0, 4).get_string_from_ascii() != "BSP":
		t.error = "not a BSP file"
		return t
	t.version = data.decode_u32(4)
	t.field8 = data.decode_u32(8)
	var size := data.decode_u32(12)
	var root_off := data.decode_u32(16)
	if size != data.size() or root_off != HEADER:
		t.error = "header: size %d (file %d), root 0x%X" % [size, data.size(), root_off]
		return t
	var nodes := {}
	var pending := []
	var covered := HEADER
	var stack := [root_off]
	var links := []    # [node, front_off, back_off]
	while not stack.is_empty():
		var o: int = stack.pop_back()
		if nodes.has(o) or o + 0x1C > data.size():
			t.error = "node 0x%X shared or out of range" % o
			return t
		var n := BNode.new()
		var f := data.decode_s32(o)
		var b := data.decode_s32(o + 4)
		n.flags = data.decode_u32(o + 8)
		n.normal = [data.decode_s32(o + 12), data.decode_s32(o + 16), data.decode_s32(o + 20)]
		n.d = data.decode_s32(o + 24)
		nodes[o] = n
		covered += 0x1C
		if f == 0 or b < 0:
			t.error = "node 0x%X: front %d back %d" % [o, f, b]
			return t
		if f < 0:
			var lo := -f
			if lo + 4 > data.size():
				t.error = "leaf out of range"
				return t
			var cnt := data.decode_u32(lo)
			var refs := []
			for k in cnt:
				refs.append(data.decode_u32(lo + 4 + 4 * k))
			var leaf := BLeaf.new()
			n.front = leaf
			pending.append([leaf, refs])
			covered += 4 + 4 * cnt
		if b > 0:
			stack.append(b)
		if f > 0:
			stack.append(f)
		links.append([n, f, b])
	if covered != data.size():
		t.error = "tree covers 0x%X of 0x%X bytes" % [covered, data.size()]
		return t
	for l in links:
		if l[1] > 0:
			l[0].front = nodes.get(l[1])
		if l[2] > 0:
			l[0].back = nodes.get(l[2])
	for p in pending:
		for r in p[1]:
			if not nodes.has(r):
				t.error = "leaf face 0x%X is not a node" % r
				return t
			p[0].faces.append(nodes[r])
	t.root = nodes[root_off]
	return t


func nodes() -> Array:
	var out := []
	var st := [root]
	while not st.is_empty():
		var n: BNode = st.pop_back()
		out.append(n)
		if n.back != null:
			st.append(n.back)
		if n.front is BNode:
			st.append(n.front)
	return out


## [[leaf, path]] with path = [[node, took_front], ...] from the root.
func leaves() -> Array:
	var out := []
	var st := [[root, []]]
	while not st.is_empty():
		var e: Array = st.pop_back()
		var n: BNode = e[0]
		var path: Array = e[1]
		if n.back != null:
			st.append([n.back, path + [[n, false]]])
		if n.front is BLeaf:
			out.append([n.front, path + [[n, true]]])
		else:
			st.append([n.front, path + [[n, true]]])
	return out


func write() -> PackedByteArray:
	var order := []
	var offs := {}
	var pos := HEADER
	var st := [root]
	while not st.is_empty():
		var n: BNode = st.pop_back()
		offs[n] = pos
		order.append(n)
		pos += 0x1C
		if n.front is BLeaf:
			offs[n.front] = pos
			order.append(n.front)
			pos += 4 + 4 * n.front.faces.size()
		if n.back != null:
			st.append(n.back)
		if n.front is BNode:
			st.append(n.front)
	var out := PackedByteArray()
	out.resize(pos)
	out[0] = 0x42
	out[1] = 0x53
	out[2] = 0x50
	out[3] = 0
	out.encode_u32(4, version)
	out.encode_u32(8, field8)
	out.encode_u32(12, pos)
	out.encode_u32(16, HEADER)
	for x in order:
		var o: int = offs[x]
		if x is BLeaf:
			out.encode_u32(o, x.faces.size())
			for k in x.faces.size():
				out.encode_u32(o + 4 + 4 * k, offs[x.faces[k]])
		else:
			out.encode_s32(o, -offs[x.front] if x.front is BLeaf else offs[x.front])
			out.encode_s32(o + 4, offs[x.back] if x.back != null else 0)
			out.encode_u32(o + 8, x.flags)
			out.encode_s32(o + 12, x.normal[0])
			out.encode_s32(o + 16, x.normal[1])
			out.encode_s32(o + 20, x.normal[2])
			out.encode_s32(o + 24, x.d)
	return out


## Invariants that hold on all 32 original files.
func check() -> Array:
	var errs := []
	for n in nodes():
		var ax: int = n.axis()
		if ax < 3:
			var e := [0, 0, 0]
			e[ax] = FX if n.flags & 1 else -FX
			if n.normal != e:
				errs.append("axial node flags 0x%X normal %s" % [n.flags, n.normal])
		if n.flags & 8 and n.back != null:
			errs.append("bit3 set with a back child")
	for lp in leaves():
		var anc := {}
		for pe in lp[1]:
			anc[pe[0]] = true
		for f in lp[0].faces:
			if not anc.has(f):
				errs.append("leaf face is not an ancestor")
				break
	return errs


# --- geometry (doubles) -----------------------------------------------------------------------------------------

static func _cube(lo: float, hi: float) -> Array:
	var v := []
	for x in [lo, hi]:
		for y in [lo, hi]:
			for z in [lo, hi]:
				v.append([x, y, z])
	var quads := [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
	var out := []
	for q in quads:
		out.append([v[q[0]], v[q[1]], v[q[2]], v[q[3]]])
	return out


## Convex polyhedron (list of polygons) cut to the side n.p + d <= 0 (normal / d in fx).
static func clip(poly: Array, normal: Array, d: float, eps := 1e-6) -> Array:
	var nx: float = normal[0] / float(FX)
	var ny: float = normal[1] / float(FX)
	var nz: float = normal[2] / float(FX)
	var dd: float = d / float(FX)
	var out := []
	var cut := []
	for f in poly:
		var g := []
		var m: int = f.size()
		for i in m:
			var a: Array = f[i]
			var b: Array = f[(i + 1) % m]
			var sa: float = nx * a[0] + ny * a[1] + nz * a[2] + dd
			var sb: float = nx * b[0] + ny * b[1] + nz * b[2] + dd
			if sa <= eps:
				g.append(a)
			if absf(sa) <= eps:
				cut.append(a)
			elif (sa < -eps and sb > eps) or (sa > eps and sb < -eps):
				var t := sa / (sa - sb)
				var x := [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2])]
				g.append(x)
				cut.append(x)
		if g.size() >= 3:
			out.append(g)
	var cap := []
	for x in cut:
		var dup := false
		for y in cap:
			if (x[0] - y[0]) * (x[0] - y[0]) + (x[1] - y[1]) * (x[1] - y[1]) + (x[2] - y[2]) * (x[2] - y[2]) < 1e-12:
				dup = true
				break
		if not dup:
			cap.append(x)
	if cap.size() >= 3 and not out.is_empty():
		var c := [0.0, 0.0, 0.0]
		for x in cap:
			c[0] += x[0]
			c[1] += x[1]
			c[2] += x[2]
		c = [c[0] / cap.size(), c[1] / cap.size(), c[2] / cap.size()]
		var u := [cap[0][0] - c[0], cap[0][1] - c[1], cap[0][2] - c[2]]
		var w := [ny * u[2] - nz * u[1], nz * u[0] - nx * u[2], nx * u[1] - ny * u[0]]
		var keyed := []
		for x in cap:
			var r := [x[0] - c[0], x[1] - c[1], x[2] - c[2]]
			keyed.append([atan2(r[0] * w[0] + r[1] * w[1] + r[2] * w[2], r[0] * u[0] + r[1] * u[1] + r[2] * u[2]), x])
		keyed.sort_custom(func(p, q): return p[0] < q[0])
		var capp := []
		for k in keyed:
			capp.append(k[1])
		out.append(capp)
	return out


static func volume(poly: Array) -> float:
	if poly.size() < 4:
		return 0.0
	var c := [0.0, 0.0, 0.0]
	var n := 0
	for f in poly:
		for v in f:
			c[0] += v[0]
			c[1] += v[1]
			c[2] += v[2]
			n += 1
	c = [c[0] / n, c[1] / n, c[2] / n]
	var vol := 0.0
	for f in poly:
		var f0: Array = f[0]
		for k in range(1, f.size() - 1):
			var a: Array = f[k]
			var b: Array = f[k + 1]
			var p := [f0[0] - c[0], f0[1] - c[1], f0[2] - c[2]]
			var q := [a[0] - c[0], a[1] - c[1], a[2] - c[2]]
			var r := [b[0] - c[0], b[1] - c[1], b[2] - c[2]]
			vol += absf(p[0] * (q[1] * r[2] - q[2] * r[1]) - p[1] * (q[0] * r[2] - q[2] * r[0]) + p[2] * (q[0] * r[1] - q[1] * r[0])) / 6.0
	return vol


## Display geometry of every solid cell: [{verts: PackedVector3Array, faces: [PackedInt32Array], inside: Vector3,
## lo: Vector3, hi: Vector3}] (layout units). The cell region is the intersection of its leaf face planes.
func brushes() -> Array:
	var out := []
	for lp in leaves():
		var leaf: BLeaf = lp[0]
		var took := {}
		for pe in lp[1]:
			took[pe[0]] = pe[1]
		var poly := _cube(-BIG, BIG)
		for f in leaf.faces:
			if took.get(f, true):
				poly = clip(poly, f.normal, f.d)
			else:
				poly = clip(poly, [-f.normal[0], -f.normal[1], -f.normal[2]], -f.d)
			if poly.is_empty():
				break
		if poly.size() < 4:
			continue
		var verts := PackedVector3Array()
		var faces := []
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		var unbounded := false
		var sum := Vector3.ZERO
		for f in poly:
			var idx := PackedInt32Array()
			for v in f:
				if absf(v[0]) > BIG * 0.5 or absf(v[1]) > BIG * 0.5 or absf(v[2]) > BIG * 0.5:
					unbounded = true
				var pv := Vector3(v[0], v[1], v[2])
				var k := -1
				for j in verts.size():
					if verts[j].distance_squared_to(pv) < 1e-6:
						k = j
						break
				if k < 0:
					k = verts.size()
					verts.append(pv)
					sum += pv
					lo = lo.min(pv)
					hi = hi.max(pv)
				idx.append(k)
			faces.append(idx)
		if unbounded or verts.size() < 4:
			continue
		out.append({"verts": verts, "faces": faces, "inside": sum / verts.size(), "lo": lo, "hi": hi})
	return out


# --- editing ----------------------------------------------------------------------------------------------------

func _flip(n: BNode) -> void:
	n.normal = [-n.normal[0], -n.normal[1], -n.normal[2]]
	n.d = -n.d
	if n.axis() < 3:
		n.flags ^= 1


## Plane coord = value; solid_below: the solid side is coordinate <= value. Returns [flags, normal, d].
static func axial_plane(axis: int, value: float, solid_below: bool) -> Array:
	var nrm := [0, 0, 0]
	nrm[axis] = FX if solid_below else -FX
	var v := roundi(value * FX)
	return [(axis << 1) | (1 if solid_below else 0), nrm, -v if solid_below else v]


## [leaf, path] of the solid cell holding point p (layout units, Vector3), or [] if p is empty.
func find_cell(p: Vector3) -> Array:
	var q := [roundi(p.x * FX), roundi(p.y * FX), roundi(p.z * FX)]
	var n: BNode = root
	var path := []
	while true:
		var f := n.side(q)
		path.append([n, f])
		var c = n.front if f else n.back
		if c == null:
			return []
		if c is BLeaf:
			return [c, path]
		n = c
	return []


func classify(p: Vector3) -> bool:
	return not find_cell(p).is_empty()


static func cell_polytope(path: Array) -> Array:
	var poly := _cube(-BIG, BIG)
	for pe in path:
		var n: BNode = pe[0]
		if pe[1]:
			poly = clip(poly, n.normal, n.d)
		else:
			poly = clip(poly, [-n.normal[0], -n.normal[1], -n.normal[2]], -n.d)
	return poly


## Planes [flags, normal, d] (front-side form) that carry a facet of the cell.
static func cell_planes(path: Array) -> Array:
	var poly := cell_polytope(path)
	var out := []
	for pe in path:
		var n: BNode = pe[0]
		var fl: int
		var nrm: Array
		var d: int
		if pe[1]:
			fl = n.flags & 7
			nrm = n.normal.duplicate()
			d = n.d
		else:
			fl = (n.flags & 7) ^ (1 if n.axis() < 3 else 0)
			nrm = [-n.normal[0], -n.normal[1], -n.normal[2]]
			d = -n.d
		var nf := [nrm[0] / float(FX), nrm[1] / float(FX), nrm[2] / float(FX)]
		var on := {}
		for f in poly:
			for v in f:
				if absf(nf[0] * v[0] + nf[1] * v[1] + nf[2] * v[2] + d / float(FX)) < 1e-3:
					on[str(v)] = true
		var dup := false
		for o in out:
			if o[1] == nrm and o[2] == d:
				dup = true
		if on.size() >= 3 and not dup:
			out.append([fl, nrm, d])
	return out


func _parents() -> Dictionary:
	var par := {}
	for n in nodes():
		par[n.front] = [n, true]
		if n.back != null:
			par[n.back] = [n, false]
	return par


## Make a solid cell empty (see tools/bsp.py delete_cell). "" or an error.
func delete_cell(leaf: BLeaf) -> String:
	var par := _parents()
	var n: BNode = par[leaf][0]
	while true:
		if n.back != null:
			_flip(n)
			n.front = n.back
			n.back = null
			return ""
		if n == root:
			return "deleting the last solid cell would leave an empty tree"
		var pq: Array = par[n]
		var q: BNode = pq[0]
		if not pq[1]:
			q.back = null
			return ""
		n = q
	return ""


## Add the convex solid {p : n.p + d <= 0 for every plane}; returns the number of empty slots filled (-1: empty brush).
func add_brush(planes: Array) -> int:
	var poly0 := _cube(-BIG, BIG)
	for pl in planes:
		poly0 = clip(poly0, pl[1], pl[2])
	if volume(poly0) < 1e-6:
		return -1
	var filled := 0
	var st := [[root, poly0]]
	while not st.is_empty():
		var e: Array = st.pop_back()
		var n: BNode = e[0]
		var poly: Array = e[1]
		var nf := [n.normal[0] / float(FX), n.normal[1] / float(FX), n.normal[2] / float(FX)]
		var smin := INF
		var smax := -INF
		for f in poly:
			for v in f:
				var s: float = nf[0] * v[0] + nf[1] * v[1] + nf[2] * v[2] + n.d / float(FX)
				smin = minf(smin, s)
				smax = maxf(smax, s)
		if smax > 1e-6:
			var bk := clip(poly, [-n.normal[0], -n.normal[1], -n.normal[2]], -n.d)
			if volume(bk) > 1e-6:
				if n.back == null:
					n.back = _chain(planes)
					n.flags &= ~8
					filled += 1
				else:
					st.append([n.back, bk])
		if smin < -1e-6 and n.front is BNode:
			var fr := clip(poly, n.normal, n.d)
			if volume(fr) > 1e-6:
				st.append([n.front, fr])
	return filled


static func _chain(planes: Array) -> BNode:
	var ns := []
	for pl in planes:
		var n := BNode.new()
		n.flags = pl[0]
		n.normal = pl[1].duplicate()
		n.d = pl[2]
		ns.append(n)
	for k in ns.size() - 1:
		ns[k].front = ns[k + 1]
	var leaf := BLeaf.new()
	leaf.faces = ns.duplicate()
	ns[-1].front = leaf
	return ns[0]


func add_box(lo: Vector3, hi: Vector3) -> int:
	var planes := []
	for ax in 3:
		planes.append(axial_plane(ax, hi[ax], true))
		planes.append(axial_plane(ax, lo[ax], false))
	return add_brush(planes)


## Move a solid cell by delta: delete it, then add its facet planes shifted. Returns add_brush's count, or -2 on error.
func move_cell(leaf: BLeaf, path: Array, delta: Vector3) -> int:
	var t := [roundi(delta.x * FX), roundi(delta.y * FX), roundi(delta.z * FX)]
	var planes := []
	for pl in cell_planes(path):
		var nrm: Array = pl[1]
		planes.append([pl[0], nrm, pl[2] - fdiv(nrm[0] * t[0] + nrm[1] * t[1] + nrm[2] * t[2], FX)])
	if delete_cell(leaf) != "":
		return -2
	return add_brush(planes)
