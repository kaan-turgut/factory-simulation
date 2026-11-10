extends RefCounted
## Shared built-in mesh, material and signage helpers.

var _materials: Dictionary[Color, StandardMaterial3D] = {}
var _sign_font := FontVariation.new()


func _init() -> void:
	_sign_font.base_font = ThemeDB.fallback_font
	_sign_font.variation_embolden = 0.62


func material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var surface := StandardMaterial3D.new()
		surface.albedo_color = color
		surface.roughness = 0.76
		_materials[color] = surface
	return _materials[color]


func box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _mesh(parent, at, mesh, color)


func cylinder(
	parent: Node3D, at: Vector3, radius: float, height: float, color: Color,
	top_radius: float = -1.0
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = 24
	mesh.rings = 0
	return _mesh(parent, at, mesh, color)


func sphere(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radial_segments = 12
	mesh.rings = 6
	var instance := _mesh(parent, at, mesh, color)
	instance.scale = size
	return instance


func _mesh(parent: Node3D, at: Vector3, mesh: Mesh, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.position = at
	instance.mesh = mesh
	instance.material_override = material(color)
	parent.add_child(instance)
	return instance


func batch_static(parent: Node3D, dynamic_parts: Array[MeshInstance3D] = []) -> void:
	# Only merge direct primitive children. Nested groups may animate or be hidden.
	var groups: Dictionary[Material, Array] = {}
	for child in parent.get_children():
		var piece := child as MeshInstance3D
		if piece == null or piece in dynamic_parts or not piece.mesh is PrimitiveMesh \
				or piece.get_child_count() != 0:
			continue
		var surface := piece.material_override
		if not groups.has(surface):
			groups[surface] = []
		groups[surface].append(piece)
	for surface in groups:
		var pieces := groups[surface]
		if pieces.size() < 2:
			continue
		var geometry := SurfaceTool.new()
		geometry.begin(Mesh.PRIMITIVE_TRIANGLES)
		for piece: MeshInstance3D in pieces:
			geometry.append_from(piece.mesh, 0, piece.transform)
		geometry.set_material(surface)
		var batch := MeshInstance3D.new()
		batch.mesh = geometry.commit()
		parent.add_child(batch)
		for piece: MeshInstance3D in pieces:
			parent.remove_child(piece)
			piece.queue_free()


func sign(parent: Node3D, at: Vector3, text: String, color: Color) -> Label3D:
	var label := Label3D.new()
	label.position = at
	label.text = text
	label.font = _sign_font
	label.font_size = 48
	label.pixel_size = 0.012
	label.modulate = color
	label.outline_modulate = Color("#132435")
	label.outline_size = 13
	parent.add_child(label)
	return label
