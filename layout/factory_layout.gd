extends RefCounted
## Chocolate Works floor plan. Equipment anchors, loading points and routes share this model.

const Master = preload("res://erp/master_files.gd")
const Grid = preload("res://layout/factory_grid.gd")
const Placement = preload("res://layout/placement.gd")
const Rules = preload("res://layout/placement_rules.gd")
const WarehouseRoom = preload("res://layout/warehouse_room.gd")

const DEFAULT_SIZE := Vector2i(120, 100)
const MIN_SIZE := Vector2i(120, 32)
const PREVIOUS_SIZE := Vector2i(128, 40)
const ORIGIN := Vector3(-32, 0, 13)
const PLATFORM_HEIGHT := 3.5
## Routing lanes of the original floor plan (grid y). A layout file may define its own `lanes`;
## saves from before lanes were data use these values.
const CART_LANE := 11.2
const WALK_LANE := 9.45
const SUPPLY_LANE := 2.15
const LIFT_LANE := 5.8
const REAR_LANE := 17.4
const PALLET_BAYS := 3
const LEGACY_WAREHOUSE_SLOTS := 8
const MAX_CREW := 4
const MAX_CARTS := 4
const CART_BODY := Vector3(1.22, 1.75, 1.49)
const CART_OFFSET := Vector3(0, 0, 0.67)

# Port offsets use local +X right, +Y up, +Z rear, measured from the footprint center.
const LINKS := {
	&"CartonBelt": [&"Packer", &"belt_out", &"Palletizer", &"belt_in"]
}

const LINKED_GROUPS := [[&"Extruder", &"Hopper"], [&"Packer", &"PackagingWIP", &"Palletizer"]]
const SUPPLY_STATIONS := {"COAT-IN": &"Coater", "COAT-IN-02": &"Coater02", "PACK-IN": &"Packer", "CREAM-IN": &"CreamMixer", "PACK-IN-02": &"Packer02",
	"GUM-IN": &"GumMixer", "GUM-PAN-IN": &"GumPan02", "GUM-PACK-IN": &"WalletPacker"}
## Supply locations used by several neighbouring stations. Deliveries go to the station
## named in SUPPLY_STATIONS; the others draw from the same staged stock.
const SHARED_SUPPLY := {"GUM-PAN-IN": [&"GumPan01", &"GumPan02", &"GumPan03"], "GUM-PACK-IN": [&"WalletPacker", &"BottleFiller"]}


static func supplies(location: String, station: StringName) -> bool:
	return SUPPLY_STATIONS.get(location) == station or station in SHARED_SUPPLY.get(location, [])

var error := ""
## Identifies the floor plan family. Saved layouts only apply to the plan they were made for.
var plan_id := "legacy"
## True for saves made before lanes were layout data: they keep the original lanes and defaults.
var legacy := false
var supply_lane := SUPPLY_LANE
var lift_lane := LIFT_LANE
var walk_lane := WALK_LANE
var cart_lane := CART_LANE
var rear_lane := REAR_LANE
var _lane_extras := {}
var grid: Grid
var objects: Dictionary[StringName, Placement] = {}
## Equipment that joined the master data after a saved layout was written.
var appended: Array[StringName] = []
var reserved: Array[Rect2i] = []
var _route_obstacles := {}
var _cart_blockers := {}
var _approaches := {}


func _init(dimensions: Vector2i = Vector2i.ZERO, directory: String = "", snapshot: Dictionary = {}, legacy_plan: bool = false) -> void:
	error = _load(dimensions, directory, snapshot, legacy_plan)


static func warehouse_cell_after_resize(cell: Vector2i, turns: int, previous: Vector2i, current: Vector2i) -> Vector2i:
	if current == DEFAULT_SIZE and previous in [PREVIOUS_SIZE, Vector2i(88, 32)] \
			and turns == 0 and cell == Vector2i(previous.x - 11, 14):
		# Move the former stock rack position clear of Packing 02's cart approach.
		return Vector2i(103, 13)
	return cell + Vector2i(current.x - previous.x, 0)


func _load(dimensions: Vector2i, directory: String, snapshot: Dictionary, legacy_plan: bool = false) -> String:
	var file := "factory_layout_legacy" if legacy_plan else "factory_layout"
	var result := Master.read(file, directory) if snapshot.is_empty() else {"error": "", "data": snapshot}
	if not result.error.is_empty():
		return result.error
	if not result.data is Dictionary or not _numbers(result.data.get("size"), 2, true, 1) or not result.data.get("objects") is Array:
		return "%s.json: expected size and equipment definitions." % file
	var data: Dictionary = result.data
	legacy = legacy_plan or (not snapshot.is_empty() and not data.has("lanes"))
	var problem := _read_lanes(data, legacy)
	if not problem.is_empty():
		return problem
	var configured := Vector2i(int(data.size[0]), int(data.size[1]))
	if snapshot.is_empty() and configured != configured.max(MIN_SIZE):
		return "factory_layout.json size: too small for factory aisles."
	grid = Grid.new(configured if dimensions == Vector2i.ZERO else dimensions.max(MIN_SIZE), ORIGIN)
	var width := grid.size.x
	var definitions: Array = data.objects.duplicate(true)
	if not snapshot.is_empty():
		var defaults := Master.read("factory_layout_legacy" if legacy else "factory_layout", directory)
		if not defaults.error.is_empty():
			return defaults.error
		var missing := false
		for row in defaults.data.objects:
			if not definitions.any(func(saved: Dictionary) -> bool: return saved.get("id") == row.id):
				definitions.append(row)
				appended.append(StringName(row.id))
				missing = true
		if missing:
			for definition in definitions:
				if definition.id == "Palletizer" and not definition.ports.has("cart_dock"):
					for row in defaults.data.objects:
						if row.id == "Palletizer":
							definition.ports["cart_dock"] = row.ports.cart_dock
							break
			grid = Grid.new(grid.size.max(Vector2i(defaults.data.size[0], defaults.data.size[1])), ORIGIN)
			width = grid.size.x
	for row in definitions:
		if not row is Dictionary or not row.get("id") is String or row.id.is_empty() or objects.has(StringName(row.id)):
			return "factory_layout.json: missing or duplicate equipment ID."
		if not row.get("kind") is String or not _numbers(row.get("cell"), 2, true) \
			or not _numbers(row.get("size"), 2, true, 1) or not _numbers(row.get("clearance"), 4, true) \
			or not Master.number(row.get("height"), 0.001) or not Master.number(row.get("elevation")) \
			or not Master.number(row.get("turns"), 0, 3, true) or not row.get("ports") is Dictionary or not row.get("movable") is bool:
			return "factory_layout.json [%s]: invalid footprint, elevation, clearance, orientation or ports." % row.id
		var ports: Dictionary[StringName, Vector3] = {}
		for key in row.ports:
			var point: Array = row.ports[key] if row.ports[key] is Array else []
			if not _numbers(point, 3, false, -INF):
				return "factory_layout.json [%s].ports.%s: expected three finite coordinates." % [row.id, key]
			ports[StringName(key)] = Vector3(point[0], point[1], point[2])
		var cell := Vector2i(int(row.cell[0]), int(row.cell[1]))
		var size := Vector2i(int(row.size[0]), int(row.size[1]))
		if row.id == "Warehouse" and dimensions != Vector2i.ZERO:
			cell.x += width - configured.x
		if row.id in ["RawWarehouse", "Warehouse"] and WarehouseRoom.high_bay(size):
			cell.y += grid.size.y - configured.y
		var movable: bool = row.movable
		if not snapshot.is_empty() and not snapshot.has("placement_revision"):
			movable = movable or StringName(row.id) in [&"Extruder", &"Hopper", &"PackagingWIP", &"Palletizer", &"Warehouse"]
		_define(Placement.new(StringName(row.id), StringName(row.kind), cell,
			size, row.height, row.elevation, int(row.turns),
			Vector4i(int(row.clearance[0]), int(row.clearance[1]), int(row.clearance[2]), int(row.clearance[3])), ports, movable))
	var required := {&"Platform":[&"pick_0", &"pick_1"], &"Stairs":[], &"Hopper":[&"drop_0", &"drop_1", &"outlet"],
		&"Extruder":[&"feed", &"raw_dock"], &"Oven":[&"raw_dock", &"cooked_dock"], &"Oven02":[&"raw_dock", &"cooked_dock"],
		&"Coater":[&"cooked_dock", &"coated_dock", &"supply"], &"Coater02":[&"cooked_dock", &"coated_dock", &"supply"],
		&"Packer":[&"belt_out", &"supply"], &"PackagingWIP":[&"coated_dock"],
		&"Palletizer":[&"belt_in"], &"Warehouse":[], &"RawParking":[], &"CookedParking":[], &"CoatedParking":[], &"RawWarehouse":[], &"SFGWarehouse":[&"stock_dock"]}
	for key in required:
		if not objects.has(key):
			return "factory_layout.json: missing required equipment %s." % key
		for port_id in required.get(key, []):
			if not objects[key].ports.has(port_id):
				return "factory_layout.json [%s].ports.%s: required dock." % [key, port_id]
	if _lane_extras.has("reserved"):
		reserved = []
		for row: Array in _lane_extras.reserved:
			reserved.append(Rect2i(int(row[0]), int(row[1]), int(row[2]), int(row[3])))
		return ""
	var cart_end := cart_aisle_end()
	var lift_start := cart_end - 2
	reserved = [Rect2i(0, 0, width, 2), Rect2i(0, 8, cart_end, 2),
		Rect2i(0, 10, cart_end, 2), Rect2i(lift_start, 4, width - lift_start, 3)]
	return ""


## Lanes are grid y values. `legacy` plans always use the constants above.
func _read_lanes(data: Dictionary, legacy_plan: bool) -> String:
	supply_lane = SUPPLY_LANE
	lift_lane = LIFT_LANE
	walk_lane = WALK_LANE
	cart_lane = CART_LANE
	rear_lane = REAR_LANE
	_lane_extras = {}
	plan_id = "legacy"
	if legacy_plan or not data.has("lanes"):
		return ""
	var lanes: Variant = data.lanes
	if not lanes is Dictionary:
		return "factory_layout.json lanes: expected a lane definition."
	for key in ["supply", "lift", "walk", "cart", "rear"]:
		if not Master.number(lanes.get(key), 0.5, 1000.0):
			return "factory_layout.json lanes.%s: expected a position in metres." % key
	supply_lane = float(lanes.supply)
	lift_lane = float(lanes.lift)
	walk_lane = float(lanes.walk)
	cart_lane = float(lanes.cart)
	rear_lane = float(lanes.rear)
	for key in ["aisle_end", "lift_home_x"]:
		if lanes.has(key):
			if not Master.number(lanes[key], 1.0, 1000.0):
				return "factory_layout.json lanes.%s: expected a position in metres." % key
			_lane_extras[key] = float(lanes[key])
	if lanes.has("reserved"):
		if not lanes.reserved is Array:
			return "factory_layout.json lanes.reserved: expected rectangles."
		for row in lanes.reserved:
			if not _numbers(row, 4, true):
				return "factory_layout.json lanes.reserved: expected [x, y, width, height] cells."
		_lane_extras["reserved"] = lanes.reserved.duplicate(true)
	plan_id = String(data.get("plan", "aisle"))
	return ""


func lanes_snapshot() -> Dictionary:
	if legacy:
		return {}
	var lanes := {"supply": supply_lane, "lift": lift_lane, "walk": walk_lane, "cart": cart_lane, "rear": rear_lane}
	lanes.merge(_lane_extras)
	return lanes


func snapshot() -> Dictionary:
	var rows := []
	for item in objects.values():
		var ports := {}
		for key in item.ports:
			var point: Vector3 = item.ports[key]
			ports[String(key)] = [point.x, point.y, point.z]
		rows.append({"id": String(item.id), "kind": String(item.kind), "cell": [item.cell.x, item.cell.y],
			"size": [item.size.x, item.size.y], "height": item.height, "elevation": item.elevation,
			"turns": item.turns, "clearance": [item.clearance.x, item.clearance.y, item.clearance.z, item.clearance.w],
			"ports": ports, "movable": item.movable})
	var data := {"size": [grid.size.x, grid.size.y], "objects": rows, "placement_revision": 1}
	if not legacy:
		data["lanes"] = lanes_snapshot()
		data["plan"] = plan_id
	return data


func _numbers(values: Variant, count: int, whole: bool, low: float = 0.0) -> bool:
	if not values is Array or values.size() != count:
		return false
	for value in values:
		if not Master.number(value, low, INF, whole):
			return false
	return true


func supply_point(location: String, plan: Dictionary = objects) -> Vector3:
	if location == "RM-STAGE":
		return grid.to_world(Vector2(1.0, 10.0))
	if SUPPLY_STATIONS.has(location):
		return port(SUPPLY_STATIONS[location], &"supply", plan)
	if location == "RM-WH":
		var room: Placement = plan[&"RawWarehouse"]
		return _room_point(room, WarehouseRoom.raw_dock(room.size))
	return grid.to_world(Vector2(10.0, supply_lane))


func supply_route(from: Vector3, target: Vector3) -> Array[Vector3]:
	return _floor_route(from, target, supply_lane, 0.75)


func _define(item: Placement) -> void:
	assert(not objects.has(item.id), "Duplicate layout ID")
	objects[item.id] = item


func center(id: StringName, plan: Dictionary = objects) -> Vector3:
	return plan[id].center(grid)


func port(id: StringName, name: StringName, plan: Dictionary = objects) -> Vector3:
	return plan[id].port(grid, name)


func lane_z(lane: float) -> float:
	return grid.to_world(Vector2(0, lane)).z


func platform_pick(index: int) -> Vector3:
	return port(&"Platform", StringName("pick_%d" % index))


func platform_drop(index: int) -> Vector3:
	return port(&"Hopper", StringName("drop_%d" % index))


func crew_home(index: int) -> Vector3:
	return grid.to_world(Vector2(7.0 + index * 1.3, 8.05))


func cart_home(index: int, raw: bool) -> Vector3:
	var offsets := [0.0, 1.55, 3.1, 6.75]
	var parking := objects[&"RawParking" if raw else &"CookedParking"]
	var x: float = -2.75 + index * 1.62 if raw else -3.5 + offsets[index]
	return parking.local_point(grid, Vector3(x, 0, -0.1))


func coated_cart_home(index: int) -> Vector3:
	return objects[&"CoatedParking"].local_point(grid, Vector3(-3.5 + index * 2.0, 0, -0.1))


func cart_heading(point: Vector3) -> float:
	return 0.0 if point.z > lane_z(cart_lane) else PI


func cart_body_center(point: Vector3) -> Vector3:
	return point + CART_OFFSET.rotated(Vector3.UP, cart_heading(point))


func pallet_position(index: int, plan: Dictionary = objects) -> Vector3:
	return plan[&"Palletizer"].local_point(grid, Vector3(-2.65 + index * 2.65, 0, -2.35))


func pallet_approach(index: int, plan: Dictionary = objects) -> Vector3:
	return pallet_position(index, plan) + Vector3(0, 0, 1.65).rotated(Vector3.UP, plan[&"Palletizer"].yaw())


func warehouse_slot_count(plan: Dictionary = objects) -> int:
	return WarehouseRoom.FG_SLOT_COUNT if WarehouseRoom.high_bay(plan[&"Warehouse"].size) else LEGACY_WAREHOUSE_SLOTS


func warehouse_slot(index: int, plan: Dictionary = objects) -> Vector3:
	var room: Placement = plan[&"Warehouse"]
	if WarehouseRoom.high_bay(room.size):
		return _room_point(room, WarehouseRoom.finished_slot(room.size, index))
	return room.local_point(grid, Vector3(-3.60 + (index % 4) * 2.2,
		0, -2.55 + floori(index / 4.0) * 5.2))


func warehouse_approach(index: int, plan: Dictionary = objects) -> Vector3:
	var room: Placement = plan[&"Warehouse"]
	var distance := WarehouseRoom.FG_APPROACH if WarehouseRoom.high_bay(room.size) else 1.65
	return warehouse_slot(index, plan) + Vector3(0, 0, distance).rotated(Vector3.UP, room.yaw())


func warehouse_entry_path(plan: Dictionary = objects) -> Array[Vector3]:
	var room: Placement = plan[&"Warehouse"]
	var apron := _room_point(room, Vector2(0, room.size.y * 0.5 + 3.25))
	return [Vector3(lift_side_x(), 0, lane_z(lift_lane)), Vector3(lift_side_x(), 0, apron.z), apron]


func _room_point(room: Placement, local: Vector2) -> Vector3:
	return room.local_point(grid, Vector3(local.x, 0, -local.y))


func cart_aisle_end() -> int:
	return int(_lane_extras.get("aisle_end", grid.size.x - 23))


func lift_home() -> Vector3:
	return grid.to_world(Vector2(_lane_extras.get("lift_home_x", cart_aisle_end() + 8.6), lift_lane))


func lift_side_x() -> float:
	return grid.to_world(Vector2(grid.size.x - 1.05, 0)).x


func route(from: Vector3, to: Vector3, lane: float) -> Array[Vector3]:
	if lane == cart_lane or lane == walk_lane:
		return _floor_route(from, to, lane, 0.34 if lane == cart_lane else 0.22)
	if from.is_equal_approx(to):
		return []
	if is_equal_approx(from.x, to.x):
		return [to]
	var z := lane_z(lane)
	return [Vector3(from.x, from.y, z), Vector3(to.x, to.y, z), to]


func lift_to_slot(from: Vector3, index: int, plan: Dictionary = objects) -> Array[Vector3]:
	var target := warehouse_approach(index, plan)
	var room: Placement = plan[&"Warehouse"]
	if WarehouseRoom.high_bay(room.size):
		var path := warehouse_entry_path(plan)
		path.push_front(Vector3(from.x, 0, lane_z(lift_lane)))
		var row := WarehouseRoom.finished_slot(room.size, index)
		var aisle := row.y + WarehouseRoom.FG_APPROACH + WarehouseRoom.FG_TURN_AHEAD
		path.append(_room_point(room, Vector2(0, aisle)))
		path.append(_room_point(room, Vector2(row.x, aisle)))
		path.append(target)
		return path
	if index < 4:
		return route(from, target, lift_lane)
	var rear := lane_z(rear_lane)
	return [Vector3(from.x, 0, lane_z(lift_lane)), Vector3(lift_side_x(), 0, lane_z(lift_lane)),
		Vector3(lift_side_x(), 0, rear), Vector3(target.x, 0, rear), target]


func lift_from_slot(index: int, plan: Dictionary = objects) -> Array[Vector3]:
	var from := warehouse_approach(index, plan)
	if WarehouseRoom.high_bay(plan[&"Warehouse"].size):
		var path := lift_to_slot(lift_home(), index, plan)
		path.pop_back()
		path.reverse()
		return path
	if index < 4:
		return route(from, lift_home(), lift_lane)
	var rear := lane_z(rear_lane)
	return [Vector3(from.x, 0, rear), Vector3(lift_side_x(), 0, rear),
		Vector3(lift_side_x(), 0, lane_z(lift_lane)), lift_home()]


func belt(id: StringName, plan: Dictionary = objects) -> Array[Vector3]:
	var link: Array = LINKS[id]
	return [port(link[0], link[1], plan), port(link[2], link[3], plan)]


func definition(id: StringName) -> Placement:
	if not LINKS.has(id):
		return objects.get(id)
	var span := belt(id)
	var a := grid.coordinates(span[0])
	var b := grid.coordinates(span[1])
	var across := Vector2(0, 0.60) if absf(a.x - b.x) > absf(a.y - b.y) else Vector2(0.60, 0)
	var first := Vector2i((a.min(b) - across).floor())
	var last := Vector2i((a.max(b) + across).ceil())
	return Placement.new(id, &"conveyor", first, last - first, span[0].y + 0.20)


func group_for(id: StringName) -> Array:
	for group in LINKED_GROUPS:
		if id in group:
			return group
	return [id]


func proposal(id: StringName, cell: Vector2i, turns: int) -> Dictionary:
	var source: Placement = objects[id]
	var footprint := source.footprint()
	var center_cell := Vector2(source.cell) + Vector2(footprint.size) * 0.5
	var target := source.at(cell, turns) as Placement
	var new_center := Vector2(cell) + Vector2(target.footprint().size) * 0.5
	var delta := posmod(turns - source.turns, 4)
	var result := {}
	for member: StringName in group_for(id):
		var item: Placement = objects[member]
		var moved := item.at(item.cell, item.turns + delta) as Placement
		var local := Vector2(item.cell) + Vector2(item.footprint().size) * 0.5 - center_cell
		var origin := new_center + local.rotated(delta * PI * 0.5) - Vector2(moved.footprint().size) * 0.5
		moved.cell = Vector2i(origin.round())
		result[member] = moved
	return result


func validate_changes(changes: Dictionary) -> String:
	var plan := objects.duplicate()
	plan.merge(changes, true)
	for id in changes:
		var item: Placement = changes[id]
		if not objects.has(id) or not objects[id].movable:
			return "This assembly has a fixed location."
		var reason := _validate_footprint(item, plan)
		if not reason.is_empty():
			return reason
	return _validate_connections(plan)


func validate_move(id: StringName, anchor: Vector2i, orientation: int) -> String:
	if not objects.has(id) or not objects[id].movable:
		return "This assembly has a fixed location."
	var item: Placement = objects[id].at(anchor, orientation)
	var reason := _validate_footprint(item, objects)
	if not reason.is_empty():
		return reason
	var plan := objects.duplicate()
	plan[item.id] = item
	return _validate_connections(plan)


func move(id: StringName, anchor: Vector2i, orientation: int) -> String:
	var reason := validate_move(id, anchor, orientation)
	if reason.is_empty():
		objects[id] = objects[id].at(anchor, orientation)
		invalidate_routes()
	return reason


## Saved layouts receive new equipment at its default cells. If those cells are taken,
## move the new equipment together, keeping its arrangement, to the nearest place where
## the whole plan validates. Returns the remaining problem, if any.
func fit_appended() -> String:
	var problem := validate()
	var group := appended.filter(func(id: StringName) -> bool: return objects.has(id) and objects[id].movable)
	if problem.is_empty() or group.is_empty():
		return problem
	var originals := {}
	var bounds := Rect2i()
	for id: StringName in group:
		originals[id] = objects[id]
		var area: Rect2i = objects[id].required_area()
		bounds = area if bounds.size == Vector2i.ZERO else bounds.merge(area)
	var others: Array[Rect2i] = []
	for item: Placement in objects.values():
		if item.id not in group and is_zero_approx(item.elevation) and item.kind != &"parking":
			others.append(item.required_area())
	var room := Rect2i(Vector2i.ZERO, grid.size)
	for radius in range(1, maxi(grid.size.x, grid.size.y)):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var shifted := Rect2i(bounds.position + Vector2i(dx, dy), bounds.size)
				if not room.encloses(shifted) or others.any(func(area: Rect2i) -> bool: return area.intersects(shifted)):
					continue
				for id: StringName in group:
					var item: Placement = originals[id]
					objects[id] = item.at(item.cell + Vector2i(dx, dy), item.turns)
				invalidate_routes()
				if validate().is_empty():
					return ""
	for id: StringName in group:
		objects[id] = originals[id]
	invalidate_routes()
	return problem


func validate() -> String:
	if not error.is_empty():
		return error
	for item: Placement in objects.values():
		var reason := _validate_footprint(item, objects)
		if not reason.is_empty():
			return "factory_layout.json [%s]: %s" % [item.id, reason]
	var problem := _validate_connections(objects)
	return "factory_layout.json: " + problem if not problem.is_empty() else ""


func _validate_footprint(item: Placement, plan: Dictionary) -> String:
	var reason := Rules.validate(grid, item, plan, reserved)
	if not reason.is_empty():
		return reason
	if is_zero_approx(item.elevation) and item.kind in [&"machine", &"storage"]:
		for leg: Rect2 in _platform_supports(plan):
			if Rect2(item.footprint()).intersects(leg):
				return "Footprint overlaps a mezzanine support."
	return ""


func _platform_supports(plan: Dictionary) -> Array[Rect2]:
	var deck: Placement = plan[&"Platform"]
	var result: Array[Rect2] = []
	for x in [-1.0, 1.0]:
		for z in [-1.0, 1.0]:
			var offset := Vector3(x * (deck.size.x * 0.5 - 0.23), 0, z * (deck.size.y * 0.5 - 0.23))
			result.append(_local_area(deck, offset, Vector2(0.53, 0.55)))
	return result


func _validate_connections(plan: Dictionary) -> String:
	if not port(&"Extruder", &"feed", plan).is_equal_approx(port(&"Hopper", &"outlet", plan)):
		return "The hopper outlet must align with the extruder feed."
	var deck: Placement = plan[&"Platform"]
	var hopper: Placement = plan[&"Hopper"]
	var walking_area := Rect2(deck.footprint()).grow(-0.2)
	var sacks := _local_area(deck, Vector3(-2.3, 0, 2.4), Vector2(4.65, 1.0))
	if Rect2(hopper.footprint()).intersects(sacks):
		return "The hopper would overlap the ingredient sacks."
	for index in 2:
		var pick := grid.coordinates(port(&"Platform", StringName("pick_%d" % index), plan))
		var drop := grid.coordinates(port(&"Hopper", StringName("drop_%d" % index), plan))
		if not walking_area.has_point(pick) or not walking_area.has_point(drop) \
				or _segment_hits(pick, drop, Rect2(hopper.footprint()).grow(0.18)) \
				or _segment_hits(pick, drop, sacks):
			return "A platform worker would lose access to the hopper."
	var obstacles := _obstacles(plan)
	var docks := _dock_points(plan)
	var areas := _dock_areas(docks)
	if areas.size() != docks.size():
		return "Two carts would share the same dock."
	for index in docks.size():
		for other in range(index):
			if areas[docks[index]].intersects(areas[docks[other]]):
				return "Two cart docks would overlap."
	var blockers := obstacles.duplicate()
	blockers.merge(areas)
	var destinations := docks.duplicate()
	for index in MAX_CREW:
		destinations.append(crew_home(index))
	if not _lane_clear(docks, cart_lane, 0.34, blockers):
		return "A cart dock or cart route would be obstructed."
	if not _lane_clear(destinations, walk_lane, 0.22, blockers):
		return "A worker would lose access to a cart or dock."
	for index in PALLET_BAYS:
		var approach := pallet_approach(index, plan)
		if not _path_clear(lift_home(), route(lift_home(), approach, lift_lane), 0.88, obstacles):
			return "A forklift pickup route would be obstructed."
		for slot in warehouse_slot_count(plan):
			if not _path_clear(approach, lift_to_slot(approach, slot, plan), 0.88, obstacles):
				return "A forklift delivery route would be obstructed."
	for slot in warehouse_slot_count(plan):
		if not _path_clear(warehouse_approach(slot, plan), lift_from_slot(slot, plan), 0.88, obstacles):
			return "A forklift return route would be obstructed."
	var supply_stops: Array[Vector3] = [supply_point("RM-WH", plan), supply_point("RM-STAGE", plan)]
	for location in SUPPLY_STATIONS:
		supply_stops.append(supply_point(location, plan))
	if not _lane_clear(supply_stops, supply_lane, 0.75, obstacles):
		return "A material handler route would be obstructed."
	for key: StringName in LINKS:
		var endpoints := belt(key, plan)
		var link: Array = LINKS[key]
		var direction := endpoints[1] - endpoints[0]
		var source: Placement = plan[link[0]]
		var target: Placement = plan[link[2]]
		var heading := Vector3.RIGHT.rotated(Vector3.UP, source.yaw())
		var intake := Vector3.RIGHT.rotated(Vector3.UP, target.yaw())
		if direction.dot(heading) < 0.6 or direction.length() > 12.0 \
			or direction.cross(heading).length() > 0.001 or heading.dot(intake) < 0.99:
			return "Keep the connected belt ports aligned and within 12 m."
		if not _path_clear(endpoints[0], [endpoints[1]], 0.49, obstacles, [link[0], link[2]]):
			return "A conveyor connection would be obstructed."
	return ""


func _dock_points(plan: Dictionary) -> Array[Vector3]:
	var points: Array[Vector3] = [
		port(&"Extruder", &"raw_dock", plan), port(&"Oven", &"raw_dock", plan),
		port(&"Oven", &"cooked_dock", plan), port(&"Coater", &"cooked_dock", plan),
		port(&"Oven02", &"raw_dock", plan), port(&"Oven02", &"cooked_dock", plan),
		port(&"Coater02", &"cooked_dock", plan), port(&"Coater", &"coated_dock", plan),
		port(&"Coater02", &"coated_dock", plan), port(&"PackagingWIP", &"coated_dock", plan),
		port(&"SFGWarehouse", &"stock_dock", plan)
	]
	for item: Placement in plan.values():
		for name in [&"input_dock", &"output_dock", &"cart_dock"]:
			if item.ports.has(name):
				points.append(item.port(grid, name))
	for index in MAX_CARTS:
		points.append(cart_home(index, true))
		points.append(cart_home(index, false))
		points.append(coated_cart_home(index))
	return points


func _dock_areas(points: Array[Vector3]) -> Dictionary:
	var areas := {}
	for point in points:
		areas[point] = _area(cart_body_center(point), Vector2(CART_BODY.x, CART_BODY.z))
	return areas


func _lane_clear(points: Array[Vector3], lane: float, radius: float, blockers: Dictionary) -> bool:
	var z := lane_z(lane)
	var low := INF
	var high := -INF
	for point in points:
		var approach := _aisle_approach(point, lane, radius, blockers)
		if approach.is_empty():
			return false
		var junction: Vector3 = approach.back()
		low = minf(low, junction.x)
		high = maxf(high, junction.x)
	return _path_clear(Vector3(low, 0, z), [Vector3(high, 0, z)], radius, blockers)


func _aisle_approach(point: Vector3, lane: float, radius: float, blockers: Dictionary) -> Array[Vector3]:
	var aisle_z := lane_z(lane)
	var junction := Vector3(point.x, point.y, aisle_z)
	# Cart stops are keyed by their world coordinates. A cart can enter its own stop.
	var ignore := [point] if blockers.has(point) else []
	if _path_clear(point, [junction], radius, blockers, ignore):
		return [junction]
	if not _path_clear(point, [], radius, blockers, ignore):
		return []

	var cell := grid.coordinates(point)
	var toward := signf(lane - cell.y)
	var nearest := absf(lane - cell.y)
	var sides: Array[float] = []
	for id in blockers:
		if id in ignore:
			continue
		var area: Rect2 = blockers[id].grow(radius)
		if not _segment_hits(cell, Vector2(cell.x, lane), area):
			continue
		var edge := area.position.y if toward > 0 else area.end.y
		nearest = minf(nearest, absf(edge - cell.y) - 0.08)
		sides.append(area.position.x - 0.30)
		sides.append(area.end.x + 0.30)
	if nearest < 0.20:
		return _grid_approach(point, lane, radius, blockers, ignore)
	sides.sort_custom(func(a: float, b: float) -> bool:
		var left := absf(a - cell.x)
		var right := absf(b - cell.x)
		return a < b if left == right else left < right)
	for side in sides:
		for progress: float in [nearest, minf(0.65, nearest)]:
			var turn := grid.to_world(cell + Vector2(0, progress * toward), point.y)
			var bypass := grid.to_world(Vector2(side, cell.y + progress * toward), point.y)
			var join := Vector3(bypass.x, point.y, aisle_z)
			if _path_clear(point, [turn, bypass, join], radius, blockers, ignore):
				return [turn, bypass, join]
	return _grid_approach(point, lane, radius, blockers, ignore)


## Fallback for stops behind other equipment: an axis-aligned grid search around every
## blocker to the aisle. Equipment with a direct or single-detour approach never gets here,
## so established routes stay exactly as they were.
func _grid_approach(point: Vector3, lane: float, radius: float, blockers: Dictionary, ignore: Array) -> Array[Vector3]:
	const STEP := 0.5
	var cells := Vector2i(ceili(grid.size.x / STEP), ceili(grid.size.y / STEP))
	var search := AStarGrid2D.new()
	search.region = Rect2i(Vector2i.ZERO, cells)
	search.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	search.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	search.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	search.update()
	var margin := radius + STEP * 0.5
	var edge := ceili(margin / STEP)
	search.fill_solid_region(Rect2i(0, 0, cells.x, edge))
	search.fill_solid_region(Rect2i(0, cells.y - edge, cells.x, edge))
	search.fill_solid_region(Rect2i(0, 0, edge, cells.y))
	search.fill_solid_region(Rect2i(cells.x - edge, 0, edge, cells.y))
	for id in blockers:
		if id in ignore:
			continue
		var area: Rect2 = blockers[id].grow(margin)
		var low := Vector2i(floori(area.position.x / STEP), floori(area.position.y / STEP))
		var high := Vector2i(ceili(area.end.x / STEP), ceili(area.end.y / STEP))
		search.fill_solid_region(Rect2i(low, high - low))
	var start_cell := grid.coordinates(point)
	var start := Vector2i(roundi(start_cell.x / STEP), roundi(start_cell.y / STEP))
	var row := roundi(lane / STEP)
	if not search.region.has_point(start) or search.is_point_solid(start):
		return []
	# Join the aisle at the open lane point nearest the stop.
	var finish := Vector2i(-1, row)
	for offset in cells.x:
		for x in [start.x - offset, start.x + offset]:
			if x >= 0 and x < cells.x and not search.is_point_solid(Vector2i(x, row)):
				finish.x = x
				break
		if finish.x >= 0:
			break
	if finish.x < 0:
		return []
	var steps := search.get_id_path(start, finish)
	if steps.size() < 2:
		return []
	var result: Array[Vector3] = []
	for index in range(1, steps.size()):
		var turning := index == steps.size() - 1 or steps[index + 1] - steps[index] != steps[index] - steps[index - 1]
		if turning:
			result.append(grid.to_world(Vector2(steps[index]) * STEP, point.y))
	# The first leg leaves the stop along its own axis, so the path stays axis-aligned.
	var first := grid.coordinates(result[0])
	if not is_equal_approx(first.x, start_cell.x) and not is_equal_approx(first.y, start_cell.y):
		var horizontal := steps[1].y == steps[0].y
		var corner := Vector2(first.x, start_cell.y) if horizontal else Vector2(start_cell.x, first.y)
		result.push_front(grid.to_world(corner, point.y))
	result[result.size() - 1].z = lane_z(lane)
	return result if _path_clear(point, result, radius, blockers, ignore) else []


func invalidate_routes() -> void:
	_route_obstacles.clear()
	_cart_blockers.clear()
	_approaches.clear()


func _floor_route(from: Vector3, to: Vector3, lane: float, radius: float) -> Array[Vector3]:
	if from.is_equal_approx(to):
		return []
	if _route_obstacles.is_empty():
		_route_obstacles = _obstacles(objects)
		_cart_blockers = _route_obstacles.duplicate()
		_cart_blockers.merge(_dock_areas(_dock_points(objects)))
	var blockers := _route_obstacles if lane == supply_lane else _cart_blockers
	if from.x == to.x and (lane != cart_lane or ((from.z > to.z) == (to.z < lane_z(lane)))) 			and _path_clear(from, [to], radius, blockers, [from, to]):
		return [to]
	var departure := _cached_approach(from, lane, radius, blockers)
	var arrival := _cached_approach(to, lane, radius, blockers)
	if departure.is_empty() or arrival.is_empty():
		return []
	var result := departure.duplicate()
	for index in range(arrival.size() - 1, -1, -1):
		result.append(arrival[index])
	result.append(to)
	return result


func _cached_approach(point: Vector3, lane: float, radius: float, blockers: Dictionary) -> Array[Vector3]:
	if not _approaches.has(lane):
		_approaches[lane] = {}
	var points: Dictionary = _approaches[lane]
	if not points.has(point):
		points[point] = _aisle_approach(point, lane, radius, blockers)
	return points[point]


func _obstacles(plan: Dictionary) -> Dictionary:
	var result := {}
	for item: Placement in plan.values():
		if is_zero_approx(item.elevation) and (item.kind in [&"machine", &"access"] or item.id == &"SFGWarehouse"):
			result[item.id] = Rect2(item.footprint())
	for id: StringName in [&"RawWarehouse", &"Warehouse"]:
		var item: Placement = plan[id]
		var room := WarehouseRoom.new(item.size, id == &"Warehouse")
		var panels := room.walls + room.racks
		for index in panels.size():
			var area: Rect2 = panels[index]
			var offset := area.get_center()
			result[StringName("%sPanel%d" % [id, index])] = _local_area(item,
				Vector3(offset.x, 0, -offset.y), area.size)
	var supports := _platform_supports(plan)
	for index in supports.size():
		result[StringName("PlatformSupport%d" % index)] = supports[index]
	result[&"PackagingWIP"] = _local_area(plan[&"PackagingWIP"], Vector3(1.05, 0, 0.35), Vector2(3.4, 1.25))
	result[&"Palletizer"] = _local_area(plan[&"Palletizer"], Vector3(-0.66, 0, 2.0), Vector2(6.7, 1.5))
	for index in PALLET_BAYS:
		result[StringName("PalletBay%d" % index)] = _area(pallet_position(index, plan), _rotated_size(Vector2(1.70, 1.36), plan[&"Palletizer"]))
	if not WarehouseRoom.high_bay(plan[&"Warehouse"].size):
		for index in LEGACY_WAREHOUSE_SLOTS:
			result[StringName("WarehouseSlot%d" % index)] = _area(warehouse_slot(index, plan), _rotated_size(Vector2(1.70, 1.36), plan[&"Warehouse"]))
	return result


func _rotated_size(size: Vector2, item: Placement) -> Vector2:
	return size if item.turns % 2 == 0 else Vector2(size.y, size.x)


func _local_area(item: Placement, local: Vector3, size: Vector2) -> Rect2:
	return _area(item.local_point(grid, local), _rotated_size(size, item))


func _area(at: Vector3, size: Vector2) -> Rect2:
	return Rect2(grid.coordinates(at) - size * 0.5, size)


func _path_clear(
	start: Vector3, path: Array[Vector3], radius: float, obstacles: Dictionary,
	ignore: Array = []
) -> bool:
	var from := grid.coordinates(start)
	var inside := Rect2(grid.bounds()).grow(-radius)
	if not inside.has_point(from):
		return false
	var points: Array[Vector3] = [start]
	points.append_array(path)
	for point: Vector3 in points:
		var to := grid.coordinates(point)
		if not inside.has_point(to):
			return false
		for id in obstacles:
			if id not in ignore and _segment_hits(from, to, obstacles[id].grow(radius)):
				return false
		from = to
	return true


func _segment_hits(from: Vector2, to: Vector2, rect: Rect2) -> bool:
	# Aisle and dock approaches are axis-aligned. Check their spans without building edge arrays.
	if from.x == to.x:
		return from.x >= rect.position.x and from.x <= rect.end.x \
			and maxf(from.y, to.y) >= rect.position.y and minf(from.y, to.y) <= rect.end.y
	if from.y == to.y:
		return from.y >= rect.position.y and from.y <= rect.end.y \
			and maxf(from.x, to.x) >= rect.position.x and minf(from.x, to.x) <= rect.end.x
	if rect.has_point(from) or rect.has_point(to):
		return true
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)]
	for index in corners.size():
		if Geometry2D.segment_intersects_segment(from, to, corners[index], corners[(index + 1) % 4]) != null:
			return true
	return false
