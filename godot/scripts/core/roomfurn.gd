class_name RoomFurn
extends RefCounted
## Hotel room default furniture (docs/formats/roomfurn.md): arm9 default lists, room grid files and the
## grid -> world placement of Room_PlacePropOnGrid 0x020c1eb4.

const ROOM_LOCS := 0x0211F9D4      # u32[6] location ids, index = room slot
const DEFAULTS := 0x0211FA70       # [6 slots][6 entries] {u8 prop, u8 x, u8 z, u8 rot}
const GRID_ENTRIES := 0x02127754   # u16[6] rom.bin entry of the room grid
const JUMP_TABLE := 0x02011E2C     # Prop_CreatePlacementObject
const LOAD_TEX := 0x020bd908
const N_SLOTS := 6
const N_DEFAULT := 6
const CELL := 2.0

const FLOOR_PROPS := [[6, 8], [36, 36], [57, 61], [64, 67], [70, 70], [92, 93], [95, 100], [102, 159], [164, 184]]
const WALL_PROPS := [[9, 11], [62, 63], [68, 69], [83, 91], [94, 94], [101, 101], [160, 160], [162, 163], [185, 244]]
const NODE_KINDS := {0: [28, 18], 3: [32, 22], 4: [48, 38], 5: [36, 26]}

var gd: GameData
var _prop_tex := {}
var _placement := {}


func _init(g: GameData) -> void:
	gd = g


static func _in(ranges: Array, p: int) -> bool:
	for r in ranges:
		if p >= r[0] and p <= r[1]:
			return true
	return false


static func is_furniture(prop: int) -> bool:
	return _in(FLOOR_PROPS, prop) or _in(WALL_PROPS, prop)


static func is_wall(prop: int) -> bool:
	return _in(WALL_PROPS, prop)


func room_locations() -> Array:
	var out := []
	for i in N_SLOTS:
		out.append(gd.u32(ROOM_LOCS + 4 * i))
	return out


func grid_entries() -> Array:
	var out := []
	for i in N_SLOTS:
		out.append(gd.u16(GRID_ENTRIES + 2 * i))
	return out


func slot_of(loc: int) -> int:
	return room_locations().find(loc)


## Original 24-byte default list of a slot (from the ROM's arm9).
func defaults_bytes(slot: int) -> PackedByteArray:
	var o := DEFAULTS - GameData.BASE + 24 * slot
	return gd.a9.slice(o, o + 24)


class Grid:
	var raw: PackedByteArray
	var cells_size := 0
	var origin := Vector2.ZERO
	var width := 0
	var depth := 0
	var n_heights := 0
	var heights := []
	var cells_at := 0
	var walls_at := 0
	var n_walls := 0

	func _init(r: PackedByteArray) -> void:
		raw = r
		if r.size() < 0x1C:
			return
		cells_size = r.decode_u32(0)
		origin = Vector2(r.decode_s32(4) / 4096.0, r.decode_s32(8) / 4096.0)
		width = r.decode_u16(12)
		depth = r.decode_u16(14)
		n_heights = r[0x14]
		n_walls = r[0x15]
		for k in n_heights:
			heights.append(r.decode_s32(0x1C + 4 * k) / 4096.0)
		cells_at = 0x1C + 4 * n_heights
		walls_at = cells_at + cells_size

	func cell(x: int, z: int) -> int:
		return raw[cells_at + z * width + x]

	## [pos (float), orient, height index]
	func wall(i: int) -> Array:
		var o := walls_at + 8 * i
		return [raw.decode_s32(o) / 4096.0, raw[o + 4], raw[o + 5]]


func grid(slot: int) -> Grid:
	return Grid.new(gd.rombin.raw_entry(grid_entries()[slot]))


static func _fx(v: int, s: int) -> int:
	return (v * s + 0x800) >> 12


## [box_x, box_z, box_w, box_d, scale] of the prop model, raw fx (BMD0 model +0x2C..+0x38).
func model_box_fx(prop: int) -> Array:
	var d := gd.rombin.data(gd.prop_model(prop))
	if d.size() < 16 or d.slice(0, 4).get_string_from_ascii() != "BMD0":
		return [0, 0, 0, 0, 4096]
	var bo := -1
	for k in d.decode_u16(14):
		var o := d.decode_u32(16 + 4 * k)
		if d.slice(o, o + 4).get_string_from_ascii() == "MDL0":
			bo = o
			break
	if bo < 0:
		return [0, 0, 0, 0, 4096]
	var o := bo + 8
	var p := o + 8 + (d[o + 1] + 1) * 4
	var m := bo + d.decode_u32(p + 4)
	return [d.decode_s16(m + 0x2C), d.decode_s16(m + 0x30), d.decode_s16(m + 0x32), d.decode_s16(m + 0x36),
		d.decode_s32(m + 0x38)]


func model_box(prop: int) -> Vector2:
	var b := model_box_fx(prop)
	return Vector2(_fx(absi(b[0]), b[4]) / 4096.0, _fx(absi(b[1]), b[4]) / 4096.0)


## Frame-0 nodes of a node file: [[kind, id, x, y, z, class]] (fx32), [] on error.
static func read_nodes(raw: PackedByteArray) -> Array:
	if raw.size() < 4:
		return []
	var nf := raw[1]
	var n := raw.decode_u16(2)
	var o := 4
	var out := []
	for _k in n:
		if o + 4 > raw.size():
			return []
		var kind := raw.decode_u16(o)
		var nid := raw.decode_u16(o + 2)
		o += 4
		if not NODE_KINDS.has(kind):
			return []
		var size: int = NODE_KINDS[kind][0]
		var co: int = NODE_KINDS[kind][1]
		if o + co + 2 > raw.size():
			return []
		out.append([kind, nid, raw.decode_s32(o), raw.decode_s32(o + 4), raw.decode_s32(o + 8), raw.decode_u16(o + co)])
		o += size * nf
	return out


func node_file(prop: int) -> int:
	var rec := GameData.PROP_MODELS + 8 * prop
	var lst := gd.u32(rec)
	var cnt := gd.u16(rec + 6)
	return gd.u16(lst + 4) if cnt and lst else -1


## [wall (0/1), off_x, off_z] of the prop's placement object, [] if the prop is not furniture.
func placement(prop: int) -> Array:
	if _placement.has(prop):
		return _placement[prop]
	var res := []
	if is_furniture(prop):
		var b := model_box_fx(prop)
		var ax := 0
		var az := 0
		var nf := node_file(prop)
		if nf >= 0:
			for n in read_nodes(gd.rombin.data(nf)):
				if n[5] == 2:
					ax = n[2]
					az = n[4]
					break
		var ix := _fx(b[2], b[4]) - _fx(absi(b[0]), b[4]) + ax
		var iz := _fx(b[3], b[4]) - _fx(absi(b[1]), b[4]) + az
		res = [1 if is_wall(prop) else 0, maxi(0, -ix) / 4096.0, maxi(0, -iz) / 4096.0]
	_placement[prop] = res
	return res


## World placement of a room entry: {pos: Vector3, angle: float, exact: bool} or {} (wall slot out of range).
func place(g: Grid, prop: int, x: int, z: int, rot: int) -> Dictionary:
	var pl := placement(prop)
	var wall: int = pl[0] if not pl.is_empty() else 0
	var off_x: float = pl[1] if not pl.is_empty() else 0.0
	var off_z: float = pl[2] if not pl.is_empty() else 0.0
	var bx := model_box(prop)
	var ox := g.origin.x
	var oz := g.origin.y
	if wall:
		if x >= g.n_walls:
			return {}
		var w := g.wall(x)
		var a: float = w[1] * PI / 2
		var along := (z + 1) * CELL + bx.x
		var X: float
		var Z: float
		if w[1] & 1 == 0:
			X = ox + along
			Z = w[0]
		else:
			X = w[0]
			Z = oz + along
		X -= 0.5 * sin(a)
		Z -= 0.5 * cos(a)
		var Y: float = g.heights[w[2]] if w[2] < g.n_heights else 0.0
		return {"pos": Vector3(X, Y, Z), "angle": a, "exact": not pl.is_empty()}
	var ex := bx.x
	var ez := bx.y
	if rot & 1:
		var t := ex
		ex = ez
		ez = t
		t = off_x
		off_x = off_z
		off_z = t
	if rot >= 2:
		off_x = maxf(0.0, -off_x)
		off_z = maxf(0.0, -off_z)
	var X2 := ox + (x + 1) * CELL + ex + off_x
	var Z2 := oz + (z + 1) * CELL + ez + off_z
	var c := g.cell(x, z) if x < g.width and z < g.depth else 0xFF
	var Y2: float = g.heights[c] if c < g.n_heights else 0.0
	return {"pos": Vector3(X2, Y2, Z2), "angle": rot * PI / 2, "exact": not pl.is_empty()}


# --- prop variant textures (Prop_CreatePlacementObject case -> Gfx_LoadTexPal256) ---------------------------------

func _w(ad: int) -> int:
	var o := ad - GameData.BASE
	return gd.a9.decode_u32(o) if o >= 0 and o + 4 <= gd.a9.size() else 0


static func _rel(ad: int, i: int) -> int:
	var off := i & 0xFFFFFF
	if off & 0x800000:
		off -= 1 << 24
	return ad + 8 + 4 * off


static func _imm(i: int) -> int:
	var r := ((i >> 8) & 15) * 2
	var v := i & 0xFF
	return ((v >> r) | (v << (32 - r))) & 0xFFFFFFFF


func _prop_texture_case(prop: int) -> int:
	var ad := _rel(JUMP_TABLE + 4 * prop, _w(JUMP_TABLE + 4 * prop))
	var regs := {}
	for _k in 120:
		var i := _w(ad)
		var rd := (i >> 12) & 15
		var rn := (i >> 16) & 15
		var rm := i & 15
		if i & 0xFF7F0000 == 0xE51F0000:   # ldr rd,[pc,#+-imm]
			var off := (i & 0xFFF) if i & 0x800000 else -(i & 0xFFF)
			regs[rd] = ["lit", _w(ad + 8 + off)]
		elif i & 0xFFFF0FFF == 0xE1D500BA:   # ldrh rd,[r5,#0xa] (prop id)
			regs[rd] = ["prop", 0]
		elif i & 0xFFF00000 == 0xE2400000 and regs.get(rn, [""])[0] == "prop":   # sub rd,rn,#imm
			regs[rd] = ["prop", _imm(i)]
		elif i & 0xFFF000F0 == 0xE19000B0:   # ldrh rd,[rn,rm]
			var t: Array = regs.get(rn, [""])
			var p: Array = regs.get(rm, [""])
			regs[rd] = ["entry", t[1], p[1]] if t[0] == "lit" and p[0] == "prop" else [""]
		elif i & 0xFFF00FF0 == 0xE1A00080 and regs.get(rm, [""])[0] == "prop":   # mov rd,rm lsl #1
			regs[rd] = regs[rm]
		elif i >> 24 == 0xEB:   # bl
			if _rel(ad, i) == LOAD_TEX:
				var r1: Array = regs.get(1, [""])
				if r1[0] == "entry":
					return gd.u16(r1[1] + 2 * (prop - r1[2]))
				if r1[0] == "lit" and r1[1] < 0x10000:
					return r1[1]
				return -1
			var keep := {}
			for k in regs:
				if k > 3:
					keep[k] = regs[k]
			regs = keep
		elif i >> 24 == 0xEA:   # b
			ad = _rel(ad, i)
			continue
		elif i == 0xE12FFF1E:   # bx lr
			return -1
		ad += 4
	return -1


## rom.bin entry of the variant texture (512-byte palette + 8bpp texels) put on the prop's model, or -1.
func prop_texture(prop: int) -> int:
	if prop < 0 or prop >= GameData.N_PROPS:
		return -1
	if not _prop_tex.has(prop):
		_prop_tex[prop] = _prop_texture_case(prop)
	return _prop_tex[prop]


## Default furniture of a room as dicts {index, prop, x, z, rot, wall, pos, angle, exact, placed, along}.
func room_items(slot: int, list: PackedByteArray) -> Array:
	var g := grid(slot)
	var out := []
	for i in N_DEFAULT:
		var prop := list[4 * i]
		var x := list[4 * i + 1]
		var z := list[4 * i + 2]
		var rot := list[4 * i + 3]
		var r := place(g, prop, x, z, rot)
		var pl := placement(prop)
		var wall: bool = not pl.is_empty() and pl[0] == 1
		var along = null
		if wall and not r.is_empty():
			along = "z" if g.wall(x)[1] & 1 else "x"
		out.append({"index": i, "prop": prop, "x": x, "z": z, "rot": rot, "wall": wall,
			"pos": r.get("pos"), "angle": r.get("angle", 0.0), "exact": r.get("exact", false),
			"placed": not r.is_empty(), "along": along})
	return out
