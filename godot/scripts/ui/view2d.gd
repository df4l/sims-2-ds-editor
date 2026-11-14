extends Control
## Top-down view: x to the right, z down (same orientation as tools/bsp.py png).
## Left drag pans, or moves the selected item when the drag starts on it. Wheel zooms. Click selects.
## Right / middle drag also pans.

var ed   # main.gd
var cx := 0.0
var cz := 0.0
var scale_px := 2.0
var drag := {}
var ghost := {}     # {key, x, z, step}
var hover_world := Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP


func to_s(x: float, z: float) -> Vector2:
	return Vector2((x - cx) * scale_px + size.x / 2, (z - cz) * scale_px + size.y / 2)


func to_w(p: Vector2) -> Vector2:
	return Vector2(cx + (p.x - size.x / 2) / scale_px, cz + (p.y - size.y / 2) / scale_px)


func fit() -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for b in ed.brushes2d:
		for p in b.poly:
			lo = lo.min(p)
			hi = hi.max(p)
	for it in ed.items:
		lo = lo.min(Vector2(it.x, it.z))
		hi = hi.max(Vector2(it.x, it.z))
	if lo.x == INF:
		return
	cx = (lo.x + hi.x) / 2
	cz = (lo.y + hi.y) / 2
	var w := maxf(size.x, 100)
	var h := maxf(size.y, 100)
	scale_px = 0.92 * minf(w / maxf(hi.x - lo.x, 1), h / maxf(hi.y - lo.y, 1))
	queue_redraw()


func center_on(x: float, z: float) -> void:
	cx = x
	cz = z
	queue_redraw()


func _item_pos(it: Dictionary) -> Vector2:
	if not ghost.is_empty() and ghost.key == it.key:
		return Vector2(ghost.x, ghost.z)
	return Vector2(it.x, it.z)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#18181f"))
	if ed == null or ed.gd == null:
		return
	var font := get_theme_default_font()
	if ed.show_bsp:
		for b in ed.brushes2d:
			if b.poly.size() < 3:
				continue
			var pts := PackedVector2Array()
			for p in b.poly:
				pts.append(to_s(p.x, p.y))
			draw_colored_polygon(pts, b.col)
			pts.append(pts[0])
			draw_polyline(pts, Color(0, 0, 0, 0.8), 1.0)
		if ed.cell != null:
			for b in ed.brushes2d:
				if b.brush == ed.cell and b.poly.size() >= 3:
					var pts := PackedVector2Array()
					for p in b.poly:
						pts.append(to_s(p.x, p.y))
					draw_colored_polygon(pts, Color(1, 1, 1, 0.25))
					pts.append(pts[0])
					draw_polyline(pts, Color.WHITE, 2.0)
	if ed.mode == "cells":
		return
	for it in ed.items:
		var p := _item_pos(it)
		var s := to_s(p.x, p.y)
		if s.x < -200 or s.y < -200 or s.x > size.x + 200 or s.y > size.y + 200:
			continue
		var col: Color = W.color_of(it.type)
		var sel: bool = it.key == ed.sel
		if it.half_size != null:
			var hs: Vector3 = it.half_size
			draw_rect(Rect2(s - Vector2(hs.x, hs.z) * scale_px, Vector2(hs.x, hs.z) * 2 * scale_px), col, false, 3.0 if sel else 1.5)
		if it.angle != null:
			# ASSUMED: angle 0 faces +z, positive angles turn towards +x
			draw_line(s, s + 12 * Vector2(sin(it.angle), cos(it.angle)), col, 2.0)
		var r := 6.0 if sel else 4.0
		draw_circle(s, r, col)
		draw_arc(s, r, 0, TAU, 16, Color.WHITE if sel else Color.BLACK, 2.0 if sel else 1.0)
		if ed.show_labels or sel:
			draw_string(font, s + Vector2(7, -5), it.label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	if ed.placing:
		var m := to_s(hover_world.x, hover_world.y)
		draw_circle(m, 5, W.color_of(ed.pal_type))
		draw_string(font, m + Vector2(8, -6), "click to place (Esc cancels)", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


func item_at(p: Vector2):
	var best = null
	var bd := 10.0
	for it in ed.items:
		var d := to_s(it.x, it.z).distance_to(p)
		if d < bd:
			bd = d
			best = it
	return best


func _gui_input(e: InputEvent) -> void:
	if ed == null or ed.gd == null:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var f := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 / 1.15
				var w := to_w(mb.position)
				scale_px = clampf(scale_px * f, 0.05, 200)
				cx = w.x - (mb.position.x - size.x / 2) / scale_px
				cz = w.y - (mb.position.y - size.y / 2) / scale_px
				queue_redraw()
			accept_event()
			return
		if mb.pressed:
			grab_focus()
			var hit = item_at(mb.position) if mb.button_index == MOUSE_BUTTON_LEFT and ed.mode == "items" else null
			var moving = hit if hit != null and hit.key == ed.sel else null
			drag = {"start": mb.position, "cx": cx, "cz": cz, "moved": false, "item": moving,
				"button": mb.button_index, "ox": hit.x if hit != null else 0.0, "oz": hit.z if hit != null else 0.0}
		elif not drag.is_empty():
			var d := drag
			drag = {}
			if d.item != null and d.moved:
				var g := ghost
				ghost = {}
				ed.on_2d_moved(d.item, g)
				queue_redraw()
				return
			if d.moved or d.button != MOUSE_BUTTON_LEFT:
				return
			var w := to_w(mb.position)
			if ed.placing and ed.mode == "items":
				ed.on_2d_place(w.x, w.y)
			elif ed.mode == "cells":
				ed.on_2d_cell(w.x, w.y)
			else:
				var it = item_at(mb.position)
				ed.select(it.key if it != null else "")
		accept_event()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		hover_world = to_w(mm.position)
		if ed.placing:
			queue_redraw()
		if drag.is_empty():
			return
		var dv: Vector2 = mm.position - drag.start
		if absf(dv.x) + absf(dv.y) > 3:
			drag.moved = true
		if not drag.moved:
			return
		if drag.item != null:
			var it: Dictionary = drag.item
			ghost = {"key": it.key, "x": drag.ox + dv.x / scale_px, "z": drag.oz + dv.y / scale_px, "step": Vector2i.ZERO}
			if it.kind == "furniture":
				_snap_furniture(it)
			else:
				ed.status("move to x %d, z %d" % [roundi(ghost.x), roundi(ghost.z)])
		else:
			cx = drag.cx - dv.x / scale_px
			cz = drag.cz - dv.y / scale_px
		queue_redraw()


## Furniture moves by whole grid cells; a wall prop only along its wall.
func _snap_furniture(it: Dictionary) -> void:
	var g: float = RoomFurn.CELL
	var sx := roundi((ghost.x - it.x) / g)
	var sz := roundi((ghost.z - it.z) / g)
	if it.wall:
		var along := sz if it.along == "z" else sx
		ghost.step = Vector2i(0, along)
		ghost.x = it.x + (along if it.along == "x" else 0) * g
		ghost.z = it.z + (along if it.along == "z" else 0) * g
		ed.status("wall slot %d, cell %d" % [it.cell.x, it.cell.y + along])
	else:
		ghost.step = Vector2i(sx, sz)
		ghost.x = it.x + sx * g
		ghost.z = it.z + sz * g
		ed.status("cell %d, %d" % [it.cell.x + sx, it.cell.y + sz])
