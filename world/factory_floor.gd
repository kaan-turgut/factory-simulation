extends Node3D
## The roofless chocolate hall. Geometry and indicators read the simulation's layout and state.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Primitives = preload("res://world/primitives.gd")
const Equipment = preload("res://world/equipment_view.gd")
const Logistics = preload("res://world/logistics_view.gd")
const Stock = preload("res://world/stock_models.gd")
const Processing = preload("res://world/processing_models.gd")
const WarehouseView = preload("res://world/warehouse_view.gd")
const Industrial = preload("res://world/industrial_models.gd")
const Hall = preload("res://world/hall_models.gd")
const LineModels = preload("res://world/line_models.gd")
const GumModels = preload("res://world/gum_models.gd")
const Site = preload("res://world/site_models.gd")
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
const CELL_ART := {
	&"CreamMixer": ["Cream Mixer 01", Color("#b79b66")],
	&"Spreader": ["Cream Spreader 01", Color("#7b9a79")],
	&"Cutter": ["Wafer Cutter 01", Color("#bf8750")],
	&"CoolingTunnel": ["Cooling Tunnel 01", Color("#568ea3")],
	&"Packer02": ["Packaging Line 02", Color("#806c99")],
	&"GumMixer": ["Gum Mixer 01", Color("#4f9fa8")],
	&"GumSheeter": ["Gum Sheeter 01", Color("#5f86c4")],
	&"FruitFormer": ["Fruit Gum Former 01", Color("#e07a5f")],
	&"GumConditioner": ["Gum Conditioning 01", Color("#7fb3c8")],
	&"GumPan01": ["Coating Pan 01", Color("#5f86c4")],
	&"GumPan02": ["Coating Pan 02", Color("#5f86c4")],
	&"GumPan03": ["Coating Pan 03", Color("#5f86c4")],
	&"WalletPacker": ["Wallet Packer 01", Color("#2f9e8f")],
	&"BottleFiller": ["Bottle Filler 01", Color("#3a8fd0")]
}
const GUM_CELLS := [&"GumMixer", &"GumSheeter", &"FruitFormer", &"GumConditioner", &"GumPan01", &"GumPan02",
	&"GumPan03", &"WalletPacker", &"BottleFiller"]
const PACKING_CELLS := [&"Packer02", &"WalletPacker", &"BottleFiller"]

var layout: Layout
var _draw := Primitives.new()
var _stock := Stock.new(_draw)
var _industrial := Industrial.new(_draw, _stock)
var _line := LineModels.new(_industrial)
var _gum := GumModels.new(_industrial)
var _gum_mixer: GumModels.MixerModel
var _pans: Dictionary[StringName, GumModels.PanModel] = {}
var _tunnel_marks: Dictionary[StringName, Array] = {}
var _slot_tints: Dictionary[StringName, StandardMaterial3D] = {}
var _gum_supplies: Array[Node3D] = []
var _syrup_totes: Array[Node3D] = []
var _gum_cartons: Array[Node3D] = []
var _equipment: Dictionary[StringName, Equipment] = {}
var _logistics: Logistics
var _staged: Array[Stock.PalletView] = []
var _stored: Array[Stock.PalletView] = []
var _warehouse_markers: Array[MeshInstance3D] = []
var _oven_doors := {}
var _oven_heaters := {}
var _auger: Node3D
var _enrobers := {}
var _hall: Hall
var _route_overlay: Node3D
var _raw_groups: Array[Node3D] = []
## High-bay raw warehouse: one slot per pallet position, drawn with three multimeshes.
var _raw_slots: Array[Transform3D] = []
var _raw_decks: MultiMesh
var _raw_cases: MultiMesh
var _raw_sacks: MultiMesh
var _pallet_picks: Array[Equipment] = []
var _freight_cage: Node3D
var _raw_revision := -1
var _coating_colors := {}
var _erp_enabled := false
var _cream_motor: Node3D
var _processing_models: Dictionary[StringName, Processing] = {}
var _warehouse_views: Array[WarehouseView] = []
var _cream_supplies: Array[Node3D] = []


func configure(floor_plan: Layout, erp_enabled: bool = false) -> void:
	_erp_enabled = erp_enabled
	_raw_groups.clear()
	_raw_slots.clear()
	_raw_decks = null
	_pallet_picks.clear()
	_raw_revision = -1
	_coating_colors.clear()
	_route_overlay = null
	_oven_doors.clear()
	_oven_heaters.clear()
	_enrobers.clear()
	_processing_models.clear()
	_warehouse_views.clear()
	_tunnel_marks.clear()
	_cream_supplies.clear()
	_gum_mixer = null
	_pans.clear()
	_slot_tints.clear()
	_gum_supplies.clear()
	_syrup_totes.clear()
	_gum_cartons.clear()
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
		_build_sfg_warehouse()
		for id: StringName in CELL_ART:
			_build_cell(id)
	Site.new().build(self, layout, _industrial, _draw, _stock)
	_draw.batch_static(self, _warehouse_markers)
	for station in _equipment.values():
		_draw.batch_static(station, [station.beacon])
	_logistics = Logistics.new(self, _draw, _stock, _erp_enabled, _industrial)
	_logistics.freight_cage = _freight_cage


func update_view(camera: Camera3D) -> void:
	# Cut away the walls and roof bays that would block the camera.
	if _hall != null:
		_hall.update_view(camera)


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
	_processing_models[&"Packer"].show_loads(line.packer.state == Line.Machine.State.RUNNING)
	var hopper_text := "%0.0f / %0.0f kg" % [line.hopper.quantity, line.hopper.capacity]
	if _erp_enabled and line.erp.explicit_planning:
		var prepared := 0.0
		for quantity in line.erp.balances["SFG-DECK"].values():
			prepared += float(quantity)
		hopper_text = "%.0f kg dough stock · %s in hopper" % [prepared, hopper_text]
	_equipment[&"Hopper"].update_machine("01  Ingredients", hopper_text, Color("#b7cef0"))
	_equipment[&"Hopper"].fill_slots(line.hopper.occupancy())
	_equipment[&"Coater"].fill_slots(line.cooked_input.occupancy())
	_refresh_oven(&"Oven", "Oven 01", line.oven)
	_equipment[&"Palletizer"].update_machine("06  Palletizing", "%d full" % line.pallets_ready(), Palette.FG)
	_equipment[&"Warehouse"].update_machine("07  FG warehouse", "%d / %d pallets" % [
		line.warehouse_count(), line.warehouse.size()], Palette.FG)
	for index in _staged.size():
		_staged[index].refresh(line.staged_pallets[index], true)
	var free := line.warehouse.size() - line.warehouse_count()
	free -= int(line.warehouse_reserved_slot >= 0)
	for index in _stored.size():
		var pallet := line.warehouse[index]
		if pallet != null and _stored[index] == null:
			var node := _equipment[&"Warehouse"]
			_stored[index] = _stock.pallet(node, node.to_local(layout.warehouse_slot(index)) + Vector3.UP * (0.049 + layout.warehouse_height(index)))
		if _stored[index] != null:
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
		if index < _warehouse_markers.size():
			_warehouse_markers[index].material_override = _draw.material(marker)
	_logistics.refresh(line)
	if line.erp != null and _erp_enabled:
		_refresh_erp(line)
		_refresh_cells(line)
		for id: StringName in _enrobers:
			var order := line.order_at(id)
			var coating: String = order.get("recipe", {}).get("spec", {}).get("coating_color", "")
			if Color.html_is_valid(coating):
				_enrobers[id].tint(Color(coating))


func animate(line: Line, delta: float) -> void:
	_logistics.animate(line, delta)
	_auger.rotation.x = fposmod(line.extruder.total_output * 0.28, TAU)
	_processing_models[&"Packer"].animate(line.packer.state == Line.Machine.State.RUNNING, delta)
	for room in _warehouse_views:
		room.animate(line, delta)
	_animate_station(line, &"Oven", &"Coater", line.oven, line.coater, delta)
	if _erp_enabled:
		_animate_station(line, &"Oven02", &"Coater02", line.ovens[&"Oven02"], line.coaters[&"Coater02"], delta)
		_animate_cells(line, delta)


func _refresh_oven(id: StringName, title: String, machine: Line.Oven) -> void:
	var cooking := machine.state == Line.Oven.State.COOKING
	var tint := Palette.BLOCKED if cooking else Palette.IDLE
	if machine.state in [Line.Oven.State.READY, Line.Oven.State.UNLOADING]:
		tint = Palette.RUNNING
	_equipment[id].update_machine(title, machine.state_title(), tint)
	_oven_heaters[id].visible = cooking


func _animate_station(line: Line, oven_id: StringName, coat_id: StringName, oven: Line.Oven, coater: Line.Machine, delta: float) -> void:
	_enrobers[coat_id].animate(coater.total_output, coater.state == Line.Machine.State.RUNNING)
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
		if op.type == "pack" and op.equipment == "Packer":
			steps.append([&"PackagingWIP", "Cart delivery · WIP"])
		elif op.type in ["spread", "cut", "cool", "gum_form", "gum_condition", "gum_coat"] or StringName(op.equipment) in PACKING_CELLS:
			steps.append([&"SFGWarehouse", "Reserved semi-finished stock"])
		steps.append([StringName(op.equipment), "%02d  %s" % [op.number, op.description]])
		if StringName(op.equipment) in PACKING_CELLS:
			steps.append([&"Palletizer", "Cart delivery · cartons"])
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
	_hall = Hall.new(_industrial)
	_hall.light(self)

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
				Vector3(tile.x - 0.02, 0.11, tile.y - 0.02), slab).material_override = _industrial.concrete(slab)
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
	_hall.build(self, grid, layout)
	var aisle_end := layout.cart_aisle_end()
	_strip(grid.origin.x + 1.5, grid.origin.x + aisle_end - 1.0, layout.lane_z(layout.walk_lane),
		0.87, Color("#a6acaa"))
	var lift_z := layout.lane_z(layout.lift_lane)
	var side := layout.lift_side_x()
	_strip(grid.origin.x + aisle_end - 1.8, side + 0.62, lift_z, 2.64, Color("#706e5d"))
	var outbound := layout.center(&"Warehouse") + Vector3(0.5, 0.04, -5.1)
	if Layout.WarehouseRoom.high_bay(layout.objects[&"Warehouse"].size):
		var entry := layout.warehouse_entry_path()
		for index in range(1, entry.size()):
			_drive_lane(entry[index - 1], entry[index], 1.95, 0.016)
		_drive_lane(entry.back(), entry.back().move_toward(layout.center(&"Warehouse"), 4.0), 2.4, 0.019)
		outbound = entry.back() + Vector3(0, 0.04, 1.15)
	else:
		var rear_z := layout.lane_z(layout.rear_lane)
		_strip(layout.center(&"Warehouse").x - 5.8, side + 0.62, rear_z, 1.8, Color("#706e5d"))
		_drive_lane(Vector3(side, 0, lift_z), Vector3(side, 0, rear_z), 1.32, 0.013)
	for x in range(aisle_end - 1, width - 1):
		_draw.box(self, grid.to_world(Vector2(x, layout.lift_lane), 0.029),
			Vector3(0.43, 0.014, 0.057), SAFETY)
	for x in range(2, aisle_end - 1, 2):
		_draw.box(self, grid.to_world(Vector2(x, layout.walk_lane), 0.032),
			Vector3(0.64, 0.014, 0.045), PALE)
	_floor_text(grid.to_world(Vector2(30.5, 2.7), 0.04), "CHOCOLATE WORKS   /   02", PALE, 0.031)
	_floor_text(grid.to_world(Vector2(width - 12.0, 2.9), 0.04), "FORKLIFT ONLY  ›", SAFETY, 0.025)
	_floor_text(outbound, "OUTBOUND", SAFETY, 0.025)
	for id in [&"RawParking", &"CookedParking"]:
		_station(id, "", PALE, false)
	if _erp_enabled:
		_station(&"CoatedParking", "", Color("#b88bc7"), false)
		_floor_text(layout.center(&"CoatedParking") + Vector3(0, 0.04, 1.15), "COATED CARTS", Color("#e0b3ee"), 0.014)


func _build_platform() -> void:
	var deck := _station(&"Platform", "", PALE, false)
	var plan := layout.objects[&"Platform"]
	var half := Vector2(plan.size) * 0.5
	var y := plan.elevation
	# The walking surface sits above the frame and supports to avoid coplanar faces.
	var sheet_thickness := 0.05
	var frame_height := 0.34 - sheet_thickness
	var leg_height := y - sheet_thickness
	var k := _industrial
	var column := k.paint(STEEL)
	k.box(deck, Vector3(0, -sheet_thickness - frame_height * 0.5, 0),
		Vector3(plan.size.x, frame_height, plan.size.y), k.frame_dark)
	k.box(deck, Vector3(0, -sheet_thickness * 0.5, 0),
		Vector3(plan.size.x - 0.08, sheet_thickness, plan.size.y - 0.08), k.grating)
	# Joists under the grating.
	for x in range(1, int(plan.size.x)):
		k.box(deck, Vector3(-half.x + x, -sheet_thickness - frame_height - 0.12, 0),
			Vector3(0.1, 0.24, plan.size.y - 0.3), k.frame_dark)
	for side_x: float in [-1.0, 1.0]:
		for side_z: float in [-1.0, 1.0]:
			var leg := Vector3(side_x * (half.x - 0.23), -y + leg_height * 0.5, side_z * (half.y - 0.23))
			k.box(deck, leg, Vector3(0.26, leg_height, 0.26), column)
			k.box(deck, leg + Vector3(0, -leg_height * 0.5 + 0.015, 0), Vector3(0.5, 0.03, 0.5), k.frame_dark)
			k.box(deck, leg + Vector3(0, -leg_height * 0.5 + 0.5, 0), Vector3(0.3, 1.0, 0.3), k.hazard)
	var left := deck.position.x - half.x + 0.08
	var right := deck.position.x + half.x - 0.08
	var front := deck.position.z + half.y - 0.08
	var rear := deck.position.z - half.y + 0.08
	var hopper := _station(&"Hopper", "01  Ingredients", PALE)
	hopper.offset_readout(Vector3(-2.35, 0.35, -2.75))
	_rail(Vector3(left, y, rear), Vector3(right, y, rear))
	_rail(Vector3(left, y, rear), Vector3(left, y, front))
	if layout.has_freight_lift():
		# Leave the front rail open where the lift cage docks with the deck.
		var gate := deck.position.x + Layout.FREIGHT_LIFT_CAGE.x
		_rail(Vector3(left, y, front), Vector3(gate - 1.3, y, front))
		_rail(Vector3(gate + 1.3, y, front), Vector3(right, y, front))
	else:
		_rail(Vector3(left, y, front), Vector3(right, y, front))
	var stairs := _station(&"Stairs", "", SAFETY, false, false)
	var stair_plan := layout.objects[&"Stairs"]
	var stair_depth := stair_plan.size.y
	var rise := stair_plan.height
	# The stair footprint can straddle the deck edge. Keep the flight in the part that is
	# clear of the deck, so no tread runs underneath it.
	var footprint := Vector2(-stair_plan.size.x * 0.5, stair_plan.size.x * 0.5)
	var deck_edge := deck.position.x + half.x - stairs.position.x
	if deck_edge > footprint.x and deck_edge < footprint.y - 0.6:
		footprint.x = deck_edge + 0.08
	var stair_x := (footprint.x + footprint.y) * 0.5
	var stair_width := footprint.y - footprint.x - 0.16
	var top_z := stairs.position.z - stair_depth * 0.5
	# Deck edge rail with an opening where the flight arrives.
	_rail(Vector3(right, y, rear), Vector3(right, y, top_z - 0.05))
	if front > top_z + 1.2:
		_rail(Vector3(right, y, top_z + 1.05), Vector3(right, y, front))
	# The deck itself is the landing above the twelve treads.
	for index in 12:
		var step_y := rise * (12.0 - index) / 13.0
		var z := -stair_depth * 0.5 + (index + 0.5) * stair_depth / 12.0
		var size := Vector3(stair_width, 0.22, stair_depth / 12.0)
		_industrial.box(stairs, Vector3(stair_x, step_y - 0.03, z), Vector3(size.x, 0.05, size.z), _industrial.grating)
		_industrial.box(stairs, Vector3(stair_x, step_y - 0.03, z + size.z * 0.5 - 0.02), Vector3(size.x, 0.052, 0.04), _industrial.safety)
		stairs.add_hitbox(size, Vector3(stair_x, step_y - 0.22, z))
	for side: float in [-0.5, 0.5]:
		var stringer := _industrial.box(stairs, Vector3(stair_x + side * stair_width, rise * 0.5 - 0.1, 0),
			Vector3(0.06, 0.3, sqrt(stair_depth * stair_depth + rise * rise)), _industrial.frame_dark)
		stringer.rotation.x = atan2(rise, stair_depth)
		# The deck-side rail starts below the opening so people can step across onto the deck.
		var start := 1.05 if side < 0.0 and footprint.x > -stair_plan.size.x * 0.5 else 0.0
		var rail_x := stair_x + side * (stair_width + 0.1)
		_rail(stairs.position + Vector3(rail_x, lerpf(rise, 0.25, start / stair_depth), -stair_depth * 0.5 + start),
			stairs.position + Vector3(rail_x, 0.25, stair_depth * 0.5))
	# Guard across the open top end of the flight.
	_rail(stairs.position + Vector3(stair_x - stair_width * 0.55, rise, -stair_depth * 0.5),
		stairs.position + Vector3(stair_x + stair_width * 0.55, rise, -stair_depth * 0.5))
	for index in 4:
		for tier in 3:
			_stock.sack(deck, Vector3(-4.12 + index * 1.21, 0.22 + tier * 0.31,
				-2.27 - (index % 2) * 0.24), 1.14)
	_floor_text(deck.position + Vector3(-2.0, 0.023, 0.41), "INGREDIENT DECK", INK, 0.015)
	_line.build_hopper(hopper)
	for index in 6:
		var bag := _stock.sack(hopper, Vector3(0, 1.58, 0), 0.55)
		bag.position = Vector3(-0.52 + (index % 3) * 0.52, 1.58, -0.26 + floori(index / 3.0) * 0.54)
		hopper.inventory_slots.append(bag)
	if layout.has_freight_lift():
		_build_freight_lift()


## A caged freight lift on the deck's aisle side: the material handler rides it with the pallet jack.
func _build_freight_lift() -> void:
	var k := _industrial
	var top := layout.objects[&"Platform"].elevation
	var tower := Node3D.new()
	tower.name = "FreightLift"
	tower.position = layout.freight_lift_base()
	add_child(tower)
	var half := Layout.FREIGHT_LIFT_SIZE * 0.5 + Vector2(0.12, 0.12)
	var height := top + 1.45
	k.box(tower, Vector3(0, 0.02, 0), Vector3(half.x * 2.0 + 0.3, 0.04, half.y * 2.0 + 0.3), k.frame_dark)
	for side_x: float in [-1.0, 1.0]:
		for side_z: float in [-1.0, 1.0]:
			var post := Vector3(side_x * half.x, height * 0.5, side_z * half.y)
			k.box(tower, post, Vector3(0.12, height, 0.12), k.frame_dark)
			k.box(tower, post * Vector3(1, 0, 1) + Vector3(0, 0.45, 0), Vector3(0.18, 0.9, 0.18), k.hazard)
	# The shaft stays open on the aisle side (+Z) and toward the deck (-Z); frames tie the posts above and below.
	for tie_y: float in [0.05, top * 0.5, height]:
		for side_z: float in [-1.0, 1.0]:
			k.box(tower, Vector3(0, tie_y, side_z * half.y), Vector3(half.x * 2.0, 0.1, 0.1), k.frame_dark)
		for side_x: float in [-1.0, 1.0]:
			k.box(tower, Vector3(side_x * half.x, tie_y, 0), Vector3(0.1, 0.1, half.y * 2.0), k.frame_dark)
	# Chain hoist: motor and drive housing on the roof, guide chain down the rear posts.
	k.box(tower, Vector3(0, height + 0.2, 0), Vector3(1.1, 0.4, 0.8), k.paint(AMBER))
	for side_x: float in [-0.5, 0.5]:
		k.pipe(tower, Vector3(side_x, height, -0.5), Vector3(side_x, 0.2, -0.5), 0.015, k.chrome)
	_draw.batch_static(tower)
	# The moving cage: grating floor, side guards and a chain across the aisle-side entry.
	_freight_cage = Node3D.new()
	_freight_cage.name = "Cage"
	tower.add_child(_freight_cage)
	var cage := Layout.FREIGHT_LIFT_SIZE
	k.box(_freight_cage, Vector3(0, -0.02, 0), Vector3(cage.x, 0.08, cage.y), k.grating)
	k.box(_freight_cage, Vector3(0, -0.1, 0), Vector3(cage.x, 0.1, cage.y), k.frame_dark)
	for side_x: float in [-1.0, 1.0]:
		var wall_x := side_x * (cage.x * 0.5 - 0.04)
		k.box(_freight_cage, Vector3(wall_x, 1.0, 0), Vector3(0.05, 0.05, cage.y), k.safety)
		k.box(_freight_cage, Vector3(wall_x, 0.55, 0), Vector3(0.04, 0.04, cage.y), k.safety)
		k.box(_freight_cage, Vector3(wall_x, 0.5, 0), Vector3(0.04, 1.0, 0.04), k.safety)
	k.box(_freight_cage, Vector3(0, 0.95, cage.y * 0.5 - 0.04), Vector3(cage.x, 0.04, 0.04), k.hazard)
	_draw.batch_static(_freight_cage)


func _build_extruder() -> void:
	var node := _station(&"Extruder", "02  Extruder", TEAL)
	node.offset_readout(Vector3(0, -0.66, 1.25))
	var feed: Vector3 = layout.objects[&"Extruder"].ports[&"feed"]
	feed.z = -feed.z
	_auger = _line.build_extruder(node, TEAL, feed)


func _build_oven(id: StringName, title: String) -> void:
	var node := _station(id, title, OVEN_RED)
	var model := _industrial.build_oven(node, title, OVEN_RED)
	_oven_doors[id] = model.door
	_oven_heaters[id] = model.heater


func _build_coater(id: StringName, title: String) -> void:
	var node := _station(id, title, COCOA)
	_enrobers[id] = _industrial.build_enrober(node, title, COCOA)


func _build_pack_wip() -> void:
	var node := _station(&"PackagingWIP", "Packaging WIP", Color("#b88bc7"))
	node.offset_readout(Vector3(-0.8, 0.10, 0.55))
	_draw.box(node, Vector3(0, 0.017, 0), Vector3(5.84, 0.03, 1.90), Color("#695d75"))
	_line.wire_shelving(node, Vector3(1.05, 0, -0.37), Vector3(3.1, 1.5, 0.92), [0.2, 0.82, 1.44], [-1.5, 0.0, 1.5])
	for y: float in [0.20, 0.82]:
		for x: float in [-0.07, 0.66, 1.43, 2.16]:
			node.inventory_slots.append(_stock.wafer(node, Vector3(x, y + 0.012, -0.38),
				Stock.CHOCOLATE, Vector3(0.61, 0.22, 0.75)))


func _build_packer() -> void:
	var node := _station(&"Packer", "05  Packaging", AMBER)
	_processing_models[&"Packer"] = Processing.new(_industrial, node, &"Packer", 4.2, AMBER)
	_build_belt(&"CartonBelt", layout.belt(&"CartonBelt"), AMBER)


func _build_palletizing() -> void:
	var node := _station(&"Palletizer", "06  Palletizing", AMBER)
	node.offset_readout(Vector3(0, 0, -2.0))
	var bays: Array[Vector3] = []
	for index in Layout.PALLET_BAYS:
		bays.append(node.to_local(layout.pallet_position(index)))
	_line.build_palletizing(node, AMBER, bays)
	_rail(node.to_global(Vector3(-3.65, 0, -3.42)), node.to_global(Vector3(-0.3, 0, -3.42)))
	for index in Layout.PALLET_BAYS:
		var at := layout.pallet_position(index)
		_bay(at + Vector3(0, 0.023, 0), Vector2(2.16, 1.91), SAFETY, node.rotation.y)
		_staged.append(_stock.pallet(node, node.to_local(at)))
		_floor_text(at + Vector3(0, 0.036, 1.22).rotated(Vector3.UP, node.rotation.y), "P%d" % (index + 1), PALE, 0.017)


func _build_warehouse() -> void:
	var spec := layout.objects[&"Warehouse"]
	var size := spec.size
	var room := Layout.WarehouseRoom.new(size, true)
	var high_bay := room.rack_bays > 0
	var node := _station(&"Warehouse", "07  FG warehouse", AMBER, true, not high_bay)
	if high_bay:
		node.add_hitbox(Vector3(size.x, 0.12, size.y), Vector3.ZERO)
	_warehouse_views.append(WarehouseView.new(node, _draw, room, AMBER, _industrial))
	node.offset_readout(Vector3(0, room.height - spec.height, -size.y * 0.30))
	_draw.box(node, Vector3(0, 0.015, 0),
		Vector3(size.x - 0.4, 0.025, size.y - 0.2), Color("#637276"))
	if high_bay:
		var per_row := Layout.WarehouseRoom.FG_SLOTS_PER_ROW
		var turn := Vector3.BACK * Layout.WarehouseRoom.FG_TURN_AHEAD
		var back := node.to_local(layout.warehouse_approach(Layout.WarehouseRoom.FG_SLOT_COUNT - per_row)).z + turn.z
		_drive_lane(node.to_global(Vector3(0, 0, size.y * 0.5)), node.to_global(Vector3(0, 0, back)), 3.2, 0.032)
		for index in range(0, Layout.WarehouseRoom.FG_SLOT_COUNT, per_row):
			var left := node.to_local(layout.warehouse_approach(index)) + turn
			var right := node.to_local(layout.warehouse_approach(index + per_row - 1)) + turn
			_drive_lane(node.to_global(left), node.to_global(right), 2.0, 0.034)
	for index in layout.warehouse_position_count():
		var at := layout.warehouse_slot(index)
		var marker := _draw.box(self, at + Vector3(0, 0.033, 0), Vector3(1.93, 0.021, 1.54), METAL)
		marker.rotation.y = node.rotation.y
		_warehouse_markers.append(marker)
		_bay(at + Vector3(0, 0.053, 0), Vector2(2.02, 1.68), PALE, node.rotation.y)
		_floor_text(at + Vector3(0, 0.053, 1.05).rotated(Vector3.UP, node.rotation.y), "%02d" % (index + 1), PALE, 0.015)
	# Every pallet place, upper rack levels included, can be selected once a pallet sits in it.
	for index in layout.warehouse_slot_count():
		_stored.append(null)
		if _erp_enabled:
			var pick := Equipment.new()
			pick.position = layout.warehouse_slot(index) + Vector3.UP * layout.warehouse_height(index)
			pick.rotation.y = node.rotation.y
			add_child(pick)
			var id := StringName("FGSlot%d" % index)
			pick.configure(id, _draw, Vector3(1.7, 1.7, 1.4), "", AMBER, false)
			_equipment[id] = pick
			_pallet_picks.append(pick)
			pick.set_active(false)
	_draw.batch_static(node)


func _build_raw_warehouse() -> void:
	var spec := layout.objects[&"RawWarehouse"]
	var room := Layout.WarehouseRoom.new(spec.size, false)
	var high_bay := room.rack_bays > 0
	var node := _station(&"RawWarehouse", "RM  Raw materials", TEAL, true, not high_bay)
	if high_bay:
		node.add_hitbox(Vector3(spec.size.x, 0.12, spec.size.y), Vector3.ZERO)
	_warehouse_views.append(WarehouseView.new(node, _draw, room, TEAL, _industrial))
	node.offset_readout(Vector3(0, room.height - spec.height, -spec.size.y * 0.25))
	_draw.box(node, Vector3(0, 0.045, 0), Vector3(spec.size.x - 0.2, 0.09, spec.size.y - 0.2), Color("#687f8b"))
	if high_bay:
		_build_raw_slots(node, room)
	for index in room.racks.size():
		var area := room.racks[index]
		var center := area.get_center()
		var x := center.x
		var z := center.y
		var apron := area.end.y + 0.62
		_draw.box(node, Vector3(x, 0.10, apron), Vector3(area.size.x, 0.016, 1.1), Color("#556d73"))
		if not high_bay:
			for side: float in [-1.12, 1.12]:
				_draw.box(node, Vector3(x + side * (area.size.x * 0.5 - 0.12), 0.92, z),
					Vector3(0.09, 1.76, 0.12), STEEL)
			for y: float in [0.27, 1.12]:
				_draw.box(node, Vector3(x, y, z), Vector3(area.size.x, 0.11, area.size.y), TEAL)
		if high_bay:
			_floor_text(node.to_global(Vector3(x, 0.13, apron)), "RACK " + "ABCDE"[index % 5], PALE, 0.020)
			continue
		var group := Node3D.new()
		group.position = Vector3(x, 0, z)
		node.add_child(group)
		_raw_groups.append(group)
		var shelves: Array = room.rack_levels.slice(0, 3) if high_bay else [0.27, 1.12]
		var bays := room.rack_bays if high_bay else 2
		for shelf: float in shelves:
			for bay in bays:
				var at := Vector3((bay + 0.5 - bays * 0.5) * area.size.x / bays, shelf + 0.10, 0.0)
				if high_bay:
					_stock.pallet_deck(group, at - Vector3.UP * 0.02, Vector2(1.38, 1.10), 0.14)
				if index < 2:
					_stock.sack(group, at + Vector3.UP * 0.26, 1.1 if high_bay else 0.81)
				else:
					var carton := Vector3(1.27, 0.56, 1.02) if high_bay else Vector3(area.size.x * 0.39, 0.43, 0.78)
					_stock.carton(group, at + Vector3.UP * (0.12 + carton.y * 0.5), carton)
		_draw.batch_static(group)
		var label: String = ["FLOUR / SUGAR", "OTHER INPUTS", "COATINGS", "CARTONS", "LABELS"][index]
		_floor_text(node.to_global(Vector3(x, 0.13, apron)), label, PALE, 0.020 if high_bay else 0.01)
	var dock := layout.supply_point("RM-WH")
	if high_bay:
		var threshold := node.to_global(Vector3(0, 0, spec.size.y * 0.5))
		var apron := threshold + Vector3.BACK.rotated(Vector3.UP, node.rotation.y) * 3.25
		_drive_lane(dock, threshold, 3.2, 0.104)
		_drive_lane(threshold, apron, 2.4, 0.016)
		_floor_text(apron + Vector3.UP * 0.04, "INBOUND", SAFETY, 0.025)
	_bay(dock + Vector3.UP * 0.12, Vector2(2.15, 2.70), SAFETY, node.rotation.y)
	_draw.batch_static(node)


func _build_sfg_warehouse() -> void:
	var node := _station(&"SFGWarehouse", "SFG  WAFER STOCK", TEAL)
	_draw.box(node, Vector3(0, 0.012, 0), Vector3(6.9, 0.02, 2.9), Color("#687f8b"))
	_line.longspan_shelving(node, Vector3(0, 0, 0.1), Vector3(6.5, 2.3, 1.25), [0.35, 1.25, 2.14], [-3.2, -1.1, 1.1, 3.2])
	for index in 6:
		var at := Vector3(-2.15 + (index % 3) * 2.15, 0.53 + floorf(index / 3.0) * 0.9, 0.1)
		var stock := Node3D.new()
		stock.position = at
		node.add_child(stock)
		_stock.carton(stock, Vector3.ZERO, Vector3(1.8, 0.32, 1.0))
		node.inventory_slots.append(stock)


func _build_cell(id: StringName) -> void:
	var art: Array = CELL_ART[id]
	var node := _station(id, art[0], art[1])
	var size: Vector2i = layout.objects[id].size
	if id == &"CreamMixer":
		_cream_motor = _line.build_cream_mixer(node, art[1])
		for index in 4:
			_cream_supplies.append(_stock.sack(node, Vector3(-2.0, 0.63, -1.68 + index * 0.88), 0.78))
	elif id == &"GumMixer":
		_gum_mixer = _gum.build_mixer(node, art[1])
		# Weighed gum base, polyol and aroma sacks staged on a pallet beside the mixer.
		_stock.pallet_deck(node, Vector3(-1.75, 0, 1.45), Vector2(1.1, 0.9), 0.14)
		for index in 4:
			_gum_supplies.append(_stock.sack(node, Vector3(-1.75, 0.28 + floorf(index / 2.0) * 0.22,
				1.45 + (index % 2 - 0.5) * 0.44), 0.7))
	elif _gum_pan(id):
		_pans[id] = _gum.build_pan(node, art[1], art[0])
		node.offset_readout(Vector3(0, 0.6, 0))
		if id == &"GumPan02":
			# The shared syrup station between the pans: coating syrup in IBC totes.
			for side: float in [-1.0, 1.0]:
				_syrup_totes.append(_gum.ibc(node, Vector3(side * 3.0, 0, -0.9), Color("#d9b46a") if side < 0 else Color("#cfe3f0")))
	else:
		var model := Processing.new(_industrial, node, id, size.x - 0.30, art[1])
		_processing_models[id] = model
		node.offset_readout(Vector3(0, 0.72, -0.68))
		if id in [&"CoolingTunnel", &"GumConditioner"]:
			var marks: Array[Node3D] = []
			var half := (size.x - 0.30) * 0.5 - 0.4
			for index in 6:
				var tint := Stock.CHOCOLATE if id == &"CoolingTunnel" else Color("#e7e2d2")
				marks.append(_stock.wafer(node, Vector3(lerpf(-half, half, index / 5.0), model.belt_load_height(), 0),
					tint, Vector3(0.44, 0.14 if id == &"CoolingTunnel" else 0.06, 0.66)))
			_tunnel_marks[id] = marks
		if id == &"WalletPacker":
			# Cartons, labels and wallet cards for both gum packers on a pallet between them.
			var stack := _pivot(node, Vector3(5.0, 0, -0.6))
			_stock.pallet_deck(stack, Vector3.ZERO, Vector2(1.2, 1.0), 0.14)
			for index in 6:
				_stock.carton(stack, Vector3(-0.3 + (index % 2) * 0.6, 0.31 + floorf(index / 2.0) * 0.34, 0), Vector3(0.56, 0.32, 0.9))
			_gum_cartons.append(stack)
	var tray_z := 1.78 if id in [&"CreamMixer", &"GumMixer"] else 1.50
	var tray_y := 0.77 if id in [&"CreamMixer", &"GumMixer"] else 0.95
	# Stainless outfeed table with raised lips.
	var k := _industrial
	k.box(node, Vector3(0, tray_y - 0.02, tray_z), Vector3(2.03, 0.04, 0.66), k.stainless)
	for z: float in [-0.32, 0.32]:
		k.box(node, Vector3(0, tray_y + 0.02, tray_z + z), Vector3(2.03, 0.05, 0.02), k.polished)
	for x: float in [-0.95, 0.95]:
		for z: float in [-0.26, 0.26]:
			k.leg(node, Vector3(x, 0, tray_z + z), tray_y - 0.04)
	k.box(node, Vector3(0, 0.25, tray_z), Vector3(1.9, 0.02, 0.5), k.stainless_dark)
	for index in 4:
		var at := Vector3(-0.66 + index * 0.44, tray_y + 0.003, tray_z)
		if id in PACKING_CELLS:
			var box := _pivot(node, at)
			_stock.carton(box, Vector3.UP * 0.10, Vector3(0.37, 0.20, 0.42))
			node.inventory_slots.append(box)
		elif id in GUM_CELLS:
			node.inventory_slots.append(_gum_tote(id, node, at))
		else:
			var tint := Stock.CHOCOLATE if id == &"CoolingTunnel" else Stock.COOKED
			node.inventory_slots.append(_stock.wafer(node, at, tint, Vector3(0.34, 0.16, 0.42)))


func _refresh_cells(line: Line) -> void:
	for id in CELL_ART:
		var node := _equipment[id]
		var cell := line.active_cell(id)
		node.update_machine(CELL_ART[id][0], line.work_center_status(id),
			Palette.IDLE if cell == null else Palette.color(cell.machine.state))
		if _processing_models.has(id):
			_processing_models[id].show_loads(cell != null and cell.machine.state == Line.Machine.State.RUNNING)
		node.fill_slots(0.0 if cell == null else cell.output.occupancy())
		if id == &"Cutter" and cell != null:
			var spec: Dictionary = line.order_at(id).recipe.spec
			var length_mm: float = spec.get("dimensions_mm", [80])[0]
			for item in node.inventory_slots:
				item.scale.x = clampf(length_mm / 80.0, 0.25, 1.25)
	_show_staged(_cream_supplies, line, "CREAM-IN", 15.0)
	_show_staged(_gum_supplies, line, "GUM-IN", 10.0)
	_show_staged(_syrup_totes, line, "GUM-PAN-IN", 20.0)
	_show_staged(_gum_cartons, line, "GUM-PACK-IN", 1.0)
	for id: StringName in _tunnel_marks:
		var tunnel := line.active_cell(id)
		var marks: Array = _tunnel_marks[id]
		for index in marks.size():
			marks[index].visible = tunnel != null and index < ceili(tunnel.inside / tunnel.standard.internal_kg * marks.size())
	for id: StringName in GUM_CELLS:
		var order := line.order_at(id)
		if order.is_empty() or not _equipment.has(id):
			continue
		var spec: Dictionary = order.recipe.spec
		var product := Color(spec.get("coating_color", "#e7e2d2"))
		var package := Color(spec.get("package_color", spec.get("coating_color", "#e7e2d2")))
		if _processing_models.has(id):
			_processing_models[id].tint(product, package)
		if _pans.has(id):
			_pans[id].tint(product)
		if id == &"GumMixer" and _gum_mixer != null:
			_gum_mixer.tint(product)
		if _slot_tints.has(id) and _slot_tints[id].albedo_color != product:
			_slot_tints[id].albedo_color = product
		for mark in _tunnel_marks.get(id, []):
			(mark.get_child(0) as MeshInstance3D).material_override = _draw.material(product)


func _show_staged(items: Array[Node3D], line: Line, location: String, step: float) -> void:
	if items.is_empty():
		return
	var staged := 0.0
	for quantity in line.erp.balances.get(location, {}).values():
		staged += float(quantity)
	for index in items.size():
		items[index].visible = staged > index * step


func _gum_pan(id: StringName) -> bool:
	return String(id).begins_with("GumPan")


## Blue food-grade tote holding gum mass, centres or coated gum; the contents take the order colour.
func _gum_tote(id: StringName, parent: Node3D, at: Vector3) -> Node3D:
	if not _slot_tints.has(id):
		var surface := StandardMaterial3D.new()
		surface.albedo_color = Color("#e7e2d2")
		surface.roughness = 0.45
		_slot_tints[id] = surface
	var tote := _pivot(parent, at)
	var content := _draw.box(tote, Vector3(0, 0.13, 0), Vector3(0.3, 0.06, 0.36), Color.WHITE)
	content.material_override = _slot_tints[id]
	var plastic := Color("#2a6db5")
	_draw.box(tote, Vector3(0, 0.012, 0), Vector3(0.36, 0.024, 0.42), plastic)
	for x: float in [-0.17, 0.17]:
		_draw.box(tote, Vector3(x, 0.09, 0), Vector3(0.02, 0.16, 0.42), plastic)
	for z: float in [-0.2, 0.2]:
		_draw.box(tote, Vector3(0, 0.09, z), Vector3(0.36, 0.16, 0.02), plastic)
	_draw.batch_static(tote, [content])
	return tote


func _animate_cells(line: Line, delta: float) -> void:
	var mixer := line.active_cell(&"CreamMixer")
	if mixer != null:
		_cream_motor.rotation.y = fposmod(mixer.remaining * 3.0, TAU)
	for id: StringName in CELL_ART:
		if not _processing_models.has(id):
			continue
		var cell := line.active_cell(id)
		_processing_models[id].animate(cell != null and cell.machine.state == Line.Machine.State.RUNNING, delta)
	var step := delta if line.playing else 0.0
	if _gum_mixer != null:
		var batch := line.active_cell(&"GumMixer")
		_gum_mixer.animate(batch != null and batch.remaining > 0.0, step)
	for id: StringName in _pans:
		var pan := line.active_cell(id)
		_pans[id].animate(pan != null and pan.remaining > 0.0, step)
	for id: StringName in _tunnel_marks:
		var tunnel := line.active_cell(id)
		if tunnel == null or tunnel.cohorts.is_empty():
			continue
		var marks: Array = _tunnel_marks[id]
		var half := (layout.objects[id].size.x - 0.30) * 0.5 - 0.4
		var residence: float = tunnel.standard.residence_seconds
		for index in marks.size():
			var cohort: Array = tunnel.cohorts[floori(float(index * tunnel.cohorts.size()) / marks.size())]
			var progress := 1.0 - clampf((cohort[0] - line.erp.now) / residence, 0.0, 1.0)
			marks[index].position.x = lerpf(-half, half, progress)


## Two pallets per bay on the three storage levels of every rack: one slot per RM-WH pallet position.
func _build_raw_slots(node: Node3D, room: Layout.WarehouseRoom) -> void:
	for area in room.racks:
		for level in room.rack_levels.slice(0, 3):
			for bay in room.rack_bays:
				var width := area.size.x / room.rack_bays
				for side in 2:
					var x := area.position.x + width * (bay + 0.25 + side * 0.5)
					_raw_slots.append(Transform3D(Basis.IDENTITY, Vector3(x, level + 0.10, area.get_center().y)))
	var deck := BoxMesh.new()
	deck.size = Vector3.ONE
	deck.material = _stock.wood(Color("#a8865c"))
	var case := BoxMesh.new()
	case.size = Vector3.ONE
	case.material = _stock.instanced_board()
	var sack: Array = _stock.instanced_sack()
	_raw_decks = _rack_layer(node, deck, false)
	_raw_cases = _rack_layer(node, case, true)
	_raw_sacks = _rack_layer(node, sack[0], true, sack[1])


func _rack_layer(node: Node3D, mesh: Mesh, colored: bool, surface: Material = null) -> MultiMesh:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = colored
	multi.mesh = mesh
	multi.instance_count = _raw_slots.size() * (10 if surface != null else 1)
	multi.visible_instance_count = 0
	var view := MultiMeshInstance3D.new()
	view.multimesh = multi
	view.material_override = surface
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(view)
	return multi


## Load look per material: powders in woven sacks, the rest as wrapped cases, drums or totes.
static func _raw_load(code: String) -> Array:
	if code in ["RM-FLOUR", "RM-SUGAR", "RM-MILK", "RM-COCOA", "RM-GUMBASE", "RM-MALTITOL", "RM-XYLITOL", "RM-SORBITOL"]:
		var tint: Color = {"RM-SUGAR": Color("#f4f1ea"), "RM-MILK": Color("#eef0f2"), "RM-COCOA": Color("#b08a6e"),
			"RM-GUMBASE": Color("#d7d2c2")}.get(code, Color("#e6dcc8"))
		return ["sack", tint, 1.0]
	if code.begins_with("RM-SYRUP-") or code in ["RM-OIL", "RM-GLUCOSE", "RM-GLYCERIN"]:
		return ["case", Color("#dfe7ea"), 1.15]
	if code.begins_with("RM-AROMA-") or code.begins_with("RM-COLOR-"):
		return ["case", Color("#3f74a8"), 0.85]
	if code.begins_with("RM-COAT-"):
		return ["case", Color("#8a5c40"), 0.95]
	if code.begins_with("PK-WRAP") or code in ["PK-WALLET", "PK-POUCH-KIDS"]:
		return ["case", Color("#d4dadd"), 1.0]
	if code == "PK-BOTTLE":
		return ["case", Color("#bcd6e6"), 1.3]
	return ["case", Color("#c79b67"), 1.1]


## Fill rack slots from the ledger: each racked material takes its whole pallets in code order,
## and its last pallet stands as high as it is full.
func _refresh_raw_slots(book) -> void:
	var catalog = book.catalog
	var codes: Array = book.balances["RM-WH"].keys()
	codes.sort()
	var slot := 0
	var cases := 0
	var sacks := 0
	for code: String in codes:
		var per_pallet: float = catalog.pallet_qty(code)
		var qty: float = book.stock(code, "RM-WH")
		if per_pallet <= 0.0 or qty <= Line.EPSILON:
			continue
		var look := _raw_load(code)
		var pallets: int = catalog.positions(code, qty)
		for index in pallets:
			if slot >= _raw_slots.size():
				break
			var fill := clampf(qty / per_pallet - index, 0.0, 1.0)
			var base := _raw_slots[slot]
			slot += 1
			_raw_decks.set_instance_transform(slot - 1, base.scaled_local(Vector3(1.32, 0.14, 1.05)).translated_local(Vector3(0, 0.5, 0)))
			if look[0] == "sack":
				var layers := maxi(1, ceili(fill * 5.0 - 0.01))
				for layer in layers:
					# Interlocked layers: lengthwise along the rack depth, then across it.
					var across := layer % 2 == 1
					for side in 2:
						var offset := Vector3(0, 0, (side - 0.5) * 0.62) if across else Vector3((side - 0.5) * 0.62, 0, 0)
						var at := base.origin + offset + Vector3(0, 0.28 + layer * 0.25, 0)
						var turn := Basis.IDENTITY if across else Basis(Vector3.UP, PI * 0.5)
						_raw_sacks.set_instance_transform(sacks, Transform3D(turn.scaled(Vector3(1.0, 0.85, 1.0)), at))
						_raw_sacks.set_instance_color(sacks, look[1])
						sacks += 1
			else:
				var height: float = 1.15 * look[2] * maxf(0.2, fill)
				_raw_cases.set_instance_transform(cases, Transform3D(Basis.IDENTITY.scaled(Vector3(1.22, height, 0.98)),
					base.origin + Vector3(0, 0.14 + height * 0.5, 0)))
				_raw_cases.set_instance_color(cases, look[1])
				cases += 1
	_raw_decks.visible_instance_count = slot
	_raw_cases.visible_instance_count = cases
	_raw_sacks.visible_instance_count = sacks


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
		if _raw_decks != null:
			_refresh_raw_slots(book)
		var room: Dictionary = book.raw_warehouse()
		var blocked: bool = room.free == 0 or not room.waiting.is_empty()
		_equipment[&"RawWarehouse"].update_machine("RM  Raw materials", "%d / %d pallet positions%s" % [room.used, room.capacity,
			" · %d at dock" % room.waiting.size() if not room.waiting.is_empty() else ""], Palette.BLOCKED if blocked else Palette.SFG)
	var sfg := _equipment[&"SFGWarehouse"]
	var kg := 0.0
	for quantity in book.balances["SFG-WH"].values():
		kg += float(quantity)
	sfg.update_machine("SFG  WAFER STOCK", "%0.1f kg on hand" % kg, Palette.SFG)
	sfg.fill_slots(clampf(kg / 150.0, 0.0, 1.0))
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


func _build_belt(id: StringName, span: Array[Vector3], accent: Color) -> void:
	_station(id, "", accent, false)
	_line.roller_conveyor(self, span[0] + Vector3.UP * 0.1, span[1] + Vector3.UP * 0.1, accent, 1.0)


func _rail(start: Vector3, end: Vector3) -> void:
	_industrial.handrail(self, start, end)


func _strip(start: float, end: float, z: float, width: float, tint: Color) -> void:
	var length := end - start
	_draw.box(self, Vector3((start + end) * 0.5, 0.016, z), Vector3(length, 0.025, width), tint)


func _drive_lane(start: Vector3, end: Vector3, width: float, y: float) -> void:
	var span := end - start
	if span.is_zero_approx():
		return
	var at := (start + end) * 0.5 + Vector3.UP * y
	var stripe := _draw.box(self, at, Vector3(width, 0.018, span.length()), Color("#706e5d"))
	stripe.look_at(at + span)


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
