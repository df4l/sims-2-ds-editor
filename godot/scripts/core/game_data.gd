class_name GameData
extends RefCounted
## Everything read from one ROM: the decompressed ARM9 (data tables at fixed addresses, ASJP v0x00), rom.bin,
## text banks, model names. docs/formats/location.md, layout.md, objinfo.md, roomfurn.md.

const BASE := 0x02000000
const EXPECTED_CODE := "ASJP"

# location table (Map_LoadLocation 0x02084894): u32 ptr[33]
const LOC_TABLE := 0x021332E0
const LOC_COUNT := 33
const NONE := 0xFFFF

# Place of each id = name of its first scene model (CONFIRMED 2026-10-05, see tools/locations.py)
const PLACES := [
	"AlienRoom (Gov Lab)", "ArtGallery", "Atrium", "Basement", "Casino", "CityExterior (town, starting place)",
	"CityHall", "CultRoom", "DeluxeRoom (hotel)", "Desert", "Freezer", "Furnace", "Gym", "HotelLobby", "Jail",
	"JungleRoom (hotel)", "LionLounge", "ManagerSuite", "ModernRoom (hotel)", "Observatory", "Penthouse",
	"RatCave (Cat Cave)", "RoomBeingBuilt1", "RoomBeingBuilt2", "Saloon", "SaloonRooms", "SaxLounge",
	"SecondFloorLobby (hotel)", "SecretWarehouse", "SmHotelRoom", "Store", "SushiBar", "Vault",
]

# model tables of the actor constructors: {u32 anim_list, u16 BMD0 entry, u16 anim_count}
const NPC_MODELS := 0x02118310       # type 1
const PROP_MODELS := 0x0211CD2C      # types 2 and 10
const OBJECT_MODELS := 0x0211CC3C    # type 4
const N_NPCS := 63
const N_OBJECTS := 30
const N_PROPS := 331

const ARG_SIZE_TABLE := 0x021229AC   # script opcode -> arg byte count (0x52 opcodes)
const CONV_TABLE := 0x0211F16C       # conversation id -> {u32 lines*, u8 count}; line {u16 text, u8 speaker, u8 0}
const N_CONV := 216                  # in the original table; a table moved by the editor has TABLE_MAX entries
const CONV_LITERALS := [0x0204209C, 0x020412FC]   # ARM9 literals holding the table base (NavOp17, NavOp2A)
const CONV_OV := 15                  # overlay holding the third literal (State0E_ShowNextLine)
const CONV_OV_LITERAL := 0x0214A144
const CONV_NONE := 0xD8              # "no conversation" for script op 0x19 (Npc_SetTalkConversation): never an id
const CONV_STATE21 := [3, 0x23, 0xA6]   # ops 0x17 / 0x2A send these to state 0x21: only line 0's text is used
const MSG_TABLE := 0x0211E8C0        # message id -> {u32 text id, s32 text id 2 or -1}
const N_MSG := 26                    # in the original table (0x0211E990 is other data)
const MSG_LITERAL := 0x02040720      # the only reference (NavOp45_Message)
const MSG_UNUSED := 0xFFFFFFFF       # text id of the unused records of a table moved by the editor
const TABLE_MAX := 256               # conversation / message ids are u8 in the script ops
const NPC_NAME_BASE := 0x143

# object info table (Info_Npc / Info_Prop): 18-byte records
const INFO := 0x02122A00
const INFO_REC := 18
const INFO_NPC_BASE := 2
const INFO_PROP_BASE := 0x3B
const N_NPC_INFO := 56
const NO_ICON := 6180

# text banks (rom.bin entries)
const BANKS := {"en": 123, "fr": 3496, "de": 3593, "it": 4184, "ja": 4214, "es": 7599}
const LANGS := ["en", "fr", "de", "it", "ja", "es"]

var rom: NdsRom
var rombin := RomBin.new()
var a9 := PackedByteArray()
var rombin_file_id := -1
var error := ""
var warning := ""
var locations := []      # dicts
var arg_size := PackedByteArray()
var _banks := {}
var _names := {}
var conv_override = null   # Array (see conversations()) set by EditProject when the conversations are edited
var msg_override = null    # Array of [text, text2] set by EditProject
var _rom_convs = null
var _rom_msgs = null


func open(path: String) -> bool:
	rom = NdsRom.new()
	if not rom.load_file(path):
		error = rom.error
		return false
	return _init_from_rom()


func _init_from_rom() -> bool:
	rombin_file_id = rom.find_file("rom.bin")
	if rombin_file_id < 0:
		error = "this ROM has no rom.bin: not The Sims 2 (DS)"
		return false
	if not rombin.load_bytes(rom.read_file(rombin_file_id)):
		error = rombin.error
		return false
	a9 = rom.arm9_decompressed()
	if a9.is_empty():
		error = rom.error
		return false
	if rom.game_code != EXPECTED_CODE:
		warning = "Game code %s: this editor was made on ASJP (Europe) v0x00. Data tables are read at fixed ARM9 addresses and may be wrong." % rom.game_code
	if not _check_tables():
		return false
	_read_locations()
	arg_size = a9.slice(ARG_SIZE_TABLE - BASE, ARG_SIZE_TABLE - BASE + 0x52)
	return true


func _check_tables() -> bool:
	for loc in LOC_COUNT:
		var p := u32(LOC_TABLE + 4 * loc)
		if p < BASE or p - BASE + 0x14 > a9.size():
			error = "location table not found at 0x%08X: wrong game version" % LOC_TABLE
			return false
	return true


# --- arm9 access ----------------------------------------------------------------------------------------------

func u8(a: int) -> int:
	return a9[a - BASE]


func u16(a: int) -> int:
	return a9.decode_u16(a - BASE)


func s16(a: int) -> int:
	return a9.decode_s16(a - BASE)


func u32(a: int) -> int:
	return a9.decode_u32(a - BASE)


func s32(a: int) -> int:
	return a9.decode_s32(a - BASE)


func _read_locations() -> void:
	locations.clear()
	for loc in LOC_COUNT:
		var p := u32(LOC_TABLE + 4 * loc)
		var f := []
		for i in 10:
			f.append(u16(p + 2 * i))
		var models := []
		for j in f[7]:
			var lp := u32(p + 0x14 + 8 * j)
			models.append({"model": u16(p + 0x18 + 8 * j), "anim_list": lp, "anims": u16(p + 0x1A + 8 * j)})
		locations.append({"location": loc, "place": PLACES[loc], "record": p, "bsp": f[0], "gmd1": f[1],
			"nav": f[2], "special_model": f[8], "field12": f[9], "models": models})


func model_entry(table: int, i: int) -> int:
	return u16(table + 8 * i + 4)


func npc_model(i: int) -> int:
	return model_entry(NPC_MODELS, i)


func prop_model(i: int) -> int:
	return model_entry(PROP_MODELS, i)


func object_model(i: int) -> int:
	return model_entry(OBJECT_MODELS, i)


# --- names --------------------------------------------------------------------------------------------------

## Names stored in a Nitro dictionary at d[o].
static func dict_names(d: PackedByteArray, o: int) -> PackedStringArray:
	var out := PackedStringArray()
	if o + 8 > d.size():
		return out
	var count := d[o + 1]
	var p := o + 8 + (count + 1) * 4
	if p + 4 > d.size():
		return out
	var names_off := d.decode_u16(p + 2)
	for i in count:
		var a := p + names_off + 16 * i
		if a + 16 > d.size():
			break
		out.append(d.slice(a, a + 16).get_string_from_ascii())
	return out


## First MDL0 model name of a BMD0 rom.bin entry ("" if unreadable).
func model_name(entry: int) -> String:
	if _names.has(entry):
		return _names[entry]
	var name := ""
	var d := rombin.data(entry)
	if d.size() > 16 and d.slice(0, 4).get_string_from_ascii() == "BMD0":
		for i in d.decode_u16(14):
			var bo := d.decode_u32(16 + 4 * i)
			if bo + 4 <= d.size() and d.slice(bo, bo + 4).get_string_from_ascii() == "MDL0":
				var n := dict_names(d, bo + 8)
				if not n.is_empty():
					name = n[0]
				break
	_names[entry] = name
	return name


# --- text -----------------------------------------------------------------------------------------------------

func bank(lang: String) -> TextBank:
	if not _banks.has(lang):
		_banks[lang] = TextBank.new(rombin.raw_entry(BANKS[lang]))
	return _banks[lang]


## Show this bank content instead of the ROM's (edited text, see EditProject). Empty = back to the ROM's.
func set_bank_bytes(lang: String, d: PackedByteArray) -> void:
	_banks[lang] = TextBank.new(d if not d.is_empty() else rombin.raw_entry(BANKS[lang]))


func text(i: int, lang := "en") -> String:
	return bank(lang).text(i)


func npc_name(n: int, lang := "en") -> String:
	return text(NPC_NAME_BASE + n, lang) if n < 0x3F else "npc%d" % n


func speaker_name(s: int, lang := "en") -> String:
	if s == 0x3F:
		return "narrator"
	if s == 0x40:
		return "player"
	return text(NPC_NAME_BASE + s, lang)


## Base of the conversation table the game uses (moved to the ARM9 extension by an earlier export, or not).
func conv_table() -> int:
	return u32(CONV_LITERALS[0])


## Records of the ROM's conversation table: [{ptr, count}].
func rom_conv_records() -> Array:
	var t := conv_table()
	var n := N_CONV if t == CONV_TABLE else TABLE_MAX
	var out := []
	for cid in n:
		out.append({"ptr": u32(t + 8 * cid), "count": u8(t + 8 * cid + 4)})
	return out


## The ROM's conversations: one entry per id, null (no record) or [[text id, speaker], ...].
func rom_conversations() -> Array:
	if _rom_convs == null:
		_rom_convs = []
		for r in rom_conv_records():
			if r.ptr == 0 or r.ptr < BASE or r.ptr + 4 * r.count > BASE + a9.size():
				_rom_convs.append(null)
				continue
			var lines := []
			for k in r.count:
				lines.append([u16(r.ptr + 4 * k), u8(r.ptr + 4 * k + 2)])
			_rom_convs.append(lines)
	return _rom_convs


func conversations() -> Array:
	return conv_override if conv_override != null else rom_conversations()


func n_conv() -> int:
	return conversations().size()


func conv_exists(cid: int) -> bool:
	var cs := conversations()
	return cid >= 0 and cid < cs.size() and cs[cid] != null


## [[text id, speaker]] of a conversation ([] when it does not exist).
func conversation(cid: int) -> Array:
	return conversations()[cid] if conv_exists(cid) else []


func msg_table() -> int:
	return u32(MSG_LITERAL)


## The ROM's messages: [[text id, second text id or -1]].
func rom_messages() -> Array:
	if _rom_msgs == null:
		_rom_msgs = []
		var t := msg_table()
		var n := N_MSG if t == MSG_TABLE else TABLE_MAX
		for mid in n:
			if t != MSG_TABLE and u32(t + 8 * mid) == MSG_UNUSED:
				break
			_rom_msgs.append([u32(t + 8 * mid), s32(t + 8 * mid + 4)])
	return _rom_msgs


func messages() -> Array:
	return msg_override if msg_override != null else rom_messages()


func n_msg() -> int:
	return messages().size()


## [text id, second text id or -1] ([] when it does not exist).
func message(mid: int) -> Array:
	var ms := messages()
	return ms[mid] if mid >= 0 and mid < ms.size() else []


# --- object info (icons, in-game names) -----------------------------------------------------------------------

func info_record(i: int) -> Dictionary:
	var a := INFO + INFO_REC * i
	return {"tiles": u16(a), "def": u16(a + 2), "pal": u16(a + 4), "text": u16(a + 8),
		"price": u16(a + 14), "icon": u16(a) != NO_ICON}


func info_npc(n: int) -> Dictionary:
	return info_record(n + INFO_NPC_BASE) if n >= 0 and n < N_NPC_INFO else {}


func info_prop(p: int) -> Dictionary:
	return info_record(p + INFO_PROP_BASE) if p >= 0 and p < N_PROPS else {}


func prop_game_name(p: int, lang := "en") -> String:
	var r := info_prop(p)
	return text(r.text, lang) if not r.is_empty() else ""
