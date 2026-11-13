extends SceneTree
## Simulation instances: create, rename, save and continue, the opening page, and fleet changes without Reset.

const Instances = preload("res://erp/instances.gd")
const SaveGame = preload("res://erp/save_game.gd")
const Line = preload("res://simulation/production_line.gd")
const FACTORY = preload("res://scenes/factory.tscn")
const MENU = preload("res://scenes/start_menu.tscn")
const TEST_DIR := "user://test_instances"
const IMPORT_DIR := "user://test_instances_import"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Instances.directory = TEST_DIR
	Instances.import_legacy = false
	_clear(TEST_DIR)
	_store()
	await _factory_round_trip()
	await _opening_page()
	_legacy_import()
	_fleet()
	_clear(TEST_DIR)
	_clear(IMPORT_DIR)
	print("Simulation instances: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _store() -> void:
	_check(Instances.list().is_empty(), "A new folder lists no instances")
	var alpha := Instances.create("  Alpha  ")
	_check(alpha.error.is_empty() and Instances.find(alpha.id).name == "Alpha", "Create a named instance")
	_check(not Instances.create("alpha").error.is_empty(), "Names are unique regardless of case")
	_check(not Instances.create("   ").error.is_empty(), "Empty names are rejected")
	var beta := Instances.create("Beta")
	_check(not Instances.rename(beta.id, "ALPHA").is_empty(), "Rename cannot take another instance's name")
	_check(Instances.rename(beta.id, "Gamma").is_empty() and Instances.find(beta.id).name == "Gamma", "Rename an instance")
	_check(not Instances.rename("sim-missing", "Delta").is_empty(), "Renaming a missing instance fails")
	_check(not Instances.find(alpha.id).saved and not Instances.load_line(alpha.id).error.is_empty(), "An unsaved instance cannot be continued")
	var doomed := Instances.create("Doomed")
	var line := Line.new()
	line.enable_erp()
	Instances.save(doomed.id, line)
	_check(FileAccess.file_exists(Instances.path(doomed.id)), "A saved instance has a file")
	_check(Instances.delete(doomed.id).is_empty() and Instances.find(doomed.id).is_empty()
		and not FileAccess.file_exists(Instances.path(doomed.id)), "Delete removes the listing and the save file")
	_check(not Instances.delete(doomed.id).is_empty() and Instances.find(alpha.id).name == "Alpha", "Deleting twice fails and leaves others alone")


func _open(request: Dictionary) -> Node:
	Instances.pending = request
	var factory := FACTORY.instantiate()
	root.add_child(factory)
	await process_frame
	await process_frame
	return factory


func _factory_round_trip() -> void:
	var created := Instances.create("Round trip")
	var factory := await _open({"id": created.id, "new": true})
	_check(factory._instance_id == created.id and Instances.find(created.id).saved, "A new instance opens and is saved at once")
	_check("ROUND TRIP" in factory.hud._instance_label.text, "The HUD shows the instance name")
	_check(factory.hud.find_children("*", "Button", true, false).any(func(b: Button) -> bool: return b.text == "Main menu")
		and not factory.terminal.find_children("*", "Button", true, false).any(func(b: Button) -> bool: return b.text in ["Main menu", "Load"]),
		"Main menu is in the factory view, not in ERP")
	factory._confirm_start_menu()
	var asking: Array = factory.find_children("*", "ConfirmationDialog", false, false)
	_check(asking.size() == 1 and "Save this simulation instance" in asking[0].dialog_text, "Main menu asks before leaving")
	asking[0].canceled.emit()
	var demand: Dictionary = factory.line.erp.create_demand("FG-1001", 7, 3600.0)
	factory.line.set_playing(true)
	factory.line.advance(30.0)
	factory._save_instance()
	var row := Instances.find(created.id)
	_check(row.saved and float(row.sim_seconds) >= 29.0, "Saving records the simulation time (%s)" % row.sim_seconds)
	factory.queue_free()
	await process_frame
	var again := await _open({"id": created.id, "new": false})
	_check(again.line.erp.demands.has(demand.id) and again.line.elapsed_seconds() >= 29.0, "Continue restores the saved state")
	again.queue_free()
	await process_frame
	var plain := FACTORY.instantiate()
	plain.resume_saved = false
	root.add_child(plain)
	await process_frame
	_check(plain._instance_id.is_empty() and plain.hud._instance_label.text.is_empty(), "A scene opened without an instance is an unsaved run")
	plain.queue_free()
	await process_frame


func _opening_page() -> void:
	var menu := MENU.instantiate()
	root.add_child(menu)
	await process_frame
	var rows := Instances.list()
	_check(menu._list.get_child_count() == rows.size(), "The opening page lists every saved instance (%d)" % rows.size())
	var saved: Dictionary = rows.filter(func(row: Dictionary) -> bool: return row.saved)[0]
	var card: Node = menu._list.find_child("Instance_" + saved.id, true, false)
	var buttons: Array = card.find_children("*", "Button", true, false) if card != null else []
	_check(buttons.any(func(b: Button) -> bool: return b.text == "Continue" and not b.disabled)
		and buttons.any(func(b: Button) -> bool: return b.text == "Rename") and buttons.any(func(b: Button) -> bool: return b.text == "Delete"),
		"Saved instances offer Continue, Rename and Delete")
	_check(menu._name.text.begins_with("Simulation "), "A default name is suggested")
	var count: int = menu._list.get_child_count()
	menu._confirm_delete(saved)
	var sure: Array = menu.find_children("*", "ConfirmationDialog", false, false)
	_check(sure.size() == 1 and saved.name in sure[0].dialog_text and Instances.list().size() == count, "Delete asks first and removes nothing yet")
	sure[0].canceled.emit()
	_check(Instances.list().size() == count, "Cancelling keeps the instance")
	menu._confirm_delete(saved)
	menu.find_children("*", "ConfirmationDialog", false, false)[0].confirmed.emit()
	_check(Instances.list().size() == count - 1 and Instances.find(saved.id).is_empty() and menu._list.get_child_count() == count - 1,
		"Confirming deletes the instance and refreshes the list")
	menu._name.text = "Alpha"
	menu._create()
	_check("already exists" in menu._feedback.text, "The page explains a duplicate name")
	menu.queue_free()
	await process_frame


func _legacy_import() -> void:
	if not FileAccess.file_exists(SaveGame.PATH):
		print("  (no single-slot save on this machine; import not exercised)")
		return
	Instances.directory = IMPORT_DIR
	Instances.import_legacy = true
	_clear(IMPORT_DIR)
	var rows := Instances.list()
	_check(rows.size() == 1 and rows[0].name == "My factory" and FileAccess.file_exists(Instances.path(rows[0].id))
		and FileAccess.file_exists(SaveGame.PATH), "The old single save is copied in once and kept")
	_check(Instances.list().size() == 1, "The import happens only once")
	Instances.directory = TEST_DIR
	Instances.import_legacy = false


func _fleet() -> void:
	var line := Line.new()
	line.enable_erp()
	line.set_setting(&"floor_count", 2.0)
	_check(line.sync_fleet() and line.floor_crew.size() == 2, "An idle line applies a smaller floor crew at once")
	line.set_setting(&"floor_count", 4.0)
	line.runs["MO-TEST"] = {}
	_check(not line.sync_fleet() and line.floor_crew.size() == 2, "A busy line keeps its crew until orders finish")
	line.runs.clear()
	_check(line.sync_fleet() and line.floor_crew.size() == 4, "The change applies once nothing runs")


func _clear(folder: String) -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		return
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
