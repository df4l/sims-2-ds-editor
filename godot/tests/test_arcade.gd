extends SceneTree
## Checks of own arcade games (ArcadeExt, docs/formats/arcade.md §6):
##   Godot --headless --path godot --script res://tests/test_arcade.gd -- rom.nds out_dir
## Uses its own project folder (user://tests/arcade). Puts the test card on cabinet 174 (Lunar Lander) and turns the
## Space Armada cabinet of location 24 (layout item 0/0/23, prop 165) into a 174. Writes out_dir/arcade_card.nds
## (direct boot into location 24) and out_dir/arcade_ext.bin + arcade_ext.txt (extension and addresses, for capstone).

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var out_dir: String = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var pr := EditProject.new(gd)
	pr.dir = "user://tests/arcade"
	pr.edits.clear()
	pr.undo_stack.clear()
	DirAccess.make_dir_recursive_absolute(pr.dir)
	for f in DirAccess.get_files_at(pr.dir):
		DirAccess.remove_absolute(pr.dir.path_join(f))

	# --- original ARM9 ------------------------------------------------------------------------------------------
	var m0 := Arm9Mod.new(gd.a9)
	for at in ArcadeExt.TABLE_LITERALS:
		check(m0.read_u32(at) - ArcadeExt.TABLE in [0, 4, 8], "literal 0x%08X -> table" % at)
	var hits := m0.pointers_into(ArcadeExt.TABLE, ArcadeExt.TABLE + 12 * ArcadeExt.OLD_TYPES)
	check(hits.size() == ArcadeExt.TABLE_LITERALS.size(), "no other word points into the table (%d hits)" % hits.size())
	for p in ArcadeExt.FREE_PROPS:
		check(m0.read_u32(ArcadeExt.FREE_PROPS[p]) == ArcadeExt.MOV_R3_0, "prop %d case sets type 0" % p)
	check(gd.prop_game_name(174).contains("Lunar"), "174 = " + gd.prop_game_name(174))

	# --- project ------------------------------------------------------------------------------------------------
	check(pr.set_arcade_game(173, ArcadeExt.TEST_CARD, "asm") != "", "cabinet 173 refused (has a game)")
	check(pr.set_arcade_game(174, "init:\nupdate:\n\tfoo r0\nfree:\n", "asm") != "", "assembly error reported")
	check(pr.set_arcade_game(174, "init:\nupdate:\n", "asm") != "", "missing free label reported")
	check(pr.set_arcade_game(174, "func frame\nfoo\nend\n").begins_with("line 2:"), "script error reported with its line")
	check(pr.set_arcade_game(174, ArcadeExt.TEST_CARD, "asm") == "", "test card on 174")
	check(pr.arcade_game(174).lang == "asm", "stored as asm")
	check(pr.arcade_games().size() == 1 and pr.has_arm9_edits(), "listed, ARM9 edit")
	# moved into the view of the start camera (Sim at (28, 0, 40) looking to -z), screen towards the camera
	var ee := pr.edit_item(24, 0, 0, 23, 28, null, 22, 180, null, {"prop": 174})
	check(ee == "", "location 24 cabinet -> 174 " + ee)

	var m := pr.arm9_mod()
	check(m.error == "", "install: " + m.error)
	var tab := m.read_u32(ArcadeExt.TABLE_LITERALS[0]) - 4   # 0x02029414 holds TABLE + 0 ... check below
	var base := -1
	for at in ArcadeExt.TABLE_LITERALS:
		var v := m.read_u32(at)
		check(v >= Arm9Mod.EXT_BASE, "literal 0x%08X moved (0x%08X)" % [at, v])
		if base < 0 or v < base:
			base = v
	tab = base
	for t in ArcadeExt.OLD_TYPES:
		check(m.read(tab + 12 * t, 12) == m0.read(ArcadeExt.TABLE + 12 * t, 12), "type %d entry kept" % t)
	check(m.read_u32(ArcadeExt.FREE_PROPS[174]) == (ArcadeExt.MOV_R3_0 | 10), "prop 174 -> type 10")
	check(m.read_u32(ArcadeExt.FREE_PROPS[175]) == ArcadeExt.MOV_R3_0, "prop 175 untouched")
	var init := m.read_u32(tab + 120)
	var upd := m.read_u32(tab + 124)
	var fre := m.read_u32(tab + 128)
	check(init >= Arm9Mod.EXT_BASE and upd > init and fre > upd, "type 10 functions in the extension")

	# for capstone: the whole extension + where things are
	var f := FileAccess.open(out_dir.path_join("arcade_ext.bin"), FileAccess.WRITE)
	f.store_buffer(m.ext)
	f.close()
	f = FileAccess.open(out_dir.path_join("arcade_ext.txt"), FileAccess.WRITE)
	f.store_string("base 0x%08X\ntable 0x%08X\ninit 0x%08X\nupdate 0x%08X\nfree 0x%08X\n" % [Arm9Mod.EXT_BASE, tab, init, upd, fre])
	f.close()

	# --- test ROM -----------------------------------------------------------------------------------------------
	var e := pr.export_rom(out_dir.path_join("arcade_card.nds"), [24, 0])
	check(e == "", "test ROM export " + e)
	var gd2 := GameData.new()
	check(gd2.open(out_dir.path_join("arcade_card.nds")), "test ROM opens")
	var m2 := Arm9Mod.new(gd2.a9)
	check(m2.read_u32(ArcadeExt.FREE_PROPS[174]) == (ArcadeExt.MOV_R3_0 | 10), "exported ARM9 has the 174 patch")
	check(pr.set_arcade_game(174, "") == "" and pr.arcade_games().is_empty(), "game removed")

	# --- script games (VM) ----------------------------------------------------------------------------------------
	var vm0 := ArcadeExt.install_vm(Arm9Mod.new(gd.a9))
	check(not vm0.has("error"), "VM assembles: %s" % vm0.get("error", "%d bytes" % vm0.get("size", 0)))
	if not vm0.has("error"):
		var mvm := Arm9Mod.new(gd.a9)
		var rvm := ArcadeExt.install_vm(mvm)
		# the op table matches the opcodes of the reference VM
		var labs: Dictionary = rvm.labels
		var consts: Dictionary = (ArcadeVM as Script).get_script_constant_map()
		var named := {}
		for n in ["RET", "PUSHB", "PUSHH", "PUSHW", "LOAD", "STORE", "LOADX", "STOREX", "JMP", "JZ", "JNZ", "CALL",
				"POP", "DUP", "ADD", "SUB", "MUL", "DIV", "MOD", "AND", "OR", "XOR", "SHL", "SHR", "NEG", "NOT", "BNOT",
				"EQ", "NE", "LT", "LE", "GT", "GE", "CLS", "SPR", "RECT", "PIX", "TEXT", "NUM", "SFX", "PAL", "HELD",
				"PRESSED", "RND", "ABS", "MIN", "MAX", "HIT", "PEEK"]:
			named[consts[n]] = "op_" + n.to_lower()
		var bad_ops := []
		for i in ArcadeVM.NOPS:
			var want: String = named.get(i, "vm_stop")
			if mvm.read_u32(labs.vm_optab + 4 * i) != labs.get(want, -1):
				bad_ops.append("0x%02X" % i)
		check(bad_ops.is_empty(), "op table = opcodes of ArcadeVM %s" % str(bad_ops))
		f = FileAccess.open(out_dir.path_join("arcade_vm.bin"), FileAccess.WRITE)
		f.store_buffer(mvm.read(rvm.addr, rvm.size))
		f.close()
		f = FileAccess.open(out_dir.path_join("arcade_vm.txt"), FileAccess.WRITE)
		f.store_string("base 0x%08X\n" % rvm.addr)
		for l in rvm.labels:
			f.store_string("%s 0x%08X\n" % [l, rvm.labels[l]])
		f.close()
	for rom in [["arcade_self.nds", SELFTEST], ["arcade_lander.nds", ArcadeExamples.LANDER], ["arcade_sfx.nds", SFXTEST]]:
		var es := pr.set_arcade_game(174, rom[1])
		check(es == "", "script game on 174 (%s) %s" % [rom[0], es])
		var ms := pr.arm9_mod()
		check(ms.error == "", "install: " + ms.error)
		var ee2 := pr.export_rom(out_dir.path_join(rom[0]), [24, 0])
		check(ee2 == "", "export " + rom[0] + " " + ee2)
		# where the game block is (for the emulator comparison)
		var t0 := 0x7FFFFFFF
		for at in ArcadeExt.TABLE_LITERALS:
			t0 = mini(t0, ms.read_u32(at))
		var thunk := ms.read_u32(t0 + 120)
		var gblk := ms.read_u32(thunk + 24)  # literal pool after the 6 thunk instructions
		check(ms.read_u32(gblk + 0) > gblk and ms.read(gblk + 0xC, 2).decode_u16(0) == ArcadeScript.compile(rom[1]).nsprites,
			"game block 0x%08X" % gblk)
		f = FileAccess.open(out_dir.path_join(rom[0].get_basename() + ".txt"), FileAccess.WRITE)
		f.store_string("block 0x%08X\ninit 0x%08X\n" % [gblk, thunk])
		f.close()
	f = FileAccess.open(out_dir.path_join("selftest.txt"), FileAccess.WRITE)
	f.store_string(SELFTEST)
	f.close()
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)


## Deterministic program using every opcode (no rnd, no sfx): the ARM VM in the emulator must draw exactly what
## ArcadeVM draws for the same tick (tests/arcade_vm_ref.gd).
const SELFTEST := """palette #000000, #FF0000, #00FF00, #FFFFFF
sprite a
3.......2......1
.33....22.....11
..333..2.2...1.1
...3333...2.1..1
1111.....2.2...3
.2.2.....2..2..3
..3.3...2....2.3
...1.1.2......23
end
var i, j, k, acc, arr[20], t2

func down
  k -= 1
  acc += k * k
  if k > 0
    down
  end
end

func frame
  cls tick & 3
  acc = 0
  for i = -20 to 20 step 3
    arr[(i + 20) / 3] = i * tick - 7
    acc += (i * 1000 + tick) / (i - 2) + (tick * 37) % (i + 25) - (i << (tick & 7)) + (-i >> 2)
    acc += tick / (i - i) + tick % (i - i) + (-tick * 7) / 4 + (-tick * 7) % 4
  end
  acc ^= ~tick
  acc += tick * 123456789 * 99
  k = 18
  down
  num acc, 2, 2, 3
  num -tick * 12345, 2, 10, 2
  num arr[tick % 14], 2, 18, 1, 2
  num arr[-1] + arr[25], 64, 18, 1
  text "HELLO, world! 0123456789\\n?!:-+=()[]_#$%&'*/<>@^", 2, 30, 3
  text "big", 60, 50, 2, 3
  for j = 0 to 5
    spr a, (tick * 3 + j * 23) % 150 - 16, 60 + j * 9, j & 3
  end
  spr 1, 0, 0
  spr -1, 0, 0
  rect tick % 140 - 10, 100, 20, 10, 1
  rect -3, -3, 8, 8, 2
  rect 120, 120, 50, 50, 3
  pix tick % 128, 127, 3
  t2 = peek(tick % 128, 127) * 100 + peek(200, 5) + hit(tick, 0, 10, 10, 50, 0, 5, 5) * 10
  num t2, 90, 2, 1
  num min(tick, 50) + max(-tick, -30) + abs(-tick), 90, 10, 2
  num held(0xFFF) + pressed(0) * 1000, 90, 18, 3
  if tick % 2 == 0 and tick % 3 == 0 or tick % 7 == 0
    rect 120, 0, 8, 8, 2
  end
  if not (tick & 4)
    pal 2, tick * 1000
  end
end
"""


## Every named sound in turn (one every 30 ticks) and, every frame, ids both VMs must ignore (past the table,
## negative, a looping ambience): the emulator run checks that the ARM VM keeps going (tick, n) without a crash.
const SFXTEST := """palette #000000, #555555, #AAAAAA, #FFFFFF
var ids[17]
var n, bad
func init
  ids[0] = SFX_BOUNCE
  ids[1] = SFX_LOST
  ids[2] = SFX_BLIP
  ids[3] = SFX_COPTER
  ids[4] = SFX_CATCH
  ids[5] = SFX_MISS
  ids[6] = SFX_LAUNCH
  ids[7] = SFX_LASER
  ids[8] = SFX_BREAK
  ids[9] = SFX_PADDLE
  ids[10] = SFX_ENEMY_SHOT
  ids[11] = SFX_EXPLODE
  ids[12] = SFX_SHOOT
  ids[13] = SFX_EXTRA1
  ids[14] = SFX_EXTRA2
  ids[15] = SFX_COIN
  ids[16] = SFX_CLACK
  n = 0
end
func frame
  cls 0
  bad = 0x29
  sfx bad
  sfx bad + 700
  sfx -bad
  if attract
    return
  end
  if tick % 30 == 0
    sfx ids[n % 17]
    n += 1
  end
  text "SFX", 4, 4, 3
  num n, 4, 14, 2
  num ids[(n + 16) % 17], 4, 24, 1
  num tick, 4, 34, 1
end
"""
