class_name S2Sprite
extends RefCounted
## OBJ sprite = [tiles entry][definition entry][16-colour palette entry] (docs/formats/catalog.md). Used for the
## in-game icons of NPCs and props (object info table, GameData.info_record).
## definition: u8 w, u8 h, u16 0, u16 ?, u16 frame_count, u32 tiles_size (bit 24: streamed), u16 frame_offset[n]
## frame: u8 piece_count | 0x80, u8 0, u8 w, u8 h, u16 tile_offset, s16 x0, s16 y0, [6 bytes if streamed], u32 piece[]
## piece: bits 0-8 x, 9-17 y (signed), 18-19 size, 20-21 shape, 22-31 first tile (32-byte 4bpp tiles)

const OBJ_DIM := {
	Vector2i(0, 0): Vector2i(8, 8), Vector2i(0, 1): Vector2i(16, 16), Vector2i(0, 2): Vector2i(32, 32), Vector2i(0, 3): Vector2i(64, 64),
	Vector2i(1, 0): Vector2i(16, 8), Vector2i(1, 1): Vector2i(32, 8), Vector2i(1, 2): Vector2i(32, 16), Vector2i(1, 3): Vector2i(64, 32),
	Vector2i(2, 0): Vector2i(8, 16), Vector2i(2, 1): Vector2i(8, 32), Vector2i(2, 2): Vector2i(16, 32), Vector2i(2, 3): Vector2i(32, 64),
}


static func _s9(v: int) -> int:
	return v - 512 if v & 256 else v


## First frame: {tile_offset, pieces: [[x, y, w, h, tile]]} or {}.
static func first_frame(d: PackedByteArray) -> Dictionary:
	if d.size() < 0x10:
		return {}
	var n := d.decode_u16(6)
	if n == 0 or 0xC + 2 * n > d.size():
		return {}
	var hdr := 16 if (d.decode_u32(8) >> 24) & 1 else 10
	var p := 0xC + d.decode_u16(0xC)
	if p + hdr > d.size():
		return {}
	var k := d[p] & 0x7F
	if p + hdr + 4 * k > d.size():
		return {}
	var pieces := []
	for j in k:
		var v := d.decode_u32(p + hdr + 4 * j)
		var key := Vector2i((v >> 20) & 3, (v >> 18) & 3)
		if not OBJ_DIM.has(key):
			return {}
		var dim: Vector2i = OBJ_DIM[key]
		pieces.append([_s9(v & 511), _s9((v >> 9) & 511), dim.x, dim.y, v >> 22])
	return {"tile_offset": d.decode_u16(p + 4), "pieces": pieces}


## Image of the record's icon (first frame), null if it does not decode.
static func render_icon(gd: GameData, rec: Dictionary) -> Image:
	if rec.is_empty() or not rec.icon:
		return null
	var blobs := gd.rombin.blobs(rec.tiles)
	var fr := first_frame(gd.rombin.data(rec.def))
	if blobs.is_empty() or fr.is_empty() or fr.pieces.is_empty():
		return null
	var tiles: PackedByteArray
	if blobs.size() == 1:
		tiles = blobs[0].out.slice(fr.tile_offset)
	else:
		for b in blobs:
			if b.start == fr.tile_offset:
				tiles = b.out
		if tiles.is_empty():
			return null
	var palb := gd.rombin.data(rec.pal)
	if palb.size() < 32:
		return null
	var pal := []
	for i in 16:
		var c := palb.decode_u16(2 * i)
		pal.append(Color8((c & 31) * 255 / 31, ((c >> 5) & 31) * 255 / 31, ((c >> 10) & 31) * 255 / 31, 255))
	var x0 := 1 << 20
	var y0 := 1 << 20
	var x1 := -(1 << 20)
	var y1 := -(1 << 20)
	for pc in fr.pieces:
		if (pc[4] + pc[2] * pc[3] / 64) * 32 > tiles.size():
			return null
		x0 = mini(x0, pc[0])
		y0 = mini(y0, pc[1])
		x1 = maxi(x1, pc[0] + pc[2])
		y1 = maxi(y1, pc[1] + pc[3])
	var img := Image.create_empty(x1 - x0, y1 - y0, false, Image.FORMAT_RGBA8)
	for pc in fr.pieces:
		var tw: int = pc[2] / 8
		for t in tw * (pc[3] / 8):
			var base: int = (pc[4] + t) * 32
			var ox: int = pc[0] - x0 + (t % tw) * 8
			var oy: int = pc[1] - y0 + (t / tw) * 8
			for y in 8:
				for x in 8:
					var b := tiles[base + y * 4 + x / 2]
					var v := (b >> 4) if x & 1 else (b & 15)
					if v:
						img.set_pixel(ox + x, oy + y, pal[v])
	return img
