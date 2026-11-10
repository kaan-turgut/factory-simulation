extends Node
## Connects player commands and the fixed-step line to the independent views.

const Line = preload("res://simulation/production_line.gd")
const Floor = preload("res://world/factory_floor.gd")
const Orbit = preload("res://world/orbit_camera.gd")
const HUD = preload("res://ui/factory_hud.gd")
const ERPWindow = preload("res://ui/erp_window.gd")
const SaveGame = preload("res://erp/save_game.gd")
const GridView = preload("res://world/grid_view.gd")
const Layout = Line.Layout
const Editor = preload("res://layout/layout_editor.gd")
const NO_CELL := Vector2i(-2147483648, -2147483648)

@export var building_cells := Vector2i.ZERO
@export var erp_enabled := true
@export var resume_saved := true

var terminal: ERPWindow

var line: Line
var grid_view: GridView
var editor: Editor
var _build_mode := false
var _drag_armed := false
var _dragging := false
var _press_point := Vector2.INF
var _pointer := Vector2.INF
var _release_point := Vector2.INF
var _release_over_ui := false
var _grab_offset := Vector2.ZERO
var _cursor_screen := Vector2.INF
var _cursor_camera := Transform3D.IDENTITY
var _cursor_offset := 0.0
var _pending_pick := false
var _pick_origin := Vector3.ZERO
var _pick_direction := Vector3.ZERO
var _selected: StringName = &""
var _show_grid := false
var _placing := false
var _turns := 0
var _preview_cell := NO_CELL
var _preview_reason := ""
var _highlighted_order := ""
var _save_load_error := ""
var _layout_refitted := false
@onready var floor_view: Floor = $Floor
@onready var camera: Orbit = $OrbitCamera
@onready var hud: HUD = $HUD


func _ready() -> void:
	var fresh_shift := "--fresh-shift" in OS.get_cmdline_user_args()
	if fresh_shift:
		resume_saved = false
	line = Line.new(Layout.new(building_cells))
	if erp_enabled:
		line.enable_erp()
		if resume_saved and FileAccess.file_exists(SaveGame.PATH):
			var saved := SaveGame.load_line()
			if saved.error.is_empty():
				line = saved.line
				_layout_refitted = saved.get("refitted", false)
			else:
				_save_load_error = saved.error
				resume_saved = false
				push_warning(saved.error)
	var layout := line.layout
	var error := line.validation_error if erp_enabled or not line.validation_error.is_empty() else layout.validate()
	if not error.is_empty():
		push_error("Invalid factory master data. " + error)
		hud.set_hint("Factory master data error. " + error)
		set_process(false)
		set_physics_process(false)
		set_process_unhandled_key_input(false)
		return
	editor = Editor.new(line)
	var layout_note := ""
	if (resume_saved or fresh_shift) and FileAccess.file_exists(Editor.PATH):
		layout_note = editor.load_layout(Editor.PATH, true)
	_rebuild_world()
	if erp_enabled:
		terminal = ERPWindow.new()
		add_child(terminal)
		terminal.bind(line)
		terminal.play_requested.connect(_set_playing)
		terminal.closed.connect(_resume_camera)
		terminal.save_requested.connect(_save_shift)
		terminal.load_requested.connect(_load_shift)
		terminal.locate_requested.connect(_locate_stock)
		terminal.route_requested.connect(_highlight_order)
		hud.erp_requested.connect(_open_erp)
		if _save_load_error.is_empty():
			hud.set_hint("Saved shift moved to the larger factory. Cart jobs resume when you press Play." if _layout_refitted
				else "Open ERP to create and release a production order.")
		else:
			hud.set_hint("Existing save preserved. " + _save_load_error)
			terminal.notice("Existing save preserved. " + _save_load_error)
		if resume_saved:
			get_tree().auto_accept_quit = false
	hud.enable_erp(erp_enabled)
	camera.floor_clicked.connect(_pick)
	hud.selection_requested.connect(_select)
	hud.play_requested.connect(_set_playing.bind(true))
	hud.pause_requested.connect(_set_playing.bind(false))
	hud.reset_requested.connect(_reset)
	hud.speed_requested.connect(_set_speed)
	hud.setting_requested.connect(_set_setting)
	hud.dispatch_requested.connect(_dispatch)
	hud.home_requested.connect(camera.home)
	hud.grid_requested.connect(_toggle_grid)
	hud.placement_requested.connect(_toggle_placement)
	hud.build_requested.connect(_toggle_build)
	hud.build_panel.action_requested.connect(_build_action)
	get_window().focus_exited.connect(_cancel_drag_on_focus_loss)
	if not layout_note.is_empty() and _save_load_error.is_empty():
		hud.set_hint("Saved layout pending · " + layout_note)
	_refresh()
	floor_view.animate(line, 0.0)


func _process(delta: float) -> void:
	var previous_tick := line.elapsed_ticks
	line.advance(delta)
	if line.elapsed_ticks != previous_tick:
		_refresh()
	if line.playing:
		floor_view.animate(line, delta)
		if _selected != &"" and not line.layout.objects.has(_selected) and not Layout.LINKS.has(_selected):
			_update_selection_grid()
	if terminal == null or not terminal.is_open():
		var point := _pointer if _dragging else get_viewport().get_mouse_position()
		var pose := camera.global_transform
		if point != _cursor_screen or pose != _cursor_camera or camera.h_offset != _cursor_offset:
			_cursor_screen = point
			_cursor_camera = pose
			_cursor_offset = camera.h_offset
			_update_cursor(point)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if terminal != null and terminal.is_open():
		if event.keycode == KEY_ESCAPE:
			terminal.close()
		return
	if _build_mode and event.is_command_or_control_pressed() and event.keycode == KEY_Z:
		_build_action("redo" if event.shift_pressed else "undo")
		get_viewport().set_input_as_handled()
		return
	match event.keycode:
		KEY_B:
			_toggle_build()
		KEY_E:
			_open_erp()
		KEY_SPACE:
			_set_playing(not line.playing)
		KEY_ESCAPE:
			if _placing:
				_toggle_placement()
			elif _build_mode:
				_set_build_mode(false)
			else:
				_select(&"")
		KEY_HOME:
			camera.home()
		KEY_G:
			_toggle_grid(not _show_grid)
		KEY_R:
			_rotate_placement(-1 if event.shift_pressed else 1)


func _input(event: InputEvent) -> void:
	if not _build_mode or _press_point == Vector2.INF:
		return
	if event is InputEventMouseMotion:
		_pointer = event.position
		_start_drag_if_needed()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_pointer = event.position
		_release_point = event.position
		_release_over_ui = get_viewport().gui_get_hovered_control() != null


func _pick(point: Vector2) -> void:
	# Capture the ray before camera easing changes the meaning of the click.
	_pick_origin = camera.project_ray_origin(point)
	_pick_direction = camera.project_ray_normal(point)
	_pending_pick = true
	if _build_mode:
		_press_point = point
		_pointer = point


func _physics_process(_delta: float) -> void:
	if _pending_pick:
		_pending_pick = false
		if _placing:
			_commit_at(_pick_origin, _pick_direction)
		else:
			_select(floor_view.equipment_at(_pick_origin, _pick_origin + _pick_direction * camera.far))
			if _build_mode:
				_arm_drag()
				_start_drag_if_needed()
	if _release_point != Vector2.INF:
		if _dragging:
			var cell := _placement_cell(camera.project_ray_origin(_release_point), camera.project_ray_normal(_release_point))
			if _release_over_ui or cell == NO_CELL or not _commit_cell(cell):
				_end_placement()
		_clear_drag()


func _select(id: StringName) -> void:
	if _placing:
		_end_placement()
	_selected = id
	if _build_mode:
		hud.inspector.hide()
		if line.layout.definition(id) == null:
			_selected = &""
	else:
		hud.inspector.select(id, line)
		if not hud.inspector.visible:
			_selected = &""
	floor_view.select(_selected)
	camera.set_inspector_open(_build_mode or _selected != &"")
	_update_selection_grid()


func _toggle_grid(enabled: bool) -> void:
	_show_grid = enabled
	hud.set_grid_button(enabled)
	grid_view.set_grid_visible(enabled or _placing or _build_mode)


func _toggle_placement() -> void:
	if _placing:
		_end_placement()
		hud.set_hint("Placement cancelled.")
	else:
		_begin_placement()


func _end_placement() -> void:
	_placing = false
	_preview_cell = NO_CELL
	_clear_drag()
	grid_view.clear_preview()
	grid_view.set_grid_visible(_show_grid or _build_mode)
	hud.set_cursor("")
	_cursor_screen = Vector2.INF
	_update_selection_grid()


func _placement_cell(origin: Vector3, direction: Vector3) -> Vector2i:
	var item: Layout.Placement = line.layout.objects[_selected]
	var hit := grid_view.project_ray(origin, direction, item.elevation, not _build_mode)
	if hit == Vector3.INF:
		return NO_CELL
	var grid := line.layout.grid
	if not _dragging:
		return grid.cell_at(hit)
	var size := item.size if _turns % 2 == 0 else Vector2i(item.size.y, item.size.x)
	var offset := _grab_offset.rotated((_turns - item.turns) * PI * 0.5)
	return Vector2i((grid.coordinates(hit) - offset - Vector2(size) * 0.5).round())


func _commit_at(origin: Vector3, direction: Vector3) -> void:
	var cell := _placement_cell(origin, direction)
	if cell != NO_CELL:
		_commit_cell(cell)


func _toggle_build() -> void:
	_set_build_mode(not _build_mode)


func _set_build_mode(enabled: bool) -> void:
	if _placing:
		_end_placement()
	_build_mode = enabled
	_clear_drag()
	_pending_pick = false
	if enabled:
		line.set_playing(false)
		editor.invalidate_preview()
	hud.set_build_active(enabled)
	grid_view.set_grid_visible(_show_grid or enabled)
	grid_view.show_build_areas(enabled, line.layout.objects.values(), line.layout.reserved)
	_select(_selected)
	_cursor_screen = Vector2.INF
	if enabled:
		hud.set_hint("Build Mode · Shift paused · Select or drag a station")
	else:
		hud.set_hint("Shift paused · Use Save Layout to reuse your edits." if editor.dirty()
			else "Shift paused. Press Play to resume.")
	_refresh()


func _build_action(action: String) -> void:
	if not _build_mode:
		return
	match action:
		"move":
			_toggle_placement()
		"rotate":
			_rotate_placement(1)
		"cancel":
			_end_placement()
			hud.set_hint("Placement cancelled.")
		"save":
			var reason := editor.save()
			hud.set_hint("Layout saved to factory_layout.json." if reason.is_empty() else reason)
			_update_build_panel()
		"undo", "redo", "load", "default":
			if _placing:
				_end_placement()
			var reason := ""
			match action:
				"undo": reason = editor.undo()
				"redo": reason = editor.redo()
				"load": reason = editor.load_layout()
				"default": reason = editor.reset_default()
			if reason.is_empty():
				_refresh_layout_views()
			hud.set_hint("Layout updated." if reason.is_empty() else reason)
			_update_build_panel()


func _update_build_panel() -> void:
	if not _build_mode:
		return
	var panel = hud.build_panel
	panel.update_history(editor.dirty(), editor.can_undo(), editor.can_redo())
	var item := line.layout.definition(_selected)
	if item == null:
		panel.update_selection("Select equipment", "Click a station, then drag or use Move.",
			line.layout_edit_problem(), GridView.INVALID, false, false)
		return
	var center := line.erp.catalog.center_at(item.id) if line.erp != null else {}
	var title := String(center.get("description", {
		&"Hopper": "Ingredient hopper", &"Warehouse": "Finished goods warehouse",
		&"PackagingWIP": "Packaging WIP", &"Palletizer": "Palletizing bays"
	}.get(item.id, String(item.id).capitalize())))
	var footprint := item.footprint()
	var details := "ID %s%s\nCell (%d, %d) · %d × %d cells · %d°\nElevation %.1f m · Height %.2f m" % [
		item.id, " · " + String(center.id) if not center.is_empty() else "",
		item.cell.x, item.cell.y, footprint.size.x, footprint.size.y, item.turns * 90, item.elevation, item.height]
	var group := line.layout.group_for(item.id)
	if group.size() > 1:
		details += "\nLinked equipment moves together."
	var reason := line.layout_edit_problem(group) if item.movable else "Fixed equipment."
	var status := "Ready to move" if reason.is_empty() else reason
	var tint := GridView.VALID if reason.is_empty() else GridView.INVALID
	if _placing and _preview_cell != NO_CELL:
		status = "Ready to place" if _preview_reason.is_empty() else _preview_reason
		tint = GridView.VALID if _preview_reason.is_empty() else GridView.INVALID
	panel.update_selection(title, details, status, tint, reason.is_empty(), _placing)


func _rotate_placement(delta: int) -> void:
	if not _placing:
		if not _build_mode or not _begin_placement():
			return
		var item: Layout.Placement = line.layout.objects[_selected]
		var center := Vector2(item.cell) + Vector2(item.footprint().size) * 0.5
		_turns = posmod(item.turns + delta, 4)
		var size := item.size if _turns % 2 == 0 else Vector2i(item.size.y, item.size.x)
		var cell := Vector2i((center - Vector2(size) * 0.5).round())
		_commit_cell(cell)
		return
	_turns = posmod(_turns + delta, 4)
	_preview_cell = NO_CELL
	_cursor_screen = Vector2.INF
	_update_cursor(_pointer if _dragging else get_viewport().get_mouse_position())


func _begin_placement() -> bool:
	var item := line.layout.definition(_selected)
	if item == null or not item.movable:
		return false
	var reason := line.layout_edit_problem(line.layout.group_for(_selected))
	if not reason.is_empty():
		hud.set_hint(reason)
		return false
	_placing = true
	_turns = item.turns
	_preview_cell = NO_CELL
	_preview_reason = ""
	_cursor_screen = Vector2.INF
	editor.invalidate_preview()
	grid_view.set_grid_visible(true)
	grid_view.clear_selection()
	hud.set_hint("Place on the grid · R / Shift+R rotates · Esc cancels")
	_update_selection_grid()
	return true


func _clear_drag() -> void:
	_drag_armed = false
	_dragging = false
	_press_point = Vector2.INF
	_release_point = Vector2.INF
	_grab_offset = Vector2.ZERO
	camera.set_build_drag(false)


func _cancel_drag_on_focus_loss() -> void:
	if _dragging:
		_end_placement()
	elif _drag_armed:
		_clear_drag()


func _arm_drag() -> void:
	var item := line.layout.definition(_selected)
	if item == null or not item.movable or not line.layout_edit_problem(line.layout.group_for(_selected)).is_empty():
		return
	var hit := grid_view.project_ray(_pick_origin, _pick_direction, item.elevation, false)
	if hit == Vector3.INF:
		return
	var half := Vector2(item.footprint().size) * 0.5
	var offset := line.layout.grid.coordinates(hit) - Vector2(item.cell) - half
	_grab_offset = offset.clamp(-half, half)
	_drag_armed = true


func _start_drag_if_needed() -> void:
	if not _drag_armed or _dragging or _press_point.distance_squared_to(_pointer) < 36.0:
		return
	_dragging = _begin_placement()
	camera.set_build_drag(_dragging)
	_drag_armed = false


func _commit_cell(cell: Vector2i) -> bool:
	var result := editor.preview(_selected, cell, _turns)
	var reason: String = result.reason
	if reason.is_empty():
		reason = editor.apply(result.changes)
	if not reason.is_empty():
		_show_preview(cell)
		hud.set_hint(reason)
		return false
	_end_placement()
	_refresh_layout_views()
	hud.set_hint("%s placed at (%d, %d)." % [_selected, cell.x, cell.y])
	return true


func _refresh_layout_views() -> void:
	if _build_mode:
		grid_view.show_build_areas(true, line.layout.objects.values(), line.layout.reserved)
	floor_view.configure(line.layout, erp_enabled)
	if erp_enabled and not _highlighted_order.is_empty():
		floor_view.show_route(line.erp.orders.get(_highlighted_order, {}))
	floor_view.select(_selected)
	floor_view.animate(line, 0.0)
	_cursor_screen = Vector2.INF
	_refresh()


func _update_cursor(point: Vector2) -> void:
	if get_viewport().gui_get_hovered_control() != null:
		_clear_cursor()
		return
	var grid := line.layout.grid
	if _placing:
		var cell := _placement_cell(camera.project_ray_origin(point), camera.project_ray_normal(point))
		if cell != NO_CELL:
			_show_preview(cell)
		else:
			_clear_cursor()
		return
	var elevation := 0.0
	var hit := grid_view.project(camera, point)
	if not _placing:
		var deck := line.layout.objects[&"Platform"]
		var upper := grid_view.project(camera, point, deck.elevation)
		if upper != Vector3.INF and deck.footprint().has_point(grid.cell_at(upper)):
			hit = upper
			elevation = deck.elevation
	if hit == Vector3.INF:
		_clear_cursor()
		return
	var cell := grid.cell_at(hit)
	grid_view.hover(cell, elevation)
	hud.set_cursor("X %02d   Z %02d   Y %.1f m" % [cell.x, cell.y, elevation])


func _clear_cursor() -> void:
	hud.set_cursor("")
	grid_view.clear_hover()
	if _placing and _preview_cell != NO_CELL:
		grid_view.clear_preview()
		_preview_cell = NO_CELL


func _show_preview(cell: Vector2i) -> void:
	if _preview_cell != cell:
		_preview_cell = cell
		var result := editor.preview(_selected, cell, _turns)
		_preview_reason = result.reason
		grid_view.preview_group(result.changes.values(), _preview_reason.is_empty(), result.conflicts)
		_update_build_panel()
	var item: Layout.Placement = line.layout.objects[_selected]
	var caption := "X %02d   Z %02d   Y %.1f m   %d°" % [cell.x, cell.y, item.elevation, _turns * 90]
	if _preview_reason.is_empty():
		hud.set_cursor(caption + "  ·  Ready to place", GridView.VALID)
	else:
		hud.set_cursor(caption + "  ·  " + _preview_reason, GridView.INVALID)


func _update_selection_grid() -> void:
	_update_build_panel()
	if _selected == &"":
		grid_view.clear_selection()
		return
	var item := line.layout.definition(_selected)
	if item != null:
		var footprint := item.footprint()
		var caption := "(%d, %d)   ·   %d × %d cells   ·   Y %.1f m   ·   %d°" % [
			item.cell.x, item.cell.y, footprint.size.x, footprint.size.y, item.elevation, item.turns * 90]
		var notes := "%s · %s · %.2f m high" % [item.id, item.kind, item.height]
		hud.inspector.set_layout_info(caption, notes, item.movable,
			line.layout_edit_problem(line.layout.group_for(item.id)).is_empty(), _placing)
		if not _placing:
			grid_view.selection(footprint, item.required_area(), item.elevation)
		return
	var view := floor_view.view_of(_selected)
	if view != null:
		var grid := line.layout.grid
		var area := view.occupied_cells(grid)
		var elevation := view.position.y - grid.origin.y
		var cell := grid.cell_at(view.position)
		var kind := "Stored" if String(_selected).begins_with("FGSlot") else "Mobile"
		var caption := "Cell (%d, %d)   ·   Y %.1f m   ·   %s" % [cell.x, cell.y, elevation, kind]
		hud.inspector.set_layout_info(caption, "", false, false, false)
		grid_view.selection(area, area, elevation)


func _set_playing(enabled: bool) -> void:
	if enabled and _build_mode:
		hud.set_hint("Exit Build Mode with B, then press Play.")
		return
	if _placing:
		_end_placement()
	line.set_playing(enabled)
	hud.set_hint("Select stations, carts, or crew to follow the shift." if enabled
		else "Shift paused. Adjust equipment or press Play to resume.")
	_refresh()


func _set_speed(value: int) -> void:
	line.set_multiplier(value)
	_refresh()


func _reset() -> void:
	if _placing:
		_end_placement()
	line.reset()
	_select(_selected)
	var message := "Shift reset. Press Play to run with the current settings."
	if erp_enabled:
		message = "ERP shift paused. Current order and stock are preserved."
		if line.erp.active_id.is_empty():
			message = "ERP shift paused. Fleet settings applied and stock preserved."
	hud.set_hint(message)
	_refresh()
	floor_view.animate(line, 0.0)


func _set_setting(key: StringName, value: float) -> void:
	var accepted := line.set_setting(key, value)
	hud.inspector.sync_setting(key, line.settings[key])
	var message := ""
	if not accepted:
		if Line.Settings.TECHNICAL.has(key) and not line.order_at(StringName(Line.Settings.TECHNICAL[key][0])).is_empty():
			message = "This work center is committed to an order."
		elif key == &"batch_capacity" and not line.oven.can_load():
			message = "Wait until the cooked batch has been unloaded."
		else:
			message = "Capacity must cover current and reserved stock."
	elif key in [&"floor_count", &"raw_count", &"cooked_count", &"coated_cart_count"]:
		message = "Fleet size takes effect on Reset between orders." if erp_enabled else "Fleet size takes effect on Reset."
	hud.inspector.feedback(message)
	_refresh()


func _dispatch(all_stock: bool) -> void:
	var removed := line.dispatch(all_stock)
	hud.inspector.feedback("Dispatched %d pallet(s)." % removed)
	_refresh()


func _refresh() -> void:
	hud.refresh(line)
	floor_view.refresh(line)
	_update_selection_grid()


func _rebuild_world() -> void:
	var layout := line.layout
	floor_view.configure(layout, erp_enabled)
	if erp_enabled and not _highlighted_order.is_empty():
		floor_view.show_route(line.erp.orders.get(_highlighted_order, {}))
	if grid_view != null:
		remove_child(grid_view)
		grid_view.queue_free()
	grid_view = GridView.new()
	add_child(grid_view)
	grid_view.configure(layout.grid, layout.objects[&"Platform"])
	grid_view.set_grid_visible(_show_grid or _build_mode)
	camera.fit_factory(layout.grid.to_world(Vector2(layout.grid.size) * 0.5), layout.grid.size)


func _open_erp(page: int = -1, filter: String = "") -> void:
	if terminal == null:
		return
	if _build_mode:
		_set_build_mode(false)
	if _placing:
		_end_placement()
	_clear_cursor()
	camera._rotating = false
	camera._panning = false
	camera.set_process(false)
	camera.set_process_input(false)
	camera.set_process_unhandled_input(false)
	terminal.open(page, filter)


func _highlight_order(id: String) -> void:
	_highlighted_order = "" if _highlighted_order == id else id
	floor_view.show_route(line.erp.orders.get(_highlighted_order, {}))


func _resume_camera() -> void:
	camera.set_process(true)
	camera.set_process_input(true)
	camera.set_process_unhandled_input(true)


func _locate_stock(location: String) -> void:
	match location:
		"RM-WH": _select(&"RawWarehouse")
		"RM-STAGE": _select(&"Platform")
		"COAT-IN": _select(&"Coater")
		"COAT-IN-02": _select(&"Coater02")
		"PACK-IN": _select(&"Packer")
		"PACK-WIP": _select(&"PackagingWIP")
		"FG-WH": _select(&"Warehouse")
		"TRANSIT": _select(&"SupplyShuttle")
		_: _select(&"Oven")


func _save_shift() -> void:
	if not _save_load_error.is_empty():
		terminal.notice("Existing save preserved. Resolve the load error or start with --fresh-shift.")
		return
	var error := SaveGame.save(line)
	terminal.notice("Shift saved at " + Line.ERP.date(line.elapsed_seconds()) if error.is_empty() else error)


func _load_shift() -> void:
	var saved := SaveGame.load_line()
	if not saved.error.is_empty():
		terminal.notice(saved.error)
		return
	_select(&"")
	line = saved.line
	editor = Editor.new(line)
	_save_load_error = ""
	_highlighted_order = ""
	_rebuild_world()
	terminal.bind(line)
	_refresh()
	floor_view.animate(line, 0.0)
	terminal.notice("Saved shift moved to the larger factory and paused." if saved.get("refitted", false)
		else "Saved shift restored and paused.")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and erp_enabled and resume_saved and line != null and line.erp != null:
		var error := SaveGame.save(line)
		if error.is_empty():
			get_tree().quit()
		else:
			hud.set_hint(error)
