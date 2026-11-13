extends SceneTree
## The aisle floor plan, its lanes as layout data, and the original plan kept for older saves.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Editor = preload("res://layout/layout_editor.gd")
const Save = preload("res://erp/save_game.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_new_plan()
	_flow_distances()
	_rack_levels()
	_freight_lift()
	_original_plan()
	_persistence()
	_layout_files()
	print("Floor plan: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _length(path: Array[Vector3], start: Vector3 = Vector3.INF) -> float:
	var total := 0.0
	var previous := start
	for point in path:
		if previous != Vector3.INF:
			total += previous.distance_to(point)
		previous = point
	return total


func _new_plan() -> void:
	var plan := Layout.new()
	_check(plan.validate().is_empty(), "The default plan validates: " + plan.validate())
	_check(plan.grid.size == Vector2i(120, 75) and plan.plan_id == "aisle-v1" and not plan.legacy, "Default hall is 120 × 75 m on the aisle plan")
	_check(is_equal_approx(plan.cart_lane, 17.2) and is_equal_approx(plan.walk_lane, 16.75) and is_equal_approx(plan.supply_lane, 17.0)
		and is_equal_approx(plan.lift_lane, 17.0), "Lanes come from the layout file")
	var south_row := [&"CreamMixer", &"Spreader", &"Cutter", &"GumMixer", &"GumSheeter", &"GumConditioner", &"GumPan01", &"SFGWarehouse"]
	var north_row := [&"Oven", &"Oven02", &"Coater", &"Coater02", &"CoolingTunnel", &"Packer02", &"WalletPacker", &"BottleFiller", &"Extruder"]
	for id: StringName in south_row:
		_check(plan.objects[id].turns == 2 and plan.objects[id].footprint().end.y <= 14, "%s faces the aisle from the south side" % id)
	for id: StringName in north_row:
		_check(plan.objects[id].turns == 0 and plan.objects[id].cell.y >= 20, "%s faces the aisle from the north side" % id)
	# Every cart dock sits inside the production aisle's six metres between the two rows.
	var docks: Array[Vector3] = plan._dock_points(plan.objects)
	var outside := docks.filter(func(point: Vector3) -> bool:
		var y := plan.grid.coordinates(point).y
		return y < 14.0 or y > 29.0)
	_check(outside.is_empty(), "All cart docks and cart parking bays are around the aisle (%d elsewhere)" % outside.size())
	# Material flows west to east: each cell's input dock is west of its output dock, on either side of the aisle.
	for id: StringName in [&"Spreader", &"Cutter", &"GumSheeter", &"GumConditioner", &"Packer02", &"CoolingTunnel"]:
		var item: Layout.Placement = plan.objects[id]
		_check(plan.grid.coordinates(item.port(plan.grid, &"input_dock")).x < plan.grid.coordinates(item.port(plan.grid, &"output_dock")).x,
			"%s takes material in on its west side" % id)
	var packer: Layout.Placement = plan.objects[&"Packer"]
	var pallets: Layout.Placement = plan.objects[&"Palletizer"]
	_check(pallets.cell.y == 20 and plan.objects[&"PackagingWIP"].cell.y == 21 and packer.cell.y == 24,
		"The packing block keeps its pallet bays on the aisle and the packer behind them")


func _flow_distances() -> void:
	var plan := Layout.new()
	var door := plan.supply_point("RM-WH")
	var stage := plan.supply_point("RM-STAGE")
	var route := plan.supply_route(door, stage)
	_check(not route.is_empty() and _length(route, door) < 55.0,
		"The shuttle reaches the ingredient mezzanine in %.0f m (it was about 90)" % _length(route, door))
	var approach := plan.pallet_approach(0)
	var slot_path := plan.lift_to_slot(approach, 0)
	_check(slot_path.size() > 2 and _length(slot_path, approach) < 110.0, "A pallet reaches its warehouse slot in %.0f m" % _length(slot_path, approach))
	var cooling := plan.port(&"CoolingTunnel", &"output_dock")
	var wip := plan.port(&"PackagingWIP", &"coated_dock")
	var haul := plan.route(cooling, wip, plan.cart_lane)
	_check(not haul.is_empty() and _length(haul, cooling) < 25.0, "A cart from the cooling tunnel to packaging WIP drives %.0f m" % _length(haul, cooling))


func _rack_levels() -> void:
	var plan := Layout.new()
	_check(plan.warehouse_slot_count() == 96 and plan.warehouse_position_count() == 24, "The FG warehouse holds 96 pallets on 24 positions, four levels")
	_check(plan.warehouse_slot(5).is_equal_approx(plan.warehouse_slot(5 + 24 * 3)) and plan.warehouse_approach(5).is_equal_approx(plan.warehouse_approach(53)),
		"Upper levels share the ground position and the forklift approach")
	_check(plan.warehouse_height(5) == 0.0 and is_equal_approx(plan.warehouse_height(24), 1.95) and is_equal_approx(plan.warehouse_height(95), 5.82),
		"Levels sit on the rack beams (0, 1.95, 3.90, 5.82 m)")
	var room := Layout.WarehouseRoom.new(plan.objects[&"Warehouse"].size, true)
	_check(room.rack_levels.size() == 3 and is_equal_approx(room.rack_levels[2], plan.warehouse_height(95)), "The drawn rack beams match the storage heights")
	var line := Line.new()
	line.enable_erp(false)
	_check(line.warehouse.size() == 96 and line.warehouse.find(null) == 0, "A new line fills the floor level first")
	_check(is_equal_approx(line.storage_handling_seconds(0), Line.LIFT_HANDLING_SECONDS)
		and is_equal_approx(line.storage_handling_seconds(95), Line.LIFT_HANDLING_SECONDS + 3.0 * Line.LIFT_LEVEL_SECONDS), "Each level adds mast time to storing a pallet")
	var original := Layout.new(Vector2i.ZERO, "", {}, true)
	_check(original.warehouse_slot_count() == 96 and original.validate().is_empty(), "The original plan has the four-level racks too")


func _freight_lift() -> void:
	var plan := Layout.new()
	var door := plan.supply_point("RM-WH")
	var stage := plan.supply_point("RM-STAGE")
	_check(plan.has_freight_lift() and stage.y > 3.0 and is_equal_approx(plan.freight_lift_base().y, 0.0), "The aisle plan has a freight lift to the mezzanine")
	for route: Array[Vector3] in [plan.supply_route(door, stage), plan.supply_route(stage, door)]:
		var previous: Vector3 = door if route.back() == stage else stage
		var climbs := 0
		var diagonal := false
		for point in route:
			var step := point - previous
			if absf(step.y) > 0.01:
				climbs += 1
				diagonal = diagonal or Vector2(step.x, step.z).length() > 0.01
			previous = point
		_check(climbs == 1 and not diagonal, "A trip changes level once, straight up or down the lift shaft")
	var handler := Line.Operator.new(&"Handler", "Handler", plan.freight_lift_base())
	handler.travel(plan.supply_route(plan.freight_lift_base(), stage), Line.Operator.State.MOVING_PALLET_JACK, "Lift", "Deck")
	var seconds := 0.0
	while not handler.finished() and seconds < 60.0:
		handler.advance(0.25, 2.4)
		seconds += 0.25
	_check(handler.position.is_equal_approx(stage) and seconds > plan.freight_lift_top().y / Line.Operator.LIFT_SPEED - 0.5,
		"The cage rises at lift speed (%.1f s for %.1f m)" % [seconds, stage.y])
	var original := Layout.new(Vector2i.ZERO, "", {}, true)
	_check(not original.has_freight_lift(), "The original plan has no freight lift")


func _original_plan() -> void:
	var original := Layout.new(Vector2i.ZERO, "", {}, true)
	_check(original.validate().is_empty() and original.legacy and original.plan_id == "legacy", "The original plan still validates as the legacy plan")
	_check(original.grid.size == Vector2i(120, 100) and is_equal_approx(original.cart_lane, Layout.CART_LANE)
		and is_equal_approx(original.supply_lane, Layout.SUPPLY_LANE) and original.cart_aisle_end() == 97, "It keeps its size and constant lanes")
	_check(original.snapshot().has("lanes") == false and original.lanes_snapshot().is_empty(), "A legacy layout saves without lane data")
	var shipped: Layout = Layout.new()
	_check(original.objects[&"Oven"].cell != shipped.objects[&"Oven"].cell, "The two plans differ")


func _persistence() -> void:
	var plan := Layout.new()
	var data := plan.snapshot()
	_check(data.lanes.cart == 17.2 and data.plan == "aisle-v1" and data.size == [120, 75], "A snapshot carries lanes, plan and size")
	var again := Layout.new(Vector2i.ZERO, "", data)
	_check(again.error.is_empty() and not again.legacy and again.plan_id == "aisle-v1" and is_equal_approx(again.cart_lane, 17.2)
		and again.validate().is_empty(), "A snapshot restores to the same plan")
	var legacy_data := Layout.new(Vector2i.ZERO, "", {}, true).snapshot()
	var old := Layout.new(Vector2i.ZERO, "", legacy_data)
	_check(old.error.is_empty() and old.legacy and is_equal_approx(old.cart_lane, Layout.CART_LANE) and old.validate().is_empty(),
		"A save without lanes restores as the original plan")
	var line := Line.new(Layout.new(Vector2i.ZERO, "", {}, true))
	line.enable_erp(false)
	var restored := Save.restore(Save.snapshot(line))
	_check(restored.error.is_empty() and restored.line.layout.legacy and restored.line.layout.grid.size == Vector2i(120, 100),
		"A saved simulation on the original plan resumes on it")
	var modern := Line.new()
	modern.enable_erp(false)
	var modern_restored := Save.restore(Save.snapshot(modern))
	_check(modern_restored.error.is_empty() and not modern_restored.line.layout.legacy and modern_restored.line.layout.plan_id == "aisle-v1",
		"A saved simulation on the aisle plan resumes on it")
	var broken := plan.snapshot()
	broken.lanes.cart = "north"
	_check(not Layout.new(Vector2i.ZERO, "", broken).error.is_empty(), "A lane that is not a number is rejected")
	var editor := Editor.new(Line.new(Layout.new(Vector2i.ZERO, "", {}, true)))
	_check(editor.reset_default().is_empty() and editor.line.layout.legacy, "Default on an original-plan instance restores the original positions")


func _layout_files() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var editor := Editor.new(line)
	var path := "user://floor-plan-test-%d.json" % OS.get_process_id()
	_check(editor.save(path).is_empty(), "Save the layout file")
	var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(payload.get("plan") == "aisle-v1", "The layout file names its floor plan")
	_check(Editor.new(Line.new()).load_layout(path).is_empty(), "It loads on the same plan")
	payload.erase("plan")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload))
	file.close()
	var message := Editor.new(Line.new()).load_layout(path)
	_check("different floor plan" in message, "A file from the original plan is not applied: " + message)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
