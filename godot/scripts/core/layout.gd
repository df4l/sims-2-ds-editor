class_name Layout
extends RefCounted
## Location layout file (docs/formats/layout.md), read by Map_LoadNav 0x02053128 / Map_ParseNavBlock 0x020528c0.
## File:  u8 n_blocks, u8 n_entries, u16 entries_size (= 16 * n_entries), entry[n_entries], block[n_blocks]
## Block: u16 size, u8 n_groups, u8 n_scripts, u8 n_c4, u8 n_c5, u8 n_c6, u8 pad,
##        u16 off_scripts, off_c4, off_c5, off_c6 (relative to block + 0x10), groups, script area, tables (raw)
## Group: u16 size, u8 items_offset (= 4 + n + pad), u8 n, u8 item_size[n], pad to 4, items
## Item:  s16 x, y, z, u8 type, u8 ?, type-specific payload

const ITEM_SIZE := {0: 12, 1: 16, 2: 16, 3: 16, 4: 24, 5: 16, 7: 12, 8: 12, 9: 20, 10: 12, 11: 12}
const ITEM_NAME := {0: "none", 1: "npc", 2: "prop", 3: "box13", 4: "object_box", 5: "zone5", 7: "box", 8: "unk8",
	9: "waypoint", 10: "timed_prop", 11: "sound"}
const TYPE_LABEL := {1: "npc", 2: "prop", 3: "trigger box", 4: "door / object box", 5: "light?", 7: "box",
	8: "event watcher", 9: "waypoint", 10: "timed prop", 11: "sound"}
const TIMED_PROP_BIAS := 0x47

# Editable fields per type, as read by Nav_SpawnEntity / Nav_AddWaypoint: [name, offset, fmt, min, max, bias].
# Stored value = value - bias. Bytes not listed are never read by the constructors.
static var FIELDS := {
	1: [["angle_deg", 8, "h", -360, 360, 0], ["npc", 0xE, "B", 0, GameData.N_NPCS - 1, 0]],
	2: [["angle_deg", 8, "h", -360, 360, 0], ["prop", 0xE, "B", 0, 255, 0]],
	3: [["size_x", 9, "B", 0, 255, 0], ["size_y", 0xA, "B", 0, 255, 0], ["size_z", 0xB, "B", 0, 255, 0],
		["repeat", 8, "B", 0, 255, 0], ["group", 0xC, "B", 0, 255, 0], ["script", 0xD, "B", 0, 255, 0]],
	4: [["angle_deg", 8, "h", -360, 360, 0], ["size_x", 0xF, "B", 0, 255, 0], ["size_y", 0x10, "B", 0, 255, 0],
		["size_z", 0x11, "B", 0, 255, 0], ["dest", 0xE, "B", 0, 255, 0], ["entry", 0x12, "B", 0, 255, 0],
		["object", 0x13, "B", 0, GameData.N_OBJECTS, 0]],
	5: [["radius", 8, "H", 0, 0xFFFF, 0], ["r", 0xB, "B", 0, 31, 0], ["g", 0xC, "B", 0, 31, 0], ["b", 0xD, "B", 0, 31, 0]],
	7: [["kind", 8, "B", 0, 255, 0], ["size_x", 9, "B", 0, 255, 0], ["size_y", 0xA, "B", 0, 255, 0],
		["size_z", 0xB, "B", 0, 255, 0]],
	8: [["arg8", 8, "B", 0, 255, 0], ["mode", 9, "B", 0, 255, 0], ["argA", 0xA, "B", 0, 255, 0]],
	9: [["radius", 8, "B", 0, 255, 0], ["link1", 0xA, "B", 0, 255, 0], ["link2", 0xC, "B", 0, 255, 0],
		["link3", 0xE, "B", 0, 255, 0], ["link4", 0x10, "B", 0, 255, 0]],
	10: [["prop", 8, "B", TIMED_PROP_BIAS, TIMED_PROP_BIAS + 255, TIMED_PROP_BIAS], ["hour_slot", 9, "B", 0, 2, 0],
		["value", 0xA, "B", 0, 255, 0], ["collect_bit", 0xB, "B", 0, 63, 0]],
	11: [["sound_slot", 8, "B", 0, 255, 0]],
}
# New item templates: the most common value of each byte over the 1290 items of the 32 files
static var TEMPLATE := {
	1: {}, 2: {}, 3: {"size_x": 20, "size_y": 20, "size_z": 20},
	4: {"size_x": 15, "size_y": 2, "size_z": 15, "dest": 5, "object": GameData.N_OBJECTS},
	5: {"radius": 13, "r": 31, "g": 31, "b": 31}, 7: {"size_x": 15, "size_z": 30},
	8: {"mode": 1, "raw": {0xB: 1}}, 9: {"radius": 8}, 10: {"prop": TIMED_PROP_BIAS}, 11: {"sound_slot": 29},
}

const ARENA := 0x800          # Map_LoadNav parse arena
const MAX_WAYPOINTS := 32     # Nav_AddWaypoint list at world+0x6C

var entries := []   # PackedByteArray(16) each
var blocks := []    # Block
var error := ""
var write_error := ""   # set by write() when a block outgrows its u16 size / offsets


class Item:
	var raw: PackedByteArray

	func _init(r: PackedByteArray) -> void:
		raw = r

	var x: int:
		get: return raw.decode_s16(0)
	var y: int:
		get: return raw.decode_s16(2)
	var z: int:
		get: return raw.decode_s16(4)
	var type: int:
		get: return raw[6]

	func set_pos(px: int, py: int, pz: int) -> void:
		raw.encode_s16(0, px)
		raw.encode_s16(2, py)
		raw.encode_s16(4, pz)

	func copy() -> Item:
		return Item.new(raw.duplicate())

	func spec(name: String) -> Array:
		for f in Layout.FIELDS.get(type, []):
			if f[0] == name:
				return f
		return []

	func has_field(name: String) -> bool:
		return not spec(name).is_empty()

	func get_field(name: String) -> int:
		var f := spec(name)
		if f.is_empty():
			return 0
		var v := 0
		match f[2]:
			"h": v = raw.decode_s16(f[1])
			"H": v = raw.decode_u16(f[1])
			_: v = raw[f[1]]
		return v + f[5]

	## "" on success, else the error.
	func set_field(name: String, v: int) -> String:
		var f := spec(name)
		if f.is_empty():
			return "type %d has no field %s" % [type, name]
		if v < f[3] or v > f[4]:
			return "%s %s must be an integer in %d..%d, not %d" % [Layout.ITEM_NAME.get(type, type), name, f[3], f[4], v]
		var s: int = v - f[5]
		match f[2]:
			"h": raw.encode_s16(f[1], s)
			"H": raw.encode_u16(f[1], s)
			_: raw[f[1]] = s
		return ""

	func typed() -> Dictionary:
		var out := {}
		for f in Layout.FIELDS.get(type, []):
			out[f[0]] = get_field(f[0])
		return out

	func angle_deg():
		return raw.decode_s16(8) if type in [1, 2, 4] else null

	## Half size of the box types (3, 4, 7) or null.
	func half_size():
		match type:
			3, 7: return Vector3(raw[9] / 2.0, raw[10] / 2.0, raw[11] / 2.0)
			4: return Vector3(raw[0xF] / 2.0, raw[0x10] / 2.0, raw[0x11] / 2.0)
		return null

	## Readable fields (as tools/layout.py Item.fields).
	func fields() -> Dictionary:
		var r := raw
		match type:
			1, 2: return {"angle_deg": r.decode_s16(8), "id": r[0xE]}
			3: return {"half_size": half_size(), "repeat": r[8], "group": r[0xC], "script": r[0xD]}
			4: return {"angle_deg": r.decode_s16(8), "dest": r[0xE], "half_size": half_size(), "entry": r[0x12],
				"object": null if r[0x13] == 0x1E else r[0x13]}
			5: return {"size": [r[0xB], r[0xC], r[0xD]], "radius": r.decode_u16(8)}
			7: return {"kind": r[8], "half_size": half_size()}
			8: return {"a": r[8], "b": r[9], "c": r[10]}
			9: return {"radius": r[8], "links": [r[10], r[12], r[14], r[16]]}
			10: return {"prop": r[8] + 0x47, "hour_slot": r[9], "value": r[10], "flag": r[11]}
			11: return {"sound_slot": r[8]}
		return {}


class Group:
	var b2 := 0
	var items := []


class Block:
	var counts := [0, 0, 0, 0]    # n_scripts, n_c4, n_c5, n_c6
	var pad := 0
	var offs := [0, 0, 0, 0]
	var groups := []
	var scripts := []              # script = Array of [opcode, PackedByteArray args]
	var tables := PackedByteArray()
	var tables_at := 0


static func new_item(t: int, x := 0, y := 0, z := 0) -> Item:
	var r := PackedByteArray()
	r.resize(ITEM_SIZE[t])
	var it := Item.new(r)
	r[6] = t
	it.set_pos(x, y, z)
	var tpl: Dictionary = TEMPLATE.get(t, {})
	for o in tpl.get("raw", {}):
		it.raw[o] = tpl.raw[o]
	for k in tpl:
		if k != "raw":
			it.set_field(k, tpl[k])
	return it


func duplicate_layout() -> Layout:
	var l := Layout.parse(write(), arg_size_ref)
	return l


var arg_size_ref := PackedByteArray()


## Parse a layout file. arg_size: script opcode -> arg byte count (ARM9 table 0x021229AC). Check `error`.
static func parse(d: PackedByteArray, arg_size: PackedByteArray) -> Layout:
	var lay := Layout.new()
	lay.arg_size_ref = arg_size
	if d.size() < 4:
		lay.error = "layout too small"
		return lay
	var nb := d[0]
	var ne := d[1]
	var es := d.decode_u16(2)
	if es != 16 * ne:
		lay.error = "entries_size %d != 16 * %d" % [es, ne]
		return lay
	for i in ne:
		lay.entries.append(d.slice(4 + 16 * i, 20 + 16 * i))
	var p := 4 + es
	for _b in nb:
		if p + 0x10 > d.size():
			lay.error = "block at 0x%X out of the file" % p
			return lay
		var size := d.decode_u16(p)
		var ng := d[p + 2]
		var blk := Block.new()
		blk.counts = [d[p + 3], d[p + 4], d[p + 5], d[p + 6]]
		blk.pad = d[p + 7]
		blk.offs = [d.decode_u16(p + 8), d.decode_u16(p + 10), d.decode_u16(p + 12), d.decode_u16(p + 14)]
		var base := p + 0x10
		var q := base
		for _g in ng:
			var gs := d.decode_u16(q)
			var b2 := d[q + 2]
			var n := d[q + 3]
			if b2 != 4 + n + ((4 - n % 4) % 4):
				lay.error = "group at 0x%X: items offset %d" % [q, b2]
				return lay
			var grp := Group.new()
			grp.b2 = b2
			var it := q + b2
			for k in n:
				var ln := d[q + 4 + k]
				var item := Item.new(d.slice(it, it + ln))
				if ITEM_SIZE.get(item.type, -1) != ln:
					lay.error = "item at 0x%X: type %d size %d" % [it, item.type, ln]
					return lay
				grp.items.append(item)
				it += ln
			if it - q != gs:
				lay.error = "group at 0x%X: size %d != %d" % [q, gs, it - q]
				return lay
			blk.groups.append(grp)
			q += gs
		if q - base != blk.offs[0]:
			lay.error = "block at 0x%X: groups end 0x%X != off_scripts 0x%X" % [p, q - base, blk.offs[0]]
			return lay
		var tail := d.slice(q, p + size)
		var res := _parse_scripts(tail, blk.counts[0], arg_size)
		if res.is_empty():
			lay.error = "block at 0x%X: bad script area" % p
			return lay
		blk.scripts = res[0]
		blk.tables = tail.slice(res[1])
		blk.tables_at = blk.offs[0] + res[1]
		lay.blocks.append(blk)
		p += size
	if p != d.size():
		lay.error = "blocks end at 0x%X, file is 0x%X" % [p, d.size()]
	return lay


static func _parse_scripts(t: PackedByteArray, n: int, arg_size: PackedByteArray) -> Array:
	if n == 0:
		return [[], 0]
	if 2 * n > t.size():
		return []
	var offs := []
	for i in n:
		offs.append(t.decode_u16(2 * i))
	var q := 2 * n
	var lists := []
	for i in n:
		if q >= t.size():
			return []
		var c := t[q]
		lists.append(t.slice(q + 1, q + 1 + c))
		q += 1 + c
	var scripts := []
	var end := q
	for i in n:
		var s := []
		var p: int = offs[i]
		for op in lists[i]:
			if op >= arg_size.size():
				return []
			var a := arg_size[op]
			s.append([op, t.slice(p, p + a)])
			p += a
		scripts.append(s)
		end = maxi(end, p)
	return [scripts, end]


static func _write_scripts(scripts: Array, start: int) -> PackedByteArray:
	var out := PackedByteArray()
	if scripts.is_empty():
		return out
	var lists := PackedByteArray()
	for s in scripts:
		lists.append(s.size())
		for op in s:
			lists.append(op[0])
	var head := 2 * scripts.size() + lists.size()
	head += (4 - (start + head) % 4) % 4
	var args := PackedByteArray()
	var area := PackedByteArray()
	area.resize(2 * scripts.size())
	for i in scripts.size():
		area.encode_u16(2 * i, head + args.size())
		for op in scripts[i]:
			args.append_array(op[1])
	area.append_array(lists)
	while area.size() < head:
		area.append(0)
	area.append_array(args)
	return area


func write() -> PackedByteArray:
	write_error = ""
	var out := PackedByteArray([blocks.size(), entries.size(), 0, 0])
	out.encode_u16(2, 16 * entries.size())
	for e in entries:
		out.append_array(e)
	for b in blocks:
		var body := PackedByteArray()
		for g in b.groups:
			var n: int = g.items.size()
			var padn := (4 - n % 4) % 4
			var hdr := 4 + n + padn
			var gbody := PackedByteArray()
			for it in g.items:
				gbody.append(it.raw.size())
			for _k in padn:
				gbody.append(0)
			for it in g.items:
				gbody.append_array(it.raw)
			var gh := PackedByteArray([0, 0, hdr, n])
			gh.encode_u16(0, hdr + gbody.size() - n - padn)
			body.append_array(gh)
			body.append_array(gbody)
		var off_scripts := body.size()
		body.append_array(_write_scripts(b.scripts, off_scripts))
		var delta: int = body.size() - b.tables_at
		body.append_array(b.tables)
		if 0x10 + body.size() > 0xFFFF:
			write_error = "block %d would be %d bytes, over the u16 block size" % [blocks.find(b), 0x10 + body.size()]
		var bh := PackedByteArray()
		bh.resize(0x10)
		bh.encode_u16(0, 0x10 + body.size())
		bh[2] = b.groups.size()
		bh[3] = b.scripts.size()
		bh[4] = b.counts[1]
		bh[5] = b.counts[2]
		bh[6] = b.counts[3]
		bh[7] = b.pad
		bh.encode_u16(8, off_scripts)
		for k in range(1, 4):
			bh.encode_u16(8 + 2 * k, (b.offs[k] + delta) & 0xFFFF)
		out.append_array(bh)
		out.append_array(body)
	return out


# --- runtime limits ---------------------------------------------------------------------------------------------

static func _arena_block(b: Block) -> int:
	var n := 0
	if not b.groups.is_empty():
		n += 8 * b.groups.size() + 8
	for g in b.groups:
		if not g.items.is_empty():
			n += 8 * g.items.size() + 8
	for cr in [[b.scripts.size(), 8], [b.counts[3], 8], [b.counts[1], 8], [b.counts[2], 12]]:
		if cr[0]:
			n += cr[0] * cr[1] + 8
	return n


func arena_size(variant: int) -> int:
	var n := 0
	if not entries.is_empty():
		n += 4 * entries.size() + 8
	if not blocks.is_empty():
		n += 2 * 0x24 + 8
	n += _arena_block(blocks[0])
	if variant:
		n += _arena_block(blocks[variant])
	return n


func waypoint_count(variant: int) -> int:
	var bl := [blocks[0]]
	if variant:
		bl.append(blocks[variant])
	var n := 0
	for b in bl:
		for g in b.groups:
			for it in g.items:
				if it.type == 9:
					n += 1
	return n


func limit_errors() -> Array:
	var errs := []
	for v in blocks.size():
		var a := arena_size(v)
		if a > ARENA:
			errs.append("variant %d: Map_LoadNav arena %d bytes > %d (8 bytes per item)" % [v, a, ARENA])
		var w := waypoint_count(v)
		if w > MAX_WAYPOINTS:
			errs.append("variant %d: %d waypoints > %d (Nav_AddWaypoint list)" % [v, w, MAX_WAYPOINTS])
	return errs


func entry_ids() -> Array:
	var out := []
	for e in entries:
		out.append(e[0xC])
	return out
