extends SceneTree
## External master-data validation, route execution and independent resource commitments.

const Line = preload("res://simulation/production_line.gd")
const Catalog = Line.ERP.Catalog
const Master = Catalog.Master
const Save = preload("res://erp/save_game.gd")

var _failures := 0


func _initialize() -> void:
	_master_data()
	_versions()
	_parallel()
	_coated_transport()
	_legacy_execution()
	print("Alternative routing integration checks, %d failures." % _failures)
	quit(int(_failures > 0))


func _master_data() -> void:
	var catalog := Catalog.new()
	var plan := Line.Layout.new()
	_check(catalog.error.is_empty() and plan.validate().is_empty(), "External catalog and layout are valid")
	_check(catalog.routings.has("WAFER-01") and catalog.work_centers.size() == 12, "Legacy routes and twelve work centers")
	var folder := "user://routing-fixtures-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	for file in DirAccess.get_files_at(Master.PROJECT_PATH):
		if file.ends_with(".json"):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(Master.PROJECT_PATH.path_join(file)),
				ProjectSettings.globalize_path(folder.path_join(file)))
	var schedule_path := folder.path_join("scheduling.json")
	var schedule_copy := FileAccess.get_file_as_string(schedule_path)
	var broken_calendar: Dictionary = JSON.parse_string(schedule_copy)
	broken_calendar.stages.bake = null
	_write(schedule_path, JSON.stringify(broken_calendar))
	_check("scheduling.json [bake]" in Catalog.new(folder).error, "Report an invalid stage definition")
	_write(schedule_path, schedule_copy)
	var external := Catalog.new(folder)
	var path := folder.path_join("work_centers.json")
	var centers: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	centers[2].technical.batch_kg = 66
	_write(path, JSON.stringify(centers))
	_check(external.work_centers["WC-OVN-02"].technical.batch_kg == 60
		and Catalog.new(folder).work_centers["WC-OVN-02"].technical.batch_kg == 66,
		"Editing JSON affects a new registry and leaves the running registry stable")
	centers[2].technical.batch_kg = -1
	_write(path, JSON.stringify(centers))
	_check("WC-OVN-02].technical.batch_kg" in Catalog.new(folder).error, "Reject invalid technical capacity")
	_write(path, "{bad")
	_check("work_centers.json:" in Catalog.new(folder).error, "Report JSON parse error with filename")
	centers[2].technical.batch_kg = 60
	centers[2].id = centers[1].id
	_write(path, JSON.stringify(centers))
	_check("duplicate identifier" in Catalog.new(folder).error, "Reject duplicate work center IDs")
	centers[2].id = "WC-OVN-02"
	_write(path, JSON.stringify(centers))
	path = folder.path_join("routings.json")
	var routes: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	routes[0].operations[1].work_center = "MISSING"
	_write(path, JSON.stringify(routes))
	_check("WAFER-01].operations[1]" in Catalog.new(folder).error, "Report broken routing reference")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(Master.PROJECT_PATH.path_join("routings.json")),
		ProjectSettings.globalize_path(path))
	path = folder.path_join("production_versions.json")
	var versions: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	versions[0].routing = "WAFER-02"
	versions[0].product = "FG-1005"
	versions[0].bom_version = versions[4].bom_version
	_write(path, JSON.stringify(versions))
	_check("does not support this product" in Catalog.new(folder).error, "Reject incompatible product assignment")
	path = folder.path_join("boms.json")
	var boms: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	for bom in boms:
		if bom.parent == "DOUGH-01":
			bom.parts[0].code = "BAKED-01"
	_write(path, JSON.stringify(boms))
	_check("circular BOM" in Catalog.new(folder).error, "Reject a circular external BOM")
	path = folder.path_join("factory_layout.json")
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for item in layout.objects:
		if item.id == "Oven02":
			item.ports.raw_dock = [0, 0, 0]
	_write(path, JSON.stringify(layout))
	_check("obstructed" in Line.Layout.new(Vector2i.ZERO, folder).validate(), "Reject unreachable dock")
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))


func _versions() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var book := line.erp
	var denied := book.create_order("FG-1004", 8, 0, 1, "PV-1004-02")
	_check(not denied.error.is_empty(), "Invalid product version is rejected")
	var order := book.create_order("FG-1001", 8, 0, 1)
	_check(order.error.is_empty(), "Create order with default route")
	if not order.error.is_empty():
		return
	_check(book.select_version(order.id, "PV-1001-03").is_empty(), "Override version before release")
	_check(book.orders[order.id].route.operations[2].equipment == "Coater02", "Version assigns coater 02")
	_check(book.release(order.id).is_empty(), "Release validates version and materials")
	var frozen: Dictionary = book.orders[order.id].route.duplicate(true)
	_check(line.set_setting(&"coater_rate_02", 6400.0), "Independent idle station setting")
	book.catalog.routings["WAFER-03"].operations[1].work_center = "WC-OVN-02"
	_check(not book.select_version(order.id, "PV-1001-02").is_empty(), "Released version is locked")
	_check(book.orders[order.id].route == frozen, "Changing work center or routing leaves released snapshot unchanged")
	book.catalog.center_at(&"Coater").available = false
	var fallback := book.create_order("FG-1001", 8, 0, 1)
	_check(fallback.error.is_empty() and book.orders[fallback.id].version == "PV-1001-02",
		"Default version skips an offline machine")
	_check(not book.create_order("FG-1004", 8, 0, 1).error.is_empty(),
		"An SKU without an available compatible center cannot be routed")


func _parallel() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var book := line.erp
	# Use crossed assignments to ensure worker delivery follows the routing, not machine pairing.
	var first := book.create_order("FG-1001", 16, 0, 1, "PV-1001-03")
	var second := book.create_order("FG-1003", 10, 0, 2, "PV-1003-04")
	var waiting := book.create_order("FG-1001", 8, 0, 3, "PV-1001-01")
	_check(first.error.is_empty() and second.error.is_empty() and waiting.error.is_empty(), "Create mixed routing orders")
	if not first.error.is_empty() or not second.error.is_empty() or not waiting.error.is_empty():
		return
	for document in [first, second, waiting]:
		_check(book.release(document.id).is_empty(), "Release " + document.id)
	line.set_playing(true)
	var parallel := false
	var conflict := false
	var overlap := false
	var conservation := true
	var raw_destinations := {}
	var cooked_destinations := {}
	var snapshot := {}
	for tick in 12000:
		line.advance(Line.STEP_SECONDS)
		if tick % 4 == 0:
			var coated := 0.0
			for document in book.orders.values():
				coated += float(document.consumed.get(document.recipe.coating, 0.0))
			conservation = conservation and absf(line.ingredients_taken + coated - line.material_on_site()) < 0.00001
		overlap = overlap or (line.ovens[&"Oven02"].state == Line.Oven.State.COOKING
			and line.coaters[&"Coater02"].actual_rate > 0.0)
		if book.orders[first.id].status == "In Progress" and book.orders[second.id].status == "In Progress":
			parallel = true
			conflict = conflict or book.orders[waiting.id].status == "Released"
			if snapshot.is_empty():
				snapshot = Save.snapshot(line)
		for task in line.floor_assignments.values():
			if task.kind == Line.JobKind.MOVE_CART and task.site == Line.Cart.Site.OVEN_RAW:
				raw_destinations[task.run] = task.point
			if task.kind == Line.JobKind.MOVE_CART and task.site == Line.Cart.Site.COATER:
				cooked_destinations[task.run] = task.point
		if book.orders[waiting.id].status == "Completed":
			break
	_check(parallel and conflict, "Different centers run concurrently and a shared-center order queues")
	_check(overlap, "Coater 02 processes one order while Oven 02 cooks another")
	_check(conservation, "Concurrent stock stays conserved at each sampled step")
	_check(raw_destinations.get(first.id) == line.layout.port(&"Oven", &"raw_dock")
		and raw_destinations.get(second.id) == line.layout.port(&"Oven02", &"raw_dock"), "Raw carts reach selected ovens")
	_check(cooked_destinations.get(first.id) == line.layout.port(&"Coater02", &"cooked_dock")
		and cooked_destinations.get(second.id) == line.layout.port(&"Coater", &"cooked_dock"), "Cooked carts reach crossed coating assignments")
	_check(is_equal_approx(book.orders[first.id].received_kg, 80.0) and is_equal_approx(book.orders[second.id].received_kg, 50.0)
		and is_equal_approx(line.warehouse_mass(), 170.0) and line.erp_wip().is_empty(), "All order mass is delivered separately")
	for order in [book.orders[first.id], book.orders[second.id], book.orders[waiting.id]]:
		var movements := book.movements.filter(func(row: Dictionary) -> bool:
			return row.document == order.id and row.type == "FG Receipt")
		_check(not movements.is_empty() and movements.all(func(row: Dictionary) -> bool:
			return row.code == order.code), "Order-specific finished-goods trace")
	if snapshot.is_empty():
		return
	var restored := Save.restore(snapshot)
	_check(restored.error.is_empty(), "Save restores concurrent commitments")
	if restored.error.is_empty():
		var resumed: Line = restored.line
		resumed.set_playing(true)
		resumed.advance(line.elapsed_seconds() - resumed.elapsed_seconds())
		_check(Save.snapshot(resumed) == Save.snapshot(line), "Parallel restore preserves exact jobs, material and ledger")


func _coated_transport() -> void:
	var line := Line.new()
	line.enable_erp(false)
	line.set_setting(&"pack_wip_capacity", 8.0)
	line.set_setting(&"coated_cart_capacity", 17.0)
	var order := line.erp.create_order("FG-1001", 13, 0, 1, "PV-1001-02")
	if not order.error.is_empty() or not line.erp.release(order.id).is_empty():
		_check(false, "Create a coated transport order")
		return
	line.set_playing(true)
	var in_transit := {}
	var in_buffer := {}
	var legacy := {}
	var waited := false
	for tick in 4500:
		line.advance(Line.STEP_SECONDS)
		var run: Dictionary = line.runs.get(order.id, {})
		if not run.is_empty() and legacy.is_empty() and run.output.quantity > 0.1:
			legacy = _legacy_outfeed_fixture(line, order.id)
		for cart in line.carts:
			if cart.coated and cart.site == Line.Cart.Site.TRANSIT and cart.stock.quantity > 0.0 and in_transit.is_empty():
				_check(cart.order_id == order.id, "Loaded cart retains its production order")
				waited = line.pack_wip.quantity == 0.0 and line.packer.actual_rate == 0.0
				in_transit = Save.snapshot(line)
		if line.pack_dock != null and line.pack_dock.stock.quantity > 0.0 				and is_equal_approx(line.pack_wip.quantity, 8.0) and in_buffer.is_empty():
			_check(line.erp_pack_wip() == {"COATED-1001": 8.0}, "The physical packaging buffer posts stock at PACK-WIP")
			_check(not line.set_setting(&"pack_wip_capacity", 7.0), "Cannot reduce capacity below stock on hand")
			in_buffer = Save.snapshot(line)
		if line.erp.orders[order.id].status == "Completed":
			break
	_check(waited, "Packaging waits while the first loaded cart is travelling")
	_check(not in_buffer.is_empty(), "Small packaging buffer unloads only part of the cart")
	_check(is_equal_approx(line.warehouse_mass(), 65.0) and line.erp_wip().is_empty(),
		"Cart-fed order completes with its full mass and no residual WIP")
	var delivered := 0.0
	for movement in line.erp.movements:
		if movement.document == order.id and movement.to == "PACK-WIP":
			delivered += movement.qty
	_check(is_equal_approx(delivered, 65.0), "Coated cart unloading is posted once per delivered quantity")
	for snapshot in [in_transit, in_buffer]:
		if snapshot.is_empty():
			continue
		var restored := Save.restore(snapshot)
		_check(restored.error.is_empty(), "Restore the cart or WIP buffer during packaging")
		if restored.error.is_empty():
			var resumed: Line = restored.line
			resumed.set_playing(true)
			resumed.advance(line.elapsed_seconds() - resumed.elapsed_seconds())
			_check(Save.snapshot(resumed) == Save.snapshot(line), "Packaging restore preserves carts, WIP and the ledger")
	_check(not legacy.is_empty(), "Capture legacy outfeed migration fixture")
	if not legacy.is_empty():
		var migrated := Save.restore(legacy.snapshot)
		_check(migrated.error.is_empty(), "Load previous factory with coated stock already on the old conveyor")
		if migrated.error.is_empty():
			var refitted: Line = migrated.line
			_check(refitted.layout.grid.size == Line.Layout.DEFAULT_SIZE and refitted.pack_wip.quantity == 0.0,
				"Previous shift adopts the expanded factory and cart-fed WIP")
			_check(is_equal_approx(refitted.material_on_site(), legacy.mass),
				"Legacy ready and in-transit stock are conserved without double counting")
			refitted.set_playing(true)
			refitted.advance(1000.0)
			_check(is_equal_approx(refitted.warehouse_mass(), 65.0), "Refitted order finishes via the new carts")


func _legacy_outfeed_fixture(line: Line, order_id: String) -> Dictionary:
	var data := Save.snapshot(line)
	data.version = 2
	data.size = Vector2i(64, 26)
	data.layout = {"size": [64, 26], "objects": []}
	var outfeed: Dictionary = data.execution.runs[order_id].output
	data.execution.runs[order_id].ready = {"capacity": 12.0, "quantity": outfeed.quantity * 0.5}
	data.execution.runs[order_id].transfers = [[line.elapsed_ticks + 4, outfeed.quantity * 0.5]]
	data.stock.coated_input = outfeed
	data.stock.erase("pack_wip")
	data.carts = data.carts.filter(func(cart: Dictionary) -> bool: return not cart.body.coated)
	for actor in data.floor:
		var job: Array = data.jobs.get(actor.id, [])
		if not job.is_empty() and String(job[1]).begins_with("Coated"):
			data.jobs.erase(actor.id)
			actor.state = Line.Operator.State.IDLE
			actor._route.clear()
			if data.line._cart_route_owner == actor.id:
				data.line._cart_route_owner = &""
	var run: Dictionary = data.execution.runs[order_id]
	run.erase("outbound")
	run.erase("pack")
	return {"snapshot": data, "mass": line.material_on_site()}


func _legacy_execution() -> void:
	var line := Line.new()
	line.enable_erp(false)
	var order := line.erp.create_order("FG-1001", 8, 0, 1)
	if not order.error.is_empty() or not line.erp.release(order.id).is_empty():
		_check(false, "Create a legacy migration fixture")
		return
	line.set_playing(true)
	line.advance(25.0)
	var phase_three := Save.snapshot(line)
	phase_three.version = 1
	phase_three.erase("execution")
	phase_three.erase("layout")
	phase_three.erp.orders[order.id].erase("route")
	phase_three.erp.orders[order.id].erase("version")
	phase_three.erp.erase("feeder_id")
	phase_three.erp.erase("pack_id")
	for row in phase_three.carts:
		row.body.erase("order_id")
	for job in phase_three.jobs.values():
		job.resize(5)
	var migrated := Save.restore(phase_three)
	_check(migrated.error.is_empty(), "Migrate a Phase 3 order during production")
	if not migrated.error.is_empty():
		return
	var restored: Line = migrated.line
	_check(restored.erp.orders[order.id].version == "PHASE-3" and restored.order_at(&"Oven").id == order.id,
		"Legacy active order retains its original physical machine")
	var mass := restored.material_on_site()
	_check(is_equal_approx(mass, line.material_on_site()), "Legacy migration preserves in-flight stock")
	restored.set_playing(true)
	restored.advance(950.0)
	_check(restored.erp.orders[order.id].status == "Completed" and is_equal_approx(restored.warehouse_mass(), 40.0),
		"Migrated order resumes through warehouse delivery")
	var setup := restored.erp.create_order("FG-1001", 8, restored.erp.now, 1, "PV-1001-02")
	_check(setup.error.is_empty() and restored.erp.release(setup.id).is_empty(), "Release onto Coater 02")
	for tick in 4500:
		restored.advance(Line.STEP_SECONDS)
		if restored.erp.orders[setup.id].status == "Completed":
			break
	_check(restored.erp.transition(setup.id, "Closed").is_empty(), "Close an order before cart cleanup")
	restored.advance(20.0)
	_check(not restored.runs.has(setup.id), "Closed order releases its commitments")
	var alt := restored.erp.catalog.center_at(&"Coater02")
	alt.technical.setup_seconds = 25.0
	var next := restored.erp.create_order("FG-1003", 4, restored.erp.now, 1, "PV-1003-02")
	_check(next.error.is_empty() and restored.erp.release(next.id).is_empty(), "Release new SKU onto Coater 02")
	restored.advance(2.0)
	_check(restored.coaters[&"Coater02"].state == Line.Machine.State.SETUP
		and restored.coaters[&"Coater"].state == Line.Machine.State.IDLE,
		"Alternate coater applies its own changeover while the original coater stays idle")


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(contents)
	file.close()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
