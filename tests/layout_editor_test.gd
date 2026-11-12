extends SceneTree
## Placement transactions, persistence, and the real Build Mode mouse workflow.

const Factory = preload("res://scenes/factory.gd")
const Editor = Factory.Editor
const Line = Factory.Line
const Scene = preload("res://scenes/factory.tscn")
const Save = Factory.SaveGame

var _failures := 0
var _factory: Factory


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_transactions_and_production()
	_stacked_coaters()
	_resize_saved_shift()
	await _mouse_workflow()
	print("Layout editor checks, %d failures." % _failures)
	quit(int(_failures > 0))


func _transactions_and_production() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var editor := Editor.new(line)
	var id := &"Oven02"
	var old: Line.Layout.Placement = line.layout.objects[id]
	var dock := line.layout.port(id, &"raw_dock")
	var old_machine: Line.Oven = line.ovens[id]
	var settings := line.settings.duplicate()
	var original_nodes := line.layout.objects.size()
	var planned := line.erp.create_order("FG-1001", 8, 0, 1, "PV-1001-02")
	_check(planned.error.is_empty(), "Create a route through Oven 02 before relocating it")
	var route: Dictionary = line.erp.orders[planned.id].route.duplicate(true)
	var stock := line.erp.balances.duplicate(true)

	var overlap := editor.preview(id, line.layout.objects[&"Coater"].cell, 0)
	_check("overlaps" in overlap.reason and not overlap.conflicts.is_empty(), "Overlapping cells are marked")
	_check("wall" in editor.preview(id, Vector2i(-2, 15), 0).reason, "Reject an outside footprint")
	_check("obstructed" in editor.preview(&"Oven", Vector2i(36, 21), 0).reason, "Reject an inaccessible dock")
	_check(not editor.apply(overlap.changes).is_empty() and line.layout.objects[id] == old, "Invalid changes are atomic")

	var rotated := editor.preview(&"Oven", Vector2i(16, 16), 1)
	_check(rotated.reason.is_empty(), "Quarter turn with accessible docks validates")
	_check(editor.apply(rotated.changes).is_empty() and line.layout.objects[&"Oven"].footprint().size == Vector2i(4, 5),
		"Quarter turn swaps rectangular footprint dimensions")
	_check(editor.undo().is_empty() and line.layout.objects[&"Oven"].turns == 0, "Undo restores orientation")
	_check(editor.redo().is_empty() and line.layout.objects[&"Oven"].turns == 1, "Redo restores quarter turn")
	_check(editor.undo().is_empty(), "Restore original Oven 01 before alternate-route test")

	var moved := editor.preview(id, Vector2i(26, 16), 0)
	_check(moved.reason.is_empty() and editor.apply(moved.changes).is_empty(), "Move Oven 02 by a cell")
	_check(line.layout.port(id, &"raw_dock") != dock and line.layout.objects.size() == original_nodes,
		"Dock follows the move without duplicating equipment")
	_check(line.ovens[id] == old_machine and line.settings == settings and line.erp.orders[planned.id].route == route,
		"Machine instance, settings, and existing routing stay intact")
	_check(line.erp.balances == stock, "Moving equipment preserves ERP inventory")
	_check(editor.can_undo() and not editor.can_redo(), "New edit clears redo history")

	var path := "user://factory-layout-test-%d.json" % OS.get_process_id()
	_check(editor.save(path).is_empty() and not editor.dirty(), "Save independent placement file")
	var payload: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var saved_pose: Array = payload.placements["Oven02"]
	_check(saved_pose[0] == 26 and saved_pose[1] == 16 and saved_pose[2] == 0 and not payload.has("materials"),
		"Layout file contains stable IDs and poses")
	var resumed := Line.new()
	resumed.enable_erp(false)
	var new_editor := Editor.new(resumed)
	_check(new_editor.load_layout(path).is_empty(), "Load the saved layout into a fresh simulation")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(resumed.layout.objects[id].cell == Vector2i(26, 16), "Oven 02 persisted at the new cell")
	_check(new_editor.reset_default().is_empty() and resumed.layout.objects[id].cell == old.cell, "Restore defaults")
	_check(new_editor.undo().is_empty() and resumed.layout.objects[id].cell == Vector2i(26, 16), "Undo default reset")
	var saved_shift := Save.restore(Save.snapshot(resumed))
	_check(saved_shift.error.is_empty() and saved_shift.line.layout.objects[id].cell == Vector2i(26, 16),
		"Operational snapshots also retain confirmed placements")

	var order := resumed.erp.create_order("FG-1001", 8, 0, 1, "PV-1001-02")
	_check(order.error.is_empty() and resumed.erp.release(order.id).is_empty(), "Release through the relocated oven")
	resumed.set_playing(true)
	var delivered := false
	for tick in 3600:
		resumed.advance(Line.STEP_SECONDS)
		for job in resumed.floor_assignments.values():
			if job.kind == Line.JobKind.MOVE_CART and job.site == Line.Cart.Site.OVEN_RAW:
				delivered = delivered or (job.run == order.id and job.point == resumed.layout.port(id, &"raw_dock") and job.point != dock)
		if resumed.erp.orders[order.id].status == "Completed":
			break
		if tick == 50:
			resumed.set_playing(false)
			var mass := resumed.material_on_site()
			var disallowed := new_editor.apply(resumed.layout.proposal(id, old.cell, 0))
			_check("using the line" in disallowed and is_equal_approx(resumed.material_on_site(), mass),
				"Paused work in progress locks editing and retains material")
			resumed.set_playing(true)
	_check(delivered and resumed.erp.orders[order.id].status == "Completed" and is_equal_approx(resumed.warehouse_mass(), 40.0),
		"Workers deliver to the saved Oven 02 position and the order completes")
	resumed.advance(90.0)
	resumed.set_playing(false)
	_check("warehouse stock" in resumed.layout_edit_problem([&"Warehouse"]), "Occupied warehouse cannot move")
	_check(resumed.layout_edit_problem([&"Extruder"]).is_empty(), "Crew parks the empty extruder cart between orders")

	var coupled := Editor.new(line)
	var hopper_before := line.layout.center(&"Hopper")
	var linked := coupled.preview(&"Extruder", Vector2i(5, 16), 0)
	_check(linked.reason.is_empty() and coupled.apply(linked.changes).is_empty(), "Move the extruder and hopper together")
	_check(line.layout.center(&"Hopper") != hopper_before
		and line.layout.port(&"Extruder", &"feed").is_equal_approx(line.layout.port(&"Hopper", &"outlet")),
		"Linked ingredient assembly keeps its ports aligned")
	var packing := coupled.preview(&"Packer", Vector2i(60, 16), 0)
	_check(packing.reason.is_empty() and coupled.apply(packing.changes).is_empty()
		and line.layout.objects[&"PackagingWIP"].cell.x == 58 and line.layout.objects[&"Palletizer"].cell.x == 66,
		"Packaging group moves with WIP and palletizing")


func _stacked_coaters() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var editor := Editor.new(line)
	var layout := line.layout
	var front: Line.Layout.Placement = layout.objects[&"Coater"]
	var rear := Vector2i(front.cell.x, front.cell.y + 8)
	var placement := editor.preview(&"Coater02", rear, 0)
	_check(placement.reason.is_empty() and editor.apply(placement.changes).is_empty(),
		"Coater 02 can sit behind Coater 01 at the same X coordinate")
	if layout.objects[&"Coater02"].cell != rear:
		return
	var start := layout.port(&"Oven02", &"cooked_dock")
	var target := layout.port(&"Coater02", &"cooked_dock")
	var route := layout.route(start, target, Line.Layout.CART_LANE)
	var obstacles := layout._obstacles(layout.objects)
	obstacles.merge(layout._dock_areas(layout._dock_points(layout.objects)))
	_check(route.size() > 3 and route.back() == target
		and layout._path_clear(start, route, 0.34, obstacles, [start, target]),
		"Rear coater has a safe cart detour around the front station's bays")
	_check(editor.undo().is_empty() and editor.redo().is_empty()
		and layout.route(start, target, Line.Layout.CART_LANE) == route,
		"Undo and redo rebuild the dock paths")
	var first := line.erp.create_order("FG-1001", 8, 0, 1, "PV-1001-01")
	var second := line.erp.create_order("FG-1001", 8, 0, 2, "PV-1001-02")
	if not first.error.is_empty() or not second.error.is_empty() \
			or not line.erp.release(first.id).is_empty() or not line.erp.release(second.id).is_empty():
		_check(false, "Release both stacked coater routes")
		return
	line.set_playing(true)
	var delivered := false
	for tick in 6000:
		line.advance(Line.STEP_SECONDS)
		for job in line.floor_assignments.values():
			if job.run == second.id and job.kind == Line.JobKind.MOVE_CART and job.site == Line.Cart.Site.COATER:
				delivered = delivered or job.point == target
		if line.erp.orders[second.id].status == "Completed":
			break
	_check(delivered and line.erp.orders[first.id].status == "Completed"
		and line.erp.orders[second.id].status == "Completed" and is_equal_approx(line.warehouse_mass(), 80.0),
		"Workers deliver to both stacked coaters and both orders complete")


func _resize_saved_shift() -> void:
	var former := Line.Layout.new().snapshot()
	former.size = [128, 40]
	# Saves from the 128 × 40 hall predate the gum line; the loader adds it on its own.
	former.objects = former.objects.filter(func(row: Dictionary) -> bool:
		return row.id not in ["GumMixer", "GumSheeter", "FruitFormer", "GumConditioner", "GumPan01", "GumPan02",
			"GumPan03", "WalletPacker", "BottleFiller"])
	for room in former.objects:
		if room.id == "Warehouse":
			room.cell = [117, 14]
			room.size = [10, 8]
			room.height = 1.5
		elif room.id == "RawWarehouse":
			room.cell = [2, 3]
			room.size = [16, 4]
			room.height = 2.2
	var layout := Line.Layout.new(Line.Layout.PREVIOUS_SIZE, "", former)
	var previous := Line.new(layout)
	previous.enable_erp(false)
	_check(previous.validation_error.is_empty(), "Validate the legacy room fixture")
	if not previous.validation_error.is_empty():
		return
	var path := "user://factory-layout-resize-test-%d.json" % OS.get_process_id()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": 1, "size": [128, 40], "placements": {"Warehouse": [117, 14, 0]}}))
	file.close()
	var fresh := Line.new()
	var default_cell := fresh.layout.objects[&"Warehouse"].cell
	_check(Editor.new(fresh).load_layout(path).is_empty() and fresh.layout.objects[&"Warehouse"].cell == default_cell,
		"The prior layout file keeps the expanded warehouse at its new location")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var order := previous.erp.create_order("FG-1001", 8, 0, 1, "PV-1001-02")
	_check(order.error.is_empty() and previous.erp.release(order.id).is_empty(), "Release an order in the former hall")
	previous.set_playing(true)
	for tick in 3600:
		previous.advance(Line.STEP_SECONDS)
		if previous._lift_phase == Line.LiftPhase.TO_STORAGE:
			break
	_check(previous.lift_load != null, "Capture a forklift with a pallet in transit")
	var snapshot := Save.snapshot(previous)
	snapshot.version = 7
	# The fixture hall grew when the newer gum line was added; the save still records the old size.
	snapshot.size = Line.Layout.PREVIOUS_SIZE
	var saved := Save.restore(snapshot)
	_check(saved.error.is_empty() and saved.get("refitted", false), "Restore the previous shift in the resized hall")
	if not saved.error.is_empty():
		return
	var resized: Line = saved.line
	_check(resized.layout.grid.size == Vector2i(120, 100)
		and resized.layout.objects[&"Packer02"].cell == layout.objects[&"Packer02"].cell,
		"Resize keeps the Packing 02 dock in place")
	_check(resized.layout.objects[&"Warehouse"].cell == default_cell
		and resized.layout.objects[&"RawWarehouse"].cell == fresh.layout.objects[&"RawWarehouse"].cell,
		"Restoring the shift relocates both warehouse rooms")
	_check(resized.erp.balances == previous.erp.balances and resized.erp.movements == previous.erp.movements
		and is_equal_approx(resized.material_on_site(), previous.material_on_site()),
		"Resize preserves material and the transaction history")
	resized.set_playing(true)
	resized.advance(600.0)
	_check(resized.erp.orders[order.id].status == "Completed" and is_equal_approx(resized.warehouse_mass(), 40.0),
		"The resumed forklift delivers the pallet to the relocated warehouse")
	var eight_slots := Save.snapshot(resized)
	eight_slots.version = 8
	eight_slots.settings[&"warehouse_capacity"] = 4.0
	eight_slots.warehouse.resize(8)
	var upgraded := Save.restore(eight_slots)
	_check(upgraded.error.is_empty() and upgraded.line.warehouse.size() == 24
		and not upgraded.line.settings.has(&"warehouse_capacity")
		and Save.snapshot(upgraded.line).warehouse.slice(0, 8) == eight_slots.warehouse,
		"Eight-slot saves keep their pallets and gain sixteen empty positions")
	var staged := previous.erp.stock("RM-FLOUR", "RM-STAGE")
	_check(previous.erp.manual_transfer("RM-FLOUR", 2, "RM-WH", "RM-STAGE", "Warehouse migration test").is_empty(),
		"Queue an ingredient shipment from the former warehouse")
	for tick in 1800:
		previous.advance(Line.STEP_SECONDS)
		if previous.erp.shipment.get("manual", false) and previous.erp.shipment.phase == 1:
			break
	_check(is_equal_approx(previous.erp.stock("RM-FLOUR", "TRANSIT"), 2.0), "Capture the ingredient shipment in transit")
	snapshot = Save.snapshot(previous)
	snapshot.version = 7
	saved = Save.restore(snapshot)
	_check(saved.error.is_empty(), "Restore the shipment with the relocated raw-material dock")
	if not saved.error.is_empty():
		return
	resized = saved.line
	resized.set_playing(true)
	resized.advance(300.0)
	_check(is_zero_approx(resized.erp.stock("RM-FLOUR", "TRANSIT"))
		and is_equal_approx(resized.erp.stock("RM-FLOUR", "RM-STAGE"), staged + 2.0),
		"The relocated shipment posts exactly once")


func _mouse_workflow() -> void:
	_factory = Scene.instantiate()
	_factory.resume_saved = false
	_factory.explicit_planning = false
	root.add_child(_factory)
	await process_frame
	_factory.line.set_playing(true)
	_key(KEY_B)
	await create_timer(0.45).timeout
	_check(_factory._build_mode and not _factory.line.playing and _factory.grid_view.is_grid_visible(),
		"B enters Build Mode, pauses, and shows the grid")
	var id := &"Oven02"
	var grid := _factory.line.layout.grid
	var place: Line.Layout.Placement = _factory.line.layout.objects[id]
	var start := _factory.camera.unproject_position(place.center(grid) + Vector3.UP * 1.8)
	_button(start, true)
	await physics_frame
	await process_frame
	_check(_factory._selected == id and _factory._drag_armed, "Mouse selects Oven 02 and arms drag")
	if _factory._selected != id:
		return
	var anchor := Vector2i(26, 16)
	var center := Vector2(anchor) + Vector2(place.footprint().size) * 0.5
	var target := _factory.camera.unproject_position(grid.to_world(center + _factory._grab_offset))
	_motion(target, start)
	await process_frame
	_check(_factory._dragging and _factory._preview_cell == anchor and _factory._preview_reason.is_empty(),
		"Dragged preview snaps to the valid grid cell")
	_button(target, false)
	await physics_frame
	await process_frame
	_check(not _factory._placing and _factory.line.layout.objects[id].cell == anchor, "Release commits the drag")
	_check(_factory.floor_view.find_children("Oven02", "", true, false).size() == 1, "Confirmed move has one world model")
	_key(KEY_Z, true)
	_check(_factory.line.layout.objects[id].cell == place.cell, "Cmd+Z undoes the drag")
	_key(KEY_Z, true, true)
	_check(_factory.line.layout.objects[id].cell == anchor, "Cmd+Shift+Z redoes the drag")

	var current: Line.Layout.Placement = _factory.line.layout.objects[id]
	start = _factory.camera.unproject_position(current.center(grid) + Vector3.UP * 1.8)
	_button(start, true)
	await physics_frame
	await process_frame
	var blocked := Vector2(_factory.line.layout.objects[&"Coater"].cell) + Vector2(current.size) * 0.5
	target = _factory.camera.unproject_position(grid.to_world(blocked + _factory._grab_offset))
	_motion(target, start)
	await process_frame
	_check(_factory._placing and not _factory._preview_reason.is_empty(), "An invalid drag shows the reason")
	_key(KEY_R, false, true)
	_check(_factory._turns == 3, "Shift+R rotates counterclockwise")
	_key(KEY_ESCAPE)
	_button(target, false)
	await physics_frame
	await process_frame
	_check(_factory._build_mode and not _factory._placing and _factory.line.layout.objects[id].cell == anchor,
		"Escape cancels a drag without leaving Build Mode")
	_key(KEY_B)
	_check(not _factory._build_mode and not _factory.grid_view.is_grid_visible(), "Exit restores the previous grid setting")


func _key(code: Key, command: bool = false, shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.meta_pressed = command and OS.has_feature("macos")
	event.ctrl_pressed = command and not OS.has_feature("macos")
	event.shift_pressed = shift
	root.push_input(event, true)


func _button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	root.push_input(event, true)


func _motion(point: Vector2, previous: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = point - previous
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event, true)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
