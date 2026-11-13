extends SceneTree
## Run with: godot --headless --path . --script res://tests/factory_scene_test.gd

const Factory = preload("res://scenes/factory.gd")
const SCENE = preload("res://scenes/factory.tscn")

var _factory: Factory
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_factory = SCENE.instantiate()
	_factory.erp_enabled = false
	root.add_child(_factory)
	_factory.set_process(false)
	await process_frame
	await process_frame

	var line := _factory.line
	var camera := _factory.camera
	var original_home := camera.position
	var inspector := _factory.hud.inspector
	_check(not line.playing, "Factory opens paused")

	_click_button("Grid")
	_check(_factory.grid_view.is_grid_visible(), "Grid toolbar button shows the overlay")
	var grid := line.layout.grid
	_check(grid.size == Vector2i(120, 100)
		and camera.is_position_in_frustum(grid.to_world(Vector2(grid.size)))
		and camera.is_position_in_frustum(grid.origin), "Home camera frames the resized factory")
	_hover_world(grid.cell_center(Vector2i(22, 5)))
	_check(_label_with_text("X 22   Z 05   Y 0.0 m") != null, "Ground hover shows grid coordinates")
	_hover_world(grid.cell_center(Vector2i(8, 22), 3.5))
	_check(_label_with_text("X 08   Z 22   Y 3.5 m") != null, "Mezzanine hover shows elevation")
	_click_label("03  OVEN 01")
	await process_frame
	_click_button("Place")
	_check(_factory._placing, "Station inspector opens placement mode")
	_key(KEY_R)
	_check(_factory._turns == 1, "R rotates the snapped preview")
	var old_cell := line.layout.objects[&"Oven"].cell
	await _pick_world(grid.cell_center(line.layout.objects[&"Coater"].cell))
	_check(_factory._placing and line.layout.objects[&"Oven"].cell == old_cell,
		"Clicking an invalid placement keeps the original station")
	var new_cell := Vector2i(16, 16)
	await _pick_world(grid.cell_center(new_cell))
	var oven := line.layout.objects[&"Oven"]
	var oven_view := _factory.floor_view.view_of(&"Oven")
	_check(not _factory._placing and oven.cell == new_cell and oven.turns == 1,
		"Valid click commits the rotated, snapped placement")
	_check(oven_view.position.is_equal_approx(oven.center(grid)) and is_equal_approx(oven_view.rotation.y, PI / 2.0),
		"Placement updates both world model and the simulation layout")
	_key(KEY_G)
	_check(not _factory.grid_view.is_grid_visible(), "G hides the grid overlay")
	_key(KEY_ESCAPE)
	await create_timer(0.45).timeout

	await _pick_world(line.floor_crew[0].position + Vector3(0, 1.1, 0))
	_check(inspector.visible and _label_with_text("Floor worker 1") != null, "3D picks a floor worker")
	await _pick_world(line.platform_crew[0].position + Vector3(0, 1.1, 0))
	_check(_label_with_text("Platform worker 1") != null, "3D picks an elevated worker")
	await _pick_world(line.forklift.position + Vector3(0, 1.1, 0))
	_check(_label_with_text("Forklift") != null, "3D picks the forklift")
	await _pick_world(line.layout.center(&"Oven") + Vector3(0, 1.75, 0))
	_check(_label_with_text("Oven 01") != null, "3D picks the oven")
	await _edit_setting(&"cook_minutes", "0.8")
	_check(is_equal_approx(line.settings[&"cook_minutes"], 0.8), "Oven duration accepts numeric input")

	_click_label("02  EXTRUDER")
	await process_frame
	var rate_field := inspector.find_child("extruder_rate", true, false) as SpinBox
	var row := rate_field.get_parent()
	var slider := row.get_child(0) as HSlider
	var slider_rect := slider.get_global_rect()
	_click(slider_rect.position + Vector2(slider_rect.size.x * 0.65, slider_rect.size.y / 2.0))
	_check(line.extruder.configured_rate > 9000.0, "Slider adjusts the selected machine")
	await _edit_setting(&"extruder_rate", "13500")
	_check(line.extruder.configured_rate == 13500.0, "Numeric machine rate edit")
	_key(KEY_ESCAPE)
	await create_timer(0.45).timeout

	_click_button("20×")
	_click_button("▶  Play")
	_check(line.playing and line.multiplier == 20, "Play and speed controls")
	for index in 100:
		_factory._process(0.05)
		if line.carts[0].site == line.Cart.Site.TRANSIT \
				and line.carts[0].position.distance_to(line.layout.port(&"Extruder", &"raw_dock")) > 3.0:
			break
	var cart := line.carts[0]
	_check(cart.site == line.Cart.Site.TRANSIT, "Live scene dispatches the full raw cart")
	var cart_view := _factory.floor_view.get_node("Raw1") as Node3D
	await _pick_world(cart_view.to_global(Vector3(0, 0.85, 0.67)))
	_check(_label_with_text("Raw cart 1") != null, "3D picks a cart during its transport task")
	_check(_label_with_text("●  In transport") != null, "Cart inspector reports live transport state")

	for index in 65:
		_factory._process(1.0)
		if line.warehouse_count() == 4:
			break
	_check(line.warehouse_count() == 4, "Live scene stores four pallets")
	_click_button("Pause")
	var tick := line.elapsed_ticks
	_factory._process(1.0)
	_check(not line.playing and line.elapsed_ticks == tick, "Pause freezes the live line")
	_click_label("07  WAREHOUSE")
	await process_frame
	_check(inspector.find_child("warehouse_capacity", true, false) == null,
		"Warehouse has no capacity input")
	_check(_label_with_text("4 / 24") != null and "4 / 24 pallets" in inspector._readout.text,
		"Dashboard and inspector show fixed capacity")
	_click_button("Dispatch one")
	_check(line.warehouse_count() == 3 and line.dispatched_pallets == 1, "Dispatch one via inspector")
	_click_button("Dispatch all")
	_check(line.warehouse_count() == 0 and line.dispatched_pallets == 4, "Dispatch all via inspector")

	_click_button("▶  Play")
	for index in 25:
		_factory._process(1.0)
		if line.warehouse_count() > 0:
			break
	_check(line.warehouse_count() > 0, "Live scene resumes deliveries after dispatch")
	_check(_find_button("Reset") == null, "No Reset button in the transport bar")
	line.reset()
	_check(line.elapsed_ticks == 0 and not line.playing and line.warehouse_count() == 0
		and line.warehouse.size() == 24, "Sandbox reset clears the run and keeps fixed capacity")
	_key(KEY_ESCAPE)
	_check(not inspector.visible, "Escape closes inspector")

	var empty := Vector2(100, 400)
	await create_timer(0.55).timeout
	var original := camera.position
	_mouse_button(MOUSE_BUTTON_WHEEL_UP, empty, true)
	await create_timer(0.35).timeout
	_check(camera.position.length() < original.length(), "Wheel zooms in")
	var distance := camera._target_distance
	_key(KEY_Z)
	_check(camera._target_distance < distance, "Z zooms in without modifiers")
	_key(KEY_X)
	_check(is_equal_approx(camera._target_distance, distance), "X zooms out without modifiers")
	_key(KEY_EQUAL)
	_check(camera._target_distance < distance, "Equals key zooms in")
	_key(KEY_MINUS)
	_check(is_equal_approx(camera._target_distance, distance), "Minus key zooms out")
	_click_button("+")
	_check(camera._target_distance < distance, "Toolbar zooms in")
	_click_button("−")
	_check(is_equal_approx(camera._target_distance, distance), "Toolbar zooms out")
	var pinch := InputEventMagnifyGesture.new()
	pinch.position = empty
	pinch.factor = 1.25
	root.push_input(pinch, true)
	_check(camera._target_distance < distance, "Spreading a trackpad pinch zooms in")
	pinch.factor = 0.8
	root.push_input(pinch, true)
	_check(is_equal_approx(camera._target_distance, distance), "Closing a trackpad pinch zooms out")
	original = camera.position
	_drag(MOUSE_BUTTON_RIGHT, empty, Vector2(75, 25))
	await create_timer(0.35).timeout
	_check(absf(camera.position.x - original.x) > 1.0, "Right drag orbits")
	original = camera.position
	_drag(MOUSE_BUTTON_MIDDLE, empty, Vector2(100, 0))
	await create_timer(0.35).timeout
	_check(camera.position.distance_to(original) > 1.0, "Middle drag pans")
	original = camera.position
	await _hold_movement_key(KEY_W, true)
	_check(camera.position.distance_to(original) > 1.0, "WASD pans the camera")
	original = camera.position
	await _hold_movement_key(KEY_RIGHT, false)
	_check(camera.position.distance_to(original) > 1.0, "Arrow keys pan the camera")
	_click_button("Home view")
	await create_timer(0.7).timeout
	_check(camera.position.distance_to(original_home) < 0.1, "Home restores camera")

	print("Chocolate factory scene interaction test, %d failures." % _failures)
	quit(1 if _failures else 0)


func _pick_world(point: Vector3) -> void:
	_click(_factory.camera.unproject_position(point))
	await physics_frame
	await process_frame
	await process_frame


func _hover_world(point: Vector3) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _factory.camera.unproject_position(point)
	root.push_input(event, true)
	_factory._update_cursor(event.position)


func _click_label(copy: String) -> void:
	var label := _label_with_text(copy)
	_check(label != null, "Dashboard card exists " + copy)
	if label != null:
		_click(label.get_global_rect().get_center())


func _edit_setting(key: StringName, value: String) -> void:
	var spin := _factory.hud.inspector.find_child(String(key), true, false) as SpinBox
	_check(spin != null, "Inspector setting exists " + String(key))
	if spin == null:
		return
	await _enter_setting(spin.get_line_edit(), value)


func _find_button(copy: String) -> Button:
	for node in _factory.find_children("*", "Button", true, false):
		if (node as Button).text == copy:
			return node
	return null


func _click_button(copy: String) -> void:
	for node in _factory.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == copy:
			_click(button.get_global_rect().get_center())
			return
	_check(false, "Button exists: " + copy)


func _enter_setting(edit: LineEdit, copy: String) -> void:
	_click(edit.get_global_rect().get_center())
	await process_frame
	_check(edit.is_editing(), "Numeric field accepts editing")
	edit.text = copy
	_key(KEY_ENTER)
	await process_frame


func _label_with_text(copy: String) -> Label:
	for node in _factory.find_children("*", "Label", true, false):
		var label := node as Label
		if label.text == copy:
			return label
	return null


func _click(point: Vector2) -> void:
	_mouse_button(MOUSE_BUTTON_LEFT, point, true)
	_mouse_button(MOUSE_BUTTON_LEFT, point, false)


func _drag(button: MouseButton, start: Vector2, movement: Vector2) -> void:
	_mouse_button(button, start, true)
	var event := InputEventMouseMotion.new()
	event.position = start + movement
	event.relative = movement
	root.push_input(event, true)
	_mouse_button(button, event.position, false)


func _mouse_button(button: MouseButton, point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.pressed = pressed
	root.push_input(event, true)


func _key(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)


func _hold_movement_key(keycode: Key, physical: bool) -> void:
	var event := InputEventKey.new()
	if physical:
		event.physical_keycode = keycode
	else:
		event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	await create_timer(0.25).timeout
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await create_timer(0.25).timeout


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + description)
