extends SceneTree
## ArmAsm checks.
##   Godot --headless --path godot --script res://tests/test_armasm.gd -- out_dir
## Writes out_dir/armasm.bin + out_dir/armasm_expect.txt (one capstone line per instruction word, base 0x02200000);
## tools/check_armasm.py compares them with capstone (independent decoder).

const BASE := 0x02200000

# [source line, expected capstone text ("mnemonic op_str")]; a label "start" is at BASE.
const CASES := [
	["mov r0, #1", "mov r0, #1"],
	["mov r0, #0x1000", "mov r0, #0x1000"],
	["mov r1, #0xFFFFFFFF", "mvn r1, #0"],
	["mvn r2, #0xFF00", "mvn r2, #0xff00"],
	["movs r3, r4", "movs r3, r4"],
	["moveq r3, r4, lsl #2", "lsleq r3, r4, #2"],
	["mov r3, r4, asr r5", "asr r3, r4, r5"],
	["lsl r0, r1, #3", "lsl r0, r1, #3"],
	["lsrs r0, r1, #1", "lsrs r0, r1, #1"],
	["add r0, r1, #0x1A4", "add r0, r1, #0x1a4"],
	["add r0, r1, #-4", "sub r0, r1, #4"],
	["add r0, #8", "add r0, r0, #8"],
	["sub r0, r1, r2, lsl #4", "sub r0, r1, r2, lsl #4"],
	["rsb r0, r0, #0", "rsb r0, r0, #0"],
	["and r0, r0, #3", "and r0, r0, #3"],
	["and r0, r0, #0xFFFFFF00", "bic r0, r0, #0xff"],
	["orrne r1, r1, r2, lsr #8", "orrne r1, r1, r2, lsr #8"],
	["eors r1, r2, r3", "eors r1, r2, r3"],
	["cmp r0, #0x80", "cmp r0, #0x80"],
	["cmp r0, #-1", "cmn r0, #1"],
	["tst r1, #0x20", "tst r1, #0x20"],
	["cmp r2, r3", "cmp r2, r3"],
	["mul r0, r1, r2", "mul r0, r1, r2"],
	["mla r0, r1, r2, r3", "mla r0, r1, r2, r3"],
	["smull r0, r1, r2, r3", "smull r0, r1, r2, r3"],
	["clz r0, r1", "clz r0, r1"],
	["ldr r0, [r1]", "ldr r0, [r1]"],
	["ldr r0, [r1, #4]", "ldr r0, [r1, #4]"],
	["ldr r0, [r1, #-4]", "ldr r0, [r1, #-4]"],
	["ldr r0, [r1, #4]!", "ldr r0, [r1, #4]!"],
	["ldr r0, [r1], #4", "ldr r0, [r1], #4"],
	["str r0, [sp, #8]", "str r0, [sp, #8]"],
	["ldrb r0, [r1, r2]", "ldrb r0, [r1, r2]"],
	["strb r0, [r1, -r2]", "strb r0, [r1, -r2]"],
	["ldr r0, [r1, r2, lsl #2]", "ldr r0, [r1, r2, lsl #2]"],
	["ldreqb r0, [r1]", "ldrbeq r0, [r1]"],
	["ldrh r0, [r1, #0x1A]", "ldrh r0, [r1, #0x1a]"],
	["strh r0, [r1, r2]", "strh r0, [r1, r2]"],
	["ldrsb r0, [r1, #-1]", "ldrsb r0, [r1, #-1]"],
	["ldrsh r0, [r1]", "ldrsh r0, [r1]"],
	["push {r4-r7, lr}", "push {r4, r5, r6, r7, lr}"],
	["pop {r4-r7, pc}", "pop {r4, r5, r6, r7, pc}"],
	["ldmia r0!, {r1, r2}", "ldm r0!, {r1, r2}"],
	["stmdb sp!, {r0}", "stmdb sp!, {r0}"],
	["stmia r3, {r0-r2}", "stm r3, {r0, r1, r2}"],
	["bx lr", "bx lr"],
	["blx r3", "blx r3"],
	["b start", "b #0x2200000"],
	["bne start", "bne #0x2200000"],
	["bls start", "bls #0x2200000"],
	["bl 0x020BBDE8", "bl #0x20bbde8"],
	["bleq FUNC", "bleq #0x2046880"],
	["ldr r0, =0x02139E8C", "ldr r0, [pc, #0xc]"],
	["ldr r1, =FUNC + 4", "ldr r1, [pc, #0xc]"],
	["ldr r2, =0x02139E8C", "ldr r2, [pc, #4]"],
	["adr r3, data", "add r3, pc, #8"],
	["nop", "mov r0, r0"],
]


func _init() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var fails := 0
	var src := "start:\n"
	for c in CASES:
		src += "\t" + c[0] + "\n"
	src += "\t.pool\ndata:\n\t.word data, 0x12345678\n\t.byte 1, 2, 'A'\n\t.align 4\n\t.hword 0xBEEF\n"
	var a := ArmAsm.new()
	var bin := a.assemble(src, BASE, {"FUNC": 0x02046880})
	if bin.is_empty():
		print("FAIL assemble: ", a.error)
		quit(1)
		return
	var n := CASES.size()
	# literal pool: 2 distinct values (0x02139E8C deduped, FUNC + 4), then data
	var pool := BASE + 4 * n
	fails += _check(bin.decode_u32(4 * n) == 0x02139E8C, "pool word 0")
	fails += _check(bin.decode_u32(4 * n + 4) == 0x02046884, "pool word 1 (FUNC + 4)")
	fails += _check(a.labels["data"] == pool + 8, "label after the pool")
	fails += _check(bin.decode_u32(4 * n + 8) == pool + 8, ".word label")
	fails += _check(bin.decode_u32(4 * n + 12) == 0x12345678, ".word number")
	fails += _check(bin[4 * n + 16] == 1 and bin[4 * n + 18] == 65, ".byte")
	fails += _check(bin.decode_u16(4 * n + 20) == 0xBEEF, ".align + .hword")
	# errors
	for bad in ["mov r0, #0x101", "ldr r0, [r1, #4096]", "foo r1", "b nowhere", "add r0, r1, r16"]:
		var b := ArmAsm.new()
		fails += _check(b.assemble(bad, BASE).is_empty() and b.error != "", "refused: " + bad + " -> " + b.error)
	# expected listing for capstone
	var f := FileAccess.open(out_dir.path_join("armasm.bin"), FileAccess.WRITE)
	f.store_buffer(bin.slice(0, 4 * n))
	f.close()
	var exp := ""
	for c in CASES:
		exp += c[1] + "\n"
	f = FileAccess.open(out_dir.path_join("armasm_expect.txt"), FileAccess.WRITE)
	f.store_string(exp)
	f.close()
	print("%d failure(s)" % fails)
	quit(1 if fails else 0)


func _check(ok: bool, what: String) -> int:
	print("  ", "ok   " if ok else "FAIL ", what)
	return 0 if ok else 1
