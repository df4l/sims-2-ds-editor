class_name SimsTab
extends MarginContainer
## Sims tab: the player Sim's starting look (docs/formats/sim.md). The 3D preview is built like Sim_ApplyAppearance
## does in game (hair / torso / legs nodes, head / torso / legs textures, palette ranges). Every change is saved at
## once (undo with Ctrl+Z) and written into the ARM9 at export (SimLook.install): a new game, and Test ▶, start with
## this look. Create-a-Sim still offers its own choices, starting from it.

const STYLE_NAMES := [["A", "B", "C", "D", "E", "F", "G", "H"], ["A", "B", "C"], ["A", "B", "C", "D"]]

var ed
var model := SimLook.FEMALE
var sex_opt: OptionButton
var style_opts := []      # OptionButton per SimLook.NODES row
var tex_opts := []        # OptionButton per SimLook.TEXTURES row
var col_opts := []        # OptionButton per SimLook.COLORS row
var info: Label
var view: SubViewportContainer
var vp := SubViewport.new()
var cam := Camera3D.new()
var holder := Node3D.new()
var yaw := 0.0
var pitch := -0.15
var dist := 30.0
var target := Vector3(0, 6, 0)
var _drag := false
var _busy := false
var _shown_sig := ""


func _init() -> void:
	name = "Sims"
	for s in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + s, 8)


func _ready() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	sex_opt = OptionButton.new()
	sex_opt.add_item("Female Sim (FemSim)", SimLook.FEMALE)
	sex_opt.add_item("Male Sim (MalSim)", SimLook.MALE)
	sex_opt.item_selected.connect(func(i):
		model = sex_opt.get_item_id(i)
		refresh())
	v.add_child(W.hbox([W.label("Starting look", W.MUTED, false), sex_opt,
		W.button("Reset", _reset, "Back to the game's own starting look of this Sim")]))
	info = W.label("", W.MUTED)
	v.add_child(info)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(split)
	view = SubViewportContainer.new()
	view.stretch = true
	view.custom_minimum_size = Vector2(240, 320)
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.tooltip_text = "Drag to turn, wheel to zoom"
	view.gui_input.connect(_view_input)
	split.add_child(view)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	view.add_child(vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("#18181f")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	vp.add_child(env)
	cam.fov = 40
	cam.near = 0.2
	cam.far = 500
	vp.add_child(cam)
	vp.add_child(holder)

	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size.x = 250
	split.add_child(sc)
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 8)
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(form)
	for k in SimLook.NODES.size():
		var o := OptionButton.new()
		o.item_selected.connect(func(i): _set_style(k, i))
		form.add_child(W.label(SimLook.NODES[k][1] + " style", null, false))
		form.add_child(o)
		style_opts.append(o)
	for k in SimLook.TEXTURES.size():
		var o := OptionButton.new()
		o.item_selected.connect(func(i): _set_texture(k, o.get_item_id(i)))
		o.expand_icon = false
		form.add_child(W.label(SimLook.TEXTURES[k][1] + " texture", null, false))
		form.add_child(o)
		tex_opts.append(o)
	for k in SimLook.COLORS.size():
		var o := OptionButton.new()
		o.item_selected.connect(func(i): _set_color(k, o.get_item_id(i)))
		form.add_child(W.label(SimLook.COLORS[k][1], null, false))
		form.add_child(o)
		col_opts.append(o)
	_update_cam()


func reset() -> void:
	_shown_sig = ""
	for c in holder.get_children():
		c.queue_free()


## Called by the editor after ROM open, edits and undo.
func refresh() -> void:
	if ed == null or ed.proj == null or sex_opt == null:
		return
	var r: PackedByteArray = ed.proj.sim_look(model)
	var edited: bool = ed.proj.is_edited("sim", model)
	info.text = ("Edited: a new game starts with this look (also Test ▶)." if edited
		else "The game's own starting look. Changes are saved at once and go into the ARM9 at export.") \
		+ " Top / bottom colour names are assumed (docs/formats/sim.md)."
	if not is_visible_in_tree():
		_shown_sig = ""
		return
	var sig := "%d:%s" % [model, r.hex_encode()]
	if sig == _shown_sig:
		return
	_shown_sig = sig
	_busy = true
	var nb := Nsbmd.new()
	nb.parse(ed.gd.rombin.data(ed.gd.npc_model(model)))
	SimLook.apply(ed.gd, nb, model, r)
	for k in SimLook.NODES.size():
		var o: OptionButton = style_opts[k]
		o.clear()
		for i in SimLook.NODES[k][2]:
			o.add_item(STYLE_NAMES[k][i], i)
		o.select(SimLook.style(r, k))
	var lists := SimLook.cas_textures(ed.gd, model)
	for k in SimLook.TEXTURES.size():
		var o: OptionButton = tex_opts[k]
		o.clear()
		var cur := SimLook.u16(r, SimLook.TEXTURES[k][0])
		var lst: Array = lists[["head", "torso", "legs"][k]].duplicate()
		if not lst.has(cur) and cur != SimLook.NONE:
			lst.push_front(cur)
		for e in lst:
			var img := SimLook.texture_image(ed.gd, nb, SimLook.TEXTURES[k][2], e)
			if img != null:
				img.resize(32, 32, Image.INTERPOLATE_NEAREST)
				o.add_icon_item(ImageTexture.create_from_image(img), "%d" % e, e)
			else:
				o.add_item("%d" % e, e)
			if e == cur:
				o.select(o.item_count - 1)
	for k in SimLook.COLORS.size():
		var o: OptionButton = col_opts[k]
		var c: Array = SimLook.COLORS[k]
		o.clear()
		o.add_item("model's own", SimLook.NONE)
		for i in c[2]:
			o.add_icon_item(_swatch(SimLook.swatch(ed.gd, c, i)), "%d" % i, i)
		var cur := SimLook.u16(r, c[0])
		o.select(0 if cur == SimLook.NONE else cur + 1)
	# skin B only counts when skin A is set (Sim_ApplyAppearance)
	(col_opts[1] as OptionButton).disabled = SimLook.u16(r, 0x12) == SimLook.NONE
	_busy = false
	for ch in holder.get_children():
		ch.queue_free()
	var mi := nb.build()
	if mi != null:
		holder.add_child(mi)
		var bb := mi.get_aabb()
		target = bb.get_center()
		dist = maxf(bb.size.y, 4.0) * 1.9
		_update_cam()


static func _swatch(cols: Array) -> ImageTexture:
	var img := Image.create(24, 12, false, Image.FORMAT_RGB8)
	if cols.is_empty():
		return ImageTexture.create_from_image(img)
	for x in 24:
		var c: Color = cols[mini(cols.size() - 1, x * cols.size() / 24)]
		for y in 12:
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func _edit(f: Callable) -> void:
	if _busy or ed == null or ed.proj == null:
		return
	var r: PackedByteArray = ed.proj.sim_look(model).duplicate()
	f.call(r)
	var e: String = ed.proj.set_sim_look(model, r)
	if e != "":
		ed.status("Sim look not changed: " + e)
	else:
		ed.status("Starting look of the %s Sim changed" % ("female" if model == SimLook.FEMALE else "male"))
		ed._show_edited()
	refresh()


func _set_style(k: int, i: int) -> void:
	_edit(func(r): SimLook.set_style(r, k, i))


func _set_texture(k: int, entry: int) -> void:
	_edit(func(r): SimLook.set_u16(r, SimLook.TEXTURES[k][0], entry))


func _set_color(k: int, v: int) -> void:
	_edit(func(r): SimLook.set_u16(r, SimLook.COLORS[k][0], v))


func _reset() -> void:
	if ed == null or ed.proj == null:
		return
	if not ed.proj.is_edited("sim", model):
		ed.status("This Sim already has the game's own starting look")
		return
	ed.proj.set_sim_look(model, ed.proj.original("sim", model))
	ed._show_edited()
	ed.status("Starting look back to the game's own")
	refresh()


func _view_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_drag = ev.pressed
		elif ev.button_index == MOUSE_BUTTON_WHEEL_UP and ev.pressed:
			dist = maxf(dist * 0.9, 3.0)
			_update_cam()
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN and ev.pressed:
			dist = minf(dist * 1.1, 200.0)
			_update_cam()
	elif ev is InputEventMouseMotion and _drag:
		yaw -= ev.relative.x * 0.01
		pitch = clampf(pitch - ev.relative.y * 0.01, -1.4, 1.4)
		_update_cam()


func _update_cam() -> void:
	var dir := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw))
	cam.position = target + dir * dist
	cam.look_at(target, Vector3.UP)
