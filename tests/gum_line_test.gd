extends SceneTree
## Run with: godot --headless --path . --script res://tests/gum_line_test.gd
## Chewing gum family: master data, the mix → form → condition → pan coat → pack chain,
## coating pans that charge centres from carts, and adding the family to older saves.

const Line = preload("res://simulation/production_line.gd")
const API = preload("res://agent/agent_api.gd")
const Save = preload("res://erp/save_game.gd")
const Schedule = preload("res://erp/scheduling.gd")

const GUM_EQUIPMENT := ["GumMixer", "GumSheeter", "FruitFormer", "GumConditioner", "GumPan01", "GumPan02",
	"GumPan03", "WalletPacker", "BottleFiller"]
const GUM_PREFIXES := ["MASS-", "CORE-", "COND-", "PELLET-", "FRUIT-", "FG-30", "RM-GUMBASE", "RM-MALTITOL", "RM-XYLITOL",
	"RM-SORBITOL", "RM-GLUCOSE", "RM-GLYCERIN", "RM-SYRUP-", "RM-WAX", "RM-AROMA-", "RM-COLOR-", "PK-WALLET", "PK-BOTTLE",
	"PK-POUCH-KIDS", "PK-BOX-30", "PK-LABEL-30"]

var _failures := 0


func _initialize() -> void:
	_master_data()
	_production_chain()
	_older_save()
	print("Chewing gum line: %d failures." % _failures)
	quit(int(_failures > 0))


func _master_data() -> void:
	var line := Line.new(Line.Layout.new())
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Gum master data and layout validate")
	var catalog = line.erp.catalog
	var products: Array = catalog.materials.keys().filter(func(code: String) -> bool: return code.begins_with("FG-30"))
	_check(products.size() == 7, "Seven gum products")
	var formats := {}
	for code in products:
		formats[catalog.materials[code].packaging_format] = true
	_check(formats.has("wallet") and formats.has("bottle") and formats.has("kids_pouch"), "Wallet, bottle and kids pouch formats")
	_check(catalog.boms["MASS-SPEAR-SF"].parts.any(func(part: Dictionary) -> bool: return part.code == "RM-GUMBASE")
		and catalog.boms["MASS-SPEAR-SF"].parts.any(func(part: Dictionary) -> bool: return part.code == "RM-MALTITOL"),
		"Sugar-free mass is gum base with a polyol")
	_check(catalog.boms["MASS-STRAW"].parts.any(func(part: Dictionary) -> bool: return part.code == "RM-SORBITOL")
		and catalog.boms["MASS-STRAW"].parts.any(func(part: Dictionary) -> bool: return part.code == "RM-SUGAR"),
		"Kids mass is sugary with sorbitol")
	var pans := Schedule.alternatives(catalog, "FRUIT-STRAW", 40.0, 0.0)
	_check(pans.size() == 3, "All three coating pans can coat fruit gum")
	var flow := ", ".join(catalog.manufacturing_flow("FG-3005"))
	_check(flow.contains("MASS-STRAW") and flow.contains("CORE-STRAW") and flow.contains("COND-STRAW")
		and flow.contains("FRUIT-STRAW"), "Kids gum flows through mass, centres, conditioning and coating")
	for id in GUM_EQUIPMENT:
		_check(line.cell_machines.has(StringName(id)), "Cell machine for " + id)


func _production_chain() -> void:
	var api := API.new()
	var line: Line = api.line
	var book = line.erp
	var base_before: float = book.stock("RM-GUMBASE", "RM-WH")
	var syrup_before: float = book.stock("RM-SYRUP-SUGAR", "RM-WH")
	for row in [["FG-3001", 8], ["FG-3003", 8], ["FG-3005", 8]]:
		api.handle({"cmd": "create_demand", "args": {"code": row[0], "boxes": row[1], "due": 30000}})
	api.handle({"cmd": "run_mrp", "args": {}})
	var created: Array = api.handle({"cmd": "convert_all", "args": {}}).get("created", [])
	_check(created.size() == 15, "MRP plans five stages for each of three products")
	api.handle({"cmd": "set_auto_release", "args": {"enabled": true}})
	var pan_charged := false
	for step in 80:
		api.handle({"cmd": "advance", "args": {"seconds": 600}})
		for id in [&"GumPan01", &"GumPan02", &"GumPan03"]:
			var cell = line.active_cell(id)
			pan_charged = pan_charged or (cell != null and cell.remaining > 0.0 and cell.batch_output > 0.0)
		if created.all(func(id: String) -> bool: return book.orders[id].status == "Completed"):
			break
	_check(created.all(func(id: String) -> bool: return book.orders[id].status == "Completed"), "Every gum order completes")
	_check(pan_charged, "A coating pan charges centres from its input stock")
	var boxes := {}
	for pallet in line.warehouse:
		if pallet != null:
			boxes[pallet.sku] = int(boxes.get(pallet.sku, 0)) + pallet.boxes
	_check(boxes.get("FG-3001", 0) == 8 and boxes.get("FG-3003", 0) == 8 and boxes.get("FG-3005", 0) == 8,
		"Eight boxes of wallet, bottle and kids gum reach the warehouse")
	var masses := 0.0
	for id in created:
		var order: Dictionary = book.orders[id]
		if order.code.begins_with("MASS-"):
			masses += order.recipe.target * (0.24 if order.code == "MASS-STRAW" else 0.30)
	_check(is_equal_approx(snappedf(base_before - book.stock("RM-GUMBASE", "RM-WH"), 0.001), snappedf(masses, 0.001)),
		"Gum base use matches the mass BOMs")
	var fruit: Dictionary = book.orders[created.filter(func(id: String) -> bool: return book.orders[id].code == "FRUIT-STRAW")[0]]
	_check(is_equal_approx(snappedf(syrup_before - book.stock("RM-SYRUP-SUGAR", "RM-WH"), 0.001), snappedf(fruit.recipe.target * 0.34, 0.001)),
		"Sugar syrup use matches the pan coating BOM")
	_check(book.stock("RM-GUMBASE", "GUM-IN") >= 0.0 and book.balances.has("GUM-PAN-IN"), "Gum staging locations hold stock")


func _older_save() -> void:
	# A save written before the gum family: catalog, ledger locations and layout rows removed.
	var line := Line.new(Line.Layout.new())
	line.enable_erp()
	var data := Save.snapshot(line)
	for field in ["materials", "boms", "routings", "production_versions", "standards"]:
		for key in data.catalog[field].keys():
			var code: String = data.catalog[field][key].get("material", data.catalog[field][key].get("product", key)) \
				if field in ["standards", "production_versions"] else key
			if GUM_PREFIXES.any(func(prefix: String) -> bool: return code.begins_with(prefix)):
				data.catalog[field].erase(key)
	for id in data.catalog.work_centers.keys():
		if data.catalog.work_centers[id].equipment in GUM_EQUIPMENT:
			data.catalog.work_centers.erase(id)
	var packer: Dictionary = data.catalog.work_centers["WC-PKG-02"]
	packer.materials = packer.materials.filter(func(code: String) -> bool: return not code.begins_with("FG-30"))
	packer.categories = packer.categories.filter(func(family: String) -> bool: return family != "Chewing gum")
	for stage in ["gum_mix", "gum_form", "gum_condition", "gum_coat"]:
		data.catalog.scheduling.stages.erase(stage)
	for location in ["GUM-IN", "GUM-PAN-IN", "GUM-PACK-IN"]:
		data.catalog.locations.erase(location)
		data.erp.balances.erase(location)
	for location in data.erp.balances.values():
		for code in location.keys():
			if GUM_PREFIXES.any(func(prefix: String) -> bool: return code.begins_with(prefix)):
				location.erase(code)
	data.layout.objects = data.layout.objects.filter(func(row: Dictionary) -> bool: return row.id not in GUM_EQUIPMENT)
	for id in GUM_EQUIPMENT:
		data.plan.erase(StringName(id))
	# The owner moved the cream mixer into the area the gum line uses by default.
	data.plan[&"CreamMixer"] = [Vector2i(66, 34), 0]
	var restored := Save.restore(data)
	_check(restored.error.is_empty(), "An older save loads with the gum family added")
	if not restored.error.is_empty():
		printerr(restored.error)
		return
	var loaded: Line = restored.line
	var catalog = loaded.erp.catalog
	_check(catalog.materials.has("FG-3005") and catalog.work_centers.has("WC-PAN-03")
		and catalog.scheduling.stages.has("gum_coat") and "FG-3005" in catalog.work_centers["WC-PKG-02"].materials,
		"Gum products, work centers, stages and Packer 02 eligibility are merged")
	_check(is_equal_approx(loaded.erp.stock("RM-GUMBASE", "RM-WH"), catalog.opening["RM-GUMBASE"]), "New ingredients get opening stock")
	_check(loaded.layout.objects[&"CreamMixer"].cell == Vector2i(66, 34), "Saved placements are kept")
	_check(loaded.layout.objects[&"GumSheeter"].cell != Vector2i(66, 34) and loaded.layout.validate().is_empty(),
		"New equipment moves clear of the saved layout and the plan validates")
	_check(loaded.erp.create_order("FG-3005", 4, loaded.erp.now, 5, "").error.is_empty(), "Gum orders can be planned in the older save")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
