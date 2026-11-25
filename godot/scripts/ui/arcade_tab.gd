class_name ArcadeTab
extends MarginContainer
## Arcade tab: own games for the free cabinets 174 / 175 / 176 (docs/formats/arcade_vm.md). Source editor in the
## arcade language, live preview (ArcadeVM, the reference copy of the in-game VM), palette and 16×8 sprite editors
## that rewrite the source, and where the cabinet is placed. The source text is the only truth: the sprite and
## palette editors edit its `sprite` blocks and `palette` line. Unapplied text is kept per cabinet until Apply.

const PROPS := [174, 175, 176]
const CELL := 14                 # sprite editor cell size (px)
const FPS := 30.0                # the game calls Update every 2nd frame
## Preview keys: physical keys (melonDS default layout) -> DS key name.
const KEYMAP := {KEY_X: "A", KEY_Z: "B", KEY_S: "X", KEY_A: "Y", KEY_Q: "L", KEY_W: "R", KEY_ENTER: "START",
	KEY_BACKSPACE: "SELECT", KEY_RIGHT: "RIGHT", KEY_LEFT: "LEFT", KEY_UP: "UP", KEY_DOWN: "DOWN"}
const SHADER := """
shader_type canvas_item;
// The VM screen as bytes (32 x 128, R8): 4 pixels of 2 bits per byte, pixel x in bits (x & 3) * 2.
uniform vec4 c0 : source_color;
uniform vec4 c1 : source_color;
uniform vec4 c2 : source_color;
uniform vec4 c3 : source_color;
void fragment() {
	ivec2 p = clamp(ivec2(floor(UV * 128.0)), ivec2(0), ivec2(127));
	int b = int(round(texelFetch(TEXTURE, ivec2(p.x >> 2, p.y), 0).r * 255.0));
	int v = (b >> ((p.x & 3) * 2)) & 3;
	COLOR = v == 0 ? c0 : (v == 1 ? c1 : (v == 2 ? c2 : c3));
}
"""
const REFERENCE := """ARCADE LANGUAGE (full reference: docs/formats/arcade_vm.md)

Line based. ; or // starts a comment. Integers are signed 32-bit and wrap.

DECLARATIONS
  palette #000000, #FFFFFF, #FF8020, #60C0FF   the 4 colours (0 = background / transparent in sprites)
  const NAME = expr                            constant (folded at compile time)
  var x, y = 10, t[8]                          reset at every init (arrays: 1..255 slots)
  keep best = 0                                set once at boot, kept across games (high score)
  sprite NAME  …8 rows of up to 16 pixels (. or 0 transparent, 1..3 colour)…  end
  func init … end                              optional, run at Insert Coin / attract screen
  func frame … end                             required, run 30 times per second
  func NAME … end                              own function, called by its name (no arguments)

STATEMENTS
  x = e    x += e (-= *= /= %= &= |= ^=)    a[i] = e
  if e / elif e / else / end      while e / end      for i = a to b [step k] / end
  break   continue   return   NAME (call)

COMMANDS
  cls c                           fill the screen
  rect x, y, w, h, c              filled rectangle
  pix x, y, c                     one pixel
  spr s, x, y [, flip]            sprite (flip: 1 horizontal, 2 vertical)
  text "...", x, y, c [, size]    3×5 font, \\n = new line
  num v, x, y, c [, size]         number in decimal
  pal i, #RRGGBB                  change a palette entry
  sfx id                          play a game sound (ids below)

EXPRESSIONS (low to high)
  or  and  not  | ^ &  == != < <= > >=  << >>  + -  * / %  unary - ~
  x / 0 = 0, x % 0 = 0. Literals: 123 0x7F 'A' #RRGGBB true false

FUNCTIONS
  held(mask) pressed(mask) rnd(n) abs(v) min(a, b) max(a, b)
  hit(x1, y1, w1, h1, x2, y2, w2, h2) peek(x, y)

BUILT-INS
  attract (1 on the attract screen), tick (frames since init)
  keys: A B SELECT START RIGHT LEFT UP DOWN R L X Y

SOUNDS (sfx; names = where the original cabinets use them)
  SFX_BOUNCE 0x1F  ball on a wall, player hit, crash
  SFX_LOST   0x20  ball lost / restart      SFX_BLIP    0x21  paddle edge, pickup
  SFX_COPTER 0x23  Copter delivery          SFX_CATCH   0x24  pie caught
  SFX_MISS   0x25  pie missed               SFX_LAUNCH  0x26  new pie
  SFX_LASER  0x27  X-Raider shot            SFX_BREAK   0x28  brick / target hit
  SFX_PADDLE 0x2A  paddle hit, march step   SFX_ENEMY_SHOT 0x2B  invader shot
  SFX_EXPLODE 0x2C invader destroyed        SFX_SHOOT   0x2D  player shot
  SFX_EXTRA1 0x2F, SFX_EXTRA2 0x30  arcade sounds no cabinet uses
  SFX_COIN 0x15C  insert coin               SFX_CLACK  0x264  billiard ball
  Any id 0..671 works except the looping ambiences 0x22 0x29 0x2E (ignored).

IN THE GAME
  A presses Stop in the Sims UI: the session ends. Use B, X, Y and the D-pad.
  Screen 128×128, 4 colours. 30 000 ops per frame at most (the frame stops there).
  Variables: 254 slots. Call depth 32."""

var ed                           # main.gd
var prop := 174
var lang := "script"             # language of the shown text ("asm": stored ArmAsm game, no preview)
var drafts := {}                 # prop -> unapplied text
var vm := ArcadeVM.new()
var prog := {}                   # last program that compiled
var running := true
var _acc := 0.0
var _prev_keys := 0
var _setting := false
var _sprites := {}               # name -> {head, end, px: PackedByteArray(128)} parsed from the text
var _sprite_sel := ""
var paint := 1
var _sfx_msg := ""
var _sfx_until := 0
var _place_sig := ""

var cab_opt: OptionButton
var src: CodeEdit
var info: Label
var screen_box: PanelContainer
var screen_rect: TextureRect
var screen_tex: ImageTexture
var screen_mat: ShaderMaterial
var run_btn: Button
var attract_chk: CheckBox
var stat_lbl: Label
var pal_btns: Array = []
var spr_opt: OptionButton
var grid: Control
var paint_btns: Array = []
var place_box: VBoxContainer
var ref_dlg: AcceptDialog
var timer: Timer


func _init() -> void:
	name = "Arcade"
	for s in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + s, 8)


func _ready() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)

	cab_opt = OptionButton.new()
	cab_opt.item_selected.connect(func(i): show_cabinet(cab_opt.get_item_id(i)))
	var ex := MenuButton.new()
	ex.text = "Examples ▾"
	ex.flat = false
	ex.tooltip_text = "Replace the text with an example game (Apply to keep it)"
	for k in ArcadeExamples.ALL:
		ex.get_popup().add_item(k)
	ex.get_popup().index_pressed.connect(func(i): load_example(ex.get_popup().get_item_text(i)))
	v.add_child(W.hbox([W.label("Cabinet", W.MUTED, false), cab_opt,
		W.button("Apply", apply, "Compile and save this game on the cabinet (Ctrl+S)"),
		W.button("Remove", _remove, "Give the cabinet back its original behaviour (falls back to Space Armada)"),
		ex, W.button("Reference…", func(): ref_dlg.popup_centered_ratio(0.6), "The arcade language")]))

	# --- left column: preview, palette, sprite editor, placement (scrolls); right: the source -------------------
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(split)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size.x = 284
	split.add_child(sc)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(left)
	var code_box := VBoxContainer.new()
	code_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(code_box)
	screen_box = PanelContainer.new()
	screen_box.focus_mode = Control.FOCUS_ALL
	screen_box.tooltip_text = "Click to play with the keyboard"
	screen_box.gui_input.connect(_screen_input)
	screen_box.focus_entered.connect(func(): screen_box.self_modulate = Color(1.4, 1.4, 0.8))
	screen_box.focus_exited.connect(func():
		screen_box.self_modulate = Color.WHITE
		_prev_keys = 0)
	left.add_child(screen_box)
	screen_rect = TextureRect.new()
	screen_rect.custom_minimum_size = Vector2(256, 256)
	screen_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen_rect.stretch_mode = TextureRect.STRETCH_SCALE
	screen_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var img := Image.create(32, 128, false, Image.FORMAT_R8)
	screen_tex = ImageTexture.create_from_image(img)
	screen_rect.texture = screen_tex
	var sh := Shader.new()
	sh.code = SHADER
	screen_mat = ShaderMaterial.new()
	screen_mat.shader = sh
	screen_rect.material = screen_mat
	screen_box.add_child(screen_rect)
	run_btn = W.button("Pause", _toggle_run, "Pause / resume the preview")
	attract_chk = W.toggle("Attract", false, func(_on): restart(),
		"Start as the attract screen (attract = 1: the cabinet without a coin)")
	left.add_child(W.hbox([run_btn, W.button("Restart", restart, "Insert Coin again (init)"),
		W.button("Step", _step_once, "One frame (paused)"), attract_chk]))
	stat_lbl = W.label("", W.MUTED, false)
	left.add_child(stat_lbl)
	var keys := PackedStringArray()
	for k in [KEY_Z, KEY_S, KEY_A, KEY_X]:
		keys.append("%s = %s" % [_key_label(k), KEYMAP[k]])
	left.add_child(W.label("Click the screen to play: arrows = D-pad, " + ", ".join(keys) + " (A stops the game in the Sims UI)", W.MUTED))
	left.add_child(HSeparator.new())
	var right := left
	right.add_child(W.label("Palette", W.MUTED, false))
	var ph := HBoxContainer.new()
	for i in 4:
		var b := ColorPickerButton.new()
		b.custom_minimum_size = Vector2(44, 26)
		b.edit_alpha = false
		b.tooltip_text = "Colour %d%s" % [i, " (background, transparent in sprites)" if i == 0 else ""]
		b.color_changed.connect(_pal_live.bind(i))
		b.popup_closed.connect(_pal_commit.bind(i))
		pal_btns.append(b)
		ph.add_child(b)
	right.add_child(ph)
	spr_opt = OptionButton.new()
	spr_opt.custom_minimum_size.x = 120
	spr_opt.item_selected.connect(func(i):
		_sprite_sel = spr_opt.get_item_text(i)
		grid.queue_redraw())
	right.add_child(W.hbox([W.label("Sprite", W.MUTED, false), spr_opt,
		W.button("New", _new_sprite, "Add an empty sprite block to the text")]))
	grid = Control.new()
	grid.custom_minimum_size = Vector2(16 * CELL + 1, 8 * CELL + 1)
	grid.mouse_filter = Control.MOUSE_FILTER_STOP
	grid.tooltip_text = "Left: paint with the chosen colour · right: transparent"
	grid.draw.connect(_draw_grid)
	grid.gui_input.connect(_grid_input)
	right.add_child(grid)
	var pb := HBoxContainer.new()
	pb.add_child(W.label("Paint", W.MUTED, false))
	for i in 4:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(30, 24)
		b.text = "·" if i == 0 else str(i)
		b.tooltip_text = "transparent" if i == 0 else "colour %d" % i
		b.pressed.connect(func():
			paint = i
			_paint_buttons())
		paint_btns.append(b)
		pb.add_child(b)
	right.add_child(pb)
	right.add_child(HSeparator.new())
	place_box = VBoxContainer.new()
	right.add_child(place_box)

	# --- source ---------------------------------------------------------------------------------------------------
	src = CodeEdit.new()
	src.size_flags_vertical = Control.SIZE_EXPAND_FILL
	src.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	src.custom_minimum_size = Vector2(260, 200)
	src.gutters_draw_line_numbers = true
	src.indent_automatic = true
	src.indent_use_spaces = true
	src.indent_size = 2
	src.highlight_current_line = true
	src.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	src.syntax_highlighter = _highlighter()
	src.text_changed.connect(_on_text_changed)
	src.gui_input.connect(func(e):
		if e is InputEventKey and e.pressed and e.keycode == KEY_S and e.ctrl_pressed:
			apply()
			src.accept_event())
	code_box.add_child(src)
	info = W.label("", W.MUTED)
	code_box.add_child(info)

	timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.3
	timer.timeout.connect(compile_preview)
	add_child(timer)
	ref_dlg = AcceptDialog.new()
	ref_dlg.title = "Arcade language"
	var t := TextEdit.new()
	t.editable = false
	t.text = REFERENCE
	t.custom_minimum_size = Vector2(640, 420)
	t.add_theme_font_override("font", src.get_theme_font("font"))
	ref_dlg.add_child(t)
	add_child(ref_dlg)
	_paint_buttons()


func _key_label(k: int) -> String:
	var lk := DisplayServer.keyboard_get_keycode_from_physical(k)
	return OS.get_keycode_string(lk if lk != KEY_NONE else k)


func _highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = Color("#b5cea8")
	h.symbol_color = Color(0.75, 0.77, 0.82)
	h.function_color = Color("#4fc3f7")
	h.member_variable_color = Color(0.85, 0.85, 0.9)
	for k in ArcadeScript.KEYWORDS:
		h.add_keyword_color(k, Color("#ce93d8"))
	for k in ["func", "end", "sprite", "palette", "const", "var", "keep"]:
		h.add_keyword_color(k, Color("#ffb74d"))
	for k in ArcadeScript.COMMANDS:
		h.add_keyword_color(k, Color("#81c784"))
	for k in ArcadeScript.FUNCS:
		h.add_keyword_color(k, Color("#4fc3f7"))
	for k in ArcadeVM.KEYS:
		h.add_keyword_color(k, Color("#f06292"))
	for k in ArcadeVM.SOUNDS:
		h.add_keyword_color(k, Color("#f06292"))
	for k in ["attract", "tick", "true", "false"]:
		h.add_keyword_color(k, Color("#f06292"))
	h.add_color_region(";", "", W.MUTED, true)
	h.add_color_region("//", "", W.MUTED, true)
	h.add_color_region("\"", "\"", Color("#e6c07b"), false)
	return h


# =================================================================================================================
# cabinets, drafts, apply
# =================================================================================================================

## Called by the editor after ROM open, edits and undo. Cheap when the tab is hidden.
func refresh() -> void:
	if ed == null or ed.proj == null:
		return
	var cur := prop
	cab_opt.clear()
	for p in PROPS:
		var g: Dictionary = ed.proj.arcade_game(p)
		var mark := "" if g.is_empty() else ("  · own game" if g.lang == "script" else "  · own game (asm)")
		if drafts.has(p):
			mark += " *"
		cab_opt.add_item("%d · %s%s" % [p, ed.gd.prop_game_name(p), mark], p)
		if p == cur:
			cab_opt.select(cab_opt.item_count - 1)
	_title()
	if not is_visible_in_tree():
		_place_sig = ""
		return
	# text: keep a draft, else follow the stored game (undo, apply)
	if not drafts.has(prop):
		var g: Dictionary = ed.proj.arcade_game(prop)
		var want: String = g.get("source", "")
		if want != src.text or lang != g.get("lang", "script"):
			_show_text(want, g.get("lang", "script"))
	_render_place()


func reset() -> void:
	drafts.clear()
	prog = {}
	_place_sig = ""
	prop = 174
	if src != null:
		_show_text("", "script")


func show_cabinet(p: int) -> void:
	prop = p
	var g: Dictionary = ed.proj.arcade_game(p)
	_show_text(drafts.get(p, g.get("source", "")), g.get("lang", "script"))
	_place_sig = ""
	refresh()


func _show_text(t: String, l: String) -> void:
	lang = l
	_setting = true
	src.text = t
	src.clear_undo_history()
	_setting = false
	prog = {}
	compile_preview()


func _stored_text() -> String:
	return ed.proj.arcade_game(prop).get("source", "")


func _on_text_changed() -> void:
	if _setting:
		return
	if src.text == _stored_text():
		drafts.erase(prop)
	else:
		drafts[prop] = src.text
	_title()
	timer.start()


func _title() -> void:
	var tabs: TabContainer = get_parent() as TabContainer
	if tabs != null:
		tabs.set_tab_title(get_index(), "Arcade *" if not drafts.is_empty() else "Arcade")


func load_example(n: String) -> void:
	_setting = true
	src.text = ArcadeExamples.ALL[n]
	_setting = false
	lang = "script"
	_on_text_changed()
	compile_preview()
	ed.status("Example \"%s\" loaded on cabinet %d: Apply to keep it" % [n, prop])


## Save the text as the cabinet's game ("" = remove it). Returns the error ("" = saved).
func apply() -> String:
	if ed.proj == null:
		return "no ROM"
	var t := src.text
	if t.strip_edges() == "":
		t = ""
	var e: String = ed.proj.set_arcade_game(prop, t, lang)
	if e != "":
		var ln := 0
		if e.begins_with("line "):
			ln = e.get_slice(":", 0).trim_prefix("line ").to_int()
		_error(e.substr(e.find(":") + 2) if ln > 0 else e, ln)
		ed.status("Arcade game not applied: " + e)
		return e
	drafts.erase(prop)
	refresh()
	ed.status(("Own game saved on cabinet %d (%s)" % [prop, ed.gd.prop_game_name(prop)]) if t != ""
		else "Cabinet %d back to the original" % prop)
	ed._show_edited()
	return ""


func _remove() -> void:
	if ed.proj.arcade_game(prop).is_empty() and not drafts.has(prop):
		ed.status("Cabinet %d has no own game" % prop)
		return
	ed.ask("Remove the own game of cabinet %d (%s)? Unapplied text is lost too." % [prop, ed.gd.prop_game_name(prop)],
		func():
			drafts.erase(prop)
			ed.proj.set_arcade_game(prop, "")
			_show_text("", "script")
			refresh()
			ed._show_edited()
			ed.status("Cabinet %d back to the original" % prop))


# =================================================================================================================
# compile + preview
# =================================================================================================================

func compile_preview() -> void:
	for i in src.get_line_count():
		src.set_line_background_color(i, Color(0, 0, 0, 0))
	_parse_sprites()
	if lang != "script":
		prog = {}
		_set_info("ArmAsm game (made by a test): saved as it is, no preview.", W.MUTED)
		_sync_side()
		return
	if src.text.strip_edges() == "":
		prog = {}
		vm = ArcadeVM.new()
		_blank_screen()
		_set_info("No own game on this cabinet: in the game it falls back to Space Armada. Pick an example " +
			"(Examples ▾) or write one (Reference…), then Apply.", W.MUTED)
		_sync_side()
		return
	var p := ArcadeScript.compile(src.text)
	if p.has("error"):
		_error(p.error, p.line)
		_sync_side()
		return
	prog = p
	restart()
	var warn := ""
	var re := RegEx.create_from_string("(held|pressed)\\s*\\([^)\\n;]*\\bA\\b")
	if re.search(_strip_comments(src.text)) != null:
		warn = "  ⚠ uses key A: in the game A presses Stop and ends the session (use B, X, Y, D-pad)."
	_set_info("OK: %d bytes of code, %d sprite(s), %d / 254 variables, stack %d / 48.%s" % [p.code.size(), p.nsprites,
		p.nvars - 2, p.max_stack, warn], W.WARN if warn != "" else W.MUTED)
	_sync_side()


func _strip_comments(t: String) -> String:
	var out := PackedStringArray()
	for l in t.split("\n"):
		var c := l.find(";")
		out.append(l.substr(0, c) if c >= 0 else l)
	return "\n".join(out)


func _set_info(t: String, c: Color) -> void:
	info.text = t
	info.add_theme_color_override("font_color", c)


func _error(msg: String, line: int) -> void:
	_set_info(("line %d: " % line if line > 0 else "") + msg, W.WARN)
	if line > 0 and line <= src.get_line_count():
		src.set_line_background_color(line - 1, Color(0.6, 0.15, 0.15, 0.45))


func restart() -> void:
	if prog.is_empty():
		return
	vm = ArcadeVM.new()
	vm.load(prog)
	vm.start(attract_chk.button_pressed)
	_acc = 0.0
	_after_call()
	_upload()


func _toggle_run() -> void:
	running = not running
	run_btn.text = "Pause" if running else "Run"


func _step_once() -> void:
	if running:
		_toggle_run()
	if not prog.is_empty():
		step()
		_upload()


func _process(delta: float) -> void:
	if prog.is_empty() or not running or not is_visible_in_tree():
		return
	_acc += delta
	var n := 0
	while _acc >= 1.0 / FPS and n < 3:
		_acc -= 1.0 / FPS
		step()
		n += 1
	if _acc > 0.2:
		_acc = 0.0
	if n > 0:
		_upload()


func _keys() -> int:
	if not screen_box.has_focus():
		return 0
	var k := 0
	for pk in KEYMAP:
		if Input.is_physical_key_pressed(pk):
			k |= ArcadeVM.KEYS[KEYMAP[pk]]
	return k


## One Update of the cabinet (keys from the keyboard while the screen has the focus).
func step(keys := -1) -> void:
	var held := _keys() if keys < 0 else keys
	vm.frame(held, held & ~_prev_keys)
	_prev_keys = held
	_after_call()
	if held & ArcadeVM.KEYS.A:
		_sfx_msg = "A held: in the game this presses Stop"
		_sfx_until = Time.get_ticks_msec() + 1500


func _after_call() -> void:
	if not vm.sounds.is_empty():
		_sfx_msg = "sfx " + ", ".join(vm.sounds.map(func(s): return _sound_name(s)))
		_sfx_until = Time.get_ticks_msec() + 1000


static func _sound_name(id: int) -> String:
	for k in ArcadeVM.SOUNDS:
		if ArcadeVM.SOUNDS[k] == id:
			return k
	return "0x%X" % id


func _upload() -> void:
	screen_tex.update(Image.create_from_data(32, 128, false, Image.FORMAT_R8, vm.screen))
	for i in 4:
		screen_mat.set_shader_parameter("c%d" % i, ArcadeVM.rgb555(vm.pal[i]))
	var s := "tick %d · %d ops" % [vm.vars[ArcadeVM.V_TICK], vm.ops]
	if vm.stopped != "":
		s += " · stopped: " + vm.stopped
	if Time.get_ticks_msec() < _sfx_until:
		s += " · " + _sfx_msg
	stat_lbl.text = s
	stat_lbl.add_theme_color_override("font_color", W.WARN if vm.stopped != "" else W.MUTED)


func _blank_screen() -> void:
	var b := PackedByteArray()
	b.resize(4096)
	screen_tex.update(Image.create_from_data(32, 128, false, Image.FORMAT_R8, b))
	for i in 4:
		screen_mat.set_shader_parameter("c%d" % i, Color.BLACK)
	stat_lbl.text = ""


func _screen_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		screen_box.grab_focus()
		screen_box.accept_event()
	elif e is InputEventKey and KEYMAP.has(e.physical_keycode):
		screen_box.accept_event()   # keys play the game (no focus moves, no shortcuts)


# =================================================================================================================
# palette + sprites (edit the text)
# =================================================================================================================

## Palette pickers and sprite list from the last compiled program / the parsed text.
func _sync_side() -> void:
	var pal: PackedInt32Array = prog.palette if not prog.is_empty() else PackedInt32Array([0, 0x7FFF, 0x03E0, 0x001F])
	for i in 4:
		pal_btns[i].color = ArcadeVM.rgb555(pal[i])
		pal_btns[i].disabled = lang != "script"
	spr_opt.clear()
	for n in _sprites:
		spr_opt.add_item(n)
		if n == _sprite_sel:
			spr_opt.select(spr_opt.item_count - 1)
	if not _sprites.has(_sprite_sel):
		_sprite_sel = _sprites.keys()[0] if not _sprites.is_empty() else ""
		if _sprite_sel != "":
			spr_opt.select(0)
	grid.queue_redraw()


func _parse_sprites() -> void:
	_sprites.clear()
	var re := RegEx.create_from_string("^\\s*sprite\\s+([A-Za-z_]\\w*)\\s*(;.*)?$")
	var i := 0
	var n := src.get_line_count()
	while i < n:
		var m := re.search(src.get_line(i))
		if m == null:
			i += 1
			continue
		var px := PackedByteArray()
		px.resize(128)
		var head := i
		var row := 0
		i += 1
		while i < n:
			var t := src.get_line(i).strip_edges()
			var sc := t.find(";")
			if sc >= 0:
				t = t.substr(0, sc).strip_edges()
			if t == "end":
				break
			if t != "" and row < 8:
				for x in mini(16, t.length()):
					px[row * 16 + x] = maxi(0, "0123".find(t[x]))
				row += 1
			i += 1
		if i < n:   # unterminated blocks are reported by the compiler
			_sprites[m.get_string(1)] = {"head": head, "end": i, "px": px}
		i += 1


func _draw_grid() -> void:
	var cols: Array = []
	for i in 4:
		cols.append(pal_btns[i].color)
	grid.draw_rect(Rect2(Vector2.ZERO, grid.custom_minimum_size), Color(0.1, 0.1, 0.12))
	if not _sprites.has(_sprite_sel):
		grid.draw_string(get_theme_default_font(), Vector2(8, 4 * CELL), "no sprite (New adds one)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, W.MUTED)
		return
	var px: PackedByteArray = _sprites[_sprite_sel].px
	for y in 8:
		for x in 16:
			var r := Rect2(x * CELL + 1, y * CELL + 1, CELL - 1, CELL - 1)
			var v := px[y * 16 + x]
			if v == 0:
				var chk := Color(0.22, 0.22, 0.25) if (x + y) & 1 else Color(0.3, 0.3, 0.33)
				grid.draw_rect(r, chk)
			else:
				grid.draw_rect(r, cols[v])


func _grid_input(e: InputEvent) -> void:
	var btn := 0
	if e is InputEventMouseButton and e.pressed:
		btn = e.button_index
	elif e is InputEventMouseMotion:
		btn = MOUSE_BUTTON_LEFT if e.button_mask & MOUSE_BUTTON_MASK_LEFT else (
			MOUSE_BUTTON_RIGHT if e.button_mask & MOUSE_BUTTON_MASK_RIGHT else 0)
	if btn != MOUSE_BUTTON_LEFT and btn != MOUSE_BUTTON_RIGHT:
		return
	var x := int(e.position.x) / CELL
	var y := int(e.position.y) / CELL
	if x < 0 or x >= 16 or y < 0 or y >= 8:
		return
	set_sprite_pixel(_sprite_sel, x, y, paint if btn == MOUSE_BUTTON_LEFT else 0)
	grid.accept_event()


## Paint one pixel of sprite `n`: rewrites the rows of its block in the text (one undo step).
func set_sprite_pixel(n: String, x: int, y: int, c: int) -> void:
	if not _sprites.has(n) or lang != "script":
		return
	var s: Dictionary = _sprites[n]
	if s.px[y * 16 + x] == c:
		return
	s.px[y * 16 + x] = c
	var rows := PackedStringArray()
	var last := 0
	for r in 8:
		var t := ""
		for xx in 16:
			var v: int = s.px[r * 16 + xx]
			t += "." if v == 0 else str(v)
			if v != 0:
				last = r + 1
		rows.append(t)
	var ind := _indent(src.get_line(s.head))
	var body := ""
	for r in maxi(last, 1):
		body += ind + rows[r] + "\n"
	src.begin_complex_operation()
	if s.end > s.head + 1:
		src.remove_text(s.head + 1, 0, s.end, 0)
	src.insert_text(body, s.head + 1, 0)
	src.end_complex_operation()
	_parse_sprites()
	grid.queue_redraw()


func _indent(l: String) -> String:
	return l.substr(0, l.length() - l.strip_edges(true, false).length())


func _new_sprite() -> void:
	if lang != "script":
		return
	var k := 1
	while _sprites.has("sprite%d" % k) or src.text.contains("sprite%d" % k):
		k += 1
	var n := "sprite%d" % k
	# before the first func, else at the end
	var at := src.get_line_count()
	for i in src.get_line_count():
		if src.get_line(i).strip_edges().begins_with("func "):
			at = i
			break
	var block := "sprite %s\n%s\nend\n\n" % [n, "................"]
	if at >= src.get_line_count():
		src.insert_text("\n" + block, src.get_line_count() - 1, src.get_line(src.get_line_count() - 1).length())
	else:
		src.insert_text(block, at, 0)
	_sprite_sel = n
	_parse_sprites()
	_sync_side()
	src.set_caret_line(at)
	src.center_viewport_to_caret()


func _pal_live(c: Color, i: int) -> void:
	if not prog.is_empty():
		var v := _bgr555(c)
		vm.pal[i] = v
		vm.pal_start[i] = v
		_upload()
	grid.queue_redraw()


func _bgr555(c: Color) -> int:
	return (c.r8 >> 3) | ((c.g8 >> 3) << 5) | ((c.b8 >> 3) << 10)


func _pal_commit(_i: int) -> void:
	set_palette([pal_btns[0].color, pal_btns[1].color, pal_btns[2].color, pal_btns[3].color])


## Write the `palette` line (replaces the first one, keeps its comment; else inserted after the header comments).
func set_palette(cols: Array) -> void:
	if lang != "script":
		return
	var parts := PackedStringArray()
	for c in cols:
		parts.append("#%02X%02X%02X" % [c.r8 & 0xF8, c.g8 & 0xF8, c.b8 & 0xF8])
	var line := "palette " + ", ".join(parts)
	var re := RegEx.create_from_string("^\\s*palette\\b")
	for i in src.get_line_count():
		var l := src.get_line(i)
		if re.search(l) != null:
			var sc := l.find(";")
			var nl := _indent(l) + line + ("   " + l.substr(sc) if sc >= 0 else "")
			if nl != l:
				src.begin_complex_operation()
				src.remove_text(i, 0, i, l.length())
				src.insert_text(nl, i, 0)
				src.end_complex_operation()
			return
	var at := 0
	while at < src.get_line_count() and src.get_line(at).strip_edges().begins_with(";"):
		at += 1
	src.insert_text(line + "\n", at, 0)


func _paint_buttons() -> void:
	for i in paint_btns.size():
		paint_btns[i].button_pressed = i == paint


# =================================================================================================================
# where the cabinet is
# =================================================================================================================

## Layout items (type 2 prop) using cabinet `p`: [[location, "b/g/i"], ...], one per layout file.
func placements(p: int) -> Array:
	var out := []
	var seen := {}
	for L in ed.gd.locations:
		if L.nav == GameData.NONE or seen.has(L.nav):
			continue
		seen[L.nav] = true
		var lay: Layout = ed.proj.load_layout(L.location)
		if lay == null or lay.error != "":
			continue
		for b in lay.blocks.size():
			for g in lay.blocks[b].groups.size():
				var its: Array = lay.blocks[b].groups[g].items
				for i in its.size():
					if its[i].type == 2 and its[i].get_field("prop") == p:
						out.append([L.location, "%d/%d/%d" % [b, g, i]])
	return out


## The selected item if it is a prop (type 2), as [b, g, i], else [].
func _selected_prop() -> Array:
	if ed.lay == null or not ed.sel.count("/") == 2 or ed.sel.begins_with("e/"):
		return []
	var p: PackedStringArray = ed.sel.split("/")
	var b := p[0].to_int()
	var g := p[1].to_int()
	var i := p[2].to_int()
	if b >= ed.lay.blocks.size() or g >= ed.lay.blocks[b].groups.size() or i >= ed.lay.blocks[b].groups[g].items.size():
		return []
	return [b, g, i] if ed.lay.blocks[b].groups[g].items[i].type == 2 else []


func _render_place() -> void:
	var sp := _selected_prop()
	var sig := "%d|%d|%s|%s|%d" % [prop, ed.loc, ed.sel, str(sp), ed.proj.edits.size()]
	for k in ed.proj.edited_keys():
		if k.begins_with("layout:"):
			sig += k + str(hash(ed.proj.edits[k]))
	if sig == _place_sig:
		return
	_place_sig = sig
	for c in place_box.get_children():
		c.queue_free()
	place_box.add_child(W.label("Placed in", W.MUTED, false))
	var pl := placements(prop)
	if pl.is_empty():
		place_box.add_child(W.label("Nowhere yet. Select a prop in a location (e.g. a Space Armada cabinet) and " +
			"use the button below, or add a prop %d (Add item tab)." % prop, W.WARN))
	for x in pl.slice(0, 6):
		var L = ed.gd.loc(x[0])
		place_box.add_child(W.button("%d · %s  (%s)" % [x[0], L.place, x[1]], func():
			ed.open_location(x[0])
			ed.select(x[1]), "Show this cabinet in the location view"))
	if pl.size() > 6:
		place_box.add_child(W.label("… and %d more" % (pl.size() - 6), W.MUTED, false))
	var b := W.button("Selected prop → cabinet %d" % prop, _use_selected,
		"Turn the prop selected in the location view into this cabinet (same place and angle)")
	b.disabled = sp.is_empty() or ed.lay.blocks[sp[0]].groups[sp[1]].items[sp[2]].get_field("prop") == prop
	place_box.add_child(b)
	place_box.add_child(W.label("Test ▶ (F5) starts a new game in the shown location.", W.MUTED))


func _use_selected() -> void:
	var sp := _selected_prop()
	if sp.is_empty():
		return
	var keep: String = ed.sel
	if ed.apply(ed.proj.edit_item(ed.loc, sp[0], sp[1], sp[2], null, null, null, null, null, {"prop": prop})):
		ed.select(keep)
		ed.tabs.current_tab = get_index()
		ed.status("Prop %s of location %d is now cabinet %d" % [keep, ed.loc, prop])
