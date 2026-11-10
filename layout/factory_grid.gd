extends RefCounted
## Meter grid. Positive grid Z points toward the rear (negative world Z).

var size: Vector2i
var origin: Vector3


func _init(dimensions: Vector2i, front_left: Vector3 = Vector3.ZERO) -> void:
	size = dimensions
	origin = front_left


func bounds() -> Rect2i:
	return Rect2i(Vector2i.ZERO, size)


func to_world(point: Vector2, elevation: float = 0.0) -> Vector3:
	return origin + Vector3(point.x, elevation, -point.y)


func coordinates(point: Vector3) -> Vector2:
	return Vector2(point.x - origin.x, origin.z - point.z)


func cell_at(point: Vector3) -> Vector2i:
	return Vector2i(coordinates(point).floor())


func cell_center(cell: Vector2i, elevation: float = 0.0) -> Vector3:
	return to_world(Vector2(cell) + Vector2(0.5, 0.5), elevation)
