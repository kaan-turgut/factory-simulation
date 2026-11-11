extends SceneTree

const Line = preload("res://simulation/production_line.gd")
const MRP = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const EPS := 1e-6

var _failures := 0


func _initialize() -> void:
	_master_data()
	_packaging_migration()
	_purchase_and_transfer()
	_reservations()
	_late_receipt_and_safety()
	_competing_demand()
	_planning_and_manufacturing()
	_floor_crew_migration()
	_thousand_box_order()
	print("ChocoERP integration checks, %d failures." % _failures)
	quit(int(_failures > 0))


func _master_data() -> void:
	var catalog := Line.ERP.Catalog.new()
	var colors := {}
	for index in range(1001, 1006):
		var code := "FG-%d" % index
		var recipe := catalog.recipe(code, 9)
		_check(recipe.error.is_empty(), code + " has an executable BOM")
		if not recipe.error.is_empty():
			continue
		colors[recipe.spec.package_color] = true
		_near(recipe.spec.pack_kg, 0.1, code + " uses 100 g packs")
		_near(recipe.spec.packs_per_box, 50.0, code + " uses 50 packs per shipping box")
		_near(recipe.spec.box_kg, 5.0, code + " uses 5 kg shipping boxes")
		_near(recipe.spec.boxes_per_pallet, 8.0, code + " uses eight-box pallets")
		_near(recipe.spec.batch_kg, 40.0, code + " uses 40 kg full pallets")
		_near(catalog.boms[code].base, 5.0, code + " uses a one-box BOM base")
		_near(recipe.needs["PK-BOX-%d" % index], 9.0, code + " uses one carton per box")
		_near(recipe.needs["PK-LABEL-%d" % index], 9.0, code + " uses one label per box")
		_near(recipe.needs["PK-WRAP"], 450.0, code + " uses one wrapper per retail pack")
		_near(recipe.needs[recipe.coating], recipe.target * 0.2, "Variant coating explosion")
		_near(recipe.needs["RM-FLOUR"], recipe.target * 0.8 * 0.44, "Combined-route flour explosion")
		_near(recipe.needs["PK-PALLET"], ceilf(9.0 / recipe.spec.boxes_per_pallet), "Pallet rounding")
	_check(colors.size() == 5, "Portfolio distinguishes packaging")
	_check(catalog.clone_product("FG-1002", "FG-1020", "Dark trial").is_empty(), "Clone stable SKU")
	_check(catalog.recipe("FG-1020", 4).error.is_empty(), "Cloned routing and BOM are valid")
	var reject := catalog.save_bom("DOUGH-01", 1, [{"code": "FG-1002", "qty": 1.0, "unit": "kg", "scrap": 0.0}], true)
	_check(not reject.is_empty(), "BOM cycle rejected")
	var old_version: int = catalog.boms["FG-1020"].version
	_check(catalog.edit_material("FG-1020", "Dark trial", 0.0, 240.0, true, 0.125, 40, 6).is_empty(),
		"Dependent product sizes update")
	var edited := catalog.recipe("FG-1020", 7)
	_check(edited.error.is_empty() and edited.bom_version == old_version + 1, "Changed spec versions its BOM")
	_near(edited.target, 35.0, "Consumer pack weight derives shipping weight")
	_near(edited.needs["PK-WRAP"], 280.0, "Wrapper BOM follows the packs per carton")


func _packaging_migration() -> void:
	var line := _line()
	var book := line.erp
	var code := "FG-1002"
	var catalog := book.catalog
	catalog.edit_material(code, "Dark wafer (saved name)", 3.0, 210.0, true, 0.08, 50, 8)
	catalog.boms[code].version = 1
	catalog._update_bom_versions(code)
	catalog.edit_material("FG-1003", "Custom white wafer", 0.0, 240.0, true, 0.12, 40, 10)
	var dark_demand := book.create_demand(code, 3, 1500.0)
	book.adjust("RM-COAT-1002", 2.0, "Saved stock fixture")
	var released := book.create_order(code, 2, 1000.0, 1)
	_check(book.release(released.id).is_empty(), "Release an order with the original carton size")
	var data := Save.snapshot(line)
	data.version = 4
	var result := Save.restore(data)
	_check(result.error.is_empty(), "Load a shift with original carton sizes")
	if not result.error.is_empty():
		return
	var restored: Line = result.line
	var updated := restored.erp.catalog.recipe(code, 2)
	_check(updated.error.is_empty() and updated.bom_version == 2, "Migrated BOM and production versions agree")
	_near(updated.target, 10.0, "New orders use standard 5 kg cartons")
	_near(restored.erp.demands[dark_demand.id].recipe.target, 15.0, "Unconverted demand keeps its planned box count")
	_near(restored.erp.catalog.materials["FG-1003"].box_kg, 4.8, "Custom packaging stays intact")
	_check(updated.spec.name == "Dark wafer (saved name)" and updated.spec.minimum == 3.0,
		"Migration preserves unrelated material fields")
	_check(restored.erp.orders[released.id] == book.orders[released.id]
		and restored.erp.reservations == book.reservations and restored.erp.balances == book.balances,
		"Migration preserves the released specification, reservation and stock")
	var reloaded := Save.restore(Save.snapshot(restored))
	_check(reloaded.error.is_empty() and reloaded.line.erp.catalog.boms[code].version == 2,
		"Saving a migrated shift preserves the new BOM version")


func _purchase_and_transfer() -> void:
	var line := _line()
	var b := line.erp
	var opening_coating := b.stock("RM-COAT-1002", "RM-WH")
	var po := b.purchase("SUP-02", "RM-COAT-1002", 12.0)
	_check(po.error.is_empty(), "Create purchase order")
	_near(b.stock("RM-COAT-1002", "RM-WH"), opening_coating, "Purchase creates no early stock")
	_check(not b.receive(po.id, 5.0).is_empty(), "Early manual receipt blocked")
	b.now = b.purchases[po.id].due
	_check(b.receive(po.id, 5.0).is_empty() and b.purchases[po.id].status == "Partial", "Partial receipt")
	_check(not b.receive(po.id, 8.0).is_empty(), "Over-receipt blocked")
	_check(b.receive(po.id, 7.0).is_empty() and b.purchases[po.id].status == "Received", "Complete remainder")
	_near(b.stock("RM-COAT-1002", "RM-WH"), opening_coating + 12.0, "Actual receipts update stock")
	var opening := b.stock("RM-FLOUR", "RM-WH")
	_check(b.manual_transfer("RM-FLOUR", 25.0, "RM-WH", "RM-STAGE", "Physical transfer test").is_empty(),
		"Queue transfer to mezzanine")
	_near(b.stock("RM-FLOUR", "RM-STAGE"), 0.0, "Transfer does not teleport")
	line.set_playing(true)
	line.advance(1.0)
	_near(b.stock("RM-FLOUR", "TRANSIT"), 25.0, "Material travels on the pallet jack")
	_near(b.stock("RM-FLOUR", "RM-WH"), opening - 25.0, "Pickup decrements warehouse once")
	var snapshot := Save.snapshot(line)
	snapshot.version = 9
	snapshot.shuttle.title = "Material shuttle"
	snapshot.shuttle.state = Line.Operator.State.DRIVING
	var saved := Save.restore(snapshot)
	_check(saved.error.is_empty() and saved.line.erp.material_handler.state == Line.Operator.State.MOVING_PALLET_JACK
		and saved.line.erp.material_handler.title == Line.ERP.MATERIAL_HANDLER_TITLE,
		"A legacy supply trip resumes with the material handler")
	if not saved.error.is_empty():
		return
	line = saved.line
	b = line.erp
	line.set_playing(true)
	line.advance(75.0)
	_near(b.stock("RM-FLOUR", "RM-STAGE"), 25.0, "Travel and handling complete transfer")
	_near(b.stock("RM-FLOUR", "TRANSIT"), 0.0, "Transit cleared after drop")
	_near(b.reservations["RM-FLOUR"], 0.0, "Transfer reservation released")
	_check(not b.adjust("RM-FLOUR", -100000.0, "Count").is_empty(), "Negative inventory rejected")


func _reservations() -> void:
	var line := _line()
	var b := line.erp
	var opening := b.stock("RM-COAT-1001", "RM-WH")
	var id: String = b.create_order("FG-1001", 8, 400.0, 5).id
	_check(b.release(id).is_empty(), "Release a fully covered order")
	_check(not b.release(id).is_empty(), "Release is not repeatable")
	_near(b.reservations["RM-COAT-1001"], 8.0, "Release reserves exact coating quantity")
	_near(b.stock("RM-COAT-1001", "RM-WH"), opening, "Release does not consume physical stock")
	_check(not b.adjust("RM-COAT-1001", -opening, "Count").is_empty(), "Adjustment protects reservations")
	_check(not b.transition(id, "Closed").is_empty(), "Released cannot close directly")
	var plan := MRP.new()
	plan.run(b, line.erp_fg())
	_check(plan.summary.requirements == 0, "MRP excludes already reserved order demand")
	_check(b.transition(id, "Cancelled").is_empty(), "Cancel released pending order")
	_near(b.reservations["RM-COAT-1001"], 0.0, "Cancellation releases reservation")


func _late_receipt_and_safety() -> void:
	var line := _line()
	var b := line.erp
	b.adjust("RM-COAT-1002", -b.stock("RM-COAT-1002", "RM-WH"), "Shortage test")
	var material: Dictionary = b.catalog.materials["RM-COAT-1002"]
	material.minimum = 2.0
	material.lead = 120.0
	var id: String = b.create_order("FG-1002", 2, 0.0, 1).id
	var plan := MRP.new()
	plan.run(b, {})
	var key := "BUY|" + id + "|RM-COAT-1002"
	_near(plan.proposals[key].qty, 4.0, "MRP replenishes demand plus safety stock")
	_check(plan.proposals[key].start < b.now, "Planning lead flags a past release date")
	_check(plan.convert(key, b, {}).error.is_empty(), "Convert late purchase")
	_check(not plan.proposals.has(key) and plan.summary.late > 0, "Late open PO is visible without duplication")
	_check(plan.rows.any(func(row: Dictionary) -> bool: return row.kind == "Late scheduled receipt"),
		"Time-phased projection identifies the late receipt")
	for row in plan.rows:
		if row.code == "RM-COAT-1002" and row.kind == "BOM requirement":
			_near(row.projected, -2.0, "Future receipts do not appear in projected stock before arrival")


func _competing_demand() -> void:
	var line := _line()
	var book := line.erp
	var first: String = book.create_demand("FG-1001", 8, 800.0).id
	var plan := MRP.new()
	var first_order := plan.convert("MAKE|" + first, book, {})
	_check(first_order.error.is_empty(), "Convert the first demand")
	if not first_order.error.is_empty():
		return
	var second: String = book.create_demand("FG-1001", 8, 1800.0).id
	plan.run(book, {})
	_check(plan.proposals.has("MAKE|" + second), "Second demand cannot reuse the first demand's future output")
	_check(book.release(first_order.id).is_empty(), "Release demand-linked order")
	line.set_playing(true)
	line.advance(1800.0)
	plan.run(book, line.erp_fg())
	_check(line.warehouse_count() == 1 and plan.proposals.has("MAKE|" + second),
		"Second demand cannot reuse the first demand's physically received output")
	var second_order := plan.convert("MAKE|" + second, book, line.erp_fg())
	_check(second_order.error.is_empty() and book.transition(second_order.id, "Cancelled").is_empty(),
		"Cancel a linked pending order")
	plan.run(book, line.erp_fg())
	_check(plan.proposals.has("MAKE|" + second), "Cancellation lets MRP plan unmet demand again")


func _planning_and_manufacturing() -> void:
	var layout := Line.Layout.new()
	_check(layout.move(&"Oven", Vector2i(16, 16), 1).is_empty(), "ERP uses placed factory layout")
	var line := Line.new(layout)
	line.enable_erp(false)
	var b := line.erp
	b.adjust("RM-COAT-1002", -b.stock("RM-COAT-1002", "RM-WH"), "Shortage test")
	var demand := b.create_demand("FG-1002", 13, 420.0)
	var plan := MRP.new()
	plan.run(b, line.erp_fg())
	var purchase_key := "BUY|" + String(demand.id) + "|RM-COAT-1002"
	var make_key := "MAKE|" + String(demand.id)
	_check(plan.proposals.has(purchase_key) and plan.proposals.has(make_key), "Demand creates make and buy proposals")
	if not plan.proposals.has(purchase_key) or not plan.proposals.has(make_key):
		return
	_near(plan.proposals[purchase_key].qty, 13.0, "MRP finds exact dark coating shortage")
	_check(plan.summary.buy == 1 and plan.summary.make == 1 and plan.summary.shortages.size() == 1,
		"MRP distinguishes one shortage from other covered inputs")
	plan.run(b, line.erp_fg())
	_check(plan.proposals.size() == 2 and b.purchases.is_empty(), "Rerun replaces proposals without buying")
	var order_doc := plan.convert(make_key, b, line.erp_fg())
	_check(order_doc.error.is_empty(), "Make proposal creates production document")
	if not order_doc.error.is_empty():
		return
	var id: String = order_doc.id
	_check("RM-COAT-1002" in b.release(id), "Release identifies missing ingredient")
	_check(not plan.proposals.has(make_key) and b.demands[demand.id].converted == id, "Converted demand is not planned twice")
	var order_buy := "BUY|" + id + "|RM-COAT-1002"
	var purchase := plan.convert(order_buy, b, line.erp_fg())
	_check(purchase.error.is_empty(), "Convert MRP proposal to PO")
	_check(not plan.proposals.has(order_buy), "Open PO nets the shortage without a duplicate")
	line.set_playing(true)
	line.advance(89.75)
	_near(b.stock("RM-COAT-1002", "RM-WH"), 0.0, "No inventory before actual receipt")
	_check(line.warehouse_count() == 0 and line.extruder.total_output == 0.0, "No production without release")
	line.advance(0.25)
	_near(b.stock("RM-COAT-1002", "RM-WH"), 13.0, "Timed receipt posts missing chocolate")
	_check(b.release(id).is_empty() and b.orders[id].status == "Released", "Release covered order")
	_check(line.warehouse_count() == 0 and b.orders[id].consumed.is_empty(), "Release is not production")
	for step in 1400:
		line.advance(Line.STEP_SECONDS)
		if not b.shipment.is_empty() and b.shipment.phase == 1 and b.active_id == id:
			break
	_check(b.active_id == id and not b.shipment.is_empty(), "Actual order starts a physical supply task")
	_check(not b.transition(id, "Cancelled").is_empty(), "Active order cannot erase WIP")
	var path := "user://choco-erp-test-%d.save" % OS.get_process_id()
	_check(Save.save(line, path).is_empty(), "Write versioned local save mid-transfer")
	var saved := Save.load_line(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(saved.error.is_empty(), "Load saved shipment, documents, inventory and layout")
	if not saved.error.is_empty():
		return
	var restored: Line = saved.line
	_check(not restored.playing and restored.layout.objects[&"Oven"].turns == 1, "Restore paused with the same placement")
	restored.set_playing(true)
	line.advance(1250.0)
	restored.advance(1250.0)
	_check(Save.snapshot(restored) == Save.snapshot(line), "Reload resumes with exact stock, jobs and movement IDs")
	var order: Dictionary = b.orders[id]
	_check(order.status == "Completed" and order.received == 13 and order.packed == 13,
		"Finished quantity is received through forklift before completion")
	_check(order.started >= order.start and order.completed > order.started + 36.0, "Production requires elapsed time")
	_near(order.received_kg, 65.0, "Finished quantity in kg")
	_near(line.erp_fg().get("FG-1002", 0.0), 65.0, "ERP reads physical warehouse stock")
	_check(line.warehouse_count() == 2 and line.warehouse[1].boxes == 5 and line.warehouse[1].sealed,
		"Final partial pallet occupies real warehouse space")
	_near(order.consumed.get("RM-COAT-1002", 0.0), 13.0, "Physical coating consumption")
	_near(order.consumed.get("RM-FLOUR", 0.0), 22.88, "Physical batter consumption")
	_near(order.consumed.get("PK-BOX-1002", 0.0), 13.0, "Packaging consumed as cartons form")
	_near(order.consumed.get("PK-WRAP", 0.0), 650.0, "Film consumed as retail packs are formed")
	_near(order.consumed.get("PK-PALLET", 0.0), 2.0, "Actual pallets consumed")
	_near(b.reservations.get("RM-COAT-1002", 0.0), 0.0, "Completed order releases remaining reservation")
	var ids := {}
	var fg_kg := 0.0
	var receipts := 0
	for row in b.movements:
		_check(not ids.has(row.id), "Movement ID is unique")
		ids[row.id] = true
		if row.type == "FG Receipt" and row.document == id:
			fg_kg += row.qty
			receipts += 1
	_near(fg_kg, 65.0, "Order document traces warehouse receipts")
	_check(receipts == 2 and line.erp_wip().is_empty(), "Exactly two receipts and drained WIP")
	_check(b.transition(id, "Closed").is_empty(), "Completed document can close")
	_changeover(line)
	_check(line.dispatch(false) == 1, "Dispatch removes one physical pallet")
	_near(line.erp_fg().get("FG-1002", 0.0), 25.0, "ERP dispatch derives from the pallet inventory")
	for stock in b.balances.values():
		for value in stock.values():
			_check(value >= 0.0, "All externally stocked material stays nonnegative")


func _changeover(line: Line) -> void:
	var b := line.erp
	b.coat_setup_seconds = 20.0
	b.pack_setup_seconds = 10.0
	var next: String = b.create_order("FG-1001", 3, b.now, 1).id
	_check(b.release(next).is_empty(), "Queue a different SKU on the shared line")
	line.advance(1.0)
	_check(b.active_id == next and b.coat_remaining > 0 and b.pack_remaining > 0, "Different SKU starts both setups")
	_check(line.coater.state == Line.Machine.State.SETUP and line.packer.state == Line.Machine.State.SETUP,
		"Machines visibly enter Setup")
	var before := line.coater.total_output
	line.advance(15.0)
	_check(b.coat_remaining > 0 and b.pack_remaining == 0.0, "Parallel timers respect distinct durations")
	_near(line.coater.total_output, before, "Setup blocks processing")
	line.advance(900.0)
	_check(b.orders[next].status == "Completed" and line.warehouse_count() == 3, "Second SKU completes independently")
	_near(line.erp_fg().get("FG-1001", 0.0), 15.0, "Second SKU stays separate")
	_near(line.erp_fg().get("FG-1002", 0.0), 65.0, "First SKU remains intact")


func _floor_crew_migration() -> void:
	var line := _line()
	line.set_setting(&"floor_count", 2.0)
	line.reset()
	var book := line.erp
	var order := book.create_order("FG-1001", 8, 0, 1)
	_check(order.error.is_empty() and book.release(order.id).is_empty(), "Release the old crew's order")
	line.set_playing(true)
	for tick in 2000:
		line.advance(Line.STEP_SECONDS)
		if not line.floor_assignments.is_empty():
			break
	_check(not line.floor_assignments.is_empty(), "Save while a floor job is assigned")
	var current := Save.snapshot(line)
	var custom := Save.restore(current)
	_check(custom.error.is_empty() and custom.line.floor_crew.size() == 2, "Current saves preserve a chosen crew size")
	var previous := current.duplicate(true)
	previous.version = 6
	var result := Save.restore(previous)
	_check(result.error.is_empty(), "Restore the old two-worker shift")
	if not result.error.is_empty():
		return
	var restored: Line = result.line
	var migrated := Save.snapshot(restored)
	_check(restored.floor_crew.size() == 4 and restored.settings[&"floor_count"] == 4
		and restored.find_operator(&"Worker3") != null and restored.find_operator(&"Worker4") != null,
		"Old shift gains two new floor workers")
	_check(migrated.floor.slice(0, 2) == previous.floor and migrated.jobs == previous.jobs
		and restored.erp.orders == book.orders and restored.erp.balances == book.balances,
		"Additional crew preserves the original workers, assignments and inventory")
	restored.set_playing(true)
	restored.advance(900.0)
	_check(restored.erp.orders[order.id].status == "Completed" and is_equal_approx(restored.warehouse_mass(), 40.0),
		"Saved order completes with the expanded crew")


func _thousand_box_order() -> void:
	var line := _line()
	var book := line.erp
	var id: String = book.create_order("FG-1001", 1000, 0.0, 1).id
	_check(book.release(id).is_empty(), "Release 1,000 boxes from opening stock")
	line.set_playing(true)
	for interval in 64:
		line.advance(250.0)
		if line.warehouse_count() == 24:
			break
	_check(line.warehouse_count() == 24 and book.orders[id].status == "In Progress",
		"Full physical warehouse holds a large order")
	line.set_setting(&"floor_count", 3)
	line.reset()
	_check(not line.playing and line.floor_crew.size() == 4 and book.active_id == id,
		"Reset preserves the active order and its assigned fleet")
	line.set_playing(true)
	for interval in 320:
		line.dispatch(true)
		line.advance(160.0)
		if book.orders[id].status == "Completed":
			break
	var order: Dictionary = book.orders[id]
	_check(order.status == "Completed" and order.received == 1000, "Dispatch lets the 1,000-box order finish")
	_near(order.received_kg, 5000.0, "1,000-box order ships its full mass")
	_near(order.consumed.get("RM-COAT-1001", 0.0), 1000.0, "Large order consumes its reserved coating exactly")
	_check(line.erp_wip().is_empty(), "Large order drains all WIP")
	var stock := line.warehouse_mass()
	line.reset()
	_check(not line.playing and line.floor_crew.size() == 3 and order.status == "Completed",
		"Reset between orders applies fleet settings and preserves documents")
	_near(line.warehouse_mass(), stock, "Fleet reconfiguration preserves stored pallets")


func _line() -> Line:
	var line := Line.new()
	line.enable_erp(false)
	return line


func _near(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < EPS, "%s (%.9f vs %.9f)" % [message, actual, expected])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
