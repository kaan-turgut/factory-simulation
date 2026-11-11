extends SceneTree
## Explicit stage orders, dated finite capacity, and stock-to-stock factory execution.

const Line = preload("res://simulation/production_line.gd")
const Schedule = Line.ERP.Scheduling
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const SCENE = preload("res://scenes/factory.tscn")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_end_to_end()
	_automatic_release()
	_automatic_release_competition()
	_resources()
	_netting()
	_changeover()
	await _planning_board()
	print("Detailed Scheduling: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Default layout and scheduling master data load")
	return line


func _order(line: Line, code: String, quantity: float, start: float = 0.0, version: String = "") -> Dictionary:
	var result := line.erp.create_order(code, quantity, maxf(line.erp.now, start), 5, version)
	_check(result.error.is_empty(), "Create %s: %s" % [code, result.error])
	return line.erp.orders.get(result.get("id", ""), {})


func _finish(line: Line, order: Dictionary, timeout: float = 2500.0) -> void:
	line.set_playing(true)
	var stop := line.erp.now + timeout
	while line.erp.now < stop and order.get("status") != "Completed":
		line.advance(2.0)
	_check(order.get("status") == "Completed", "Complete " + String(order.get("code", "")) + " " + String(order.get("delay", "")))


func _release(line: Line, order: Dictionary) -> void:
	var message := line.erp.release(order.id)
	_check(message.is_empty(), "Release %s: %s" % [order.code, message])


func _end_to_end() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	var demand := book.create_demand("FG-1001", 10, 2400.0)
	_check(demand.error.is_empty(), "Create milk wafer demand")
	plan.run(book, {})
	_check(plan.summary.make == 6 and plan.summary.buy == 0 and book.orders.is_empty(), "MRP proposes six explicit operations without scheduling or releasing")
	var signature := plan.proposals.duplicate(true)
	plan.run(book, {})
	_check(signature == plan.proposals, "Repeated MRP preserves proposal identities and amounts")
	var by_code := {}
	for code in ["FG-1001", "COOLED-1001", "COATED-1001", "BAKED-01", "RAW-01", "DOUGH-01"]:
		for proposal in plan.proposals.values():
			if proposal.code == code:
				var result := plan.convert(proposal.id, book, {})
				_check(result.error.is_empty(), "Convert " + code + " to a finite planned slot")
				if result.error.is_empty():
					by_code[code] = book.orders[result.id]
				break
	if by_code.size() != 6:
		return
	_check(plan.summary.make == 0 and book.orders.size() == 6, "Converted documents net future receipts without duplicate proposals")
	var pack: Dictionary = by_code["FG-1001"]
	var coat: Dictionary = by_code["COATED-1001"]
	var cool: Dictionary = by_code["COOLED-1001"]
	var bake: Dictionary = by_code["BAKED-01"]
	var raw: Dictionary = by_code["RAW-01"]
	var dough: Dictionary = by_code["DOUGH-01"]
	_check(dough.pegs == [raw.id] and raw.pegs == [bake.id] and bake.pegs == [coat.id] and coat.pegs == [cool.id] and cool.pegs == [pack.id], "MRP conversion creates immediate-level pegging links")
	_check(not Schedule.peg(book, pack.id, dough.id).is_empty(), "Reject incompatible or cyclic pegging")
	for downstream in [pack, cool, coat, bake, raw]:
		var error := book.release(downstream.id)
		_check("available" in error and "short" in error and downstream.status == "Created", "Planned supply cannot release " + downstream.code)
	_check(book.reservations.is_empty(), "Failed release reserves no components")
	line.set_playing(true)
	line.advance(60)
	_check(line.extruder.total_output == 0.0 and line.oven.batches == 0 and line.warehouse_count() == 0,
		"No operation runs without an explicit release")
	_release(line, dough)
	var flour: float = book.stock("RM-FLOUR", "RM-WH")
	_check(is_equal_approx(book.reservations["RM-FLOUR"], 35.2), "Only batter preparation reserves flour")
	line.advance(dough.start - book.now - 1.0)
	_check(dough.status == "Released" and dough.started < 0.0 and book.stock("RM-FLOUR", "RM-WH") == flour, "Future release waits without consuming")
	_finish(line, dough)
	_check(is_equal_approx(book.stock("DOUGH-01", "SFG-DECK"), 80.0) and line.extruder.total_output == 0.0, "Batter is physically prepared and received separately")
	for order in [raw, bake, coat, cool, pack]:
		var upstream := [line.extruder.total_output, line.oven.batches, line.coater.total_output]
		var before: float = order.start
		if order == pack:
			var wrappers: float = book.stock("PK-WRAP", "RM-WH")
			book.adjust("PK-WRAP", -wrappers, "Packaging shortage test")
			_check("PK-WRAP" in book.release(pack.id) and is_zero_approx(book.reservations.get("COOLED-1001", 0.0)),
				"Missing retail film blocks release without reserving wafers")
			book.adjust("PK-WRAP", wrappers, "Packaging stock restored")
		_release(line, order)
		_finish(line, order)
		_check(order.started >= before and order.completed >= order.started and order.start == before,
			"Keep planned times and actual execution separate for " + order.code)
		_check(order.remaining.is_empty() and line.order_wip(order.id).is_empty(), "No reservations or WIP left for " + order.code)
		_check(is_equal_approx(order.received_kg, order.recipe.target), "Receive exactly the planned quantity for " + order.code)
		if order == pack:
			_check(upstream == [line.extruder.total_output, line.oven.batches, line.coater.total_output],
				"Packaging from received stock does not execute an upstream stage")
	_check(is_equal_approx(line.erp_fg().get("FG-1001", 0.0), 50.0) and line.warehouse_count() == ceili(10.0 / pack.recipe.spec.boxes_per_pallet), "Forklift receives ten boxes in FG storage")
	_check(is_equal_approx(line.material_on_site(), 50.0) and is_equal_approx(line.ingredients_taken, 80.0)
		and is_equal_approx(bake.scrapped, 40.0) and is_equal_approx(line.scrapped_kg, 40.0),
		"80 kg batter and 10 kg coating reconcile to 50 kg finished and 40 kg baking loss")
	_check(pack.consumed.get("PK-WRAP") == 500.0, "Line 01 issues one wrapper per retail pack")
	_check(book.reservations.values().all(func(amount: float) -> bool: return is_zero_approx(amount)), "All reservations consumed")
	var receipts := {}
	var issues := {}
	var seen := {}
	for event in book.journal(9999):
		_check(not seen.has(event.id), "Movement ID is unique")
		seen[event.id] = true
		if event.type in ["SFG Receipt", "FG Receipt"]:
			receipts[event.document] = float(receipts.get(event.document, 0.0)) + event.qty
		elif event.type == "Consumption":
			if not issues.has(event.document):
				issues[event.document] = {}
			issues[event.document][event.code] = float(issues[event.document].get(event.code, 0.0)) + event.qty
	for order in by_code.values():
		_check(is_equal_approx(receipts.get(order.id, 0.0), order.recipe.target), "Receipt trace matches " + order.id)
		for code in order.recipe.needs:
			_check(is_equal_approx(issues.get(order.id, {}).get(code, 0.0), order.recipe.needs[code]), "Component issue matches order BOM")
	var finished := Save.restore(Save.snapshot(line).duplicate(true))
	_check(finished.error.is_empty() and finished.line.erp.orders[pack.id].status == "Completed", "Restore completed production")
	if finished.error.is_empty():
		var previous: int = finished.line.erp.journal().size()
		finished.line.set_playing(true)
		finished.line.advance(200.0)
		_check(finished.line.erp.journal().size() == previous, "Completed orders do not restart after reload")


func _automatic_release() -> void:
	var line := _line()
	var book := line.erp
	var pack := _order(line, "FG-1001", 2.0, 240.0)
	var coat := _order(line, "COATED-1001", 10.0, 180.0)
	var cool := _order(line, "COOLED-1001", 10.0, 210.0)
	var bake := _order(line, "BAKED-01", 8.0, 90.0)
	var raw := _order(line, "RAW-01", 16.0, 45.0)
	var dough := _order(line, "DOUGH-01", 16.0, 15.0)
	line.set_playing(true)
	line.advance(5.0)
	_check(dough.status == "Created" and book.reservations.is_empty(), "Auto Release defaults off")
	line.set_playing(false)
	book.auto_release = true
	line.advance(100.0)
	_check(dough.status == "Created", "Auto Release waits for the shift to run")
	line.set_playing(true)
	line.advance(1.0)
	_check(dough.status == "Released" and dough.started < 0.0 and book.reservations["RM-FLOUR"] > 0.0,
		"Auto Release reserves available stock before the planned start")
	_check([raw, bake, coat, cool, pack].all(func(order: Dictionary) -> bool: return order.status == "Created"),
		"Scheduled upstream supply cannot release a downstream order")
	_finish(line, pack)
	for order in [dough, raw, bake, coat, cool, pack]:
		_check(order.status == "Completed" and order.started >= order.start,
			"Auto-released order completes at or after scheduled start: " + order.code)
	_check(is_equal_approx(line.warehouse_mass(), 10.0) and is_equal_approx(book.reservations["COOLED-1001"], 0.0),
		"Auto Release carries all six stages through warehouse receipt")


func _automatic_release_competition() -> void:
	var line := _line()
	var book := line.erp
	book._post("RAW-01", 16.0, "", "SFG-WH", "Opening", "", "Competition test stock")
	book._post("BAKED-01", 8.0, "", "SFG-WH", "Opening", "", "Coating test stock")
	book.adjust("RM-COAT-1001", -book.stock("RM-COAT-1001", "RM-WH"), "Test purchase receipt")
	var first := _order(line, "BAKED-01", 8.0, 600.0, "BAKED-01/WC-OVN-01")
	var priority := _order(line, "BAKED-01", 8.0, 600.0, "BAKED-01/WC-OVN-02")
	book.prioritize(priority.id, 1)
	var coat := _order(line, "COATED-1001", 10.0, 600.0)
	var po := book.purchase("SUP-02", "RM-COAT-1001", 2.0)
	_check(po.error.is_empty(), "Order missing coating")
	if not po.error.is_empty():
		return
	book.auto_release = true
	var restored := Save.restore(Save.snapshot(line))
	_check(restored.error.is_empty() and restored.line.erp.auto_release, "Save and restore the enabled switch")
	if not restored.error.is_empty():
		return
	line = restored.line
	book = line.erp
	first = book.orders[first.id]
	priority = book.orders[priority.id]
	coat = book.orders[coat.id]
	line.set_playing(true)
	line.advance(1.0)
	_check(priority.status == "Released" and first.status == "Created" and book.reservations["RAW-01"] == 16.0,
		"Only the higher-priority order reserves shared stock at the same start time")
	line.advance(float(book.purchases[po.id].due) - book.now - Line.STEP_SECONDS)
	_check(coat.status == "Created", "Open purchase order cannot trigger Auto Release")
	line.advance(Line.STEP_SECONDS)
	_check(coat.status == "Released" and book.purchases[po.id].status == "Received",
		"Physical purchase receipt triggers Auto Release")
	book.auto_release = false
	book.transition(priority.id, "Cancelled")
	line.advance(1.0)
	_check(first.status == "Created" and coat.status == "Released",
		"Switching off stops new automatic releases")


func _resources() -> void:
	var line := _line()
	var book := line.erp
	var dough := _order(line, "DOUGH-01", 180.0)
	_release(line, dough)
	_finish(line, dough)
	var raw := _order(line, "RAW-01", 180.0)
	_release(line, raw)
	_finish(line, raw)
	if raw.status != "Completed":
		return
	line.set_setting(&"floor_speed", 0.5)
	var start: float = book.now + 10.0
	var a := _order(line, "BAKED-01", 65.0, start, "BAKED-01/WC-OVN-01")
	var b := _order(line, "BAKED-01", 25.0, start, "BAKED-01/WC-OVN-02")
	var c := _order(line, "BAKED-01", 0.5, start, "BAKED-01/WC-OVN-01")
	_check(a.start == b.start and c.start == a.finish, "Parallel ovens can overlap while one oven is scheduled finitely")
	var bake_work: Dictionary = book.catalog.scheduling.stages.bake
	_check(a.estimate == bake_work.handling_seconds + 2 * (a.standard.cycle_seconds + a.standard.loading_seconds
		+ a.standard.unloading_seconds + bake_work.batch_handling_seconds), "Oven duration includes two cycles and both batches' handling")
	_check("conflict" in book.reschedule(c.id, a.start), "Reject drag into occupied interval")
	_check(not book.reschedule(c.id, a.start, "BAKED-01/WC-COT-01").is_empty(), "Reject incompatible machine")
	_check(not book.create_order("COATED-1005", 2.0, start, 5, "COATED-1005/WC-COT-02").error.is_empty(), "Reject a coater incompatible with strawberry")
	_release(line, a)
	_release(line, b)
	_check(not book.release(c.id).is_empty() and book.reservations["RAW-01"] == 180.0, "Competing order cannot double-reserve")
	book._post("RAW-01", 1.0, "", "SFG-WH", "Opening", "", "Third bake test lot")
	_release(line, c)
	_check(not book.reschedule(a.id, a.start + 100).is_empty(), "Released routing and time are frozen")
	var route: Dictionary = a.route.duplicate(true)
	book.catalog.standards[a.standard.id].cycle_seconds = 900.0
	line.set_playing(true)
	var visited := {}
	var both := false
	var queued := false
	var saved := false
	for tick in 16000:
		line.advance(Line.STEP_SECONDS)
		queued = queued or (c.status == "Released" and "occupied" in c.delay)
		both = both or (line.order_at(&"Oven").get("id") == a.id and line.order_at(&"Oven02").get("id") == b.id)
		for job in line.floor_assignments.values():
			if job.site == Line.Cart.Site.OVEN_RAW and job.kind == Line.JobKind.MOVE_CART:
				visited[job.run] = job.point
		if not saved and line.carts.any(func(cart: Line.Cart) -> bool:
			return cart.site == Line.Cart.Site.SFG_DOCK and cart.stock.quantity > 0):
			var path := "user://ppds-check-%d.save" % OS.get_process_id()
			var error := Save.save(line, path)
			var restored := Save.load_line(path)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			_check(error.is_empty() and restored.error.is_empty(), "Persist a loaded SFG dock in flight")
			if restored.error.is_empty():
				_check(restored.line.erp.journal() == book.journal() and restored.line.erp.reservations == book.reservations
					and restored.line.erp.orders[a.id].route == route and restored.line.sfg_dock.stock.quantity > 0,
					"Reload keeps WIP, reservations, movement IDs, and released route snapshot")
				line = restored.line
				line.set_playing(true)
				book = line.erp
				a = book.orders[a.id]
				b = book.orders[b.id]
				c = book.orders[c.id]
			saved = true
		if a.status == "Completed" and b.status == "Completed" and c.status == "Completed":
			break
	_check(saved and both, "Observe concurrent commitments and save an in-flight stock transfer")
	_check(visited.get(a.id) == line.layout.port(&"Oven", &"raw_dock")
		and visited.get(b.id) == line.layout.port(&"Oven02", &"raw_dock"), "Workers deliver to the frozen work center coordinates")
	_check(a.status == "Completed" and b.status == "Completed" and is_equal_approx(book.stock("BAKED-01", "SFG-WH"), 90.5),
		"Concurrent multi-cart orders conserve stock and complete")
	_check(a.completed > a.finish and a.logistics_seconds > 0.0 and a.oven_wait_seconds > 0.0,
		"Slow cart transport creates measured lateness and wait time")
	_check(queued and c.started >= a.completed, "An actual overrun holds the next released order")
	_check(line.ovens[&"Oven"].batches == 3 and line.ovens[&"Oven02"].batches == 1,
		"Explicit orders respect the batch count and a final partial lot")
	book.catalog.scheduling.work_center_calendars["WC-OVN-02"] = [[0, 900]]
	_check(not Schedule.in_calendar(book.catalog, "WC-OVN-02", 800, 950)
		and Schedule.next_slot(book, "WC-OVN-02", 800, 150) == Schedule.DAY, "Calendar advances an operation to the next usable window")


func _netting() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	var code := "RM-COAT-1001"
	_check(book.adjust(code, -book.stock(code, "RM-WH"), "Test stock removal").is_empty(), "Remove sample coating inventory")
	book.create_demand("FG-1001", 8, 7200)
	plan.run(book, {})
	var proposals: Array = plan.proposals.values().filter(func(row: Dictionary) -> bool: return row.code == code)
	_check(proposals.size() == 1 and proposals[0].type == "Buy", "MRP proposes one external receipt for milk coating")
	if proposals.is_empty():
		return
	var po := plan.convert(proposals[0].id, book, {})
	_check(po.error.is_empty() and book.stock(code, "RM-WH") == 0.0, "Converted PO creates no physical stock")
	plan.run(book, {})
	_check(plan.proposals.values().all(func(row: Dictionary) -> bool: return row.code != code), "Scheduled PO nets the same dated shortage on rerun")
	_check(not book.adjust(code, -1, "Invalid count").is_empty(), "Reject negative stock")


func _changeover() -> void:
	var line := _line()
	var book := line.erp
	# Existing completed baked stock is a valid starting point for independent coating.
	book._post("BAKED-01", 16.0, "", "SFG-WH", "Opening", "", "Coating test fixture")
	book.adjust("RM-COAT-1002", 2.0, "Coating test fixture")
	book.catalog.changeovers["COAT"].seconds = 25.0
	book.catalog.changeovers["MATERIAL"].seconds = 0.0
	var milk := _order(line, "COATED-1001", 10.0, 0.0, "COATED-1001/WC-COT-01")
	var dark := _order(line, "COATED-1002", 10.0, 0.0, "COATED-1002/WC-COT-01")
	_release(line, milk)
	_release(line, dark)
	_finish(line, milk)
	var saw_setup := false
	var setup_start := -1.0
	var cutoff: float = book.now + 900.0
	while book.now < cutoff and dark.status != "Completed":
		line.advance(Line.STEP_SECONDS)
		if line.coaters[&"Coater"].state == Line.Machine.State.SETUP:
			if not saw_setup:
				setup_start = book.now
			saw_setup = true
			if dark.started >= 0.0:
				_check(false, "Coater has no actual start during changeover")
				break
	_check(saw_setup and dark.status == "Completed" and dark.started >= setup_start + 25.0,
		"Coater changeover consumes simulated time before the new SKU starts")
	_check(is_equal_approx(book.stock(milk.code, "SFG-WH"), 10.0) and is_equal_approx(book.stock(dark.code, "SFG-WH"), 10.0),
		"Changing coating keeps SKU stock separate")


func _planning_board() -> void:
	var factory := SCENE.instantiate()
	factory.resume_saved = false
	root.add_child(factory)
	var terminal = factory.terminal
	terminal.open(5)
	var switch := terminal._auto_release as CheckButton
	_check(switch.is_visible_in_tree() and not switch.button_pressed, "ChocoERP displays the default-off switch")
	switch.button_pressed = true
	_check(factory.line.erp.auto_release, "ERP switch enables automatic release")
	switch.button_pressed = false
	_check(not factory.line.erp.auto_release, "ERP switch disables automatic release")
	terminal._new_order()
	await process_frame
	var forms: Array[Node] = terminal.find_children("*", "ConfirmationDialog", false, false)
	_check(forms.size() == 1, "Production Orders opens the stage creation form")
	if forms.is_empty():
		factory.queue_free()
		return
	var form: ConfirmationDialog = forms[0]
	var pickers := form.find_children("*", "OptionButton", true, false)
	var materials: OptionButton = pickers[0]
	for index in materials.item_count:
		if materials.get_item_metadata(index) == "BAKED-01":
			materials.select(index)
			materials.item_selected.emit(index)
			break
	var versions: OptionButton = pickers[1]
	_check(versions.item_count == 2, "Baking form offers both oven work centers")
	var quantity := form.find_child("quantity", true, false) as LineEdit
	var start := form.find_child("start", true, false) as LineEdit
	quantity.text = "30"
	quantity.text_changed.emit("30")
	start.text = "2"
	start.text_changed.emit("2")
	form.get_ok_button().pressed.emit()
	await process_frame
	_check(factory.line.erp.orders.size() == 1, "Stage form schedules one baking order")
	if factory.line.erp.orders.is_empty():
		factory.queue_free()
		return
	var first: Dictionary = factory.line.erp.orders.values()[0]
	_check(first.stage == "bake" and first.quantity == 30.0 and first.start == 120.0,
		"Stage form preserves quantity and simulated start")
	terminal.open(9, "BAKED-01")
	_check(terminal._rows.has("ROUTE-BAKED-01-WC-OVN-02"), "Routing Master shows an independent stage path")
	terminal.open(terminal.SCHEDULE_PAGE)
	await create_timer(0.35).timeout
	var board = terminal._board
	_check(board.visible and board._centers.size() == factory.line.erp.catalog.work_centers.size(), "ERP board exposes every master-data work center")
	var chart_body := board._canvas.get_parent() as Control
	chart_body.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	await process_frame
	await process_frame
	var swipe := InputEventPanGesture.new()
	swipe.position = board._canvas.get_global_rect().get_center()
	swipe.delta = Vector2(0.3, 0.0)
	root.push_input(swipe, true)
	var time_offset: float = board._left
	_check(time_offset > 0.0 and is_zero_approx(board._top), "Horizontal swipe scrolls only the timeline")
	swipe.delta = Vector2(0.0, 0.3)
	root.push_input(swipe, true)
	_check(is_equal_approx(board._left, time_offset) and board._top > 0.0 and board._top < 1.0,
		"Vertical swipe scrolls work centers by part of a row (offset %.3f, page %.3f, total %.3f)" % [
			board._top, board._vertical.page, board._vertical.max_value])
	swipe.delta = Vector2(-0.3, -0.3)
	root.push_input(swipe, true)
	_check(is_zero_approx(board._left) and is_zero_approx(board._top), "Reverse swipe moves both axes back")
	chart_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board._canvas.queue_redraw()
	await process_frame
	await process_frame
	if board._boxes.has(first.id):
		var from: Rect2 = board._boxes[first.id]
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.position = from.get_center()
		press.pressed = true
		board._input_canvas(press)
		var motion := InputEventMouseMotion.new()
		motion.position = press.position + Vector2(35, board.ROW)
		board._input_canvas(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = motion.position
		board._input_canvas(release)
		_check(first.center == "WC-OVN-02" and is_equal_approx(first.start, 150.0), "Dragging a bar updates the machine and scheduled time")
		board.details_requested.emit(first.id)
		_check(terminal._page == 5 and terminal._selected.get("id") == first.id, "Gantt opens the selected order detail")
	else:
		_check(false, "Gantt paints a selectable bar in the visible range")
	factory.queue_free()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: ", description)
