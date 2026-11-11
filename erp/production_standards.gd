extends RefCounted
## Product-operation-resource standards, unit conversions, and illustrative cleaning rules.
const Storage = preload("res://simulation/storage.gd")
const EPS := 0.000001
const MODELS := ["continuous", "batch", "packaging", "residence"]
const UNITS := ["kg/h", "pieces/h", "cartons/h"]


static func validate(catalog) -> String:
	var signatures := {}
	var covered := {}
	for id in catalog.standards:
		var row: Dictionary = catalog.standards[id]
		var prefix := "production_standards.json [%s]" % id
		var material: Dictionary = catalog.materials.get(row.get("material"), {})
		var center: Dictionary = catalog.work_centers.get(row.get("work_center"), {})
		if material.is_empty() or center.is_empty() or material.procurement != "In-house":
			return prefix + ": missing manufactured material or work center."
		if row.get("operation") != center.operation or row.get("model") not in center.get("models", []) \
				or row.material not in center.get("materials", []) or material.get("family", "") not in center.categories:
			return prefix + ": unsupported material, operation, model or work center capability."
		if not row.get("active") is bool or not catalog.Master.number(row.get("version"), 1, INF, true) \
				or not catalog.Master.number(row.get("valid_from")) or not catalog.Master.number(row.get("valid_to")) \
				or (row.valid_to > 0 and row.valid_to < row.valid_from):
			return prefix + ": invalid status, version or validity interval."
		for field in ["setup_seconds", "scrap_expectation"]:
			if not catalog.Master.number(row.get(field), 0, 86400 if field == "setup_seconds" else 1):
				return prefix + "." + field + ": invalid value."
		if not catalog.Master.number(row.get("yield_factor"), EPS, 1):
			return prefix + ".yield_factor: expected a yield above zero and at most one."
		if not row.get("yield_loss_reason", "") is String:
			return prefix + ".yield_loss_reason: expected a description."
		for reference in ["routing", "production_version"]:
			if row.has(reference) and not catalog.get("routings" if reference == "routing" else "production_versions").has(row[reference]):
				return prefix + "." + reference + ": missing reference."
		var route_id: String = row.get("routing", "")
		if row.has("production_version"):
			var version: Dictionary = catalog.production_versions[row.production_version]
			if version.product != row.material or (not route_id.is_empty() and route_id != version.routing):
				return prefix + ".production_version: the version must match this material and routing."
			route_id = version.routing
		if not route_id.is_empty() and not catalog.routings[route_id].operations.any(func(op: Dictionary) -> bool:
			return op.type == row.operation and op.work_center == row.work_center):
			return prefix + ".routing: the operation is missing from the routing."
		covered["%s|%s" % [row.material, row.work_center]] = true
		var key := "%s|%s|%s|%s|%s" % [row.material, row.operation, row.work_center,
			row.get("routing", ""), row.get("production_version", "")]
		for prior in signatures.get(key, []):
			if row.valid_from < (INF if prior.valid_to == 0 else prior.valid_to) \
					and prior.valid_from < (INF if row.valid_to == 0 else row.valid_to):
				return prefix + ": overlapping duplicate production standard."
		if not signatures.has(key):
			signatures[key] = []
		signatures[key].append(row)
		if row.model in ["packaging", "residence"] and row.yield_factor != 1.0:
			return prefix + ".yield_factor: this model preserves product mass."
		if row.model == "batch":
			for field in ["batch_kg", "min_batch_kg", "cycle_seconds", "loading_seconds", "unloading_seconds"]:
				if not catalog.Master.number(row.get(field), EPS):
					return prefix + "." + field + ": expected a positive batch parameter."
			if row.min_batch_kg > row.batch_kg or row.batch_kg > center.technical.batch_kg:
				return prefix + ".batch_kg: minimum batch or design capacity is incompatible."
		else:
			if not catalog.Master.number(row.get("rate"), EPS) or row.get("unit") not in UNITS:
				return prefix + ".rate/unit: expected a positive supported rate."
			if (row.model == "packaging") != (row.unit == "cartons/h") \
					or (row.model == "packaging" and material.type != "FERT") \
					or (row.unit == "pieces/h" and not catalog.Master.number(material.get("piece_kg"), EPS)):
				return prefix + ".unit: incompatible material or processing model."
			if kg_per_hour(row, material) > float(center.technical.get("rate", INF)) + EPS:
				return prefix + ".rate: exceeds the work center's design maximum."
			if row.model == "residence":
				if not catalog.Master.number(row.get("residence_seconds"), EPS) \
						or not catalog.Master.number(row.get("internal_kg"), EPS, center.technical.internal_kg):
					return prefix + ": invalid residence time or internal capacity."
	for center in catalog.work_centers.values():
		for code in center.materials:
			if not covered.has("%s|%s" % [code, center.id]):
				return "production_standards.json: missing standard for %s on %s." % [code, center.id]
	for rule in catalog.changeovers.values():
		if rule.get("operation") != "*" and not catalog.PARAMETERS.has(rule.get("operation")):
			return "changeovers.json [%s].operation: unknown operation." % rule.id
		if rule.get("dimension") not in ["material", "family", "coating", "flavor", "packaging_format", "cleaning_group"] \
				or not rule.get("from_value") is String or not rule.get("to_value") is String \
				or not catalog.Master.number(rule.get("seconds")):
			return "changeovers.json [%s]: invalid changeover rule." % rule.id
	return ""


static func resolve(catalog, code: String, operation: Dictionary, when: float, route: String, version: String) -> Dictionary:
	var matches := []
	var specificity := -1
	for standard in catalog.standards.values():
		if standard.material == code and standard.operation == operation.type and standard.work_center == operation.work_center \
				and standard.active and standard.valid_from <= when and (standard.valid_to == 0 or when < standard.valid_to) \
				and standard.get("routing", route) == route and standard.get("production_version", version) == version:
			var rank := 2 if standard.has("production_version") else int(standard.has("routing"))
			if rank > specificity:
				matches.clear()
				specificity = rank
			if rank == specificity:
				matches.append(standard)
	if matches.size() != 1:
		return {"error": "Expected one valid production standard for %s / %s / %s. Found %d." %
			[code, operation.type, operation.work_center, matches.size()]}
	return {"error": "", "standard": matches[0].duplicate(true)}


static func kg_per_hour(standard: Dictionary, material: Dictionary) -> float:
	match standard.get("unit", ""):
		"kg/h": return standard.rate
		"cartons/h": return standard.rate * material.box_kg
		"pieces/h": return standard.rate * material.piece_kg
	return 0.0


static func batch_count(standard: Dictionary, output: float) -> int:
	var capacity: float = standard.batch_kg * standard.yield_factor
	return maxi(0, ceili((output - Storage.MASS_EPSILON) / capacity))


static func processing_seconds(standard: Dictionary, material: Dictionary, output: float) -> float:
	match standard.model:
		"batch":
			return batch_count(standard, output) * (standard.cycle_seconds + standard.loading_seconds + standard.unloading_seconds)
		"residence":
			var throughput := minf(kg_per_hour(standard, material), standard.internal_kg * 3600.0 / standard.residence_seconds)
			return output * 3600.0 / throughput + standard.residence_seconds
		_:
			return output * 3600.0 / kg_per_hour(standard, material)


static func changeover(catalog, previous: Dictionary, current: Dictionary, operation: String, base: float = 0.0, frozen: Dictionary = {}) -> float:
	if previous.is_empty():
		return base
	if previous.get("code") == current.get("code"):
		return 0.0
	var seconds := base
	for rule in (catalog.changeovers if frozen.is_empty() else frozen).values():
		if rule.operation not in ["*", operation]:
			continue
		var before: String = previous.get("code" if rule.dimension == "material" else rule.dimension, "")
		var after: String = current.get("code" if rule.dimension == "material" else rule.dimension, "")
		if before != after and rule.from_value in ["*", before] and rule.to_value in ["*", after]:
			seconds = maxf(seconds, rule.seconds)
	return seconds


static func caption(standard: Dictionary) -> String:
	if standard.is_empty():
		return "Legacy saved parameters"
	if standard.model == "batch":
		return "%.1f kg/batch · %.1f min cycle · %.1fs load / %.1fs unload" % [
			standard.batch_kg, standard.cycle_seconds / 60, standard.loading_seconds, standard.unloading_seconds]
	var label := "%.1f %s" % [standard.rate, standard.unit]
	if standard.model == "residence":
		label += " · %.1fs residence · %.1f kg internal" % [standard.residence_seconds, standard.internal_kg]
	return label
