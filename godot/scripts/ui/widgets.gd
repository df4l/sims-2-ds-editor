class_name W
extends RefCounted
## Small UI helpers shared by the editor panels.

const COLORS := {
	1: Color("#4fc3f7"), 2: Color("#ffb74d"), 3: Color("#e57373"), 4: Color("#81c784"), 5: Color("#ba68c8"),
	7: Color("#90a4ae"), 8: Color("#fff176"), 9: Color("#a1887f"), 10: Color("#ffcc80"), 11: Color("#4db6ac"),
	"entry": Color("#ffd54f"), "furniture": Color("#f06292"),
}
const NAMES := {1: "npc", 2: "prop", 3: "trigger box", 4: "door / object box", 5: "light?", 7: "box",
	8: "event watcher", 9: "waypoint", 10: "timed prop", 11: "sound", "entry": "entry point",
	"furniture": "room furniture (default)"}
const MUTED := Color(0.62, 0.64, 0.7)
const WARN := Color(1.0, 0.72, 0.35)


static func color_of(t) -> Color:
	return COLORS.get(t, Color.WHITE)


static func button(text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	return b


static func toggle(text: String, on: bool, cb: Callable, tip := "") -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.tooltip_text = tip
	c.toggled.connect(cb)
	return c


static func label(text: String, color = null, wrap := true) -> Label:
	var l := Label.new()
	l.text = text
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 120
	if color != null:
		l.add_theme_color_override("font_color", color)
	return l


static func spin(lo: float, hi: float, v: float, step := 1.0) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = v
	s.allow_greater = false
	s.allow_lesser = false
	s.custom_minimum_size.x = 84
	s.select_all_on_focus = true
	return s


static func option(items: Array, current) -> OptionButton:
	## items: [[id, text], ...]
	var o := OptionButton.new()
	o.fit_to_longest_item = false
	o.clip_text = true
	o.custom_minimum_size.x = 160
	for it in items:
		o.add_item(it[1], it[0])
		if it[0] == current:
			o.select(o.item_count - 1)
	return o


static func option_value(o: OptionButton) -> int:
	return o.get_item_id(o.selected) if o.selected >= 0 else -1


static func kv_table(rows: Array) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	for r in rows:
		var k := label(str(r[0]), MUTED, false)
		g.add_child(k)
		var v := label(str(r[1]))
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(v)
	return g


static func hbox(children: Array) -> HBoxContainer:
	var h := HBoxContainer.new()
	for c in children:
		h.add_child(c)
	return h


static func clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


static func fmt(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


## Icon grid picker (NPC / prop): search box + ItemList with the in-game icons.
class IconPicker:
	extends VBoxContainer
	signal picked(id: int)
	var options := []    # [{id, label, tip, icon: Texture2D or null}]
	var value := -1
	var list := ItemList.new()
	var search := LineEdit.new()
	var head := Label.new()

	func _init(title: String, opts: Array, v: int) -> void:
		options = opts
		value = v
		var hb := HBoxContainer.new()
		var t := Label.new()
		t.text = title
		t.add_theme_color_override("font_color", W.MUTED)
		hb.add_child(t)
		head.clip_text = true
		head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(head)
		add_child(hb)
		search.placeholder_text = "Search (id, name, model)…"
		search.clear_button_enabled = true
		search.text_changed.connect(func(_t): _fill())
		add_child(search)
		list.icon_mode = ItemList.ICON_MODE_TOP
		list.max_columns = 0
		list.same_column_width = true
		list.fixed_column_width = 76
		list.fixed_icon_size = Vector2i(40, 40)
		list.custom_minimum_size = Vector2(0, 230)
		list.max_text_lines = 2
		list.item_selected.connect(_on_sel)
		add_child(list)
		_fill()

	func _fill() -> void:
		list.clear()
		var q := search.text.strip_edges().to_lower()
		var sel := -1
		for o in options:
			if q != "" and not (str(o.id) + " " + o.tip).to_lower().contains(q):
				continue
			var txt: String = str(o.id) if o.icon != null else "%d %s" % [o.id, o.label]
			var i := list.add_item(txt, o.icon)
			list.set_item_metadata(i, o.id)
			list.set_item_tooltip(i, o.tip)
			if o.id == value:
				sel = i
		if sel >= 0:
			list.select(sel)
			list.ensure_current_is_visible()
		_head()

	func _head() -> void:
		head.text = str(value)
		for o in options:
			if o.id == value:
				head.text = o.tip
		head.tooltip_text = head.text

	func _on_sel(i: int) -> void:
		value = list.get_item_metadata(i)
		_head()
		picked.emit(value)

	func set_icon(id: int, tex: Texture2D) -> void:
		for o in options:
			if o.id == id:
				o.icon = tex
		for i in list.item_count:
			if list.get_item_metadata(i) == id:
				list.set_item_icon(i, tex)
				list.set_item_text(i, str(id))
