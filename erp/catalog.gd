extends RefCounted
## Fictional demonstration master data. Quantities use material base units.

const Master = preload("res://erp/master_files.gd")
const OPERATIONS := ["extrude", "bake", "coat", "pack"]
const MATERIAL_STAGES := ["dough", "raw", "baked", "coated", "finished"]
const PARAMETERS := {
	"extrude": {"rate": [0.0, 36000.0]},
	"bake": {"batch_kg": [1.0, 300.0], "cycle_seconds": [3.0, 1800.0]},
	"coat": {"rate": [0.0, 36000.0], "input_kg": [1.0, 500.0], "setup_seconds": [0.0, 86400.0]},
	"pack": {"rate": [0.0, 36000.0], "setup_seconds": [0.0, 86400.0]}
}

var materials := {}
var boms := {}
var suppliers := {}
var routings := {}
var production_versions := {}
var work_centers := {}
var locations := {}
var opening := {}
var error := ""


func _init(directory: String = "") -> void:
	error = _load(directory)


func _load(directory: String) -> String:
	for table in [
		["materials", "code", ["name", "type", "unit", "procurement", "location", "minimum", "lead", "active", "opening"]],
		["products", "code", ["coating", "wafer", "family", "coating_color", "package_color", "pack_kg",
			"packs_per_box", "boxes_per_pallet", "shelf_days"]],
		["boms", "parent", ["base", "version", "active", "parts"]],
		["suppliers", "id", ["name", "codes", "lead", "minimum", "price"]],
		["work_centers", "id", ["description", "equipment", "operation", "categories", "coatings", "technical", "available"]],
		["routings", "id", ["description", "version", "categories", "active", "valid_from", "valid_to", "operations"]],
		["production_versions", "id", ["product", "bom_version", "routing", "routing_version", "min_boxes",
			"max_boxes", "valid_from", "valid_to", "active"]]
	]:
		var result := Master.index(table[0], table[1], table[2], directory)
		if not result.error.is_empty():
			return result.error
		if table[0] == "products":
			for code in result.data:
				var item: Dictionary = result.data[code]
				if not materials.has(code) or materials[code].type != "FERT":
					return "products.json [%s].code: expected a finished material." % code
				if not Master.number(item.pack_kg, 0.0001) or not Master.number(item.packs_per_box, 1, 10000, true) \
						or not Master.number(item.boxes_per_pallet, 1, 32, true) or not Master.number(item.shelf_days, 0, INF, true):
					return "products.json [%s]: invalid packaging quantities or shelf life." % code
				if not item.coating is String or not item.wafer is String or not item.family is String \
			or not item.coating_color is String or not Color.html_is_valid(item.coating_color) \
			or not item.package_color is String or not Color.html_is_valid(item.package_color):
					return "products.json [%s]: invalid product descriptions or colors." % code
				materials[code].merge(item, true)
				materials[code].merge({"box_kg": item.pack_kg * item.packs_per_box, "bom": code,
					"batch_kg": item.pack_kg * item.packs_per_box * item.boxes_per_pallet}, true)
		else:
			set(table[0], result.data)
	var result := Master.read("storage_locations", directory)
	if not result.error.is_empty():
		return result.error
	if not result.data is Dictionary:
		return "storage_locations.json: expected location identifiers and descriptions."
	locations = result.data
	return _validate()


func _validate() -> String:
	for location in ["RM-WH", "RM-STAGE", "COAT-IN", "PACK-IN", "TRANSIT", "WIP", "PACK-WIP", "FG-WH"]:
		if not locations.get(location) is String:
			return "storage_locations.json [%s]: description required." % location
	for code in materials:
		var item: Dictionary = materials[code]
		if item.type not in ["ROH", "HALB", "FERT", "VERP"] or item.unit not in ["kg", "ea"] \
				or not locations.has(item.location) or not item.active is bool or not item.name is String \
				or item.procurement != ("External" if item.type in ["ROH", "VERP"] else "In-house"):
			return "materials.json [%s]: invalid type, unit, location, description, or procurement type." % code
		for field in ["lead", "minimum", "opening"]:
			if not Master.number(item[field], 0, INF, item.unit == "ea" and field == "opening"):
				return "materials.json [%s].%s: invalid quantity or time." % [code, field]
		if item.opening > 0:
			if item.procurement != "External" or item.location != "RM-WH":
				return "materials.json [%s].opening: opening stock must be external and at RM-WH." % code
			opening[code] = item.opening
		item.erase("opening")
		if item.type == "FERT" and not item.has("box_kg"):
			return "products.json [%s]: finished material needs a product specification." % code
	for code in boms:
		var bom: Dictionary = boms[code]
		if not materials.has(code) or materials[code].procurement != "In-house" or not Master.number(bom.base, 0.000001) \
				or not Master.number(bom.version, 1, INF, true) or not bom.active is bool or not bom.parts is Array or bom.parts.is_empty():
			return "boms.json [%s]: invalid parent, base, version or parts." % code
		var seen := {}
		for part in bom.parts:
			if not part is Dictionary or not part.get("code") is String or not materials.has(part.code) or seen.has(part.code) \
					or part.get("unit") != materials[part.code].unit or not Master.number(part.get("qty"), 0.000001) \
					or not Master.number(part.get("scrap"), 0, 1):
				return "boms.json [%s].parts: invalid or duplicate component." % code
			seen[part.code] = true
	for code in boms:
		for part in boms[code].parts:
			if _reaches(part.code, code, {}):
				return "boms.json [%s].parts: circular BOM through %s." % [code, part.code]
	for id in suppliers:
		var item: Dictionary = suppliers[id]
		if not item.codes is Array or item.codes.is_empty() or not item.name is String:
			return "suppliers.json [%s].codes: expected a list of supplied materials." % id
		for code in item.codes:
			if not materials.has(code) or materials[code].procurement != "External":
				return "suppliers.json [%s].codes: invalid material %s." % [id, code]
		for field in ["lead", "minimum", "price"]:
			if not Master.number(item[field]):
				return "suppliers.json [%s].%s: invalid number." % [id, field]
	var equipment := {}
	for id in work_centers:
		var item: Dictionary = work_centers[id]
		if not item.equipment is String or equipment.has(item.equipment) or not PARAMETERS.has(item.operation) \
				or not item.description is String or not item.categories is Array or item.categories.is_empty() \
				or not item.coatings is Array or not item.technical is Dictionary or not item.available is bool:
			return "work_centers.json [%s]: invalid or duplicate equipment, capabilities or availability." % id
		if item.operation == "coat" and not locations.has(item.get("supply_location")):
			return "work_centers.json [%s].supply_location: unknown storage location." % id
		equipment[item.equipment] = true
		for field in PARAMETERS[item.operation]:
			var bounds: Array = PARAMETERS[item.operation][field]
			if not Master.number(item.technical.get(field), bounds[0], bounds[1]):
				return "work_centers.json [%s].technical.%s: invalid value." % [id, field]
	for id in routings:
		var route: Dictionary = routings[id]
		if not _valid_dates(route) or not Master.number(route.version, 1, INF, true) or not route.description is String \
				or not route.categories is Array or not route.operations is Array or route.operations.size() != OPERATIONS.size():
			return "routings.json [%s]: invalid header or operation sequence." % id
		var previous := 0.0
		for index in OPERATIONS.size():
			var op: Variant = route.operations[index]
			if not op is Dictionary or op.get("type") != OPERATIONS[index] or not op.get("handling") is String \
					or not Master.number(op.get("number"), previous + 1.0, INF, true) \
					or op.get("input") != MATERIAL_STAGES[index] or op.get("output") != MATERIAL_STAGES[index + 1] \
					or not work_centers.has(op.get("work_center")) or work_centers[op.work_center].operation != op.type:
				return "routings.json [%s].operations[%d]: invalid work center, operation or material stage." % [id, index]
			previous = float(op.number)
	for id in production_versions:
		var item: Dictionary = production_versions[id]
		if not _valid_dates(item) or not boms.has(item.product) or not materials[item.product].has("box_kg") \
				or not routings.has(item.routing) or item.bom_version != boms[item.product].version \
				or item.routing_version != routings[item.routing].version or not Master.number(item.min_boxes, 1, 100000, true) \
				or not Master.number(item.max_boxes, item.min_boxes, 100000, true):
			return "production_versions.json [%s]: invalid product, BOM, routing version or lot range." % id
		var incompatibility := _compatibility(routings[item.routing], materials[item.product])
		if not incompatibility.is_empty():
			return "production_versions.json [%s].routing: %s" % [id, incompatibility]
	return ""


func _valid_dates(row: Dictionary) -> bool:
	return row.active is bool and Master.number(row.valid_from) and Master.number(row.valid_to) \
		and (row.valid_to == 0 or row.valid_to >= row.valid_from)


func _in_effect(row: Dictionary, when: float) -> bool:
	return row.active and row.valid_from <= when and (row.valid_to == 0 or row.valid_to >= when)


func _compatibility(route: Dictionary, product: Dictionary) -> String:
	if product.family not in route.categories:
		return "Routing does not support this product family."
	for op in route.operations:
		var center: Dictionary = work_centers[op.work_center]
		if product.family not in center.categories or (not center.coatings.is_empty() and product.coating not in center.coatings):
			return "%s does not support this product." % center.description
	return ""


func route_for(product: String, boxes: int, when: float, requested: String = "", require_available: bool = true) -> Dictionary:
	if not materials.has(product) or not materials[product].has("box_kg"):
		return {"error": "Unknown finished product."}
	var ids: Array = production_versions.keys() if requested.is_empty() else [requested]
	for id in ids:
		var version: Dictionary = production_versions.get(id, {})
		if version.get("product", "") != product or not _in_effect(version, when) \
				or boxes < version.min_boxes or boxes > version.max_boxes or boms[product].version != version.bom_version:
			continue
		var route: Dictionary = routings[version.routing].duplicate(true)
		if not _in_effect(route, when) or not _compatibility(route, materials[product]).is_empty():
			continue
		var eligible := true
		for operation in route.operations:
			var center: Dictionary = work_centers[operation.work_center]
			var ready: bool = center.available and float(center.technical.get("rate", 1.0)) > 0.0
			eligible = eligible and (not require_available or ready)
			operation.merge({"equipment": center.equipment, "description": center.description,
				"technical": center.technical.duplicate(true), "available": ready,
				"supply_location": center.get("supply_location", "")})
		if eligible:
			route.production_version = id
			route.bom_version = version.bom_version
			route.error = ""
			return route
	return {"error": "No eligible production version for this SKU, lot size, date and work center availability."}


func center_at(equipment: StringName) -> Dictionary:
	for center in work_centers.values():
		if StringName(center.equipment) == equipment:
			return center
	return {}


func estimate(recipe: Dictionary, route: Dictionary) -> float:
	var ops: Array = route.operations
	return (3600.0 * recipe.dough_target / maxf(1.0, ops[0].technical.rate)
		+ ceilf(recipe.dough_target / ops[1].technical.batch_kg) * ops[1].technical.cycle_seconds
		+ 3600.0 * recipe.target / maxf(1.0, ops[2].technical.rate)
		+ 3600.0 * recipe.target / maxf(1.0, ops[3].technical.rate))


func _update_bom_versions(code: String) -> void:
	for item in production_versions.values():
		if item.product == code:
			item.bom_version = boms[code].version


func save_bom(code: String, base: float, parts: Array, active: bool) -> String:
	if not materials.has(code) or materials[code].procurement != "In-house" or not _positive(base):
		return "Choose an in-house parent and a positive base quantity."
	var seen := {}
	for part in parts:
		var child: String = part.get("code", "")
		var scrap: float = part.get("scrap", 0.0)
		if not materials.has(child) or seen.has(child) or not _positive(part.get("qty", 0.0)) \
				or not is_finite(scrap) or scrap < 0.0 or scrap > 1.0 or part.get("unit") != materials[child].unit:
			return "Each component needs a unique code, positive quantity, base unit and scrap from 0 to 1."
		if _reaches(child, code, {}):
			return "This component would create a circular BOM."
		seen[child] = true
	if parts.is_empty():
		return "Add at least one component."
	var version := int(boms.get(code, {}).get("version", 0)) + 1
	boms[code] = {"parent": code, "base": base, "version": version, "active": active, "parts": parts.duplicate(true)}
	_update_bom_versions(code)
	return ""


func _reaches(code: String, target: String, visited: Dictionary) -> bool:
	if code == target:
		return true
	if visited.has(code):
		return false
	visited[code] = true
	for part in boms.get(code, {}).get("parts", []):
		if _reaches(part.code, target, visited):
			return true
	return false


func explode(code: String, quantity: float) -> Dictionary:
	var result := {}
	var error := _explode(code, quantity, result, {})
	return {"requirements": result if error.is_empty() else {}, "error": error}


func _explode(code: String, amount: float, result: Dictionary, path: Dictionary) -> String:
	if not materials.has(code) or not materials[code].active:
		return "Unavailable material " + code
	if path.has(code):
		return "Circular BOM at " + code
	if materials[code].procurement == "External":
		result[code] = float(result.get(code, 0.0)) + amount
		return ""
	var bom: Dictionary = boms.get(code, {})
	if bom.is_empty() or not bom.active:
		return "No active BOM for " + code
	path[code] = true
	for part in bom.parts:
		var error := _explode(part.code, amount * part.qty * (1.0 + part.scrap) / bom.base, result, path)
		if not error.is_empty():
			return error
	path.erase(code)
	return ""


func recipe(code: String, boxes: int) -> Dictionary:
	if not materials.has(code) or materials[code].type != "FERT" or not materials[code].active or boxes < 1:
		return {"error": "Choose an active finished product and positive box quantity."}
	var spec: Dictionary = materials[code].duplicate(true)
	var target: float = boxes * spec.box_kg
	var exploded := explode(code, target)
	if not exploded.error.is_empty():
		return {"error": exploded.error}
	var finished := _rates(code)
	var coated := _by_type(finished, "HALB")
	var packaging := _by_type(finished, "VERP")
	if coated.size() != 1 or packaging.size() != 3 or finished.size() != 4:
		return {"error": "This BOM needs one coated wafer and three packaging components for the wafer line."}
	var coated_code: String = coated.keys()[0]
	var coating_mix := _rates(coated_code)
	var baked := _by_type(coating_mix, "HALB")
	var chocolate := _by_type(coating_mix, "ROH")
	if baked.size() != 1 or chocolate.size() != 1 or coating_mix.size() != 2 or not is_equal_approx(float(coated[coated_code]), 1.0):
		return {"error": "Coating requires one baked wafer and one coating component."}
	var baked_code: String = baked.keys()[0]
	var raw := _rates(baked_code)
	if raw.size() != 1:
		return {"error": "The oven requires one extruded wafer material."}
	var raw_code: String = raw.keys()[0]
	var dough := _rates(raw_code)
	if dough.size() != 1 or not is_equal_approx(float(raw[raw_code]), 1.0):
		return {"error": "The oven requires a 1-to-1 wafer recipe."}
	var dough_code: String = dough.keys()[0]
	var mix := _rates(dough_code)
	var baked_rate: float = baked[baked_code]
	var coating_code: String = chocolate.keys()[0]
	var coat_rate: float = chocolate[coating_code]
	if not is_equal_approx(baked_rate + coat_rate, 1.0) or not is_equal_approx(float(dough[dough_code]), 1.0):
		return {"error": "Extrusion, baking and coating must conserve food mass on this routing."}
	var total := 0.0
	for child in mix:
		if materials[child].procurement != "External" or materials[child].unit != "kg":
			return {"error": "Dough components must be external kilogram materials."}
		total += float(mix[child])
	if not is_equal_approx(total, 1.0):
		return {"error": "The dough blend must total one kg of ingredients per kg."}
	if not packaging.has("PK-PALLET") or not is_equal_approx(float(packaging["PK-PALLET"]) * spec.box_kg * spec.boxes_per_pallet, 1.0):
		return {"error": "Pallet allocation must match boxes per pallet."}
	packaging.erase("PK-PALLET")
	for child in packaging:
		if materials[child].unit != "ea" or not is_equal_approx(float(packaging[child]) * spec.box_kg, 1.0):
			return {"error": "This packing line needs one carton and one label per box."}
	var needs: Dictionary = exploded.requirements
	for child in needs:
		if materials[child].unit == "ea":
			needs[child] = ceilf(float(needs[child]) - 1e-7)
	return {"error": "", "spec": spec, "target": target, "dough_target": target * baked_rate,
		"mix": mix, "dough": dough_code, "raw": raw_code, "baked": baked_code, "coated": coated_code,
		"coating": coating_code, "coat_rate": coat_rate, "baked_rate": baked_rate,
		"packaging": packaging.keys(), "needs": needs, "bom_version": boms[code].version,
		"bom_snapshot": _freeze_bom(code)}


func _freeze_bom(product: String) -> Dictionary:
	var headers := {}
	var pending := [product]
	while not pending.is_empty():
		var code: String = pending.pop_back()
		if headers.has(code) or not boms.has(code):
			continue
		headers[code] = boms[code].duplicate(true)
		for part in boms[code].parts:
			pending.append(part.code)
	return headers


func _rates(code: String) -> Dictionary:
	var output := {}
	var bom: Dictionary = boms.get(code, {})
	if not bom.is_empty():
		for part in bom.parts:
			output[part.code] = float(part.qty) * (1.0 + part.scrap) / float(bom.base)
	return output


func _by_type(rates: Dictionary, category: String) -> Dictionary:
	var output := {}
	for code in rates:
		if materials[code].type == category:
			output[code] = rates[code]
	return output


func supplier_for(code: String) -> Dictionary:
	for supplier in suppliers.values():
		if code in supplier.codes:
			return supplier
	return {}


func _positive(value: float) -> bool:
	return is_finite(value) and value > 0.0


func edit_material(code: String, name: String, minimum: float, lead: float, active: bool,
		pack_kg: float = 0.0, packs: int = 0, boxes: int = 0) -> String:
	if not materials.has(code) or name.strip_edges().is_empty() or not is_finite(minimum) \
			or minimum < 0.0 or not is_finite(lead) or lead < 0.0:
		return "Check description, safety stock and lead time."
	var item: Dictionary = materials[code]
	if item.type == "FERT":
		if not _positive(pack_kg) or packs < 1 or boxes < 1 or boxes > 32 or pack_kg * packs > 50.0:
			return "Use a positive pack weight, 1–32 boxes per pallet and at most 50 kg per carton."
		var header: Dictionary = boms[code]
		if not is_equal_approx(item.pack_kg, pack_kg) or item.packs_per_box != packs or item.boxes_per_pallet != boxes:
			for part in header.parts:
				if materials[part.code].type == "HALB":
					part.qty *= pack_kg * packs / float(header.base)
				elif part.code == "PK-PALLET":
					part.qty = 1.0 / boxes
			header.base = pack_kg * packs
			header.version += 1
			_update_bom_versions(code)
		item.pack_kg = pack_kg
		item.packs_per_box = packs
		item.box_kg = pack_kg * packs
		item.boxes_per_pallet = boxes
		item.batch_kg = item.box_kg * boxes
	item.name = name.strip_edges()
	item.minimum = minimum
	item.lead = lead
	item.active = active
	return ""


func clone_product(source: String, code: String, name: String) -> String:
	if not materials.has(source) or materials[source].type != "FERT" or materials.has(code) \
			or not code.begins_with("FG-") or not code.substr(3).is_valid_int() or code.substr(3).to_int() < 1 \
			or name.strip_edges().is_empty():
		return "Use an unused FG-number and a description."
	var item: Dictionary = materials[source].duplicate(true)
	item.code = code
	item.name = name.strip_edges()
	item.bom = code
	materials[code] = item
	var header: Dictionary = boms[source].duplicate(true)
	header.parent = code
	header.version = 1
	boms[code] = header
	for version in production_versions.values():
		if version.product == source:
			var copy: Dictionary = version.duplicate()
			copy.id = "%s-%s" % [code, copy.routing]
			copy.product = code
			copy.bom_version = header.version
			production_versions[copy.id] = copy
	return ""
