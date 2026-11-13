extends SceneTree
## Raw-material warehouse capacity: pallet positions, receipts that wait at the dock, MRP warnings and saves.

const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const API = preload("res://agent/agent_api.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_master_data()
	_receipts()
	_planning()
	_persistence()
	_agent()
	print("Raw warehouse: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Factory loads: " + line.validation_error)
	return line


## Fill the warehouse with bottles until only `free` positions remain.
func _fill(book, free: int) -> void:
	var room: Dictionary = book.raw_warehouse()
	var pallets: int = room.free - free
	if pallets > 0:
		_check(book.adjust("PK-BOTTLE", pallets * book.catalog.pallet_qty("PK-BOTTLE"), "Test: fill racks").is_empty(), "Fill the racks")


func _master_data() -> void:
	var book = _line().erp
	var catalog = book.catalog
	_check(catalog.raw_capacity() == 90, "RM-WH holds 90 pallet positions")
	for code in catalog.materials:
		var item: Dictionary = catalog.materials[code]
		if item.procurement == "External":
			_check(item.get("storage", "") in catalog.STORAGE_TYPES, "Storage type for " + code)
	_check(catalog.positions("RM-FLOUR", 1000.0) == 1 and catalog.positions("RM-FLOUR", 1000.5) == 2
		and catalog.positions("RM-FLOUR", 0.0) == 0, "Part-full pallets take a whole position")
	_check(catalog.pallet_qty("RM-WATER") == 0.0 and catalog.pallet_qty("PK-PALLET") == 0.0
		and catalog.pallet_qty("PK-LABEL-1001") == 0.0, "Water, empty pallets and labels are not racked")
	var room: Dictionary = book.raw_warehouse()
	_check(room.used == 69 and room.free == 21 and room.waiting.is_empty(), "Opening stock uses 69 of 90 positions (%d)" % room.used)
	_check(is_inf(book.raw_room("RM-WATER")), "Unracked materials have unlimited room")


func _receipts() -> void:
	var line := _line()
	var book = line.erp
	_fill(book, 1)
	var flour: float = book.stock("RM-FLOUR", "RM-WH")
	var room: float = book.raw_room("RM-FLOUR")
	_check(is_equal_approx(room, 5000.0 - flour), "Flour fits its part-full pallet plus one free position (%s)" % room)
	var po: Dictionary = book.purchase("SUP-01", "RM-FLOUR", 3000.0)
	var water: Dictionary = book.purchase("SUP-03", "RM-WATER", 500.0)
	line.set_playing(true)
	line.advance(float(book.purchases[po.id].due) + 2.0)
	var order: Dictionary = book.purchases[po.id]
	_check(order.status == "Partial" and is_equal_approx(order.received, room) and is_equal_approx(order.at_dock, 3000.0 - room),
		"Only what fits is put away; the rest waits at the dock (%s / %s)" % [order.received, order.get("at_dock", -1)])
	_check(book.raw_warehouse().free == 0 and book.raw_warehouse().waiting.size() == 1, "The warehouse reports full with one delivery waiting")
	_check(book.purchases[water.id].status == "Received", "Water goes to its tank even when the racks are full")
	_check(not book.manual_transfer("RM-FLOUR", 10.0, "RM-STAGE", "RM-WH", "Return").is_empty() or book.stock("RM-FLOUR", "RM-STAGE") < 10.0,
		"No returns into a full warehouse")
	line.advance(30.0)
	_check(float(order.get("dock_seconds", 0.0)) >= 25.0, "Dock waiting time accumulates (%s s)" % order.get("dock_seconds", 0.0))
	_check(book.adjust("PK-BOTTLE", -2.0 * book.catalog.pallet_qty("PK-BOTTLE"), "Test: free two positions").is_empty(), "Free two positions")
	line.advance(2.0)
	_check(order.status == "Received" and is_zero_approx(order.at_dock), "The waiting delivery is put away once space frees")
	_check(book.raw_warehouse().used <= book.catalog.raw_capacity(), "Receipts never exceed capacity")


func _planning() -> void:
	var line := _line()
	var book = line.erp
	book.adjust("RM-COAT-1002", -book.stock("RM-COAT-1002", "RM-WH"), "Test: no dark coating")
	_fill(book, 0)
	var plan := Plan.new()
	book.create_demand("FG-1002", 40, 7200.0)
	plan.run(book, line.erp_fg())
	var full: Array = plan.exceptions.filter(func(row: Dictionary) -> bool: return row.kind == "storage_full")
	_check(full.any(func(row: Dictionary) -> bool: return row.code == "RM-COAT-1002"), "MRP warns that the coating requisition will not fit")
	var coat: Array = plan.proposals.values().filter(func(item: Dictionary) -> bool: return item.code == "RM-COAT-1002")
	_check(not coat.is_empty() and coat[0].exceptions.any(func(text: String) -> bool: return "pallet positions" in text),
		"The requisition carries the storage message")
	var po: Dictionary = book.purchase("SUP-02", "RM-COAT-1002", 100.0)
	line.set_playing(true)
	line.advance(float(book.purchases[po.id].due) + 2.0)
	plan.run(book, line.erp_fg())
	_check(plan.exceptions.any(func(row: Dictionary) -> bool: return row.kind == "at_dock" and row.element == po.id),
		"MRP reports the delivery waiting at the dock")


func _persistence() -> void:
	var line := _line()
	var book = line.erp
	_fill(book, 0)
	var po: Dictionary = book.purchase("SUP-01", "RM-SUGAR", 2000.0)
	line.set_playing(true)
	line.advance(float(book.purchases[po.id].due) + 3.0)
	var data := Save.snapshot(line)
	var restored := Save.restore(data.duplicate(true))
	_check(restored.error.is_empty(), "Shift with a delivery at the dock restores")
	if restored.error.is_empty():
		var copy: Line = restored.line
		_check(float(copy.erp.purchases[po.id].get("at_dock", 0.0)) > 0.0 and copy.erp.raw_warehouse().used == book.raw_warehouse().used,
			"Dock wait and rack occupancy survive save and load")
	# A save from before warehouse capacity gains storage settings and the default capacity.
	var old := data.duplicate(true)
	old.catalog.erase("storage_capacity")
	for code in old.catalog.materials:
		old.catalog.materials[code].erase("storage")
		old.catalog.materials[code].erase("pallet_qty")
	var migrated := Save.restore(old)
	_check(migrated.error.is_empty() and migrated.line.erp.catalog.raw_capacity() == 90
		and migrated.line.erp.catalog.pallet_qty("RM-FLOUR") == 1000.0, "Older saves gain pallet sizes and capacity")


func _agent() -> void:
	var api := API.new()
	var loaded: Dictionary = api.load_scenario_data({"name": "Tight racks", "raw_warehouse_positions": 75, "demands": []})
	_check(loaded.error.is_empty() if loaded.has("error") else true, "Scenario sets warehouse capacity")
	var stock: Dictionary = api.handle({"cmd": "stock", "args": {"codes": ["RM-FLOUR"]}})
	_check(stock.ok and stock.raw_warehouse.capacity_positions == 75 and stock.raw_warehouse.used_positions == 69
		and stock.stock[0].pallets_in_rm_wh == 4, "Agent stock shows positions: " + JSON.stringify(stock.get("raw_warehouse", {})))
	var material: Dictionary = api.handle({"cmd": "material", "args": {"code": "PK-BOTTLE"}})
	_check(material.ok and material.storage == "rack" and material.pallet_qty == 5000.0, "Agent material lookup shows pallet size")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
