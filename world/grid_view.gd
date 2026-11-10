extends Node3D
## Optional meter grid, footprint highlights and a snapped placement ghost.

const Grid = preload("res://layout/factory_grid.gd")
const Placement = preload("res://layout/placement.gd")
const Primitives = preload("res://world/primitives.gd")
const SELECTED := Color("#62f5ce")
const CLEARANCE := Color("#ffcc77")
const VALID := Color("#66e7b1")
const INVALID := Color("#ff8275")

var grid: Grid
var _lines := ImmediateMesh.new()
var _hover := ImmediateMesh.new()
var _outline := ImmediateMesh.new()
var _preview_outline := ImmediateMesh.new()
var _grid_layer := Node3D.new()
var _fill: MeshInstance3D
var _ghost: MeshInstance3D
var _fill_box := BoxMesh.new()
var _ghost_box := BoxMesh.new()
var _line_material := StandardMaterial3D.new()
var _ghost_material := StandardMaterial3D.new()
var _last_hover := Rect2i()
var _last_hover_y := -1.0
var _last_selection := Rect2i()
var _last_clearance := Rect2i()
var _last_selection_y := -1.0


func configure(factory_grid: Grid, deck: Placement) -> void:
	grid = factory_grid
	name = "GridOverlay"
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_material.vertex_color_use_as_albedo = true
	add_child(_grid_layer)
	_instance(_grid_layer, _lines, _line_material)
	_instance(_grid_layer, _hover, _line_material)
	_instance(self, _outline, _line_material)
	_instance(self, _preview_outline, _line_material)
	_fill = _instance(self, _fill_box, _tint(Color(0.34, 0.92, 0.70, 0.22)))
	_ghost_material = _tint(VALID)
	_ghost = _instance(self, _ghost_box, _ghost_material)
	_fill.hide()
	_ghost.hide()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_grid_lines(grid.bounds(), 0.055)
	_grid_lines(deck.footprint(), deck.elevation + 0.025)
	_lines.surface_end()
	_build_boundary_labels(deck.footprint())
	_grid_layer.hide()


func set_grid_visible(enabled: bool) -> void:
	_grid_layer.visible = enabled
	if not enabled:
		clear_hover()


func is_grid_visible() -> bool:
	return _grid_layer.visible


func project(camera: Camera3D, point: Vector2, elevation: float = 0.0) -> Vector3:
	return project_ray(camera.project_ray_origin(point), camera.project_ray_normal(point), elevation)


func project_ray(origin: Vector3, direction: Vector3, elevation: float = 0.0) -> Vector3:
	var plane := Plane(Vector3.UP, grid.origin.y + elevation)
	var hit: Variant = plane.intersects_ray(origin, direction)
	if hit == null or not grid.bounds().has_point(grid.cell_at(hit)):
		return Vector3.INF
	return hit


func hover(cell: Vector2i, elevation: float) -> void:
	if not _grid_layer.visible:
		return
	var rect := Rect2i(cell, Vector2i.ONE)
	if rect == _last_hover and elevation == _last_hover_y:
		return
	_last_hover = rect
	_last_hover_y = elevation
	_hover.clear_surfaces()
	_hover.surface_begin(Mesh.PRIMITIVE_LINES)
	_rect(_hover, rect, elevation + 0.075, Color("#e6ffff"))
	_hover.surface_end()


func clear_hover() -> void:
	if not _last_hover.has_area():
		return
	_last_hover = Rect2i()
	_hover.clear_surfaces()


func selection(rect: Rect2i, clearance: Rect2i, elevation: float) -> void:
	if rect == _last_selection and clearance == _last_clearance and elevation == _last_selection_y:
		return
	_last_selection = rect
	_last_clearance = clearance
	_last_selection_y = elevation
	_outline.clear_surfaces()
	_outline.surface_begin(Mesh.PRIMITIVE_LINES)
	_rect(_outline, rect, elevation + 0.083, SELECTED)
	if clearance != rect:
		_rect(_outline, clearance, elevation + 0.082, CLEARANCE, true)
	_outline.surface_end()
	_fill_box.size = Vector3(rect.size.x, 0.007, rect.size.y)
	_fill.position = grid.to_world(Vector2(rect.position) + Vector2(rect.size) * 0.5, elevation + 0.072)
	_fill.show()


func clear_selection() -> void:
	if not _last_selection.has_area():
		return
	_last_selection = Rect2i()
	_outline.clear_surfaces()
	_fill.hide()


func preview(item: Placement, valid: bool) -> void:
	var rect := item.footprint()
	var tint := VALID if valid else INVALID
	_ghost_box.size = Vector3(rect.size.x, item.height, rect.size.y)
	_ghost.position = item.center(grid) + Vector3(0, item.height * 0.5 + 0.025, 0)
	_ghost_material.albedo_color = Color(tint, 0.27)
	_ghost.show()
	_preview_outline.clear_surfaces()
	_preview_outline.surface_begin(Mesh.PRIMITIVE_LINES)
	_rect(_preview_outline, rect, item.elevation + 0.094, tint)
	_rect(_preview_outline, rect, item.elevation + item.height, tint)
	if item.required_area() != rect:
		_rect(_preview_outline, item.required_area(), item.elevation + 0.088, tint, true)
	_preview_outline.surface_end()


func clear_preview() -> void:
	_ghost.hide()
	_preview_outline.clear_surfaces()


func _grid_lines(rect: Rect2i, y: float) -> void:
	for x in range(rect.position.x, rect.end.x + 1):
		_line(_lines, Vector2(x, rect.position.y), Vector2(x, rect.end.y), y, _grid_color(x))
	for z in range(rect.position.y, rect.end.y + 1):
		_line(_lines, Vector2(rect.position.x, z), Vector2(rect.end.x, z), y, _grid_color(z))


func _grid_color(index: int) -> Color:
	return Color(0.40, 0.91, 0.93, 0.82) if index % 5 == 0 else Color(0.09, 0.20, 0.26, 0.43)


func _rect(mesh: ImmediateMesh, rect: Rect2i, y: float, tint: Color, dashed: bool = false) -> void:
	var corners := [Vector2(rect.position), Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end), Vector2(rect.position.x, rect.end.y)]
	for index in corners.size():
		var from: Vector2 = corners[index]
		var to: Vector2 = corners[(index + 1) % 4]
		if not dashed:
			_line(mesh, from, to, y, tint)
			continue
		var steps := ceili(from.distance_to(to))
		for step in steps:
			_line(mesh, from.lerp(to, float(step) / steps),
				from.lerp(to, (float(step) + 0.57) / steps), y, tint)


func _line(mesh: ImmediateMesh, from: Vector2, to: Vector2, y: float, tint: Color) -> void:
	mesh.surface_set_color(tint)
	mesh.surface_add_vertex(grid.to_world(from, y))
	mesh.surface_add_vertex(grid.to_world(to, y))


func _build_boundary_labels(deck: Rect2i) -> void:
	var draw := Primitives.new()
	_label(draw, Vector2(0.9, 0.6), 1.28, "(0, 0)")
	for x in _ticks(grid.size.x):
		_label(draw, Vector2(x, 0.42), 1.26, "X%d" % x)
		if x < grid.size.x and (x < deck.position.x or x > deck.end.x):
			_label(draw, Vector2(x, grid.size.y - 0.42), 1.9, "X%d" % x)
	for z in _ticks(grid.size.y):
		_label(draw, Vector2(0.47, z), 1.52, "Z%d" % z)
		if z < grid.size.y:
			_label(draw, Vector2(grid.size.x - 0.47, z), 1.52, "Z%d" % z)


func _ticks(limit: int) -> Array[int]:
	var ticks: Array[int] = []
	for index in range(5, limit - 1, 5):
		ticks.append(index)
	ticks.append(limit)
	return ticks


func _label(draw: Primitives, point: Vector2, elevation: float, copy: String) -> void:
	var label := draw.sign(_grid_layer, grid.to_world(point, elevation), copy, Color("#c8f6fb"))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.017
	label.no_depth_test = true


func _tint(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material


func _instance(parent: Node3D, mesh: Mesh, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance
