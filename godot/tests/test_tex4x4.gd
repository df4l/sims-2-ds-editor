extends SceneTree
## 4x4 texture encoder (Tex4x4) checks:
##   Godot --headless --path godot --script res://tests/test_tex4x4.gd -- rom.nds [max textures per kind]
## 1. the game's own 4x4 textures (scene models), decoded, re-encoded with the number of pairs the game's file uses
##    for that texture: error vs the decoded original (the game's encoding reaches 0);
## 2. the game's 8bpp textures, encoded as 4x4: error vs the 8bpp source, next to the 8bpp re-encode (exact) and a
##    4bpp re-encode (16 colours, median cut) as a lossy reference;
## 3. encode -> Nsbmd._decode_4x4 gives back what the encoder measured (format written as the hardware reads it).
## Errors are RMS per texel in 8-bit units (alpha < 128 texels ignored) and PSNR.

var fails := 0


func check(cond: bool, what: String) -> void:
	print("  ", "ok   " if cond else "FAIL ", what)
	if not cond:
		fails += 1


static func rms(a: Image, b: Image) -> float:
	var da := a.get_data()
	var db := b.get_data()
	var e := 0.0
	var n := 0
	for i in a.get_width() * a.get_height():
		if da[4 * i + 3] < 128:
			continue
		for k in 3:
			var d := float(da[4 * i + k]) - float(db[4 * i + k])
			e += d * d
		n += 3
	return sqrt(e / maxi(1, n))


static func psnr(r: float) -> float:
	return 99.0 if r < 1e-3 else 20.0 * log(255.0 / r) / log(10.0)


## Decode a Tex4x4 result with the reader's decoder (as the hardware reads the format).
static func decode(enc: Dictionary, w: int, h: int) -> Image:
	var nb := Nsbmd.new()
	var out := PackedByteArray()
	out.resize(w * h * 4)
	nb._decode_4x4({"w": w, "h": h, "data1": enc.data, "data2": enc.idx}, enc.palette, 0, out)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var gd := GameData.new()
	if not gd.open(args[0]):
		print("cannot open: ", gd.error)
		quit(2)
		return
	var limit := int(args[1]) if args.size() > 1 else 40
	var mset := {}
	for L in gd.locations:
		for m in L.models:
			mset[m.model] = true
	var four := []    # [name, image, pairs used by the game]
	var eight := []   # [name, image]
	for e in mset:
		var a := Nsbmd.new()
		if not a.parse(gd.rombin.data(e)):
			continue
		var pal_of := {}
		for m in a.model.materials:
			if m.texture != "" and a.palettes.has(m.palette):
				pal_of[m.texture] = a.palettes[m.palette]
		for name in a.textures:
			var t: Dictionary = a.textures[name]
			if (t.fmt != 5 and t.fmt != 4) or not pal_of.has(name):
				continue
			var pal = pal_of[name]
			var img := a.decode_texture(t, pal)
			if img == null:
				continue
			if t.fmt == 5 and four.size() < limit:
				var used := {}
				for k in t.data2.size() / 2:
					used[t.data2.decode_u16(2 * k) & 0x3FFF] = true
				four.append(["%d:%s" % [e, name], img, used.size()])
			elif t.fmt == 4 and eight.size() < limit:
				eight.append(["%d:%s" % [e, name], img])
	print("textures: %d 4x4, %d 8bpp" % [four.size(), eight.size()])

	# --- 1. game 4x4 re-encoded ---
	var t0 := Time.get_ticks_msec()
	var sum := 0.0
	var worst := 0.0
	var mismatch := 0
	for x in four:
		var img: Image = x[1]
		var enc := Tex4x4.encode(img, x[2])
		var dec := decode(enc, img.get_width(), img.get_height())
		var r := rms(img, dec)
		# the encoder's own error (5-bit units, squared per texel over 3 channels) must match the decode
		var own := sqrt(enc.err / 3.0) * 255.0 / 31.0
		if absf(own - r) > 1.5:
			mismatch += 1
		sum += r
		worst = maxf(worst, r)
		if r > 6.0:
			print("    %s %dx%d pairs %d/%d rms %.2f" % [x[0], img.get_width(), img.get_height(), enc.pairs, x[2], r])
	var n4 := maxi(1, four.size())
	print("  game 4x4 re-encoded: mean rms %.2f (PSNR %.1f dB), worst %.2f, %d ms" % [sum / n4, psnr(sum / n4), worst,
		Time.get_ticks_msec() - t0])
	check(sum / n4 < 4.0, "game 4x4 textures re-encoded with the game's pair count: mean rms < 4")
	check(mismatch == 0, "encoder error = decoded error (%d mismatch)" % mismatch)

	# --- 2. 8bpp textures as 4x4 ---
	t0 = Time.get_ticks_msec()
	var s4 := 0.0
	var s16 := 0.0
	var pairs := 0
	for x in eight:
		var img: Image = x[1]
		var nbk := img.get_width() * img.get_height() / 16
		var enc := Tex4x4.encode(img, maxi(16, nbk / 8))
		pairs += enc.pairs
		s4 += rms(img, decode(enc, img.get_width(), img.get_height()))
		var p16 := NsbmdWriter.encode_texture(img, 1024, 16)
		var nb := Nsbmd.new()
		var d16 := nb.decode_texture({"fmt": p16.fmt, "w": p16.w, "h": p16.h, "data1": p16.data, "params": (1 << 29) if p16.color0 else 0},
			{"off": 0, "block": p16.palette})
		s16 += rms(img, d16)
	var n8 := maxi(1, eight.size())
	print("  8bpp as 4x4 (pairs = blocks / 8): mean rms %.2f (PSNR %.1f dB), %d pairs; 4bpp median cut: rms %.2f; %d ms" % [
		s4 / n8, psnr(s4 / n8), pairs, s16 / n8, Time.get_ticks_msec() - t0])
	check(s4 < s16, "4x4 closer to the source than 16-colour palettes")

	# --- 3. transparency: mode 1 blocks keep alpha ---
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			img.set_pixel(x, y, Color(x / 15.0, y / 15.0, 0.5, 0.0 if (x + y) % 5 == 0 else 1.0))
	var enc := Tex4x4.encode(img, 64)
	var dec := decode(enc, 16, 16)
	var alpha_ok := true
	for y in 16:
		for x in 16:
			if (dec.get_pixel(x, y).a < 0.5) != ((x + y) % 5 == 0):
				alpha_ok = false
	check(alpha_ok, "transparent texels stay transparent, opaque ones opaque (rms %.2f)" % rms(img, dec))

	print("FAILS: %d" % fails)
	quit(1 if fails else 0)
