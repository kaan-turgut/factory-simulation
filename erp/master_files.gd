extends RefCounted
## Loads each definition once for the lifetime of the process. Callers get their own copy.

const PROJECT_PATH := "res://master_data"
static var _cache := {}


static func read(name: String, directory: String = "") -> Dictionary:
	if directory.is_empty():
		if not _cache.has(name):
			_cache[name] = read(name, source_directory())
		return _cache[name].duplicate(true)
	var path := directory.path_join(name + ".json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": path + ": cannot open file."}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return {"error": "%s:%d: %s" % [path, parser.get_error_line(), parser.get_error_message()]}
	return {"error": "", "data": parser.data}


static func source_directory() -> String:
	var executable := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("editor"):
		for directory in [executable, executable.path_join("../../..").simplify_path()]:
			if DirAccess.dir_exists_absolute(directory.path_join("master_data")):
				return directory.path_join("master_data")
	return PROJECT_PATH


static func index(name: String, key: String, fields: Array, directory: String = "") -> Dictionary:
	var result := read(name, directory)
	if not result.error.is_empty():
		return result
	if not result.data is Array:
		return {"error": name + ".json: expected a list."}
	var rows := {}
	for item in result.data:
		if not item is Dictionary or not item.get(key) is String or String(item[key]).is_empty():
			return {"error": "%s.json: missing or invalid %s." % [name, key]}
		var id: String = item[key]
		if rows.has(id):
			return {"error": "%s.json [%s].%s: duplicate identifier." % [name, id, key]}
		for field in fields:
			if not item.has(field):
				return {"error": "%s.json [%s].%s: required field." % [name, id, field]}
		rows[id] = item
	return {"error": "", "data": rows}


static func number(value: Variant, low: float = 0.0, high: float = INF, whole: bool = false) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= low \
		and float(value) <= high and (not whole or float(value) == floorf(value))
