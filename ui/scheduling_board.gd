extends VBoxContainer
## A single clipped canvas draws only the visible resource rows and time range.

signal selected(id: String)
signal details_requested(id: String)
signal feedback(message: String)

const Scheduling = preload("res://erp/scheduling.gd")
const Book = preload("res://erp/operations.gd")
const LABEL_WIDTH := 160.0
const HEADER := 32.0
const ROW := 48.0
const PAN_PIXELS_PER_UNIT := 100.0 / 3.0
const SCALES := [300.0, 60.0, 15.0, 5.0]
const COLORS := {"Created": Color("#307db2"), "Released": Color("#6a54ad"),
	"In Progress": Color("#187858"), "Completed": Color("#496977"), "Closed": Color("#496977"),
	"Delayed": Color("#a45b21"), "Material shortage": Color("#a13e50")}

var line
var picked := ""
var _canvas: Control
var _horizontal: HScrollBar
var _vertical: VScrollBar
var _resource: OptionButton
var _status: OptionButton
var _material: LineEdit
var _date: LineEdit
var _centers: Array[String] = []
var _rows: Array[String] = []
var _by_center := {}
var _boxes := {}
var _cached_line
var _schedule_revision := -1
var _left := 0.0
var _top := 0.0
var _scale := 1
var _drag := ""
var _from := Vector2.ZERO
var _pointer := Vector2.ZERO
var _moving := false
var _shortages := {}


func _ready() -> void:
	var controls := HFlowContainer.new()
	add_child(controls)
	_material = _field(controls, "Material / order")
	_date = _field(controls, "Day or day range (1–3)")
	_resource = OptionButton.new()
	controls.add_child(_resource)
	_resource.item_selected.connect(func(_index: int) -> void: _filter())
	_status = OptionButton.new()
	for status in ["All statuses", "Planned", "Released", "In Progress", "Completed", "Delayed", "Material shortage"]:
		_status.add_item(status)
	controls.add_child(_status)
	_status.item_selected.connect(func(_index: int) -> void: refresh())
	var zoom := OptionButton.new()
	for caption in ["5 min / tick", "1 min / tick", "15 sec / tick", "5 sec / tick"]:
		zoom.add_item(caption)
	zoom.select(_scale)
	zoom.item_selected.connect(func(index: int) -> void:
		_scale = index
		refresh())
	controls.add_child(zoom)
	var jump := Button.new()
	jump.text = "Jump to now"
	jump.pressed.connect(func() -> void:
		_horizontal.value = maxf(0.0, line.erp.now - _seconds_per_pixel() * 90.0))
	controls.add_child(jump)
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(body)
	_canvas = Control.new()
	_canvas.clip_contents = true
	_canvas.custom_minimum_size = Vector2(300, 250)
	_canvas.size_flags_horizontal = SIZE_EXPAND_FILL
	_canvas.draw.connect(_paint)
	_canvas.gui_input.connect(_input_canvas)
	_canvas.resized.connect(refresh)
	body.add_child(_canvas)
	_vertical = VScrollBar.new()
	_vertical.value_changed.connect(func(value: float) -> void:
		_top = value
		_canvas.queue_redraw())
	_vertical.step = 0.0
	_vertical.custom_step = 1.0
	body.add_child(_vertical)
	_horizontal = HScrollBar.new()
	_horizontal.step = 0.0
	_horizontal.value_changed.connect(func(value: float) -> void:
		_left = value
		_canvas.queue_redraw())
	add_child(_horizontal)

	var legend := HFlowContainer.new()
	add_child(legend)
	for state in COLORS:
		if state == "Closed":
			continue
		var key := Label.new()
		key.text = "■ " + ("Planned" if state == "Created" else state)
		key.add_theme_color_override("font_color", COLORS[state])
		key.add_theme_font_size_override("font_size", 12)
		legend.add_child(key)


func _field(parent: Control, hint: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = hint
	field.custom_minimum_size.x = 148
	field.text_changed.connect(func(_value: String) -> void: refresh())
	parent.add_child(field)
	return field


func bind(factory_line) -> void:
	line = factory_line
	_cached_line = null
	_by_center.clear()
	_boxes.clear()
	picked = ""


func refresh() -> void:
	if line == null or _horizontal == null:
		return
	var book = line.erp
	if _cached_line != line:
		_cached_line = line
		_centers.assign(book.catalog.work_centers.keys())
		_resource.clear()
		_resource.add_item("All work centers")
		for id in _centers:
			_resource.add_item(book.catalog.work_centers[id].description)
		_resource.select(0)
		picked = ""
		_schedule_revision = -1
		_filter()
	if _schedule_revision != book.schedule_revision:
		_schedule_revision = book.schedule_revision
		_by_center.clear()
		for order in book.orders.values():
			var center: String = order.get("center", "")
			if center.is_empty() or order.status == "Cancelled":
				continue
			if not _by_center.has(center):
				_by_center[center] = []
			_by_center[center].append(order)
		for orders in _by_center.values():
			orders.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.start < b.start)
	_shortages.clear()
	_horizontal.page = maxf(1.0, (_canvas.size.x - LABEL_WIDTH) * _seconds_per_pixel())
	var last: float = maxf(3600.0, book.now + _horizontal.page)
	for orders in _by_center.values():
		if not orders.is_empty():
			last = maxf(last, orders.back().finish + SCALES[_scale])
	_horizontal.max_value = maxf(last, _horizontal.page)
	_vertical.page = maxf(1.0, (_canvas.size.y - HEADER) / ROW)
	_vertical.max_value = maxf(_vertical.page, _rows.size())
	_canvas.queue_redraw()


func _filter() -> void:
	_rows = _centers.duplicate()
	if _resource.selected > 0:
		_rows.assign([_centers[_resource.selected - 1]])
	refresh()


func _seconds_per_pixel() -> float:
	return SCALES[_scale] / 70.0


func _state(order: Dictionary) -> String:
	if order.status == "Created":
		if not _shortages.has(order.id):
			_shortages[order.id] = not line.erp.shortages(order).is_empty()
		if _shortages[order.id]:
			return "Material shortage"
	if order.status in ["Released", "In Progress"] and (line.erp.now > order.finish 			or (order.started < 0.0 and line.erp.now > order.start and not String(order.delay).is_empty())):
		return "Delayed"
	return order.status


func _matches(order: Dictionary, state: String) -> bool:
	var query := _material.text.strip_edges().to_lower()
	if not query.is_empty() and not (String(order.code) + " " + String(order.id) + " " 			+ String(order.recipe.spec.name)).to_lower().contains(query):
		return false
	var date := _date.text.strip_edges().replace("–", "-")
	var first := date.get_slice("-", 0).to_int()
	var last := date.get_slice("-", 1).to_int() if "-" in date else first
	if first > 0 and (order.finish < (first - 1) * Scheduling.DAY or order.start >= last * Scheduling.DAY):
		return false
	var filter := _status.get_item_text(_status.selected)
	return _status.selected == 0 or filter == state or (filter == "Planned" and order.status == "Created") 		or (filter == "Completed" and state == "Closed")


func _paint() -> void:
	var size := _canvas.size
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("#f9fbfe"))
	_boxes.clear()
	if line == null:
		return
	var right := _left + maxf(0, size.x - LABEL_WIDTH) * _seconds_per_pixel()
	var first := floori(_top)
	var last := mini(_rows.size(), ceili(_top + maxf(0, size.y - HEADER) / ROW))
	for i in range(first, last):
		var y := HEADER + (i - _top) * ROW
		var shade := Color("#eaf1f8") if i % 2 == 0 else Color("#f6f9fc")
		_canvas.draw_rect(Rect2(0, y, size.x, ROW), shade)
		var center: Dictionary = line.erp.catalog.work_centers[_rows[i]]
		_text(Vector2(10, y + 21), center.description, Color("#253c51"), 14, LABEL_WIDTH - 16)
		_text(Vector2(10, y + 37), center.id, Color("#50677b"), 11, LABEL_WIDTH - 16)
		_canvas.draw_line(Vector2(0, y + ROW), Vector2(size.x, y + ROW), Color("#dce7f1"))
	_canvas.draw_rect(Rect2(0, 0, size.x, HEADER), Color("#f9fbfe"))
	var interval: float = SCALES[_scale]
	var tick := floorf(_left / interval) * interval
	while tick <= right:
		var x := _time_x(tick)
		if x >= LABEL_WIDTH:
			_canvas.draw_line(Vector2(x, HEADER - 4), Vector2(x, size.y), Color("#ccdceb"))
			_text(Vector2(x + 4, 20), Book.date(tick).substr(0, 11 if interval >= 60.0 else 15), Color("#39536a"), 11, 70)
		tick += interval
	_text(Vector2(10, 20), "WORK CENTER", Color("#39536a"), 12, LABEL_WIDTH - 16)
	_canvas.draw_line(Vector2(LABEL_WIDTH, 0), Vector2(LABEL_WIDTH, size.y), Color("#b9ccde"), 1)
	for i in range(first, last):
		var y := HEADER + (i - _top) * ROW + 7
		for order in _by_center.get(_rows[i], []):
			if order.start >= right:
				break
			var actual_end: float = order.completed if order.completed >= 0.0 else line.erp.now
			if order.finish <= _left and (order.started < 0.0 or actual_end <= _left):
				continue
			var state := _state(order)
			if not _matches(order, state):
				continue
			var bar := _bar(order.start, order.finish, y, 25)
			if bar.has_area():
				_boxes[order.id] = bar
				_canvas.draw_rect(bar, COLORS[state])
				if order.id == picked:
					_canvas.draw_rect(bar, Color("#152d43"), false, 2.0)
				if bar.size.x > 18 and bar.size.y >= 20:
					_text(bar.position + Vector2(5, 17), "%s  %s  %.2f %s" % [
						order.code, order.id, order.quantity, order.unit], Color.WHITE, 12, bar.size.x - 8)
			if order.started >= 0.0:
				var actual := _bar(order.started, actual_end, y + 29.0, 4.0)
				if actual.has_area():
					_canvas.draw_rect(actual, Color("#16374c"))
	_draw_pegs()
	var now := _time_x(line.erp.now)
	if now >= LABEL_WIDTH and now < size.x:
		_canvas.draw_line(Vector2(now, HEADER - 5), Vector2(now, size.y), Color("#d03462"), 2)
	if _moving and not _drag.is_empty():
		_draw_preview()


func _draw_pegs() -> void:
	for id in _boxes:
		var order: Dictionary = line.erp.orders[id]
		for parent in order.pegs:
			if _boxes.has(parent) and picked in [id, parent]:
				var from: Rect2 = _boxes[id]
				var to: Rect2 = _boxes[parent]
				_canvas.draw_line(Vector2(from.end.x, from.get_center().y), Vector2(to.position.x, to.get_center().y),
					Color("#e89e28"), 2, true)


func _draw_preview() -> void:
	var target := _drop_target()
	if target.is_empty():
		return
	var rect := _bar(target.start, target.start + target.estimate, HEADER + (target.row - _top) * ROW + 7, 25)
	if not rect.has_area():
		return
	_canvas.draw_rect(rect, Color("#48ad82a5") if target.error.is_empty() else Color("#c84e5dbb"))
	_canvas.draw_rect(rect, Color("#244659"), false, 1)


func _bar(start: float, finish: float, y: float, height: float) -> Rect2:
	var x := clampf(_time_x(start), LABEL_WIDTH, _canvas.size.x)
	var edge := clampf(_time_x(finish), LABEL_WIDTH, _canvas.size.x)
	var top := clampf(y, HEADER, _canvas.size.y)
	var bottom := clampf(y + height, HEADER, _canvas.size.y)
	return Rect2(x, top, maxf(0.0, edge - x), bottom - top)


func _time_x(seconds: float) -> float:
	return LABEL_WIDTH + (seconds - _left) / _seconds_per_pixel()


func _text(at: Vector2, value: String, color: Color, point: int, width: float) -> void:
	_canvas.draw_string(ThemeDB.fallback_font, at, value, HORIZONTAL_ALIGNMENT_LEFT, width, point, color)


func _input_canvas(event: InputEvent) -> void:
	if line == null:
		return
	if event is InputEventPanGesture:
		if _drag.is_empty():
			# macOS delivers trackpad motion and momentum as fractional pan deltas.
			var pixels: Vector2 = event.delta * PAN_PIXELS_PER_UNIT
			_horizontal.value += pixels.x * _seconds_per_pixel()
			_vertical.value += pixels.y / ROW
		_canvas.accept_event()
		return
	if event is InputEventMouseMotion and not _drag.is_empty():
		_pointer = event.position
		_moving = _moving or _from.distance_to(_pointer) > 4.0
		if _moving:
			var target := _drop_target()
			if not target.is_empty():
				feedback.emit(target.error if not target.error.is_empty() else "Move to " + Book.date(target.start))
			_canvas.queue_redraw()
		return
	if not event is InputEventMouseButton:
		return
	if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var direction := -1 if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else 1
		if event.shift_pressed or event.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			_horizontal.value += direction * SCALES[_scale]
		else:
			_vertical.value += direction
		_canvas.accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			for id in _boxes:
				if _boxes[id].has_point(event.position):
					picked = id
					selected.emit(id)
					if event.double_click:
						details_requested.emit(id)
					elif line.erp.orders[id].status == "Created":
						_drag = id
						_from = event.position
						_pointer = _from
					_canvas.queue_redraw()
					break
		elif not _drag.is_empty():
			var target := _drop_target() if _moving else {}
			if not target.is_empty():
				var error: String = target.error
				if error.is_empty():
					error = line.erp.reschedule(_drag, target.start, target.version)
				feedback.emit("Scheduled at " + Book.date(target.start) if error.is_empty() else error)
			_drag = ""
			_moving = false
			refresh()
		_canvas.accept_event()


func _drop_target() -> Dictionary:
	var row := floori(_top + (_pointer.y - HEADER) / ROW)
	if _pointer.y < HEADER or _pointer.y >= _canvas.size.y or row >= _rows.size():
		return {}
	var order: Dictionary = line.erp.orders[_drag]
	var start := maxf(line.erp.now, snappedf(order.start + (_pointer.x - _from.x) * _seconds_per_pixel(), 5.0))
	var target := {"start": start, "row": row, "estimate": order.estimate, "version": "", "error": "This machine cannot make " + order.code}
	for route in Scheduling.alternatives(line.erp.catalog, order.code, order.quantity, start):
		if route.operations[0].work_center != _rows[row] or not route.operations[0].available:
			continue
		target.version = route.production_version
		var assignment := Scheduling.assignment(line.erp, order.code, order.quantity, start, target.version, order.id)
		if not assignment.error.is_empty():
			target.error = assignment.error
			break
		target.estimate = assignment.duration
		target.error = Scheduling.placement_conflict(line.erp, assignment, start, order.id)
		break
	return target
