extends SceneTree
## Product/resource standards, explicit filled-wafer orders and physical work in progress.
const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const Scheduling = Line.ERP.Scheduling
const Standards = Line.ERP.Catalog.Standards
const Scene = preload("res://scenes/factory.tscn")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_rates_and_eligibility()
	_setup_and_batches()
	_minimum_lot_and_yield()
	_filled_family()
	await _expanded_scene()
	print("Production Standards and filled wafers: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Load and validate the expanded master data and hall")
	return line


func _rates_and_eligibility() -> void:
	var line := _line()
	var book := line.erp
	var catalog := book.catalog
	var milk := Scheduling.assignment(book, "COATED-1001", 20, 0, "COATED-1001/WC-COT-01")
	var dark := Scheduling.assignment(book, "COATED-1002", 20, 0, "COATED-1002/WC-COT-01")
	var other := Scheduling.assignment(book, "COATED-1001", 20, 0, "COATED-1001/WC-COT-02")
	_check(milk.error.is_empty() and dark.error.is_empty() and other.error.is_empty(), "Select product/resource standards")
	_check(milk.route.operations[0].standard.rate == 420.0 and dark.route.operations[0].standard.rate == 370.0,
		"Same coater runs different materials at different standard rates")
	_check(milk.duration < other.duration, "Same product takes longer on the slower alternative")
	var draft := book.create_order("COATED-1001", 20, 0, 1, "COATED-1001/WC-COT-01")
	var order: Dictionary = book.orders[draft.id]
	var before: float = order.estimate
	_check(book.reschedule(order.id, 0, "COATED-1001/WC-COT-02").is_empty() and order.estimate > before,
		"Moving a draft to the alternative changes its duration")
	_check(book.reschedule(order.id, 0, "COATED-1001/WC-COT-01").is_empty(), "Restore the original assignment")
	book._post("BAKED-01", 16.0, "", "SFG-WH", "Opening", "", "Test stock")
	_check(book.release(order.id).is_empty(), "Release the standard and immediate BOM")
	var frozen: Dictionary = order.standard.duplicate(true)
	catalog.standards[order.standard.id].rate = 500.0
	_check(order.standard == frozen and order.route.operations[0].standard == frozen, "Released order freezes its production standard")
	_check(line.set_operating_factor(&"Coater", 80) and order.estimate == before, "Operating factor leaves planned duration intact")
	_check(not line.set_setting(&"coater_rate", 999.0), "Expanded gameplay rejects editing the absolute machine rate")
	line.set_playing(true)
	var observed := false
	for tick in 3600:
		line.advance(Line.STEP_SECONDS)
		if line.coater.actual_rate > 0:
			observed = is_equal_approx(line.coater.configured_rate, 336.0) and is_equal_approx(line.coater.actual_rate, 336.0)
			break
	_check(observed, "Physical coating uses frozen 420 kg/h times the 80% operating factor")
	_check(catalog.reload_standards().is_empty() and order.standard == frozen,
		"Explicit standard reload keeps the released rate snapshot")
	var missing_id := "STD-COATED-1003-WC-COT-02"
	var missing: Dictionary = catalog.standards[missing_id]
	var unreleased := book.create_order("COATED-1003", 2, 700, 1, "COATED-1003/WC-COT-02")
	catalog.standards.erase(missing_id)
	_check("production standard" in book.create_order("COATED-1003", 2, 700, 1, "COATED-1003/WC-COT-02").error,
		"A missing standard blocks scheduling")
	_check("production standard" in book.release(unreleased.id), "A missing standard blocks release")
	catalog.standards[missing_id] = missing
	catalog.standards["DUPLICATE"] = missing.duplicate(true)
	_check("duplicate" in Standards.validate(catalog), "Validation rejects overlapping standards")
	catalog.standards.erase("DUPLICATE")
	var mini := Scheduling.assignment(book, "FG-2005", 8, 0, "FG-2005/WC-PKG-02")
	_check(mini.error.is_empty() and mini.route.operations[0].standard.unit == "cartons/h",
		"Mini product uses the carton standard on Line 02")
	_check(Standards.kg_per_hour(mini.route.operations[0].standard, mini.recipe.spec) == 260.0,
		"130 cartons/h at 2 kg/carton equals 260 kg/h")
	_check(Scheduling.assignment(book, "FG-2005", 8, 0, "FG-2005/WC-PKG-01").error != "",
		"Line 01 rejects the mini packaging format")
	var premium1 := Scheduling.assignment(book, "FG-2001", 8, 0, "FG-2001/WC-PKG-01")
	var premium2 := Scheduling.assignment(book, "FG-2001", 8, 0, "FG-2001/WC-PKG-02")
	_check(premium1.duration > premium2.duration, "Both packaging lines can run a premium product at different rates")
	var bites := Scheduling.assignment(book, "CUT-HAZ-MINI", 2, 0, "")
	_check(bites.route.operations[0].standard.unit == "pieces/h"
		and bites.recipe.spec.dimensions_mm.map(func(value): return int(value)) == [22, 22, 20]
		and is_equal_approx(mini.recipe.spec.pack_kg / bites.recipe.spec.piece_kg, 10.0),
		"Cutter applies mini dimensions and the pouch holds ten whole pieces")
	var classic := Scheduling.alternatives(catalog, "FG-1001", 8, 0)
	_check(classic.size() == 2 and classic.all(func(route: Dictionary) -> bool: return route.id.begins_with("ROUTE-FG-")),
		"Classic packaging offers one independent route per eligible line")


func _setup_and_batches() -> void:
	var line := _line()
	var book := line.erp
	var hazard := book.create_order("CREAM-HAZ", 80, 0, 1)
	var nut: Dictionary = book.orders[hazard.id]
	var vanilla := book.create_order("CREAM-VAN", 10, nut.finish, 1)
	var plain: Dictionary = book.orders[vanilla.id]
	var handling: float = book.catalog.scheduling.stages.cream.handling_seconds
	var buffer: float = book.catalog.Scheduling.process_factor(book.catalog)
	_check(nut.estimate == ceilf(handling + 2 * (255 + 4 + 4) * buffer), "80 kg hazelnut cream books two buffered batches with cycle and handling")
	_check(plain.route.operations[0].setup_seconds == 900 and plain.estimate == ceilf(handling + (240 + 8) * buffer + 900),
		"Planned hazelnut-to-vanilla transition reserves extra cleaning")
	var block := book.create_order("BLOCK-HAZ", 10, 0, 1)
	book._post("BAKED-01", 7, "", "SFG-WH", "Opening", "", "Test stock")
	book._post("CREAM-VAN", 3, "", "SFG-WH", "Opening", "", "Wrong flavor fixture")
	_check("CREAM-HAZ" in book.release(block.id), "Sandwiching requires the exact cream material")
	line.set_playing(true)
	line.advance(15)
	_check(line.active_cell(&"CreamMixer") == null and book.stock("CREAM-HAZ", "SFG-WH") == 0.0,
		"A downstream order cannot manufacture cream by itself")
	_check(book.release(nut.id).is_empty() and book.release(plain.id).is_empty(), "Release both explicit cream batches")
	book.catalog.changeovers["NUT-CLEAN"].seconds = 5.0
	var observed := false
	for tick in 16000:
		line.advance(Line.STEP_SECONDS)
		if line.runs.has(plain.id) and not observed:
			observed = line.runs[plain.id].setup > 890
		if plain.status == "Completed":
			break
	_check(observed and plain.status == "Completed", "Actual changeover uses the released cleaning rule snapshot")
	_check(is_equal_approx(book.stock("CREAM-HAZ", "SFG-WH"), 80.0)
		and is_equal_approx(book.stock("CREAM-VAN", "SFG-WH"), 13.0), "Both cream stocks retain material identity")


func _minimum_lot_and_yield() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-2005", 1, 2400)
	plan.run(book, {})
	_check(plan.proposals.values().any(func(item: Dictionary) -> bool:
		return item.code == "CREAM-HAZ" and is_equal_approx(item.quantity, 1.0)),
		"MRP rounds a sub-minimum cream requirement to a feasible batch")
	var uncoated := book.catalog.manufacturing_flow("FG-2004")
	_check("CUT-VAN" in uncoated and "COOLED-2001" not in uncoated and "COATED-2001" not in uncoated,
		"The vanilla uncoated product explicitly bypasses coating and cooling")
	book.catalog.standards["STD-CUT-VAN-WC-CUT-01"].yield_factor = 0.8
	book._post("BLOCK-VAN", 10, "", "SFG-WH", "Opening", "", "Yield test")
	var cut := book.create_order("CUT-VAN", 8, 0, 1)
	var order: Dictionary = book.orders[cut.id]
	_check(book.release(order.id).is_empty() and is_equal_approx(order.remaining["BLOCK-VAN"], 10.0),
		"Lower yield reserves more input for the same output")
	line.set_playing(true)
	line.advance(1100)
	_check(order.status == "Completed" and is_equal_approx(order.received_kg, 8.0)
		and is_equal_approx(order.scrapped, 2.0) and is_equal_approx(line.scrapped_kg, 2.0),
		"Physical yield loss is posted and accounted for")


func _filled_family() -> void:
	var line := _line()
	var book := line.erp
	var moved := line.layout.move(&"Cutter", Vector2i(60, 44), 0)
	_check(moved.is_empty(), "Move the cutter in the expanded hall with valid cart routes")
	var cutter_dock := line.layout.port(&"Cutter", &"input_dock")
	var plan := Plan.new()
	var milk := book.create_demand("FG-2001", 40, 4200)
	var mini := book.create_demand("FG-2005", 24, 4300)
	_check(milk.error.is_empty() and mini.error.is_empty(), "Create demand for two filled-wafer products")
	plan.run(book, {})
	var codes := {}
	for proposal in plan.proposals.values():
		if proposal.type == "Make":
			codes[proposal.code] = true
	for code in ["DOUGH-01", "RAW-01", "BAKED-01", "CREAM-VAN", "BLOCK-VAN", "CUT-VAN",
			"COATED-2001", "COOLED-2001", "FG-2001", "CREAM-HAZ", "BLOCK-HAZ", "CUT-HAZ-MINI", "FG-2005"]:
		_check(codes.has(code), "MRP proposes the independent order for " + code)
	_check(not codes.has("COATED-2002") and not codes.has("COOLED-2002"), "Uncoated mini product bypasses coating and cooling")
	for attempt in 36:
		var selected := ""
		for proposal in plan.proposals.values():
			if proposal.type == "Make":
				selected = proposal.id
				break
		if selected.is_empty():
			break
		var converted := plan.convert(selected, book, {})
		if not converted.error.is_empty():
			_check(false, "Convert " + selected + " " + converted.error)
			return
	_check(plan.proposals.is_empty(), "All proposals convert without duplication")
	_check(book.orders.values().all(func(order: Dictionary) -> bool: return order.status == "Created"),
		"MRP conversion creates planned orders without releasing them")
	var fg_milk: Dictionary = book.orders[book.demands[milk.id].converted]
	var fg_mini: Dictionary = book.orders[book.demands[mini.id].converted]
	var milk_id: String = fg_milk.id
	var mini_id: String = fg_mini.id
	_check(not book.release(milk_id).is_empty() and not book.release(mini_id).is_empty(), "Future upstream orders cannot release either package")
	book.auto_release = true
	line.set_playing(true)
	var saved := false
	var simultaneous := false
	var pallet_cart := false
	var cutter_delivery := false
	var traceable_carts := true
	var elapsed_before_cooling := -1.0
	for tick in 88000:
		line.advance(Line.STEP_SECONDS)
		if tick % 16 == 0:
			if line.warehouse_count() == line.warehouse.size():
				line.dispatch(true)
			simultaneous = simultaneous or book.orders.values().filter(func(order: Dictionary) -> bool:
				return order.status == "In Progress").size() > 1
			for cart in line.carts:
				if cart.stock.quantity > Line.EPSILON and not cart.order_id.is_empty() and not cart.material.is_empty():
					var owner: Dictionary = book.orders[cart.order_id]
					traceable_carts = traceable_carts and (cart.material == owner.code or owner.recipe.needs.has(cart.material))
		for job in line.floor_assignments.values():
			pallet_cart = pallet_cart or (job.run == mini_id and job.site == Line.Cart.Site.PALLET_DOCK)
			cutter_delivery = cutter_delivery or (job.site == Line.Cart.Site.CELL_IN and job.point == cutter_dock)
		var tunnel := line.active_cell(&"CoolingTunnel")
		if tunnel != null and tunnel.inside > 0.0 and not saved:
			var operation := line.order_at(&"CoolingTunnel")
			_check(tunnel.produced == 0.0 and not tunnel.cohorts.is_empty(), "Cooling holds the product before residence expires")
			elapsed_before_cooling = operation.started
			var restored := Save.restore(Save.snapshot(line))
			_check(restored.error.is_empty(), "Reload an in-flight cooling order and cart queue")
			if not restored.error.is_empty():
				return
			var resumed: Line = restored.line
			_check(resumed.active_cell(&"CoolingTunnel").snapshot() == tunnel.snapshot()
				and resumed.erp.journal() == book.journal(), "Restore exact residence queue and goods movements")
			line = resumed
			book = line.erp
			line.set_playing(true)
			fg_milk = book.orders[milk_id]
			fg_mini = book.orders[mini_id]
			saved = true
		if fg_milk.status == "Completed" and fg_mini.status == "Completed":
			break
	_check(saved and simultaneous and pallet_cart, "Run overlapping orders, reload cooling, and move Line 02 cartons by worker cart")
	_check(cutter_delivery and traceable_carts, "Worker carts follow the moved cutter and retain order/material identity")
	_check(fg_milk.status == "Completed" and fg_mini.status == "Completed", "Both filled products finish through forklift receipt")
	_check(is_equal_approx(fg_milk.received_kg, 200.0) and is_equal_approx(fg_mini.received_kg, 48.0), "Receive correct finished pallet masses")
	_check(fg_mini.consumed.get("PK-WRAP-MINI") == 960.0, "Line 02 issues one pouch per pack")
	_check(is_equal_approx(line.warehouse_mass() + line.dispatched_kg, 248.0), "Finished mass survives dispatch and reload")
	var movement_totals := {}
	var issues := {}
	var chocolate := 0.0
	for entry in book.journal(100000):
		if entry.type in ["SFG Receipt", "FG Receipt"]:
			movement_totals[entry.document] = float(movement_totals.get(entry.document, 0)) + entry.qty
		if entry.type == "Consumption":
			var key := "%s/%s" % [entry.document, entry.code]
			issues[key] = float(issues.get(key, 0)) + entry.qty
			if entry.code == "RM-COAT-1001":
				chocolate += entry.qty
		if entry.code == "COOLED-2001" and entry.type == "WIP Produced":
			var cooled: Dictionary = book.orders[entry.document]
			_check(entry.time + Line.STEP_SECONDS >= elapsed_before_cooling + cooled.standard.residence_seconds,
				"Cooling output posts after residence time")
	for order in book.orders.values():
		_check(order.status == "Completed" and order.started >= order.start and order.completed >= order.started,
			"Order finishes with correct planned/actual time " + order.code)
		_check(order.standard.work_center == order.center and order.standard.material == order.code,
			"Order traces the selected product/resource standard " + order.code)
		_check(is_equal_approx(movement_totals.get(order.id, 0), order.recipe.target)
			and order.remaining.is_empty() and line.order_wip(order.id).is_empty(), "Receipt, WIP and reservation balance for " + order.code)
		for code in order.recipe.needs:
			var key := "%s/%s" % [order.id, code]
			_check(is_equal_approx(issues.get(key, 0.0), order.recipe.needs[code]), "Trace component issue " + key)
	_check(is_equal_approx(line.ingredients_taken + chocolate, line.material_on_site() + line.dispatched_kg + line.scrapped_kg),
		"Both filled routes conserve ingredient and chocolate mass")


func _expanded_scene() -> void:
	var factory := Scene.instantiate()
	factory.resume_saved = false
	root.add_child(factory)
	await process_frame
	for id: StringName in [&"CreamMixer", &"Spreader", &"Cutter", &"CoolingTunnel", &"Packer02"]:
		factory._select(id)
		_check(factory.floor_view.view_of(id) != null and factory.hud.inspector._selection == id,
			"Select the new machine in the factory " + String(id))
		var factor = factory.hud.inspector.find_child("operating_rate_factor", true, false)
		_check(factor != null, "Machine inspector exposes the operating factor")
	factory.terminal.open(factory.terminal.STANDARDS_PAGE, "FG-2005")
	_check(factory.terminal._rows.has("FG-2005/WC-PKG-01") and factory.terminal._rows.has("FG-2005/WC-PKG-02"),
		"Production Standards displays eligible and ineligible packaging resources")
	_check(factory.terminal._rows.has("CREAM-HAZ/WC-CRM-01"), "Product filter includes upstream material standards")
	factory.terminal.open(4)
	factory.terminal._example_demands()
	factory.terminal._example_demands()
	_check(factory.line.erp.demands.size() == 6 and factory.terminal.plan.summary.make > 0,
		"Examples add three wafer and three gum demands and rerun MRP without duplicates")
	var terminal = factory.terminal
	_check(terminal._table.columns == 9 and terminal._rows.has("BAKED-01"), "MRP opens on the material coverage list")
	terminal._rows["BAKED-01"].select(0)
	terminal._on_select()
	terminal._on_activate()
	var elements := []
	var row: TreeItem = terminal._table.get_root().get_first_child()
	while row != null:
		elements.append(row.get_text(1))
		row = row.get_next()
	_check(terminal._mrp_material == "BAKED-01" and "PlOrd." in elements and "DepReq" in elements and "Stock" in elements,
		"Double-click opens the stock/requirements list: " + str(elements))
	var planned: Array = terminal.plan.proposals.values().filter(func(item: Dictionary) -> bool: return item.code == "BAKED-01")
	terminal._rows[planned[0].id].select(0)
	terminal._on_select()
	terminal._toggle_firm()
	_check(factory.line.erp.planned_orders[planned[0].number].firmed, "Firm a planned order from the list")
	terminal._render()
	_check(terminal._rows.has(planned[0].id) and terminal._rows[planned[0].id].get_text(1) == "PlOrd.*", "Firmed order shows as PlOrd.*")
	terminal._open_material("")
	_check(terminal._mrp_material.is_empty() and terminal._rows.has("BAKED-01"), "Back to the coverage list")
	var before: int = factory.line.erp.orders.size() + factory.line.erp.purchases.size()
	_check(not terminal._shown_proposals().is_empty(), "The coverage view shows planned orders to convert")
	var converted: Dictionary = terminal.plan.convert_all(factory.line.erp, factory.line.erp_fg(), terminal._shown)
	_check(converted.failed.is_empty() and factory.line.erp.orders.size() + factory.line.erp.purchases.size() == before + converted.created.size()
		and terminal._shown_proposals().is_empty() and factory.line.erp.planned_orders.is_empty(),
		"Convert all shown leaves no planned orders: " + str(converted.failed))
	_machine_models(factory.floor_view)
	_shutter_traffic(factory.floor_view, factory.line)
	factory.queue_free()


func _machine_models(floor_view) -> void:
	for row: Array in [[&"Spreader", "MeteringRoller"], [&"Cutter", "CuttingHead"],
			[&"CoolingTunnel", "CoolingFan"], [&"Packer02", "SealingJaw"], [&"Packer", "FeedReel"]]:
		var part := floor_view.view_of(row[0]).find_child(row[1], true, false) as Node3D
		_check(part != null, "Machine has its own operating mechanism: " + String(row[0]))
		if part == null:
			continue
		var idle_pose := part.transform
		var model = floor_view._processing_models[row[0]]
		model.animate(false, 0.17)
		_check(part.transform == idle_pose, "Mechanism stays still while idle")
		model.animate(true, 0.17)
		_check(part.transform != idle_pose, "Mechanism moves while processing")


func _shutter_traffic(floor_view, line: Line) -> void:
	var goods_room = floor_view._warehouse_views[0]
	var raw_room = floor_view._warehouse_views[1]
	var layout := line.layout
	var handler := line.erp.material_handler
	var raw_gate = raw_room.doors[0]
	var view = floor_view.view_of(handler.id)
	_check(view.find_child("ManualPalletJack", true, false) != null, "Material handler has a manual pallet jack")
	_check(raw_gate.raised == 0.0, "Raw shutter is closed with the handler inside")
	_check(line.erp.manual_transfer("RM-FLOUR", 25.0, "RM-WH", "RM-STAGE", "Material handler test").is_empty(),
		"Queue a real raw-material pickup")
	line.set_playing(true)
	# He walks from his desk to the parked pallet jack and the raw dock before the pickup.
	for tick in 600:
		line.advance(Line.STEP_SECONDS)
		if line.erp.stock("RM-FLOUR", "TRANSIT") > 0.0:
			break
	floor_view.refresh(line)
	var logistics = floor_view._logistics
	_check(logistics._jack_load.visible and logistics._jack_ingredients.visible and not logistics._jack_packaging.visible,
		"The pallet jack shows ingredient sacks while stock is in transit")
	var crossed := false
	for tick in 280:
		line.advance(Line.STEP_SECONDS)
		raw_room.animate(line, Line.STEP_SECONDS)
		crossed = crossed or raw_gate.raised > 0.999
	floor_view.refresh(line)
	_check(crossed and raw_gate.raised == 0.0, "Raw shutter opens for the pallet jack and closes after it clears")
	_check(not logistics._jack_load.visible and is_equal_approx(line.erp.stock("RM-FLOUR", "RM-STAGE"), 25.0),
		"The pallet jack empties when the ingredients are delivered")
	line.set_playing(false)
	var forklift := line.forklift
	for slot in [0, line.warehouse.size() - 1]:
		var gate = goods_room.doors[0]
		forklift.position = layout.pallet_approach(0)
		forklift.previous_position = forklift.position
		forklift.travel(layout.lift_to_slot(forklift.position, slot), Line.Operator.State.DRIVING, "Deliver", "FG warehouse")
		var opened := false
		while not forklift.finished():
			forklift.advance(Line.STEP_SECONDS, 8.0)
			goods_room.animate(line, Line.STEP_SECONDS)
			opened = opened or gate.raised > 0.999
		_check(opened, "Forklift opens the shutter on its delivery route to slot %d" % slot)
		forklift.travel(layout.lift_from_slot(slot), Line.Operator.State.DRIVING, "Return", "Lift parking")
		for tick in 140:
			forklift.advance(Line.STEP_SECONDS, 8.0)
			goods_room.animate(line, Line.STEP_SECONDS)
		_check(forklift.finished() and gate.raised == 0.0, "Warehouse shutter closes after the forklift returns")


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", description)
