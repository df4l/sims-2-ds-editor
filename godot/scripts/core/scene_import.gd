class_name SceneImport
extends RefCounted
## glTF / GLB scene -> location scene model (NsbmdWriter) + collision brushes (BspBuild).
## Coordinates: the file's (Y up, like the game); `scale` multiplies them (game units per file unit).
## Object names (case-insensitive suffix):
##   "-col" / "_col" / "-colonly" / "_colonly": collision only (not drawn); one convex brush (its convex mesh;
##       a non-convex one falls back to slabs behind its faces);
##   "-nocol" / "_nocol": drawn, never solid.
## Collision = the "-col" objects + (auto_collision) a slab `thickness` deep behind every other drawn face.
## Colours: glTF vertex colours are linear -> converted to sRGB (the DS uses them as they are); material base colour
## (Godot keeps it sRGB) multiplies them. Textures: the base colour texture.

var error := ""
var warnings := []
var surfaces := []      # for NsbmdWriter.build
var brushes := []       # for BspBuild.compile
var aabb := AABB()
var n_col_objects := 0


static func _suffix(name: String) -> String:
	var n := name.to_lower()
	for s in ["-colonly", "_colonly", "-col", "_col"]:
		if n.ends_with(s):
			return "col"
	for s in ["-nocol", "_nocol"]:
		if n.ends_with(s):
			return "nocol"
	return ""


static func _xform(n: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p := n
	while p != null:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func load_file(path: String, scale := 1.0, thickness := 0.5, auto_collision := true) -> bool:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		error = "cannot read %s (error %d)" % [path.get_file(), err]
		return false
	var root := doc.generate_scene(state)
	if root == null:
		error = "%s has no scene" % path.get_file()
		return false
	var ok := load_scene(root, scale, thickness, auto_collision)
	root.free()
	return ok


## Same from a scene already in memory.
func load_scene(root: Node, scale := 1.0, thickness := 0.5, auto_collision := true) -> bool:
	error = ""
	warnings.clear()
	surfaces.clear()
	brushes.clear()
	n_col_objects = 0
	var slab_src := []   # [verts, indices] of the drawn meshes allowed to collide
	var st := [root]
	var first := true
	while not st.is_empty():
		var n: Node = st.pop_back()
		for c in n.get_children():
			st.append(c)
		var mesh: Mesh = null
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
		elif n is ImporterMeshInstance3D and (n as ImporterMeshInstance3D).mesh != null:
			mesh = (n as ImporterMeshInstance3D).mesh.get_mesh()
		if mesh == null:
			continue
		var kind := _suffix(n.name)
		var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), Vector3.ZERO) * _xform(n)
		var flip := xf.basis.determinant() < 0
		var col_v := PackedVector3Array()
		var col_i := PackedInt32Array()
		for s in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				warnings.append("%s: surface %d is not made of triangles (skipped)" % [n.name, s])
				continue
			var a := mesh.surface_get_arrays(s)
			var V0: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var V := PackedVector3Array()
			V.resize(V0.size())
			for i in V0.size():
				V[i] = xf * V0[i]
				if first:
					aabb = AABB(V[i], Vector3.ZERO)
					first = false
				else:
					aabb = aabb.expand(V[i])
			var I: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if I.is_empty():
				I.resize(V.size())
				for i in V.size():
					I[i] = i
			if flip:
				var t := 0
				while t + 2 < I.size():
					var x := I[t + 1]
					I[t + 1] = I[t + 2]
					I[t + 2] = x
					t += 3
			if kind == "col":
				var base := col_v.size()
				col_v.append_array(V)
				for i in I:
					col_i.append(base + i)
				continue
			var mat: Material = null
			if n is MeshInstance3D:
				mat = (n as MeshInstance3D).get_active_material(s)
			if mat == null:
				mat = mesh.surface_get_material(s)
			var img: Image = null
			var tint := Color.WHITE
			var double_sided := false
			var alpha := 1.0
			if mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				if bm.albedo_texture != null:
					img = bm.albedo_texture.get_image()
				tint = Color(bm.albedo_color.r, bm.albedo_color.g, bm.albedo_color.b)
				double_sided = bm.cull_mode == BaseMaterial3D.CULL_DISABLED
				if bm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA:
					alpha = bm.albedo_color.a
			var C := PackedColorArray()
			if a[Mesh.ARRAY_COLOR] != null:
				for c in (a[Mesh.ARRAY_COLOR] as PackedColorArray):
					C.append(c.linear_to_srgb())
			var UV: PackedVector2Array = a[Mesh.ARRAY_TEX_UV] if a[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			if img != null and UV.is_empty():
				warnings.append("%s: textured but has no UVs (texture ignored)" % n.name)
				img = null
			surfaces.append({"verts": V, "indices": I, "uvs": UV, "colors": C, "image": img, "color": tint,
				"double_sided": double_sided, "alpha": alpha, "name": str(n.name)})
			if kind != "nocol":
				slab_src.append([V, I])
		if kind == "col" and not col_i.is_empty():
			n_col_objects += 1
			var planes := BspBuild.convex_brush(col_v, col_i)
			if planes.size() >= 4:
				brushes.append(planes)
			else:
				warnings.append("%s: collision object is not convex: slabs behind its faces instead" % n.name)
				brushes.append_array(BspBuild.slab_brushes(col_v, col_i, thickness))
	if surfaces.is_empty():
		error = "nothing to draw in the file"
		return false
	if auto_collision:
		for sv in slab_src:
			brushes.append_array(BspBuild.slab_brushes(sv[0], sv[1], thickness))
	if brushes.is_empty():
		warnings.append("no collision: the Sim will fall")
	return true
