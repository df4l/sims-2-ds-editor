class_name Nsbmd
extends RefCounted
## BMD0 (NNS G3D model) -> Godot mesh, bind pose. Port of the parts of nitrogen (itself a port of apicula) the old
## editor used, with the UV fixes of tools/nitro.py:
##  - texture coordinates go through the NNS Maya texture SRT (pivot in UV space, noclip calcTexMtx_Maya);
##  - repeat / mirror / clamp per axis come from the material teximage_param | the texture params;
##  - V = 0 on the first texture row (DS t = 0).
## Optional prop variant texture (512-byte palette + 8bpp texels, roomfurn.prop_texture) swapped in like
## Gfx_ReplaceModelTexture 0x020bbee0.

const _GPU_SIZES := [
	0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 1, 0, 1, 1, 1, 0,
	16, 12, 16, 12, 9, 3, 3, -1, -1, -1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1,
	-1, -1, -1, -1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 1, 0,
]
const _RENDER_PARAMS := {0x00: 0, 0x01: 0, 0x02: 2, 0x03: 1, 0x04: 1, 0x05: 1, 0x06: 3, 0x07: 1, 0x08: 1, 0x0B: 0,
	0x0C: 2, 0x0D: 2, 0x24: 1, 0x26: 4, 0x2B: 0, 0x40: 0, 0x44: 1, 0x46: 4, 0x47: 2, 0x66: 5, 0x80: 0}

static var _shaders := {}

var buf: PackedByteArray
var error := ""
var textures := {}    # name -> {params, data1, data2}
var palettes := {}    # name -> {off, block}
var model := {}       # first model of MDL0


static func fix(x: int, sign_bits: int, int_bits: int, frac_bits: int) -> float:
	var total := sign_bits + int_bits + frac_bits
	x &= (1 << total) - 1
	if sign_bits and x & (1 << (int_bits + frac_bits)):
		x -= 1 << total
	return x / float(1 << frac_bits)


func _u16(o: int) -> int:
	return buf.decode_u16(o)


func _u32(o: int) -> int:
	return buf.decode_u32(o)


## [[datum offset, name], ...] of a Nitro info block.
func _info(at: int, datum_size: int) -> Array:
	var count := buf[at + 1]
	var data_start := at + 16 + 4 * count
	var names_start := data_start + count * datum_size
	var out := []
	for i in count:
		var n := buf.slice(names_start + 16 * i, names_start + 16 * i + 16).get_string_from_ascii()
		out.append([data_start + i * datum_size, n])
	return out


## Parse a BMD0. Returns false (see error) when there is no usable model.
func parse(d: PackedByteArray) -> bool:
	buf = d
	if d.size() < 16 or d.slice(0, 4).get_string_from_ascii() != "BMD0":
		error = "not a BMD0"
		return false
	var mdl_at := -1
	for i in d.decode_u16(14):
		var off := d.decode_u32(16 + 4 * i)
		var stamp := d.slice(off, off + 4).get_string_from_ascii()
		if stamp == "MDL0":
			mdl_at = off
		elif stamp == "TEX0":
			_read_tex(off)
	if mdl_at < 0:
		error = "no MDL0"
		return false
	var models := _info(mdl_at + 8, 4)
	if models.is_empty():
		error = "empty MDL0"
		return false
	model = _read_model(mdl_at + _u32(models[0][0]), models[0][1])
	return not model.is_empty()


func _read_tex(at: int) -> void:
	var texture_off := _u16(at + 14)
	var tex_block := _u32(at + 20)
	var c1 := _u32(at + 36)
	var c2 := _u32(at + 40)
	var pal_len := _u16(at + 48) << 3
	var palette_off := _u32(at + 52)
	var pal_block_off := _u32(at + 56)
	var pal_block := buf.slice(at + pal_block_off, at + pal_block_off + pal_len)
	for e in _info(at + texture_off, 8):
		var params := _u32(e[0])
		var off := (params & 0xFFFF) << 3
		var fmt := (params >> 26) & 7
		var w := 8 << ((params >> 20) & 7)
		var h := 8 << ((params >> 23) & 7)
		var bpp: int = [0, 8, 2, 4, 8, 2, 8, 16][fmt]
		var ln := w * h * bpp / 8
		var t := {"params": params, "fmt": fmt, "w": w, "h": h}
		if fmt == 5:
			t.data1 = buf.slice(at + c1 + off, at + c1 + off + ln)
			t.data2 = buf.slice(at + c2 + off / 2, at + c2 + off / 2 + ln / 2)
		else:
			t.data1 = buf.slice(at + tex_block + off, at + tex_block + off + ln)
			t.data2 = PackedByteArray()
		textures[e[1]] = t
	for e in _info(at + palette_off, 4):
		palettes[e[1]] = {"off": _u16(e[0]) << 3, "block": pal_block}


func _read_model(at: int, name: String) -> Dictionary:
	var m := {"name": name}
	var render_off := _u32(at + 4)
	var mat_off := _u32(at + 8)
	var pieces_off := _u32(at + 12)
	var inv_off := _u32(at + 16)
	var num_objects := buf[at + 23]
	m.up_scale = fix(_u32(at + 28), 1, 19, 12)
	m.down_scale = fix(_u32(at + 32), 1, 19, 12)
	m.ops = _parse_render(at + render_off)
	m.pieces = []
	for e in _info(at + pieces_off, 4):
		var base := at + pieces_off + _u32(e[0])
		var co := _u32(base + 8)
		var cl := _u32(base + 12)
		m.pieces.append(buf.slice(base + co, base + co + cl))
	m.materials = _read_materials(at + mat_off)
	m.objects = []
	for e in _info(at + 64, 4):
		m.objects.append(_read_object(at + 64 + _u32(e[0])))
	m.inv_binds = []
	var p := at + inv_off
	for _k in num_objects:
		if p + 84 > buf.size():
			break
		var v := []
		for j in 12:
			v.append(fix(_u32(p + 4 * j), 1, 19, 12))
		# column-major 4x3 -> affine rows
		m.inv_binds.append(PackedFloat64Array([v[0], v[3], v[6], v[9], v[1], v[4], v[7], v[10], v[2], v[5], v[8], v[11]]))
		p += 84
	return m


func _read_materials(at: int) -> Array:
	var tex_pair := _u16(at)
	var pal_pair := _u16(at + 2)
	var mats := []
	for e in _info(at + 4, 4):
		mats.append(_read_material(at + _u32(e[0]), e[1]))
	for e in _info(at + tex_pair, 4):
		var off := _u16(e[0])
		for k in buf[e[0] + 2]:
			var mi := buf[at + off + k]
			if mi < mats.size():
				mats[mi].texture = e[1]
	for e in _info(at + pal_pair, 4):
		var off := _u16(e[0])
		for k in buf[e[0] + 2]:
			var mi := buf[at + off + k]
			if mi < mats.size():
				mats[mi].palette = e[1]
	return mats


func _read_material(at: int, name: String) -> Dictionary:
	var dif_amb := _u32(at + 4)
	var poly_attr := _u32(at + 12)
	var poly_mask := _u32(at + 16)
	var teximage := _u32(at + 20)
	var flags := _u16(at + 0x1E)
	var mat := {"name": name, "texture": "", "palette": "",
		"params": teximage & poly_mask, "teximage": teximage,
		"width": _u16(at + 32), "height": _u16(at + 34),
		"diffuse": _rgb(dif_amb & 0x7FFF), "diffuse_default": (dif_amb >> 15) & 1 == 1,
		"alpha": ((poly_attr >> 16) & 31) / 31.0,
		"cull_back": (poly_attr >> 6) & 1 == 0}
	var srt := [1.0, 1.0, 0.0, 1.0, 0.0, 0.0]
	if flags & 1:
		var p := at + 0x2C
		if not flags & 2:
			srt[0] = buf.decode_s32(p) / 4096.0
			srt[1] = buf.decode_s32(p + 4) / 4096.0
			p += 8
		if not flags & 4:
			srt[2] = buf.decode_s16(p) / 4096.0
			srt[3] = buf.decode_s16(p + 2) / 4096.0
			p += 4
		if not flags & 8:
			srt[4] = buf.decode_s32(p) / 4096.0
			srt[5] = buf.decode_s32(p + 4) / 4096.0
	mat.srt = srt
	return mat


static func _rgb(x: int) -> Color:
	return Color((x & 31) / 31.0, ((x >> 5) & 31) / 31.0, ((x >> 10) & 31) / 31.0)


func _read_object(at: int) -> PackedFloat64Array:
	var flags := _u16(at)
	var t := flags & 1
	var r := (flags >> 1) & 1
	var s := (flags >> 2) & 1
	var pv := (flags >> 3) & 1
	var m0 := _u16(at + 2)
	var p := at + 4
	var trans = null
	var rot = null   # 9 floats row-major
	var scale = null
	if t == 0:
		trans = [fix(_u32(p), 1, 19, 12), fix(_u32(p + 4), 1, 19, 12), fix(_u32(p + 8), 1, 19, 12)]
		p += 12
	if pv == 1:
		var a := fix(_u16(p), 1, 3, 12)
		var b := fix(_u16(p + 2), 1, 3, 12)
		p += 4
		rot = _pivot((flags >> 4) & 15, (flags >> 8) & 15, a, b)
	elif r == 0:
		var mm := [fix(m0, 1, 3, 12)]
		for k in 8:
			mm.append(fix(_u16(p + 2 * k), 1, 3, 12))
		p += 16
		rot = _colmajor(mm)
	if s == 0:
		scale = [fix(_u32(p), 1, 19, 12), fix(_u32(p + 4), 1, 19, 12), fix(_u32(p + 8), 1, 19, 12)]
	# T * R * S as an affine 3x4
	var m := _ident()
	if scale != null:
		m = PackedFloat64Array([scale[0], 0, 0, 0, 0, scale[1], 0, 0, 0, 0, scale[2], 0])
	if rot != null:
		var rm := PackedFloat64Array([rot[0], rot[1], rot[2], 0, rot[3], rot[4], rot[5], 0, rot[6], rot[7], rot[8], 0])
		m = _mul(rm, m)
	if trans != null:
		m[3] += trans[0]
		m[7] += trans[1]
		m[11] += trans[2]
	return m


static func _colmajor(a: Array) -> Array:
	return [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]


static func _pivot(sel: int, neg: int, a: float, b: float) -> Array:
	if sel >= 9:
		return _colmajor([-a, 0, 0, 0, 0, 0, 0, 0, 0])
	var o := 1.0 if neg & 1 == 0 else -1.0
	var c := b if neg & 2 == 0 else -b
	var d := a if neg & 4 == 0 else -a
	var table := [
		[o, 0, 0, 0, a, b, 0, c, d], [0, o, 0, a, 0, b, c, 0, d], [0, 0, o, a, b, 0, c, d, 0],
		[0, a, b, o, 0, 0, 0, c, d], [a, 0, b, 0, o, 0, c, 0, d], [a, b, 0, 0, 0, o, c, d, 0],
		[0, a, b, 0, c, d, o, 0, 0], [a, 0, b, c, 0, d, 0, o, 0], [a, b, 0, c, d, 0, 0, 0, o],
	]
	return _colmajor(table[sel])


func _parse_render(at: int) -> Array:
	var ops := []
	var p := at
	var n := buf.size()
	while p < n:
		var op := buf[p]
		p += 1
		var params: PackedByteArray
		if op == 0x09:
			var cnt := buf[p + 1]
			params = buf.slice(p, p + 2 + 3 * cnt)
			p += 2 + 3 * cnt
		else:
			if not _RENDER_PARAMS.has(op):
				return ops
			params = buf.slice(p, p + _RENDER_PARAMS[op])
			p += _RENDER_PARAMS[op]
		match op:
			0x00, 0x02:
				pass
			0x01:
				return ops
			0x03:
				ops.append(["load", params[0]])
			0x04, 0x24, 0x44:
				ops.append(["mat", params[0]])
			0x05:
				ops.append(["draw", params[0]])
			0x06, 0x26, 0x46, 0x66:
				if op == 0x46:
					ops.append(["load", params[3]])
				elif op == 0x66:
					ops.append(["load", params[4]])
				ops.append(["obj", params[0]])
				if op == 0x26 or op == 0x66:
					ops.append(["store", params[3]])
			0x09:
				var terms := []
				for k in params[1]:
					terms.append([params[2 + 3 * k], params[3 + 3 * k], params[4 + 3 * k] / 256.0])
				ops.append(["skin", terms])
				ops.append(["store", params[0]])
			0x0B:
				ops.append(["up"])
			0x2B:
				ops.append(["down"])
	return ops


# --- affine 3x4 (row-major) -------------------------------------------------------------------------------------

static func _ident() -> PackedFloat64Array:
	return PackedFloat64Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])


static func _mul(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(12)
	for i in 3:
		for j in 4:
			var v := a[4 * i] * b[j] + a[4 * i + 1] * b[4 + j] + a[4 * i + 2] * b[8 + j]
			if j == 3:
				v += a[4 * i + 3]
			r[4 * i + j] = v
	return r


static func _scale(m: PackedFloat64Array, x: float, y: float, z: float) -> PackedFloat64Array:
	return _mul(m, PackedFloat64Array([x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0]))


# --- geometry -----------------------------------------------------------------------------------------------------

## Build the bind-pose mesh. Returns a MeshInstance3D (null if nothing to draw).
## variant: optional prop variant texture (see class doc).
func build(variant := PackedByteArray()) -> MeshInstance3D:
	if not variant.is_empty():
		_swap_texture(variant)
	var mats: Array = model.materials
	var objs: Array = model.objects
	var stack := []
	for _k in 32:
		stack.append(_ident())
	var cur := _ident()
	var cur_mat := 0
	# per material: positions, colors, uvs, indices
	var surf := {}
	var uvmaps := []
	for m in mats:
		uvmaps.append(_uv_map(m))
	for op in model.ops:
		match op[0]:
			"load":
				cur = stack[op[1]].duplicate()
			"store":
				stack[op[1]] = cur.duplicate()
			"obj":
				if op[1] < objs.size():
					cur = _mul(cur, objs[op[1]])
			"skin":
				var acc := PackedFloat64Array()
				acc.resize(12)
				for t in op[1]:
					if t[0] < 32 and t[1] < model.inv_binds.size():
						var pm := _mul(stack[t[0]], model.inv_binds[t[1]])
						for k in 12:
							acc[k] += t[2] * pm[k]
				cur = acc
			"up":
				cur = _scale(cur, model.up_scale, model.up_scale, model.up_scale)
			"down":
				cur = _scale(cur, model.down_scale, model.down_scale, model.down_scale)
			"mat":
				cur_mat = op[1]
			"draw":
				if op[1] < model.pieces.size():
					if not surf.has(cur_mat):
						surf[cur_mat] = {"v": PackedVector3Array(), "c": PackedColorArray(), "uv": PackedVector2Array(),
							"i": PackedInt32Array()}
					var mat: Dictionary = mats[cur_mat] if cur_mat < mats.size() else {}
					cur = _run_piece(model.pieces[op[1]], cur, stack, surf[cur_mat], mat,
						uvmaps[cur_mat] if cur_mat < uvmaps.size() else [])
	var mesh := ArrayMesh.new()
	for mi in surf:
		var s: Dictionary = surf[mi]
		if s.i.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s.v
		arr[Mesh.ARRAY_COLOR] = s.c
		arr[Mesh.ARRAY_TEX_UV] = s.uv
		arr[Mesh.ARRAY_INDEX] = s.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(mats[mi] if mi < mats.size() else {}))
	if mesh.get_surface_count() == 0:
		return null
	var mi3 := MeshInstance3D.new()
	mi3.mesh = mesh
	mi3.name = model.name
	return mi3


## [a, b, c, d, e, f] with u = a s + b t + e, v = c s + d t + f in the stored texture's UV space (see tools/nitro.py).
func _uv_map(mat: Dictionary) -> Array:
	var t = textures.get(mat.texture) if mat.texture != "" else null
	if t == null:
		return []
	var tw: float = t.w
	var th: float = t.h
	var ow: float = mat.width if mat.width else tw
	var oh: float = mat.height if mat.height else th
	var srt: Array = mat.srt
	var ss: float = srt[0]
	var st: float = srt[1]
	var sn: float = srt[2]
	var cs: float = srt[3]
	var ts: float = srt[4]
	var tt: float = srt[5]
	var a := ss * cs / ow
	var b := ss * sn / oh
	var c := -st * sn / ow
	var d := st * cs / oh
	var e := ss * (-0.5 * cs - (0.5 * sn - 0.5) - ts)
	var f := st * (-0.5 * cs + (0.5 * sn - 0.5) + tt) + 1.0
	var ku := ow / tw
	var kv := oh / th
	return [a * ku, b * ku, c * kv, d * kv, e * ku, f * kv]


func _run_piece(cmds: PackedByteArray, cur: PackedFloat64Array, stack: Array, s: Dictionary, mat: Dictionary,
		uvm: Array) -> PackedFloat64Array:
	var pos := 0
	var n := cmds.size()
	var fifo := []
	var vx := 0.0
	var vy := 0.0
	var vz := 0.0
	var uv := Vector2.ZERO
	var col := Color.WHITE
	if not mat.is_empty() and mat.diffuse_default and mat.diffuse != Color.WHITE:
		col = mat.diffuse
	var prim := 0
	var V: PackedVector3Array = s.v
	var C: PackedColorArray = s.c
	var U: PackedVector2Array = s.uv
	var I: PackedInt32Array = s.i
	var first: int = V.size()
	while true:
		if fifo.is_empty():
			if n - pos < 4:
				break
			fifo = [cmds[pos], cmds[pos + 1], cmds[pos + 2], cmds[pos + 3]]
			pos += 4
		var op: int = fifo.pop_front()
		if op >= _GPU_SIZES.size() or _GPU_SIZES[op] < 0:
			break
		var np: int = _GPU_SIZES[op]
		if n - pos < 4 * np:
			break
		var p0 := cmds.decode_u32(pos) if np > 0 else 0
		var p1 := cmds.decode_u32(pos + 4) if np > 1 else 0
		var p2 := cmds.decode_u32(pos + 8) if np > 2 else 0
		pos += 4 * np
		var emit := false
		match op:
			0x14:
				var idx := p0 & 31
				if idx < stack.size():
					cur = stack[idx].duplicate()
			0x1B:
				cur = _scale(cur, fix(p0, 1, 19, 12), fix(p1, 1, 19, 12), fix(p2, 1, 19, 12))
			0x40:
				I.append_array(_prim_indices(first, V.size(), prim))
				first = V.size()
				prim = p0 & 3
			0x41:
				I.append_array(_prim_indices(first, V.size(), prim))
				first = V.size()
			0x23:
				vx = fix(p0 & 0xFFFF, 1, 3, 12)
				vy = fix(p0 >> 16, 1, 3, 12)
				vz = fix(p1 & 0xFFFF, 1, 3, 12)
				emit = true
			0x24:
				vx = fix(p0 & 0x3FF, 1, 3, 6)
				vy = fix((p0 >> 10) & 0x3FF, 1, 3, 6)
				vz = fix((p0 >> 20) & 0x3FF, 1, 3, 6)
				emit = true
			0x25:
				vx = fix(p0 & 0xFFFF, 1, 3, 12)
				vy = fix(p0 >> 16, 1, 3, 12)
				emit = true
			0x26:
				vx = fix(p0 & 0xFFFF, 1, 3, 12)
				vz = fix(p0 >> 16, 1, 3, 12)
				emit = true
			0x27:
				vy = fix(p0 & 0xFFFF, 1, 3, 12)
				vz = fix(p0 >> 16, 1, 3, 12)
				emit = true
			0x28:
				vx += 0.125 * fix(p0 & 0x3FF, 1, 0, 9)
				vy += 0.125 * fix((p0 >> 10) & 0x3FF, 1, 0, 9)
				vz += 0.125 * fix((p0 >> 20) & 0x3FF, 1, 0, 9)
				emit = true
			0x22:
				var ts := fix(p0 & 0xFFFF, 1, 11, 4)
				var tt := fix(p0 >> 16, 1, 11, 4)
				if not uvm.is_empty():
					uv = Vector2(uvm[0] * ts + uvm[1] * tt + uvm[4], uvm[2] * ts + uvm[3] * tt + uvm[5])
			0x20:
				col = Color((p0 & 31) / 31.0, ((p0 >> 5) & 31) / 31.0, ((p0 >> 10) & 31) / 31.0)
			0x21:
				col = Color.WHITE
		if emit:
			V.append(Vector3(cur[0] * vx + cur[1] * vy + cur[2] * vz + cur[3],
				cur[4] * vx + cur[5] * vy + cur[6] * vz + cur[7],
				cur[8] * vx + cur[9] * vy + cur[10] * vz + cur[11]))
			C.append(col)
			U.append(uv)
	I.append_array(_prim_indices(first, V.size(), prim))
	s.v = V
	s.c = C
	s.uv = U
	s.i = I
	return cur


## Triangles of the vertices [first, end) for primitive type prim, clockwise for Godot (DS / glTF are CCW).
static func _prim_indices(first: int, end: int, prim: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	match prim:
		0:
			var i := first
			while i + 2 < end:
				idx.append_array([i, i + 2, i + 1])
				i += 3
		1:
			var i := first
			while i + 3 < end:
				idx.append_array([i, i + 2, i + 1, i, i + 3, i + 2])
				i += 4
		2:
			var i := first
			var odd := false
			while i + 2 < end:
				if odd:
					idx.append_array([i, i + 1, i + 2])
				else:
					idx.append_array([i, i + 2, i + 1])
				i += 1
				odd = not odd
		3:
			var i := first
			while i + 3 < end:
				# quad (i, i+1, i+3, i+2)
				idx.append_array([i, i + 3, i + 1, i, i + 2, i + 3])
				i += 2
	return idx


# --- textures -----------------------------------------------------------------------------------------------------

func _swap_texture(tex: PackedByteArray) -> void:
	for name in textures:
		var t: Dictionary = textures[name]
		if t.fmt == 4 and tex.size() == 512 + t.w * t.h:
			t.data1 = tex.slice(512)
			for m in model.materials:
				if m.texture == name and palettes.has(m.palette):
					palettes[m.palette] = {"off": 0, "block": tex.slice(0, 512)}
			return


static func _c5(x: int) -> int:
	return ((x << 3) | (x >> 2)) & 0xFF


func decode_texture(t: Dictionary, pal) -> Image:
	var fmt: int = t.fmt
	var w: int = t.w
	var h: int = t.h
	var d1: PackedByteArray = t.data1
	if fmt != 7 and pal == null:
		return null
	var pb: PackedByteArray = pal.block if pal != null else PackedByteArray()
	var po: int = pal.off if pal != null else 0
	var c0t: bool = (t.params >> 29) & 1 == 1
	# palette -> RGB bytes
	var pr := PackedByteArray()
	var npal := (pb.size() - po) / 2 if pal != null else 0
	pr.resize(maxi(npal, 0) * 3)
	for i in npal:
		var c := pb.decode_u16(po + 2 * i)
		pr[3 * i] = _c5(c & 31)
		pr[3 * i + 1] = _c5((c >> 5) & 31)
		pr[3 * i + 2] = _c5((c >> 10) & 31)
	var out := PackedByteArray()
	out.resize(w * h * 4)
	var nb := d1.size()
	match fmt:
		1, 6:
			var ib := 5 if fmt == 1 else 3
			for i in mini(w * h, nb):
				var x := d1[i]
				var ci := x & ((1 << ib) - 1)
				var a := x >> ib
				var a5 := ((a << 2) | (a >> 1)) if fmt == 1 else a
				_put(out, i, pr, ci, _c5(a5))
		2, 3, 4:
			var bpp: int = {2: 2, 3: 4, 4: 8}[fmt]
			var per := 8 / bpp
			var mask := (1 << bpp) - 1
			for i in w * h:
				var byte_i := i / per
				if byte_i >= nb:
					break
				var ci := (d1[byte_i] >> ((i % per) * bpp)) & mask
				_put(out, i, pr, ci, 0 if (ci == 0 and c0t) else 255)
		7:
			for i in mini(w * h, nb / 2):
				var c := d1.decode_u16(2 * i)
				out[4 * i] = _c5(c & 31)
				out[4 * i + 1] = _c5((c >> 5) & 31)
				out[4 * i + 2] = _c5((c >> 10) & 31)
				out[4 * i + 3] = 255 if c & 0x8000 else 0
		5:
			_decode_4x4(t, pb, po, out)
		_:
			return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)


static func _put(out: PackedByteArray, i: int, pr: PackedByteArray, ci: int, a: int) -> void:
	if 3 * ci + 2 < pr.size():
		out[4 * i] = pr[3 * ci]
		out[4 * i + 1] = pr[3 * ci + 1]
		out[4 * i + 2] = pr[3 * ci + 2]
	out[4 * i + 3] = a


func _decode_4x4(t: Dictionary, pb: PackedByteArray, po: int, out: PackedByteArray) -> void:
	var w: int = t.w
	var h: int = t.h
	var d1: PackedByteArray = t.data1
	var d2: PackedByteArray = t.data2
	var nbx := w / 4
	for by in h / 4:
		for bx in nbx:
			var bi := by * nbx + bx
			if 4 * bi + 4 > d1.size() or 2 * bi + 2 > d2.size():
				continue
			var block := d1.decode_u32(4 * bi)
			var extra := d2.decode_u16(2 * bi)
			var mode := extra >> 14
			var pa := po + ((extra & 0x3FFF) << 2)
			var cols := []
			for k in 4:
				var o := pa + 2 * k
				var c := pb.decode_u16(o) if o + 2 <= pb.size() else 0
				cols.append([_c5(c & 31), _c5((c >> 5) & 31), _c5((c >> 10) & 31), 255])
			var px: Array
			match mode:
				0: px = [cols[0], cols[1], cols[2], [0, 0, 0, 0]]
				1: px = [cols[0], cols[1], _avg(cols[0], cols[1], 1, 1, 2), [0, 0, 0, 0]]
				2: px = cols
				_: px = [cols[0], cols[1], _avg(cols[1], cols[0], 3, 5, 8), _avg(cols[0], cols[1], 3, 5, 8)]
			for y in 4:
				for x in 4:
					var texel := (block >> (2 * (4 * y + x))) & 3
					var c: Array = px[texel]
					var o := 4 * ((by * 4 + y) * w + bx * 4 + x)
					out[o] = c[0]
					out[o + 1] = c[1]
					out[o + 2] = c[2]
					out[o + 3] = c[3]


static func _avg(a: Array, b: Array, wa: int, wb: int, div: int) -> Array:
	return [(wa * a[0] + wb * b[0]) / div, (wa * a[1] + wb * b[1]) / div, (wa * a[2] + wb * b[2]) / div,
		(wa * a[3] + wb * b[3]) / div]


static func _shader(blend: bool, cull: bool) -> Shader:
	var key := "%s%s" % [blend, cull]
	if _shaders.has(key):
		return _shaders[key]
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, %s, %s;
uniform sampler2D tex : source_color, filter_nearest, repeat_disable;
uniform bool use_tex = false;
uniform vec4 base : source_color = vec4(1.0);
uniform int wrap_s = 0;
uniform int wrap_t = 0;
uniform float alpha_cut = 0.0;
float wrap1(float x, int m) {
	if (m == 1) { return fract(x); }
	if (m == 2) { float t = mod(x, 2.0); return t > 1.0 ? 2.0 - t : t; }
	return clamp(x, 0.0, 1.0);
}
vec3 to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045)));
}
void fragment() {
	vec4 c = base;
	c.rgb *= to_linear(COLOR.rgb);
	if (use_tex) {
		c *= textureLod(tex, vec2(wrap1(UV.x, wrap_s), wrap1(UV.y, wrap_t)), 0.0);
	}
	if (c.a < alpha_cut) { discard; }
	ALBEDO = c.rgb;
	%s
}
""" % ["cull_back" if cull else "cull_disabled", "blend_mix, depth_draw_opaque" if blend else "depth_draw_opaque",
		"ALPHA = c.a;" if blend else ""]
	_shaders[key] = sh
	return sh


func _wrap(param: int, axis: int) -> int:
	if not (param >> (16 + axis)) & 1:
		return 0
	return 2 if (param >> (18 + axis)) & 1 else 1


var _mat_cache := {}


func _material(mat: Dictionary) -> ShaderMaterial:
	var t = null
	var img: Image = null
	if not mat.is_empty() and mat.texture != "" and textures.has(mat.texture):
		t = textures[mat.texture]
		img = decode_texture(t, palettes.get(mat.palette))
	var has_alpha := false
	if t != null and img != null:
		var fmt: int = t.fmt
		has_alpha = fmt in [1, 5, 6, 7] or (fmt in [2, 3, 4] and (t.params >> 29) & 1 == 1)
	var alpha: float = mat.get("alpha", 1.0)
	var blend := alpha < 1.0
	var sm := ShaderMaterial.new()
	sm.shader = _shader(blend, mat.get("cull_back", true))
	if img != null:
		sm.set_shader_parameter("tex", ImageTexture.create_from_image(img))
		sm.set_shader_parameter("use_tex", true)
		var param: int = mat.params | t.params
		sm.set_shader_parameter("wrap_s", _wrap(param, 0))
		sm.set_shader_parameter("wrap_t", _wrap(param, 1))
		sm.set_shader_parameter("base", Color(1, 1, 1, alpha))
	else:
		var dc: Color = mat.get("diffuse", Color.WHITE)
		sm.set_shader_parameter("base", Color(dc.r, dc.g, dc.b, alpha))
	sm.set_shader_parameter("alpha_cut", 0.5 if has_alpha and not blend else 0.0)
	return sm
