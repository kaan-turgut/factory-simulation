extends Node3D
## Picking, selection marks, status lights and inventory slots shared by equipment.

const Primitives = preload("res://world/primitives.gd")
const Grid = preload("res://layout/factory_grid.gd")

var inventory_slots: Array[Node3D] = []
var beacon: MeshInstance3D
var _readout: Label3D
var _selection: Node3D
var _body: StaticBody3D


func configure(
	id: StringName, primitives: Primitives, size: Vector3, title: String, accent: Color,
	show_readout: bool = true, pick_offset: Vector3 = Vector3.ZERO, create_hitbox: bool = true
) -> void:
	name = id
	_body = StaticBody3D.new()
	_body.collision_layer = 2
	_body.collision_mask = 0
	_body.set_meta("equipment", id)
	add_child(_body)
	if create_hitbox:
		add_hitbox(size, pick_offset)

	_readout = primitives.sign(self, Vector3(0, size.y + 0.68, 0), title, Color.WHITE)
	_readout.pixel_size = 0.021
	_readout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_readout.no_depth_test = true
	_readout.modulate = accent.lightened(0.56)
	_readout.visible = show_readout

	_selection = Node3D.new()
	_selection.position = pick_offset
	_selection.name = "SelectionMarks"
	add_child(_selection)
	for x: float in [-1.0, 1.0]:
		for z: float in [-1.0, 1.0]:
			var corner := Vector3(x * (size.x * 0.5 + 0.15), 0.055, z * (size.z * 0.5 + 0.15))
			primitives.box(_selection, corner - Vector3(x * 0.38, 0, 0),
				Vector3(0.85, 0.055, 0.10), accent)
			primitives.box(_selection, corner - Vector3(0, 0, z * 0.38),
				Vector3(0.10, 0.055, 0.85), accent)
	_selection.hide()


func add_hitbox(size: Vector3, ground_offset: Vector3) -> void:
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	collider.position = ground_offset + Vector3(0, size.y * 0.5, 0)
	_body.add_child(collider)


func offset_readout(offset: Vector3) -> void:
	_readout.position += offset


func occupied_cells(grid: Grid) -> Rect2i:
	var collider := _body.get_child(0) as CollisionShape3D
	var half := (collider.shape as BoxShape3D).size * 0.5
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for x: float in [-half.x, half.x]:
		for z: float in [-half.z, half.z]:
			var point := grid.coordinates(collider.to_global(Vector3(x, 0, z)))
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	return Rect2i(Vector2i(minimum.floor()), Vector2i(maximum.ceil() - minimum.floor()))


func select(selected: bool) -> void:
	_selection.visible = selected


func set_active(active: bool) -> void:
	if visible != active:
		visible = active
		_body.collision_layer = 2 if active else 0


func update_machine(title: String, state: String, color: Color) -> void:
	_readout.text = "%s\n%s" % [title, state]
	_readout.modulate = color.lightened(0.24)
	if beacon != null:
		var lamp := beacon.material_override as StandardMaterial3D
		lamp.albedo_color = color
		lamp.emission = color


func fill_slots(fill: float) -> void:
	var occupied := fill * inventory_slots.size()
	for index in inventory_slots.size():
		var fraction := clampf(occupied - index, 0.0, 1.0)
		var slot := inventory_slots[index]
		slot.visible = fraction > 0.0
		slot.scale.y = maxf(0.12, fraction)
