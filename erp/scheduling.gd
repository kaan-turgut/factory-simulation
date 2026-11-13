extends RefCounted
## Finite scheduling and immediate-BOM orders. Physical stock remains in the ERP ledger.
const EPS := 0.000001
const DAY := 86400.0
const MAX_DAYS := 366


static func stage_for(catalog, code: String) -> String:
	var item: Dictionary = catalog.materials.get(code, {})
	if item.is_empty() or not item.active:
		return ""
	for stage in catalog.scheduling.stages:
		var products: Array = catalog.scheduling.stages[stage].materials
		if code in products or (item.type == "FERT" and "FERT" in products):
			return stage
	return ""


static func alternatives(catalog, code: String, quantity: float, when: float) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var stage := stage_for(catalog, code)
	if stage.is_empty() or not is_finite(quantity) or quantity <= EPS:
		return rows
	var bom: Dictionary = catalog.boms.get(code, {})
	if bom.is_empty() or not bom.active:
		return rows
	for version in catalog.production_versions.values():
		if version.product != code or not catalog._in_effect(version, when) or quantity < version.min_quantity or quantity > version.max_quantity \
				or version.bom_version != bom.version:
			continue
		var route: Dictionary = catalog.routings[version.routing]
		if not catalog._in_effect(route, when) or route.get("legacy_only", false):
			continue
		var operation: Dictionary = route.operations.back().duplicate(true)
		if route.operations.size() != 1 and stage != "pack":
			continue
		var center: Dictionary = catalog.work_centers[operation.work_center]
		if center.operation != stage or code not in center.get("materials", []):
			continue
		operation.merge({"equipment": center.equipment, "description": center.description,
			"available": center.available, "supply_location": center.get("supply_location", ""),
			"input_port": center.get("input_port", ""), "output_port": center.get("output_port", ""),
			"technical": center.technical.duplicate(true)}, true)
		var resolved: Dictionary = catalog.Standards.resolve(catalog, code, operation, when, route.id, version.id)
		if resolved.error.is_empty():
			operation.standard = resolved.standard
			var std: Dictionary = resolved.standard
			operation.technical.merge({"setup_seconds": std.setup_seconds}, true)
			if std.model == "batch":
				operation.technical.merge({"batch_kg": std.batch_kg, "cycle_seconds": std.cycle_seconds}, true)
			else:
				operation.technical.design_rate = operation.technical.rate
				operation.technical.rate = catalog.Standards.kg_per_hour(std, catalog.materials[code])
		else:
			operation.available = false
			operation.standard_error = resolved.error
		rows.append({"id": route.id, "version": route.version, "description": route.description,
			"production_version": version.id, "bom_version": bom.version, "error": "", "operations": [operation]})
	return rows

static func recipe(catalog, code: String, quantity: float) -> Dictionary:
	var stage := stage_for(catalog, code)
	if stage.is_empty() or not is_finite(quantity) or quantity <= EPS or quantity > 100000.0:
		return {"error": "Choose an active manufactured material and a quantity above zero, up to 100,000."}
	var bom: Dictionary = catalog.boms.get(code, {})
	if bom.is_empty() or not bom.active:
		return {"error": "No active BOM for " + code}
	var spec: Dictionary = catalog.materials[code].duplicate(true)
	var result := {"error": "", "stage": stage, "target": quantity, "spec": spec, "needs": {},
		"mix": {}, "mass_inputs": {}, "internals": [], "dough_target": quantity, "packaging": [], "bom_version": bom.version,
		"bom_snapshot": {code: bom.duplicate(true)}}
	if stage == "pack":
		if not is_equal_approx(quantity, roundf(quantity)):
			return {"error": "Packaging quantities must be whole shipping boxes."}
		# Keep packaging specifications and rounding independent of upstream BOM availability.
		result.target = quantity * spec.box_kg

	var rates: Dictionary = catalog._rates(code)
	var internal := ""
	var mass_rate := 0.0
	for child in rates:
		var component: Dictionary = catalog.materials[child]
		if not component.active:
			return {"error": "Inactive component " + child}
		var amount := float(rates[child]) * float(result.target)
		result.needs[child] = ceilf(amount - EPS) if component.unit == "ea" else amount
		if component.unit == "kg":
			mass_rate += float(rates[child])
			result.mass_inputs[child] = rates[child]
		if component.procurement == "In-house":
			result.internals.append(child)
			if internal.is_empty():
				internal = child
		elif stage in catalog.PREPARATION_STAGES:
			result.mix[child] = rates[child]
		elif stage == "coat":
			result.coating = child
			result.coat_rate = rates[child]
	if not is_equal_approx(mass_rate, 1.0):
		return {"error": "The stage BOM must conserve food mass."}
	result.input = internal
	if stage in catalog.PREPARATION_STAGES and (not internal.is_empty() or result.mix.size() != rates.size()):
		return {"error": "Ingredient preparation requires external kilogram inputs."}
	if stage in catalog.SINGLE_INPUT_STAGES and (rates.size() != 1 or internal.is_empty()):
		return {"error": "This operation needs one kilogram input."}
	if stage == "gum_coat" and (result.internals.size() != 1 or rates.size() < 2 or result.mass_inputs.size() != rates.size()):
		return {"error": "Pan coating needs one gum centre material and kilogram coating supplies."}
	if stage == "spread" and (result.internals.size() != 2 or rates.size() != 2):
		return {"error": "Sandwiching requires a wafer material and a cream material."}
	if stage == "coat":
		if rates.size() != 2 or internal.is_empty() or not result.has("coating"):
			return {"error": "Coating needs baked wafers and one coating material."}
		result.baked = internal
		result.baked_rate = rates[internal]
		result.coated = code
	if stage == "pack":
		var packaging: Dictionary = catalog.packing_components(spec, rates)
		if result.internals.size() != 1 or packaging.is_empty() or rates.size() != packaging.size() + 2 \
				or not is_equal_approx(float(rates[internal]), 1.0):
			return {"error": "Packaging needs one wafer input and quantities that match the packs, carton, label and pallet specifications."}
		result.packaging = packaging.keys()
		result.packaging_per_box = packaging
		result.coated = internal
	return result


static func duration(catalog, recipe_data: Dictionary, operation: Dictionary) -> float:
	if not operation.has("standard"):
		return INF
	var stage: Dictionary = catalog.scheduling.stages[operation.type]
	var standard: Dictionary = operation.standard
	var handling := float(stage.handling_seconds) + float(stage.get("handling_seconds_per_kg", 0.0)) * float(recipe_data.target)
	if standard.model == "batch":
		var batches: int = catalog.Standards.batch_count(standard, recipe_data.target)
		handling += batches * float(stage.get("batch_handling_seconds", 0.0))
	return ceilf(handling + catalog.Standards.processing_seconds(standard, recipe_data.spec, recipe_data.target)
		+ float(operation.get("setup_seconds", standard.setup_seconds)))


static func setup_for(book, code: String, op: Dictionary, start: float, ignore: String = "") -> float:
	var previous := {}
	for order in book.orders.values():
		if order.id != ignore and order.get("center", "") == op.work_center and order.status != "Cancelled" \
				and order.start <= start and (previous.is_empty() or order.start > previous.start):
			previous = order
	return book.catalog.Standards.changeover(book.catalog, previous.get("recipe", {}).get("spec", {}),
		book.catalog.materials[code], op.type, op.standard.setup_seconds)


static func assignment(book, code: String, quantity: float, start: float, version: String, ignore: String = "") -> Dictionary:
	var data := recipe(book.catalog, code, quantity)
	if not data.error.is_empty():
		return data
	var problem := "No eligible production version at this date."
	for route in alternatives(book.catalog, code, quantity, start):
		if not version.is_empty() and route.production_version != version:
			continue
		var op: Dictionary = route.operations[0]
		if not op.available:
			problem = op.get("standard_error", "The selected resource is unavailable.")
			continue
		op.setup_seconds = setup_for(book, code, op, start, ignore)
		var seconds := duration(book.catalog, data, op)
		if op.standard.model == "batch":
			var input_kg: float = data.target / op.standard.yield_factor
			var batches: int = book.catalog.Standards.batch_count(op.standard, data.target)
			if input_kg / batches + EPS < op.standard.min_batch_kg:
				problem = "Quantity cannot form the required minimum batches on this resource."
				continue
		var yield_factor: float = op.standard.yield_factor
		if yield_factor < 1.0:
			for component in data.mass_inputs:
				data.mass_inputs[component] /= yield_factor
				data.needs[component] /= yield_factor
			for component in data.mix:
				data.mix[component] = data.mass_inputs[component]
			if data.stage == "extrude":
				data.dough_target /= yield_factor
			data.baked_rate = data.mass_inputs.get(data.get("baked", ""), 0.0)
			data.coat_rate = data.mass_inputs.get(data.get("coating", ""), 0.0)
		return {"error": "", "recipe": data, "route": route, "duration": seconds, "center": op.work_center}
	return {"error": problem}


static func calendar(catalog, center: String) -> Array:
	return catalog.scheduling.work_center_calendars.get(center, catalog.scheduling.calendar)


static func in_calendar(catalog, center: String, start: float, finish: float) -> bool:
	var day := floorf(start / DAY) * DAY
	for window in calendar(catalog, center):
		if start >= day + window[0] and finish <= day + window[1] + EPS:
			return true
	# A 24-hour calendar has no midnight break.
	var windows := calendar(catalog, center)
	return windows.size() == 1 and windows[0][0] == 0 and windows[0][1] == DAY


static func conflict(book, center: String, start: float, finish: float, ignore: String = "") -> String:
	if not in_calendar(book.catalog, center, start, finish):
		return "The operation falls outside this work center's availability calendar."
	for row in book.orders.values():
		if row.id == ignore or row.get("center", "") != center or row.status == "Cancelled":
			continue
		if start < float(row.finish) - EPS and finish > float(row.start) + EPS:
			return "Capacity conflict with %s on %s." % [row.id, center]
	return ""


static func next_slot(book, center: String, start: float, seconds: float, ignore: String = "") -> float:
	var occupied: Array = book.orders.values().filter(func(row: Dictionary) -> bool:
		return row.id != ignore and row.get("center", "") == center and row.status != "Cancelled")
	occupied.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.start < b.start)
	var candidate := maxf(0.0, start)
	for attempt in range(occupied.size() + MAX_DAYS + 1):
		if not in_calendar(book.catalog, center, candidate, candidate + seconds):
			var day := floorf(candidate / DAY) * DAY
			var found := false
			for window in calendar(book.catalog, center):
				var opening := maxf(candidate, day + window[0])
				if opening + seconds <= day + window[1] + EPS:
					candidate = opening
					found = true
					break
			if not found:
				candidate = day + DAY
				continue
		var blocked := false
		for row in occupied:
			if candidate < float(row.finish) - EPS and candidate + seconds > float(row.start) + EPS:
				candidate = row.finish
				blocked = true
				break
		if not blocked:
			return candidate
	return INF


static func fit(book, code: String, quantity: float, start: float, version: String, ignore: String = "") -> Dictionary:
	var candidate := maxf(start, book.now)
	for attempt in range(book.orders.size() + 2):
		var data := assignment(book, code, quantity, candidate, version, ignore)
		if not data.error.is_empty():
			return data
		var available := next_slot(book, data.center, candidate, data.duration, ignore)
		if not is_finite(available):
			break
		if available > candidate + EPS:
			candidate = available
			continue
		var successor := next_order(book, data.center, candidate, ignore)
		if successor_setup_exceeds(book, data.recipe.spec, successor):
			candidate = successor.finish
			continue
		data.start = candidate
		return data
	return {"error": "No open slot fits this operation."}


static func next_order(book, center: String, start: float, ignore: String = "") -> Dictionary:
	var next := {}
	for order in book.orders.values():
		if order.id != ignore and order.get("center", "") == center and order.status != "Cancelled" \
				and order.start > start and (next.is_empty() or order.start < next.start):
			next = order
	return next


static func successor_setup_exceeds(book, before: Dictionary, successor: Dictionary) -> bool:
	if not successor.has("standard"):
		return false
	var needed: float = book.catalog.Standards.changeover(book.catalog, before, successor.recipe.spec,
		successor.stage, successor.standard.setup_seconds, successor.get("setup_rules", {}))
	return needed > float(successor.route.operations[0].get("setup_seconds", 0)) + EPS


static func placement_conflict(book, data: Dictionary, start: float, ignore: String) -> String:
	var problem := conflict(book, data.center, start, start + float(data.duration), ignore)
	if not problem.is_empty():
		return problem
	var next := next_order(book, data.center, start, ignore)
	if successor_setup_exceeds(book, data.recipe.spec, next):
		return "This move would require more setup time for %s. Reschedule that order first." % next.id
	return ""


static func create(book, code: String, quantity: float, start: float, priority: int, version: String = "") -> Dictionary:
	if not is_finite(start) or start < 0:
		return {"error": "Enter a nonnegative simulated start."}
	var candidate := maxf(start, book.now)
	var data := {}
	var error := "No eligible production version at this date."
	for route in alternatives(book.catalog, code, quantity, candidate):
		if not version.is_empty() and route.production_version != version:
			continue
		var op: Dictionary = route.operations[0]
		if not op.available:
			error = op.get("standard_error", "The selected resource is unavailable.")
			continue
		var option := fit(book, code, quantity, candidate, route.production_version)
		if not option.error.is_empty():
			error = option.error
		elif data.is_empty() or option.start + option.duration < data.start + data.duration:
			data = option
	if data.is_empty():
		var validation := recipe(book.catalog, code, quantity)
		return validation if not validation.error.is_empty() else {"error": error}
	var scheduled: float = data.start
	var id: String = book._id("MO")
	var row := {"id": id, "code": code, "quantity": quantity, "boxes": int(quantity) if data.recipe.stage == "pack" else 0,
		"unit": "box" if data.recipe.stage == "pack" else "kg", "requested_start": start,
		"line": book.LINE, "priority": clampi(priority, 1, 9), "status": "Created", "remaining": {},
		"consumed": {}, "packed": 0, "received": 0.0, "received_kg": 0.0, "dough_issued": 0.0,
		"started": -1.0, "completed": -1.0, "warning": "", "pegs": [], "delay": "", "logistics_seconds": 0.0,
		"material_wait_seconds": 0.0, "oven_wait_seconds": 0.0, "scrapped": 0.0, "released_quantity": 0.0}
	_set_slot(book, row, data, scheduled)
	book.orders[id] = row
	book.schedule_revision += 1
	book.changed()
	return {"error": "", "id": id, "start": scheduled}


static func reschedule(book, id: String, start: float, version: String = "") -> String:
	var order: Dictionary = book.orders.get(id, {})
	if order.get("status") != "Created" or not order.has("stage"):
		return "Only a planned stage order can be rescheduled."
	if not is_finite(start) or start < book.now - EPS:
		return "Choose a start at or after the current simulation time."
	var data := assignment(book, order.code, order.quantity, start, order.version if version.is_empty() else version, id)
	if not data.error.is_empty():
		return data.error
	var error := placement_conflict(book, data, start, id)
	if error.is_empty():
		_set_slot(book, order, data, start)
		book.schedule_revision += 1
		book.changed()
	return error


static func _set_slot(book, order: Dictionary, data: Dictionary, start: float) -> void:
	order.merge({"recipe": data.recipe, "stage": data.recipe.stage, "route": data.route,
		"version": data.route.production_version, "standard": data.route.operations[0].standard.duplicate(true),
		"center": data.center, "estimate": data.duration,
		"start": start, "finish": start + data.duration}, true)
	if data.recipe.stage != "pack":
		# When the first lot is ready, for stages that start on part of this output.
		order.first_output = minf(float(data.duration), first_output(book.catalog, order.code, float(data.recipe.target)))


static func peg(book, child: String, parent: String) -> String:
	var upstream: Dictionary = book.orders.get(child, {})
	var downstream: Dictionary = book.orders.get(parent, {})
	if upstream.is_empty() or downstream.is_empty() or child == parent \
			or not downstream.recipe.needs.has(upstream.code) or _reaches(book, parent, child):
		return "Select an order that directly supplies a BOM component. Cycles are forbidden."
	if not parent in upstream.pegs:
		upstream.pegs.append(parent)
		book.changed()
	return ""


static func _reaches(book, start: String, target: String) -> bool:
	var pending: Array = [start]
	var seen := {}
	while not pending.is_empty():
		var current: String = pending.pop_back()
		if current == target:
			return true
		if not seen.has(current):
			seen[current] = true
			pending.append_array(book.orders.get(current, {}).get("pegs", []))
	return false


static func dependency_warning(book, order: Dictionary) -> String:
	for upstream in book.orders.values():
		if order.id in upstream.get("pegs", []) and upstream.status not in ["Completed", "Closed", "Cancelled"]:
			if supply_late(book.catalog, upstream, order) <= EPS:
				continue
			if not overlaps(book.catalog, order.get("stage", ""), upstream.code):
				return "%s is planned to finish after this order starts." % upstream.id
			if first_lot_at(book.catalog, upstream, order) > float(order.start) + EPS:
				return "%s is planned to deliver its first lot after this order starts." % upstream.id
			return "%s is planned to finish after this order finishes." % upstream.id
	return ""


# --- Stage overlap ------------------------------------------------------------------
# A stage can start on a first lot of its manufactured input while the upstream stage is still
# running, so the stages of a product flow like one line instead of one batch after another.

static func overlap_enabled(catalog) -> bool:
	return bool(catalog.scheduling.get("overlap", {}).get("enabled", false))


## Kilograms of manufactured input a stage needs in stock before it can start. Zero means the
## stage waits for its whole input.
static func start_kg(catalog, stage: String) -> float:
	return float(catalog.scheduling.stages.get(stage, {}).get("start_kg", 0.0))


## Whether a stage may start on part of the output of the upstream material.
static func overlaps(catalog, parent_stage: String, child_code: String) -> bool:
	return overlap_enabled(catalog) and start_kg(catalog, parent_stage) > 0.0 \
		and catalog.materials.get(child_code, {}).get("procurement") == "In-house"


## Seconds an upstream stage needs before its first lot (of `lot_kg`) is available downstream.
static func first_output(catalog, code: String, quantity: float, lot_kg: float = 0.0) -> float:
	var config: Dictionary = catalog.scheduling.get("overlap", {})
	var lot := lot_kg if lot_kg > 0.0 else float(config.get("first_lot_kg", 75.0))
	var sample := minf(quantity, lot)
	var best := INF
	for route in alternatives(catalog, code, sample, 0.0):
		var op: Dictionary = route.operations[0]
		if not op.available or not op.has("standard"):
			continue
		var data := recipe(catalog, code, sample)
		if data.error.is_empty():
			best = minf(best, duration(catalog, data, op))
	return best if is_finite(best) else 0.0


## When the first lot a consuming stage needs is ready from an upstream order.
static func first_lot_at(catalog, upstream: Dictionary, parent: Dictionary) -> float:
	return float(upstream.start) + first_output(catalog, upstream.code, float(upstream.recipe.target), start_kg(catalog, parent.get("stage", "")))


## Seconds by which an upstream order's supply comes too late for the order that consumes it.
## Without overlap its output must be there when the consumer starts. With overlap the first lot
## must be there at the start and the last lot by the time the consumer finishes.
static func supply_late(catalog, upstream: Dictionary, parent: Dictionary) -> float:
	if not overlaps(catalog, parent.get("stage", ""), upstream.code):
		return float(upstream.finish) - float(parent.start)
	return maxf(first_lot_at(catalog, upstream, parent) - float(parent.start), float(upstream.finish) - float(parent.finish))
