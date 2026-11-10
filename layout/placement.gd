extends RefCounted
## Geometry of one layout object. Stock capacities are defined by the simulation.

const Grid = preload("res://layout/factory_grid.gd")

var id: StringName
var kind: StringName
var cell: Vector2i
var size: Vector2i
var height: float
var elevation: float
var turns: int
var clearance: Vector4i
var ports: Dictionary[StringName, Vector3]
var movable: bool


func _init(
	key: StringName, object_type: StringName, anchor: Vector2i, dimensions: Vector2i,
	height_m: float, y: float = 0.0, orientation: int = 0,
	margins: Vector4i = Vector4i.ZERO, connections: Dictionary[StringName, Vector3] = {},
	can_move: bool = false
) -> void:
	id = key
	kind = object_type
	cell = anchor
	size = dimensions
	height = height_m
	elevation = y
	turns = posmod(orientation, 4)
	clearance = margins
	ports = connections.duplicate()
	movable = can_move


func at(anchor: Vector2i, orientation: int) -> RefCounted:
	var definition: GDScript = get_script()
	return definition.new(id, kind, anchor, size, height, elevation, orientation, clearance, ports, movable)


func footprint() -> Rect2i:
	var oriented := size if turns % 2 == 0 else Vector2i(size.y, size.x)
	return Rect2i(cell, oriented)


func required_area() -> Rect2i:
	var margins := clearance
	for quarter_turn in turns:
		margins = Vector4i(margins.w, margins.x, margins.y, margins.z)
	var body := footprint()
	return Rect2i(body.position - Vector2i(margins.x, margins.y),
		body.size + Vector2i(margins.x + margins.z, margins.y + margins.w))


func center(grid: Grid) -> Vector3:
	return grid.to_world(Vector2(cell) + Vector2(footprint().size) * 0.5, elevation)


func yaw() -> float:
	return turns * PI * 0.5


func local_point(grid: Grid, offset: Vector3) -> Vector3:
	return center(grid) + Vector3(offset.x, offset.y, -offset.z).rotated(Vector3.UP, yaw())


func port(grid: Grid, key: StringName) -> Vector3:
	return local_point(grid, ports[key])
