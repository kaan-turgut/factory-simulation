extends RefCounted
## Roofless stock room and proximity-operated roll-up shutters.

const Room = preload("res://layout/warehouse_room.gd")
const Primitives = preload("res://world/primitives.gd")
const Line = preload("res://simulation/production_line.gd")
const Industrial = preload("res://world/industrial_models.gd")

const CLADDING := Color("#788a92")
const PANEL := Color("#475c66")
const CONCRETE := Color("#899594")
const FRAME := Color("#293f4b")
const GUIDE := Color("#edbe61")
const SHUTTER := Color("#aebdbf")
const SLAT_EDGE := Color("#83989c")
const OPEN := Color("#79e4a2")
const CLOSED := Color("#eb805f")


class Door extends Node3D:
	var curtain: Node3D
	var lamp: MeshInstance3D
	var width: float
	var height: float
	var requested := 0.0
	var raised := 0.0

	func sense(point: Vector3, target: Vector3, heading: float, reach: Vector3) -> void:
		if requested == 1.0 or absf(point.y - global_position.y) > 0.6:
			return
		var offset := to_local(point)
		if absf(offset.x) > width * 0.5 + 0.7:
			return
		var depth := absf(offset.z)
		if depth >= 6.8:
			return
		var forward := Vector3(sin(heading), 0.0, cos(heading))
		var normal := forward.dot(global_basis.z) * signf(-offset.z)
		var side := absf(forward.dot(global_basis.x))
		var clearance := absf(normal) * (reach.y if normal > 0.0 else reach.z) + side * reach.x
		if depth <= clearance + 0.14:
			requested = 1.0
		elif offset.z * (to_local(target).z - offset.z) < -0.001:
			requested = maxf(requested, 1.0 - smoothstep(clearance + 0.55, 6.8, depth))

	func update(delta: float, draw: Primitives) -> void:
		# Proximity sets the minimum safe opening even at 20× speed.
		# Closing is eased so the curtain stays clear as the vehicle leaves.
		var next := maxf(requested, move_toward(raised, 0.0, delta * 0.8))
		requested = 0.0
		if next == raised:
			return
		raised = next
		curtain.position.y = height * raised
		curtain.scale.y = maxf(0.001, 1.0 - raised)
		curtain.visible = raised < 0.999
		lamp.material_override = draw.material(OPEN if raised > 0.94 else GUIDE if raised > 0.01 else CLOSED)


var doors: Array[Door] = []
var _draw: Primitives
var _kit: Industrial


func _init(parent: Node3D, draw: Primitives, room: Room, accent: Color, kit: Industrial) -> void:
	_draw = draw
	_kit = kit
	var shell := Node3D.new()
	shell.name = "StockRoom"
	parent.add_child(shell)
	for area in room.walls:
		_panel(shell, area, room.height, accent)
	for opening in room.openings:
		_build_shutter(shell, opening, room.door_height, accent)
		var lintel := room.height - room.door_height - 0.60
		if lintel > 0.01:
			var cap := _draw.box(shell, Vector3(opening.center.x, room.height - lintel * 0.5, opening.center.y),
				Vector3(opening.width, lintel, Room.WALL_DEPTH), CLADDING)
			cap.rotation.y = opening.yaw
	for area in room.racks:
		if room.rack_bays > 0:
			_rack(shell, room, area, accent)
	_draw.batch_static(shell)


func animate(line: Line, delta: float) -> void:
	var alpha := line.interpolation()
	_sense(line.forklift, alpha, Vector3(0.88, 2.22, 1.31))
	if line.erp != null:
		_sense(line.erp.material_handler, alpha, Vector3(0.60, 1.56, 1.25))
	for worker in line.floor_crew:
		_sense(worker, alpha, Vector3(0.47, 1.32, 0.49))
	for door in doors:
		door.update(delta, _draw)


func _sense(actor: Line.Operator, alpha: float, reach: Vector3) -> void:
	var point := actor.previous_position.lerp(actor.position, alpha)
	var target := point if actor._route.is_empty() else actor._route[0]
	for door in doors:
		door.sense(point, target, actor.heading, reach)


func _panel(parent: Node3D, area: Rect2, height: float, accent: Color) -> void:
	var center := area.get_center()
	_draw.box(parent, Vector3(center.x, height * 0.5, center.y),
		Vector3(area.size.x, height, area.size.y), CLADDING).material_override = _kit.ribbed(CLADDING)
	var horizontal := area.size.x > area.size.y
	var span := maxf(area.size.x, area.size.y)
	var axis := Vector3.RIGHT if horizontal else Vector3.BACK
	var at := Vector3(center.x, 0.0, center.y)
	var edge := Vector3(area.size.x + (0.0 if horizontal else 0.05), 0.16,
		area.size.y + (0.05 if horizontal else 0.0))
	_draw.box(parent, at + Vector3.UP * 0.11, edge * Vector3(1, 1.65, 1), CONCRETE)
	_draw.box(parent, at + Vector3.UP * (height - 0.08), edge, FRAME)
	_draw.box(parent, at + Vector3.UP * 0.57, edge * Vector3(1, 0.48, 1), accent)
	for index in range(1, ceili(span / 0.62)):
		var seam := axis * (-span * 0.5 + index * 0.62)
		var rib := Vector3(0.048, height - 0.70, Room.WALL_DEPTH + 0.04)
		if not horizontal:
			rib = Vector3(rib.z, rib.y, rib.x)
		_draw.box(parent, at + seam + Vector3.UP * (height * 0.5 + 0.23), rib, PANEL)


func _rack(parent: Node3D, room: Room, area: Rect2, accent: Color) -> void:
	# Selective pallet racking: perforated frames with diagonal bracing, step beams in the
	# room accent, wire mesh decks, base plates and column guards on the aisle side.
	var k := _kit
	var upright := k.paint(Color("#2f5d8a"))
	var beam := k.paint(accent)
	var center := area.get_center()
	var front := area.end.y - 0.09
	var rear := area.position.y + 0.09
	var depth := front - rear
	for bay in room.rack_bays + 1:
		var x := lerpf(area.position.x + 0.08, area.end.x - 0.08, float(bay) / room.rack_bays)
		for z: float in [rear, front]:
			k.box(parent, Vector3(x, Room.RACK_HEIGHT * 0.5, z), Vector3(0.1, Room.RACK_HEIGHT, 0.08), upright)
			k.box(parent, Vector3(x, Room.RACK_HEIGHT * 0.5, z + (0.041 if z == front else -0.041)),
				Vector3(0.05, Room.RACK_HEIGHT - 0.1, 0.003), k.vent)
			k.box(parent, Vector3(x, 0.006, z), Vector3(0.18, 0.012, 0.16), k.frame_dark)
		k.box(parent, Vector3(x, 0.4, front + 0.13), Vector3(0.22, 0.8, 0.12), k.safety)
		k.box(parent, Vector3(x, 0.4, front + 0.191), Vector3(0.16, 0.6, 0.003), k.hazard)
		# Frame bracing: horizontals at the ends and alternating diagonals between.
		var panel := 0.9
		var rises := floori((Room.RACK_HEIGHT - 0.3) / panel)
		var diagonal := sqrt(depth * depth + panel * panel)
		for index in rises:
			var y := 0.15 + index * panel
			var brace := k.box(parent, Vector3(x, y + panel * 0.5, center.y), Vector3(0.03, 0.03, diagonal), upright)
			brace.rotation.x = atan2(panel, depth) * (1.0 if index % 2 == 0 else -1.0)
		for y: float in [0.15, Room.RACK_HEIGHT - 0.15]:
			k.box(parent, Vector3(x, y, center.y), Vector3(0.03, 0.03, depth), upright)
	for y in room.rack_levels:
		for z: float in [rear, front]:
			k.box(parent, Vector3(center.x, y, z + (0.06 if z == front else -0.06)),
				Vector3(area.size.x, 0.12, 0.05), beam)
		# Mesh decks keep stock on the lower levels visible from overhead.
		k.box(parent, Vector3(center.x, y + 0.064, center.y), Vector3(area.size.x - 0.12, 0.008, depth - 0.02), k.grating)
		for part in range(1, room.rack_bays * 3):
			var x := area.position.x + area.size.x * part / (room.rack_bays * 3.0)
			k.box(parent, Vector3(x, y + 0.035, center.y), Vector3(0.04, 0.05, depth - 0.02), k.stainless_dark)


func _build_shutter(parent: Node3D, opening: Room.Opening, height: float, accent: Color) -> void:
	var door := Door.new()
	door.name = "RollUpShutter"
	door.width = opening.width
	door.height = height
	door.position = Vector3(opening.center.x, 0, opening.center.y)
	door.rotation.y = opening.yaw
	parent.add_child(door)
	doors.append(door)
	var width := opening.width
	for side: float in [-1.0, 1.0]:
		var x := side * (width * 0.5 + 0.065)
		_draw.box(door, Vector3(x, height * 0.5, 0), Vector3(0.13, height, 0.23), FRAME)
		_draw.box(door, Vector3(x, 0.44, 0.10), Vector3(0.13, 0.88, 0.04), GUIDE)
		for stripe in 3:
			var at := _draw.box(door, Vector3(x, 0.17 + stripe * 0.25, 0.127),
				Vector3(0.145, 0.066, 0.017), FRAME)
			at.rotation.z = 0.33
	_draw.box(door, Vector3(0, height + 0.30, 0), Vector3(width + 0.22, 0.60, 0.37), FRAME)
	_draw.box(door, Vector3(0, height + 0.43, 0.19), Vector3(width + 0.22, 0.11, 0.045), accent)
	_draw.box(door, Vector3(0, 0.025, 0), Vector3(width, 0.025, 0.28), GUIDE)
	door.curtain = Node3D.new()
	door.curtain.name = "SlattedCurtain"
	door.add_child(door.curtain)
	_draw.box(door.curtain, Vector3(0, height * 0.5, 0), Vector3(width, height, 0.095), SHUTTER)
	for index in range(1, ceili(height / 0.17)):
		_draw.box(door.curtain, Vector3(0, index * 0.17, 0), Vector3(width, 0.028, 0.125), SLAT_EDGE)
	_draw.box(door.curtain, Vector3(0, 0.06, 0), Vector3(width, 0.12, 0.16), FRAME)
	_draw.batch_static(door.curtain)
	door.lamp = _draw.box(door, Vector3(width * 0.5 - 0.25, height + 0.16, 0.20),
		Vector3(0.17, 0.12, 0.05), CLOSED)
	_draw.batch_static(door, [door.lamp])
