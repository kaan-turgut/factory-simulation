extends RefCounted
## Versioned native snapshot. Restores authoritative quantities and in-flight jobs without replay.

const Line = preload("res://simulation/production_line.gd")
const PATH := "user://chocolate-works-erp.save"
const VERSION := 3
const LINE_FIELDS := ["elapsed_ticks", "multiplier", "ingredients_taken", "dispatched_kg",
	"dispatched_pallets", "boxes_completed", "raw_deliveries", "cooked_deliveries", "forklift_deliveries",
	"hopper_reserved", "warehouse_reserved_slot", "box_progress", "box_target", "_pending_seconds",
	"_cart_route_owner", "_lift_phase", "_lift_pickup_slot"]
const ACTOR_FIELDS := ["id", "title", "position", "previous_position", "heading", "state", "task",
	"destination", "remaining", "cargo_kg", "reserved_kg", "_route"]
const CART_FIELDS := ["id", "raw", "coated", "site", "home", "position", "previous_position", "heading", "owner", "order_id"]
const PALLET_FIELDS := ["target_boxes", "boxes", "mass", "id", "sku", "order_id", "tint", "sealed"]
const CATALOG_FIELDS := ["materials", "boms", "suppliers", "routings", "work_centers", "production_versions", "locations"]
const OVEN_FIELDS := ["state", "remaining", "batches", "owner"]
const MACHINE_FIELDS := ["configured_rate", "actual_rate", "state", "total_output"]
const STOCK_FIELDS := ["capacity", "quantity"]
const ERP_FIELDS := ["balances", "orders", "purchases", "demands", "reservations", "movements",
	"history", "day_output", "pending_events", "now", "sequence", "active_id", "last_product", "feeder_id", "pack_id",
	"coat_setup_seconds", "pack_setup_seconds", "coat_remaining", "pack_remaining", "shipment", "manual_shipments",
	"_next_sample", "_next_flush", "utilization", "delay_seconds"]


static func save(line: Line, path: String = PATH) -> String:
	if line.erp == null:
		return "No ERP shift is open."
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "Could not open the save location."
	file.store_var(snapshot(line), false)
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK:
		return "Could not write the save."
	result = DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"),
		ProjectSettings.globalize_path(path))
	return "" if result == OK else "Could not replace the previous save."


static func load_line(path: String = PATH) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "No saved shift found."}
	var data: Variant = file.get_var(false)
	file.close()
	if not data is Dictionary or data.get("version", -1) not in [1, 2, VERSION]:
		return {"error": "The save is invalid or uses an unsupported version."}
	return restore(data)


static func snapshot(line: Line) -> Dictionary:
	var plan := {}
	for id in line.layout.objects:
		var object := line.layout.objects[id]
		if object.movable:
			plan[id] = [object.cell, object.turns]
	var jobs := {}
	for owner in line.floor_assignments:
		var job := line.floor_assignments[owner]
		jobs[owner] = [job.kind, job.cart.id, job.site, job.point, job.title, job.run]
	var stock := {}
	for field in ["hopper", "cooked_input", "pack_wip"]:
		stock[field] = _fields(line.get(field), ["capacity", "quantity"])
	var machines := {}
	for field in ["extruder", "coater", "packer"]:
		machines[field] = _fields(line.get(field), ["configured_rate", "actual_rate", "state", "total_output"])
	var data := {
		"version": VERSION, "size": line.layout.grid.size, "plan": plan, "settings": line.settings,
		"layout": line.layout.snapshot(), "execution": _execution(line),
		"line": _fields(line, LINE_FIELDS), "stock": stock, "machines": machines,
		"oven": _fields(line.oven, ["state", "remaining", "batches", "owner"]),
		"oven_stock": _fields(line.oven.stock, ["capacity", "quantity"]),
		"platform": line.platform_crew.map(func(actor): return _fields(actor, ACTOR_FIELDS)),
		"floor": line.floor_crew.map(func(actor): return _fields(actor, ACTOR_FIELDS)),
		"forklift": _fields(line.forklift, ACTOR_FIELDS), "jobs": jobs,
		"carts": line.carts.map(func(cart): return {"body": _fields(cart, CART_FIELDS),
			"stock": _fields(cart.stock, ["capacity", "quantity"])}),
		"berths": [line.raw_at_extruder, line.raw_at_oven, line.cooked_at_oven, line.cooked_at_coater] \
			.map(func(cart): return cart.id if cart != null else &""),
		"staged": line.staged_pallets.map(_pallet_snapshot), "warehouse": line.warehouse.map(_pallet_snapshot),
		"load": _pallet_snapshot(line.lift_load), "erp": _fields(line.erp, ERP_FIELDS),
		"catalog": _fields(line.erp.catalog, CATALOG_FIELDS),
		"shuttle": _fields(line.erp.shuttle, ACTOR_FIELDS)
	}
	return data.duplicate(true)


static func restore(data: Dictionary) -> Dictionary:
	for key in ["size", "plan", "settings", "line", "stock", "machines", "oven", "oven_stock",
		"platform", "floor", "forklift", "jobs", "carts", "berths", "staged", "warehouse",
		"load", "erp", "catalog", "shuttle"]:
		if not data.has(key):
			return {"error": "The save is missing " + key + "."}
	if not data.erp is Dictionary or not data.erp.get("balances") is Dictionary \
			or not data.size is Vector2i or not data.plan is Dictionary:
		return {"error": "Invalid save structure."}
	for location in data.erp.balances.values():
		for qty in location.values():
			if not is_finite(float(qty)) or float(qty) < 0.0:
				return {"error": "Invalid stock in save."}
	var old: bool = data.version == 1
	var refit: bool = int(data.version) < VERSION
	if not old and (not data.get("layout") is Dictionary or not data.get("execution") is Dictionary
			or not data.catalog is Dictionary or not data.catalog.get("production_versions") is Dictionary):
		return {"error": "The save is missing routing or layout data."}
	var plan := Line.Layout.new() if refit else Line.Layout.new(data.size, "", data.layout)
	if not plan.error.is_empty():
		return {"error": plan.error}
	if not refit:
		for id in data.plan:
			if not plan.objects.has(id) or not plan.objects[id].movable:
				return {"error": "Unknown saved placement."}
			plan.objects[id] = plan.objects[id].at(data.plan[id][0], data.plan[id][1])
	var layout_error := plan.validate()
	if not layout_error.is_empty():
		return {"error": layout_error}
	var line := Line.new(plan)
	line.enable_erp()
	if not line.validation_error.is_empty():
		return {"error": line.validation_error}
	for key in data.settings:
		line.settings[key] = data.settings[key]
	_set_fields(line, data.line, LINE_FIELDS)
	for field in ["hopper", "cooked_input"]:
		_set_fields(line.get(field), data.stock[field], STOCK_FIELDS)
	if not refit:
		if not data.stock.get("pack_wip") is Dictionary:
			return {"error": "The save is missing packaging WIP."}
		_set_fields(line.pack_wip, data.stock.pack_wip, STOCK_FIELDS)
		if not is_finite(line.pack_wip.quantity) or line.pack_wip.quantity < 0.0 or line.pack_wip.quantity > line.pack_wip.capacity:
			return {"error": "Invalid packaging WIP balance in save."}
	for field in data.machines:
		_set_fields(line.get(field), data.machines[field], ["configured_rate", "actual_rate", "state", "total_output"])
	_set_fields(line.oven, data.oven, ["state", "remaining", "batches", "owner"])
	_set_fields(line.oven.stock, data.oven_stock, ["capacity", "quantity"])
	line.platform_crew.clear()
	line.floor_crew.clear()
	for row in data.platform:
		line.platform_crew.append(_actor(row))
	for row in data.floor:
		line.floor_crew.append(_actor(row))
	line.forklift = _actor(data.forklift)
	line.carts.clear()
	for row in data.carts:
		if refit and row.body.get("coated", false):
			continue
		var cart := Line.Cart.new(row.body.id, row.body.raw, row.stock.capacity, row.body.home)
		_set_fields(cart, row.body, CART_FIELDS)
		cart.stock.quantity = row.stock.quantity
		line.carts.append(cart)
	line.raw_at_extruder = line.find_cart(data.berths[0])
	line.raw_at_oven = line.find_cart(data.berths[1])
	line.cooked_at_oven = line.find_cart(data.berths[2])
	line.cooked_at_coater = line.find_cart(data.berths[3])
	for owner in data.jobs:
		var job: Array = data.jobs[owner]
		var task := Line.FloorJob.new(job[0], line.find_cart(job[1]), job[2], job[3], job[4])
		task.run = data.erp.active_id if old else job[5]
		line.floor_assignments[owner] = task
	line.staged_pallets.assign(data.staged.map(_pallet))
	line.warehouse.assign(data.warehouse.map(_pallet))
	line.lift_load = _pallet(data.load)
	var pack_location: String = line.erp.catalog.locations["PACK-WIP"]
	_set_fields(line.erp.catalog, data.catalog, ["materials", "boms", "suppliers"] if old else CATALOG_FIELDS)
	_set_fields(line.erp, data.erp, ERP_FIELDS)
	line.erp.shuttle = _actor(data.shuttle)
	if not line.erp.catalog.locations.has("PACK-WIP"):
		line.erp.catalog.locations["PACK-WIP"] = pack_location
	if line.pack_wip.quantity > Line.EPSILON and line.erp.pack_id.is_empty():
		return {"error": "Saved packaging WIP has no production order."}
	if old:
		_migrate_v1(line, float(data.stock.get("coated_input", {}).get("quantity", 0.0)))
	else:
		var error := _restore_execution(line, data.execution, refit)
		if not error.is_empty():
			return {"error": error}
	if refit:
		_refit_transport(line)
	line.set_playing(false)
	return {"error": "", "line": line, "refitted": refit}


static func _execution(line: Line) -> Dictionary:
	var ovens := {}
	for id in line.ovens:
		ovens[id] = [_fields(line.ovens[id], OVEN_FIELDS), _fields(line.ovens[id].stock, STOCK_FIELDS)]
	var coaters := {}
	for id in line.coaters:
		coaters[id] = [_fields(line.coaters[id], MACHINE_FIELDS), _fields(line.coater_inputs[id], STOCK_FIELDS)]
	var runs := {}
	for id in line.runs:
		var run: Dictionary = line.runs[id]
		runs[id] = {"output": _fields(run.output, STOCK_FIELDS), "setup": run.setup, "cycle": run.cycle, "fed": run.fed,
			"raw": run.raw.id if run.raw != null else &"", "cooked": run.cooked.id if run.cooked != null else &"",
			"intake": run.intake.id if run.intake != null else &"", "outbound": run.outbound.id if run.outbound != null else &"",
			"pack": run.pack.id if run.pack != null else &""}
	return {"ovens": ovens, "coaters": coaters, "runs": runs, "last_coatings": line.last_coatings,
		"pack_last_recipe": line.pack_last_recipe}


static func _restore_execution(line: Line, data: Dictionary, refit: bool) -> String:
	for field in ["ovens", "coaters", "runs", "last_coatings", "pack_last_recipe"]:
		if not data.get(field) is Dictionary:
			return "Invalid saved execution field " + field
	for id in data.ovens:
		if not line.ovens.has(id):
			return "Saved oven %s is missing. Restore its equipment definition." % id
		_set_fields(line.ovens[id], data.ovens[id][0], OVEN_FIELDS)
		_set_fields(line.ovens[id].stock, data.ovens[id][1], STOCK_FIELDS)
	for id in data.coaters:
		if not line.coaters.has(id):
			return "Saved coater %s is missing. Restore its equipment definition." % id
		_set_fields(line.coaters[id], data.coaters[id][0], MACHINE_FIELDS)
		_set_fields(line.coater_inputs[id], data.coaters[id][1], STOCK_FIELDS)
	line.last_coatings = data.last_coatings
	line.pack_last_recipe = data.pack_last_recipe
	for order in line.erp.orders.values():
		if order.status not in ["Released", "In Progress"]:
			continue
		var route: Dictionary = order.get("route", {})
		if not route.get("operations") is Array or route.operations.size() != 4:
			return "Missing saved routing for " + order.id
		for op in route.operations:
			if not op is Dictionary or not op.get("equipment") is String \
			or not line.layout.objects.has(StringName(op.equipment)):
				return "Saved route references missing equipment for " + order.id
	for id in data.runs:
		var order: Dictionary = line.erp.orders.get(id, {})
		if order.is_empty() or not order.has("route") or not order.route.get("operations") is Array or order.route.operations.size() != 4:
			return "Missing saved route for " + id
		if not line.ovens.has(StringName(order.route.operations[1].equipment)) \
			or not line.coaters.has(StringName(order.route.operations[2].equipment)):
			return "Saved route refers to missing equipment for " + id
		line._begin_route(order, true)
		var run: Dictionary = line.runs[id]
		var saved: Dictionary = data.runs[id]
		_set_fields(run.output, saved.output, STOCK_FIELDS)
		if refit:
			# The previous outfeed already counted material on the belt and at its infeed.
			run.output.capacity = maxf(Line.COATER_OUTFEED_KG, run.output.capacity)
		for key in ["setup", "cycle", "fed"]:
			run[key] = saved[key]
		for key in ["raw", "cooked", "intake", "outbound", "pack"]:
			run[key] = line.find_cart(saved.get(key, &""))
		if run.pack != null:
			if line.pack_dock != null:
				return "Saved routes claim the same packaging dock."
			line.pack_dock = run.pack
	for id in [line.erp.active_id, line.erp.feeder_id, line.erp.pack_id]:
		if not id.is_empty() and not line.runs.has(id):
			return "Saved commitment points to missing route " + id
	for task in line.floor_assignments.values():
		if not line.runs.has(task.run) or task.cart == null:
			return "Saved cart task points to missing route or cart."
	if line.runs.has(line.erp.active_id):
		line._open_run(line.erp.active_id)
		line._close_run()
	return ""


static func _migrate_v1(line: Line, coated_kg: float) -> void:
	var book := line.erp
	book.balances["COAT-IN-02"] = {}
	line.pack_last_recipe = book.last_product
	if not book.last_product.is_empty():
		line.last_coatings[&"Coater"] = book.last_product.coating
	var legacy := {"id": "WAFER-01", "version": 1, "description": "Phase 3 original equipment",
		"production_version": "PHASE-3", "operations": [
			{"number": 10, "type": "extrude", "equipment": "Extruder", "work_center": "WC-EXT-01",
				"description": "Extruder 01", "technical": {"rate": line.settings[&"extruder_rate"]}},
			{"number": 20, "type": "bake", "equipment": "Oven", "work_center": "WC-OVN-01", "description": "Oven 01",
				"technical": {"batch_kg": line.settings[&"batch_capacity"], "cycle_seconds": line.settings[&"cook_minutes"] * 60.0}},
			{"number": 30, "type": "coat", "equipment": "Coater", "work_center": "WC-COT-01", "description": "Coater 01",
				"supply_location": "COAT-IN", "technical": {"rate": line.settings[&"coater_rate"],
					"input_kg": line.settings[&"coater_input"], "setup_seconds": book.coat_setup_seconds}},
			{"number": 40, "type": "pack", "equipment": "Packer", "work_center": "WC-PKG-01", "description": "Packaging 01",
				"technical": {"rate": line.settings[&"packing_rate"], "setup_seconds": book.pack_setup_seconds}}
		]}
	for version in book.catalog.production_versions.values():
		if book.catalog.boms.has(version.product):
			version.bom_version = book.catalog.boms[version.product].version
	for order in book.orders.values():
		order.route = legacy.duplicate(true)
		order.route.bom_version = order.recipe.bom_version
		order.version = "PHASE-3"
		order.estimate = book.catalog.estimate(order.recipe, order.route)
		if order.status == "Created":
			var route := book.catalog.route_for(order.code, order.boxes, maxf(book.now, order.start))
			if route.error.is_empty():
				book._apply_route(order, route)
	var order: Dictionary = book.orders.get(book.active_id, {})
	if order.is_empty() and not line.floor_assignments.is_empty():
		# A Phase 3 shift could finish while an empty cart was returning.
		for candidate in book.orders.values():
			if candidate.status in ["Completed", "Closed"] \
			and (order.is_empty() or candidate.completed > order.completed):
				order = candidate
		if not order.is_empty():
			for task in line.floor_assignments.values():
				task.run = order.id
	if order.is_empty():
		return
	line._begin_route(order, true)
	var run: Dictionary = line.runs[order.id]
	run.output.quantity = coated_kg
	run.raw = line.raw_at_oven
	run.cooked = line.cooked_at_oven
	run.intake = line.cooked_at_coater
	run.setup = book.coat_remaining
	if order.status == "In Progress":
		book.feeder_id = order.id
		book.pack_id = order.id if order.packed < order.boxes else ""
	line.last_coatings[&"Coater"] = order.recipe.coating
	if book.pack_id.is_empty():
		line.pack_last_recipe = order.recipe
	for cart in line.carts:
		if cart.stock.quantity > Line.EPSILON:
			cart.order_id = order.id


static func _refit_transport(line: Line) -> void:
	var layout := line.layout
	for cart in line.carts:
		var index := int(String(cart.id).right(1)) - 1
		cart.home = layout.cart_home(index, cart.raw)
		var run := _legacy_cart_run(line, cart)
		# Rebase a moving cart to a safe bay, keeping its load, worker and reserved destination.
		if cart.site == Line.Cart.Site.TRANSIT:
			cart.site = Line.Cart.Site.PARKING
		cart.position = _legacy_cart_point(line, cart, cart.site, run)
		cart.previous_position = cart.position
		cart.heading = PI
	for index in line.floor_crew.size():
		var worker := line.floor_crew[index]
		var task: Line.FloorJob = line.floor_assignments.get(worker.id)
		_place_actor(worker, layout.crew_home(index))
		if task == null:
			worker.idle()
			continue
		if task.kind == Line.JobKind.MOVE_CART or worker.state == Line.Operator.State.WALKING:
			if task.kind == Line.JobKind.MOVE_CART:
				task.point = _legacy_cart_point(line, task.cart, task.site, line.runs.get(task.run, {}))
			else:
				task.point = task.cart.position
			worker.travel(layout.route(worker.position, task.cart.position, Line.Layout.WALK_LANE),
				Line.Operator.State.WALKING, task.title, Line.Cart.SITE_NAMES[task.cart.site])
		else:
			_place_actor(worker, task.cart.position)
	line._create_coated_carts()
	_refit_forklift(line)
	_refit_shuttle(line)


static func _legacy_cart_run(line: Line, cart: Line.Cart) -> Dictionary:
	var task: Line.FloorJob = line.floor_assignments.get(cart.owner)
	if task != null:
		return line.runs.get(task.run, {})
	for run in line.runs.values():
		if cart in [run.raw, run.cooked, run.intake]:
			return run
	return {}


static func _legacy_cart_point(line: Line, cart: Line.Cart, site: Line.Cart.Site, run: Dictionary) -> Vector3:
	match site:
		Line.Cart.Site.EXTRUDER:
			return line.layout.port(&"Extruder", &"raw_dock")
		Line.Cart.Site.OVEN_RAW:
			return line.layout.port(run.get("bake", &"Oven"), &"raw_dock")
		Line.Cart.Site.OVEN_COOKED:
			return line.layout.port(run.get("bake", &"Oven"), &"cooked_dock")
		Line.Cart.Site.COATER:
			return line.layout.port(run.get("coat", &"Coater"), &"cooked_dock")
	return cart.home


static func _refit_forklift(line: Line) -> void:
	var vehicle := line.forklift
	var layout := line.layout
	_place_actor(vehicle, layout.lift_home())
	match line._lift_phase:
		Line.LiftPhase.TO_PALLET:
			vehicle.travel(layout.route(vehicle.position, layout.pallet_approach(line._lift_pickup_slot), Line.Layout.LIFT_LANE),
				Line.Operator.State.DRIVING, vehicle.task, vehicle.destination)
		Line.LiftPhase.PICK_UP:
			_place_actor(vehicle, layout.pallet_approach(line._lift_pickup_slot))
		Line.LiftPhase.TO_STORAGE:
			vehicle.travel(layout.lift_to_slot(vehicle.position, line.warehouse_reserved_slot),
				Line.Operator.State.DRIVING, vehicle.task, vehicle.destination)
		Line.LiftPhase.DROP_OFF:
			_place_actor(vehicle, layout.warehouse_approach(line.warehouse_reserved_slot))
		Line.LiftPhase.RETURN:
			line._lift_phase = Line.LiftPhase.WAIT
			vehicle.idle()


static func _refit_shuttle(line: Line) -> void:
	var shuttle := line.erp.shuttle
	var layout := line.layout
	var shipment := line.erp.shipment
	_place_actor(shuttle, layout.supply_point("RM-WH"))
	if shipment.is_empty():
		shuttle.idle()
	elif shipment.phase == 2:
		_place_actor(shuttle, layout.supply_point(shipment.target))
	else:
		var dock := layout.supply_point(shipment.source if shipment.phase == 0 else shipment.target)
		shuttle.travel(layout.supply_route(shuttle.position, dock), Line.Operator.State.DRIVING,
			shuttle.task, shuttle.destination)


static func _place_actor(actor: Line.Operator, point: Vector3) -> void:
	actor.position = point
	actor.previous_position = point
	actor._route.clear()


static func _actor(data: Dictionary) -> Line.Operator:
	var actor := Line.Operator.new(data.id, data.title, data.position)
	_set_fields(actor, data, ACTOR_FIELDS)
	return actor


static func _pallet_snapshot(pallet: Line.Pallet) -> Dictionary:
	return {} if pallet == null else _fields(pallet, PALLET_FIELDS)


static func _pallet(data: Dictionary) -> Line.Pallet:
	if data.is_empty():
		return null
	var pallet := Line.Pallet.new(data.target_boxes)
	_set_fields(pallet, data, PALLET_FIELDS)
	return pallet


static func _fields(object: Object, fields: Array) -> Dictionary:
	var values := {}
	for field in fields:
		values[field] = object.get(field)
	return values


static func _set_fields(object: Object, data: Dictionary, fields: Array) -> void:
	for field in fields:
		if not data.has(field):
			continue
		if object.get(field) is Array:
			object.get(field).assign(data[field])
		else:
			object.set(field, data[field])
