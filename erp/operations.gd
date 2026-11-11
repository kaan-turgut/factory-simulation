extends RefCounted
## Stock ledger, documents and line execution policy. Physical WIP and FG remain in the line.

const Scheduling = preload("res://erp/scheduling.gd")
const Catalog = preload("res://erp/catalog.gd")
const Operator = preload("res://simulation/operator.gd")
const EPS := 1e-7
const RAW_LOCATIONS := ["RM-WH", "RM-STAGE", "COAT-IN", "COAT-IN-02", "PACK-IN", "TRANSIT"]
const SFG_LOCATIONS := ["SFG-WH", "SFG-DECK"]
const OPEN := ["Created", "Released", "In Progress"]
const LINE := "LINE-01"

var explicit_planning := true
var auto_release := false
var planning_conversions := {}
var dispatch_queue := {}
var catalog := Catalog.new()
var balances := {}
var orders := {}
var purchases := {}
var demands := {}
var reservations := {}
var movements: Array[Dictionary] = []
var history: Array[Dictionary] = []
var day_output := {}
var pending_events := {}
var now := 0.0
var revision := 0
var schedule_revision := 0
var warehouse_revision := 0
var sequence := 0
var active_id := ""
var scope_id := ""
var feeder_id := ""
var pack_id := ""
var last_product := {}
var coat_setup_seconds := 600.0
var pack_setup_seconds := 300.0
var coat_remaining := 0.0
var pack_remaining := 0.0
var shuttle: Operator
var shipment := {}
var manual_shipments: Array[Dictionary] = []
var _next_sample := 60.0
var _next_flush := 15.0
var _auto_release_checked := -1
var utilization := {"Extruder": 0.0, "Coater": 0.0, "Coater02": 0.0, "Packer": 0.0}
var delay_seconds := 0.0
var warning := ""


func _init() -> void:
	for location in RAW_LOCATIONS + SFG_LOCATIONS:
		balances[location] = {}
	if not catalog.error.is_empty():
		return
	for center in catalog.work_centers.values():
		if center.equipment == "Coater":
			coat_setup_seconds = center.technical.setup_seconds
		elif center.equipment == "Packer":
			pack_setup_seconds = center.technical.setup_seconds
	for code in catalog.opening:
		_post(code, catalog.opening[code], "", "RM-WH", "Opening", "", "Demonstration opening stock")


func changed() -> void:
	revision += 1


func _id(prefix: String) -> String:
	sequence += 1
	return "%s-%05d" % [prefix, sequence]


func stock(code: String, location: String) -> float:
	return float(balances.get(location, {}).get(code, 0.0))


func total_stock(code: String) -> float:
	var total := 0.0
	for location in RAW_LOCATIONS + SFG_LOCATIONS:
		total += stock(code, location)
	return total


func available(code: String) -> float:
	return maxf(0.0, total_stock(code) - float(reservations.get(code, 0.0)))


func _post(code: String, qty: float, source: String, target: String, kind: String,
		document: String, reason: String) -> void:
	if source == "RM-WH" or target == "RM-WH":
		warehouse_revision += 1
	if balances.has(source):
		balances[source][code] = maxf(0.0, stock(code, source) - qty)
	if balances.has(target):
		balances[target][code] = stock(code, target) + qty
	_record(code, qty, source, target, kind, document, reason)
	changed()


func _record(code: String, qty: float, source: String, target: String, kind: String,
		document: String, reason: String) -> void:
	movements.append({"id": _id("GM"), "time": now, "last": now, "code": code, "qty": qty,
		"unit": catalog.materials[code].unit, "from": source, "to": target, "type": kind,
		"document": document, "reason": reason})


func flow(code: String, qty: float, source: String, target: String, kind: String, reason: String) -> void:
	if qty <= EPS:
		return
	var key := "%s|%s|%s|%s|%s|%s" % [active().get("id", ""), code, source, target, kind, reason]
	if not pending_events.has(key):
		pending_events[key] = {"id": _id("GM"), "time": now, "last": now, "code": code, "qty": 0.0,
			"unit": catalog.materials[code].unit, "from": source, "to": target, "type": kind,
			"document": active().get("id", ""), "reason": reason}
	pending_events[key].qty += qty
	pending_events[key].last = now
	changed()


func flush_flows() -> void:
	for row in pending_events.values():
		movements.append(row)
	pending_events.clear()


func journal(limit: int = 200) -> Array:
	var records: Array = movements.slice(maxi(0, movements.size() - limit))
	records.append_array(pending_events.values())
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.id.get_slice("-", 1)) > int(b.id.get_slice("-", 1)))
	return records.slice(0, limit)


func manual_transfer(code: String, qty: float, source: String, target: String, reason: String) -> String:
	if not _quantity(code, qty) or source == target or reason.strip_edges().is_empty() \
			or not (source in ["RM-WH", "RM-STAGE"] and target in ["RM-WH", "RM-STAGE"]):
		return "Choose a valid external material, two locations, a quantity and a reason."
	if target == "RM-STAGE" and catalog.materials[code].type != "ROH":
		return "The mezzanine holds raw ingredients."
	if minf(stock(code, source) - _planned_pickups(code, source), available(code)) + EPS < qty:
		return "Insufficient unreserved stock."
	reservations[code] = float(reservations.get(code, 0.0)) + qty
	manual_shipments.append({"source": source, "target": target, "items": {code: qty},
		"order": _id("TR"), "reason": reason, "manual": true})
	changed()
	return ""


func adjust(code: String, qty: float, reason: String) -> String:
	if not _quantity(code, absf(qty)) or reason.strip_edges().is_empty():
		return "Choose an external material, nonzero adjustment and reason."
	if qty < 0 and -qty > minf(stock(code, "RM-WH") - _planned_pickups(code, "RM-WH"), available(code)) + EPS:
		return "Adjustment would consume reserved stock or make stock negative."
	_post(code, absf(qty), "RM-WH" if qty < 0 else "", "RM-WH" if qty > 0 else "",
		"Adjustment", _id("ADJ"), reason)
	return ""


func _planned_pickups(code: String, location: String) -> float:
	var amount := 0.0
	for task in manual_shipments:
		if task.source == location:
			amount += float(task.items.get(code, 0.0))
	if not shipment.is_empty() and shipment.phase <= 0 and shipment.source == location:
		amount += float(shipment.items.get(code, 0.0))
	return amount


func _quantity(code: String, qty: float) -> bool:
	return catalog.materials.has(code) and catalog.materials[code].procurement == "External" \
		and is_finite(qty) and qty > EPS and (catalog.materials[code].unit != "ea" or absf(qty - roundf(qty)) < EPS)


func create_order(code: String, quantity: float, start: float, priority: int, version: String = "") -> Dictionary:
	if explicit_planning:
		return Scheduling.create(self, code, quantity, start, priority, version)
	var boxes := int(quantity)
	if not is_finite(start) or start < 0.0 or boxes > 100000:
		return {"error": "Invalid planned time or quantity."}
	var recipe := catalog.recipe(code, boxes)
	if not recipe.error.is_empty():
		return recipe
	var route := catalog.route_for(code, boxes, maxf(start, now), version)
	if not route.error.is_empty():
		return route
	var id := _id("MO")
	orders[id] = {"id": id, "code": code, "boxes": boxes, "unit": "box", "start": start,
		"finish": start, "line": LINE, "priority": clampi(priority, 1, 9),
		"status": "Created", "recipe": recipe, "remaining": {}, "consumed": {},
		"dough_issued": 0.0, "packed": 0, "received": 0, "received_kg": 0.0,
		"started": -1.0, "completed": -1.0, "warning": ""}
	_apply_route(orders[id], route)
	changed()
	return {"error": "", "id": id}


func select_version(id: String, version: String) -> String:
	var order: Dictionary = orders.get(id, {})
	if order.is_empty() or order.status != "Created":
		return "Select a created order."
	if order.has("stage"):
		return reschedule(id, maxf(now, order.start), version)
	var route := catalog.route_for(order.code, order.boxes, maxf(now, order.start), version)
	if not route.error.is_empty():
		return route.error
	var recipe := catalog.recipe(order.code, order.boxes)
	if not recipe.error.is_empty():
		return recipe.error
	order.recipe = recipe
	_apply_route(order, route)
	changed()
	return ""


func reschedule(id: String, start: float, version: String = "") -> String:
	return Scheduling.reschedule(self, id, start, version)


func _apply_route(order: Dictionary, route: Dictionary) -> void:
	order.route = route
	order.version = route.production_version
	order.estimate = catalog.estimate(order.recipe, route)
	order.finish = order.start + maxf(float(order.recipe.spec.lead), order.estimate + 120.0)


func component_available(order: Dictionary, code: String) -> float:
	if not order.has("stage"):
		return available(code)
	var locations := ["RM-WH", "RM-STAGE"]
	match order.stage:
		"extrude":
			locations = ["SFG-DECK"]
		"bake":
			locations = ["SFG-WH"]
		"coat":
			locations = ["SFG-WH"] if code == order.recipe.input else ["RM-WH", order.route.operations[0].supply_location]
		"pack":
			locations = ["SFG-WH"] if code == order.recipe.input else ["RM-WH", "PACK-IN"]
	var accessible := 0.0
	for location in locations:
		accessible += stock(code, location)
	return maxf(0.0, accessible - float(reservations.get(code, 0.0)))


func shortages(order: Dictionary) -> Dictionary:
	var missing := {}
	for code in order.recipe.needs:
		var gap := float(order.recipe.needs[code]) - component_available(order, code)
		if gap > EPS:
			missing[code] = gap
	return missing


func release(id: String) -> String:
	var order: Dictionary = orders.get(id, {})
	if order.is_empty() or order.status != "Created":
		return "Only a created order can be released."
	for code in order.recipe.needs:
		if not catalog.materials[code].active:
			return "Inactive component " + code
	if not catalog.materials[order.code].active:
		return "The manufactured material is inactive."
	if order.has("stage"):
		return _release_stage(order)
	if explicit_planning:
		return "This legacy order uses the old combined route. Cancel it and schedule independent stages."
	var route := catalog.route_for(order.code, order.boxes, maxf(now, order.start), order.get("version", ""))
	if not route.error.is_empty():
		return route.error
	if route.bom_version != order.recipe.bom_version:
		return "BOM changed. Select a production version again to confirm the updated recipe."
	for operation in route.operations:
		if operation.equipment == "Coater":
			operation.technical.setup_seconds = coat_setup_seconds
		elif operation.type == "pack":
			operation.technical.setup_seconds = pack_setup_seconds
	var missing := shortages(order)
	if not missing.is_empty():
		order.warning = "Missing " + ", ".join(PackedStringArray(missing.keys()))
		changed()
		return order.warning
	_apply_route(order, route)
	order.remaining = order.recipe.needs.duplicate()
	for code in order.remaining:
		reservations[code] = float(reservations.get(code, 0.0)) + float(order.remaining[code])
	order.status = "Released"
	order.warning = ""
	changed()
	return ""


func _release_stage(order: Dictionary) -> String:
	var assignment := Scheduling.assignment(self, order.code, order.quantity, order.start, order.version)
	if not assignment.error.is_empty():
		return assignment.error
	if assignment.recipe.bom_snapshot != order.recipe.bom_snapshot or assignment.route != order.route:
		return "BOM or routing changed. Confirm the production version again."
	var conflict := Scheduling.conflict(self, order.center, order.start, order.finish, order.id)
	if not conflict.is_empty():
		return conflict
	var missing := shortages(order)
	if not missing.is_empty():
		var reasons := PackedStringArray()
		for code in missing:
			reasons.append("%s %.3f %s required, %.3f available, %.3f short" % [
				code, order.recipe.needs[code], catalog.materials[code].unit, component_available(order, code), missing[code]])
		order.warning = ", ".join(reasons)
		changed()
		return order.warning
	order.recipe = order.recipe.duplicate(true)
	order.route = order.route.duplicate(true)
	order.remaining = order.recipe.needs.duplicate()
	for code in order.remaining:
		reservations[code] = float(reservations.get(code, 0.0)) + float(order.remaining[code])
	order.released_quantity = order.quantity
	order.status = "Released"
	dispatch_queue[order.id] = true
	order.erase("auto_release_error")
	order.warning = ""
	changed()
	return ""


func _auto_release_orders() -> void:
	var ready: Array[Dictionary] = []
	for order in orders.values():
		if order.status == "Created" and order.has("stage") and shortages(order).is_empty():
			ready.append(order)
	ready.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.start != b.start:
			return a.start < b.start
		return a.priority < b.priority if a.priority != b.priority else a.id < b.id)
	for order in ready:
		var problem := release(order.id)
		if not problem.is_empty() and problem != String(order.get("auto_release_error", "")):
			order.auto_release_error = problem
			changed()


func receive_stage(order: Dictionary, quantity: float) -> void:
	var location: String = order.recipe.spec.location
	flush_flows()
	_post(order.code, quantity, "WIP", location, "SFG Receipt", order.id, "Stage output received")
	order.received_kg += quantity
	order.received = order.received_kg
	if order.received_kg + EPS >= order.recipe.target:
		_release_remainder(order)
		order.status = "Completed"
		order.completed = now
		order.delay = ""
	changed()


func transition(id: String, status: String) -> String:
	var order: Dictionary = orders.get(id, {})
	if order.is_empty():
		return "Order does not exist."
	if status == "Cancelled" and order.status in ["Created", "Released"]:
		dispatch_queue.erase(id)
		_release_remainder(order)
		var demand: Dictionary = demands.get(order.get("demand", ""), {})
		if not demand.is_empty():
			if demand.has("converted_orders"):
				demand.converted_orders.erase(id)
			if demand.converted == id:
				demand.converted = ""
	elif status != "Closed" or order.status != "Completed":
		return "Invalid order transition. In-progress orders must finish."
	order.status = status
	schedule_revision += 1
	changed()
	return ""


func prioritize(id: String, priority: int) -> String:
	var order: Dictionary = orders.get(id, {})
	if order.is_empty() or order.status not in ["Created", "Released"]:
		return "Priority is available for pending orders."
	order.priority = clampi(priority, 1, 9)
	changed()
	return ""


func create_demand(code: String, boxes: int, due: float) -> Dictionary:
	if not is_finite(due) or due < 0.0 or boxes > 100000:
		return {"error": "Invalid requirement date or quantity."}
	var recipe := Scheduling.recipe(catalog, code, boxes) if explicit_planning else catalog.recipe(code, boxes)
	if not recipe.error.is_empty():
		return recipe
	var id := _id("DEM")
	demands[id] = {"id": id, "code": code, "boxes": boxes, "due": due, "converted": "", "recipe": recipe}
	changed()
	return {"error": "", "id": id}


func purchase(supplier_id: String, code: String, qty: float) -> Dictionary:
	var supplier: Dictionary = catalog.suppliers.get(supplier_id, {})
	if not _quantity(code, qty) or not catalog.materials[code].active \
			or supplier.is_empty() or code not in supplier.codes or qty + EPS < supplier.minimum:
		return {"error": "Check supplier, material, base unit and minimum order quantity."}
	var id := _id("PO")
	purchases[id] = {"id": id, "supplier": supplier_id, "code": code, "qty": qty, "received": 0.0,
		"due": now + maxf(supplier.lead, catalog.materials[code].lead), "status": "Open",
		"price": supplier.price}
	changed()
	return {"error": "", "id": id}


func receive(id: String, qty: float) -> String:
	var po: Dictionary = purchases.get(id, {})
	if po.is_empty() or po.status == "Received" or now + EPS < po.due \
			or not _quantity(po.code, qty) or qty > po.qty - po.received + EPS:
		return "Receipt is early, already complete, or outside the open quantity."
	qty = minf(qty, po.qty - po.received)
	po.received += qty
	po.status = "Received" if po.received + EPS >= po.qty else "Partial"
	_post(po.code, qty, "", "RM-WH", "PO Receipt", id, "Supplier delivery")
	return ""


func active() -> Dictionary:
	return orders.get(scope_id if not scope_id.is_empty() else active_id, {})


func clock(seconds: float) -> void:
	now = seconds
	# Check scheduled receipts and optional release once per simulated second.
	if fposmod(seconds, 1.0) < EPS:
		for po in purchases.values():
			if po.status != "Received" and po.due <= now:
				receive(po.id, po.qty - po.received)
		if explicit_planning and auto_release and revision != _auto_release_checked:
			_auto_release_orders()
			_auto_release_checked = revision
	if now >= _next_flush:
		flush_flows()
		_next_flush = now + 15.0


func sample_kpis(line, seconds: float) -> void:
	if line.extruder.actual_rate > EPS:
		utilization.Extruder += seconds
	if line.packer.actual_rate > EPS:
		utilization.Packer += seconds
	for id in line.coaters:
		if line.coaters[id].actual_rate > EPS:
			var name := String(id)
			utilization[name] = float(utilization.get(name, 0.0)) + seconds
	for id in line.ovens:
		if line.ovens[id].state == line.Oven.State.COOKING:
			utilization[String(id)] = float(utilization.get(String(id), 0.0)) + seconds
	if explicit_planning and line.platform_crew.any(func(worker: Operator) -> bool:
		return worker.state == Operator.State.UNLOADING) and orders.get(feeder_id, {}).get("stage") == "mix":
		utilization.Hopper = float(utilization.get("Hopper", 0.0)) + seconds
	if now < _next_sample:
		return
	var short_orders := 0
	for order in orders.values():
		if order.status == "Created" and order.start <= now and not shortages(order).is_empty():
			short_orders += 1
			if order.has("stage"):
				order.material_wait_seconds += minf(60.0, now - order.start)
	if short_orders > 0 and active_id.is_empty():
		delay_seconds += 60.0
	history.append({"time": now, "kg": today_kg(), "warehouse": line.warehouse_mass(),
		"order": active_id, "shortages": short_orders, "delay": delay_seconds})
	_next_sample = now + 60.0
	changed()


func today_kg() -> float:
	return float(day_output.get(floori(now / 86400.0), 0.0))


func feed_limit(waiting: float) -> float:
	var order := active()
	if order.is_empty():
		return 0.0
	var capacity := float(order.recipe.dough_target) - float(order.dough_issued)
	if order.get("stage") == "extrude":
		return maxf(0.0, minf(capacity, stock(order.recipe.input, "SFG-DECK")) - waiting)
	for code in order.recipe.mix:
		var staged := stock(code, "RM-STAGE") - _planned_pickups(code, "RM-STAGE")
		capacity = minf(capacity, staged / float(order.recipe.mix[code]))
	return maxf(0.0, capacity - waiting)


func issue_dough(kg: float) -> bool:
	var order := active()
	if order.is_empty() or feed_limit(0.0) + EPS < kg:
		return false
	if order.get("stage") == "extrude":
		_consume(order, order.recipe.input, kg, "SFG-DECK", "Feed prepared dough")
	else:
		for code in order.recipe.mix:
			_consume(order, code, kg * order.recipe.mix[code], "RM-STAGE", "Dough blend")
	order.dough_issued += kg
	if not order.has("stage"):
		flow(order.recipe.dough, kg, "", "WIP", "SFG Receipt", "Mixed dough sack")
	elif order.stage == "mix":
		flow(order.code, kg, "", "WIP", "WIP Produced", "Mixed dough sack")
	return true


func dough_finished() -> bool:
	var order := active()
	return not order.is_empty() and order.dough_issued + EPS >= order.recipe.dough_target


func coating_limit() -> float:
	var order := active()
	return stock(order.recipe.coating, order.route.operations[0 if order.has("stage") else 2].supply_location) / order.recipe.coat_rate if not order.is_empty() else 0.0


func coat(kg: float) -> void:
	var order := active()
	_consume(order, order.recipe.coating, kg * order.recipe.coat_rate, order.route.operations[0 if order.has("stage") else 2].supply_location, "Coating input")


func can_pack(pallet_needed: bool) -> bool:
	var order := active()
	if order.is_empty() or order.packed >= order.boxes:
		return false
	for code in order.recipe.packaging:
		if stock(code, "PACK-IN") < 1.0 - EPS:
			return false
	return not pallet_needed or stock("PK-PALLET", "PACK-IN") >= 1.0 - EPS


func pack_box(new_pallet: bool) -> bool:
	var order := active()
	for code in order.recipe.packaging:
		_consume(order, code, 1.0, "PACK-IN", "Carton formed")
	if new_pallet:
		_consume(order, "PK-PALLET", 1.0, "PACK-IN", "Pallet opened")
	order.packed += 1
	changed()
	return order.packed == order.boxes


func _consume(order: Dictionary, code: String, qty: float, source: String, reason: String) -> void:
	balances[source][code] = maxf(0.0, stock(code, source) - qty)
	order.remaining[code] = maxf(0.0, float(order.remaining[code]) - qty)
	reservations[code] = maxf(0.0, float(reservations[code]) - qty)
	order.consumed[code] = float(order.consumed.get(code, 0.0)) + qty
	flow(code, qty, source, "", "Consumption", reason)


func receive_pallet(pallet) -> void:
	var order: Dictionary = orders[pallet.order_id]
	flush_flows()
	_record(pallet.sku, pallet.mass, "WIP", "FG-WH", "FG Receipt", pallet.order_id,
		"%d cartons received on %s" % [pallet.boxes, pallet.id])
	order.received += pallet.boxes
	order.received_kg += pallet.mass
	var day := floori(now / 86400.0)
	day_output[day] = float(day_output.get(day, 0.0)) + pallet.mass
	if order.received == order.boxes:
		_release_remainder(order)
		order.status = "Completed"
		order.completed = now
		if order.has("stage"):
			order.delay = ""
		last_product = order.recipe
	changed()


func ship(pallet) -> void:
	var order: Dictionary = orders[pallet.order_id]
	order.dispatched_kg = float(order.get("dispatched_kg", 0.0)) + pallet.mass
	_record(pallet.sku, pallet.mass, "FG-WH", "", "Dispatch", pallet.order_id, pallet.id)
	changed()


func _release_remainder(order: Dictionary) -> void:
	for code in order.remaining:
		reservations[code] = maxf(0.0, float(reservations[code]) - float(order.remaining[code]))
	order.remaining.clear()


func initialize_supply(layout) -> void:
	shuttle = Operator.new(&"SupplyShuttle", "Material shuttle", layout.supply_point("RM-WH"))


func supply_tick(layout, seconds: float, sack: float, running: Array) -> void:
	shuttle.advance(seconds, 4.0)
	if not shuttle.finished():
		return
	if shipment.is_empty():
		if not manual_shipments.is_empty():
			shipment = manual_shipments.pop_front()
		elif fposmod(now, 1.0) < EPS and not active_id.is_empty():
			for id in running:
				var order: Dictionary = orders[id]
				if order.status != "In Progress":
					continue
				shipment = _supply_request(order, sack)
				if not shipment.is_empty():
					break
		if shipment.is_empty():
			return
		shipment.phase = -1
	if shipment.phase == -1:
		var pickup: Vector3 = layout.supply_point(shipment.source)
		var path: Array[Vector3] = layout.supply_route(shuttle.position, pickup)
		if path.is_empty() and not shuttle.position.is_equal_approx(pickup):
			return
		shipment.phase = 0
		shuttle.travel(path, Operator.State.DRIVING, "Collect supplies", catalog.locations[shipment.source])
	elif shipment.phase == 0:
		for code in shipment.items:
			# Recheck the source before creating in-transit stock.
			if stock(code, shipment.source) + EPS < shipment.items[code]:
				if shipment.get("manual", false):
					_release_manual_shipment()
				warning = "Shuttle pickup short at " + shipment.source
				shipment.clear()
				shuttle.idle()
				changed()
				return
		var destination: Vector3 = layout.supply_point(shipment.target)
		var path: Array[Vector3] = layout.supply_route(shuttle.position, destination)
		if path.is_empty() and not shuttle.position.is_equal_approx(destination):
			return
		for code in shipment.items:
			_post(code, shipment.items[code], shipment.source, "TRANSIT", "Transfer", shipment.order, "Shuttle pickup")
		shipment.phase = 1
		shuttle.travel(path, Operator.State.DRIVING, "Deliver supplies", catalog.locations[shipment.target])
	elif shipment.phase == 1:
		shipment.phase = 2
		shuttle.work(5.0 if shipment.target == "RM-STAGE" else 2.0, Operator.State.UNLOADING)
	else:
		for code in shipment.items:
			var reason := String(shipment.get("reason", "Freight lift to mezzanine" if shipment.target == "RM-STAGE"
				else "Supplies delivered to station"))
			_post(code, shipment.items[code], "TRANSIT", shipment.target, "Transfer", shipment.order, reason)
		if shipment.get("manual", false):
			_release_manual_shipment()
		shipment.clear()
		shuttle.idle()


func _release_manual_shipment() -> void:
	for code in shipment.items:
		reservations[code] = maxf(0.0, float(reservations[code]) - float(shipment.items[code]))


func _supply_request(order: Dictionary, sack: float) -> Dictionary:
	var recipe: Dictionary = order.recipe
	var mixture := {}
	for code in recipe.mix:
		mixture[code] = recipe.mix[code] * maxf(100.0, sack * 2.0)
	var pack := {"PK-PALLET": 5.0}
	for code in recipe.packaging:
		pack[code] = 32.0
	var groups := []
	if not order.has("stage") or order.stage == "coat":
		groups.append([order.route.operations[0 if order.has("stage") else 2].supply_location, {recipe.coating: 48.0}])
	if order.id == feeder_id and not mixture.is_empty():
		groups.push_front(["RM-STAGE", mixture])
	if order.id == pack_id:
		groups.append(["PACK-IN", pack])
	for group in groups:
		var location: String = group[0]
		var items := {}
		for code in group[1]:
			var on_hand := stock(code, location)
			var desired := minf(float(order.remaining.get(code, 0.0)), float(group[1][code]))
			var threshold := desired * 0.55
			if location == "RM-STAGE":
				threshold = minf(desired, recipe.mix[code] * sack * 1.1)
			if on_hand + EPS >= threshold:
				continue
			var amount := minf(stock(code, "RM-WH"), desired - on_hand)
			if amount > EPS:
				items[code] = amount
		if not items.is_empty():
			return {"source": "RM-WH", "target": location, "items": items, "order": order.id}
	return {}


static func date(seconds: float) -> String:
	var t := maxi(0, floori(seconds))
	return "D%d %02d:%02d:%02d" % [1 + floori(t / 86400.0), floori(t / 3600.0) % 24,
		floori(t / 60.0) % 60, t % 60]
