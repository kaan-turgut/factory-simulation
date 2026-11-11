extends RefCounted
## Fictional demonstration master data. Quantities use material base units.

const Standards = preload("res://erp/production_standards.gd")
const Scheduling = preload("res://erp/scheduling.gd")
const Master = preload("res://erp/master_files.gd")
const OPERATIONS := ["extrude", "bake", "coat", "pack"]
const MATERIAL_STAGES := ["dough", "raw", "baked", "coated", "finished"]
## MRP lot-sizing procedures. Finished goods stay lot-for-lot because each order is linked to one demand.
const LOT_PROCEDURES := {"EX": "Lot-for-lot", "FX": "Fixed lot", "PB": "Period lot"}
const PLANNING_DEFAULTS := {"lot_size": "EX", "fixed_lot": 0.0, "period_seconds": 0.0, "min_lot": 0.0,
	"max_lot": 0.0, "rounding": 0.0, "safety_time": 0.0}
const PARAMETERS := {
	"mix": {"rate": [0.0, 36000.0]},
	"extrude": {"rate": [0.0, 36000.0]},
	"bake": {"batch_kg": [1.0, 300.0], "cycle_seconds": [3.0, 1800.0]},
	"coat": {"rate": [0.0, 36000.0], "input_kg": [1.0, 500.0], "setup_seconds": [0.0, 86400.0]},
	"cream": {"batch_kg": [1.0, 300.0], "input_kg": [1.0, 500.0], "output_kg": [1.0, 500.0]},
	"spread": {"rate": [1.0, 36000.0], "input_kg": [1.0, 500.0], "output_kg": [1.0, 500.0]},
	"cut": {"rate": [1.0, 36000.0], "input_kg": [1.0, 500.0], "output_kg": [1.0, 500.0]},
	"cool": {"rate": [1.0, 36000.0], "internal_kg": [1.0, 500.0]},
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
var scheduling := {}
var standards := {}
var changeovers := {}
var planning_examples := {}
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
		["production_standards", "id", ["material", "operation", "work_center", "model"]],
		["changeovers", "id", ["operation", "dimension", "from_value", "to_value", "seconds"]],
		["planning_examples", "id", ["demands"]],
		["work_centers", "id", ["description", "equipment", "operation", "categories", "coatings", "technical", "available", "materials", "models"]],
		["routings", "id", ["description", "version", "categories", "active", "valid_from", "valid_to", "operations"]],
		["production_versions", "id", ["product", "bom_version", "routing", "routing_version", "min_quantity",
			"max_quantity", "lot_unit", "valid_from", "valid_to", "active"]]
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
			set("standards" if table[0] == "production_standards" else table[0], result.data)
	var result := Master.read("storage_locations", directory)
	if not result.error.is_empty():
		return result.error
	if not result.data is Dictionary:
		return "storage_locations.json: expected location identifiers and descriptions."
	locations = result.data
	for center in work_centers.values():
		if center.technical is Dictionary and center.technical.has("max_rate_kg_h"):
			center.technical.rate = center.technical.max_rate_kg_h
	result = Master.read("scheduling", directory)
	if not result.error.is_empty():
		return result.error
	if not result.data is Dictionary:
		return "scheduling.json: expected an object."
	scheduling = result.data
	var problem := _validate()
	if problem.is_empty():
		problem = _validate_scheduling()
	return Standards.validate(self) if problem.is_empty() else problem


func reload_standards() -> String:
	var directory := Master.source_directory()
	var rates := Master.index("production_standards", "id", ["material", "operation", "work_center", "model"], directory)
	if not rates.error.is_empty():
		return rates.error
	var rules := Master.index("changeovers", "id", ["operation", "dimension", "from_value", "to_value", "seconds"], directory)
	if not rules.error.is_empty():
		return rules.error
	var prior_rates := standards
	var prior_rules := changeovers
	standards = rates.data
	changeovers = rules.data
	var problem := Standards.validate(self)
	if not problem.is_empty():
		standards = prior_rates
		changeovers = prior_rules
	return problem


func _validate() -> String:
	for location in ["RM-WH", "RM-STAGE", "COAT-IN", "PACK-IN", "TRANSIT", "WIP", "PACK-WIP", "FG-WH", "SFG-WH", "SFG-DECK"]:
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
		if item.has("planning"):
			var problem := _planning_error(code, item.planning)
			if not problem.is_empty():
				return "materials.json [%s].planning: %s" % [code, problem]
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
		if not item.materials is Array or not item.models is Array:
			return "work_centers.json [%s]: invalid material or processing-model capability." % id
		if item.operation in ["coat", "cream", "pack"] and not locations.has(item.get("supply_location")):
			return "work_centers.json [%s].supply_location: unknown storage location." % id
		if item.has("input_port") and (not item.input_port is String or not item.get("output_port") is String \
				or not Master.number(item.technical.get("input_kg"), 1.0) or not Master.number(item.technical.get("output_kg"), 1.0)):
			return "work_centers.json [%s]: invalid cell ports or staging capacity." % id
		equipment[item.equipment] = true
		for field in PARAMETERS[item.operation]:
			var bounds: Array = PARAMETERS[item.operation][field]
			if not Master.number(item.technical.get(field), bounds[0], bounds[1]):
				return "work_centers.json [%s].technical.%s: invalid value." % [id, field]
	for id in routings:
		var route: Dictionary = routings[id]
		if not _valid_dates(route) or not Master.number(route.version, 1, INF, true) or not route.description is String \
				or not route.categories is Array or not route.operations is Array or route.operations.is_empty():
			return "routings.json [%s]: invalid header or operation sequence." % id
		var previous := 0.0
		for index in route.operations.size():
			var op: Variant = route.operations[index]
			if not op is Dictionary or not PARAMETERS.has(op.get("type")) or not op.get("handling") is String \
					or not Master.number(op.get("number"), previous + 1, INF, true) \
					or not work_centers.has(op.get("work_center")) or work_centers[op.work_center].operation != op.type:
				return "routings.json [%s].operations[%d]: invalid work center, operation or material stage." % [id, index]
			if route.operations.size() == 1:
				if not op.get("input") is Array or op.input.is_empty() or not materials.has(op.get("output")):
					return "routings.json [%s].operations[%d]: missing material input/output." % [id, index]
				for code in op.input:
					if not materials.has(code):
						return "routings.json [%s].input: unknown material %s." % [id, code]
			elif route.operations.size() != OPERATIONS.size() or op.type != OPERATIONS[index] \
					or op.get("input") != MATERIAL_STAGES[index] or op.get("output") != MATERIAL_STAGES[index + 1]:
				return "routings.json [%s].operations[%d]: invalid legacy sequence." % [id, index]
			previous = float(op.number)
	for id in production_versions:
		var item: Dictionary = production_versions[id]
		if not _valid_dates(item) or not boms.has(item.product) or materials[item.product].procurement != "In-house" \
				or not routings.has(item.routing) or item.bom_version != boms[item.product].version \
				or item.routing_version != routings[item.routing].version \
				or item.lot_unit != ("cartons" if materials[item.product].type == "FERT" else "kg") \
				or not Master.number(item.min_quantity, 0.001, 100000) \
				or not Master.number(item.max_quantity, item.min_quantity, 100000):
			return "production_versions.json [%s]: invalid product, BOM, routing version or lot range." % id
		var version_route: Dictionary = routings[item.routing]
		if version_route.operations.size() == 1:
			var op: Dictionary = version_route.operations[0]
			if op.output != item.product or item.product not in work_centers[op.work_center].materials:
				return "production_versions.json [%s]: product and resource do not match the stage routing." % id
		var incompatibility := _compatibility(version_route, materials[item.product])
		if not incompatibility.is_empty():
			return "production_versions.json [%s].routing: %s" % [id, incompatibility]
	return ""


func _validate_scheduling() -> String:
	if not scheduling.get("calendar") is Array or not scheduling.get("work_center_calendars") is Dictionary \
			or not scheduling.get("stages") is Dictionary:
		return "scheduling.json: calendar, work_center_calendars and stages are required."
	var calendars: Array = [scheduling.calendar]
	for id in scheduling.work_center_calendars:
		if not work_centers.has(id):
			return "scheduling.json work_center_calendars: unknown center " + id
		calendars.append(scheduling.work_center_calendars[id])
	for calendar in calendars:
		if not calendar is Array or calendar.is_empty():
			return "scheduling.json: a calendar needs at least one daily interval."
		var previous := 0.0
		for window in calendar:
			if not window is Array or window.size() != 2 or not Master.number(window[0], previous, 86399) \
					or not Master.number(window[1], float(window[0]) + 1, 86400):
				return "scheduling.json: calendar intervals must be ordered, disjoint and within a day."
			previous = window[1]
	for stage in scheduling.stages:
		if not PARAMETERS.has(stage):
			return "scheduling.json: unknown stage " + str(stage)
	var seen := {}
	for stage in PARAMETERS:
		var row: Variant = scheduling.stages.get(stage)
		if not row is Dictionary or not row.get("materials") is Array or row.materials.is_empty() or not row.get("centers") is Array \
				or row.centers.is_empty() or not row.get("handling") is String or not Master.number(row.get("handling_seconds")) \
				or not Master.number(row.get("batch_handling_seconds", 0.0)) \
				or not Master.number(row.get("handling_seconds_per_kg", 0.0)):
			return "scheduling.json [%s]: invalid stage materials, centers or handling times." % stage
		for code in row.materials:
			if not code is String or seen.has(code) or (code == "FERT" and stage != "pack") \
					or (code != "FERT" and not boms.has(code)):
				return "scheduling.json [%s].materials: invalid or duplicate %s." % [stage, code]
			seen[code] = true
		var listed := {}
		for id in row.centers:
			if not id is String or listed.has(id) or work_centers.get(id, {}).get("operation") != stage:
				return "scheduling.json [%s].centers: invalid or repeated work center %s." % [stage, id]
			listed[id] = true
	for code in materials:
		if materials[code].active and materials[code].procurement == "In-house" and not boms.has(code):
			return "scheduling.json: no manufacturing BOM for " + code
	for code in boms:
		if not materials[code].active or not boms[code].active:
			continue
		if not seen.has(code) and (materials[code].type != "FERT" or not seen.has("FERT")):
			return "scheduling.json: no stage for " + code
		var recipe := Scheduling.recipe(self, code, 1.0)
		if not recipe.error.is_empty():
			return "scheduling.json [%s]: %s" % [code, recipe.error]
		var output_location := "FG-WH" if recipe.stage == "pack" else ("SFG-DECK" if recipe.stage == "mix" else "SFG-WH")
		if materials[code].location != output_location:
			return "materials.json [%s].location: this stage receives stock at %s." % [code, output_location]
		if not String(recipe.input).is_empty():
			var input_location := "SFG-DECK" if recipe.stage == "extrude" else "SFG-WH"
			if materials[recipe.input].location != input_location:
				return "boms.json [%s].parts: input must be reachable from %s." % [code, input_location]
	for example in planning_examples.values():
		if not example.demands is Array or example.demands.is_empty():
			return "planning_examples.json [%s].demands: expected a list." % example.id
		for item in example.demands:
			if not item is Dictionary or materials.get(item.get("code"), {}).get("type") != "FERT" \
					or not Master.number(item.get("boxes"), 1, 100000, true) or not Master.number(item.get("due")):
				return "planning_examples.json [%s].demands: invalid product, cartons or due time." % example.id
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
		if product.get("family", "") not in center.categories or (not center.coatings.is_empty() and product.get("coating", "") not in center.coatings):
			return "%s does not support this product." % center.description
	return ""


func route_for(product: String, boxes: int, when: float, requested: String = "", require_available: bool = true) -> Dictionary:
	if not materials.has(product) or not materials[product].has("box_kg"):
		return {"error": "Unknown finished product."}
	var ids: Array = production_versions.keys() if requested.is_empty() else [requested]
	for id in ids:
		var version: Dictionary = production_versions.get(id, {})
		if version.get("product", "") != product or not _in_effect(version, when) \
				or boxes < version.min_quantity or boxes > version.max_quantity or boms[product].version != version.bom_version:
			continue
		var route: Dictionary = routings[version.routing].duplicate(true)
		if route.operations.size() != OPERATIONS.size() or not _in_effect(route, when) or not _compatibility(route, materials[product]).is_empty():
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
	var packaging := packing_components(spec, finished)
	if coated.size() != 1 or packaging.is_empty() or finished.size() != packaging.size() + 2:
		return {"error": "This BOM needs one wafer input and valid carton, label and pallet quantities."}
	var finished_input: String = coated.keys()[0]
	var coated_code := finished_input
	if Scheduling.stage_for(self, coated_code) == "cool":
		var cooled := _rates(coated_code)
		coated_code = cooled.keys()[0]
	var coating_mix := _rates(coated_code)
	var baked := _by_type(coating_mix, "HALB")
	var chocolate := _by_type(coating_mix, "ROH")
	if baked.size() != 1 or chocolate.size() != 1 or coating_mix.size() != 2 or not is_equal_approx(float(coated[finished_input]), 1.0):
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
	var needs: Dictionary = exploded.requirements
	for child in needs:
		if materials[child].unit == "ea":
			needs[child] = ceilf(float(needs[child]) - 1e-7)
	return {"error": "", "spec": spec, "target": target, "dough_target": target * baked_rate,
		"mix": mix, "dough": dough_code, "raw": raw_code, "baked": baked_code, "coated": coated_code,
		"coating": coating_code, "coat_rate": coat_rate, "baked_rate": baked_rate,
		"packaging": packaging.keys(), "packaging_per_box": packaging, "needs": needs, "bom_version": boms[code].version,
		"bom_snapshot": _freeze_bom(code)}


func packing_components(spec: Dictionary, rates: Dictionary) -> Dictionary:
	var parts := _by_type(rates, "VERP")
	if not is_equal_approx(float(parts.get("PK-PALLET", 0.0)) * spec.box_kg * spec.boxes_per_pallet, 1.0):
		return {}
	parts.erase("PK-PALLET")
	var per_box := {}
	var carton_parts := 0
	var wrapper_parts := 0
	for code in parts:
		var material: Dictionary = materials[code]
		var is_wrapper: bool = material.get("packaging_role", "") == "retail_wrap"
		var count: int = int(spec.packs_per_box) if is_wrapper else 1
		if material.unit != "ea" or not is_equal_approx(float(parts[code]) * spec.box_kg, count):
			return {}
		per_box[code] = count
		wrapper_parts += int(is_wrapper)
		carton_parts += int(not is_wrapper)
	return per_box if carton_parts == 2 and wrapper_parts <= 1 else {}


func manufacturing_flow(code: String, seen: Dictionary = {}) -> PackedStringArray:
	var result := PackedStringArray()
	if seen.has(code) or not boms.has(code):
		return result
	seen[code] = true
	for part in boms[code].parts:
		result.append_array(manufacturing_flow(part.code, seen))
	result.append(code)
	return result


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
				elif materials[part.code].get("packaging_role", "") == "retail_wrap":
					part.qty = packs
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


## MRP settings for a material, with defaults for anything not set.
func planning(code: String) -> Dictionary:
	var values := PLANNING_DEFAULTS.duplicate()
	values.merge(materials.get(code, {}).get("planning", {}), true)
	return values


func lot_caption(code: String) -> String:
	var p := planning(code)
	var text: String = p.lot_size
	match p.lot_size:
		"FX":
			text += " %s" % _short(p.fixed_lot)
		"PB":
			text += " %s min" % _short(p.period_seconds / 60.0)
	for key in ["min_lot", "max_lot", "rounding"]:
		if p[key] > 0.0:
			text += " · %s %s" % [{"min_lot": "min", "max_lot": "max", "rounding": "round"}[key], _short(p[key])]
	return text


func set_planning(code: String, values: Dictionary) -> String:
	if not materials.has(code):
		return "Unknown material."
	var merged := planning(code)
	merged.merge(values, true)
	var problem := _planning_error(code, merged)
	if not problem.is_empty():
		return problem
	for key in merged:
		if key != "lot_size":
			merged[key] = float(merged[key])
	materials[code].planning = merged
	return ""


func _planning_error(code: String, values: Variant) -> String:
	if not values is Dictionary:
		return "expected an object."
	for key in values:
		if not PLANNING_DEFAULTS.has(key):
			return "unknown setting %s." % key
	var p := PLANNING_DEFAULTS.duplicate()
	p.merge(values, true)
	if not LOT_PROCEDURES.has(p.lot_size):
		return "lot_size must be one of " + ", ".join(PackedStringArray(LOT_PROCEDURES.keys())) + "."
	for key in p:
		if key != "lot_size" and (not (p[key] is float or p[key] is int) or not is_finite(float(p[key])) or float(p[key]) < 0.0):
			return "%s must be a nonnegative number." % key
	if materials[code].type == "FERT" and (p.lot_size != "EX" or p.min_lot > 0 or p.max_lot > 0 or p.rounding > 0):
		return "finished goods are planned lot-for-lot per demand; use safety_time only."
	if p.lot_size == "FX" and p.fixed_lot <= 0.0:
		return "a fixed lot needs fixed_lot above zero."
	if p.lot_size == "PB" and p.period_seconds <= 0.0:
		return "a period lot needs period_seconds above zero."
	if p.max_lot > 0.0 and (p.max_lot < p.min_lot or (p.lot_size == "FX" and p.fixed_lot > p.max_lot)):
		return "max_lot must cover min_lot and the fixed lot."
	return ""


static func _short(value: float) -> String:
	return str(snappedf(value, 0.01)).trim_suffix(".0")


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
	var versions := {}
	var route_ids := {}
	for version in production_versions.values():
		if version.product == source:
			var copy: Dictionary = version.duplicate()
			copy.id = "%s-%s" % [code, copy.routing]
			copy.product = code
			copy.bom_version = header.version
			var route: Dictionary = routings[copy.routing]
			if route.operations.size() == 1:
				var clone: Dictionary = route.duplicate(true)
				clone.id = "%s-%s" % [route.id, code]
				clone.operations[0].output = code
				routings[clone.id] = clone
				route_ids[route.id] = clone.id
				copy.routing = clone.id
			versions[version.id] = copy.id
			production_versions[copy.id] = copy
	for source_standard in standards.values():
		if source_standard.material != source:
			continue
		var standard: Dictionary = source_standard.duplicate(true)
		standard.id = "%s-%s" % [standard.id, code]
		standard.material = code
		if standard.has("production_version"):
			standard.production_version = versions[standard.production_version]
		if standard.has("routing"):
			standard.routing = route_ids.get(standard.routing, standard.routing)
		standards[standard.id] = standard
		if code not in work_centers[standard.work_center].materials:
			work_centers[standard.work_center].materials.append(code)
	return ""
