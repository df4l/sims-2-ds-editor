class_name LayScript
extends RefCounted
## Layout script opcodes (Nav_DispatchScriptOp 0x0204299c, handler table 0x0211E4F0). Doc: docs/formats/layout.md §4b
## Field specs: "name:fmt", fmt B (u8), h (s16), H (u16); "_" names an unused byte.
## group / script: 1-based in the selected variant block, 0 = none. (g, i): item i (1-based) of group g, g 0xFF = player.

const MOOD := ["normal", "angry", "romantic", "sad", "drunk", "impatient?", "cow_stare", "hi_five", "double_guns",
	"joke", "punch", "scream"]

# opcode: [name, spec, status (C confirmed / A assumed), description]
static var OPS := {
	0x00: ["despawn_item", "group:B item:B", "C", "Nav_DespawnGroupItem(group, item)"],
	0x01: ["actor_cmd", "g:B i:B action:B value:B", "C", "action 0 despawn, 1 set/clear actor flag 1, 2 flag 4"],
	0x02: ["group_cmd", "g:B action:B value:B", "C", "op 1 on every item of a spawned group"],
	0x03: ["music_pause", "", "C", "channel 0 sequence paused"],
	0x04: ["music_resume", "", "C", "channel 0 resumed"],
	0x05: ["music_play", "track:B", "C", "Snd_PlayMusic: channel 0, track 0..0x29"],
	0x06: ["sfx", "sound:B", "C", "Snd_PlaySfx: random variant of sound id"],
	0x07: ["sound_volume_a", "value:B", "A", "sound engine byte +0x664"],
	0x08: ["sound_volume_b", "value:B", "A", "sound engine byte +0x665"],
	0x09: ["timer", "delay:H group:B script:B", "C", "after delay frames: spawn group + run script"],
	0x0A: ["despawn_group", "g:B", "C", "deletes every actor of spawned group g"],
	0x0B: ["nop_0b", "", "C", "empty handler"],
	0x0C: ["actor_face", "g:B i:B dir:B", "C", "dir 0..4 -> fixed angles"],
	0x0D: ["actor_teleport", "x:h y:h z:h g:B i:B dir:B", "C", "position + direction, then floor snap"],
	0x0E: ["actor_anim", "g:B i:B anim:B b3:B b4:B b5:B", "C", "play animation id of the actor model list"],
	0x0F: ["warp", "location:B entry:B", "C", "like a door"],
	0x10: ["request_state", "state:B a:B b:B", "C", "Game_RequestState(state, slot, a, b)"],
	0x11: ["nop_11", "", "C", "empty handler"],
	0x12: ["player_control", "enable:B", "C", "0 = cutscene (D-pad ignored), 1 = back to normal"],
	0x13: ["nop_13", "", "C", "empty handler"],
	0x14: ["set_flag", "flag:B value:B", "C", "story flag bitset +0x4814"],
	0x15: ["if_flag", "flag:B group:B script:B else_group:B else_script:B", "C", "Game_TestStoryFlag"],
	0x16: ["spawn_run", "group:B script:B", "C", "Nav_SpawnGroup + Nav_RunScript"],
	0x17: ["conversation", "conv:B group:B script:B", "C", "conversation lines; at the end spawn group + run script"],
	0x18: ["nop_18", "", "C", "empty handler"],
	0x19: ["npc_set_talk", "npc:B conv:B b2:B b3:B flag:B", "C", "conversation offered by the NPC when talked to (0xD8 = none)"],
	0x1A: ["camera_look_at", "_:B _:B _:B _:B g:B i:B script:B", "C", "camera turns to the actor; script run when done"],
	0x1B: ["actor_walk_to", "x:h y:h z:h g:B i:B mode:B b9:B", "C", "actor walks to a point"],
	0x1C: ["npc_mood", "g:B i:B mood:B", "C", "NPC animation set (MOOD names)"],
	0x1D: ["actor_resume_ai", "g:B i:B", "C", "NPC gets its default roaming back"],
	0x1E: ["actor_hold_idle", "g:B i:B", "C", "loops the mood idle animation in place"],
	0x1F: ["camera_reset", "", "C", "camera back behind the player"],
	0x20: ["money_add", "amount:h", "C", "Simoleons, clamped to 0..999999"],
	0x21: ["goal_start", "goal:B script:B", "C", "mission goal started, popup; script runs when the popup is closed"],
	0x22: ["goal_done", "goal:B script:B", "C", "mission goal completed, popup; script runs when the popup is closed"],
	0x23: ["actor_walk_to_actor", "g:B i:B g2:B i2:B mode:B", "C", "move towards another actor"],
	0x24: ["hotel_dust_add", "", "C", "current location dust level +5 (hotel rooms)"],
	0x25: ["npc_ask_money", "amount:h npc:B script:B", "C", "adds \"Pay ($amount)\" to the NPC; script runs when paid"],
	0x26: ["camera_shake", "seconds:h strength:h b4:B script:B", "C", "Cam_Shake, sound 9; script when done"],
	0x27: ["nop_27", "", "C", "empty handler"],
	0x28: ["nop_28", "", "C", "empty handler"],
	0x29: ["camera_closeup", "_:B _:B g:B i:B", "C", "camera framed on the actor"],
	0x2A: ["phone_conversation", "conv:B group:B script:B", "C", "conversation on the phone"],
	0x2B: ["if_hotel_score", "min:H group:B script:B else_group:B else_script:B", "C", "hotel score >= min"],
	0x2C: ["if_stat", "min:H idx:B _:B group:B script:B else_group:B else_script:B", "A", "byte [G]+0x5B+idx >= min"],
	0x2D: ["if_location_open", "location:B group:B script:B else_group:B else_script:B", "C", "open bit of the location"],
	0x2E: ["if_goal_started", "goal:B group:B script:B else_group:B else_script:B", "C", "goal bit 1"],
	0x2F: ["if_goal_done", "goal:B group:B script:B else_group:B else_script:B", "C", "goal bit 2"],
	0x30: ["if_goal_active", "goal:B group:B script:B else_group:B else_script:B", "C", "started and not done"],
	0x31: ["if_flags", "flag:B op:B flag2:B group:B script:B else_group:B else_script:B", "C", "op 0 and, 1 or, 2 neither, 3 xor"],
	0x32: ["random_script", "s0:B s1:B s2:B s3:B s4:B", "C", "rand % 5, then the nearest non-zero entry below"],
	0x33: ["counter_inc", "", "C", "[G]+0x2F9B += 1"],
	0x34: ["if_counter", "min:B group:B script:B else_group:B else_script:B", "C", "[G]+0x2F9B >= min"],
	0x35: ["counter_reset", "", "C", "[G]+0x2F9B = 0"],
	0x36: ["npc_set_status", "npc:B value:B", "C", "NPC record +0x10 (townie, story NPC, not around yet...)"],
	0x37: ["camera_point", "param:H point:B g:B i:B", "C", "camera at layout c6 record `point`, looking at the actor"],
	0x38: ["inventory_add", "item:B script:B full_script:B", "C", "6 slots"],
	0x39: ["inventory_remove", "item:B", "C", ""],
	0x3A: ["start_fire", "location:B", "C", "fire counter of the location"],
	0x3B: ["if_time", "h1:B m1:B h2:B m2:B group:B script:B else_group:B else_script:B", "C", "game clock within h1:m1 .. h2:m2"],
	0x3C: ["npc_met", "npc:B", "C", "listed in the phone Phonebook"],
	0x3D: ["switch_2f9c", "group0:B script0:B group1:B script1:B group2:B script2:B group3:B script3:B group4:B script4:B group5:B script5:B group6:B script6:B group7:B script7:B group8:B script8:B group9:B script9:B", "C", "group/script pair chosen by [G]+0x2F9C"],
	0x3E: ["if_counter24", "idx:B min:B group:B script:B else_group:B else_script:B", "C", "byte [G]+0x24+idx >= min"],
	0x3F: ["counter24_sub", "idx:B amount:B", "C", "byte [G]+0x24+idx -= amount"],
	0x40: ["shop_unlock_item", "item:B", "A", "quest tools made available"],
	0x41: ["npc_want_item", "npc:B item:B script:B", "C", "giving item to the NPC runs script"],
	0x42: ["if_next_goal_ready", "_:B group:B script:B else_group:B else_script:B", "C", "next goal of the mission may start"],
	0x43: ["set_weather", "mode:B", "C", "0 by date, 1 off, 2 on"],
	0x44: ["set_flag_bit2", "", "A", "[0x0213E434] word |= 4"],
	0x45: ["message", "msg:B script:B queued:B", "C", "popup with texts; script runs when the popup is closed"],
	0x46: ["if_has_item", "item:B group:B script:B else_group:B else_script:B", "C", "inventory contains item"],
	0x47: ["location_offer", "location:B", "A", "room offered for construction (assumed)"],
	0x48: ["location_link_flag", "location:B flag:B", "C", "story flag set when the location is opened"],
	0x49: ["phone_gate", "value:B", "A", "deferred phone calls wait while set"],
	0x4A: ["location_open", "location:B", "C", "Coll_SetOwned: doors lead there"],
	0x4B: ["location_setup", "event:B arg:B", "C", "hard-coded per location setup"],
	0x4C: ["npc_set_1c", "npc:B value:B", "A", "NPC brain byte +0x1C"],
	0x4D: ["door_open", "g:B i:B", "C", "door actor animation"],
	0x4E: ["actor_hold_prop", "g:B i:B remove_only:B prop:B slot:B", "C", "prop actor attached to slot"],
	0x4F: ["actor_to_object", "g:B i:B", "C", "copies position/rotation of actor"],
	0x50: ["music_play2", "track:B", "C", "Snd_PlayMusic2 on channel 1"],
	0x51: ["alfred_fly_sequence", "g:B i:B b2:B", "C", "Optimum Alfred propeller entry"],
}

const _SIZE := {"B": 1, "h": 2, "H": 2}


static func op_name(op: int) -> String:
	return OPS[op][0] if OPS.has(op) else "op_%02x" % op


static func decode_args(op: int, args: PackedByteArray) -> Dictionary:
	var out := {}
	if not OPS.has(op):
		return out
	var p := 0
	for f in OPS[op][1].split(" ", false):
		var kt: PackedStringArray = f.split(":")
		var k := kt[0]
		var t := kt[1]
		if k != "_" and p + _SIZE[t] <= args.size():
			match t:
				"B": out[k] = args[p]
				"h": out[k] = args.decode_s16(p)
				"H": out[k] = args.decode_u16(p)
		p += _SIZE[t]
	return out


## Byte offset of argument `name` of opcode op (-1 if none).
static func arg_offset(op: int, name: String) -> int:
	var p := 0
	for f in OPS[op][1].split(" ", false):
		var kt: PackedStringArray = f.split(":")
		if kt[0] == name:
			return p
		p += _SIZE[kt[1]]
	return -1


## (g, i) argument pairs of the item-addressing ops ('item' is an inventory item elsewhere).
static func item_refs(op: int) -> Array:
	if op == 0x00:
		return [["group", "item"]]
	if not OPS.has(op):
		return []
	var ks := []
	for f in OPS[op][1].split(" ", false):
		ks.append(f.split(":")[0])
	var out := []
	for pr in [["g", "i"], ["g2", "i2"]]:
		if pr[0] in ks and pr[1] in ks:
			out.append(pr)
	return out


## One readable line (plus dialogue lines) for a script op.
static func describe(gd: GameData, op: int, args: PackedByteArray, lang := "en", block = null) -> String:
	var name := op_name(op)
	var a := decode_args(op, args)
	var parts := []
	for k in a:
		if k in ["flag", "flag2", "msg"]:
			parts.append("%s=0x%x" % [k, a[k]])
		else:
			parts.append("%s=%d" % [k, a[k]])
	var s := "%s(%s)" % [name, ", ".join(parts)]
	if a.has("npc"):
		s += "  ; " + gd.npc_name(a.npc, lang)
	if name in ["conversation", "phone_conversation", "npc_set_talk"]:
		for line in gd.conversation(a.conv):
			s += "\n      | %s: %s" % [gd.speaker_name(line[1], lang), gd.text(line[0], lang).replace("\n", " ")]
	if name == "message":
		var m := gd.message(a.msg)
		if not m.is_empty():
			s += "\n      | " + gd.text(m[0], lang)
		if not m.is_empty() and m[1] >= 0:
			s += " / " + gd.text(m[1], lang)
	if name == "actor_anim" and block != null:
		var n := actor_anim_name(gd, block, a.g, a.i, a.anim)
		if n != "":
			s += "  ; " + n
	if name == "npc_mood":
		s += "  ; " + (MOOD[a.mood] if a.mood < MOOD.size() else "?")
	if a.has("location"):
		var place: String = GameData.PLACES[a.location] if a.location < GameData.PLACES.size() else "?"
		s += ("  ; -> " if name == "warp" else "  ; ") + place
	return s


static func actor_item(block, g: int, i: int):
	if g == 0xFF or g >= block.groups.size() or i <= 0 or i > block.groups[g].items.size():
		return null
	return block.groups[g].items[i - 1]


static func actor_anim_name(gd: GameData, block, g: int, i: int, anim: int) -> String:
	var it = actor_item(block, g, i)
	if it == null or not it.type in [1, 2]:
		return ""
	var tbl := GameData.NPC_MODELS if it.type == 1 else GameData.PROP_MODELS
	var rec: int = tbl + 8 * it.raw[0xE]
	var p := gd.u32(rec)
	var n := gd.u16(rec + 6)
	if p == 0:
		return ""
	for k in n:
		if gd.u16(p + 6 * k) == anim:
			var e := gd.u16(p + 6 * k + 2)
			var d := gd.rombin.data(e)
			if d.size() > 20 and d.slice(0, 4).get_string_from_ascii() == "BCA0":
				var nm := GameData.dict_names(d, d.decode_u32(16) + 8)
				return nm[0] if not nm.is_empty() else ""
	return ""


# =================================================================================================================
# Script text: disassemble / assemble (editable form of a block's scripts)
# =================================================================================================================
## One op per line: `name(field=value, ...)`. Every argument byte is covered: named fields from OPS, then
## `_<offset>=v` for bytes the handler never reads and the padding up to the ARG_SIZE record (written only when
## not 0). Named fields can also be given positionally, in OPS order. `;` starts a comment. A block is
## `script 1` ... `script n` headers, each followed by its ops.

const HEX_KEYS := ["flag", "flag2", "msg"]
static var _by_name := {}


static func op_by_name(n: String) -> int:
	if _by_name.is_empty():
		for op in OPS:
			_by_name[OPS[op][0]] = op
	if _by_name.has(n):
		return _by_name[n]
	if n.begins_with("op_") and n.length() == 5 and n.substr(3).is_valid_hex_number():
		return n.substr(3).hex_to_int()
	return -1


## [name, offset, fmt] for every byte of an op's `size`-byte record. Unnamed bytes are "_<offset>" (fmt B).
static func arg_fields(op: int, size: int) -> Array:
	var out := []
	var p := 0
	if OPS.has(op):
		for f in OPS[op][1].split(" ", false):
			var kt: PackedStringArray = f.split(":")
			var n: int = _SIZE[kt[1]]
			if p + n > size:
				break
			out.append([("_%d" % p) if kt[0] == "_" else kt[0], p, kt[1]])
			p += n
	while p < size:
		out.append(["_%d" % p, p, "B"])
		p += 1
	return out


## Named (non "_") fields of an op, as "name:fmt" strings.
static func signature(op: int, size: int) -> String:
	var parts := []
	for f in arg_fields(op, size):
		if not f[0].begins_with("_"):
			parts.append(f[0])
	return "%s(%s)" % [op_name(op), ", ".join(parts)]


static func _range(fmt: String) -> Vector2i:
	match fmt:
		"h": return Vector2i(-0x8000, 0x7FFF)
		"H": return Vector2i(0, 0xFFFF)
	return Vector2i(0, 0xFF)


## `name(field=value, ...)` of one op (no comment).
static func op_text(op: int, args: PackedByteArray) -> String:
	var parts := []
	for f in arg_fields(op, args.size()):
		var v: int
		match f[2]:
			"h": v = args.decode_s16(f[1])
			"H": v = args.decode_u16(f[1])
			_: v = args[f[1]]
		if f[0].begins_with("_"):
			if v != 0:
				parts.append("%s=0x%x" % [f[0], v])
		elif f[0] in HEX_KEYS:
			parts.append("%s=0x%x" % [f[0], v])
		else:
			parts.append("%s=%d" % [f[0], v])
	return "%s(%s)" % [op_name(op), ", ".join(parts)]


## Comment lines for an op (names, dialogue lines); empty when nothing to add.
static func op_comment(gd: GameData, op: int, args: PackedByteArray, lang := "en", block = null) -> PackedStringArray:
	var d := describe(gd, op, args, lang, block)
	var lines := d.split("\n")
	var out := PackedStringArray()
	var at := lines[0].find(")  ; ")
	if at >= 0:
		out.append(lines[0].substr(at + 5))
	for j in range(1, lines.size()):
		out.append(lines[j].strip_edges())
	return out


## Editable text of a block's scripts. With `gd`, names and dialogue lines are added as comments.
static func disassemble(scripts: Array, gd: GameData = null, lang := "en", block = null) -> String:
	var out := PackedStringArray()
	for k in scripts.size():
		if k:
			out.append("")
		out.append("script %d" % (k + 1))
		for op in scripts[k]:
			var line: String = "  " + op_text(op[0], op[1])
			if gd != null:
				var c := op_comment(gd, op[0], op[1], lang, block)
				if not c.is_empty():
					line += "  ; " + c[0]
					for j in range(1, c.size()):
						line += "\n      ; " + c[j]
			out.append(line)
	return "\n".join(out) + "\n"


static func _parse_int(s: String) -> Variant:
	s = s.strip_edges()
	var neg := s.begins_with("-")
	if neg:
		s = s.substr(1).strip_edges()
	var v: int
	if s.to_lower().begins_with("0x") and s.length() > 2 and s.substr(2).is_valid_hex_number():
		v = s.substr(2).hex_to_int()
	elif s != "" and s.is_valid_int() and s[0] != "+" and s[0] != "-":
		v = s.to_int()
	else:
		return null
	return -v if neg else v


## Assemble one op line (no comment). Returns [op, args] or an error string.
static func assemble_op(line: String, arg_size: PackedByteArray) -> Variant:
	line = line.strip_edges()
	var lp := line.find("(")
	if lp < 0 or not line.ends_with(")"):
		return "expected name(args...)"
	var name := line.substr(0, lp).strip_edges()
	var op := op_by_name(name)
	if op < 0 or op >= arg_size.size():
		return "unknown opcode '%s'" % name
	var size := arg_size[op]
	var fields := arg_fields(op, size)
	var named := []
	var by_name := {}
	for f in fields:
		by_name[f[0]] = f
		if not f[0].begins_with("_"):
			named.append(f)
	var vals := {}
	var inner := line.substr(lp + 1, line.length() - lp - 2).strip_edges()
	var pos := 0
	var seen_kw := false
	if inner != "":
		for part in inner.split(","):
			var eq := part.find("=")
			var key: String
			var sval: String
			if eq >= 0:
				key = part.substr(0, eq).strip_edges()
				sval = part.substr(eq + 1)
				seen_kw = true
				if not by_name.has(key):
					var known := []
					for f in named:
						known.append(f[0])
					return "%s has no field '%s' (fields: %s)" % [name, key, ", ".join(known) if not known.is_empty() else "none"]
			else:
				if seen_kw:
					return "positional value after a named one"
				if pos >= named.size():
					return "%s takes %d values: %s" % [name, named.size(), signature(op, size)]
				key = named[pos][0]
				sval = part
				pos += 1
			if vals.has(key):
				return "field '%s' given twice" % key
			var v = _parse_int(sval)
			if v == null:
				return "%s: '%s' is not a number" % [key, sval.strip_edges()]
			var r := _range(by_name[key][2])
			if v < r.x or v > r.y:
				return "%s = %d out of range %d..%d" % [key, v, r.x, r.y]
			vals[key] = v
	var missing := []
	for f in named:
		if not vals.has(f[0]):
			missing.append(f[0])
	if not missing.is_empty():
		return "missing %s: %s" % [", ".join(missing), signature(op, size)]
	var args := PackedByteArray()
	args.resize(size)
	for f in fields:
		var v: int = vals.get(f[0], 0)
		match f[2]:
			"h": args.encode_s16(f[1], v)
			"H": args.encode_u16(f[1], v)
			_: args[f[1]] = v
	return [op, args]


## Text -> {scripts: Array, error: String, line: int (1-based, 0 = none)}.
static func assemble(text: String, arg_size: PackedByteArray) -> Dictionary:
	var scripts := []
	var cur = null
	var ln := 0
	for raw in text.split("\n"):
		ln += 1
		var line: String = raw
		var sc := line.find(";")
		if sc >= 0:
			line = line.substr(0, sc)
		line = line.strip_edges()
		if line == "":
			continue
		if line.to_lower().begins_with("script") and line.find("(") < 0:
			var n = _parse_int(line.substr(6).strip_edges().trim_suffix(":"))
			if n == null:
				return {"scripts": [], "error": "expected 'script N'", "line": ln}
			if n != scripts.size() + 1:
				return {"scripts": [], "error": "scripts must be numbered 1, 2, 3... in order: expected script %d, got %d" % [scripts.size() + 1, n], "line": ln}
			if scripts.size() >= 255:
				return {"scripts": [], "error": "a block holds at most 255 scripts", "line": ln}
			cur = []
			scripts.append(cur)
			continue
		if cur == null:
			return {"scripts": [], "error": "op before the first 'script 1' header", "line": ln}
		var r = assemble_op(line, arg_size)
		if r is String:
			return {"scripts": [], "error": r, "line": ln}
		if cur.size() >= 255:
			return {"scripts": [], "error": "a script holds at most 255 ops", "line": ln}
		cur.append(r)
	return {"scripts": scripts, "error": "", "line": 0}


## Group / script references of one op: [[field, kind ("group" | "script"), value]] (1-based, 0 = none).
static func flow_refs(op: int, args: PackedByteArray) -> Array:
	var out := []
	if op == 0x00:
		return out
	var a := decode_args(op, args)
	for k in a:
		var kind := ""
		if k == "group" or k == "else_group" or (k.begins_with("group") and k.substr(5).is_valid_int()):
			kind = "group"
		elif k in ["script", "else_script", "full_script"] or (k.begins_with("script") and k.substr(6).is_valid_int()) \
				or (k.length() == 2 and k[0] == "s" and k[1].is_valid_int()):
			kind = "script"
		if kind != "":
			out.append([k, kind, a[k]])
	return out
