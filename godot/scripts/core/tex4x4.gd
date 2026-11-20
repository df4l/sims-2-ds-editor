class_name Tex4x4
extends RefCounted
## 4x4-compressed texture encoder (TEX0 format 5, docs/formats/bmd0.md §6).
## Hardware format (GBATEK, decoder Nsbmd._decode_4x4): per 4x4 block one u32 of 2-bit texels (bit 2 * (4y + x))
## and one u16 index: bits 0..13 = palette offset in 4-byte units from the texture's palette base, bits 14..15 mode:
##   0: c0 c1 c2 transparent   1: c0 c1 (c0+c1)/2 transparent   2: c0 c1 c2 c3   3: c0 c1 (5c0+3c1)/8 (3c0+5c1)/8
## The game's own textures share colour pairs between blocks (e.g. 9 632 blocks on 276 palette slots, mostly
## mode 3), so the encoder builds a codebook of colour PAIRS: every block uses mode 3 (opaque) or mode 1 (some
## transparent texels), and its index is the number of its pair (2 colours = 4 bytes = one index step).
## Steps: best pair per block (principal axis + least squares) -> median cut of those pairs (6-D) into at most
## max_pairs boxes -> least-squares refit of each box's pair over all its pixels -> a few passes of "each block
## picks the best of its nearest pairs, pairs refitted".

const W3 := [[1.0, 0.0], [0.0, 1.0], [0.625, 0.375], [0.375, 0.625]]   # mode 3: weights of (c0, c1) per texel
const W1 := [[1.0, 0.0], [0.0, 1.0], [0.5, 0.5]]                       # mode 1 (texel 3 = transparent)
const CANDIDATES := 6   # nearest pairs (endpoint distance) tried exactly per block in a refinement pass
const PASSES := 2


## img: RGBA8, width and height multiples of 4. Returns {data (texels), idx (indices), palette (RGB555 bytes),
## pairs, err (mean squared error per opaque texel, 5-bit units)}.
static func encode(img: Image, max_pairs := 1024) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var src := img.get_data()
	var nbx := w / 4
	var nb := nbx * (h / 4)
	# per block: 16 texels × rgb (5-bit floats), opacity mask
	var px := PackedFloat32Array()
	px.resize(nb * 48)
	var mask := PackedInt32Array()
	mask.resize(nb)
	for b in nb:
		var bx := (b % nbx) * 4
		var by := (b / nbx) * 4
		var m := 0
		for t in 16:
			var o := 4 * ((by + (t >> 2)) * w + bx + (t & 3))
			if src[o + 3] >= 128:
				m |= 1 << t
			px[48 * b + 3 * t] = src[o] * 31.0 / 255.0
			px[48 * b + 3 * t + 1] = src[o + 1] * 31.0 / 255.0
			px[48 * b + 3 * t + 2] = src[o + 2] * 31.0 / 255.0
		mask[b] = m
	# 1. best pair per block (6 floats: c0, c1), blocks with no opaque texel take no part
	var ideal := PackedFloat32Array()
	ideal.resize(nb * 6)
	var live := []
	for b in nb:
		if mask[b] == 0:
			continue
		live.append(b)
		var p := _fit_block(px, b, mask[b])
		for k in 6:
			ideal[6 * b + k] = p[k]
	# 2. codebook: exact when few distinct (quantised) pairs, else median cut
	var boxes := []
	var seen := {}
	for b in live:
		var key := _qkey(ideal, 6 * b)
		if not seen.has(key):
			seen[key] = boxes.size()
			boxes.append([])
		boxes[seen[key]].append(b)
	if boxes.size() > max_pairs:
		boxes = _median_cut(ideal, live, maxi(1, max_pairs))
	var pairs := PackedFloat32Array()
	pairs.resize(maxi(1, boxes.size()) * 6)
	var assign := PackedInt32Array()
	assign.resize(nb)
	for i in boxes.size():
		for b in boxes[i]:
			assign[b] = i
		var q := _refit(px, mask, boxes[i], _mean_pair(ideal, boxes[i]))
		for k in 6:
			pairs[6 * i + k] = q[k]
	_quantise(pairs)
	# 3. refinement: blocks pick the best of their nearest pairs, pairs refitted to their blocks
	var npairs := pairs.size() / 6
	if npairs > 1:
		for pass_i in PASSES:
			for b in live:
				var best: int = assign[b]
				var best_e := _block_err(px, b, mask[b], pairs, best)
				for c in _nearest(ideal, 6 * b, pairs, CANDIDATES):
					if c == best:
						continue
					var e := _block_err(px, b, mask[b], pairs, c)
					if e < best_e:
						best_e = e
						best = c
				assign[b] = best
			var members := []
			members.resize(npairs)
			for i in npairs:
				members[i] = []
			for b in live:
				members[assign[b]].append(b)
			for i in npairs:
				if members[i].is_empty():
					continue
				var start := PackedFloat32Array(pairs.slice(6 * i, 6 * i + 6))
				var q := _refit(px, mask, members[i], start)
				for k in 6:
					pairs[6 * i + k] = q[k]
			_quantise(pairs)
	# 4. output: texels, indices, palette
	var data := PackedByteArray()
	data.resize(4 * nb)
	var idx := PackedByteArray()
	idx.resize(2 * nb)
	var err := 0.0
	var nop := 0
	for b in nb:
		var m := mask[b]
		var mode := 3 if m == 0xFFFF else 1
		var pi: int = assign[b] if m != 0 else 0
		var cols := _colors(pairs, pi, mode)
		var word := 0
		for t in 16:
			var ti := 3
			if m & (1 << t):
				var r := _nearest_col(px, 48 * b + 3 * t, cols)
				ti = r[0]
				err += r[1]
				nop += 1
			word |= ti << (2 * t)
		data.encode_u32(4 * b, word)
		idx.encode_u16(2 * b, pi | (mode << 14))
	var pal := PackedByteArray()
	pal.resize(4 * npairs)
	for i in npairs:
		pal.encode_u16(4 * i, _c555(pairs, 6 * i))
		pal.encode_u16(4 * i + 2, _c555(pairs, 6 * i + 3))
	return {"data": data, "idx": idx, "palette": pal, "pairs": npairs, "err": err / maxi(1, nop)}


static func _c555(p: PackedFloat32Array, o: int) -> int:
	return int(p[o]) | (int(p[o + 1]) << 5) | (int(p[o + 2]) << 10)


static func _qkey(p: PackedFloat32Array, o: int) -> int:
	var k := 0
	for i in 6:
		k = (k << 5) | clampi(int(round(p[o + i])), 0, 31)
	return k


static func _quantise(p: PackedFloat32Array) -> void:
	for i in p.size():
		p[i] = clampf(round(p[i]), 0.0, 31.0)


## Best (c0, c1) of one block: principal axis of its opaque texels, extremes, then least squares (mode 3 or 1).
static func _fit_block(px: PackedFloat32Array, b: int, m: int) -> PackedFloat32Array:
	var n := 0.0
	var mean := Vector3.ZERO
	for t in 16:
		if m & (1 << t):
			mean += Vector3(px[48 * b + 3 * t], px[48 * b + 3 * t + 1], px[48 * b + 3 * t + 2])
			n += 1.0
	mean /= n
	var cxx := 0.0
	var cxy := 0.0
	var cxz := 0.0
	var cyy := 0.0
	var cyz := 0.0
	var czz := 0.0
	for t in 16:
		if m & (1 << t):
			var d := Vector3(px[48 * b + 3 * t], px[48 * b + 3 * t + 1], px[48 * b + 3 * t + 2]) - mean
			cxx += d.x * d.x
			cxy += d.x * d.y
			cxz += d.x * d.z
			cyy += d.y * d.y
			cyz += d.y * d.z
			czz += d.z * d.z
	var axis := Vector3(1, 1, 1)
	for it in 4:
		axis = Vector3(cxx * axis.x + cxy * axis.y + cxz * axis.z, cxy * axis.x + cyy * axis.y + cyz * axis.z,
			cxz * axis.x + cyz * axis.y + czz * axis.z)
		var l := axis.length()
		if l < 1e-6:
			axis = Vector3.ZERO
			break
		axis /= l
	var lo := 0.0
	var hi := 0.0
	for t in 16:
		if m & (1 << t):
			var d := (Vector3(px[48 * b + 3 * t], px[48 * b + 3 * t + 1], px[48 * b + 3 * t + 2]) - mean).dot(axis)
			lo = minf(lo, d)
			hi = maxf(hi, d)
	var c0 := mean + axis * lo
	var c1 := mean + axis * hi
	var p := PackedFloat32Array([c0.x, c0.y, c0.z, c1.x, c1.y, c1.z])
	if hi - lo > 0.5:
		p = _refit(px, PackedInt32Array([m]), [b], p, true)
	_canon(p)
	return p


## Darker endpoint first, so that the median cut and the distances see one orientation per pair.
static func _canon(p: PackedFloat32Array) -> void:
	if p[0] + p[1] + p[2] > p[3] + p[4] + p[5]:
		for k in 3:
			var t := p[k]
			p[k] = p[k + 3]
			p[k + 3] = t


static func _mean_pair(ideal: PackedFloat32Array, blocks: Array) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(6)
	for b in blocks:
		for k in 6:
			p[k] += ideal[6 * b + k]
	for k in 6:
		p[k] /= blocks.size()
	return p


## Least-squares (c0, c1) over every opaque texel of the blocks, each texel weighted by its nearest palette entry
## under the current pair (2 rounds). mask_one: mask holds only blocks[0]'s mask.
static func _refit(px: PackedFloat32Array, mask: PackedInt32Array, blocks: Array, start: PackedFloat32Array,
		mask_one := false) -> PackedFloat32Array:
	var p := start.duplicate()
	for rnd in 2:
		var aa := 0.0
		var ab := 0.0
		var bb := 0.0
		var ax := Vector3.ZERO
		var bx := Vector3.ZERO
		var sum := Vector3.ZERO
		var n := 0.0
		for b in blocks:
			var m: int = mask[0] if mask_one else mask[b]
			var mode := 3 if m == 0xFFFF else 1
			var cols := _colors(p, 0, mode)
			var wt: Array = W3 if mode == 3 else W1
			for t in 16:
				if not m & (1 << t):
					continue
				var o: int = 48 * b + 3 * t
				var r := _nearest_col(px, o, cols)
				var wa: float = wt[r[0]][0]
				var wb: float = wt[r[0]][1]
				var x := Vector3(px[o], px[o + 1], px[o + 2])
				aa += wa * wa
				ab += wa * wb
				bb += wb * wb
				ax += x * wa
				bx += x * wb
				sum += x
				n += 1.0
		var det := aa * bb - ab * ab
		if n == 0.0:
			break
		if absf(det) < 1e-6:
			var mu := sum / n
			p = PackedFloat32Array([mu.x, mu.y, mu.z, mu.x, mu.y, mu.z])
			break
		var c0 := (ax * bb - bx * ab) / det
		var c1 := (bx * aa - ax * ab) / det
		p = PackedFloat32Array([clampf(c0.x, 0, 31), clampf(c0.y, 0, 31), clampf(c0.z, 0, 31),
			clampf(c1.x, 0, 31), clampf(c1.y, 0, 31), clampf(c1.z, 0, 31)])
	return p


## Palette of pair i (starts at 6 i in p) in a mode: flat [r, g, b, r, g, b, ...] (3 or 4 colours).
static func _colors(p: PackedFloat32Array, i: int, mode: int) -> PackedFloat32Array:
	var o := 6 * i
	var c := PackedFloat32Array()
	var wt: Array = W3 if mode == 3 else W1
	for wv in wt:
		for k in 3:
			c.append(p[o + k] * wv[0] + p[o + 3 + k] * wv[1])
	return c


## [index, squared distance] of the nearest colour of cols to texel px[o..o+2].
static func _nearest_col(px: PackedFloat32Array, o: int, cols: PackedFloat32Array) -> Array:
	var best := 0
	var be := INF
	for j in cols.size() / 3:
		var dr := px[o] - cols[3 * j]
		var dg := px[o + 1] - cols[3 * j + 1]
		var db := px[o + 2] - cols[3 * j + 2]
		var e := dr * dr + dg * dg + db * db
		if e < be:
			be = e
			best = j
	return [best, be]


static func _block_err(px: PackedFloat32Array, b: int, m: int, pairs: PackedFloat32Array, i: int) -> float:
	var cols := _colors(pairs, i, 3 if m == 0xFFFF else 1)
	var e := 0.0
	for t in 16:
		if m & (1 << t):
			e += _nearest_col(px, 48 * b + 3 * t, cols)[1]
	return e


## The k pairs nearest to ideal[o..o+5] (endpoint distance, both orientations).
static func _nearest(ideal: PackedFloat32Array, o: int, pairs: PackedFloat32Array, k: int) -> Array:
	var best := []   # [dist, index], sorted
	var a0 := ideal[o]
	var a1 := ideal[o + 1]
	var a2 := ideal[o + 2]
	var a3 := ideal[o + 3]
	var a4 := ideal[o + 4]
	var a5 := ideal[o + 5]
	var worst := INF
	for i in pairs.size() / 6:
		var q := 6 * i
		var d0 := a0 - pairs[q]
		var d1 := a1 - pairs[q + 1]
		var d2 := a2 - pairs[q + 2]
		var d3 := a3 - pairs[q + 3]
		var d4 := a4 - pairs[q + 4]
		var d5 := a5 - pairs[q + 5]
		var d := d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3 + d4 * d4 + d5 * d5
		d0 = a0 - pairs[q + 3]
		d1 = a1 - pairs[q + 4]
		d2 = a2 - pairs[q + 5]
		d3 = a3 - pairs[q]
		d4 = a4 - pairs[q + 1]
		d5 = a5 - pairs[q + 2]
		d = minf(d, d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3 + d4 * d4 + d5 * d5)
		if best.size() < k or d < worst:
			var at := best.size()
			while at > 0 and best[at - 1][0] > d:
				at -= 1
			best.insert(at, [d, i])
			if best.size() > k:
				best.pop_back()
			worst = best[-1][0]
	return best.map(func(x): return x[1])


## Median cut of the blocks' pairs (6-D) into at most n boxes (arrays of block numbers): split the box with the
## largest (range × blocks) at the median of that dimension.
static func _median_cut(ideal: PackedFloat32Array, blocks: Array, n: int) -> Array:
	var boxes := [blocks.duplicate()]
	var info := [_box_info(ideal, boxes[0])]
	while boxes.size() < n:
		var bi := -1
		var bs := 0.0
		for i in boxes.size():
			var s: float = info[i][1] * boxes[i].size()
			if boxes[i].size() > 1 and s > bs:
				bs = s
				bi = i
		if bi < 0:
			break
		var dim: int = info[bi][0]
		var box: Array = boxes[bi]
		box.sort_custom(func(a, b): return ideal[6 * a + dim] < ideal[6 * b + dim])
		var half := box.size() / 2
		var lo := box.slice(0, half)
		var hi := box.slice(half)
		boxes[bi] = lo
		info[bi] = _box_info(ideal, lo)
		boxes.append(hi)
		info.append(_box_info(ideal, hi))
	return boxes


## [dimension of the largest range, that range].
static func _box_info(ideal: PackedFloat32Array, box: Array) -> Array:
	var lo := PackedFloat32Array([INF, INF, INF, INF, INF, INF])
	var hi := PackedFloat32Array([-INF, -INF, -INF, -INF, -INF, -INF])
	for b in box:
		for k in 6:
			lo[k] = minf(lo[k], ideal[6 * b + k])
			hi[k] = maxf(hi[k], ideal[6 * b + k])
	var dim := 0
	for k in 6:
		if hi[k] - lo[k] > hi[dim] - lo[dim]:
			dim = k
	return [dim, hi[dim] - lo[dim]]
