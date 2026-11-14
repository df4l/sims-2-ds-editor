extends SubViewportContainer
## 3D view: scene BMD0 models at the origin, item models / markers at their layout position, BSP collision as
## translucent cells. Layout, BSP and models share one space. Models are converted on demand (a few per frame)
## and cached. Orbit: left drag rotates, right / middle drag pans, wheel zooms, click selects.

var ed
var vp := SubViewport.new()
var world := Node3D.new()
var cam := Camera3D.new()
var root_scene := Node3D.new()
var root_bsp := Node3D.new()
var root_items := Node3D.new()
var sel_box: MeshInstance3D
var target := Vector3.ZERO
var yaw := 0.6
var pitch := -0.7
var dist := 150.0
var bounds := AABB()
var token := 0
var queue := []          # [token, entry, tex, parent]
var meshes := {}         # "entry:tex" -> Mesh or null
var item_nodes := {}     # key -> Node3D
var drag := {}
var active := false


func _ready() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(vp)
	vp.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("#18181f")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	world.add_child(env)
	cam.near = 0.5
	cam.far = 6000
	cam.fov = 50
	world.add_child(cam)
	for n in [root_scene, root_bsp, root_items]:
		world.add_child(n)
	_update_cam()


func set_active(on: bool) -> void:
	active = on
	visible = on


func _update_cam() -> void:
	var dir := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw))
	cam.position = target + dir * dist
	cam.look_at(target, Vector3.UP)


func _process(_d: float) -> void:
	# convert queued models within a small time budget per frame
	var t0 := Time.get_ticks_msec()
	while not queue.is_empty() and Time.get_ticks_msec() - t0 < 25:
		var q: Array = queue.pop_front()
		if q[0] != token or not is_instance_valid(q[3]):
			continue
		var mesh = get_mesh(q[1], q[2])
		if mesh != null:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.set_meta("item_model", q[4])
			if q[4]:
				mi.visible = ed.show_models
			q[3].add_child(mi)
			if q[4] and q[3].get_meta("key", "") == ed.sel:
				_update_sel_box()


func get_mesh(entry: int, tex: int):
	var k := "%d:%d" % [entry, tex]
	if meshes.has(k):
		return meshes[k]
	var nb := Nsbmd.new()
	var mesh = null
	if nb.parse(ed.gd.rombin.data(entry)):
		var v: PackedByteArray = ed.gd.rombin.data(tex) if tex >= 0 else PackedByteArray()
		var mi := nb.build(v)
		if mi != null:
			mesh = mi.mesh
			mi.free()
	meshes[k] = mesh
	return mesh


func clear_all() -> void:
	token += 1
	queue.clear()
	item_nodes.clear()
	sel_box = null
	for r in [root_scene, root_bsp, root_items]:
		for c in r.get_children():
			r.remove_child(c)
			c.queue_free()


func load_location(refit: bool) -> void:
	clear_all()
	_build_bsp()
	if refit:
		fit()
	for m in ed.gd.locations[ed.loc].models:
		queue.append([token, m.model, -1, root_scene, false])
	for it in ed.items:
		_add_item(it)
	update_visibility()
	set_selection(ed.sel)


func _build_bsp() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lines := PackedVector3Array()
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for b in ed.brushes:
		var v: PackedVector3Array = b.verts
		for f in b.faces:
			if f.size() < 3:
				continue
			var n := (v[f[1]] - v[f[0]]).cross(v[f[2]] - v[f[0]]).normalized()
			var col := Color(absf(n.x) * 0.5 + 0.5, absf(n.y) * 0.5 + 0.5, absf(n.z) * 0.5 + 0.5, 0.25)
			for k in range(1, f.size() - 1):
				for idx in [f[0], f[k + 1], f[k]]:
					st.set_color(col)
					st.add_vertex(v[idx])
			for k in f.size():
				lines.append(v[f[k]])
				lines.append(v[f[(k + 1) % f.size()]])
		for p in v:
			lo = lo.min(p)
			hi = hi.max(p)
	bounds = AABB(lo, hi - lo) if lo.x != INF else AABB()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mi.material_override = m
	root_bsp.add_child(mi)
	if not lines.is_empty():
		var am := ArrayMesh.new()
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = lines
		am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
		var li := MeshInstance3D.new()
		li.mesh = am
		li.material_override = _flat(Color(0.44, 0.66, 0.86, 0.6), true)
		root_bsp.add_child(li)


static func _flat(c: Color, alpha := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	if alpha:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


static func box_lines(hs: Vector3) -> ArrayMesh:
	var c := []
	for x in [-1, 1]:
		for y in [-1, 1]:
			for z in [-1, 1]:
				c.append(Vector3(x * hs.x, y * hs.y, z * hs.z))
	var e := [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]
	var v := PackedVector3Array()
	for p in e:
		v.append(c[p[0]])
		v.append(c[p[1]])
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return am


func _add_item(it: Dictionary) -> void:
	var col: Color = W.color_of(it.type)
	var g := Node3D.new()
	g.position = Vector3(it.x, it.y, it.z)
	g.set_meta("key", it.key)
	var ang: float = it.angle if it.angle != null else 0.0
	g.rotation.y = ang   # furniture: game actor angle; layout items: ASSUMED sign
	var marker := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.2
	sm.height = 2.4
	sm.radial_segments = 12
	sm.rings = 6
	marker.mesh = sm
	marker.material_override = _flat(col)
	g.add_child(marker)
	if it.angle != null:
		var arrow := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 0.3, 5)
		arrow.mesh = bm
		arrow.position = Vector3(0, 0.5, 2.5)
		arrow.material_override = _flat(col)
		g.add_child(arrow)
	if it.half_size != null:
		var box := MeshInstance3D.new()
		box.mesh = box_lines(it.half_size)
		box.material_override = _flat(col)
		box.rotation.y = -ang   # ASSUMED: boxes are not rotated
		g.add_child(box)
	root_items.add_child(g)
	item_nodes[it.key] = g
	if it.model >= 0:
		queue.append([token, it.model, it.model_tex, g, true])


func update_visibility() -> void:
	root_bsp.visible = ed.show_bsp
	root_scene.visible = ed.show_scene
	for g in root_items.get_children():
		for c in g.get_children():
			if c.has_meta("item_model"):
				c.visible = ed.show_models


func fit() -> void:
	if bounds.size == Vector3.ZERO:
		return
	target = bounds.get_center()
	var r := maxf(maxf(bounds.size.x, bounds.size.z), 20)
	dist = r * 1.1
	cam.far = r * 12
	yaw = 0.0
	pitch = -0.78
	_update_cam()


func focus(it: Dictionary) -> void:
	target = Vector3(it.x, it.y, it.z)
	dist = minf(dist, 80)
	_update_cam()


func set_selection(key: String) -> void:
	if sel_box != null and is_instance_valid(sel_box):
		sel_box.queue_free()
	sel_box = null
	_update_sel_box()


func _update_sel_box() -> void:
	if sel_box != null and is_instance_valid(sel_box):
		sel_box.queue_free()
		sel_box = null
	var g = item_nodes.get(ed.sel)
	if g == null:
		return
	var aabb := AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	for c in g.get_children():
		if c is MeshInstance3D and c.has_meta("item_model") and c.visible:
			aabb = aabb.merge(c.get_aabb())
	sel_box = MeshInstance3D.new()
	sel_box.mesh = box_lines(aabb.size / 2 + Vector3(0.2, 0.2, 0.2))
	sel_box.position = aabb.get_center()
	sel_box.material_override = _flat(Color.WHITE)
	g.add_child(sel_box)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			dist = maxf(dist / 1.15, 2)
			_update_cam()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			dist = minf(dist * 1.15, 5000)
			_update_cam()
		elif mb.pressed:
			drag = {"start": mb.position, "last": mb.position, "button": mb.button_index, "moved": false}
		elif not drag.is_empty():
			if not drag.moved and drag.button == MOUSE_BUTTON_LEFT:
				_pick(mb.position)
			drag = {}
		accept_event()
	elif e is InputEventMouseMotion and not drag.is_empty():
		var mm := e as InputEventMouseMotion
		var d: Vector2 = mm.position - drag.last
		drag.last = mm.position
		if (mm.position - drag.start).length() > 4:
			drag.moved = true
		if drag.button == MOUSE_BUTTON_LEFT:
			yaw -= d.x * 0.008
			pitch = clampf(pitch - d.y * 0.008, -1.55, 1.55)
		else:
			var right := cam.global_transform.basis.x
			var up := cam.global_transform.basis.y
			target += (-right * d.x + up * d.y) * dist * 0.0015
		_update_cam()
		accept_event()


func _pick(p: Vector2) -> void:
	var from := cam.project_ray_origin(p)
	var dir := cam.project_ray_normal(p)
	var best := ""
	var bt := INF
	for key in item_nodes:
		var g: Node3D = item_nodes[key]
		# marker sphere
		var t := _ray_sphere(from, dir, g.global_position, 1.8)
		# model boxes
		for c in g.get_children():
			if c is MeshInstance3D and c.has_meta("item_model") and c.visible:
				var box: AABB = c.global_transform * c.get_aabb()
				var hit = box.intersects_ray(from, dir)
				if hit != null:
					t = minf(t, from.distance_to(hit))
		if t < bt:
			bt = t
			best = key
	if best != "":
		ed.select(best)


static func _ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var h := b * b - cc
	if h < 0:
		return INF
	var t := -b - sqrt(h)
	return t if t > 0 else INF
