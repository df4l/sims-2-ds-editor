class_name NsbmdWriter
extends RefCounted
## Godot meshes -> BMD0 (NNS G3D model + TEX0), the subset the game's own scene models use (docs/formats/bmd0.md):
##  - one model, one identity node; one material + one shape per surface;
##  - render commands NODEDESC 0, NODE 0 visible, POSSCALE, (MAT m, SHP s)..., INVPOSSCALE, RET (like Jail_Ext);
##  - unlit materials (polyAttr 0x001F0080: lights off, front faces, alpha 31; 0x...C0 when double sided),
##    colour comes from COLOR commands (baked lighting, like the original scenes);
##  - display lists: BEGIN_VTXS triangles, COLOR / TEXCOORD when they change, VTX_16, END_VTXS;
##  - textures: palette formats, 4bpp (<= 16 colours) or 8bpp (median cut to 256), colour 0 transparent when the
##    image has alpha. Sizes are powers of two (8..max_tex).
## Name dictionaries carry the NNS patricia tree (the runtime binds textures / palettes to materials by name through
## it): node i + 1 holds entry i, root = node 0 (refBit 127, zero key). Checked byte-identical on every dictionary of
## the game's models (tests/test_bmd0.gd).
## Input triangles use Godot's winding (clockwise front faces, like Nsbmd.build output); DS / glTF are CCW.

const POLY_ATTR := 0x001F0080
const POLY_MASK := 0x3F1FF8FF
const MAT_FLAG := 0x1FCE
const NODE_IDENTITY := 0x1000F807   # u16 flag 0xF807 (T zero, R zero, S one, no matrix stack), u16 _00 = 1.0
const REPEAT_ST := 0x00030000
## Texture VRAM budget of a location's scene (all its models), plain (non 4x4) texels: the game's 4x4 textures
## (texels + indices) go to other VRAM slots than plain ones. Most plain texels in an original location: 151 552
## (Gym, + 18 688 of 4x4). City Hall re-encoded in 8bpp: 50 944 rendered fine, 183 552 and 232 704 broke the
## textures in the emulator (build/scene_test*/scene_35*.png). So the limit is between 151 552 and 183 552: keep to
## what the game is known to handle. Palettes: 17 120 max in the originals (Store).
const TEX_BUDGET := 151552
const PAL_BUDGET := 17120
## Plain texels of one file = one VRAM allocation, which cannot straddle two 128 KiB VRAM slots: the largest in one
## original file is 116 480 (CultRoom); Gym's 151 552 are split over two files (102 400 + 49 152). City Hall
## re-encoded as ONE file with 149 760 broke the textures (allocation failed, NNS setup FUN_020bd468 returns 0).
const FILE_BUDGET := 116480
const MAX_FILES := 4

var error := ""
var stats := {}


# --- dictionaries ---------------------------------------------------------------------------------------------------

static func _name16(s: String) -> PackedByteArray:
	var b := s.to_ascii_buffer()
	b.resize(16)
	return b


static func _bit(k: PackedByteArray, b: int) -> int:
	return (k[b >> 3] >> (b & 7)) & 1


## Patricia tree nodes [[refbit, left, right, entry], ...] for the names (16-byte keys), inserted in order.
static func patricia(keys: Array) -> Array:
	var nodes := [[127, 0, 0, 0]]
	var zero := PackedByteArray()
	zero.resize(16)
	for idx in keys.size():
		var k: PackedByteArray = keys[idx]
		var p := 0
		var x: int = nodes[0][1]
		while nodes[p][0] > nodes[x][0]:
			p = x
			x = nodes[x][2] if _bit(k, nodes[x][0]) else nodes[x][1]
		var xk: PackedByteArray = zero if x == 0 else keys[nodes[x][3]]
		var d := -1
		for b in range(127, -1, -1):
			if _bit(k, b) != _bit(xk, b):
				d = b
				break
		if d < 0:
			return []   # duplicate name
		p = 0
		x = nodes[0][1]
		while nodes[p][0] > nodes[x][0] and nodes[x][0] > d:
			p = x
			x = nodes[x][2] if _bit(k, nodes[x][0]) else nodes[x][1]
		var t := nodes.size()
		if _bit(k, d):
			nodes.append([d, x, t, idx])
		else:
			nodes.append([d, t, x, idx])
		if p != 0 and _bit(k, nodes[p][0]):
			nodes[p][2] = t
		else:
			nodes[p][1] = t
	# number the nodes in preorder (downward links, left first), like the game's files
	var order := [0]
	var st := [nodes[0][1]] if nodes[0][1] != 0 else []
	while not st.is_empty():
		var x: int = st.pop_back()
		order.append(x)
		for c in [nodes[x][2], nodes[x][1]]:   # pushed right first -> left visited first
			if nodes[c][0] < nodes[x][0]:
				st.append(c)
	var new_of := {}
	for i in order.size():
		new_of[order[i]] = i
	var out := []
	for old in order:
		var nd: Array = nodes[old]
		out.append([nd[0], new_of[nd[1]], new_of[nd[2]], nd[3]])
	return out


## Nitro dictionary: u8 0, u8 n, u16 size | u16 8, u16 entries offset | tree (n + 1) * 4 |
## u16 entry size, u16 names offset | entries | names 16 bytes each. `entries`: one PackedByteArray per name.
static func dict(names: Array, entry_size: int, entries: Array) -> PackedByteArray:
	var n := names.size()
	var keys := []
	for s in names:
		keys.append(_name16(s))
	var tree := patricia(keys)
	if tree.is_empty():
		return PackedByteArray()
	var ofs_entry := 8 + 4 * (n + 1)
	var size := ofs_entry + 4 + n * entry_size + 16 * n
	var out := PackedByteArray()
	out.resize(size)
	out[1] = n
	out.encode_u16(2, size)
	out.encode_u16(4, 8)
	out.encode_u16(6, ofs_entry)
	for i in tree.size():
		for j in 4:
			out[8 + 4 * i + j] = tree[i][j]
	out.encode_u16(ofs_entry, entry_size)
	out.encode_u16(ofs_entry + 2, 4 + n * entry_size)
	for i in n:
		var e: PackedByteArray = entries[i]
		for j in entry_size:
			out[ofs_entry + 4 + i * entry_size + j] = e[j] if j < e.size() else 0
		for j in 16:
			out[ofs_entry + 4 + n * entry_size + 16 * i + j] = keys[i][j]
	return out


static func _u32b(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


static func _align(b: PackedByteArray, n := 4) -> void:
	while b.size() % n:
		b.append(0)


# --- textures -------------------------------------------------------------------------------------------------------

static func _pow2(v: int, lo: int, hi: int) -> int:
	var p := lo
	while p < hi and p * 2 <= v:
		p *= 2
	# round to the nearer power of two
	if p < hi and v - p > p * 2 - v:
		p *= 2
	return p


static func _c555(c: int) -> int:
	return int(round(c * 31.0 / 255.0))


## Image -> {fmt, w, h, data, palette (PackedByteArray of RGB555), color0, colors (used, before padding), lossy}.
static func encode_texture(src: Image, max_tex := 256, max_colors := 256) -> Dictionary:
	var img: Image = src.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := _pow2(img.get_width(), 8, max_tex)
	var h := _pow2(img.get_height(), 8, max_tex)
	if w != img.get_width() or h != img.get_height():
		img.resize(w, h, Image.INTERPOLATE_CUBIC)
	var px := img.get_data()
	var npx := w * h
	var transparent := false
	for i in npx:
		if px[4 * i + 3] < 128:
			transparent = true
			break
	# RGB555 per pixel (-1 = transparent), colour counts
	var keys := PackedInt32Array()
	keys.resize(npx)
	var counts := {}
	for i in npx:
		if transparent and px[4 * i + 3] < 128:
			keys[i] = -1
			continue
		var c := _c555(px[4 * i]) | (_c555(px[4 * i + 1]) << 5) | (_c555(px[4 * i + 2]) << 10)
		keys[i] = c
		counts[c] = counts.get(c, 0) + 1
	var first := 1 if transparent else 0
	var room := clampi(max_colors, 2, 256) - first
	var lut := {}        # rgb555 -> palette index
	var pal := PackedInt32Array()
	if transparent:
		pal.append(0)
	var lossy := false
	if counts.size() <= room:
		for c in counts:
			lut[c] = pal.size()
			pal.append(c)
	else:
		lossy = true
		for box in _median_cut(counts, room):
			var sr := 0.0
			var sg := 0.0
			var sb := 0.0
			var n := 0.0
			for c in box:
				var k: float = counts[c]
				sr += (c & 31) * k
				sg += ((c >> 5) & 31) * k
				sb += ((c >> 10) & 31) * k
				n += k
			var avg := int(round(sr / n)) | (int(round(sg / n)) << 5) | (int(round(sb / n)) << 10)
			for c in box:
				lut[c] = pal.size()
			pal.append(avg)
	var fmt := 3 if pal.size() <= 16 else 4
	var data := PackedByteArray()
	if fmt == 3:
		data.resize(npx / 2)
		for i in npx:
			var ci: int = 0 if keys[i] < 0 else lut[keys[i]]
			data[i >> 1] |= ci << (4 * (i & 1))
	else:
		data.resize(npx)
		for i in npx:
			data[i] = 0 if keys[i] < 0 else lut[keys[i]]
	var used := pal.size()
	while pal.size() % 8:   # palettes start on 16 bytes (non 4-colour formats)
		pal.append(0)
	var pb := PackedByteArray()
	pb.resize(2 * pal.size())
	for i in pal.size():
		pb.encode_u16(2 * i, pal[i])
	return {"fmt": fmt, "w": w, "h": h, "data": data, "palette": pb, "color0": transparent, "colors": used,
		"lossy": lossy}


## Median cut of the RGB555 colours (dict colour -> count) into at most n boxes (arrays of colours).
static func _median_cut(counts: Dictionary, n: int) -> Array:
	var boxes := [counts.keys()]
	while boxes.size() < n:
		# split the box with the largest (channel range * pixel count)
		var best := -1
		var best_score := 0.0
		var best_axis := 0
		for bi in boxes.size():
			var box: Array = boxes[bi]
			if box.size() < 2:
				continue
			var lo := [31, 31, 31]
			var hi := [0, 0, 0]
			var cnt := 0
			for c in box:
				for a in 3:
					var v: int = (c >> (5 * a)) & 31
					lo[a] = mini(lo[a], v)
					hi[a] = maxi(hi[a], v)
				cnt += counts[c]
			for a in 3:
				var score := float(hi[a] - lo[a]) * sqrt(float(cnt))
				if score > best_score:
					best_score = score
					best = bi
					best_axis = a
		if best < 0:
			break
		var box: Array = boxes[best]
		var ax := best_axis
		box.sort_custom(func(p, q): return ((p >> (5 * ax)) & 31) < ((q >> (5 * ax)) & 31))
		var total := 0
		for c in box:
			total += counts[c]
		var acc := 0
		var cut := 1
		for i in box.size() - 1:
			acc += counts[box[i]]
			cut = i + 1
			if acc * 2 >= total:
				break
		boxes[best] = box.slice(0, cut)
		boxes.append(box.slice(cut))
	return boxes


# --- display lists --------------------------------------------------------------------------------------------------

class DL:
	var cmds := []   # [op, [params]]

	func add(op: int, params := []) -> void:
		cmds.append([op, params])

	func bytes() -> PackedByteArray:
		var out := PackedByteArray()
		var i := 0
		while i < cmds.size():
			var group := cmds.slice(i, i + 4)
			for k in 4:
				out.append(group[k][0] if k < group.size() else 0)
			for c in group:
				for p in c[1]:
					var b := PackedByteArray()
					b.resize(4)
					b.encode_u32(0, p & 0xFFFFFFFF)
					out.append_array(b)
			i += 4
		return out


static func _fx16(v: float) -> int:
	return clampi(int(round(v * 4096.0)), -32768, 32767) & 0xFFFF


# --- model ----------------------------------------------------------------------------------------------------------

## surfaces: [{verts: PackedVector3Array, indices: PackedInt32Array (Godot winding), uvs: PackedVector2Array (or
## empty), colors: PackedColorArray (or empty, sRGB / DS values), image: Image or null, double_sided: bool,
## alpha: float 0..1, color: Color (multiplies the vertex colours)}]. Returns the BMD0 bytes (empty + error on failure).
func build(model_name: String, surfaces: Array, max_tex := 256) -> PackedByteArray:
	error = ""
	stats = {"vertices": 0, "triangles": 0, "uv_clamped": 0, "textures": 0, "tex_bytes": 0, "pal_bytes": 0,
		"lossy": []}
	var surfs := surfaces.filter(func(s): return not s.indices.is_empty())
	if surfs.is_empty():
		error = "nothing to draw"
		return PackedByteArray()
	if surfs.size() > 255:
		error = "%d surfaces (materials), 255 at most" % surfs.size()
		return PackedByteArray()
	# textures (same pixels -> one texture)
	var tex_of := {}      # pixels key -> texture index
	var texs := []
	var mat_tex := []     # per surface: texture index or -1
	for s in surfs:
		var img = s.get("image")
		if img == null or s.uvs.is_empty():
			mat_tex.append(-1)
			continue
		var key := _image_key(img)
		if not tex_of.has(key):
			var t := encode_texture(img, max_tex)
			t["name"] = "tex%d" % texs.size()
			t["src"] = img
			t["max"] = max_tex
			t["ncol"] = 256
			tex_of[key] = texs.size()
			texs.append(t)
		mat_tex.append(tex_of[key])
	_fit_budget(texs)
	for t in texs:
		if t.lossy:
			stats.lossy.append(t.name)
	stats.textures = texs.size()

	stats.size = 0
	var one := _build_one(model_name, surfs, texs, mat_tex)
	return one


## Like build(), split into several BMD0 files (at most MAX_FILES) so that each file's plain texels fit FILE_BUDGET
## (one VRAM allocation per file, see TEX_BUDGET). Textures are packed first-fit by decreasing size; untextured
## surfaces go with the first file. Returns [] + error on failure.
func build_split(model_name: String, surfaces: Array, max_tex := 256) -> Array:
	error = ""
	stats = {"vertices": 0, "triangles": 0, "uv_clamped": 0, "textures": 0, "tex_bytes": 0, "pal_bytes": 0,
		"lossy": [], "size": 0}
	var surfs := surfaces.filter(func(s): return not s.indices.is_empty())
	if surfs.is_empty():
		error = "nothing to draw"
		return []
	var tex_of := {}      # pixels key -> texture index
	var texs := []
	var mat_tex := []     # per surface: texture index or -1
	for s in surfs:
		var img = s.get("image")
		if img == null or s.uvs.is_empty():
			mat_tex.append(-1)
			continue
		var key := _image_key(img)
		if not tex_of.has(key):
			var t := encode_texture(img, max_tex)
			t["name"] = "tex%d" % texs.size()
			t["src"] = img
			t["max"] = max_tex
			t["ncol"] = 256
			tex_of[key] = texs.size()
			texs.append(t)
		mat_tex.append(tex_of[key])
	_fit_budget(texs)
	for t in texs:
		if t.lossy:
			stats.lossy.append(t.name)
	stats.textures = texs.size()

	# bins of textures
	var order := range(texs.size())
	order.sort_custom(func(a, b): return texs[a].data.size() > texs[b].data.size())
	var bins := [[]]
	var used := [0]
	for ti in order:
		var sz: int = texs[ti].data.size()
		var placed := false
		for b in bins.size():
			if used[b] + sz <= FILE_BUDGET:
				bins[b].append(ti)
				used[b] += sz
				placed = true
				break
		if not placed:
			bins.append([ti])
			used.append(sz)
	if bins.size() > MAX_FILES:
		error = "textures need %d model files, %d at most" % [bins.size(), MAX_FILES]
		return []
	var out := []
	var tex_total := 0
	var pal_total := 0
	for b in bins.size():
		var remap := {}
		var btex := []
		for ti in bins[b]:
			remap[ti] = btex.size()
			btex.append(texs[ti])
		var bsurf := []
		var bmat := []
		for si in surfs.size():
			var ti: int = mat_tex[si]
			if (ti < 0 and b == 0) or remap.has(ti):
				bsurf.append(surfs[si])
				bmat.append(-1 if ti < 0 else remap[ti])
		if bsurf.is_empty():
			continue
		var f := _build_one("%s_%d" % [model_name.left(13), b], bsurf, btex, bmat)
		if f.is_empty():
			return []
		tex_total += stats.tex_bytes
		pal_total += stats.pal_bytes
		out.append(f)
	stats.tex_bytes = tex_total
	stats.pal_bytes = pal_total
	stats.files = out.size()
	return out


## One BMD0 from surfaces and their (already encoded) textures; mat_tex[i] = texture index of surface i or -1.
## Adds to stats (vertices, triangles, size); sets stats.tex_bytes / pal_bytes / pos_scale / bounds for this file.
func _build_one(model_name: String, surfs: Array, texs: Array, mat_tex: Array) -> PackedByteArray:
	if surfs.size() > 255:
		error = "%d surfaces (materials), 255 at most" % surfs.size()
		return PackedByteArray()
	var nv := 0
	var ntri := 0
	# bounds and position scale (VTX_16 is s3.12: |v / pos_scale| < 8)
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for s in surfs:
		for v in s.verts:
			lo = lo.min(v)
			hi = hi.max(v)
	var maxabs := maxf(maxf(maxf(absf(lo.x), absf(hi.x)), maxf(absf(lo.y), absf(hi.y))), maxf(absf(lo.z), absf(hi.z)))
	var pos_scale := 1
	while maxabs / pos_scale >= 7.99:
		pos_scale *= 2
	var size := hi - lo
	var box_scale := 1
	while maxf(maxabs, maxf(size.x, maxf(size.y, size.z))) / box_scale >= 7.99:
		box_scale *= 2

	# shapes
	var shapes := []   # [flag, dl bytes]
	for si in surfs.size():
		var s: Dictionary = surfs[si]
		var ti: int = mat_tex[si]
		var tw := 0
		var th := 0
		if ti >= 0:
			tw = texs[ti].w
			th = texs[ti].h
		var tint: Color = s.get("color", Color.WHITE)
		var has_col: bool = not s.colors.is_empty() or tint != Color.WHITE
		var dl := DL.new()
		dl.add(0x40, [0])
		var last_col := -1
		var last_tc := -1
		var V: PackedVector3Array = s.verts
		var I: PackedInt32Array = s.indices
		var UV: PackedVector2Array = s.uvs
		var C: PackedColorArray = s.colors
		var t := 0
		while t + 2 < I.size():
			var tri := [I[t], I[t + 2], I[t + 1]]   # Godot CW -> DS CCW
			t += 3
			var du := 0.0
			var dv := 0.0
			if ti >= 0:
				du = floorf(minf(UV[tri[0]].x, minf(UV[tri[1]].x, UV[tri[2]].x)))
				dv = floorf(minf(UV[tri[0]].y, minf(UV[tri[1]].y, UV[tri[2]].y)))
			for vi in tri:
				if has_col:
					var c: Color = (C[vi] if not C.is_empty() else Color.WHITE) * tint
					var c5 := clampi(int(round(c.r * 31)), 0, 31) | (clampi(int(round(c.g * 31)), 0, 31) << 5) \
						| (clampi(int(round(c.b * 31)), 0, 31) << 10)
					if c5 != last_col:
						dl.add(0x20, [c5])
						last_col = c5
				if ti >= 0:
					var su := int(round((UV[vi].x - du) * tw * 16.0))
					var sv := int(round((UV[vi].y - dv) * th * 16.0))
					if su > 32767 or sv > 32767:
						stats.uv_clamped += 1
					var tc := (clampi(su, -32768, 32767) & 0xFFFF) | ((clampi(sv, -32768, 32767) & 0xFFFF) << 16)
					if tc != last_tc:
						dl.add(0x22, [tc])
						last_tc = tc
				var p: Vector3 = V[vi] / pos_scale
				dl.add(0x23, [_fx16(p.x) | (_fx16(p.y) << 16), _fx16(p.z)])
				nv += 1
			ntri += 1
		dl.add(0x41)
		var flag := (4 if ti >= 0 else 0) | (2 if has_col else 0)
		shapes.append([flag, dl.bytes()])

	# --- model block ---
	var names_mat := []
	var names_shp := []
	for i in surfs.size():
		names_mat.append("mat%d" % i)
		names_shp.append("polygon%d" % i)

	# node info: dict + 1 node
	var node_dict := dict(["root"], 4, [_u32b(0)])
	node_dict.encode_u32(node_dict.size() - 16 - 4, node_dict.size())   # entry 0: node data right after the dict
	var node_info := node_dict.duplicate()
	node_info.append_array(_u32b(NODE_IDENTITY))

	# render commands
	var sbc := PackedByteArray([0x06, 0, 0, 0, 0x02, 0, 1, 0x0B])
	for i in surfs.size():
		sbc.append_array(PackedByteArray([0x04, i, 0x05, i]))
	sbc.append_array(PackedByteArray([0x2B, 0x01]))
	_align(sbc)

	# materials block
	var mats := PackedByteArray()
	var mat_recs := []
	for si in surfs.size():
		var s: Dictionary = surfs[si]
		var ti: int = mat_tex[si]
		var r := PackedByteArray()
		r.resize(0x2C)
		r.encode_u16(2, 0x2C)
		r.encode_u32(4, 0x0000FFFF)   # diffuse white, used as the vertex colour default; ambient 0
		var alpha := clampi(int(round(float(s.get("alpha", 1.0)) * 31)), 0, 31)
		var pa := (POLY_ATTR & ~0x001F0000) | (alpha << 16)
		if s.get("double_sided", false):
			pa |= 0x40
		r.encode_u32(12, pa)
		r.encode_u32(16, POLY_MASK)
		r.encode_u32(20, REPEAT_ST if ti >= 0 else 0)
		r.encode_u32(24, 0xFFFFFFFF)
		r.encode_u16(30, MAT_FLAG)
		if ti >= 0:
			r.encode_u16(32, texs[ti].w)
			r.encode_u16(34, texs[ti].h)
		r.encode_u32(36, 0x1000)
		r.encode_u32(40, 0x1000)
		mat_recs.append(r)
	# tex / palette -> material lists
	var tex_users := []
	for ti in texs.size():
		var u := PackedByteArray()
		for si in surfs.size():
			if mat_tex[si] == ti:
				u.append(si)
		tex_users.append(u)
	var tnames := texs.map(func(x): return x.name)
	var pnames := texs.map(func(x): return x.name + "_pl")
	var mat_dict := dict(names_mat, 4, names_mat.map(func(_x): return _u32b(0)))
	var tex_dict := dict(tnames, 4, tnames.map(func(_x): return _u32b(0)))
	var pal_dict := dict(pnames, 4, pnames.map(func(_x): return _u32b(0)))
	var p_tex := 4 + mat_dict.size()
	var p_pal := p_tex + tex_dict.size()
	var p_lists := p_pal + pal_dict.size()
	var lists := PackedByteArray()
	var list_off := []
	for u in tex_users:
		list_off.append(p_lists + lists.size())
		lists.append_array(u)
	var p_recs := p_lists + 2 * lists.size()
	while p_recs % 4:
		p_recs += 1
	# entries: tex / palette lists point at the same index list (texture i <-> palette i)
	var tex_list_bytes := lists.duplicate()
	for ti in texs.size():
		_set_dict_entry(tex_dict, ti, 4, PackedByteArray([list_off[ti] & 0xFF, list_off[ti] >> 8, tex_users[ti].size(), 0]))
		var po: int = list_off[ti] + lists.size()
		_set_dict_entry(pal_dict, ti, 4, PackedByteArray([po & 0xFF, po >> 8, tex_users[ti].size(), 0]))
	for si in surfs.size():
		_set_dict_entry(mat_dict, si, 4, _u32b(p_recs + 0x2C * si))
	mats.resize(4)
	mats.encode_u16(0, p_tex)
	mats.encode_u16(2, p_pal)
	mats.append_array(mat_dict)
	mats.append_array(tex_dict)
	mats.append_array(pal_dict)
	mats.append_array(tex_list_bytes)
	mats.append_array(lists)
	while mats.size() < p_recs:
		mats.append(0)
	for r in mat_recs:
		mats.append_array(r)

	# shapes block
	var shp_dict := dict(names_shp, 4, names_shp.map(func(_x): return _u32b(0)))
	var shp := shp_dict.duplicate()
	var hdr_at := shp.size()
	var dl_at := hdr_at + 0x10 * shapes.size()
	var dls := PackedByteArray()
	for k in shapes.size():
		_set_dict_entry(shp, k, 4, _u32b(hdr_at + 0x10 * k))
		var h := PackedByteArray()
		h.resize(0x10)
		h.encode_u16(2, 0x10)
		h.encode_u32(4, shapes[k][0])
		h.encode_u32(8, dl_at + dls.size() - (hdr_at + 0x10 * k))
		h.encode_u32(12, shapes[k][1].size())
		shp.append_array(h)
		dls.append_array(shapes[k][1])
		_align(dls)
	shp.append_array(dls)

	# model
	var mdl := PackedByteArray()
	mdl.resize(0x40)
	mdl.append_array(node_info)
	_align(mdl)
	var o_sbc := mdl.size()
	mdl.append_array(sbc)
	var o_mat := mdl.size()
	mdl.append_array(mats)
	_align(mdl)
	var o_shp := mdl.size()
	mdl.append_array(shp)
	_align(mdl)
	mdl.encode_u32(0, mdl.size())
	mdl.encode_u32(4, o_sbc)
	mdl.encode_u32(8, o_mat)
	mdl.encode_u32(12, o_shp)
	mdl.encode_u32(16, mdl.size())   # no envelope matrices
	mdl[0x17] = 1                    # nodes
	mdl[0x18] = surfs.size()         # materials
	mdl[0x19] = surfs.size()         # shapes
	mdl.encode_u32(0x1C, pos_scale << 12)
	mdl.encode_u32(0x20, int(round(4096.0 / pos_scale)))
	mdl.encode_u16(0x24, mini(nv, 0xFFFF))
	mdl.encode_u16(0x26, mini(ntri, 0xFFFF))
	mdl.encode_u16(0x28, mini(ntri, 0xFFFF))
	stats.vertices += nv
	stats.triangles += ntri
	var bl := lo / box_scale
	var bs := size / box_scale
	mdl.encode_u16(0x2C, _fx16(bl.x))
	mdl.encode_u16(0x2E, _fx16(bl.y))
	mdl.encode_u16(0x30, _fx16(bl.z))
	mdl.encode_u16(0x32, _fx16(bs.x))
	mdl.encode_u16(0x34, _fx16(bs.y))
	mdl.encode_u16(0x36, _fx16(bs.z))
	mdl.encode_u32(0x38, box_scale << 12)
	mdl.encode_u32(0x3C, int(round(4096.0 / box_scale)))

	var mdl_dict := dict([model_name.left(16)], 4, [_u32b(0)])
	var mdl0 := PackedByteArray([0x4D, 0x44, 0x4C, 0x30, 0, 0, 0, 0])
	mdl0.append_array(mdl_dict)
	_set_dict_entry(mdl0, 0, 4, _u32b(mdl0.size()), 8)
	mdl0.append_array(mdl)
	_align(mdl0)
	mdl0.encode_u32(4, mdl0.size())

	var tex0 := _tex0(texs)
	var out := PackedByteArray([0x42, 0x4D, 0x44, 0x30, 0xFF, 0xFE, 0x02, 0x00, 0, 0, 0, 0, 0x10, 0x00,
		2 if not tex0.is_empty() else 1, 0x00])
	out.append_array(_u32b(0))
	if not tex0.is_empty():
		out.append_array(_u32b(0))
	var a_mdl := out.size()
	out.append_array(mdl0)
	out.encode_u32(16, a_mdl)
	if not tex0.is_empty():
		out.encode_u32(20, out.size())
		out.append_array(tex0)
	out.encode_u32(8, out.size())
	stats.pos_scale = pos_scale
	stats.bounds = [lo, hi]
	stats.size += out.size()
	return out


## Identity of an image's pixels (the glTF importer makes one Image per material even when they share a file).
static func _image_key(img: Image) -> String:
	return "%dx%d:%d:%d" % [img.get_width(), img.get_height(), img.get_format(), hash(img.get_data())]


## Shrink textures until the scene fits the VRAM budgets: the largest texture is re-encoded at half its size
## (texels), the largest palettes drop to 16 colours (palettes). Sets stats.downscaled / stats.recoloured.
func _fit_budget(texs: Array) -> void:
	stats.downscaled = []
	stats.recoloured = []
	for t in texs:   # one texture must fit one file
		while t.data.size() > FILE_BUDGET and t.max > 8:
			t.max = maxi(8, maxi(t.w, t.h) / 2)
			_reencode(t)
			if not t.name in stats.downscaled:
				stats.downscaled.append(t.name)
	while true:
		var total := 0
		var big := -1
		for i in texs.size():
			total += texs[i].data.size()
			if texs[i].max > 8 and (big < 0 or texs[i].data.size() > texs[big].data.size()):
				big = i
		if total <= TEX_BUDGET or big < 0:
			break
		var t: Dictionary = texs[big]
		t.max = maxi(8, maxi(t.w, t.h) / 2)
		_reencode(t)
		if not t.name in stats.downscaled:
			stats.downscaled.append(t.name)
	while true:
		var total := 0
		var big := -1
		for i in texs.size():
			total += texs[i].palette.size()
			if texs[i].ncol > 16 and (big < 0 or texs[i].palette.size() > texs[big].palette.size()):
				big = i
		if total <= PAL_BUDGET or big < 0:
			break
		texs[big].ncol = 16
		_reencode(texs[big])
		stats.recoloured.append(texs[big].name)


static func _reencode(t: Dictionary) -> void:
	var e := encode_texture(t.src, t.max, t.ncol)
	for k in e:
		t[k] = e[k]


## Overwrite entry i of the dictionary that starts at `at` in `b`.
static func _set_dict_entry(b: PackedByteArray, i: int, entry_size: int, e: PackedByteArray, at := 0) -> void:
	var n := b[at + 1]
	var o := at + 8 + 4 * (n + 1) + 4 + i * entry_size
	for j in entry_size:
		b[o + j] = e[j] if j < e.size() else 0


func _tex0(texs: Array) -> PackedByteArray:
	if texs.is_empty():
		return PackedByteArray()
	var tnames := texs.map(func(x): return x.name)
	var pnames := texs.map(func(x): return x.name + "_pl")
	var tdata := PackedByteArray()
	var pdata := PackedByteArray()
	var tentries := []
	var pentries := []
	for t in texs:
		var param: int = (tdata.size() >> 3) | ((int(log(t.w) / log(2)) - 3) << 20) | ((int(log(t.h) / log(2)) - 3) << 23) \
			| (t.fmt << 26) | ((1 << 29) if t.color0 else 0)
		var e := PackedByteArray()
		e.resize(8)
		e.encode_u32(0, param)
		e.encode_u32(4, t.w | (t.h << 11) | 0x80000000)
		tentries.append(e)
		tdata.append_array(t.data)
		_align(tdata, 8)
		var pe := PackedByteArray()
		pe.resize(4)
		pe.encode_u16(0, pdata.size() >> 3)
		pentries.append(pe)
		pdata.append_array(t.palette)
		_align(pdata, 16)
	stats.tex_bytes = tdata.size()
	stats.pal_bytes = pdata.size()
	var td := dict(tnames, 8, tentries)
	var pd := dict(pnames, 4, pentries)
	var b := PackedByteArray()
	b.resize(0x3C)
	b[0] = 0x54
	b[1] = 0x45
	b[2] = 0x58
	b[3] = 0x30
	var o_td := b.size()
	b.append_array(td)
	var o_pd := b.size()
	b.append_array(pd)
	_align(b, 8)
	var o_tex := b.size()
	b.append_array(tdata)
	var o_end := b.size()
	b.append_array(pdata)
	b.encode_u16(0x0C, tdata.size() >> 3)
	b.encode_u16(0x0E, o_td)
	b.encode_u32(0x14, o_tex)
	b.encode_u16(0x1E, o_td)
	b.encode_u32(0x24, o_end)
	b.encode_u32(0x28, o_end)
	b.encode_u16(0x30, pdata.size() >> 3)
	b.encode_u32(0x34, o_pd)
	b.encode_u32(0x38, o_end)
	_align(b)
	b.encode_u32(4, b.size())
	return b
