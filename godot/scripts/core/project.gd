class_name EditProject
extends RefCounted
## Edits on top of the opened ROM: layout / BSP / text bank rom.bin entries, the default hotel room furniture and the
## conversation / message tables (arm9),
## with undo, autosave and ROM export. Port of the former Python editor (editor/project.py, removed).
##
## Edits are saved as soon as they are made under user://projects/<sha1 of the ROM>/ (one file per edited entry,
## decompressed content), so reopening the same ROM brings them back. The ROM file itself is never written:
## export_rom() writes a new .nds where the user chooses.
##
## Item indices: scripts address an actor as (g, i) = item i (1-based) of group g (0-based); waypoints link to
## 1-based items of their own group. Deleting an item renumbers what pointed after it, and refuses when a reference
## from another block might mean this item (ambiguous).
## Every mutating function returns "" on success or the reason it was refused (nothing changed then).

const KINDS := ["layout", "bsp", "furniture", "text", "conv", "msg"]
const UNDO_MAX := 100

var gd: GameData
var furn: RoomFurn
var edits := {}       # "kind:entry" -> PackedByteArray
var undo_stack := []  # one entry per edit: [[key, previous bytes or null (= original)], ...]
var _group := false   # while true, _store adds to the last undo entry (one edit touching several keys)
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
	for l in GameData.BANKS:
		if is_edited("text", GameData.BANKS[l]):
			gd.set_bank_bytes(l, edits[key("text", GameData.BANKS[l])])
	_sync_tables()


func original(kind: String, entry: int) -> PackedByteArray:
	match kind:
		"furniture": return furn.defaults_bytes(entry)
		"conv": return encode_convs(gd.rom_conversations())
		"msg": return encode_msgs(gd.rom_messages())
		"layout", "text": return gd.rombin.raw_entry(entry)
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
	if k.begins_with("text:"):
		var e := k.split(":")[1].to_int()
		for l in GameData.BANKS:
			if GameData.BANKS[l] == e:
				gd.set_bank_bytes(l, edits.get(k, PackedByteArray()))
	if k.begins_with("conv:") or k.begins_with("msg:"):
		_sync_tables()


func _store(kind: String, entry: int, data: PackedByteArray) -> void:
	var k := key(kind, entry)
	if _group and not undo_stack.is_empty():
		undo_stack[-1].append([k, edits.get(k)])
	else:
		undo_stack.append([[k, edits.get(k)]])
	while undo_stack.size() > UNDO_MAX:
		undo_stack.pop_front()
	_write(k, null if data == original(kind, entry) else data)


func undo() -> String:
	if undo_stack.is_empty():
		return "nothing to undo"
	var e: Array = undo_stack.pop_back()
	for i in range(e.size() - 1, -1, -1):
		_write(e[i][0], e[i][1])
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
	if lay.write_error != "":
		return lay.write_error
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


## Blocks whose groups / scripts the 1-based refs of block b point into: b itself for a variant block; for block 0
## every variant block (the one the game selected), or block 0 when there is no variant.
static func target_blocks(lay: Layout, b: int) -> Array:
	if b or lay.blocks.size() == 1:
		return [b]
	return range(1, lay.blocks.size())


## Broken script / trigger references of a whole layout (each a readable string). The game would run a wrong or
## out-of-table group / script, conversation or location for these.
func script_ref_errors(lay: Layout) -> Array:
	var out := []
	for b in lay.blocks.size():
		var blk: Layout.Block = lay.blocks[b]
		var refs := []   # [where, kind, value]
		for si in blk.scripts.size():
			var s: Array = blk.scripts[si]
			for k in s.size():
				var op: int = s[k][0]
				var where := "block %d script %d op %d %s" % [b, si + 1, k + 1, LayScript.op_name(op)]
				for r in LayScript.flow_refs(op, s[k][1]):
					refs.append([where + " " + r[0], r[1], r[2]])
				var a := LayScript.decode_args(op, s[k][1])
				if a.has("conv") and not gd.conv_exists(a.conv) and not (op == 0x19 and a.conv == GameData.CONV_NONE):
					out.append("%s: conversation %d does not exist" % [where, a.conv])
				if a.has("msg") and a.msg >= gd.n_msg():
					out.append("%s: message %d does not exist (0..%d)" % [where, a.msg, gd.n_msg() - 1])
				if a.has("location") and a.location >= GameData.LOC_COUNT:
					out.append("%s: location %d does not exist (0..%d)" % [where, a.location, GameData.LOC_COUNT - 1])
		for g in blk.groups.size():
			for i in blk.groups[g].items.size():
				var it: Layout.Item = blk.groups[g].items[i]
				if it.type == 3:
					var where := "trigger box block %d group %d item %d" % [b, g, i + 1]
					refs.append([where + " group", "group", it.get_field("group")])
					refs.append([where + " script", "script", it.get_field("script")])
		for r in refs:
			if r[2] == 0:
				continue
			for t in target_blocks(lay, b):
				var tb: Layout.Block = lay.blocks[t]
				var n: int = tb.groups.size() if r[1] == "group" else tb.scripts.size()
				if r[2] > n:
					out.append("%s = %d, but block %d has %d %ss (1-based, 0 = none)" % [r[0], r[2], t, n, r[1]])
	return out


## Replace the scripts of block b. Refused when it leaves a script or trigger reference broken (that the original
## data did not already have) or breaks a runtime limit.
func set_scripts(loc: int, b: int, scripts: Array) -> String:
	var lay := load_layout(loc)
	if lay == null:
		return "this location has no layout"
	if b < 0 or b >= lay.blocks.size():
		return "no block %d" % b
	if scripts.is_empty() and not lay.blocks[b].scripts.is_empty():
		return "the game runs script 1 when the block is loaded: keep at least one script (it may hold a no-op like nop_0b())"
	var before := {}
	for e in script_ref_errors(Layout.parse(original("layout", nav_of(loc)), gd.arg_size)):
		before[e] = true
	lay.blocks[b].scripts = scripts
	var errs := []
	for e in script_ref_errors(lay):
		if not before.has(e):
			errs.append(e)
	if not errs.is_empty():
		return "broken references:\n" + "\n".join(errs.slice(0, 12)) + ("\n…" if errs.size() > 12 else "")
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


# --- text --------------------------------------------------------------------------------------------------------

## Text of string `id` in bank `lang`, with the edits.
func text_of(lang: String, id: int) -> String:
	return gd.bank(lang).text(id)


var _orig_banks := {}


func _orig_bank(lang: String) -> TextBank:
	if not _orig_banks.has(lang):
		_orig_banks[lang] = TextBank.new(original("text", GameData.BANKS[lang]))
		_orig_banks[lang].all_strings()
	return _orig_banks[lang]


func original_text(lang: String, id: int) -> String:
	return _orig_bank(lang).text(id)


func is_text_edited(lang: String, id: int) -> bool:
	if not is_edited("text", GameData.BANKS[lang]):
		return false
	return _orig_bank(lang).string_bytes(id) != gd.bank(lang).string_bytes(id)


## Ids whose string differs from the ROM's.
func edited_text_ids(lang: String) -> Array:
	var out := []
	if not is_edited("text", GameData.BANKS[lang]):
		return out
	var o := _orig_bank(lang)
	var cur := gd.bank(lang)
	for i in mini(o.count(), cur.count()):
		if o.string_bytes(i) != cur.string_bytes(i):
			out.append(i)
	return out


## Replace string `id` of bank `lang` (readable form, see TextBank.to_str). The Huffman tree is rebuilt when the
## new text needs a byte the tree lacks (sets last_tree_rebuilt). When every string is back to the original the
## original bank is restored (the edit disappears).
var last_tree_rebuilt := false


func set_text(lang: String, id: int, t: String) -> String:
	last_tree_rebuilt = false
	if not GameData.BANKS.has(lang):
		return "no text bank for language %s" % lang
	var e: int = GameData.BANKS[lang]
	var bank := TextBank.new(current("text", e))
	if id < 0 or id >= bank.count():
		return "no string 0x%X (bank has %d)" % [id, bank.count()]
	var enc := TextBank.from_str(t)
	if enc.error != "":
		return enc.error
	if bank.string_bytes(id) == enc.bytes:
		return ""
	var orig := _orig_bank(lang)
	bank.all_strings()
	bank.strings[id] = enc.bytes
	if bank.strings == orig.all_strings():
		_store("text", e, orig.data)
		return ""
	last_tree_rebuilt = bank.set_string(id, enc.bytes)
	var data := bank.write()
	if data.is_empty():
		return "internal error: a byte has no Huffman code"
	if TextBank.new(data).all_strings() != bank.strings:
		return "internal error: the re-encoded bank does not decode back to the same strings"
	_store("text", e, data)
	return ""


# --- conversations and messages -----------------------------------------------------------------------------------
## Stored as one edit each ("conv:0", "msg:0"), the whole table in this form:
##   conv: u16 n | per id: u8 present, u8 line count, lines {u16 text id, u8 speaker, u8 0}
##   msg:  u16 n | per id: u32 text id, s32 second text id or -1
## Export (_apply_convs / _apply_msgs): a changed conversation is rewritten in place when its line array is not shared
## and does not grow, else appended to the ARM9 extension. New ids move the whole table to the extension
## (TABLE_MAX records) and rewrite every pointer to its base (conversations: 2 ARM9 literals + 1 in overlay 15;
## messages: 1 ARM9 literal). docs/formats/text.md §4.

const MAX_LINES := 255   # u8 count


static func encode_convs(cs: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, cs.size())
	for c in cs:
		if c == null:
			out.append_array(PackedByteArray([0, 0]))
			continue
		out.append_array(PackedByteArray([1, c.size()]))
		for l in c:
			out.append_array(PackedByteArray([l[0] & 0xFF, l[0] >> 8, l[1], 0]))
	return out


static func decode_convs(d: PackedByteArray) -> Array:
	var out := []
	var o := 2
	for _cid in d.decode_u16(0):
		var present := d[o]
		var n := d[o + 1]
		o += 2
		if not present:
			out.append(null)
			continue
		var lines := []
		for k in n:
			lines.append([d.decode_u16(o), d[o + 2]])
			o += 4
		out.append(lines)
	return out


static func encode_msgs(ms: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + 8 * ms.size())
	out.encode_u16(0, ms.size())
	for i in ms.size():
		out.encode_u32(2 + 8 * i, ms[i][0])
		out.encode_s32(6 + 8 * i, ms[i][1])
	return out


static func decode_msgs(d: PackedByteArray) -> Array:
	var out := []
	for i in d.decode_u16(0):
		out.append([d.decode_u32(2 + 8 * i), d.decode_s32(6 + 8 * i)])
	return out


func _sync_tables() -> void:
	gd.conv_override = decode_convs(edits[key("conv", 0)]) if is_edited("conv", 0) else null
	gd.msg_override = decode_msgs(edits[key("msg", 0)]) if is_edited("msg", 0) else null


func conversations() -> Array:
	return gd.conversations()


func text_count() -> int:
	return gd.bank("en").count()


func _check_lines(lines: Array) -> String:
	if lines.is_empty():
		return "a conversation needs at least one line (the game reads line 0 before checking the count)"
	if lines.size() > MAX_LINES:
		return "at most %d lines" % MAX_LINES
	for k in lines.size():
		var l: Array = lines[k]
		if l.size() != 2:
			return "line %d: [text id, speaker] expected" % (k + 1)
		if l[0] < 0 or l[0] >= text_count():
			return "line %d: text 0x%X does not exist (0..0x%X)" % [k + 1, l[0], text_count() - 1]
		if l[1] < 0 or l[1] > 0x40:
			return "line %d: speaker %d: must be an NPC id 0..62, 63 (narrator) or 64 (player)" % [k + 1, l[1]]
	return ""


func _store_convs(cs: Array) -> void:
	_store("conv", 0, encode_convs(cs))


func is_new_conv(cid: int) -> bool:
	var o := gd.rom_conversations()
	return not (cid < o.size() and o[cid] != null)


## Replace the lines ([[text id, speaker], ...]) of conversation cid.
func set_conversation(cid: int, lines: Array) -> String:
	var cs := conversations().duplicate(true)
	if cid < 0 or cid >= cs.size() or cs[cid] == null:
		return "no conversation %d" % cid
	var e := _check_lines(lines)
	if e != "":
		return e
	cs[cid] = lines.duplicate(true)
	_store_convs(cs)
	return ""


## Id for a new conversation: after the original ones, never CONV_NONE (-1 when none is left).
func free_conv_id() -> int:
	var cs := conversations()
	for cid in range(GameData.N_CONV, GameData.TABLE_MAX):
		if cid != GameData.CONV_NONE and (cid >= cs.size() or cs[cid] == null):
			return cid
	return -1


## New conversation; its id goes to last_index.
func add_conversation(lines: Array) -> String:
	var e := _check_lines(lines)
	if e != "":
		return e
	var cid := free_conv_id()
	if cid < 0:
		return "no free conversation id left (ids are u8; 0x%X means none)" % GameData.CONV_NONE
	var cs := conversations().duplicate(true)
	while cs.size() < GameData.TABLE_MAX:
		cs.append(null)
	cs[cid] = lines.duplicate(true)
	_store_convs(cs)
	last_index = cid
	return ""


## Script ops of every layout using conversation cid: [{location, block, script, op, name}].
func conv_users(cid: int) -> Array:
	return _table_users("conv", cid)


func msg_users(mid: int) -> Array:
	return _table_users("msg", mid)


func _table_users(field: String, v: int) -> Array:
	var out := []
	var seen := {}
	for L in gd.locations:
		var nav: int = L.nav
		if nav == GameData.NONE or seen.has(nav):
			continue
		seen[nav] = true
		var lay := Layout.parse(current("layout", nav), gd.arg_size)
		if lay.error != "":
			continue
		for b in lay.blocks.size():
			var blk: Layout.Block = lay.blocks[b]
			for si in blk.scripts.size():
				var s: Array = blk.scripts[si]
				for k in s.size():
					var a := LayScript.decode_args(s[k][0], s[k][1])
					if a.get(field) == v:
						out.append({"location": L.location, "block": b, "script": si + 1, "op": k + 1,
							"name": LayScript.op_name(s[k][0])})
	return out


## Remove a conversation added in the editor (the game's own ones may be used from code: change their lines instead).
func delete_conversation(cid: int) -> String:
	var cs := conversations().duplicate(true)
	if cid < 0 or cid >= cs.size() or cs[cid] == null:
		return "no conversation %d" % cid
	if not is_new_conv(cid):
		return "conversation %d comes from the game: change its lines instead" % cid
	var u := conv_users(cid)
	if not u.is_empty():
		return "conversation %d is used by location %d block %d script %d (%s)" % [cid, u[0].location, u[0].block, u[0].script, u[0].name]
	cs[cid] = null
	while cs.size() > gd.rom_conversations().size() and cs[-1] == null:
		cs.pop_back()
	_store_convs(cs)
	return ""


func _check_msg(t1: int, t2: int) -> String:
	if t1 < 0 or t1 >= text_count():
		return "text 0x%X does not exist (0..0x%X)" % [t1, text_count() - 1]
	if t2 != -1 and (t2 < 0 or t2 >= text_count()):
		return "second text 0x%X does not exist (-1 = none)" % t2
	return ""


func set_message(mid: int, t1: int, t2: int) -> String:
	var ms := gd.messages().duplicate(true)
	if mid < 0 or mid >= ms.size():
		return "no message %d" % mid
	var e := _check_msg(t1, t2)
	if e != "":
		return e
	ms[mid] = [t1, t2]
	_store("msg", 0, encode_msgs(ms))
	return ""


## New message; its id goes to last_index.
func add_message(t1: int, t2: int) -> String:
	var ms := gd.messages().duplicate(true)
	if ms.size() >= GameData.TABLE_MAX:
		return "no free message id left (ids are u8)"
	var e := _check_msg(t1, t2)
	if e != "":
		return e
	ms.append([t1, t2])
	_store("msg", 0, encode_msgs(ms))
	last_index = ms.size() - 1
	return ""


## Remove the last message when the editor added it and no script uses it (ids stay contiguous).
func delete_message(mid: int) -> String:
	var ms := gd.messages().duplicate(true)
	if mid != ms.size() - 1 or mid < gd.rom_messages().size():
		return "only the last message added in the editor can be removed (ids must stay contiguous)"
	var u := msg_users(mid)
	if not u.is_empty():
		return "message %d is used by location %d block %d script %d" % [mid, u[0].location, u[0].block, u[0].script]
	ms.pop_back()
	_store("msg", 0, encode_msgs(ms))
	return ""


static func _line_bytes(lines: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for l in lines:
		out.append_array(PackedByteArray([l[0] & 0xFF, l[0] >> 8, l[1], 0]))
	return out


func _apply_convs(m: Arm9Mod) -> String:
	var recs := gd.rom_conv_records()
	var orig := gd.rom_conversations()
	var cur := conversations()
	var t0 := gd.conv_table()
	var t := t0
	if cur.size() > recs.size():
		for lit in GameData.CONV_LITERALS:
			if m.read_u32(lit) != t0:
				return "ARM9 word 0x%08X is not the conversation table base: unsupported game version" % lit
		t = m.alloc(8 * GameData.TABLE_MAX)   # always TABLE_MAX: GameData reads that many from a moved table
		if t == 0:
			return m.error
		m.write(t, m.read(t0, 8 * recs.size()))
		for lit in GameData.CONV_LITERALS:
			m.write_u32(lit, t)
		ovl_patches[GameData.CONV_OV] = {GameData.CONV_OV_LITERAL: [t0, t]}
	var uses := {}
	for r in recs:
		uses[r.ptr] = uses.get(r.ptr, 0) + 1
	for cid in cur.size():
		var o = orig[cid] if cid < orig.size() else null
		if cur[cid] == o:
			continue
		var rec := PackedByteArray()
		rec.resize(8)
		if cur[cid] != null:
			var lines := _line_bytes(cur[cid])
			var p := 0
			if o != null and uses[recs[cid].ptr] == 1 and cur[cid].size() <= o.size():
				p = recs[cid].ptr
				var e := m.write(p, lines)
				if e != "":
					return e
			else:
				p = m.add(lines)
				if p == 0:
					return m.error
			rec.encode_u32(0, p)
			rec[4] = cur[cid].size()
		var e2 := m.write(t + 8 * cid, rec)
		if e2 != "":
			return e2
	return ""


func _apply_msgs(m: Arm9Mod) -> String:
	var cur := gd.messages()
	var t := gd.msg_table()
	var n := cur.size()
	if t == GameData.MSG_TABLE:
		if n > GameData.N_MSG:
			if m.read_u32(GameData.MSG_LITERAL) != t:
				return "ARM9 word 0x%08X is not the message table base: unsupported game version" % GameData.MSG_LITERAL
			t = m.alloc(8 * GameData.TABLE_MAX)
			if t == 0:
				return m.error
			m.write_u32(GameData.MSG_LITERAL, t)
			n = GameData.TABLE_MAX
	else:
		n = GameData.TABLE_MAX
	var rec := PackedByteArray()
	rec.resize(8)
	for mid in n:
		if mid < cur.size():
			rec.encode_u32(0, cur[mid][0])
			rec.encode_s32(4, cur[mid][1])
		else:
			rec.encode_u32(0, GameData.MSG_UNUSED)
			rec.encode_s32(4, -1)
		var e := m.write(t + 8 * mid, rec)
		if e != "":
			return e
	return ""


## Append a new string to every language bank (same text everywhere: translate it afterwards in the Text tab).
## Its id goes to last_index. Txt_GetString does not bound-check ids, the offset table just grows.
func add_string(t: String) -> String:
	var enc := TextBank.from_str(t)
	if enc.error != "":
		return enc.error
	var n := text_count()
	for l in GameData.LANGS:
		if gd.bank(l).count() != n:
			return "the text banks do not have the same string count (%s: %d, en: %d)" % [l, gd.bank(l).count(), n]
	if n >= 0xFFFF:
		return "text ids are u16: no room left"
	var datas := {}
	for l in GameData.LANGS:
		var bank := TextBank.new(current("text", GameData.BANKS[l]))
		bank.all_strings()
		bank.strings.append(PackedByteArray())
		bank.set_string(n, enc.bytes)
		var data := bank.write()
		if data.is_empty() or TextBank.new(data).all_strings() != bank.strings:
			return "internal error: the %s bank does not re-encode" % l
		datas[l] = data
	for k in GameData.LANGS.size():
		_group = k > 0
		_store("text", GameData.BANKS[GameData.LANGS[k]], datas[GameData.LANGS[k]])
	_group = false
	last_index = n
	return ""


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


## ARM9 with the edits that live in it (default room furniture), on top of whatever the opened ROM already has
## (an extension area from an earlier export is kept). See Arm9Mod.
## Also fills `ovl_patches` ({overlay: {literal address: [old value, new value]}}) for words outside the ARM9 that
## must follow (the conversation table base in overlay 15). Errors go to m.error.
var ovl_patches := {}


func arm9_mod() -> Arm9Mod:
	var m := Arm9Mod.new(gd.a9)
	ovl_patches = {}
	for k in edits:
		var parts: PackedStringArray = k.split(":")
		if parts[0] == "furniture":
			m.write(RoomFurn.DEFAULTS + 24 * parts[1].to_int(), edits[k])
	if m.error == "" and is_edited("conv", 0):
		m.error = _apply_convs(m)
	if m.error == "" and is_edited("msg", 0):
		m.error = _apply_msgs(m)
	return m


func patched_arm9() -> PackedByteArray:
	return arm9_mod().build()


func has_furniture_edits() -> bool:
	for k in edits:
		if k.begins_with("furniture:"):
			return true
	return false


func has_arm9_edits() -> bool:
	for k in edits:
		if k.begins_with("furniture:") or k.begins_with("conv:") or k.begins_with("msg:"):
			return true
	return false


# --- export -------------------------------------------------------------------------------------------------------

## The edited ROM image. Sets `last_hints` (unchanged ranges, for export_patch). Empty on error (`build_error`).
var last_hints := []
var build_error := ""


func build_rom() -> PackedByteArray:
	build_error = ""
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
		elif parts[0] == "text":
			reps[e] = d
	var files := {}
	if not reps.is_empty():
		files[gd.rombin_file_id] = gd.rombin.build(reps)
	var a9 := PackedByteArray()
	var ovt := PackedByteArray()
	if has_arm9_edits():
		var m := arm9_mod()
		if m.error != "":
			build_error = m.error
			return PackedByteArray()
		a9 = m.build()
		if not ovl_patches.is_empty():
			ovt = gd.rom.overlay9_table()
			for ov in ovl_patches:
				var code := gd.rom.overlay9_code(ov)
				if code.is_empty():
					build_error = gd.rom.error
					return PackedByteArray()
				var inf := gd.rom.overlay9_info(ov)
				for at in ovl_patches[ov]:
					var o: int = at - inf.ram
					var pr: Array = ovl_patches[ov][at]
					if o < 0 or o + 4 > code.size() or code.decode_u32(o) != pr[0]:
						build_error = "overlay %d: the word at 0x%08X is not 0x%08X: unsupported game version" % [ov, at, pr[0]]
						return PackedByteArray()
					code.encode_u32(o, pr[1])
				files[inf.file] = code   # stored uncompressed: clear the compressed flag
				ovt.encode_u32(32 * ov + 0x1C, code.size() & 0xFFFFFF)
	var out := gd.rom.rebuild(files, a9, ovt)
	last_hints = gd.rom.last_map.duplicate()
	if files.has(gd.rombin_file_id):
		var old_start := gd.rom.file_range(gd.rombin_file_id).x
		var new_start := out.decode_u32(out.decode_u32(0x48) + 8 * gd.rombin_file_id)
		for h in gd.rombin.last_map:
			last_hints.append([new_start + h[0], old_start + h[1], h[2]])
	return out


func _save(out_path: String, b: PackedByteArray) -> String:
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s (%s)" % [out_path, error_string(FileAccess.get_open_error())]
	f.store_buffer(b)
	f.close()
	return ""


## Write a new ROM with every edit at `out_path`. "" or an error.
func export_rom(out_path: String) -> String:
	if out_path == gd.rom.path:
		return "choose another file than the opened ROM"
	var out := build_rom()
	if out.is_empty():
		return build_error
	return _save(out_path, out)


## Write a BPS patch (opened ROM -> edited ROM) at `out_path`. "" or an error.
func export_patch(out_path: String) -> String:
	if out_path == gd.rom.path:
		return "choose another file than the opened ROM"
	var out := build_rom()
	if out.is_empty():
		return build_error
	return _save(out_path, Bps.encode(gd.rom.data, out, last_hints))
