extends Node3D
## The roofless chocolate hall. Geometry and indicators read the simulation's layout and state.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Primitives = preload("res://world/primitives.gd")
const Equipment = preload("res://world/equipment_view.gd")
const Logistics = preload("res://world/logistics_view.gd")
const Stock = preload("res://world/stock_models.gd")
const Palette = preload("res://ui/status_colors.gd")

const INK := Color("#253541")
const STEEL := Color("#566773")
const METAL := Color("#9aabb1")
const PALE := Color("#d8deda")
const CONCRETE := Color("#757c80")
const TEAL := Color("#408d88")
const AMBER := Color("#d8a250")
const OVEN_RED := Color("#a85d4b")
const COCOA := Color("#745148")
const SAFETY := Color("#edbf64")

var layout: Layout
var _draw := Primitives.new()
var _stock := Stock.new(_draw)
var _equipment: Dictionary[StringName, Equipment] = {}
var _logistics: Logistics
var _staged: Array[Stock.PalletView] = []
var _stored: Array[Stock.PalletView] = []
var _warehouse_markers: Array[MeshInstance3D] = []
var _oven_doors := {}
var _oven_heaters := {}
var _auger: Node3D
var _coating_drums := {}
var _route_overlay: Node3D
var _packing_head: Node3D
var _raw_groups: Array[Node3D] = []
var _pallet_picks: Array[Equipment] = []
var _shuttle: Equipment
var _shuttle_cargo: Node3D
var _raw_revision := -1
var _coating_colors := {}
var _erp_enabled := false


func configure(floor_plan: Layout, erp_enabled: bool = false) -> void:
	_erp_enabled = erp_enabled
	_raw_groups.clear()
	_pallet_picks.clear()
	_raw_revision = -1
	_coating_colors.clear()
	_route_overlay = null
	_oven_doors.clear()
	_oven_heaters.clear()
	_coating_drums.clear()
	layout = floor_plan
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_equipment.clear()
	_staged.clear()
	_stored.clear()
	_warehouse_markers.clear()
	_build_hall()
	_build_platform()
	_build_extruder()
	_build_oven(&"Oven", "Oven 01")
	_build_coater(&"Coater", "Coater 01")
	if _erp_enabled:
		_build_oven(&"Oven02", "Oven 02")
		_build_coater(&"Coater02", "Coater 02")
	_build_packer()
	_build_palletizing()
	_build_warehouse()
	if _erp_enabled:
		_build_pack_wip()
		_build_raw_warehouse()
		_build_shuttle()
	_draw.batch_static(self, _warehouse_markers)
	for station in _equipment.values():
		_draw.batch_static(station, [station.beacon])
	_logistics = Logistics.new(self, _draw, _stock, _erp_enabled)


func equipment_at(origin: Vector3, end: Vector3) -> StringName:
	var query := PhysicsRayQueryParameters3D.create(origin, end, 2)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return &""
	return result.collider.get_meta("equipment", &"")


func select(id: StringName) -> void:
	for key in _equipment:
		_equipment[key].select(key == id)
	_logistics.select(id)


func refresh(line: Line) -> void:
	_machine(&"Extruder", "02  Extruder", line.extruder)
	_machine(&"Coater", "Coater 01", line.coater)
	if _erp_enabled:
		_machine(&"Coater02", "Coater 02", line.coaters[&"Coater02"])
		_equipment[&"Coater02"].fill_slots(line.coater_inputs[&"Coater02"].occupancy())
		_refresh_oven(&"Oven02", "Oven 02", line.ovens[&"Oven02"])
		var buffer := _equipment[&"PackagingWIP"]
		buffer.update_machine("Packaging WIP", "%.0f / %.0f kg" % [line.pack_wip.quantity, line.pack_wip.capacity], Palette.SFG)
		buffer.fill_slots(line.pack_wip.occupancy())
	_machine(&"Packer", "05  Packaging", line.packer)
	_equipment[&"Hopper"].update_machine("01  Ingredients", "%0.0f / %0.0f kg" % [
		line.hopper.quantity, line.hopper.capacity], Color("#b7cef0"))
	_equipment[&"Hopper"].fill_slots(line.hopper.occupancy())
	_equipment[&"Coater"].fill_slots(line.cooked_input.occupancy())
	_refresh_oven(&"Oven", "Oven 01", line.oven)
	_equipment[&"Palletizer"].update_machine("06  Palletizing", "%d full" % line.pallets_ready(), Palette.FG)
	_equipment[&"Warehouse"].update_machine("07  FG warehouse", "%d / %d pallets" % [
		line.warehouse_count(), int(line.settings[&"warehouse_capacity"])], Palette.FG)
	for index in _staged.size():
		_staged[index].refresh(line.staged_pallets[index], true)
	var free := int(line.settings[&"warehouse_capacity"]) - line.warehouse_count()
	free -= int(line.warehouse_reserved_slot >= 0)
	for index in _stored.size():
		var pallet := line.warehouse[index]
		_stored[index].refresh(pallet)
		if _erp_enabled:
			_pallet_picks[index].set_active(pallet != null)
		var marker := Color("#555d63")
		if pallet != null:
			marker = Palette.RUNNING.darkened(0.35)
		elif index == line.warehouse_reserved_slot:
			marker = Palette.FG
		elif free > 0:
			marker = Color("#83a2a2")
			free -= 1
		_warehouse_markers[index].material_override = _draw.material(marker)
	_logistics.refresh(line)
	if line.erp != null and _erp_enabled:
		_refresh_erp(line)


func animate(line: Line, delta: float) -> void:
	_logistics.animate(line, delta)
	if line.erp != null and _erp_enabled:
		var operator := line.erp.shuttle
		_shuttle.position = operator.previous_position.lerp(operator.position, line.interpolation())
		_shuttle.rotation.y = operator.heading
		_shuttle_cargo.visible = not line.erp.shipment.is_empty() and line.erp.shipment.phase > 0
	_auger.rotation.x = fposmod(line.extruder.total_output * 0.28, TAU)
	_packing_head.position.y = 1.71 - 0.28 * (0.5 - 0.5 * cos(line.packer.total_output * 1.7))
	_animate_station(line, &"Oven", &"Coater", line.oven, line.coater, delta)
	if _erp_enabled:
		_animate_station(line, &"Oven02", &"Coater02", line.ovens[&"Oven02"], line.coaters[&"Coater02"], delta)


func _refresh_oven(id: StringName, title: String, machine: Line.Oven) -> void:
	var cooking := machine.state == Line.Oven.State.COOKING
	var tint := Palette.BLOCKED if cooking else Palette.IDLE
	if machine.state in [Line.Oven.State.READY, Line.Oven.State.UNLOADING]:
		tint = Palette.RUNNING
	_equipment[id].update_machine(title, machine.state_title(), tint)
	_oven_heaters[id].visible = cooking


func _animate_station(line: Line, oven_id: StringName, coat_id: StringName, oven: Line.Oven, coater: Line.Machine, delta: float) -> void:
	_coating_drums[coat_id].rotation.x = fposmod(coater.total_output * 0.23, TAU)
	var worker := line.find_operator(oven.owner) if oven.owner != &"" else null
	var opening := worker != null and worker.state in [Line.Operator.State.LOADING, Line.Operator.State.UNLOADING]
	var door: Node3D = _oven_doors[oven_id]
	if line.elapsed_ticks == 0:
		door.rotation.y = 0.0
	elif line.playing:
		door.rotation.y = lerpf(door.rotation.y, -1.30 if opening else 0.0, 1.0 - exp(-9.0 * delta))


func show_route(order: Dictionary) -> void:
	if _route_overlay != null:
		_route_overlay.queue_free()
		_route_overlay = null
	if order.is_empty():
		return
	var markers := Node3D.new()
	_route_overlay = markers
	add_child(markers)
	var previous := Vector3.ZERO
	var tint := Color("#61ebde")
	var steps := []
	for op in order.route.operations:
		if op.type == "pack":
			steps.append([&"PackagingWIP", "Cart delivery · WIP"])
		steps.append([StringName(op.equipment), "%02d  %s" % [op.number, op.description]])
	for step in steps:
		var point := layout.center(step[0])
		point.y += layout.objects[step[0]].height + 2.15
		var label := _draw.sign(markers, point, step[1], tint)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		if previous != Vector3.ZERO:
			var beam := _draw.box(markers, (previous + point) * 0.5, Vector3(0.07, 0.07, previous.distance_to(point)), tint)
			beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			beam.look_at(point)
			var direction := (point - previous).normalized()
			for side: float in [-1.0, 1.0]:
				var tip := previous.lerp(point, 0.6)
				var tail := tip - direction * 0.55 + direction.cross(Vector3.UP) * side * 0.26
				var arrow := _draw.box(markers, (tip + tail) * 0.5, Vector3(0.07, 0.07, tip.distance_to(tail)), tint)
				arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				arrow.look_at(tip)
		previous = point


func _machine(id: StringName, title: String, machine: Line.Machine) -> void:
	_equipment[id].update_machine(title, Palette.title(machine.state), Palette.color(machine.state))


func _build_hall() -> void:
	var atmosphere := Environment.new()
	atmosphere.background_mode = Environment.BG_COLOR
	atmosphere.background_color = Color("#172532")
	atmosphere.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	atmosphere.ambient_light_color = Color("#d6e0eb")
	atmosphere.ambient_light_energy = 0.48
	var environment := WorldEnvironment.new()
	environment.environment = atmosphere
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-58, -28, 0)
	light.light_color = Color("#fff1dc")
	light.light_energy = 0.85
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.shadow_blur = 1.4
	light.directional_shadow_max_distance = 133
	add_child(light)

	var grid := layout.grid
	var width := grid.size.x
	var length := grid.size.y
	var middle := Vector2(grid.size) * 0.5
	_draw.box(self, grid.to_world(middle, -0.48), Vector3(width + 0.7, 0.8, length + 0.7), INK)
	_draw.box(self, grid.to_world(middle, -0.18), Vector3(width, 0.24, length), STEEL)
	for x in range(0, width, 4):
		for z in range(0, length, 4):
			var tile := Vector2(mini(4, width - x), mini(4, length - z))
			var slab := CONCRETE.lightened(float((x * 3 + z * 2) % 5) * 0.013)
			_draw.box(self, grid.to_world(Vector2(x, z) + tile * 0.5, -0.055),
				Vector3(tile.x - 0.02, 0.11, tile.y - 0.02), slab)
	for z: float in [-0.155, length + 0.155]:
		var height := 1.66 if z > 0.0 else 1.05
		_draw.box(self, grid.to_world(Vector2(middle.x, z), height * 0.5),
			Vector3(width + 0.62, height, 0.31), STEEL)
		_draw.box(self, grid.to_world(Vector2(middle.x, z), height + 0.06),
			Vector3(width + 0.65, 0.14, 0.42), METAL)
		for x in range(0, width + 1, 8):
			_draw.box(self, grid.to_world(Vector2(x, z), height * 0.50),
				Vector3(0.34, height + 0.18, 0.46), INK)
	for x: float in [-0.155, width + 0.155]:
		_draw.box(self, grid.to_world(Vector2(x, middle.y), 0.65), Vector3(0.31, 1.3, length), STEEL)
		_draw.box(self, grid.to_world(Vector2(x, middle.y), 1.36), Vector3(0.42, 0.14, length), METAL)
		for z in range(3, length, 6):
			_draw.box(self, grid.to_world(Vector2(x, z), 0.7), Vector3(0.44, 1.56, 0.36), INK)
	var aisle_end := layout.cart_aisle_end()
	_strip(grid.origin.x + 1.5, grid.origin.x + aisle_end, layout.lane_z(Layout.CART_LANE),
		1.65, Color("#637b7d"))
	_strip(grid.origin.x + 1.5, grid.origin.x + aisle_end - 1.0, layout.lane_z(Layout.WALK_LANE),
		0.87, Color("#a6acaa"))
	var lift_z := layout.lane_z(Layout.LIFT_LANE)
	var rear_z := layout.lane_z(Layout.REAR_LANE)
	var warehouse_left := layout.center(&"Warehouse").x - 5.8
	var side := layout.lift_side_x()
	_strip(grid.origin.x + aisle_end - 1.8, side + 0.62, lift_z, 2.64, Color("#706e5d"))
	_strip(warehouse_left, side + 0.62, rear_z, 1.8, Color("#706e5d"))
	_draw.box(self, Vector3(side, 0.013, (lift_z + rear_z) * 0.5),
		Vector3(1.32, 0.02, lift_z - rear_z), Color("#706e5d"))
	for x in range(aisle_end - 1, width - 1):
		_draw.box(self, grid.to_world(Vector2(x, Layout.LIFT_LANE), 0.029),
			Vector3(0.43, 0.014, 0.057), SAFETY)
	for x in range(2, aisle_end - 1, 2):
		_draw.box(self, grid.to_world(Vector2(x, Layout.WALK_LANE), 0.032),
			Vector3(0.64, 0.014, 0.045), PALE)
	_floor_text(grid.to_world(Vector2(11.1, 2.9), 0.04), "CHOCOLATE WORKS   /   02", PALE, 0.031)
	_floor_text(grid.to_world(Vector2(width - 12.0, 2.9), 0.04), "FORKLIFT ONLY  ›", SAFETY, 0.025)
	_floor_text(grid.to_world(Vector2(22.7, Layout.CART_LANE - 0.2), 0.04),
		"CART TRANSFER AISLE", PALE, 0.014)
	_floor_text(layout.center(&"Warehouse") + Vector3(0.5, 0.04, -5.1), "OUTBOUND", SAFETY, 0.025)
	for id in [&"RawParking", &"CookedParking"]:
		_station(id, "", PALE, false)
	if _erp_enabled:
		_station(&"CoatedParking", "", Color("#b88bc7"), false)
		_floor_text(layout.center(&"CoatedParking") + Vector3(0, 0.04, 1.15), "COATED CARTS", Color("#e0b3ee"), 0.014)
	for index in Layout.MAX_CARTS:
		if _erp_enabled:
			_bay(layout.cart_body_center(layout.coated_cart_home(index)) + Vector3.UP * 0.024,
				Vector2(1.41, 1.35), Color("#b88bc7"))
		_bay(layout.cart_body_center(layout.cart_home(index, true)) + Vector3.UP * 0.024,
			Vector2(1.41, 1.35), Color("#9ebec0"))
		_bay(layout.cart_body_center(layout.cart_home(index, false)) + Vector3.UP * 0.024,
			Vector2(1.41, 1.35), Color("#bfa57d"))
	# The service bank is decorative and sits against the rear wall.
	for x: float in [19, 25, 34, 40, 46, width - 6]:
		var base := grid.to_world(Vector2(x, length - 1.1))
		_draw.box(self, base + Vector3(0, 0.87, 0), Vector3(1.55, 1.73, 0.83), INK)
		_draw.box(self, base + Vector3(0, 1.12, 0.43), Vector3(1.35, 1.13, 0.08), METAL)
		_draw.box(self, base + Vector3(0.45, 1.22, 0.5), Vector3(0.14, 0.23, 0.08), TEAL)


func _build_platform() -> void:
	var deck := _station(&"Platform", "", PALE, false)
	var plan := layout.objects[&"Platform"]
	var half := Vector2(plan.size) * 0.5
	var y := plan.elevation
	# The walking surface sits above the frame and supports to avoid coplanar faces.
	var sheet_thickness := 0.05
	var frame_height := 0.34 - sheet_thickness
	var leg_height := y - sheet_thickness
	_draw.box(deck, Vector3(0, -sheet_thickness - frame_height * 0.5, 0),
		Vector3(plan.size.x, frame_height, plan.size.y), INK)
	_draw.box(deck, Vector3(0, -sheet_thickness * 0.5, 0),
		Vector3(plan.size.x - 0.08, sheet_thickness, plan.size.y - 0.08), METAL)
	for side_x: float in [-1.0, 1.0]:
		for side_z: float in [-1.0, 1.0]:
			var leg := Vector3(side_x * (half.x - 0.23), -y + leg_height * 0.5, side_z * (half.y - 0.23))
			_draw.box(deck, leg, Vector3(0.26, leg_height, 0.26), STEEL)
			_draw.box(deck, leg + Vector3(0, -leg_height * 0.5 + 0.07, 0), Vector3(0.53, 0.14, 0.55), INK)
	var left := deck.position.x - half.x + 0.08
	var right := deck.position.x + half.x - 0.08
	var front := deck.position.z + half.y - 0.08
	var rear := deck.position.z - half.y + 0.08
	var hopper := _station(&"Hopper", "01  Ingredients", PALE)
	hopper.offset_readout(Vector3(-2.35, 0.35, -2.75))
	_rail(Vector3(left, y, rear), Vector3(right, y, rear))
	_rail(Vector3(left, y, rear), Vector3(left, y, front))
	_rail(Vector3(left, y, front), Vector3(right, y, front))
	var stairs := _station(&"Stairs", "", SAFETY, false, false)
	var stair_plan := layout.objects[&"Stairs"]
	var stair_width := stair_plan.size.x - 0.26
	var stair_depth := stair_plan.size.y
	var rise := stair_plan.height
	_rail(Vector3(right, y, rear), Vector3(right, y, stairs.position.z - stair_depth * 0.5))
	# The deck itself is the landing above the twelve treads.
	for index in 12:
		var step_y := rise * (12.0 - index) / 13.0
		var z := -stair_depth * 0.5 + (index + 0.5) * stair_depth / 12.0
		var size := Vector3(stair_width, 0.22, stair_depth / 12.0)
		_draw.box(stairs, Vector3(0, step_y - 0.11, z), size, METAL)
		stairs.add_hitbox(size, Vector3(0, step_y - 0.22, z))
	for x: float in [-stair_width * 0.55, stair_width * 0.55]:
		_rail(stairs.position + Vector3(x, rise, -stair_depth * 0.5),
			stairs.position + Vector3(x, 0.25, stair_depth * 0.5))
	for index in 4:
		for tier in 3:
			_stock.sack(deck, Vector3(-4.12 + index * 1.21, 0.22 + tier * 0.31,
				-2.27 - (index % 2) * 0.24), 1.14)
	_floor_text(deck.position + Vector3(-2.0, 0.023, 0.41), "INGREDIENT DECK", INK, 0.015)
	_draw.cylinder(hopper, Vector3(0, 0.47, 0), 0.32, 0.82, METAL, 1.03)
	_draw.cylinder(hopper, Vector3(0, 1.13, 0), 1.03, 0.66, Color("#7199a5"))
	_draw.cylinder(hopper, Vector3(0, 1.48, 0), 1.10, 0.12, METAL)
	_draw.cylinder(hopper, Vector3(0, 1.55, 0), 0.84, 0.032, INK)
	_draw.box(hopper, Vector3(0, 0.64, 1.0), Vector3(0.46, 0.32, 0.11), AMBER)
	for index in 6:
		var bag := _stock.sack(hopper, Vector3(0, 1.58, 0), 0.55)
		bag.position = Vector3(-0.52 + (index % 3) * 0.52, 1.58, -0.26 + floori(index / 3.0) * 0.54)
		hopper.inventory_slots.append(bag)


func _build_extruder() -> void:
	var node := _station(&"Extruder", "02  Extruder", TEAL)
	node.offset_readout(Vector3(0, -0.66, 1.25))
	_base(node)
	_draw.box(node, Vector3(-0.2, 0.80, 0), Vector3(4.19, 1.02, 2.38), TEAL)
	var feed: Vector3 = layout.objects[&"Extruder"].ports[&"feed"]
	feed.z = -feed.z
	var feed_top := feed.y - 0.025
	_draw.cylinder(node, Vector3(feed.x, (1.77 + feed_top) * 0.5, feed.z), 0.31, feed_top - 1.77, METAL)
	_draw.cylinder(node, Vector3(feed.x, 2.02, feed.z), 0.48, 0.16, PALE)
	var barrel := _draw.cylinder(node, Vector3(0.10, 1.43, 0), 0.68, 3.71, METAL)
	barrel.rotation_degrees.z = 90
	_auger = _pivot(node, Vector3(1.83, 1.43, 0))
	var nose := _draw.cylinder(_auger, Vector3.ZERO, 0.51, 0.29, TEAL)
	nose.rotation_degrees.z = 90
	for index in 4:
		var angle := index * TAU / 4.0
		_draw.box(_auger, Vector3(0.16, sin(angle) * 0.34, cos(angle) * 0.34),
			Vector3(0.07, 0.12, 0.12), PALE)
	_draw.box(node, Vector3(1.85, 0.93, 0.84), Vector3(1.1, 0.24, 1.77), METAL)
	_console(node, Vector3(-1.17, 1.10, 1.22), Color("#81e6d4"))
	_beacon(node, Vector3(-1.68, 1.69, 0.3))
	_bay(layout.cart_body_center(layout.port(&"Extruder", &"raw_dock")) + Vector3.UP * 0.028, Vector2(1.47, 1.4), SAFETY)


func _build_oven(id: StringName, title: String) -> void:
	var node := _station(id, title, OVEN_RED)
	_base(node)
	_draw.box(node, Vector3(0, 1.86, -0.12), Vector3(4.64, 3.10, 2.95), OVEN_RED)
	_draw.box(node, Vector3(0, 1.68, 1.42), Vector3(3.78, 2.51, 0.21), INK)
	_draw.box(node, Vector3(0, 0.60, 1.61), Vector3(3.68, 0.14, 0.62), METAL)
	var door := _pivot(node, Vector3(-1.83, 1.69, 1.67))
	_draw.box(door, Vector3(1.83, 0, 0), Vector3(3.65, 2.28, 0.17), METAL)
	_draw.box(door, Vector3(1.83, 0.37, 0.094), Vector3(2.94, 1.16, 0.044), INK)
	_draw.box(door, Vector3(1.83, 0.39, 0.12), Vector3(2.56, 0.84, 0.02), Color("#59443d"))
	var heater := _pivot(door, Vector3(1.83, 0.37, 0.14))
	for index in 3:
		var glow := _draw.box(heater, Vector3(0, -0.28 + index * 0.28, 0), Vector3(2.45, 0.061, 0.023), AMBER)
		var emissive := StandardMaterial3D.new()
		emissive.albedo_color = Color("#e5a15c")
		emissive.emission_enabled = true
		emissive.emission = Color("#e58d4b")
		emissive.emission_energy_multiplier = 0.65
		glow.material_override = emissive
	_draw.box(door, Vector3(3.16, -0.35, 0.21), Vector3(0.21, 0.46, 0.23), INK)
	for x: float in [-1.29, 0.0, 1.29]:
		_draw.box(node, Vector3(x, 3.45, -0.69), Vector3(0.92, 0.16, 1.16), INK)
		for index in 4:
			_draw.box(node, Vector3(x, 3.55, -1.04 + index * 0.23), Vector3(0.79, 0.06, 0.09), METAL)
	_console(node, Vector3(2.00, 1.86, 1.45), AMBER)
	_beacon(node, Vector3(1.95, 3.36, 0.8))
	_oven_doors[id] = door
	_oven_heaters[id] = heater
	for dock: Vector3 in [layout.port(id, &"raw_dock"), layout.port(id, &"cooked_dock")]:
		_bay(layout.cart_body_center(dock) + Vector3.UP * 0.027, Vector2(1.48, 1.42), SAFETY)


func _build_coater(id: StringName, title: String) -> void:
	var node := _station(id, title, COCOA)
	_base(node)
	_draw.box(node, Vector3(0.08, 0.88, 0), Vector3(4.78, 0.98, 2.76), COCOA)
	_draw.box(node, Vector3(-1.75, 1.26, 0.53), Vector3(1.08, 0.48, 1.6), METAL)
	for x: float in [-1.21, 1.21]:
		_draw.box(node, Vector3(x, 1.95, 0), Vector3(0.30, 1.98, 1.59), COCOA)
	var rotor := _pivot(node, Vector3(0, 2.18, -0.19))
	var drum := _draw.cylinder(rotor, Vector3.ZERO, 0.84, 2.13, Color("#9a6d58"))
	drum.rotation_degrees.z = 90
	for index in 6:
		var angle := index * TAU / 6.0
		var slat := _draw.box(rotor, Vector3(0, sin(angle) * 0.82, cos(angle) * 0.82),
			Vector3(2.10, 0.09, 0.11), Stock.CHOCOLATE)
		slat.rotation.x = -angle
	_draw.box(node, Vector3(0, 1.36, 1.18), Vector3(1.93, 0.2, 0.69), INK)
	for index in 6:
		node.inventory_slots.append(_stock.wafer(node, Vector3(-0.73 + index * 0.29, 1.46, 1.15),
			Stock.COOKED, Vector3(0.23, 0.29, 0.49)))
	_console(node, Vector3(1.75, 1.46, 1.33), Color("#d7a889"))
	_beacon(node, Vector3(1.69, 2.15, 0.52))
	_coating_drums[id] = rotor
	_bay(layout.cart_body_center(layout.port(id, &"cooked_dock")) + Vector3.UP * 0.027, Vector2(1.46, 1.41), SAFETY)
	if _erp_enabled:
		_bay(layout.cart_body_center(layout.port(id, &"coated_dock")) + Vector3.UP * 0.027, Vector2(1.46, 1.41), Color("#b88bc7"))


func _build_pack_wip() -> void:
	var node := _station(&"PackagingWIP", "Packaging WIP", Color("#b88bc7"))
	node.offset_readout(Vector3(-0.8, 0.10, 0.55))
	_draw.box(node, Vector3(0, 0.017, 0), Vector3(5.84, 0.03, 1.90), Color("#695d75"))
	for x: float in [-0.45, 1.05, 2.55]:
		for z: float in [-0.81, 0.08]:
			_draw.box(node, Vector3(x, 0.76, z), Vector3(0.09, 1.52, 0.09), STEEL)
	for y: float in [0.20, 0.82]:
		_draw.box(node, Vector3(1.05, y, -0.37), Vector3(3.13, 0.095, 1.02), METAL)
		for x: float in [-0.07, 0.66, 1.43, 2.16]:
			node.inventory_slots.append(_stock.wafer(node, Vector3(x, y + 0.14, -0.38),
				Stock.CHOCOLATE, Vector3(0.61, 0.22, 0.75)))
	_bay(layout.cart_body_center(layout.port(&"PackagingWIP", &"coated_dock")) + Vector3.UP * 0.033, Vector2(1.51, 1.46), Color("#e0b3ee"))


func _build_packer() -> void:
	var node := _station(&"Packer", "05  Packaging", AMBER)
	_base(node)
	_draw.box(node, Vector3(0, 0.63, 0), Vector3(3.95, 0.54, 2.60), STEEL)
	_draw.box(node, Vector3(0, 1.05, 0), Vector3(4.24, 0.20, 1.10), INK)
	for x: float in [-1.63, 1.63]:
		for z: float in [-1.1, 1.1]:
			_draw.box(node, Vector3(x, 1.55, z), Vector3(0.23, 2.1, 0.23), AMBER)
	_draw.box(node, Vector3(0, 2.51, 0), Vector3(3.53, 0.44, 2.51), AMBER)
	_draw.box(node, Vector3(0, 2.78, 0), Vector3(2.97, 0.13, 2.0), PALE)
	_packing_head = _pivot(node, Vector3(0, 1.71, 0))
	_draw.box(_packing_head, Vector3(0, 0.32, 0), Vector3(0.88, 1.1, 0.86), METAL)
	_draw.box(_packing_head, Vector3.ZERO, Vector3(1.15, 0.20, 1.04), PALE)
	_console(node, Vector3(1.53, 1.54, 1.29), AMBER)
	_beacon(node, Vector3(-1.19, 2.82, 0.38))
	_build_belt(&"CartonBelt", layout.belt(&"CartonBelt"), AMBER)


func _build_palletizing() -> void:
	var node := _station(&"Palletizer", "06  Palletizing", AMBER)
	node.offset_readout(Vector3(0, 0, -2.0))
	_draw.box(node, Vector3(-0.66, 0.46, -2), Vector3(6.67, 0.83, 1.45), STEEL)
	_draw.box(node, Vector3(-0.66, 0.92, -2), Vector3(6.80, 0.12, 1.52), METAL)
	_draw.box(node, Vector3(-0.66, 0.68, -1.23), Vector3(6.75, 0.19, 0.08), AMBER)
	_rail(node.to_global(Vector3(-3.65, 0, -3.22)), node.to_global(Vector3(2.75, 0, -3.22)))
	for index in Layout.PALLET_BAYS:
		var at := layout.pallet_position(index)
		_bay(at + Vector3(0, 0.023, 0), Vector2(2.16, 1.91), SAFETY, node.rotation.y)
		_staged.append(_stock.pallet(node, node.to_local(at)))
		_floor_text(at + Vector3(0, 0.036, 1.22).rotated(Vector3.UP, node.rotation.y), "P%d" % (index + 1), PALE, 0.017)


func _build_warehouse() -> void:
	var node := _station(&"Warehouse", "07  FG warehouse", AMBER)
	var size := layout.objects[&"Warehouse"].size
	_draw.box(node, Vector3(0, 0.015, 0),
		Vector3(size.x - 0.4, 0.025, size.y - 0.2), Color("#637276"))
	for index in Layout.WAREHOUSE_SLOTS:
		var at := layout.warehouse_slot(index)
		var marker := _draw.box(self, at + Vector3(0, 0.033, 0), Vector3(1.93, 0.021, 1.54), METAL)
		marker.rotation.y = node.rotation.y
		_warehouse_markers.append(marker)
		_bay(at + Vector3(0, 0.053, 0), Vector2(2.02, 1.68), PALE, node.rotation.y)
		_stored.append(_stock.pallet(node, node.to_local(at) + Vector3(0, 0.049, 0)))
		if _erp_enabled:
			var pick := Equipment.new()
			pick.position = at
			pick.rotation.y = node.rotation.y
			add_child(pick)
			var id := StringName("FGSlot%d" % index)
			pick.configure(id, _draw, Vector3(1.7, 1.7, 1.4), "", AMBER, false)
			_equipment[id] = pick
			_pallet_picks.append(pick)
			pick.set_active(false)
		_floor_text(at + Vector3(0, 0.053, 1.05).rotated(Vector3.UP, node.rotation.y), "%02d" % (index + 1), PALE, 0.015)
	for x: float in [-4.42, 4.46]:
		_draw.box(node, Vector3(x, 0.73, -3.81), Vector3(0.17, 1.46, 0.18), AMBER)
	_draw.box(node, Vector3(0.02, 1.28, -3.81), Vector3(9.0, 0.15, 0.11), STEEL)


func _build_raw_warehouse() -> void:
	var node := _station(&"RawWarehouse", "RM  Raw materials", TEAL)
	_draw.box(node, Vector3(0, 0.045, 0), Vector3(15.8, 0.09, 3.8), Color("#687f8b"))
	for index in 5:
		var x := -6.0 + 3.0 * index
		_draw.box(node, Vector3(x, 0.09, 0.9), Vector3(2.7, 0.035, 1.5), Color("#9a8762"))
		for side: float in [-1.12, 1.12]:
			_draw.box(node, Vector3(x + side, 0.92, -0.73), Vector3(0.09, 1.76, 0.12), STEEL)
		for y: float in [0.27, 1.12]:
			_draw.box(node, Vector3(x, y, -0.73), Vector3(2.28, 0.11, 1.38), TEAL)
		var group := Node3D.new()
		group.position = Vector3(x, 0.33, -0.7)
		node.add_child(group)
		_raw_groups.append(group)
		for shelf in 2:
			for bay in 2:
				var at := Vector3(-0.48 + bay * 0.96, shelf * 0.86, 0.0)
				if index < 2:
					_stock.sack(group, at + Vector3.UP * 0.19)
				else:
					_stock.carton(group, at + Vector3.UP * 0.22, Vector3(0.82, 0.43, 0.78))
		var label: String = ["FLOUR / SUGAR", "OTHER INPUTS", "COATINGS", "CARTONS", "LABELS"][index]
		_floor_text(node.position + Vector3(x, 0.13, 1.05), label, PALE, 0.01)
	_rail(node.position + Vector3(-7.85, 0, -1.82), node.position + Vector3(7.85, 0, -1.82))


func _build_shuttle() -> void:
	_shuttle = Equipment.new()
	add_child(_shuttle)
	_shuttle.configure(&"SupplyShuttle", _draw, Vector3(1.45, 1.25, 2.0), "", TEAL, false)
	_equipment[&"SupplyShuttle"] = _shuttle
	_draw.box(_shuttle, Vector3(0, 0.37, 0), Vector3(1.38, 0.37, 1.9), TEAL)
	_draw.box(_shuttle, Vector3(0, 0.61, -0.64), Vector3(1.08, 0.39, 0.43), INK)
	for x: float in [-0.65, 0.65]:
		for z: float in [-0.57, 0.57]:
			var wheel := _draw.cylinder(_shuttle, Vector3(x, 0.23, z), 0.22, 0.18, INK)
			wheel.rotation_degrees.z = 90.0
	_shuttle_cargo = Node3D.new()
	_shuttle.add_child(_shuttle_cargo)
	_stock.carton(_shuttle_cargo, Vector3(0, 0.77, 0.16), Vector3(0.94, 0.42, 1.04))
	_shuttle_cargo.hide()


func _refresh_erp(line: Line) -> void:
	var book := line.erp
	if _raw_revision != book.warehouse_revision:
		_raw_revision = book.warehouse_revision
		var qty := [0.0, 0.0, 0.0, 0.0, 0.0]
		for code: String in book.balances["RM-WH"]:
			var index := 1
			if code in ["RM-FLOUR", "RM-SUGAR"]:
				index = 0
			elif code.begins_with("RM-COAT-"):
				index = 2
			elif code.begins_with("PK-BOX-"):
				index = 3
			elif code.begins_with("PK-LABEL-"):
				index = 4
			qty[index] += book.stock(code, "RM-WH")
		for index in _raw_groups.size():
			_raw_groups[index].visible = qty[index] > Line.EPSILON
		_equipment[&"RawWarehouse"].update_machine("RM  Raw materials", "ChocoERP stock", Palette.SFG)
	_tint_coating(line.order_at(&"Packer"), &"PackagingWIP", _equipment[&"PackagingWIP"].inventory_slots)


func _tint_coating(order: Dictionary, id: StringName, markers: Array[Node3D]) -> void:
	if order.is_empty() or _coating_colors.get(id, "") == order.recipe.spec.coating_color:
		return
	_coating_colors[id] = order.recipe.spec.coating_color
	var tint := _draw.material(Color(order.recipe.spec.coating_color))
	for wafer in markers:
		(wafer.get_child(0) as MeshInstance3D).material_override = tint


func view_of(id: StringName) -> Equipment:
	if _equipment.has(id):
		return _equipment[id]
	return _logistics.views.get(id)


func _station(
	id: StringName, title: String, accent: Color, show_readout: bool = true, create_hitbox: bool = true
) -> Equipment:
	var spec := layout.definition(id)
	var station := Equipment.new()
	station.position = spec.center(layout.grid)
	station.rotation.y = spec.yaw()
	add_child(station)
	station.configure(id, _draw, Vector3(spec.size.x, spec.height, spec.size.y), title, accent,
		show_readout, Vector3.ZERO, create_hitbox)
	_equipment[id] = station
	return station


func _base(parent: Equipment) -> void:
	var footprint := layout.objects[parent.name].size
	var width := footprint.x - 0.12
	var depth := footprint.y - 0.28
	_draw.box(parent, Vector3(0, 0.22, 0), Vector3(width, 0.44, depth), INK)
	_draw.box(parent, Vector3(0, 0.41, 0), Vector3(width * 0.96, 0.15, depth * 0.92), STEEL)


func _console(parent: Node3D, at: Vector3, tint: Color) -> void:
	_draw.box(parent, at, Vector3(0.62, 0.53, 0.22), INK)
	_draw.box(parent, at + Vector3(0, 0.076, 0.116), Vector3(0.40, 0.19, 0.023), tint)
	_draw.box(parent, at + Vector3(0.16, -0.14, 0.116), Vector3(0.077, 0.075, 0.023), PALE)


func _beacon(station: Equipment, at: Vector3) -> void:
	_draw.cylinder(station, at + Vector3(0, 0.12, 0), 0.10, 0.30, INK)
	station.beacon = _draw.cylinder(station, at + Vector3(0, 0.38, 0), 0.18, 0.25, PALE)
	var lamp := StandardMaterial3D.new()
	lamp.emission_enabled = true
	lamp.emission_energy_multiplier = 0.66
	station.beacon.material_override = lamp


func _build_belt(id: StringName, span: Array[Vector3], accent: Color) -> void:
	_station(id, "", accent, false)
	var delta := span[1] - span[0]
	var length := delta.length()
	var belt := _pivot(self, span[0])
	belt.rotation.y = -atan2(delta.z, delta.x)
	_draw.box(belt, Vector3(length * 0.5, 0, 0), Vector3(length, 0.15, 1.03), INK)
	for index in floori(length / 0.17):
		var roller := _draw.cylinder(belt, Vector3(index * 0.17 + 0.1, 0.09, 0),
			0.045, 0.98, STEEL)
		roller.rotation_degrees.x = 90
	for side: float in [-0.55, 0.55]:
		_draw.box(belt, Vector3(length * 0.5, 0.12, side), Vector3(length, 0.16, 0.085), accent)
		for x: float in [0.24, length - 0.24]:
			_draw.box(belt, Vector3(x, -span[0].y * 0.5, side), Vector3(0.14, span[0].y, 0.14), STEEL)
	_draw.batch_static(belt)


func _rail(start: Vector3, end: Vector3) -> void:
	var delta := end - start
	var count := ceili(delta.length() / 1.72)
	for index in count + 1:
		var at := start.lerp(end, float(index) / count)
		_draw.box(self, at + Vector3(0, 0.52, 0), Vector3(0.081, 1.04, 0.085), SAFETY)
	for y: float in [0.46, 1.00]:
		var mid := (start + end) / 2.0 + Vector3(0, y, 0)
		var beam := _draw.box(self, mid, Vector3(0.074, 0.074, delta.length()), SAFETY)
		beam.look_at(mid + delta)


func _strip(start: float, end: float, z: float, width: float, tint: Color) -> void:
	var length := end - start
	_draw.box(self, Vector3((start + end) * 0.5, 0.016, z), Vector3(length, 0.025, width), tint)


func _bay(at: Vector3, size: Vector2, tint: Color, yaw: float = 0.0) -> void:
	for side: float in [-1, 1]:
		var edge := _draw.box(self, at + Vector3(side * size.x / 2, 0, 0).rotated(Vector3.UP, yaw),
			Vector3(0.063, 0.019, size.y), tint)
		edge.rotation.y = yaw
		edge = _draw.box(self, at + Vector3(0, 0, side * size.y / 2).rotated(Vector3.UP, yaw),
			Vector3(size.x, 0.019, 0.063), tint)
		edge.rotation.y = yaw


func _floor_text(at: Vector3, text: String, tint: Color, size: float) -> void:
	var label := _draw.sign(self, at, text, tint)
	label.rotation_degrees.x = -90
	label.pixel_size = size
	label.outline_size = 0


func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = at
	parent.add_child(pivot)
	return pivot
