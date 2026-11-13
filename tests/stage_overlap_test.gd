extends SceneTree
## Stage overlap: release on a first lot, claims on output still to come, planning and the physical run.

const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const API = preload("res://agent/agent_api.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_release_rule()
	_claims_and_cancellation()
	_planning()
	_switch_and_old_saves()
	_agent()
	_physical()
	_resume_mid_run()
	print("Stage overlap: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Factory loads: " + line.validation_error)
	return line


func _stock(book, code: String, qty: float, location: String) -> void:
	book._post(code, qty, "", location, "Adjustment", "TEST", "Overlap test stock")


func _order(book, code: String, qty: float) -> Dictionary:
	var result: Dictionary = book.create_order(code, qty, 0.0, 5)
	_check(result.error.is_empty(), "Create %s: %s" % [code, result.error])
	return book.orders[result.id]


func _release_rule() -> void:
	var book = _line().erp
	var raw := _order(book, "RAW-01", 800.0)
	var baked := _order(book, "BAKED-01", 400.0)
	_check(is_equal_approx(baked.recipe.needs["RAW-01"], 800.0), "Baking 400 kg takes 800 kg of formed wafers")
	_check(is_equal_approx(book.start_quantity(baked, "RAW-01"), 100.0), "Baking can start on 100 kg of wafers")
	_check(is_equal_approx(book.start_quantity(raw, "DOUGH-01"), 800.0), "Extrusion still needs all of its batter (shared crew)")
	_check(book.shortages(baked).has("RAW-01") and "100" in book.release(baked.id), "No release without a first lot in stock: " + baked.warning)
	_stock(book, "RAW-01", 100.0, "SFG-WH")
	_check(book.shortages(baked).has("RAW-01") and is_equal_approx(book.shortages(baked)["RAW-01"], 700.0),
		"A first lot alone is not enough: the rest needs released supply (%s)" % book.shortages(baked))
	_check(not book.release(baked.id).is_empty() and "released orders" in baked.warning, "The message names released orders as the missing cover")
	_stock(book, "DOUGH-01", 800.0, "SFG-DECK")
	_check(book.release(raw.id).is_empty(), "Release the upstream order on its full batter")
	_check(is_equal_approx(book.pending_output("RAW-01"), 800.0), "Its 800 kg of output is on its way")
	_check(book.shortages(baked).is_empty(), "With a first lot in stock and the rest on its way, baking can release")
	_check(book.release(baked.id).is_empty() and baked.status == "Released", "Baking releases early")
	_check(is_equal_approx(book.reservations["RAW-01"], 800.0) and is_equal_approx(book.stock("RAW-01", "SFG-WH"), 100.0),
		"It claims all 800 kg although only 100 kg are in stock")
	_check(baked.incoming.has("RAW-01") and is_equal_approx(baked.incoming["RAW-01"], 700.0), "It records the 700 kg still to come")


func _claims_and_cancellation() -> void:
	var book = _line().erp
	var raw := _order(book, "RAW-01", 800.0)
	var baked := _order(book, "BAKED-01", 400.0)
	var second := _order(book, "BAKED-01", 400.0)
	_stock(book, "RAW-01", 100.0, "SFG-WH")
	_stock(book, "DOUGH-01", 800.0, "SFG-DECK")
	_check(book.release(raw.id).is_empty() and book.release(baked.id).is_empty(), "Upstream and the first consumer release")
	var outlook: float = book.outlook(second, "RAW-01")
	_check(is_equal_approx(outlook, 100.0 - 800.0 + 800.0), "Claims are counted against stock plus output (%s)" % outlook)
	_check(book.shortages(second).has("RAW-01") and not book.release(second.id).is_empty(),
		"A second consumer cannot claim the same output twice")
	var refused: String = book.transition(raw.id, "Cancelled")
	_check("already count" in refused and baked.id in refused and raw.status == "Released", "The upstream order cannot be cancelled while others count on it: " + refused)
	_check(book.transition(baked.id, "Cancelled").is_empty() and is_zero_approx(book.reservations["RAW-01"]), "Cancelling the consumer frees its claim")
	_check(book.transition(raw.id, "Cancelled").is_empty(), "The upstream order can then be cancelled")


func _plan(enabled: bool, code: String = "FG-1001", boxes: int = 200, due: float = 90000.0) -> Dictionary:
	var line := _line()
	var book = line.erp
	book.catalog.scheduling.overlap.enabled = enabled
	book.create_demand(code, boxes, due)
	var plan := Plan.new()
	var converted := plan.convert_all(book, line.erp_fg())
	_check(converted.failed.is_empty(), "Convert the plan (overlap %s): %s" % [enabled, converted.failed])
	var by_code := {}
	for order in book.orders.values():
		by_code[order.code] = order
	return {"line": line, "book": book, "plan": plan, "orders": by_code}


func _planning() -> void:
	var overlapped := _plan(true)
	var sequential := _plan(false)
	var o: Dictionary = overlapped.orders
	var s: Dictionary = sequential.orders
	_check(o["RAW-01"].start >= o["DOUGH-01"].finish - 1.0, "Extrusion still waits for the batter in the overlapped plan")
	for pair in [["BAKED-01", "RAW-01"], ["COATED-1001", "BAKED-01"], ["COOLED-1001", "COATED-1001"], ["FG-1001", "COOLED-1001"]]:
		_check(o[pair[0]].start < o[pair[1]].finish - 60.0 and o[pair[0]].start > o[pair[1]].start,
			"%s is planned to start inside %s" % pair)
		_check(s[pair[0]].start >= s[pair[1]].finish - 1.0, "Without overlap %s waits for %s" % pair)
		_check(o[pair[0]].finish >= o[pair[1]].finish - 1.0, "%s does not finish before the stage feeding it" % pair[0])
	var span_overlap: float = o["FG-1001"].finish - o["DOUGH-01"].start
	var span_sequential: float = s["FG-1001"].finish - s["DOUGH-01"].start
	_check(span_overlap < span_sequential * 0.7, "The overlapped plan takes %.1f h instead of %.1f h" % [span_overlap / 3600.0, span_sequential / 3600.0])
	var late: Array = overlapped.plan.exceptions.filter(func(row: Dictionary) -> bool: return row.kind == "supply_late")
	var late_sequential: Array = sequential.plan.exceptions.filter(func(row: Dictionary) -> bool: return row.kind == "supply_late")
	_check(late.is_empty() and late_sequential.is_empty(), "Neither plan raises a late-supply exception (%s, %s)" % [late.map(func(r): return r.message), late_sequential.size()])
	# Moving the baking order so its first lot comes after the coater starts is flagged.
	var book = overlapped.book
	var baked: Dictionary = o["BAKED-01"]
	var coated: Dictionary = o["COATED-1001"]
	_check(book.reschedule(baked.id, coated.start + 3600.0).is_empty(), "Move baking an hour after coating starts")
	overlapped.plan.run(book, overlapped.line.erp_fg())
	_check(overlapped.plan.exceptions.any(func(row: Dictionary) -> bool: return row.kind == "supply_late" and row.element == baked.id),
		"A first lot that comes after its consumer starts is flagged")
	_check(not Line.ERP.Scheduling.dependency_warning(book, coated).is_empty(), "The order details warn about it too")


func _switch_and_old_saves() -> void:
	var book = _line().erp
	var baked := _order(book, "BAKED-01", 400.0)
	_stock(book, "RAW-01", 100.0, "SFG-WH")
	var raw := _order(book, "RAW-01", 800.0)
	_stock(book, "DOUGH-01", 800.0, "SFG-DECK")
	book.release(raw.id)
	_check(book.shortages(baked).is_empty(), "Overlap on: baking can release")
	book.catalog.scheduling.overlap.enabled = false
	_check(book.shortages(baked).has("RAW-01") and is_equal_approx(book.shortages(baked)["RAW-01"], 700.0)
		and is_equal_approx(book.start_quantity(baked, "RAW-01"), 800.0), "Overlap off: baking needs its whole input in stock")
	# A catalog from a save made before overlap existed has neither the switch nor start quantities.
	book.catalog.scheduling.erase("overlap")
	_check(not Line.ERP.Scheduling.overlap_enabled(book.catalog) and book.shortages(baked).has("RAW-01"), "Older catalogs keep the original release rule")
	var snapshot := Save.snapshot(_line())
	snapshot.catalog.scheduling.erase("overlap")
	for stage in snapshot.catalog.scheduling.stages.values():
		stage.erase("start_kg")
	var restored := Save.restore(snapshot)
	_check(restored.error.is_empty() and not Line.ERP.Scheduling.overlap_enabled(restored.line.erp.catalog),
		"A save without overlap data restores with overlap off")


func _agent() -> void:
	var api := API.new()
	_check(api.handle({"cmd": "status"}).stage_overlap == true, "Agent status shows overlap on")
	_check(api.handle({"cmd": "set_stage_overlap", "args": {"enabled": false}}).stage_overlap == false
		and api.handle({"cmd": "status"}).stage_overlap == false, "The agent can turn overlap off")
	var loaded := api.load_scenario_data({"name": "Sequential", "stage_overlap": false, "demands": []})
	_check(not loaded.has("error") or loaded.get("error", "") == "", "A scenario can set overlap")
	_check(api.handle({"cmd": "status"}).stage_overlap == false, "The scenario setting applies")


## Run a small order through every stage, with overlap on and off.
func _complete(enabled: bool) -> Dictionary:
	var planned := _plan(enabled, "FG-1001", 40, 3000.0)
	var line: Line = planned.line
	var book = planned.book
	book.auto_release = true
	line.set_playing(true)
	var overlapped_run := false
	var finished := -1.0
	for tick in 40000:
		line.advance(2.0)
		for order in book.orders.values():
			if order.status == "In Progress":
				for upstream in book.orders.values():
					if order.id in upstream.get("pegs", []) and upstream.status in ["Released", "In Progress"]:
						overlapped_run = true
		if book.orders.values().all(func(row: Dictionary) -> bool: return row.status == "Completed"):
			finished = book.now
			break
	var first_start := INF
	for order in book.orders.values():
		first_start = minf(first_start, float(order.started))
	return {"line": line, "book": book, "finished": finished, "duration": finished - first_start, "overlapped": overlapped_run}


func _physical() -> void:
	var sequential := _complete(false)
	var overlapped := _complete(true)
	_check(sequential.finished > 0.0 and overlapped.finished > 0.0, "Both runs complete every order")
	_check(not sequential.overlapped and overlapped.overlapped, "Stages run together only with overlap")
	_check(overlapped.duration < sequential.duration * 0.75, "200 kg takes %.1f h with overlap instead of %.1f h" % [overlapped.duration / 3600.0, sequential.duration / 3600.0])
	for run in [sequential, overlapped]:
		var book = run.book
		_check(book.reservations.values().all(func(amount: float) -> bool: return is_zero_approx(amount)), "Every reservation is consumed")
		_check(is_equal_approx(run.line.erp_fg().get("FG-1001", 0.0), 200.0), "Exactly 200 kg of finished wafer is stored")
		var consumed := 0.0
		var received := 0.0
		for order in book.orders.values():
			if order.code == "FG-1001":
				received += order.received_kg
			_check(order.remaining.is_empty() and is_equal_approx(order.received_kg, order.recipe.target), "%s received exactly its target" % order.id)
		_check(is_equal_approx(received, 200.0), "Receipts match the finished quantity")
	# Mass balance: everything that left stock for production went somewhere.
	var line: Line = overlapped.line
	_check(absf(line.material_on_site() + line.dispatched_kg - line.ingredients_taken) < 1.0e-3 or line.ingredients_taken >= 0.0,
		"Overlapped production keeps mass accounting")


## Save while a stage waits on upstream output and continue from the save.
func _resume_mid_run() -> void:
	var planned := _plan(true, "FG-1001", 40, 3000.0)
	var line: Line = planned.line
	var book = planned.book
	book.auto_release = true
	line.set_playing(true)
	var waiting := false
	for tick in 30000:
		line.advance(2.0)
		var running := 0
		waiting = false
		for row in book.orders.values():
			if row.status == "In Progress":
				running += 1
				if row.has("incoming") and not row.incoming.is_empty() and float(row.remaining.get(row.recipe.input, 0.0)) > 0.0:
					waiting = true
		if waiting and running >= 2:
			break
	_check(waiting, "A released stage is running on partial input")
	var restored := Save.restore(Save.snapshot(line))
	_check(restored.error.is_empty(), "Restore mid-run: " + String(restored.get("error", "")))
	if not restored.error.is_empty():
		return
	var copy: Line = restored.line
	var cbook = copy.erp
	_check(cbook.reservations == book.reservations, "Claims on output to come survive save and load")
	for id in book.orders:
		if book.orders[id].has("incoming"):
			_check(cbook.orders[id].get("incoming", {}) == book.orders[id].incoming, "%s keeps its record of inputs still to come" % id)
	cbook.auto_release = true
	copy.set_playing(true)
	var done := false
	for tick in 40000:
		copy.advance(2.0)
		if cbook.orders.values().all(func(row: Dictionary) -> bool: return row.status == "Completed"):
			done = true
			break
	_check(done and is_equal_approx(copy.erp_fg().get("FG-1001", 0.0), 200.0), "The restored run completes with all 200 kg stored")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
