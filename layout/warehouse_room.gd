extends RefCounted
## Room boundaries in equipment-local X/Z coordinates. Shared by routing and the 3D shell.

const WALL_DEPTH := 0.14
const RACK_HEIGHT := 6.0
const FG_RACK_BAYS := 4
const FG_ROWS := 3
const FG_SLOTS_PER_ROW := FG_RACK_BAYS * 2
## Ground positions of the finished-goods racks. Each holds one pallet per level.
const FG_SLOT_COUNT := FG_ROWS * FG_SLOTS_PER_ROW
## Ground plus three beam levels; slot index = level * FG_SLOT_COUNT + position.
const FG_LEVELS := 4
const FG_CAPACITY := FG_SLOT_COUNT * FG_LEVELS
## Pallet floor height per level (the beam tops of the rack drawn in the room).
const FG_LEVEL_HEIGHTS: Array[float] = [0.0, 1.95, 3.90, 5.82]
const FG_RACK_DEPTH := 1.75
const FG_APPROACH := 1.95
const FG_TURN_AHEAD := 1.50

class Opening:
	var center: Vector2
	var width: float
	var yaw: float

	func _init(at: Vector2, span: float, angle: float) -> void:
		center = at
		width = span
		yaw = angle


var walls: Array[Rect2] = []
var racks: Array[Rect2] = []
var rack_levels: Array[float] = []
var rack_bays := 0
var openings: Array[Opening] = []
var height: float
var door_height: float


func _init(size: Vector2i, finished_goods: bool) -> void:
	if high_bay(size):
		_build_high_bay(size, finished_goods)
		return
	height = 3.78 if finished_goods else 3.18
	door_height = 3.18 if finished_goods else 2.58
	var edge := (Vector2(size) - Vector2.ONE * WALL_DEPTH) * 0.5
	# Recess the FG walls beside the cooling and packing approaches.
	var right := edge.x - 0.96 if finished_goods else edge.x
	var back := -edge.y + 0.40 if finished_goods else -edge.y
	var front_gap := right + edge.x - 0.12 if finished_goods else 3.6
	_wall(-edge.x, right, edge.y, false, (right - edge.x) * 0.5, front_gap)
	_wall(-edge.x, right, back, false)
	_wall(back, edge.y, -edge.x, true)
	_wall(back, edge.y, right, true, -0.35, 3.82 if finished_goods else 0.0)
	if not finished_goods:
		# Leave the center lane open for material pickups.
		for row: Vector2 in [Vector2(-6.5, 1.7), Vector2(-4.53, 1.7), Vector2(-2.56, 1.7),
				Vector2(2.97, 2.25), Vector2(5.93, 2.25)]:
			racks.append(Rect2(Vector2(row.x - row.y * 0.5, -1.40), Vector2(row.y, 1.33)))


static func high_bay(size: Vector2i) -> bool:
	return size.x >= 20 and size.y >= 20


static func finished_slot(size: Vector2i, index: int) -> Vector2:
	var side := -1.0 if index % FG_SLOTS_PER_ROW < FG_RACK_BAYS else 1.0
	var column := (index % FG_RACK_BAYS + 0.5 - FG_RACK_BAYS * 0.5) * _finished_spacing(size)
	return Vector2(side * size.x * 0.29 + column, size.y * 0.27 * (1 - floori(float(index) / FG_SLOTS_PER_ROW)))


static func _finished_spacing(size: Vector2i) -> float:
	return size.x * 0.375 / FG_RACK_BAYS


static func raw_dock(size: Vector2i) -> Vector2:
	return Vector2(0, size.y * 0.5 - 5.0) if high_bay(size) else Vector2.ZERO


func _build_high_bay(size: Vector2i, finished_goods: bool) -> void:
	height = 6.4
	door_height = 3.85 if finished_goods else 3.35
	var edge := (Vector2(size) - Vector2.ONE * WALL_DEPTH) * 0.5
	_wall(-edge.x, edge.x, edge.y, false, 0.0, 6.0 if finished_goods else 5.2)
	_wall(-edge.x, edge.x, -edge.y, false)
	_wall(-edge.y, edge.y, -edge.x, true)
	_wall(-edge.y, edge.y, edge.x, true)
	if finished_goods:
		rack_bays = FG_RACK_BAYS
		rack_levels.assign(FG_LEVEL_HEIGHTS.slice(1))
		var spacing := _finished_spacing(size)
		var span := Vector2(spacing * rack_bays, FG_RACK_DEPTH)
		for index in range(0, FG_SLOT_COUNT, rack_bays):
			var center := finished_slot(size, index) + Vector2(spacing * (rack_bays - 1) * 0.5, 0)
			racks.append(Rect2(center - span * 0.5, span))
	else:
		rack_bays = 3
		rack_levels.assign([0.28, 2.15, 4.02, 5.82])
		var span := Vector2(size.x * 0.33, 2.1)
		for row: Vector2 in [Vector2(-0.27, 0.26), Vector2(-0.27, 0.0), Vector2(-0.27, -0.26),
				Vector2(0.27, 0.18), Vector2(0.27, -0.18)]:
			racks.append(Rect2(row * Vector2(size) - span * 0.5, span))


func _wall(start: float, end: float, offset: float, side: bool, center: float = 0.0, gap: float = 0.0) -> void:
	if gap <= 0.0:
		_panel(start, end, offset, side)
		return
	_panel(start, center - gap * 0.5, offset, side)
	_panel(center + gap * 0.5, end, offset, side)
	openings.append(Opening.new(Vector2(offset, center) if side else Vector2(center, offset),
		gap, PI * 0.5 if side else 0.0))


func _panel(start: float, end: float, offset: float, side: bool) -> void:
	if end <= start:
		return
	var thickness_start := offset - WALL_DEPTH * 0.5
	walls.append(Rect2(thickness_start, start, WALL_DEPTH, end - start) if side
		else Rect2(start, thickness_start, end - start, WALL_DEPTH))
