extends RefCounted
## Placement transactions. Runtime equipment and documents stay on the same line.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Placement = Layout.Placement
const PATH := "user://factory_layout.json"
const HISTORY_LIMIT := 32
const PREVIEW_LIMIT := 96

var line: Line
var _occupied := {}
var _previews := {}
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _saved: Dictionary


func _init(shift: Line) -> void:
	line = shift
	_saved = _positions()
	_index()


func invalidate_preview() -> void:
	_previews.clear()


func preview(id: StringName, cell: Vector2i, turns: int) -> Dictionary:
	var key := "%s|%s|%d" % [id, cell, turns]
	if not _previews.has(key):
		if _previews.size() >= PREVIEW_LIMIT:
			_previews.clear()
		var changes := line.layout.proposal(id, cell, turns)
		var conflicts := _conflicts(changes)
		var reason := line.layout_edit_problem(changes.keys())
		if reason.is_empty():
			if changes.values().any(func(item: Placement) -> bool: return not line.layout.grid.bounds().encloses(item.required_area())):
				reason = "Footprint or clearance crosses the interior wall."
			elif not conflicts.is_empty():
				reason = "Footprint overlaps another station."
			else:
				reason = line.layout.validate_changes(changes)
		_previews[key] = {"changes": changes, "reason": reason, "conflicts": conflicts}
	return _previews[key]


func apply(changes: Dictionary) -> String:
	var previous := {}
	var next := {}
	for id in changes:
		var current: Placement = line.layout.objects.get(id)
		if current == null:
			return "Unknown equipment %s." % id
		var target: Placement = changes[id]
		if current.cell != target.cell or current.turns != target.turns:
			previous[id] = current
			next[id] = target
	if next.is_empty():
		return ""
	var reason := _install(next)
	if reason.is_empty():
		_undo.append({"before": previous, "after": next})
		if _undo.size() > HISTORY_LIMIT:
			_undo.pop_front()
		_redo.clear()
	return reason


func undo() -> String:
	return _replay(_undo, _redo, "before")


func redo() -> String:
	return _replay(_redo, _undo, "after")


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func dirty() -> bool:
	return _positions() != _saved


func reset_default() -> String:
	var defaults := Layout.new(line.layout.grid.size)
	if not defaults.error.is_empty():
		return defaults.error
	var changes := {}
	for id in line.layout.objects:
		var item: Placement = line.layout.objects[id]
		if item.movable and defaults.objects.has(id):
			var original: Placement = defaults.objects[id]
			changes[id] = item.at(original.cell, original.turns)
	return apply(changes)


func save(path: String = PATH) -> String:
	var stamp := maxf(floorf(Time.get_unix_time_from_system() * 1000.0), line.layout_file_stamp + 1.0)
	var positions := _positions()
	var size := line.layout.grid.size
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Cannot write the layout file."
	file.store_string(JSON.stringify({"version": 1, "saved_at": stamp,
		"size": [size.x, size.y], "placements": positions}, "	") + "
")
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK or DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"),
			ProjectSettings.globalize_path(path)) != OK:
		return "Could not save the layout."
	line.layout_file_stamp = stamp
	_saved = positions
	return ""


func load_layout(path: String = PATH, newer_only: bool = false) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "No saved layout found."
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return "Invalid layout JSON at line %d." % parser.get_error_line()
	var data: Dictionary = parser.data
	var size := line.layout.grid.size
	var dimensions: Variant = data.get("size")
	if data.get("version") != 1 or not dimensions is Array or dimensions.size() != 2 \
			or dimensions[0] != size.x or dimensions[1] != size.y or not data.get("placements") is Dictionary:
		return "The saved layout does not match this factory size or version."
	var stamp: Variant = data.get("saved_at", 0.0)
	if not Layout.Master.number(stamp):
		return "The saved layout has an invalid save timestamp."
	if newer_only and stamp <= line.layout_file_stamp:
		return ""
	var changes := {}
	for key in data.placements:
		var id := StringName(key)
		var item: Placement = line.layout.objects.get(id)
		var pose: Variant = data.placements[key]
		if item == null or not item.movable or not pose is Array or pose.size() != 3:
			return "Invalid placement for %s." % id
		if not Layout.Master.number(pose[0], 0, size.x, true) or not Layout.Master.number(pose[1], 0, size.y, true) \
				or not Layout.Master.number(pose[2], 0, 3, true):
			return "Invalid coordinates or rotation for %s." % id
		changes[id] = item.at(Vector2i(int(pose[0]), int(pose[1])), int(pose[2]))
	var reason := apply(changes)
	if reason.is_empty():
		line.layout_file_stamp = stamp
		_saved = _positions()
	return reason


func _replay(source: Array[Dictionary], destination: Array[Dictionary], key: String) -> String:
	if source.is_empty():
		return "No layout changes to " + ("undo." if key == "before" else "redo.")
	var entry: Dictionary = source.back()
	var reason := _install(entry[key])
	if reason.is_empty():
		destination.append(source.pop_back())
	return reason


func _install(changes: Dictionary) -> String:
	var reason := line.layout_edit_problem(changes.keys())
	if reason.is_empty():
		reason = line.layout.validate_changes(changes)
	if reason.is_empty():
		line.layout.objects.merge(changes, true)
		line.layout.invalidate_routes()
		_index()
	return reason


func _positions() -> Dictionary:
	var result := {}
	for id in line.layout.objects:
		var item: Placement = line.layout.objects[id]
		if item.movable:
			result[String(id)] = [item.cell.x, item.cell.y, item.turns]
	return result


func _index() -> void:
	_previews.clear()
	_occupied.clear()
	for item in line.layout.objects.values():
		var rect: Rect2i = item.footprint()
		for z in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var cell := Vector2i(x, z)
				if not _occupied.has(cell):
					_occupied[cell] = []
				_occupied[cell].append(item)


func _conflicts(changes: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for item: Placement in changes.values():
		var rect := item.footprint()
		for z in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var cell := Vector2i(x, z)
				for other: Placement in _occupied.get(cell, []):
					if not changes.has(other.id) and item.elevation < other.elevation + other.height 							and other.elevation < item.elevation + item.height 							and not (other.kind == &"platform" and is_equal_approx(other.elevation, item.elevation)):
						result.append(cell)
						break
	return result
