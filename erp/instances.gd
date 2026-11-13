extends RefCounted
## Named simulation instances: one save file each, listed in an index the opening page reads.
##
## The game used to keep a single save at SaveGame.PATH. The first time the index is read, that
## file is copied in as an instance, and the original is left untouched.

const SaveGame = preload("res://erp/save_game.gd")
const NAME_LIMIT := 48

## Tests point these at their own folder so they never touch the player's instances.
static var directory := "user://instances"
static var import_legacy := true

## The instance the factory scene should open next: {"id": String, "new": bool}. Set by the opening page.
static var pending := {}


static func list() -> Array:
	var rows := _read()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.updated) > float(b.updated))
	return rows


static func find(id: String) -> Dictionary:
	for row in _read():
		if row.id == id:
			return row
	return {}


static func path(id: String) -> String:
	return directory.path_join(id + ".save")


static func create(name: String) -> Dictionary:
	var title := _clean(name)
	if title.is_empty():
		return {"error": "Name the simulation instance."}
	var rows := _read()
	if rows.any(func(row: Dictionary) -> bool: return String(row.name).to_lower() == title.to_lower()):
		return {"error": "A simulation instance with this name already exists."}
	var now := Time.get_unix_time_from_system()
	var id := "sim-%d-%03d" % [int(now), rows.size() % 1000]
	while rows.any(func(row: Dictionary) -> bool: return row.id == id) or FileAccess.file_exists(path(id)):
		id += "x"
	var row := {"id": id, "name": title, "created": now, "updated": now, "sim_seconds": 0.0, "saved": false}
	rows.append(row)
	var error := _write(rows)
	return {"error": error, "id": id} if error.is_empty() else {"error": error}


static func rename(id: String, name: String) -> String:
	var title := _clean(name)
	if title.is_empty():
		return "Name the simulation instance."
	var rows := _read()
	if rows.any(func(row: Dictionary) -> bool: return row.id != id and String(row.name).to_lower() == title.to_lower()):
		return "A simulation instance with this name already exists."
	for row in rows:
		if row.id == id:
			row.name = title
			return _write(rows)
	return "This simulation instance no longer exists."


## Remove an instance and its save file for good.
static func delete(id: String) -> String:
	var rows := _read()
	var kept := rows.filter(func(row: Dictionary) -> bool: return row.id != id)
	if kept.size() == rows.size():
		return "This simulation instance no longer exists."
	var error := _write(kept)
	if not error.is_empty():
		return error
	if FileAccess.file_exists(path(id)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path(id)))
	return ""


## Save a simulation into its instance file and refresh its listing.
static func save(id: String, line) -> String:
	var rows := _read()
	var row: Dictionary = {}
	for item in rows:
		if item.id == id:
			row = item
	if row.is_empty():
		return "This simulation instance no longer exists."
	var error: String = SaveGame.save(line, path(id))
	if not error.is_empty():
		return error
	row.updated = Time.get_unix_time_from_system()
	row.sim_seconds = line.elapsed_seconds()
	row.saved = true
	return _write(rows)


static func load_line(id: String) -> Dictionary:
	if not FileAccess.file_exists(path(id)):
		return {"error": "This simulation instance has not been saved yet."}
	return SaveGame.load_line(path(id))


static func _index() -> String:
	return directory.path_join("index.json")


static func _clean(name: String) -> String:
	return name.strip_edges().replace("\n", " ").left(NAME_LIMIT)


static func _read() -> Array:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var rows: Array = []
	if FileAccess.file_exists(_index()):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_index()))
		if data is Array:
			rows = data.filter(func(row: Variant) -> bool: return row is Dictionary and row.get("id") is String and row.get("name") is String)
	elif import_legacy and FileAccess.file_exists(SaveGame.PATH):
		rows = _import_legacy()
	return rows


## Bring the single save from before simulation instances into the list once.
static func _import_legacy() -> Array:
	var id := "sim-imported"
	var copied := DirAccess.copy_absolute(ProjectSettings.globalize_path(SaveGame.PATH), ProjectSettings.globalize_path(path(id)))
	if copied != OK:
		return []
	var modified := FileAccess.get_modified_time(SaveGame.PATH)
	var rows := [{"id": id, "name": "My factory", "created": modified, "updated": modified, "sim_seconds": -1.0, "saved": true}]
	_write(rows)
	return rows


static func _write(rows: Array) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var file := FileAccess.open(_index() + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Could not write the simulation instance list."
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()
	var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(_index() + ".tmp"), ProjectSettings.globalize_path(_index()))
	return "" if result == OK else "Could not update the simulation instance list."
