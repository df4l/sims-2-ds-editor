extends SceneTree
## Reference screen of an arcade script after N frames (for comparing the ARM VM in the emulator):
##   Godot --headless --path godot --script res://tests/arcade_vm_ref.gd -- script.txt frames held out.bin
## Runs init (not attract), then `frames` frames with no key except `held` on the last one. Writes the 0x1000-byte
## screen buffer, then the 4 palette colours (u16) and vars[0..255] (s32).


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var p := ArcadeScript.compile(FileAccess.get_file_as_string(a[0]))
	if p.has("error"):
		print("compile: line %d: %s" % [p.line, p.error])
		quit(2)
		return
	var vm := ArcadeVM.new()
	vm.load(p)
	vm.start(false)
	var n := int(a[1])
	for i in n:
		vm.frame(int(a[2]) if i == n - 1 else 0, 0)
	var out := vm.screen.duplicate()
	for c in vm.pal:
		var b := PackedByteArray([c & 0xFF, c >> 8])
		out.append_array(b)
	var v := PackedByteArray()
	v.resize(4 * ArcadeVM.NVARS)
	for i in ArcadeVM.NVARS:
		v.encode_s32(4 * i, vm.vars[i])
	out.append_array(v)
	var f := FileAccess.open(a[3], FileAccess.WRITE)
	f.store_buffer(out)
	f.close()
	print("ok tick=%d stopped='%s' ops=%d" % [vm.vars[1], vm.stopped, vm.ops])
	quit(0)
