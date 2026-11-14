extends RefCounted
## Site details around the equipment: painted walkways with zebra crossings, yellow
## machine safety zones, department signs, an office and QC lab, a canteen with lockers,
## a maintenance workshop, a pallet store with forklift charging, and safety equipment.
##
## Nothing here changes routes or blocks anyone. Every item is checked against equipment,
## cart docks and the actual cart, worker, forklift and shuttle routes of the current
## layout, and is left out where it would sit on one of them. All parts are merged per
## material into one node, so the whole site costs about one draw call per material.

const Industrial = preload("res://world/industrial_models.gd")
const Primitives = preload("res://world/primitives.gd")
const Stock = preload("res://world/stock_models.gd")
const Layout = preload("res://layout/factory_layout.gd")

const WALKWAY := Color("#4a7a5c")
const WALK_EDGE := Color("#e8ece6")
const ZONE := Color("#e9b730")
const FLOOR_Y := 0.0
## Downloaded safety props (assets/props, see CREDITS.md), built by tools/blender/build_safety_props.py.
## Floor items have their origin at the base centre, wall items at the back face; fronts face +Z.
const PROP_MODELS := "res://assets/props/%s.glb"
const TILE := 1.0

var _kit: Industrial
var _draw: Primitives
var _stock: Stock
var _layout: Layout
var _root: Node3D
var _routes: Array = []
var _taken: Array[Rect2] = []
var _machines: Array[Rect2] = []
var _wood: StandardMaterial3D
var _white: StandardMaterial3D
var _office_wall: StandardMaterial3D
var _locker: StandardMaterial3D
var _red: StandardMaterial3D
var _green_sign: StandardMaterial3D
var _glazing: StandardMaterial3D
var _glass_door: StandardMaterial3D
var _models: Dictionary[String, Array] = {}


func build(parent: Node3D, layout: Layout, kit: Industrial, draw: Primitives, stock: Stock) -> Node3D:
	_kit = kit
	_draw = draw
	_stock = stock
	_layout = layout
	_root = Node3D.new()
	_root.name = "SiteDetails"
	parent.add_child(_root)
	_wood = stock.wood(Color("#b88a5c"))
	_white = kit.paint(Color("#eef0ee"))
	_office_wall = kit.paint(Color("#dfe4e6"))
	_locker = kit.paint(Color("#5d7c99"))
	_red = kit.paint(Color("#c8302a"))
	_glazing = kit.make_surface(Color("#a9c3cf"), 0.08, 0.2)
	_glass_door = kit.make_surface(Color("#8fb3c4"), 0.04, 0.35)
	_green_sign = kit.make_surface(Color("#1e7a3c"), 0.4, 0.0)
	_green_sign.emission_enabled = true
	_green_sign.emission = Color("#2fbf5d")
	_green_sign.emission_energy_multiplier = 0.9
	_collect_obstacles()
	_safety_zones()
	_walkways()
	_department_signs()
	_staff_rooms()
	_handler_desk()
	_kitting(Rect2(19.5, 41.5, 11, 9.5))
	_marshalling(Rect2(89, 54.6, 26, 3.6))
	_safety_points()
	_cartons()
	_draw.batch_static(_root)
	return _root


# --- Staff rooms ------------------------------------------------------------------

func _staff_rooms() -> void:
	# Lab, office and maintenance workshop form one block along the rear hall wall, sharing walls
	# (the workshop is the wide room on the right). The canteen and the changing room share a wall
	# against the finished goods warehouse's west wall. Doors face the open bay.
	var placed := {
		"lab": _lab(Rect2(33, 64.2, 9, 10.5), Vector2(37.5, 64.2), [1]),
		"office": _office(Rect2(42, 64.2, 11, 10.5), Vector2(47.5, 64.2), [1, 2]),
		"workshop": _workshop(Rect2(53, 64.2, 18, 10.5)),
		"changing": _changing_room(Rect2(75.6, 40.6, 11, 10), Vector2(75.6, 45.6), [3]),
		"canteen": _canteen(Rect2(75.6, 50.6, 11, 10), Vector2(75.6, 55.6), [3, 0])}
	for room in placed:
		if not placed[room]:
			push_warning("Site: no room for the " + room)


func _handler_desk() -> void:
	# The material handler's computer desk against the raw warehouse's west wall, facing east.
	if not _layout.has_handler_desk():
		return
	var at := _layout.grid.coordinates(_layout.handler_desk_furniture())
	var prop := _prop(at, PI * 0.5)
	_desk(prop, false)
	# Swivel chair where he waits (Layout.handler_desk, 1.05 m out from the desk); he sits on it.
	_chair(prop, Vector3(0, 0, 1.08), PI)
	_kit.box(prop, Vector3(0.62, 0.45, -0.15), Vector3(0.22, 0.9, 0.5), _kit.paint(Color("#3a4248")))
	var shelf := _prop(at + Vector2(-0.1, 1.3), PI * 0.5)
	_kit.box(shelf, Vector3(0, 0.45, 0), Vector3(0.7, 0.9, 0.5), _kit.paint(Color("#9aa4a8")))
	for y: float in [0.3, 0.6]:
		_kit.box(shelf, Vector3(0, y, 0.255), Vector3(0.5, 0.02, 0.006), _kit.seam)
	_commit(prop)
	_commit(shelf)


# --- Where things may go -------------------------------------------------------

func _collect_obstacles() -> void:
	var plan := _layout.objects
	for item: Layout.Placement in plan.values():
		if not is_zero_approx(item.elevation) and item.kind != &"platform":
			continue
		_taken.append(Rect2(item.required_area()).grow(0.2))
		_machines.append(Rect2(item.required_area()))
	var docks: Array[Vector3] = _layout._dock_points(plan)
	for area: Rect2 in _layout._dock_areas(docks).values():
		_taken.append(area.grow(0.2))
	var obstacles: Dictionary = _layout._obstacles(plan)
	var blockers: Dictionary = obstacles.duplicate()
	blockers.merge(_layout._dock_areas(docks))
	for dock in docks:
		_route(dock, _layout._aisle_approach(dock, _layout.cart_lane, 0.34, blockers), 1.0)
		_route(dock, _layout._aisle_approach(dock, _layout.walk_lane, 0.22, blockers), 0.7)
	var stops: Array[Vector3] = [_layout.supply_point("RM-WH", plan), _layout.supply_ground_point("RM-STAGE", plan)]
	for location in Layout.SUPPLY_STATIONS:
		if plan.has(Layout.SUPPLY_STATIONS[location]):
			stops.append(_layout.supply_point(location, plan))
	for stop in stops:
		_route(stop, _layout._aisle_approach(stop, _layout.supply_lane, 0.75, obstacles), 1.4)
	var home := _layout.lift_home()
	for index in Layout.PALLET_BAYS:
		var approach := _layout.pallet_approach(index, plan)
		_route(home, _layout.route(home, approach, _layout.lift_lane), 1.6)
		for slot in _layout.warehouse_position_count(plan):
			_route(approach, _layout.lift_to_slot(approach, slot, plan), 1.6)
	for slot in _layout.warehouse_position_count(plan):
		_route(_layout.warehouse_approach(slot, plan), _layout.lift_from_slot(slot, plan), 1.6)
	var entry := _layout.warehouse_entry_path(plan)
	_route(entry[0], entry.slice(1), 1.8)


func _route(start: Vector3, path: Array, radius: float) -> void:
	var points := PackedVector2Array([_layout.grid.coordinates(start)])
	for point: Vector3 in path:
		points.append(_layout.grid.coordinates(point))
	_routes.append([points, radius])


func _on_route(area: Rect2) -> bool:
	for row in _routes:
		var points: PackedVector2Array = row[0]
		var grown := area.grow(row[1])
		for index in range(1, points.size()):
			if _layout._segment_hits(points[index - 1], points[index], grown):
				return true
	return false


func _free(area: Rect2, allow_routes: bool = false) -> bool:
	var hall := Rect2(Vector2.ZERO, Vector2(_layout.grid.size)).grow(-0.3)
	if not hall.encloses(area) or area.position.y < 12.6:
		return false
	for taken in _taken:
		if taken.intersects(area):
			return false
	return allow_routes or not _on_route(area)


# --- Floor markings -------------------------------------------------------------

func _floor(cell: Vector2, size: Vector2, height: float, lift: float, surface: Material) -> void:
	_kit.box(_root, _layout.grid.to_world(cell, FLOOR_Y + lift), Vector3(size.x, height, size.y), surface)


func _safety_zones() -> void:
	# Yellow lines mark each machine's operating clearance.
	var paint := _kit.paint(ZONE)
	for item: Layout.Placement in _layout.objects.values():
		if item.kind != &"machine" or not is_zero_approx(item.elevation):
			continue
		var area := Rect2(item.required_area()).grow(-0.1)
		var middle := area.get_center()
		for y: float in [area.position.y, area.end.y]:
			_floor(Vector2(middle.x, y), Vector2(area.size.x, 0.08), 0.012, 0.022, paint)
		for x: float in [area.position.x, area.end.x]:
			_floor(Vector2(x, middle.y), Vector2(0.08, area.size.y), 0.012, 0.022, paint)


func _walkways() -> void:
	# Green pedestrian walkways linking the departments, the offices and the workshop. They run
	# straight through cart docks and routes; only tiles on equipment and its clearance are left out.
	var walks: Array[Rect2] = [
		Rect2(14, 38.4, 67.4, 1.5)]
	var green := _kit.make_surface(WALKWAY, 0.7, 0.0)
	var edge := _kit.paint(WALK_EDGE)
	var hall := Rect2(Vector2.ZERO, Vector2(_layout.grid.size)).grow(-0.3)
	for walk in walks:
		var along_x := walk.size.x >= walk.size.y
		var length := walk.size.x if along_x else walk.size.y
		var count := ceili(length / TILE)
		for index in count:
			var start := index * TILE
			var span := minf(TILE, length - start)
			var tile := Rect2(walk.position + (Vector2(start, 0) if along_x else Vector2(0, start)),
				Vector2(span, walk.size.y) if along_x else Vector2(walk.size.x, span))
			if not hall.encloses(tile) or _machines.any(func(area: Rect2) -> bool: return area.intersects(tile)):
				continue
			var middle := tile.get_center()
			_floor(middle, tile.size, 0.01, 0.012, green)
			for side: float in [-0.5, 0.5]:
				var line := middle + (Vector2(0, side * (walk.size.y - 0.08)) if along_x else Vector2(side * (walk.size.x - 0.08), 0))
				_floor(line, Vector2(span, 0.07) if along_x else Vector2(0.07, span), 0.01, 0.02, edge)
			if index % 6 == 3:
				_walker_symbol(middle, along_x, edge)


func _walker_symbol(at: Vector2, along_x: bool, surface: Material) -> void:
	# A simple pedestrian pictogram: head, body, stride.
	var forward := Vector2(1, 0) if along_x else Vector2(0, 1)
	var side := Vector2(0, 1) if along_x else Vector2(1, 0)
	_floor(at + forward * 0.32, Vector2(0.16, 0.16), 0.006, 0.024, surface)
	_floor(at + forward * 0.08, (Vector2(0.3, 0.08) if along_x else Vector2(0.08, 0.3)), 0.006, 0.024, surface)
	for s: float in [-1.0, 1.0]:
		_floor(at - forward * 0.18 + side * s * 0.08, (Vector2(0.24, 0.06) if along_x else Vector2(0.06, 0.24)), 0.006, 0.024, surface)


func _department_signs() -> void:
	# Hanging department boards over each process area.
	var groups := {
		"WAFER LINE": [&"Oven", &"Oven02", &"Coater", &"Coater02", &"CreamMixer", &"Spreader", &"Cutter", &"CoolingTunnel"],
		"PACKAGING": [&"Packer", &"Packer02", &"WalletPacker", &"BottleFiller", &"Palletizer"],
		"CHEWING GUM": [&"GumMixer", &"GumSheeter", &"FruitFormer", &"GumConditioner", &"GumPan01", &"GumPan02", &"GumPan03"],
	}
	var board := _kit.paint(Color("#22313b"))
	for title: String in groups:
		var sum := Vector3.ZERO
		var count := 0
		for id: StringName in groups[title]:
			if _layout.objects.has(id):
				sum += _layout.center(id)
				count += 1
		if count == 0:
			continue
		var at := sum / count + Vector3.UP * 6.4
		_kit.box(_root, at, Vector3(4.6, 0.9, 0.12), board)
		_kit.box(_root, at + Vector3(0, -0.47, 0), Vector3(4.6, 0.06, 0.13), _kit.paint(ZONE))
		for x: float in [-2.0, 2.0]:
			_kit.cylinder(_root, at + Vector3(x, 1.25, 0), 0.012, 2.1, _kit.polished, Industrial.Y, 6)
		for face: float in [1.0, -1.0]:
			var label := _draw.sign(_root, at + Vector3(0, 0.04, face * 0.065), title, Color("#f2f4f2"))
			label.pixel_size = 0.016
			label.outline_size = 0
			label.rotation.y = 0.0 if face > 0 else PI
			label.double_sided = false


# --- Areas ----------------------------------------------------------------------

func _area_free(area: Rect2) -> bool:
	return _free(area)


func _prop(cell: Vector2, yaw: float = 0.0) -> Node3D:
	var node := Node3D.new()
	node.position = _layout.grid.to_world(cell, FLOOR_Y)
	node.rotation.y = yaw
	_root.add_child(node)
	return node


func _commit(prop: Node3D) -> void:
	# Flatten a prop into the shared root so its parts merge with everything else.
	for child in prop.get_children():
		var part := child as Node3D
		var placed := prop.transform * part.transform
		prop.remove_child(part)
		_root.add_child(part)
		part.transform = placed
	_root.remove_child(prop)
	prop.free()


func _place(cell: Vector2, footprint: Vector2, yaw: float, builder: Callable) -> bool:
	var area := Rect2(cell - footprint * 0.5, footprint)
	if not _free(area):
		return false
	var prop := _prop(cell, yaw)
	builder.call(prop)
	_commit(prop)
	return true


## `skip` lists sides left open because a hall wall or a neighbouring room's wall stands there:
## 0 = near (-y) side, 1 = far (+y) side, 2 = west side, 3 = east side. The door may be on any of the other sides.
func _room_walls(area: Rect2, door: Vector2, title: String, skip: Array = [], door_width: float = 1.0, glass_door: bool = true) -> void:
	# Roofless modular room: solid lower panels, a glazed band and a top rail. The side holding
	# `door` gets an opening of `door_width`: a framed glass door, or left open for a roller door.
	# The room name is on a plate on the outside wall, at the upper right of the door.
	var k := _kit
	var height := 2.6
	var sides := [
		[Vector2(area.position.x, area.position.y), Vector2(area.end.x, area.position.y)],
		[Vector2(area.position.x, area.end.y), Vector2(area.end.x, area.end.y)],
		[Vector2(area.position.x, area.position.y), Vector2(area.position.x, area.end.y)],
		[Vector2(area.end.x, area.position.y), Vector2(area.end.x, area.end.y)]]
	for side_index in sides.size():
		if side_index in skip:
			continue
		var side: Array = sides[side_index]
		var a: Vector2 = side[0]
		var b: Vector2 = side[1]
		var length := a.distance_to(b)
		var along := (b - a) / length
		var at := (door - a).dot(along)
		var on_side := absf((door - a).cross(along)) < 0.05 and at > 0.0 and at < length
		if on_side:
			var half := door_width * 0.5
			_wall_run(a, a + along * (at - half), height)
			_wall_run(a + along * (at + half), b, height)
			var inward := area.get_center() - door
			_door(door, along, inward, door_width, height, title, glass_door)
		else:
			_wall_run(a, b, height)
		for corner in [a, b]:
			k.box(_root, _layout.grid.to_world(corner, FLOOR_Y + height * 0.5), Vector3(0.14, height, 0.14), k.frame_dark)


func _wall_run(a: Vector2, b: Vector2, height: float) -> void:
	# Straight wall from a to b (grid coordinates), in panels of about 1.2 m.
	var length := a.distance_to(b)
	if length < 0.05:
		return
	var k := _kit
	var horizontal := is_equal_approx(a.y, b.y)
	var steps := maxi(1, ceili(length / 1.2))
	var span := length / steps
	for index in steps:
		var middle := a.lerp(b, (index + 0.5) / steps)
		var size := Vector3(span, 0, 0.1) if horizontal else Vector3(0.1, 0, span)
		var base := _layout.grid.to_world(middle, FLOOR_Y)
		k.box(_root, base + Vector3.UP * 0.55, Vector3(size.x, 1.1, size.z), _office_wall)
		k.box(_root, base + Vector3.UP * 1.75, Vector3(size.x if horizontal else 0.05, 1.3, 0.05 if horizontal else size.z), _glazing)
		k.box(_root, base + Vector3.UP * (height - 0.1), Vector3(size.x, 0.2, size.z), _office_wall)
		k.box(_root, base + Vector3.UP * 1.12, Vector3(maxf(size.x, 0.14), 0.04, maxf(size.z, 0.14)), k.polished)


func _door(door: Vector2, along: Vector2, inward: Vector2, width: float, height: float, title: String, glass: bool) -> void:
	# Built in a frame where x runs along the wall (to the right seen from outside) and +z
	# points out of the room, so the plate lands at the visitor's upper right.
	var k := _kit
	var grid := _layout.grid
	var origin := grid.to_world(door, FLOOR_Y)
	var outward := origin - grid.to_world(door + inward.normalized(), FLOOR_Y)
	outward = Vector3(outward.x, 0, outward.z).normalized()
	var right := (-outward).cross(Vector3.UP)
	var frame := Node3D.new()
	frame.transform = Transform3D(Basis(right, Vector3.UP, outward), origin)
	_root.add_child(frame)
	var aluminium := k.make_surface(Color("#5f6a72"), 0.35, 0.6) if glass else k.frame_dark
	var leaf := 2.1
	if glass:
		# Aluminium frame, a glass leaf with stiles, kick plate and pull handles, and a glass
		# fanlight up to the top rail.
		for x: float in [-width * 0.5, width * 0.5]:
			k.box(frame, Vector3(x, height * 0.5, 0), Vector3(0.06, height, 0.12), aluminium)
		k.box(frame, Vector3(0, leaf + 0.03, 0), Vector3(width, 0.06, 0.12), aluminium)
		k.box(frame, Vector3(0, height - 0.1, 0), Vector3(width, 0.2, 0.1), _office_wall)
		k.box(frame, Vector3(0, (leaf + 0.06 + height - 0.2) * 0.5, 0), Vector3(width - 0.06, height - 0.26 - leaf, 0.03), _glazing)
		var inner := width - 0.1
		k.box(frame, Vector3(0, leaf * 0.5, 0), Vector3(inner - 0.1, leaf - 0.1, 0.02), _glass_door)
		for x: float in [-inner * 0.5 + 0.025, inner * 0.5 - 0.025]:
			k.box(frame, Vector3(x, leaf * 0.5, 0), Vector3(0.05, leaf, 0.05), aluminium)
		k.box(frame, Vector3(0, leaf - 0.04, 0), Vector3(inner, 0.07, 0.05), aluminium)
		k.box(frame, Vector3(0, 0.12, 0), Vector3(inner, 0.24, 0.05), aluminium)
		for z: float in [-1.0, 1.0]:
			k.box(frame, Vector3(inner * 0.5 - 0.12, 1.05, z * 0.07), Vector3(0.025, 0.6, 0.025), k.polished)
			for y: float in [0.82, 1.28]:
				k.box(frame, Vector3(inner * 0.5 - 0.12, y, z * 0.045), Vector3(0.02, 0.02, 0.05), k.polished)
		# Frosted manifestation band so the glass reads as a door.
		for z: float in [-0.012, 0.012]:
			k.box(frame, Vector3(0, 1.45, z), Vector3(inner - 0.1, 0.1, 0.004), _white)
	# Name plate on the wall, upper right of the door seen from outside.
	var plate_at := Vector3(width * 0.5 + 0.62, 2.12, 0.075)
	k.box(frame, plate_at, Vector3(0.92, 0.26, 0.02), k.paint(Color("#22313b")))
	k.box(frame, plate_at + Vector3(0, -0.105, 0.011), Vector3(0.86, 0.018, 0.002), k.safety)
	var label := _draw.sign(frame, plate_at + Vector3(0, 0.012, 0.012), title, Color("#f2f4f2"))
	label.font_size = 36
	label.outline_size = 0
	label.pixel_size = clampf(0.8 / (title.length() * 21.0), 0.0012, 0.0034)
	label.double_sided = false
	label.visibility_range_end = 60.0
	# Flatten the meshes into the room root so they merge; keep the label as it is.
	for child in frame.get_children():
		var part := child as Node3D
		var placed := frame.transform * part.transform
		frame.remove_child(part)
		_root.add_child(part)
		part.transform = placed
	_root.remove_child(frame)
	frame.free()


func _room_clear(area: Rect2, skip: Array) -> bool:
	# Clearance of half a metre around a room, except on the side that stands against a wall.
	var margin := [0.5, 0.5, 0.5, 0.5]  # left, top, right, bottom
	for side: int in skip:
		margin[[1, 3, 0, 2][side]] = 0.0
	return _area_free(area.grow_individual(margin[0], margin[1], margin[2], margin[3]))


func _office(office: Rect2, door: Vector2, skip: Array) -> bool:
	if not _room_clear(office, skip):
		return false
	_room_walls(office, door, "PRODUCTION OFFICE", skip)
	# Office: desks with screens and chairs, a meeting table, filing cabinets, plants.
	for row in 2:
		for column in 3:
			var at := office.position + Vector2(1.8 + column * 3.0, 3.2 + row * 3.6)
			var prop := _prop(at)
			_desk(prop)
			_commit(prop)
	var meeting := _prop(office.position + Vector2(office.size.x * 0.5, office.size.y - 2.0))
	_kit.box(meeting, Vector3(0, 0.74, 0), Vector3(2.6, 0.05, 1.1), _wood)
	for x: float in [-1.1, 1.1]:
		_kit.box(meeting, Vector3(x, 0.37, 0), Vector3(0.08, 0.72, 0.9), _kit.frame_dark)
	for x: float in [-0.8, 0.0, 0.8]:
		for z: float in [-0.85, 0.85]:
			_chair(meeting, Vector3(x, 0, z), 0.0 if z < 0 else PI)
	_commit(meeting)
	for index in 4:
		var cabinet := _prop(office.position + Vector2(0.5, 1.2 + index * 0.6))
		_kit.box(cabinet, Vector3(0, 0.66, 0), Vector3(0.6, 1.32, 0.5), _kit.paint(Color("#9aa4a8")))
		for y: float in [0.35, 0.7, 1.05]:
			_kit.box(cabinet, Vector3(0.3, y, 0), Vector3(0.012, 0.02, 0.3), _kit.polished)
		_commit(cabinet)
	for corner in [office.position + Vector2(0.6, office.size.y - 0.6), office.end - Vector2(0.6, 0.6)]:
		var plant := _prop(corner)
		_plant(plant)
		_commit(plant)
	return true


func _lab(lab: Rect2, door: Vector2, skip: Array) -> bool:
	if not _room_clear(lab, skip):
		return false
	_room_walls(lab, door, "QC LAB", skip)
	# QC lab: wall benches with sinks and instruments, a fume hood, a fridge and a central island.
	var bench := _kit.paint(Color("#e4e7e5"))
	for index in 3:
		var at := lab.position + Vector2(0.45, 2.0 + index * 2.6)
		var prop := _prop(at, PI * 0.5)
		_kit.box(prop, Vector3(0, 0.45, 0), Vector3(2.2, 0.9, 0.7), bench)
		_kit.box(prop, Vector3(0, 0.92, 0), Vector3(2.24, 0.04, 0.74), _kit.paint(Color("#30383c")))
		_kit.box(prop, Vector3(-0.6, 1.02, 0.05), Vector3(0.4, 0.16, 0.34), _white)
		_kit.box(prop, Vector3(0.4, 1.06, 0.05), Vector3(0.3, 0.24, 0.3), _kit.paint(Color("#3d6f8f")))
		_kit.box(prop, Vector3(0.4, 1.08, 0.205), Vector3(0.2, 0.08, 0.006), _kit.screen)
		_kit.cylinder(prop, Vector3(0.85, 1.04, 0.1), 0.05, 0.2, _kit.glass, Industrial.Y, 10)
		_commit(prop)
	var hood := _prop(Vector2(lab.end.x - 0.55, lab.position.y + 2.2), -PI * 0.5)
	_kit.box(hood, Vector3(0, 1.1, 0), Vector3(1.5, 2.2, 0.8), _white)
	_kit.box(hood, Vector3(0, 1.3, 0.405), Vector3(1.2, 0.7, 0.008), _kit.glass)
	_kit.cylinder(hood, Vector3(0, 2.4, -0.1), 0.15, 0.4, _kit.stainless_dark, Industrial.Y, 12)
	_commit(hood)
	var fridge := _prop(Vector2(lab.end.x - 0.45, lab.end.y - 1.2), -PI * 0.5)
	_kit.box(fridge, Vector3(0, 0.95, 0), Vector3(0.7, 1.9, 0.7), _white)
	_kit.box(fridge, Vector3(0.28, 1.1, 0.355), Vector3(0.03, 0.4, 0.03), _kit.polished)
	_commit(fridge)
	var island := _prop(lab.get_center() + Vector2(0.4, 0.6))
	_kit.box(island, Vector3(0, 0.45, 0), Vector3(2.4, 0.9, 1.2), bench)
	_kit.box(island, Vector3(0, 0.92, 0), Vector3(2.44, 0.04, 1.24), _kit.paint(Color("#30383c")))
	for x: float in [-0.7, 0.0, 0.7]:
		_kit.box(island, Vector3(x, 1.0, 0), Vector3(0.24, 0.12, 0.18), _kit.paint(Color("#e8475a").lerp(Color.WHITE, 0.4)))
	_commit(island)
	return true


func _canteen(canteen: Rect2, door: Vector2, skip: Array) -> bool:
	if not _room_clear(canteen, skip):
		return false
	_room_walls(canteen, door, "CANTEEN", skip)
	for row in 2:
		for column in 3:
			var table := _prop(canteen.position + Vector2(2.2 + column * 3.6, 3.4 + row * 4.0))
			_kit.box(table, Vector3(0, 0.74, 0), Vector3(1.8, 0.04, 0.8), _white)
			_kit.box(table, Vector3(0, 0.37, 0), Vector3(0.1, 0.72, 0.1), _kit.polished)
			_kit.box(table, Vector3(0, 0.02, 0), Vector3(0.6, 0.04, 0.6), _kit.frame_dark)
			for x: float in [-0.5, 0.5]:
				for z: float in [-0.65, 0.65]:
					_chair(table, Vector3(x, 0, z), 0.0 if z < 0 else PI)
			_commit(table)
	for index in 3:
		var vending := _prop(Vector2(canteen.end.x - 0.5, canteen.position.y + 2.0 + index * 1.1), -PI * 0.5)
		var shell := _kit.paint([Color("#c8302a"), Color("#2a5d9c"), Color("#2f7d4a")][index])
		_kit.box(vending, Vector3(0, 0.95, 0), Vector3(0.95, 1.9, 0.8), shell)
		_kit.box(vending, Vector3(-0.1, 1.15, 0.405), Vector3(0.6, 1.1, 0.008), _kit.screen)
		_kit.box(vending, Vector3(0.36, 1.0, 0.41), Vector3(0.12, 0.3, 0.01), _kit.seam)
		_commit(vending)
	var cooler := _prop(Vector2(canteen.end.x - 0.4, canteen.end.y - 1.0), -PI * 0.5)
	_water_cooler(cooler)
	_commit(cooler)
	return true


func _changing_room(lockers: Rect2, door: Vector2, skip: Array) -> bool:
	if not _room_clear(lockers, skip):
		return false
	_room_walls(lockers, door, "CHANGING & HYGIENE", skip)
	# Changing room: locker banks, a bench, white coats and a hand-wash trough at the exit.
	for bank in 2:
		var at := lockers.position + Vector2(0.4 + bank * (lockers.size.x - 0.8), lockers.size.y * 0.5)
		var row := _prop(at, PI * 0.5 if bank == 0 else -PI * 0.5)
		for index in 8:
			var x := -3.15 + index * 0.9
			_kit.box(row, Vector3(x, 0.95, 0), Vector3(0.86, 1.9, 0.5), _locker)
			_kit.box(row, Vector3(x, 0.95, 0.252), Vector3(0.006, 1.8, 0.006), _kit.seam)
			_kit.box(row, Vector3(x + 0.3, 1.0, 0.255), Vector3(0.03, 0.12, 0.012), _kit.polished)
			_kit.box(row, Vector3(x, 1.7, 0.253), Vector3(0.4, 0.06, 0.004), _kit.vent)
		_commit(row)
	var bench := _prop(lockers.get_center())
	_kit.box(bench, Vector3(0, 0.45, 0), Vector3(0.4, 0.05, 4.0), _wood)
	for z: float in [-1.6, 0.0, 1.6]:
		_kit.box(bench, Vector3(0, 0.22, z), Vector3(0.35, 0.44, 0.06), _kit.polished)
	_commit(bench)
	var wash := _prop(Vector2(lockers.get_center().x, lockers.position.y + 0.8))
	_hand_wash(wash)
	_commit(wash)
	return true


func _workshop(area: Rect2) -> bool:
	# Maintenance workshop built against the rear hall wall: a walled room with a roller
	# door, benches and tool boards on the hall wall, tool chests, a drill press, spares
	# racking, a parts washer and a chained gas cylinder rack.
	if not _area_free(area.grow_individual(0.0, 0.3, 0.3, 0.0)):
		return false
	var k := _kit
	var door := Vector2(area.get_center().x, area.position.y)
	_room_walls(area, door, "MAINTENANCE", [1, 2], 2.0, false)
	var housing := _layout.grid.to_world(door, FLOOR_Y + 2.25)
	k.box(_root, housing, Vector3(2.0, 0.34, 0.4), k.frame_dark)
	k.box(_root, housing + Vector3(0, -0.28, 0), Vector3(1.9, 0.22, 0.06), k.ribbed(Color("#aebdbf")))
	for side: float in [-1.0, 1.0]:
		var post := _layout.grid.to_world(door + Vector2(side * 1.1, -0.35), FLOOR_Y + 0.6)
		k.box(_root, post, Vector3(0.14, 1.2, 0.14), k.safety)
		k.box(_root, post + Vector3(0, 0.25, 0), Vector3(0.15, 0.12, 0.15), k.frame_dark)
	_floor(door + Vector2(0, -0.6), Vector2(2.0, 1.0), 0.01, 0.012, k.hazard)
	var rear := area.end.y - 0.45
	for index in 3:
		var bench := _prop(Vector2(area.position.x + 3.0 + index * 3.4, rear), PI)
		k.box(bench, Vector3(0, 0.88, 0), Vector3(2.4, 0.06, 0.8), _wood)
		k.box(bench, Vector3(0, 0.45, -0.25), Vector3(2.3, 0.7, 0.3), k.paint(Color("#3d6f8f")))
		for x: float in [-1.15, 1.15]:
			k.box(bench, Vector3(x, 0.44, 0.3), Vector3(0.05, 0.88, 0.05), k.frame_dark)
		k.box(bench, Vector3(0, 1.65, -0.4), Vector3(2.3, 1.1, 0.03), k.vent)
		for tool in 6:
			k.box(bench, Vector3(-0.9 + tool * 0.36, 1.65 + (tool % 2) * 0.2, -0.36), Vector3(0.05, 0.3, 0.03),
				k.paint([Color("#c8302a"), Color("#2b5ea8"), Color("#3d4448")][tool % 3]))
		k.box(bench, Vector3(0.7, 0.98, 0.1), Vector3(0.28, 0.14, 0.18), k.paint(Color("#2b5ea8")))
		k.cylinder(bench, Vector3(-0.6, 0.98, 0.0), 0.06, 0.14, k.signal_red, Industrial.Y, 10)
		k.box(bench, Vector3(-0.1, 0.93, 0.15), Vector3(0.3, 0.04, 0.2), k.stainless_dark)
		_commit(bench)
	for index in 3:
		var chest := _prop(Vector2(area.position.x + 0.55, area.position.y + 2.0 + index * 1.3), PI * 0.5)
		k.box(chest, Vector3(0, 0.55, 0), Vector3(1.0, 1.1, 0.5), _red)
		for y: float in [0.3, 0.5, 0.7, 0.9]:
			k.box(chest, Vector3(0, y, 0.255), Vector3(0.9, 0.012, 0.006), k.seam)
		k.caster(chest, Vector3(-0.4, 0.05, 0), 0.05)
		k.caster(chest, Vector3(0.4, 0.05, 0), 0.05)
		_commit(chest)
	var press := _prop(Vector2(area.get_center().x + 1.5, area.position.y + 4.2))
	k.box(press, Vector3(0, 0.05, 0), Vector3(0.6, 0.1, 0.5), k.frame_dark)
	k.cylinder(press, Vector3(0, 0.9, -0.1), 0.05, 1.7, k.polished, Industrial.Y, 10)
	k.box(press, Vector3(0, 1.6, 0.0), Vector3(0.3, 0.35, 0.5), k.paint(Color("#3f7a5c")))
	k.box(press, Vector3(0, 0.8, 0.05), Vector3(0.4, 0.04, 0.4), k.frame_dark)
	_commit(press)
	var washer := _prop(Vector2(area.get_center().x - 2.0, area.position.y + 4.2))
	k.box(washer, Vector3(0, 0.45, 0), Vector3(1.0, 0.9, 0.7), k.paint(Color("#3a8fd0")))
	k.box(washer, Vector3(0, 0.92, 0), Vector3(1.02, 0.04, 0.72), k.stainless)
	k.box(washer, Vector3(0, 1.3, -0.3), Vector3(1.0, 0.76, 0.04), k.stainless)
	_commit(washer)
	var racking := _prop(Vector2(area.end.x - 0.45, area.get_center().y - 0.6), -PI * 0.5)
	for y: float in [0.3, 0.9, 1.5, 2.1]:
		k.box(racking, Vector3(0, y, 0), Vector3(5.2, 0.03, 0.6), k.grating)
		for slot in 6:
			k.box(racking, Vector3(-2.2 + slot * 0.88, y + 0.13, 0), Vector3(0.6, 0.22, 0.42),
				k.paint([Color("#2b5ea8"), Color("#d9a32a"), Color("#c8302a")][(slot + int(y * 3)) % 3]))
	for x: float in [-2.6, 0.0, 2.6]:
		for z: float in [-0.3, 0.3]:
			k.box(racking, Vector3(x, 1.2, z), Vector3(0.05, 2.4, 0.05), k.paint(Color("#2f5d8a")))
	_commit(racking)
	var cylinders := _prop(Vector2(area.position.x + 0.5, rear - 1.0), PI * 0.5)
	k.box(cylinders, Vector3(0, 0.05, 0), Vector3(1.4, 0.1, 0.45), k.frame_dark)
	for index in 4:
		k.cylinder(cylinders, Vector3(-0.5 + index * 0.33, 0.8, 0), 0.11, 1.5,
			k.paint([Color("#3b6fb6"), Color("#7a7f82"), Color("#c8302a"), Color("#2f7d4a")][index]), Industrial.Y, 14)
		k.cylinder(cylinders, Vector3(-0.5 + index * 0.33, 1.6, 0), 0.045, 0.12, k.polished, Industrial.Y, 10)
	k.box(cylinders, Vector3(0, 1.1, 0.16), Vector3(1.4, 0.03, 0.02), k.safety)
	_commit(cylinders)
	return true


func _pallet_store(area: Rect2) -> void:
	if not _area_free(area.grow_individual(0.5, 0.5, 0.5, 0.0)):
		return
	# Empty pallet stacks, stretch-wrapped stock and the forklift battery charging bay.
	var k := _kit
	for row in 3:
		for column in 5:
			var at := area.position + Vector2(2.0 + column * 2.6, 2.0 + row * 3.0)
			var stack := _prop(at)
			var height := 3 + ((row * 5 + column) * 7) % 6
			for level in height:
				_stock.pallet_deck(stack, Vector3(0, level * 0.144, 0), Vector2(1.2, 1.0), 0.144)
			_commit(stack)
	for index in 3:
		var at := area.position + Vector2(area.size.x - 2.5, 2.2 + index * 2.4)
		var wrapped := _prop(at)
		_stock.pallet_deck(wrapped, Vector3.ZERO, Vector2(1.2, 1.0), 0.144)
		k.box(wrapped, Vector3(0, 0.75, 0), Vector3(1.16, 1.2, 0.96), _stock.cardboard(Color("#dba36a")))
		k.box(wrapped, Vector3(0, 0.76, 0), Vector3(1.2, 1.24, 1.0), k.film)
		_commit(wrapped)
	var charger := _prop(Vector2(area.end.x - 1.0, area.end.y - 2.0), -PI * 0.5)
	k.box(charger, Vector3(0, 0.75, 0), Vector3(0.9, 1.5, 0.5), k.paint(Color("#e6b52c")))
	k.box(charger, Vector3(0, 1.1, 0.255), Vector3(0.4, 0.2, 0.006), k.screen)
	k.box(charger, Vector3(0, 0.6, 0.255), Vector3(0.6, 0.4, 0.006), k.vent)
	k.pipe(charger, Vector3(0.3, 0.3, 0.3), Vector3(0.3, 0.05, 1.4), 0.025, k.rubber)
	_commit(charger)
	var bay := Rect2(Vector2(area.end.x - 4.0, area.end.y - 4.0), Vector2(3.0, 3.6))
	for corner: Vector2 in [bay.position, Vector2(bay.end.x, bay.position.y)]:
		var cone := _prop(corner + Vector2(0, -0.45))
		_cone(cone)
		_commit(cone)
	for y: float in [bay.position.y, bay.end.y]:
		_floor(Vector2(bay.get_center().x, y), Vector2(bay.size.x, 0.1), 0.012, 0.022, k.paint(ZONE))
	for x: float in [bay.position.x, bay.end.x]:
		_floor(Vector2(x, bay.get_center().y), Vector2(0.1, bay.size.y), 0.012, 0.022, k.paint(ZONE))


func _kitting(area: Rect2) -> void:
	# Raw material kitting: pallets of weighed sacks and cartons staged in marked bays.
	if not _area_free(area.grow(0.5)):
		return
	var k := _kit
	var paint := k.paint(ZONE)
	for row in 2:
		for column in 4:
			var at := area.position + Vector2(1.3 + column * 2.8, 2.2 + row * 4.6)
			for y: float in [at.y - 0.75, at.y + 0.75]:
				_floor(Vector2(at.x, y), Vector2(1.6, 0.06), 0.012, 0.022, paint)
			for x: float in [at.x - 0.8, at.x + 0.8]:
				_floor(Vector2(x, at.y), Vector2(0.06, 1.5), 0.012, 0.022, paint)
			if (row * 4 + column) % 3 == 2:
				continue
			var pallet := _prop(at)
			_stock.pallet_deck(pallet, Vector3.ZERO, Vector2(1.2, 1.0), 0.144)
			if (row + column) % 2 == 0:
				for layer in 3:
					for side: float in [-0.25, 0.25]:
						var sack := _stock.sack(pallet, Vector3(0, 0.27 + layer * 0.2, side), 0.62)
						sack.rotation.y = PI * 0.5 * float(layer % 2)
			else:
				for layer in 2:
					for x: float in [-0.29, 0.29]:
						_stock.carton(pallet, Vector3(x, 0.32 + layer * 0.36, 0), Vector3(0.56, 0.34, 0.9))
			_flatten_nested(pallet)
			_commit(pallet)
	var sign := _draw.sign(_root, _layout.grid.to_world(area.get_center() + Vector2(0, -area.size.y * 0.5 - 0.2), FLOOR_Y + 0.03),
		"KITTING", Color("#e9b730"))
	sign.rotation_degrees.x = -90
	sign.pixel_size = 0.02
	sign.outline_size = 0


func _marshalling(area: Rect2) -> void:
	# Outbound marshalling lanes in front of the finished goods store, with wrapped pallets.
	if not _area_free(area.grow(0.3)):
		return
	var k := _kit
	var paint := k.paint(ZONE)
	var colours := [Color("#5974bc"), Color("#c18c55"), Color("#2f9e8f"), Color("#e8475a"), Color("#3a8fd0")]
	for lane in 5:
		var x := area.position.x + 1.6 + lane * 5.0
		for side: float in [-1.0, 1.0]:
			_floor(Vector2(x + side * 0.85, area.get_center().y), Vector2(0.08, area.size.y - 0.6), 0.012, 0.022, paint)
		for slot in maxi(1, floori(area.size.y / 3.0)):
			var pallet := _prop(Vector2(x, area.position.y + 1.6 + slot * 3.0))
			_stock.pallet_deck(pallet, Vector3.ZERO, Vector2(1.2, 1.0), 0.144)
			var tint := _stock.cardboard(colours[lane].lerp(Color("#dba36a"), 0.45))
			for layer in 3:
				for offset: float in [-0.29, 0.29]:
					k.box(pallet, Vector3(offset, 0.32 + layer * 0.34, 0), Vector3(0.56, 0.32, 0.96), tint)
			k.box(pallet, Vector3(0, 1.17, 0), Vector3(1.18, 0.012, 0.98), k.film)
			_commit(pallet)


func _flatten_nested(prop: Node3D) -> void:
	# Stock helpers build sacks and cartons as small groups; lift their parts into the prop.
	for child in prop.get_children():
		var group := child as Node3D
		if group == null or group is MeshInstance3D and group.get_child_count() == 0:
			continue
		for part in group.get_children():
			var piece := part as Node3D
			var placed := group.transform * piece.transform
			group.remove_child(piece)
			prop.add_child(piece)
			piece.transform = placed
		if not group is MeshInstance3D:
			prop.remove_child(group)
			group.free()


func _safety_points() -> void:
	# Fire points, recycling bins and hand-wash stations at the walkway corners,
	# plus green emergency exit signs along the walls.
	var spots: Array[Vector2] = [Vector2(13.0, 40.6), Vector2(50.6, 40.6), Vector2(80.0, 40.6), Vector2(84.0, 51.0),
		Vector2(116.0, 51.0), Vector2(30.0, 54.6), Vector2(87.0, 54.6), Vector2(55.0, 68.8), Vector2(30.0, 68.8)]
	for index in spots.size():
		var spot := spots[index]
		match index % 3:
			0: _place(spot, Vector2(0.8, 0.6), 0.0, _fire_point)
			1: _place(spot, Vector2(1.6, 0.7), 0.0, _bins)
			_: _place(spot, Vector2(1.4, 0.8), 0.0, _hand_wash)
	# Drinking water on the hall floor: the first free spot beside a walkway corner.
	for spot: Vector2 in [Vector2(52.4, 40.6), Vector2(82.0, 40.6), Vector2(86.0, 51.0), Vector2(14.8, 40.6),
			Vector2(57.0, 68.8), Vector2(32.0, 68.8)]:
		if _place(spot, Vector2(0.7, 0.7), 0.0, _water_cooler):
			break
	var size := Vector2(_layout.grid.size)
	for y in range(20, int(size.y) - 36, 14):
		_place(Vector2(0.55, y), Vector2(0.5, 0.9), PI * 0.5, _wall_point)
	for x in range(36, 84, 12):
		# Grid y runs along world -Z, so yaw 0 puts the board's back to the far wall.
		_place(Vector2(x, size.y - 0.55), Vector2(0.9, 0.5), 0.0, _wall_point)


# --- Props ----------------------------------------------------------------------

func _desk(prop: Node3D, with_chair: bool = true) -> void:
	var k := _kit
	k.box(prop, Vector3(0, 0.74, 0), Vector3(1.6, 0.04, 0.8), _wood)
	for x: float in [-0.75, 0.75]:
		k.box(prop, Vector3(x, 0.37, 0), Vector3(0.05, 0.72, 0.7), k.frame_dark)
	k.box(prop, Vector3(0, 1.0, -0.25), Vector3(0.6, 0.36, 0.03), k.seam)
	k.box(prop, Vector3(0, 1.0, -0.233), Vector3(0.56, 0.32, 0.004), k.screen)
	k.box(prop, Vector3(0, 0.8, -0.25), Vector3(0.05, 0.12, 0.05), k.frame_dark)
	k.box(prop, Vector3(0, 0.77, 0.08), Vector3(0.45, 0.02, 0.15), k.seam)
	if with_chair:
		_chair(prop, Vector3(0, 0, 0.75), PI)


func _chair(prop: Node3D, at: Vector3, yaw: float) -> void:
	var k := _kit
	var basis := Basis(Vector3.UP, yaw)
	var seat := k.box(prop, at + Vector3(0, 0.46, 0), Vector3(0.45, 0.07, 0.45), k.rubber)
	seat.basis = basis
	var back := k.box(prop, at + basis * Vector3(0, 0.78, -0.21), Vector3(0.42, 0.5, 0.06), k.rubber)
	back.basis = basis
	k.cylinder(prop, at + Vector3(0, 0.24, 0), 0.025, 0.42, k.polished, Industrial.Y, 8)
	k.cylinder(prop, at + Vector3(0, 0.03, 0), 0.26, 0.04, k.frame_dark, Industrial.Y, 10)


func _plant(prop: Node3D) -> void:
	var leaves := _kit.make_surface(Color("#3f7d3a"), 0.7, 0.0)
	_kit.cylinder(prop, Vector3(0, 0.25, 0), 0.22, 0.5, _kit.paint(Color("#e2ddd2")), Industrial.Y, 14, 0.26)
	_draw.sphere(prop, Vector3(0, 0.85, 0), Vector3(0.7, 0.8, 0.7), Color.WHITE).material_override = leaves
	_draw.sphere(prop, Vector3(0.12, 1.15, 0.05), Vector3(0.45, 0.5, 0.45), Color.WHITE).material_override = leaves


func _hand_wash(prop: Node3D) -> void:
	# Food-plant hygiene point: stainless trough with knee-operated taps, soap and towels.
	var k := _kit
	k.box(prop, Vector3(0, 0.82, 0), Vector3(1.3, 0.22, 0.5), k.stainless)
	k.box(prop, Vector3(0, 0.4, -0.15), Vector3(1.2, 0.8, 0.12), k.stainless)
	for x: float in [-0.35, 0.35]:
		k.pipe(prop, Vector3(x, 0.95, -0.2), Vector3(x, 1.15, -0.2), 0.015, k.polished)
		k.pipe(prop, Vector3(x, 1.15, -0.2), Vector3(x, 1.15, -0.05), 0.015, k.polished)
	k.box(prop, Vector3(0, 1.45, -0.22), Vector3(0.24, 0.3, 0.1), _white)
	k.box(prop, Vector3(0.5, 1.35, -0.22), Vector3(0.3, 0.4, 0.12), _white)
	k.box(prop, Vector3(-0.5, 1.45, -0.21), Vector3(0.28, 0.2, 0.08), k.paint(Color("#3a8fd0")))
	_model(prop, "wet_floor_sign", Vector3(0.48, 0.0, 0.45), -0.4)


func _fire_point(prop: Node3D) -> void:
	var k := _kit
	k.box(prop, Vector3(0, 1.0, -0.15), Vector3(0.6, 2.0, 0.05), _red)
	for x: float in [-0.15, 0.15]:
		_model(prop, "fire_extinguisher", Vector3(x, 0.04, -0.02))
	_model(prop, "fire_alarm", Vector3(0, 1.25, -0.125))
	k.box(prop, Vector3(0, 1.65, -0.12), Vector3(0.36, 0.36, 0.01), _white)
	k.box(prop, Vector3(0, 1.65, -0.114), Vector3(0.22, 0.22, 0.006), _red)
	k.box(prop, Vector3(0, 0.025, 0), Vector3(0.7, 0.02, 0.5), k.paint(Color("#c8302a").lerp(Color.WHITE, 0.15)))


func _bins(prop: Node3D) -> void:
	# Colour-coded waste segregation: general, plastic and paper.
	var colors := [Color("#3d4448"), Color("#e6b52c"), Color("#2a5d9c")]
	for index in 3:
		var x := -0.5 + index * 0.5
		_kit.box(prop, Vector3(x, 0.42, 0), Vector3(0.42, 0.84, 0.5), _kit.paint(colors[index]))
		_kit.box(prop, Vector3(x, 0.86, 0), Vector3(0.44, 0.04, 0.52), _kit.paint(colors[index].darkened(0.2)))
		_kit.box(prop, Vector3(x, 0.55, 0.252), Vector3(0.2, 0.2, 0.004), _white)


func _wall_point(prop: Node3D) -> void:
	# Fire extinguisher on its board with an emergency exit sign above.
	var k := _kit
	k.box(prop, Vector3(0, 1.2, -0.2), Vector3(0.7, 1.0, 0.04), _white)
	_model(prop, "fire_extinguisher", Vector3(-0.12, 0.72, -0.1))
	_model(prop, "fire_alarm", Vector3(0.2, 1.3, -0.18))
	_model(prop, "first_aid_kit", Vector3(0.16, 0.95, -0.18), 0.0, 0.9)
	k.box(prop, Vector3(-0.12, 1.55, -0.17), Vector3(0.24, 0.2, 0.01), _red)
	# Illuminated exit sign: the printed sign in front of a lit backbox.
	k.box(prop, Vector3(0, 2.6, -0.18), Vector3(0.64, 0.24, 0.04), _green_sign)
	_model(prop, "exit_sign", Vector3(0, 2.49, -0.158), 0.0, 1.45)
	k.box(prop, Vector3(0.0, 0.45, -0.19), Vector3(0.4, 0.55, 0.12), k.paint(Color("#9aa4a8")))


func _cone(prop: Node3D) -> void:
	_model(prop, "traffic_cone", Vector3.ZERO, 0.3, 0.9)


func _water_cooler(prop: Node3D) -> void:
	# Bottled water dispenser on a drip mat, with a cup dispenser on its side.
	_kit.box(prop, Vector3(0, 0.006, 0.05), Vector3(0.55, 0.012, 0.55), _kit.rubber)
	_model(prop, "water_cooler", Vector3(0, 0.012, 0))
	_kit.cylinder(prop, Vector3(0.22, 0.95, 0.0), 0.04, 0.32, _white, Industrial.Y, 10)


## Adds a downloaded model to a prop. Each material becomes its own single-surface mesh
## marked mergeable, so the site batching merges every copy of it with the rest.
func _model(prop: Node3D, name: String, at: Vector3, yaw: float = 0.0, scale_factor: float = 1.0) -> void:
	if not _models.has(name):
		var parts: Array = []
		var scene := load(PROP_MODELS % name) as PackedScene
		if scene != null:
			var root := scene.instantiate()
			for node in root.find_children("*", "MeshInstance3D", true, false):
				var source := node as MeshInstance3D
				var placed := _relative(root, source)
				for surface in source.mesh.get_surface_count():
					var tool := SurfaceTool.new()
					tool.append_from(source.mesh, surface, placed)
					var mesh := tool.commit()
					mesh.set_meta("mergeable", true)
					parts.append([mesh, source.get_active_material(surface)])
			root.free()
		_models[name] = parts
	for part: Array in _models[name]:
		var piece := MeshInstance3D.new()
		piece.mesh = part[0]
		piece.material_override = part[1]
		piece.transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_factor), at)
		prop.add_child(piece)


func _relative(root: Node, node: Node3D) -> Transform3D:
	var placed := node.transform
	var parent := node.get_parent()
	while parent != root and parent is Node3D:
		placed = (parent as Node3D).transform * placed
		parent = parent.get_parent()
	return placed


# --- Loose cartons -----------------------------------------------------------------

func _cartons() -> void:
	# Corrugated boxes left around the floor: opened with flaps in all directions, ripped,
	# crushed flat, or broken down into sheets. Seeded, so every build looks the same.
	var random := RandomNumberGenerator.new()
	random.seed = 4021
	var areas: Array[Rect2] = [Rect2(56, 31, 26, 7), Rect2(55, 21, 20, 4), Rect2(19, 41, 12, 10), Rect2(58, 82, 26, 5),
		Rect2(34, 82, 20, 3), Rect2(84, 40, 32, 8), Rect2(14, 31, 30, 7), Rect2(87, 58, 30, 3), Rect2(76, 53.5, 10, 6)]
	var placed := 0
	for attempt in 220:
		if placed >= 46:
			break
		var area := areas[attempt % areas.size()]
		var at := area.position + Vector2(random.randf() * area.size.x, random.randf() * area.size.y)
		var kind := random.randi() % 5
		var size := Vector3(random.randf_range(0.35, 0.6), random.randf_range(0.22, 0.4), random.randf_range(0.3, 0.5))
		var yaw := random.randf() * TAU
		var seed := random.randi()
		if _place(at, Vector2(0.9, 0.9), yaw, func(prop: Node3D) -> void: _loose_carton(prop, kind, size, seed)):
			placed += 1


func _loose_carton(prop: Node3D, kind: int, size: Vector3, seed: int) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var outside := _stock.cardboard(Color("#cf9a62").darkened(random.randf() * 0.12))
	var inside := _stock.cardboard(Color("#b07e4c"))
	match kind:
		0, 1:
			# Open box: four walls, a bottom and flaps folded out at different angles.
			var missing := 1 if kind == 1 else -1
			_open_box(prop, size, outside, inside, random, missing)
			if kind == 1:
				# The torn-off side lies next to the box.
				var torn := _kit.box(prop, Vector3(size.x * 0.5 + 0.25, 0.006, 0.05), Vector3(size.z * 0.8, 0.008, size.y * 0.7), outside)
				torn.rotation = Vector3(0, random.randf() * TAU, random.randf_range(-0.08, 0.08))
		2:
			# Crushed: squashed flat and skewed, with creases and flaps splayed.
			var body := _kit.box(prop, Vector3(0, size.y * 0.12, 0), Vector3(size.x * 1.15, size.y * 0.24, size.z * 1.1), outside)
			body.rotation = Vector3(random.randf_range(-0.12, 0.12), 0, random.randf_range(-0.15, 0.15))
			for index in 2:
				var crease := _kit.box(prop, Vector3(-0.1 + index * 0.2, size.y * 0.25, 0), Vector3(0.012, 0.012, size.z), _kit.seam)
				crease.rotation.y = random.randf_range(-0.4, 0.4)
			for side: float in [-1.0, 1.0]:
				var flap := _kit.box(prop, Vector3(side * (size.x * 0.75), 0.01, 0), Vector3(size.x * 0.45, 0.008, size.z * 0.9), outside)
				flap.rotation = Vector3(0, random.randf_range(-0.3, 0.3), side * 0.08)
			var tape := _kit.box(prop, Vector3(0, size.y * 0.25, 0), Vector3(0.05, 0.004, size.z * 1.1), _stock.cardboard(Color("#c9a874")))
			tape.rotation = body.rotation
		3:
			# Broken down into sheets, overlapping on the floor.
			for index in 2 + random.randi() % 2:
				var sheet := _kit.box(prop, Vector3(random.randf_range(-0.15, 0.15), 0.005 + index * 0.009, random.randf_range(-0.15, 0.15)),
					Vector3(size.x * 1.6, 0.007, size.z * 1.4), outside if index % 2 == 0 else inside)
				sheet.rotation.y = random.randf_range(-0.6, 0.6)
				_kit.box(prop, sheet.position + Vector3(0, 0.005, 0), Vector3(0.012, 0.004, size.z * 1.3), _kit.seam).rotation.y = sheet.rotation.y
		_:
			# A closed carton lying on its side with one flap popped open.
			var box := _stock.carton(prop, Vector3(0, size.z * 0.5, 0), Vector3(size.x, size.z, size.y))
			box.rotation.z = random.randf_range(-0.05, 0.05)
			var flap := _kit.box(prop, Vector3(size.x * 0.5 + 0.08, size.z * 0.85, 0), Vector3(0.18, 0.008, size.y * 0.95), outside)
			flap.rotation.z = -0.9
			_flatten_nested(prop)


func _open_box(prop: Node3D, size: Vector3, outside: Material, inside: Material, random: RandomNumberGenerator, missing: int) -> void:
	var k := _kit
	var wall := 0.01
	k.box(prop, Vector3(0, wall * 0.5, 0), Vector3(size.x, wall, size.z), inside)
	var faces := [[Vector3(0, 0, 1), size.x], [Vector3(0, 0, -1), size.x], [Vector3(1, 0, 0), size.z], [Vector3(-1, 0, 0), size.z]]
	for index in faces.size():
		var normal: Vector3 = faces[index][0]
		var width: float = faces[index][1]
		var along_z := absf(normal.x) > 0.5
		var half := (size.x if along_z else size.z) * 0.5
		var height := size.y * (0.55 if index == missing else 1.0)
		var at := normal * half + Vector3.UP * height * 0.5
		k.box(prop, at, Vector3(wall, height, width) if along_z else Vector3(width, height, wall), outside)
		if index == missing:
			continue
		# Flap hinged on the top edge, opened between upright and lying flat outward.
		var angle := random.randf_range(0.25, 2.2)
		var length := (size.z if not along_z else size.x) * 0.5
		var direction := Vector3(normal.x * sin(angle), cos(angle), normal.z * sin(angle))
		var flap := k.box(prop, normal * half + Vector3.UP * size.y + direction * length * 0.5,
			Vector3(width, length, wall) if not along_z else Vector3(wall, length, width), outside)
		if along_z:
			flap.rotation.z = -angle * normal.x
		else:
			flap.rotation.x = angle * normal.z
