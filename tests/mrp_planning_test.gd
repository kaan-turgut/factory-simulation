extends SceneTree
## MRP planning objects: lot sizing, safety time, exception messages, firmed planned orders and persistence.

const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_settings_validation()
	_period_lots()
	_buy_lots()
	_safety_time()
	_exceptions()
	_firming()
	_persistence()
	print("MRP planning: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _line() -> Line:
	var line := Line.new()
	line.enable_erp()
	_check(line.validation_error.is_empty(), "Factory loads: " + line.validation_error)
	return line


func _of(plan: Plan, code: String) -> Array:
	return plan.proposals.values().filter(func(item: Dictionary) -> bool: return item.code == code)


func _kinds(plan: Plan, kind: String) -> Array:
	return plan.exceptions.filter(func(row: Dictionary) -> bool: return row.kind == kind)


func _settings_validation() -> void:
	var catalog = _line().erp.catalog
	_check(catalog.planning("DOUGH-01").lot_size == "PB" and catalog.planning("DOUGH-01").period_seconds == 14400.0,
		"Master data period lot loads for batter")
	_check(catalog.planning("FG-1001").lot_size == "EX", "Materials without settings default to lot-for-lot")
	_check(not catalog.set_planning("FG-1001", {"lot_size": "PB", "period_seconds": 600}).is_empty(), "Finished goods reject period lots")
	_check(not catalog.set_planning("RAW-01", {"lot_size": "FX", "fixed_lot": 0}).is_empty(), "Fixed lot needs a size")
	_check(not catalog.set_planning("RAW-01", {"lot": "EX"}).is_empty(), "Unknown settings are rejected")
	_check(not catalog.set_planning("RAW-01", {"min_lot": 50, "max_lot": 10}).is_empty(), "Maximum lot must cover the minimum")
	_check(catalog.set_planning("FG-1001", {"safety_time": 300}).is_empty(), "Finished goods accept safety time")
	_check(catalog.lot_caption("RM-FLOUR") == "EX · min 100 · round 25", "Lot caption: " + catalog.lot_caption("RM-FLOUR"))


func _period_lots() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-1001", 10, 7200.0)
	book.create_demand("FG-1001", 10, 9000.0)
	plan.run(book, line.erp_fg())
	_check(_of(plan, "FG-1001").size() == 2, "Finished goods stay one planned order per demand")
	var baked := _of(plan, "BAKED-01")
	_check(baked.size() == 1 and baked[0].docs.size() == 2, "Period lot combines both baking requirements")
	for code in ["DOUGH-01", "RAW-01"]:
		_check(_of(plan, code).size() == 1, "One combined baking lot leaves one lot upstream for " + code)
	var dough: Dictionary = _of(plan, "DOUGH-01")[0]
	_check(is_zero_approx(fmod(dough.quantity, 10.0)), "Batter lot is rounded to 10 kg (%s)" % dough.quantity)
	var raw_total := 0.0
	for item in _of(plan, "RAW-01"):
		raw_total += item.qty
	var lot_line := _line()
	lot_line.erp.catalog.set_planning("DOUGH-01", {"lot_size": "EX", "rounding": 0})
	lot_line.erp.catalog.set_planning("RAW-01", {"lot_size": "EX"})
	lot_line.erp.catalog.set_planning("BAKED-01", {"lot_size": "EX"})
	lot_line.erp.create_demand("FG-1001", 10, 7200.0)
	lot_line.erp.create_demand("FG-1001", 10, 9000.0)
	var single := Plan.new()
	single.run(lot_line.erp, lot_line.erp_fg())
	_check(_of(single, "RAW-01").size() == 2 and _of(single, "DOUGH-01").size() == 2, "Lot-for-lot keeps one order per requirement")
	var single_raw := 0.0
	for item in _of(single, "RAW-01"):
		single_raw += item.qty
	_check(is_equal_approx(raw_total, single_raw), "Combining lots keeps the same total quantity")
	# A demand outside the period opens a second lot.
	book.create_demand("FG-1001", 10, 30000.0)
	plan.run(book, line.erp_fg())
	_check(_of(plan, "RAW-01").size() == 2, "A requirement after the period starts a new lot")
	# Converting a combined lot pegs the batter order to both extrusion orders.
	book.catalog.set_planning("RAW-01", {"lot_size": "EX"})
	book.catalog.set_planning("BAKED-01", {"lot_size": "EX"})
	var result := plan.convert_all(book, line.erp_fg())
	_check(result.failed.is_empty() and plan.proposals.is_empty(), "Convert all leaves no proposals: " + str(result.failed))
	var dough_orders: Array = book.orders.values().filter(func(o: Dictionary) -> bool: return o.code == "DOUGH-01")
	_check(dough_orders.any(func(o: Dictionary) -> bool: return o.pegs.size() >= 2), "Combined batter order pegs several parent orders")


func _buy_lots() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.adjust("RM-FLOUR", -book.stock("RM-FLOUR", "RM-WH"), "Test: no flour")
	book.create_demand("FG-1001", 10, 7200.0)
	plan.run(book, line.erp_fg())
	var flour := _of(plan, "RM-FLOUR")
	_check(flour.size() == 1 and flour[0].qty >= 100.0 and is_zero_approx(fmod(flour[0].qty, 25.0)),
		"Flour requisition respects minimum lot and rounding (%s)" % (flour[0].qty if not flour.is_empty() else -1))
	book.catalog.set_planning("RM-FLOUR", {"lot_size": "FX", "fixed_lot": 30.0, "min_lot": 0, "rounding": 0})
	plan.run(book, line.erp_fg())
	flour = _of(plan, "RM-FLOUR")
	_check(flour.size() >= 2 and flour.all(func(item: Dictionary) -> bool: return is_equal_approx(item.qty, 30.0)),
		"Fixed lots split a larger need into fixed-size requisitions (%d)" % flour.size())


func _safety_time() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-1001", 10, 7200.0)
	plan.run(book, line.erp_fg())
	var plain: Dictionary = _of(plan, "FG-1001")[0]
	book.catalog.set_planning("FG-1001", {"safety_time": 900})
	plan.run(book, line.erp_fg())
	var buffered: Dictionary = _of(plan, "FG-1001")[0]
	_check(is_equal_approx(buffered.finish, 7200.0 - 900.0) and is_equal_approx(plain.start - buffered.start, 900.0),
		"Safety time moves availability 15 minutes before the demand")


func _exceptions() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-1001", 10, 120.0)
	plan.run(book, line.erp_fg())
	var past := _kinds(plan, "start_in_past")
	_check(not past.is_empty() and past[0].severity == 3, "A demand due too soon raises start-in-past")
	var fg: Dictionary = _of(plan, "FG-1001")[0]
	_check(fg.has("earliest_finish") and fg.earliest_finish > 120.0 and not fg.exceptions.is_empty(), "Planned order carries its earliest finish and messages")
	_check(plan.coverage["FG-1001"].severity == 3 and plan.coverage["FG-1001"].uncovered_from == 120.0, "Coverage line shows the worst exception and gap date")
	_check(plan.rows.any(func(row: Dictionary) -> bool: return row.code == "FG-1001" and row.element == "PlOrd." and not row.exception.is_empty()),
		"Stock/requirements rows show element type and exception")
	# Unneeded supply is flagged for cancellation, early supply for postponement.
	var other := _line()
	var spare: Dictionary = other.erp.create_order("DOUGH-01", 40.0, 0.0, 5)
	var mrp := Plan.new()
	mrp.run(other.erp, other.erp_fg())
	_check(_kinds(mrp, "cancel").any(func(row: Dictionary) -> bool: return row.element == spare.id), "Unneeded production order: cancel")
	other.erp.create_demand("FG-1001", 10, 40000.0)
	mrp.run(other.erp, other.erp_fg())
	_check(_kinds(mrp, "reschedule_out").any(func(row: Dictionary) -> bool: return row.element == spare.id), "Early production order: postpone")
	# A purchase arriving after the need is brought forward.
	var buying := _line()
	buying.erp.adjust("RM-FLOUR", -buying.erp.stock("RM-FLOUR", "RM-WH"), "Test: no flour")
	var po: Dictionary = buying.erp.purchase("SUP-01", "RM-FLOUR", 500.0)
	buying.erp.purchases[po.id].due = 30000.0
	buying.erp.create_demand("FG-1001", 10, 9000.0)
	mrp.run(buying.erp, buying.erp_fg())
	_check(_kinds(mrp, "reschedule_in").any(func(row: Dictionary) -> bool: return row.element == po.id), "Late purchase order: bring forward")
	# A converted supply order moved after its parent's start is flagged.
	var pegged := _line()
	pegged.erp.create_demand("FG-1001", 10, 20000.0)
	mrp.convert_all(pegged.erp, pegged.erp_fg())
	var raw: Dictionary = pegged.erp.orders.values().filter(func(o: Dictionary) -> bool: return o.code == "RAW-01")[0]
	var parent: Dictionary = pegged.erp.orders[raw.pegs[0]]
	_check(pegged.erp.reschedule(raw.id, parent.start + 60.0).is_empty(), "Move supply after its parent start")
	mrp.run(pegged.erp, pegged.erp_fg())
	_check(_kinds(mrp, "supply_late").any(func(row: Dictionary) -> bool: return row.element == raw.id), "Pegged supply after parent start is flagged")


func _firming() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-1001", 10, 7200.0)
	plan.run(book, line.erp_fg())
	var numbers := {}
	for item in plan.proposals.values():
		numbers[item.id] = item.number
	plan.run(book, line.erp_fg())
	_check(plan.proposals.values().all(func(item: Dictionary) -> bool: return numbers.get(item.id) == item.number),
		"Unfirmed planned orders keep their numbers across runs")
	var raw: Dictionary = _of(plan, "RAW-01")[0]
	_check(plan.change(raw.number, raw.quantity + 20.0, raw.start - 300.0, book, line.erp_fg()).is_empty(), "Change a planned order")
	var changed: Dictionary = book.planned_orders[raw.number]
	_check(changed.firmed and is_equal_approx(changed.quantity, raw.quantity + 20.0), "Changing a planned order firms it")
	book.create_demand("FG-1001", 10, 7300.0)
	plan.run(book, line.erp_fg())
	var kept: Dictionary = book.planned_orders[raw.number]
	_check(kept.firmed and is_equal_approx(kept.quantity, raw.quantity + 20.0) and is_equal_approx(kept.start, raw.start - 300.0),
		"MRP leaves a firmed planned order unchanged")
	_check(plan.rows.any(func(row: Dictionary) -> bool: return row.number == raw.number and row.element == "PlOrd.*"), "Firmed order shows as PlOrd.*")
	_check(plan.firm(raw.number, false, book, line.erp_fg()).is_empty() and not book.planned_orders.get(raw.number, {}).get("firmed", false),
		"Unfirming hands the order back to MRP")
	plan.firm(_of(plan, "BAKED-01")[0].number, true, book, line.erp_fg())
	var firmed: Dictionary = _of(plan, "BAKED-01").filter(func(item: Dictionary) -> bool: return item.firmed)[0]
	var result := plan.convert(firmed.number, book, line.erp_fg())
	_check(result.error.is_empty() and not book.planned_orders.has(firmed.number) and book.orders[result.id].planned_order == firmed.number,
		"Converting a firmed planned order removes it and records its number")
	_check(not plan.change("PLO-99999", 1.0, book.now, book, line.erp_fg()).is_empty(), "Unknown planned order is rejected")


func _persistence() -> void:
	var line := _line()
	var book := line.erp
	var plan := Plan.new()
	book.create_demand("FG-1001", 10, 7200.0)
	plan.run(book, line.erp_fg())
	var number: String = _of(plan, "DOUGH-01")[0].number
	plan.firm(number, true, book, line.erp_fg())
	book.catalog.set_planning("RAW-01", {"safety_time": 120})
	var restored := Save.restore(Save.snapshot(line))
	_check(restored.error.is_empty(), "Shift with planned orders restores: " + String(restored.get("error", "")))
	if not restored.error.is_empty():
		return
	var copy: Line = restored.line
	_check(copy.erp.planned_orders.has(number) and copy.erp.planned_orders[number].firmed, "Firmed planned order survives save and load")
	_check(copy.erp.planned_sequence == book.planned_sequence, "Planned order numbering survives save and load")
	_check(copy.erp.catalog.planning("RAW-01").safety_time == 120.0, "Material planning settings survive save and load")
	var again := Plan.new()
	again.run(copy.erp, copy.erp_fg())
	_check(again.find(number).get("firmed", false), "Restored firmed order is used by MRP")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
