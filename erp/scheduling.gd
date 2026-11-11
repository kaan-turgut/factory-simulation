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
	var input := "Staged ingredients"
	for component in catalog._rates(code):
		if catalog.materials[component].procurement == "In-house":
			input = component
			break
	var handling: String = catalog.scheduling.stages[stage].handling
	if stage == "pack":
		if not is_equal_approx(quantity, roundf(quantity)):
			return rows
		for id in catalog.production_versions:
			var item: Dictionary = catalog.production_versions[id]
			if item.product != code:
				continue
			var full: Dictionary = catalog.route_for(code, int(quantity), when, id, false)
			if not full.error.is_empty():
				continue
			var operation: Dictionary = full.operations[3]
			operation.available = _available(catalog.work_centers[operation.work_center])
			operation.merge({"input": input, "output": code, "handling": handling}, true)
			full.operations = [operation]
			full.description = operation.description
			rows.append(full)
		return rows
	var product := _coated_product(catalog, code)
	for id in catalog.scheduling.stages[stage].centers:
		var center: Dictionary = catalog.work_centers[id]
		if not product.is_empty() and (product.family not in center.categories \
				or (not center.coatings.is_empty() and product.coating not in center.coatings)):
			continue
		var version := "%s/%s" % [code, id]
		rows.append({"id": version, "production_version": version, "version": 1,
			"bom_version": bom.version, "description": center.description, "error": "",
			"operations": [{"number": 10, "type": stage, "work_center": id, "equipment": center.equipment,
				"description": center.description, "technical": center.technical.duplicate(true),
				"input": input, "output": code, "handling": handling,
				"available": _available(center), "supply_location": center.get("supply_location", "")}]})
	return rows


static func _available(center: Dictionary) -> bool:
	return center.available and float(center.technical.get("rate", 1.0)) > 0


static func _coated_product(catalog, code: String) -> Dictionary:
	for item in catalog.materials.values():
		if item.type == "FERT" and catalog._rates(item.code).has(code):
			return item
	return {}


static func recipe(catalog, code: String, quantity: float) -> Dictionary:
	var stage := stage_for(catalog, code)
	if stage.is_empty() or not is_finite(quantity) or quantity <= EPS or quantity > 100000.0:
		return {"error": "Choose an active manufactured material and a quantity above zero, up to 100,000."}
	var bom: Dictionary = catalog.boms.get(code, {})
	if bom.is_empty() or not bom.active:
		return {"error": "No active BOM for " + code}
	var spec: Dictionary = catalog.materials[code].duplicate(true)
	var result := {"error": "", "stage": stage, "target": quantity, "spec": spec, "needs": {},
		"mix": {}, "dough_target": quantity, "packaging": [], "bom_version": bom.version,
		"bom_snapshot": {code: bom.duplicate(true)}}
	if stage == "pack":
		if not is_equal_approx(quantity, roundf(quantity)):
			return {"error": "Packaging quantities must be whole shipping boxes."}
		# Keep packaging specifications and rounding independent of upstream BOM availability.
		result.target = quantity * spec.box_kg
	elif stage == "coat":
		var product := _coated_product(catalog, code)
		result.spec.coating_color = product.get("coating_color", "#765346")
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
		if component.procurement == "In-house":
			if not internal.is_empty():
				return {"error": "This physical operation takes one internally produced input."}
			internal = child
		elif stage == "mix":
			result.mix[child] = rates[child]
		elif stage == "coat":
			result.coating = child
			result.coat_rate = rates[child]
		elif stage == "pack" and child != "PK-PALLET":
			result.packaging.append(child)
	if not is_equal_approx(mass_rate, 1.0):
		return {"error": "The stage BOM must conserve food mass."}
	result.input = internal
	if stage == "mix" and (not internal.is_empty() or result.mix.size() != rates.size()):
		return {"error": "Ingredient preparation requires external kilogram inputs."}
	if stage in ["extrude", "bake"] and (rates.size() != 1 or internal.is_empty()):
		return {"error": "This operation needs one kilogram input."}
	if stage == "coat":
		if rates.size() != 2 or internal.is_empty() or not result.has("coating"):
			return {"error": "Coating needs baked wafers and one coating material."}
		result.baked = internal
		result.baked_rate = rates[internal]
		result.coated = code
	if stage == "pack":
		if internal.is_empty() or result.packaging.size() != 2 or not rates.has("PK-PALLET") \
				or not is_equal_approx(float(rates[internal]), 1.0):
			return {"error": "Packaging needs coated wafers, carton, label and pallets."}
		for component in result.packaging:
			if not is_equal_approx(float(rates[component]) * float(spec.box_kg), 1.0):
				return {"error": "The carton and label quantities must match one shipping box."}
		if not is_equal_approx(float(rates["PK-PALLET"]) * float(spec.box_kg) * float(spec.boxes_per_pallet), 1.0):
			return {"error": "Pallet allocation must match boxes per pallet."}
		result.coated = internal
	return result


static func duration(catalog, recipe_data: Dictionary, operation: Dictionary) -> float:
	var config: Dictionary = catalog.scheduling.stages[operation.type]
	var tech: Dictionary = operation.technical
	var seconds: float = config.handling_seconds
	if operation.type == "bake":
		seconds += ceilf(recipe_data.target / tech.batch_kg - EPS) * (tech.cycle_seconds + config.batch_handling_seconds)
	else:
		seconds += recipe_data.target * 3600.0 / maxf(EPS, tech.rate)
	return ceilf(seconds + float(tech.get("setup_seconds", 0.0)))


static func assignment(book, code: String, quantity: float, start: float, version: String) -> Dictionary:
	var data := recipe(book.catalog, code, quantity)
	if not data.error.is_empty():
		return data
	for route in alternatives(book.catalog, code, quantity, start):
		if (version.is_empty() or route.production_version == version) and route.operations[0].available:
			var op: Dictionary = route.operations[0]
			return {"error": "", "recipe": data, "route": route,
				"duration": duration(book.catalog, data, op), "center": op.work_center}
	return {"error": "No eligible production version at this date."}


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


static func create(book, code: String, quantity: float, start: float, priority: int, version: String = "") -> Dictionary:
	if not is_finite(start) or start < 0:
		return {"error": "Enter a nonnegative simulated start."}
	var data := assignment(book, code, quantity, maxf(start, book.now), version)
	if not data.error.is_empty():
		return data
	var scheduled := next_slot(book, data.center, maxf(start, book.now), data.duration)
	if version.is_empty():
		for route in alternatives(book.catalog, code, quantity, maxf(start, book.now)):
			var op: Dictionary = route.operations[0]
			if not op.available or op.work_center == data.center:
				continue
			var estimate := duration(book.catalog, data.recipe, op)
			var candidate := next_slot(book, op.work_center, maxf(start, book.now), estimate)
			if candidate + estimate < scheduled + float(data.duration):
				data.merge({"route": route, "duration": estimate, "center": op.work_center}, true)
				scheduled = candidate
	if not is_finite(scheduled):
		return {"error": "No open slot fits this operation."}
	var id: String = book._id("MO")
	var row := {"id": id, "code": code, "quantity": quantity, "boxes": int(quantity) if data.recipe.stage == "pack" else 0,
		"unit": "box" if data.recipe.stage == "pack" else "kg", "requested_start": start,
		"line": book.LINE, "priority": clampi(priority, 1, 9), "status": "Created", "remaining": {},
		"consumed": {}, "packed": 0, "received": 0.0, "received_kg": 0.0, "dough_issued": 0.0,
		"started": -1.0, "completed": -1.0, "warning": "", "pegs": [], "delay": "", "logistics_seconds": 0.0,
		"material_wait_seconds": 0.0, "oven_wait_seconds": 0.0, "scrapped": 0.0, "released_quantity": 0.0}
	_set_slot(row, data, scheduled)
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
	var data := assignment(book, order.code, order.quantity, start, order.version if version.is_empty() else version)
	if not data.error.is_empty():
		return data.error
	var error := conflict(book, data.center, start, start + float(data.duration), id)
	if error.is_empty():
		_set_slot(order, data, start)
		book.schedule_revision += 1
		book.changed()
	return error


static func _set_slot(order: Dictionary, data: Dictionary, start: float) -> void:
	order.merge({"recipe": data.recipe, "stage": data.recipe.stage, "route": data.route,
		"version": data.route.production_version, "center": data.center, "estimate": data.duration,
		"start": start, "finish": start + data.duration}, true)


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
		if order.id in upstream.get("pegs", []) and upstream.status not in ["Completed", "Closed", "Cancelled"] \
				and upstream.finish > order.start + EPS:
			return "%s is planned to finish after this order starts." % upstream.id
	return ""
