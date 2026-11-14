class_name EditProject
extends RefCounted
## Edits on top of the opened ROM: layout / BSP rom.bin entries and the default hotel room furniture (arm9 table),
## with undo, autosave and ROM export. Port of editor/project.py.
##
## Edits are saved as soon as they are made under user://projects/<sha1 of the ROM>/ (one file per edited entry,
## decompressed content), so reopening the same ROM brings them back. The ROM file itself is never written:
## export_rom() writes a new .nds where the user chooses.
##
## Item indices: scripts address an actor as (g, i) = item i (1-based) of group g (0-based); waypoints link to
## 1-based items of their own group. Deleting an item renumbers what pointed after it, and refuses when a reference
## from another block might mean this item (ambiguous).
## Every mutating function returns "" on success or the reason it was refused (nothing changed then).

const KINDS := ["layout", "bsp", "furniture"]
const UNDO_MAX := 100

var gd: GameData
var furn: RoomFurn
var edits := {}       # "kind:entry" -> PackedByteArray
var undo_stack := []  # [key, previous bytes or null (= original)]
var dir := ""
var last_index := -1


func _init(g: GameData) -> void:
	gd = g
	furn = RoomFurn.new(g)
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA1)
	hc.update(g.rom.data)
	dir = "user://projects/" + hc.finish().hex_encode()
	_load_saved()


static func key(kind: String, entry: int) -> String:
	return "%s:%d" % [kind, entry]


func _file(k: String) -> String:
	return dir + "/" + k.replace(":", "_") + ".bin"


func _load_saved() -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		if not f.ends_with(".bin"):
			continue
		var parts := f.get_basename().split("_")
		if parts.size() == 2 and parts[0] in KINDS and parts[1].is_valid_int():
			edits[key(parts[0], parts[1].to_int())] = FileAccess.get_file_as_bytes(dir + "/" + f)


func original(kind: String, entry: int) -> PackedByteArray:
	match kind:
		"furniture": return furn.defaults_bytes(entry)
		"layout": return gd.rombin.raw_entry(entry)
		_: return gd.rombin.data(entry)


func current(kind: String, entry: int) -> PackedByteArray:
	return edits.get(key(kind, entry), original(kind, entry))


func is_edited(kind: String, entry: int) -> bool:
	return edits.has(key(kind, entry))


func edited_keys() -> Array:
	var ks := edits.keys()
	ks.sort()
	return ks


func _write(k: String, data) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if data == null:
		edits.erase(k)
		if FileAccess.file_exists(_file(k)):
			DirAccess.remove_absolute(_file(k))
	else:
		edits[k] = data
		var f := FileAccess.open(_file(k), FileAccess.WRITE)
		if f:
			f.store_buffer(data)
			f.close()


func _store(kind: String, entry: int, data: PackedByteArray) -> void:
	var k := key(kind, entry)
	undo_stack.append([k, edits.get(k)])
	while undo_stack.size() > UNDO_MAX:
		undo_stack.pop_front()
	_write(k, null if data == original(kind, entry) else data)


func undo() -> String:
	if undo_stack.is_empty():
		return "nothing to undo"
	var e: Array = undo_stack.pop_back()
	_write(e[0], e[1])
	return ""


func revert(kind: String, entry: int) -> void:
	if is_edited(kind, entry):
		_store(kind, entry, original(kind, entry))


func discard_all() -> void:
	for k in edits.keys():
		_write(k, null)
	undo_stack.clear()


# --- locations ---------------------------------------------------------------------------------------------------

func loc_record(loc: int) -> Dictionary:
	return gd.locations[loc]


func nav_of(loc: int) -> int:
	var n: int = gd.locations[loc].nav
	return -1 if n == GameData.NONE else n


func shared_with(loc: int) -> Array:
	var nav := nav_of(loc)
	var b: int = gd.locations[loc].bsp
	var out := []
	for L in gd.locations:
		if L.location != loc and ((nav >= 0 and L.nav == nav) or L.bsp == b):
			out.append(L.location)
	return out


func load_layout(loc: int) -> Layout:
	var nav := nav_of(loc)
	if nav < 0:
		return null
	return Layout.parse(current("layout", nav), gd.arg_size)


func entry_ids(loc: int) -> Array:
	var lay := load_layout(loc)
	return [] if lay == null or lay.error != "" else lay.entry_ids()


func _save_layout(nav: int, lay: Layout) -> String:
	var errs := lay.limit_errors()
	if not errs.is_empty():
		return "; ".join(errs)
	var data := lay.write()
	var chk := Layout.parse(data, gd.arg_size)
	if chk.error != "":
		return "the edited layout does not parse back: " + chk.error
	_store("layout", nav, data)
	return ""


func collect_bits(skip := []) -> Dictionary:
	var out := {}
	var seen := {}
	for L in gd.locations:
		var nav: int = L.nav
		if nav == GameData.NONE or seen.has(nav):
			continue
		seen[nav] = true
		var lay := Layout.parse(current("layout", nav), gd.arg_size)
		for b in lay.blocks.size():
			var blk: Layout.Block = lay.blocks[b]
			for g in blk.groups.size():
				for i in blk.groups[g].items.size():
					var it: Layout.Item = blk.groups[g].items[i]
					if it.type == 10 and [nav, b, g, i] != skip:
						out[it.get_field("collect_bit")] = [L.location, b, g, i]
	return out


func free_collect_bit() -> int:
	var used := collect_bits()
	for k in range(0, 64):
		if not used.has(k):
			return k
	return -1


func check_item(loc: int, lay: Layout, b: int, g: int, i: int) -> String:
	var it: Layout.Item = lay.blocks[b].groups[g].items[i]
	match it.type:
		4:
			var dest := it.get_field("dest")
			var entry := it.get_field("entry")
			if dest >= GameData.LOC_COUNT:
				return "door destination %d: no such location (0..%d)" % [dest, GameData.LOC_COUNT - 1]
			var ids := lay.entry_ids() if dest == loc else entry_ids(dest)
			if not entry in ids:
				return "door: location %d has no entry point %d (it has %s)" % [dest, entry, ids if not ids.is_empty() else "none"]
		3:
			var grp := it.get_field("group")
			var scr := it.get_field("script")
			var vbs := [b] if b else (range(1, lay.blocks.size()) if lay.blocks.size() > 1 else [0])
			for vb in vbs:
				var blk: Layout.Block = lay.blocks[vb]
				if grp > blk.groups.size() or scr > blk.scripts.size():
					return "trigger: block %d has %d groups and %d scripts (1-based, 0 = none), not group %d script %d" % [vb, blk.groups.size(), blk.scripts.size(), grp, scr]
		9:
			var items: Array = lay.blocks[b].groups[g].items
			for k in 4:
				var n := it.get_field("link%d" % (k + 1))
				if n and (n > items.size() or n == i + 1 or items[n - 1].type != 9):
					return "waypoint link%d = %d: must be 0 or the 1-based index of another waypoint of group %d" % [k + 1, n, g]
		10:
			var other = collect_bits([nav_of(loc), b, g, i]).get(it.get_field("collect_bit"))
			if other != null:
				return "collect bit %d already used by the timed prop at location %d block %d group %d item %d; free: %d" % [it.get_field("collect_bit"), other[0], other[1], other[2], other[3] + 1, free_collect_bit()]
	return ""


func _set_fields(it: Layout.Item, fields: Dictionary) -> String:
	for k in fields:
		var e := it.set_field(k, int(fields[k]))
		if e != "":
			return e
	return ""


static func _s16ok(v: int) -> bool:
	return v >= -0x8000 and v < 0x8000


func _get_item(lay: Layout, b: int, g: int, i: int) -> Layout.Item:
	if b < 0 or b >= lay.blocks.size() or g < 0 or g >= lay.blocks[b].groups.size():
		return null
	var items: Array = lay.blocks[b].groups[g].items
	return items[i] if i >= 0 and i < items.size() else null


## Move an item / set its angle / typed fields / its whole raw record (same size and type).
## Pass null to leave a value unchanged.
func edit_item(loc: int, b: int, g: int, i: int, x = null, y = null, z = null, angle_deg = null, raw = null,
		fields := {}) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	var it := _get_item(lay, b, g, i)
	if it == null:
		return "no item %d/%d/%d" % [b, g, i]
	if raw != null:
		var nr: PackedByteArray = raw
		if nr.size() != it.raw.size() or nr[6] != it.type:
			return "raw record must keep size %d and type %d" % [it.raw.size(), it.type]
		it.raw = nr.duplicate()
	if x != null or y != null or z != null:
		var nx: int = it.x if x == null else roundi(x)
		var ny: int = it.y if y == null else roundi(y)
		var nz: int = it.z if z == null else roundi(z)
		if not (_s16ok(nx) and _s16ok(ny) and _s16ok(nz)):
			return "position out of the s16 range"
		it.set_pos(nx, ny, nz)
	if angle_deg != null:
		if not it.type in [1, 2, 4]:
			return "type %d has no angle" % it.type
		var e := it.set_field("angle_deg", roundi(angle_deg))
		if e != "":
			return e
	var e2 := _set_fields(it, fields)
	if e2 != "":
		return e2
	if not fields.is_empty() or raw != null:
		var e3 := check_item(loc, lay, b, g, i)
		if e3 != "":
			return e3
	return _save_layout(nav_of(loc), lay)


## Append a new item of type t to group g of block b (no index shifts). Sets last_index.
func add_item(loc: int, b: int, g: int, t: int, x: float, y: float, z: float, fields := {}) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	if b < 0 or b >= lay.blocks.size() or g < 0 or g >= lay.blocks[b].groups.size():
		return "no group %d/%d" % [b, g]
	var items: Array = lay.blocks[b].groups[g].items
	if items.size() >= 0xFF:
		return "group is full (255 items)"
	if not Layout.FIELDS.has(t):
		return "no constructor for item type %d" % t
	if not (_s16ok(roundi(x)) and _s16ok(roundi(y)) and _s16ok(roundi(z))):
		return "position out of the s16 range"
	var it := Layout.new_item(t, roundi(x), roundi(y), roundi(z))
	var f := fields.duplicate()
	if t == 10 and f.get("collect_bit") == null:
		var fb := free_collect_bit()
		if fb < 0:
			return "no free collect bit left for a timed prop"
		f["collect_bit"] = fb
	var e := _set_fields(it, f)
	if e != "":
		return e
	items.append(it)
	e = check_item(loc, lay, b, g, items.size() - 1)
	if e != "":
		return e
	last_index = items.size() - 1
	return _save_layout(nav_of(loc), lay)


func duplicate_item(loc: int, b: int, g: int, i: int, dx := 8, dz := 8) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	var it := _get_item(lay, b, g, i)
	if it == null:
		return "no item %d/%d/%d" % [b, g, i]
	var items: Array = lay.blocks[b].groups[g].items
	if items.size() >= 0xFF:
		return "group is full (255 items)"
	var nw := it.copy()
	if not (_s16ok(it.x + dx) and _s16ok(it.z + dz)):
		return "position out of the s16 range"
	nw.set_pos(it.x + dx, it.y, it.z + dz)
	if nw.type == 9:
		for o in [10, 12, 14, 16]:
			nw.raw[o] = 0
	if nw.type == 10:
		var fb := free_collect_bit()
		if fb < 0:
			return "no free collect bit left for a timed prop"
		nw.set_field("collect_bit", fb)
	items.append(nw)
	last_index = items.size() - 1
	return _save_layout(nav_of(loc), lay)


func _blocks_seeing(lay: Layout, b: int) -> Array:
	if b == 0:
		var out := []
		for k in lay.blocks.size():
			out.append([k, lay.blocks[k]])
		return out
	return [[b, lay.blocks[b]]]


## Script references to item i (0-based) of group g of block b: [[block, script (1-based), op index, text]].
func references(lay: Layout, b: int, g: int, i: int) -> Array:
	var out := []
	for bb in _blocks_seeing(lay, b):
		var blk: Layout.Block = bb[1]
		for si in blk.scripts.size():
			var s: Array = blk.scripts[si]
			for k in s.size():
				var op: int = s[k][0]
				var a := LayScript.decode_args(op, s[k][1])
				for pr in LayScript.item_refs(op):
					if a.get(pr[0]) == g and a.get(pr[1]) == i + 1:
						out.append([bb[0], si + 1, k, LayScript.describe(gd, op, s[k][1], "en", blk)])
	return out


func delete_item(loc: int, b: int, g: int, i: int) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	if _get_item(lay, b, g, i) == null:
		return "no item %d/%d/%d" % [b, g, i]
	var refs := references(lay, b, g, i)
	if not refs.is_empty():
		var parts := []
		for r in refs.slice(0, 4):
			parts.append("block %d script %d: %s" % [r[0], r[1], r[3].split("\n")[0]])
		return "referenced by scripts: " + "; ".join(parts)
	var n: int = lay.blocks[b].groups[g].items.size()
	for bb in _blocks_seeing(lay, b):
		var blk: Layout.Block = bb[1]
		for si in blk.scripts.size():
			var s: Array = blk.scripts[si]
			for k in s.size():
				var op: int = s[k][0]
				for pr in LayScript.item_refs(op):
					var a := LayScript.decode_args(op, s[k][1])
					if a.get(pr[0]) == g and a.get(pr[1]) > i + 1 and a.get(pr[1]) <= n:
						if bb[0] != b:
							return "block %d script %d addresses item %d of group %d, maybe this one: ambiguous, not renumbered (move the item away instead)" % [bb[0], si + 1, a[pr[1]], g]
						var args: PackedByteArray = s[k][1].duplicate()
						args[LayScript.arg_offset(op, pr[1])] -= 1
						s[k] = [op, args]
	var items: Array = lay.blocks[b].groups[g].items
	items.remove_at(i)
	for w in items:
		if w.type == 9:
			for o in [10, 12, 14, 16]:
				if w.raw[o] == i + 1:
					w.raw[o] = 0
				elif w.raw[o] > i + 1:
					w.raw[o] -= 1
	return _save_layout(nav_of(loc), lay)


## Move an entry point and / or set its angle (s16, 4096 = 1 radian).
func edit_entry(loc: int, k: int, x = null, y = null, z = null, angle_rad = null) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	if k < 0 or k >= lay.entries.size():
		return "no entry point %d" % k
	var e: PackedByteArray = lay.entries[k]
	var vals := [e.decode_s16(0), e.decode_s16(2), e.decode_s16(4), e.decode_s16(6)]
	var nv := [vals[0] if x == null else roundi(x), vals[1] if y == null else roundi(y),
		vals[2] if z == null else roundi(z), vals[3] if angle_rad == null else roundi(angle_rad * 4096.0)]
	for v in nv:
		if not _s16ok(v):
			return "value %d out of the s16 range" % v
	for j in 4:
		e.encode_s16(2 * j, nv[j])
	lay.entries[k] = e
	return _save_layout(nav_of(loc), lay)


# --- BSP ----------------------------------------------------------------------------------------------------------

func load_bsp(loc: int) -> Bsp:
	return Bsp.parse(current("bsp", gd.locations[loc].bsp))


func _save_bsp(entry: int, t: Bsp) -> String:
	var data := t.write()
	var chk := Bsp.parse(data)
	if chk.error != "":
		return "edited BSP does not parse back: " + chk.error
	var errs := chk.check()
	if not errs.is_empty():
		return "edited BSP breaks an invariant: " + errs[0]
	_store("bsp", entry, data)
	return ""


func bsp_delete(loc: int, p: Vector3) -> String:
	var t := load_bsp(loc)
	var c := t.find_cell(p)
	if c.is_empty():
		return "no solid cell at that point"
	var e := t.delete_cell(c[0])
	if e != "":
		return e
	return _save_bsp(gd.locations[loc].bsp, t)


func bsp_move(loc: int, p: Vector3, delta: Vector3) -> String:
	var t := load_bsp(loc)
	var c := t.find_cell(p)
	if c.is_empty():
		return "no solid cell at that point"
	if t.move_cell(c[0], c[1], delta) < 0:
		return "the cell could not be moved"
	return _save_bsp(gd.locations[loc].bsp, t)


func bsp_box(loc: int, lo: Vector3, hi: Vector3) -> String:
	if lo.x >= hi.x or lo.y >= hi.y or lo.z >= hi.z:
		return "box: every min must be < max"
	var t := load_bsp(loc)
	var n := t.add_box(lo, hi)
	if n <= 0:
		return "the box lies entirely inside existing solid cells"
	return _save_bsp(gd.locations[loc].bsp, t)


# --- room furniture -----------------------------------------------------------------------------------------------

func furniture_slot(loc: int) -> int:
	return furn.slot_of(loc)


func furniture_list(slot: int) -> PackedByteArray:
	return current("furniture", slot)


func edit_furniture(loc: int, i: int, prop = null, x = null, z = null, rot = null) -> String:
	var slot := furniture_slot(loc)
	if slot < 0:
		return "this location has no default furniture"
	var lst := furniture_list(slot).duplicate()
	if i < 0 or i >= RoomFurn.N_DEFAULT:
		return "no furniture entry %d" % i
	var nv := [lst[4 * i], lst[4 * i + 1], lst[4 * i + 2], lst[4 * i + 3]]
	var inp := [prop, x, z, rot]
	for k in 4:
		if inp[k] != null:
			nv[k] = int(inp[k])
	if nv[0] < 0 or nv[0] >= GameData.N_PROPS:
		return "prop id %d out of range 0..%d" % [nv[0], GameData.N_PROPS - 1]
	if not RoomFurn.is_furniture(nv[0]):
		return "prop %d is not furniture (no placement object in Prop_CreatePlacementObject)" % nv[0]
	for k in range(1, 4):
		if nv[k] < 0 or nv[k] > 255:
			return "x, z must be 0..255 and rot 0..3"
	if nv[3] > 3:
		return "rot must be 0..3"
	var grid := furn.grid(slot)
	var wall := RoomFurn.is_wall(nv[0])
	if wall and nv[1] >= grid.n_walls:
		return "wall-mounted prop: x is a wall slot, this room has %d (0..%d)" % [grid.n_walls, grid.n_walls - 1]
	if not wall and (nv[1] >= grid.width or nv[2] >= grid.depth):
		return "cell (%d, %d) outside the room grid (%d x %d)" % [nv[1], nv[2], grid.width, grid.depth]
	for k in 4:
		lst[4 * i + k] = nv[k]
	_store("furniture", slot, lst)
	return ""


func patched_arm9() -> PackedByteArray:
	var a9 := gd.a9.duplicate()
	for k in edits:
		var parts: PackedStringArray = k.split(":")
		if parts[0] == "furniture":
			var o := RoomFurn.DEFAULTS - GameData.BASE + 24 * parts[1].to_int()
			var d: PackedByteArray = edits[k]
			for j in 24:
				a9[o + j] = d[j]
	return a9


func has_furniture_edits() -> bool:
	for k in edits:
		if k.begins_with("furniture:"):
			return true
	return false


# --- export -------------------------------------------------------------------------------------------------------

## Write a new ROM with every edit at `out_path`. "" or an error.
func export_rom(out_path: String) -> String:
	if out_path == gd.rom.path:
		return "choose another file than the opened ROM"
	var reps := {}
	for k in edits:
		var parts: PackedStringArray = k.split(":")
		var e := parts[1].to_int()
		var d: PackedByteArray = edits[k]
		if parts[0] == "layout":
			var p := d.duplicate()
			while p.size() % 4:
				p.append(0)
			reps[e] = p
		elif parts[0] == "bsp":
			reps[e] = S2Cmp.stored_blob(d)
	var files := {}
	if not reps.is_empty():
		files[gd.rombin_file_id] = gd.rombin.build(reps)
	var a9 := patched_arm9() if has_furniture_edits() else PackedByteArray()
	var out := gd.rom.rebuild(files, a9)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s (%s)" % [out_path, error_string(FileAccess.get_open_error())]
	f.store_buffer(out)
	f.close()
	return ""
