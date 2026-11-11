extends RefCounted
## JSON command interface for an AI planning agent.
##
## Every action goes through the same ERP functions the terminal buttons call, so an agent
## plays by the same rules as a human planner. Observations are compact summaries.
## Time only moves when the agent calls `advance` or `run_until`, so runs are deterministic.

const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const Save = preload("res://erp/save_game.gd")
const Schedule = preload("res://erp/scheduling.gd")
const Monitor = preload("res://agent/work_center_monitor.gd")

const SAMPLE_SECONDS := 1.0
const MAX_ADVANCE := 7.0 * 86400.0
const DEFAULT_STOPS := ["order_completed", "po_received", "demand_due_unmet"]
const EVENT_KINDS := ["order_released", "order_started", "order_completed", "po_received", "demand_met", "demand_due_unmet"]

var line: Line
var plan := Plan.new()
var monitor := Monitor.new()
var scenario := {}
var demand_met_at := {}
var decisions: Array[Dictionary] = []
var events: Array[Dictionary] = []
var _snapshots := {}
var _order_status := {}
var _po_status := {}
var _demand_flagged := {}

## Argument specs read "[optional ]<string|number|int|bool|array>[: note]"; the MCP bridge builds schemas from them.
var COMMANDS := {
	"describe": {"description": "List the available commands and their arguments.", "args": {}},
	"load_scenario": {"description": "Start a fresh shift from a scenario JSON file. Clears snapshots and logs.",
		"args": {"path": "string: res:// or absolute path, e.g. res://scenarios/constrained_shift.json"}},
	"status": {"description": "Clock, order counts, running work centers, delays and warnings, demand coverage.", "args": {}},
	"master_data": {"description": "Products, materials, work centers (rates, calendars, operating factors) and suppliers.",
		"args": {"section": "optional string: products | materials | work_centers | suppliers"}},
	"material": {"description": "Bill of materials and eligible work centers with the earliest finite slot for a quantity; suppliers for bought materials.",
		"args": {"code": "string: material code", "quantity": "optional number: boxes for finished goods, kg otherwise"}},
	"stock": {"description": "On hand, reserved, available and incoming quantity per material.", "args": {"codes": "optional array: material codes"}},
	"orders": {"description": "Production orders with plan vs actual times, delays, shortages and pegging.",
		"args": {"status": "optional string: Created | Released | In Progress | Completed | Cancelled | open", "code": "optional string: material code"}},
	"demands": {"description": "Customer demands with coverage and lateness.", "args": {}},
	"schedule": {"description": "Planned and running orders per work center in time order (the Gantt).", "args": {}},
	"work_centers": {"description": "Current state and cumulative time breakdown per work center (working, setup, starved, blocked, handling, no_work).", "args": {}},
	"journal": {"description": "Latest stock movements.", "args": {"limit": "optional int: default 30"}},
	"run_mrp": {"description": "Run material requirements planning. Returns proposals; nothing is created.", "args": {}},
	"convert_proposal": {"description": "Turn an MRP proposal into a planned production order or a purchase order. Proposal ids can change after each conversion; run MRP again.",
		"args": {"id": "string: proposal id", "quantity": "optional number: override", "start": "optional number: planned start in seconds", "version": "optional string: production version"}},
	"create_order": {"description": "Create a planned production order at the earliest finite slot at or after start.",
		"args": {"code": "string: material code", "quantity": "number: boxes for finished goods, kg otherwise", "start": "optional number: seconds, default now",
			"priority": "optional int: 1-9, default 5", "version": "optional string: production version"}},
	"reschedule": {"description": "Move a Created stage order to a new start or production version.",
		"args": {"id": "string: order id", "start": "number: seconds", "version": "optional string: production version"}},
	"release": {"description": "Release a Created order: reserves its immediate components. It starts at its planned start.", "args": {"id": "string: order id"}},
	"cancel": {"description": "Cancel a Created or Released order.", "args": {"id": "string: order id"}},
	"prioritize": {"description": "Set the priority of a pending order.", "args": {"id": "string: order id", "priority": "int: 1-9"}},
	"purchase": {"description": "Place a purchase order with a supplier. It is received automatically at its due time.",
		"args": {"supplier": "string: supplier id", "code": "string: material code", "quantity": "number"}},
	"create_demand": {"description": "Add a customer demand.", "args": {"code": "string: finished good code", "boxes": "int", "due": "number: seconds"}},
	"set_auto_release": {"description": "Release planned orders automatically once their components are in stock.", "args": {"enabled": "bool"}},
	"advance": {"description": "Run the simulation for a number of seconds. Returns the events that happened.", "args": {"seconds": "number"}},
	"run_until": {"description": "Run until one of the stop events happens or max_seconds pass.",
		"args": {"max_seconds": "number", "stop_on": "optional array: any of " + ", ".join(EVENT_KINDS) + "; default " + ", ".join(DEFAULT_STOPS)}},
	"snapshot": {"description": "Save the whole shift in memory under a name, for what-if experiments.", "args": {"name": "string"}},
	"restore": {"description": "Go back to a named snapshot, discarding everything since.", "args": {"name": "string"}},
	"score": {"description": "Service level, lateness, finished boxes, working share per work center and purchase spend so far.", "args": {}},
	"log_decision": {"description": "Record a decision, finding or recommendation with its reasoning in the run log.", "args": {"text": "string"}},
	"run_log": {"description": "All actions, decisions and events so far.", "args": {}},
}


func _init() -> void:
	_new_line()


func handle(request: Dictionary) -> Dictionary:
	var command := String(request.get("cmd", ""))
	var args: Dictionary = request.get("args", {}) if request.get("args") is Dictionary else {}
	if not COMMANDS.has(command):
		return {"ok": false, "error": "Unknown command '%s'. Call describe." % command}
	if line == null or not line.validation_error.is_empty():
		if command != "load_scenario" and command != "describe":
			return {"ok": false, "error": "The shift is not valid: " + (line.validation_error if line else "no line")}
	var result: Variant = call("_cmd_" + command, args)
	var response: Dictionary = result if result is Dictionary else {"result": result}
	if not response.has("ok"):
		response.ok = String(response.get("error", "")).is_empty()
	response.now = _t(line.erp.now) if line != null and line.erp != null else 0.0
	return response


# --- Setup -----------------------------------------------------------------

func _new_line() -> void:
	line = Line.new()
	line.enable_erp()
	if not line.validation_error.is_empty():
		return
	line.multiplier = 1
	line.set_playing(true)
	plan = Plan.new()
	monitor.reset()
	demand_met_at.clear()
	decisions.clear()
	events.clear()
	_snapshots.clear()
	_demand_flagged.clear()
	_remember_statuses()


func _cmd_describe(_args: Dictionary) -> Dictionary:
	return {"commands": COMMANDS, "units": "Time in simulated seconds from shift start. FG quantities in boxes, others in kg or each.",
		"scenario": scenario.get("name", "default")}


func _cmd_load_scenario(args: Dictionary) -> Dictionary:
	var path := String(args.get("path", ""))
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {"error": "Cannot read scenario " + path}
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		return {"error": "Scenario is not a JSON object."}
	return load_scenario_data(data)


func load_scenario_data(data: Dictionary) -> Dictionary:
	_new_line()
	if not line.validation_error.is_empty():
		return {"error": line.validation_error}
	scenario = data
	var problems: Array[String] = []
	for adjustment in data.get("stock_adjustments", []):
		var message := line.erp.adjust(String(adjustment.code), float(adjustment.qty), String(adjustment.get("reason", "Scenario")))
		if not message.is_empty():
			problems.append("%s: %s" % [adjustment.code, message])
	var factors: Dictionary = data.get("operating_factors", {})
	for equipment in factors:
		if not line.set_operating_factor(StringName(equipment), float(factors[equipment])):
			problems.append("Operating factor rejected for " + String(equipment))
	for demand in data.get("demands", []):
		var result := line.erp.create_demand(String(demand.code), int(demand.boxes), float(demand.due))
		if not result.error.is_empty():
			problems.append("%s: %s" % [demand.code, result.error])
	line.erp.auto_release = bool(data.get("auto_release", false))
	_remember_statuses()
	_log("scenario", {"name": data.get("name", ""), "problems": problems})
	if not problems.is_empty():
		return {"error": "; ".join(problems)}
	return {"name": data.get("name", ""), "description": data.get("description", ""),
		"horizon_seconds": data.get("horizon_seconds", 0), "demands": _demand_rows()}


# --- Observation -----------------------------------------------------------

func _cmd_status(_args: Dictionary) -> Dictionary:
	var counts := {}
	for order in line.erp.orders.values():
		counts[order.status] = int(counts.get(order.status, 0)) + 1
	var open_po := 0
	for po in line.erp.purchases.values():
		open_po += int(po.status != "Received")
	var delayed := []
	for order in line.erp.orders.values():
		if order.status in line.erp.OPEN and (not String(order.get("delay", "")).is_empty() or not String(order.warning).is_empty()):
			delayed.append({"id": order.id, "code": order.code, "status": order.status, "delay": order.get("delay", ""), "warning": order.warning})
	var running := []
	for center in line.erp.catalog.work_centers.values():
		var order := line.order_at(StringName(center.equipment))
		if not order.is_empty():
			running.append({"center": center.id, "order": order.id, "code": order.code, "state": line.work_center_status(StringName(center.equipment))})
	return {"scenario": scenario.get("name", "default"), "horizon_seconds": scenario.get("horizon_seconds", 0),
		"orders_by_status": counts, "open_purchase_orders": open_po, "auto_release": line.erp.auto_release,
		"active_work_centers": running, "orders_with_delay_or_warning": delayed,
		"demands": _demand_summary(), "finished_boxes": _finished_boxes()}


func _cmd_master_data(args: Dictionary) -> Dictionary:
	var catalog = line.erp.catalog
	var section := String(args.get("section", ""))
	var out := {}
	if section in ["", "products"]:
		var rows := []
		for code in catalog.materials:
			var item: Dictionary = catalog.materials[code]
			if item.type == "FERT":
				rows.append({"code": code, "name": item.name, "family": item.get("family", ""), "coating": item.get("coating", ""),
					"box_kg": item.get("box_kg", 0), "boxes_per_pallet": item.get("boxes_per_pallet", 0),
					"flow": Array(catalog.manufacturing_flow(code))})
		out.products = rows
	if section in ["", "materials"]:
		var rows := []
		for code in catalog.materials:
			var item: Dictionary = catalog.materials[code]
			if item.type != "FERT":
				rows.append({"code": code, "name": item.name, "type": item.type, "unit": item.unit,
					"procurement": item.procurement, "lead": item.lead, "active": item.active})
		out.materials = rows
	if section in ["", "work_centers"]:
		var rows := []
		for center in catalog.work_centers.values():
			rows.append({"id": center.id, "description": center.description, "equipment": center.equipment,
				"operation": center.operation, "available": center.available, "technical": center.technical,
				"materials": center.get("materials", []), "calendar": Schedule.calendar(catalog, center.id),
				"operating_factor": line.operating_factors.get(StringName(center.equipment), 1.0)})
		out.work_centers = rows
	if section in ["", "suppliers"]:
		out.suppliers = catalog.suppliers.values()
	return out


func _cmd_material(args: Dictionary) -> Dictionary:
	var code := String(args.get("code", ""))
	var quantity := float(args.get("quantity", 0))
	var catalog = line.erp.catalog
	if not catalog.materials.has(code):
		return {"error": "Unknown material " + code}
	var item: Dictionary = catalog.materials[code]
	var out := {"code": code, "name": item.name, "type": item.type, "unit": item.unit, "procurement": item.procurement,
		"stage": Schedule.stage_for(catalog, code)}
	if item.procurement == "External":
		var suppliers := []
		for supplier in catalog.suppliers.values():
			if code in supplier.codes:
				suppliers.append({"id": supplier.id, "lead": maxf(supplier.lead, item.lead), "minimum": supplier.minimum, "price": supplier.price})
		out.suppliers = suppliers
		return out
	if quantity <= 0.0:
		return {"error": "Give a positive quantity to explode the BOM and fit a slot."}
	var recipe := Schedule.recipe(catalog, code, quantity)
	if not recipe.error.is_empty():
		return {"error": recipe.error}
	out.components = _rounded(recipe.needs)
	out.output_kg = _t(recipe.target)
	var options := []
	for route in Schedule.alternatives(catalog, code, quantity, line.erp.now):
		var op: Dictionary = route.operations[0]
		var row := {"production_version": route.production_version, "work_center": op.work_center, "available": op.available}
		if op.available:
			var slot := Schedule.fit(line.erp, code, quantity, line.erp.now, route.production_version)
			if slot.error.is_empty():
				row.earliest_start = _t(slot.start)
				row.duration = _t(slot.duration)
				row.earliest_finish = _t(slot.start + slot.duration)
			else:
				row.error = slot.error
		else:
			row.error = op.get("standard_error", "Unavailable")
		options.append(row)
	out.options = options
	return out


func _cmd_stock(args: Dictionary) -> Dictionary:
	var book = line.erp
	var wanted: Array = args.get("codes", [])
	var incoming := {}
	for po in book.purchases.values():
		if po.status != "Received":
			if not incoming.has(po.code):
				incoming[po.code] = []
			incoming[po.code].append({"po": po.id, "qty": _t(po.qty - po.received), "due": _t(po.due)})
	var fg: Dictionary = line.erp_fg()
	var rows := []
	for code in book.catalog.materials:
		if not wanted.is_empty() and code not in wanted:
			continue
		var item: Dictionary = book.catalog.materials[code]
		var on_hand: float = book.total_stock(code) if item.type != "FERT" else float(fg.get(code, 0.0))
		var reserved := float(book.reservations.get(code, 0.0))
		if wanted.is_empty() and on_hand <= 0.0 and reserved <= 0.0 and not incoming.has(code):
			continue
		var row := {"code": code, "unit": item.unit if item.type != "FERT" else "kg", "on_hand": _t(on_hand),
			"reserved": _t(reserved), "available": _t(on_hand - reserved)}
		if incoming.has(code):
			row.incoming = incoming[code]
		rows.append(row)
	return {"stock": rows, "note": "Raw and semi-finished stock is from the ERP ledger; finished goods from stored pallets."}


func _cmd_orders(args: Dictionary) -> Dictionary:
	var status := String(args.get("status", ""))
	var code := String(args.get("code", ""))
	var rows := []
	for order in line.erp.orders.values():
		if status == "open" and order.status not in line.erp.OPEN:
			continue
		if not status.is_empty() and status != "open" and order.status != status:
			continue
		if not code.is_empty() and order.code != code:
			continue
		rows.append(_order_row(order))
	return {"orders": rows}


func _cmd_demands(_args: Dictionary) -> Dictionary:
	return {"demands": _demand_rows()}


func _cmd_schedule(_args: Dictionary) -> Dictionary:
	var lanes := {}
	for order in line.erp.orders.values():
		if order.status not in line.erp.OPEN or not order.has("center"):
			continue
		if not lanes.has(order.center):
			lanes[order.center] = []
		lanes[order.center].append({"id": order.id, "code": order.code, "status": order.status, "quantity": _t(order.quantity),
			"start": _t(order.start), "finish": _t(order.finish), "priority": order.priority})
	for center in lanes:
		lanes[center].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.start < b.start)
	return {"work_centers": lanes}


func _cmd_work_centers(_args: Dictionary) -> Dictionary:
	var rows := []
	for center in line.erp.catalog.work_centers.values():
		var equipment := StringName(center.equipment)
		var order := line.order_at(equipment)
		var row := {"id": center.id, "operation": center.operation, "state": line.work_center_status(equipment),
			"order": order.get("id", ""), "operating_factor": line.operating_factors.get(equipment, 1.0)}
		row.merge(monitor.report(center.id))
		rows.append(row)
	return {"observed_seconds": _t(monitor.observed), "work_centers": rows,
		"buckets": "working=producing, setup=changeover, starved=has order but waits for input/material/carts, blocked=output full or waiting for pickup, handling=oven loading/unloading, no_work=no order assigned"}


func _cmd_journal(args: Dictionary) -> Dictionary:
	var rows := []
	for event in line.erp.journal(int(args.get("limit", 30))):
		rows.append({"time": _t(event.get("time", 0.0)), "type": event.type, "code": event.code, "qty": _t(event.qty),
			"from": event.from, "to": event.to, "document": event.get("document", "")})
	return {"movements": rows}


# --- Planning actions ------------------------------------------------------

func _cmd_run_mrp(_args: Dictionary) -> Dictionary:
	plan.run(line.erp, line.erp_fg())
	var rows := []
	for item in plan.proposals.values():
		var row := {"id": item.id, "type": item.type, "code": item.code, "qty": _t(item.qty), "due": _t(item.due), "for": item.doc}
		for key in ["quantity", "start", "version", "supplier", "center"]:
			if item.has(key):
				row[key] = _t(item[key]) if item[key] is float else item[key]
		rows.append(row)
	_log("run_mrp", {"proposals": rows.size()})
	return {"summary": plan.summary, "proposals": rows}


func _cmd_convert_proposal(args: Dictionary) -> Dictionary:
	var edits := {}
	for key in ["quantity", "start"]:
		if args.has(key):
			edits[key] = float(args[key])
	if args.has("version"):
		edits.version = String(args.version)
	var result: Dictionary = plan.convert(String(args.get("id", "")), line.erp, line.erp_fg(), edits)
	return _acted("convert_proposal", args, result.get("error", ""), _created(result))


func _cmd_create_order(args: Dictionary) -> Dictionary:
	var result: Dictionary = line.erp.create_order(String(args.get("code", "")), float(args.get("quantity", 0)),
		float(args.get("start", line.erp.now)), int(args.get("priority", 5)), String(args.get("version", "")))
	return _acted("create_order", args, result.error, _created(result))


func _cmd_reschedule(args: Dictionary) -> Dictionary:
	var id := String(args.get("id", ""))
	var error: String = line.erp.reschedule(id, float(args.get("start", -1)), String(args.get("version", "")))
	return _acted("reschedule", args, error, {"order": _order_row(line.erp.orders[id])} if line.erp.orders.has(id) else {})


func _cmd_release(args: Dictionary) -> Dictionary:
	var id := String(args.get("id", ""))
	var error: String = line.erp.release(id)
	return _acted("release", args, error, {"order": _order_row(line.erp.orders[id])} if line.erp.orders.has(id) else {})


func _cmd_cancel(args: Dictionary) -> Dictionary:
	return _acted("cancel", args, line.erp.transition(String(args.get("id", "")), "Cancelled"), {})


func _cmd_prioritize(args: Dictionary) -> Dictionary:
	return _acted("prioritize", args, line.erp.prioritize(String(args.get("id", "")), int(args.get("priority", 5))), {})


func _cmd_purchase(args: Dictionary) -> Dictionary:
	var result: Dictionary = line.erp.purchase(String(args.get("supplier", "")), String(args.get("code", "")), float(args.get("quantity", 0)))
	var extra := {}
	if result.error.is_empty():
		var po: Dictionary = line.erp.purchases[result.id]
		extra = {"id": po.id, "due": _t(po.due), "cost": _t(po.qty * po.price)}
	return _acted("purchase", args, result.error, extra)


func _cmd_create_demand(args: Dictionary) -> Dictionary:
	var result: Dictionary = line.erp.create_demand(String(args.get("code", "")), int(args.get("boxes", 0)), float(args.get("due", 0)))
	return _acted("create_demand", args, result.error, {"id": result.get("id", "")})


func _cmd_set_auto_release(args: Dictionary) -> Dictionary:
	line.erp.auto_release = bool(args.get("enabled", false))
	return _acted("set_auto_release", args, "", {"auto_release": line.erp.auto_release})


# --- Time ------------------------------------------------------------------

func _cmd_advance(args: Dictionary) -> Dictionary:
	var seconds := float(args.get("seconds", 0))
	if not is_finite(seconds) or seconds <= 0.0 or seconds > MAX_ADVANCE:
		return {"error": "seconds must be between 0 and %d." % MAX_ADVANCE}
	var found := _run(seconds, [])
	return {"advanced": _t(seconds), "events": found}


func _cmd_run_until(args: Dictionary) -> Dictionary:
	var limit := float(args.get("max_seconds", 3600))
	if not is_finite(limit) or limit <= 0.0 or limit > MAX_ADVANCE:
		return {"error": "max_seconds must be between 0 and %d." % MAX_ADVANCE}
	var stops: Array = args.get("stop_on", DEFAULT_STOPS)
	for kind in stops:
		if kind not in EVENT_KINDS:
			return {"error": "Unknown stop event %s. Use %s." % [kind, ", ".join(EVENT_KINDS)]}
	var start: float = line.erp.now
	var found := _run(limit, stops)
	var stopped := found.any(func(event: Dictionary) -> bool: return event.kind in stops)
	return {"advanced": _t(line.erp.now - start), "stopped_by_event": stopped, "events": found}


func _run(limit: float, stops: Array) -> Array:
	var found: Array = []
	var elapsed := 0.0
	while elapsed + 1e-6 < limit:
		var step := minf(SAMPLE_SECONDS, limit - elapsed)
		line.advance(step)
		elapsed += step
		monitor.sample(line, step)
		var fresh := _detect_events()
		found.append_array(fresh)
		if fresh.any(func(event: Dictionary) -> bool: return event.kind in stops):
			break
	events.append_array(found)
	return found


func _detect_events() -> Array:
	var found: Array = []
	var now: float = line.erp.now
	for order in line.erp.orders.values():
		var before := String(_order_status.get(order.id, ""))
		if before != order.status:
			var kind := String({"Released": "order_released", "In Progress": "order_started", "Completed": "order_completed"}.get(order.status, ""))
			if not kind.is_empty() and not before.is_empty():
				found.append({"time": _t(now), "kind": kind, "order": order.id, "code": order.code})
			_order_status[order.id] = order.status
	for po in line.erp.purchases.values():
		if _po_status.get(po.id, "") != po.status:
			if po.status == "Received":
				found.append({"time": _t(now), "kind": "po_received", "po": po.id, "code": po.code, "qty": _t(po.qty)})
			_po_status[po.id] = po.status
	for row in _demand_rows():
		if row.met and not demand_met_at.has(row.id):
			demand_met_at[row.id] = now
			found.append({"time": _t(now), "kind": "demand_met", "demand": row.id, "code": row.code, "late_seconds": _t(maxf(0.0, now - row.due))})
		elif not row.met and now >= row.due and not _demand_flagged.has(row.id):
			_demand_flagged[row.id] = true
			found.append({"time": _t(now), "kind": "demand_due_unmet", "demand": row.id, "code": row.code, "short_boxes": row.boxes - row.covered_boxes})
	return found


func _remember_statuses() -> void:
	_order_status.clear()
	_po_status.clear()
	if line == null or line.erp == null:
		return
	for order in line.erp.orders.values():
		_order_status[order.id] = order.status
	for po in line.erp.purchases.values():
		_po_status[po.id] = po.status


# --- Experiments and evaluation ---------------------------------------------

func _cmd_snapshot(args: Dictionary) -> Dictionary:
	var name := String(args.get("name", ""))
	if name.is_empty():
		return {"error": "Name the snapshot."}
	_snapshots[name] = {"line": Save.snapshot(line).duplicate(true), "monitor": [monitor.totals.duplicate(true), monitor.statuses.duplicate(true), monitor.observed],
		"met": demand_met_at.duplicate(), "flagged": _demand_flagged.duplicate(), "auto_release": line.erp.auto_release}
	_log("snapshot", {"name": name})
	return {"saved": name, "snapshots": _snapshots.keys()}


func _cmd_restore(args: Dictionary) -> Dictionary:
	var name := String(args.get("name", ""))
	if not _snapshots.has(name):
		return {"error": "No snapshot named " + name, "snapshots": _snapshots.keys()}
	var saved: Dictionary = _snapshots[name]
	var result := Save.restore(saved.line.duplicate(true))
	if not result.error.is_empty():
		return {"error": result.error}
	line = result.line
	line.multiplier = 1
	line.set_playing(true)
	line.erp.auto_release = saved.auto_release
	plan = Plan.new()
	monitor.totals = saved.monitor[0].duplicate(true)
	monitor.statuses = saved.monitor[1].duplicate(true)
	monitor.observed = saved.monitor[2]
	demand_met_at = saved.met.duplicate()
	_demand_flagged = saved.flagged.duplicate()
	_remember_statuses()
	_log("restore", {"name": name})
	return {"restored": name}


func _cmd_score(_args: Dictionary) -> Dictionary:
	var on_time := 0
	var late := 0
	var open_overdue := 0
	var lateness := 0.0
	var now: float = line.erp.now
	for row in _demand_rows():
		if row.met:
			var met: float = demand_met_at.get(row.id, now)
			if met <= row.due + 1e-6:
				on_time += 1
			else:
				late += 1
				lateness += met - row.due
		elif now > row.due:
			open_overdue += 1
			lateness += now - row.due
	var spend := 0.0
	for po in line.erp.purchases.values():
		spend += po.qty * po.price
	var utilization := {}
	for center in line.erp.catalog.work_centers.values():
		utilization[center.id] = monitor.report(center.id).share.working
	var total: int = line.erp.demands.size()
	return {"demands": total, "on_time": on_time, "late": late, "open_overdue": open_overdue,
		"on_time_rate": snappedf(float(on_time) / total, 0.001) if total > 0 else 1.0,
		"total_lateness_seconds": _t(lateness), "finished_boxes": _finished_boxes(),
		"purchase_spend": snappedf(spend, 0.01), "scrap_kg": _t(line.scrapped_kg), "working_share": utilization,
		"decisions_logged": decisions.size()}


func _cmd_log_decision(args: Dictionary) -> Dictionary:
	_log("decision", {"text": String(args.get("text", ""))})
	return {"logged": decisions.size()}


func _cmd_run_log(_args: Dictionary) -> Dictionary:
	return {"log": decisions, "events": events}


# --- Helpers ---------------------------------------------------------------

func _acted(action: String, args: Dictionary, error: String, extra: Dictionary) -> Dictionary:
	_log(action, {"args": args, "error": error})
	var out := extra.duplicate()
	out.error = error
	return out


func _created(result: Dictionary) -> Dictionary:
	if not result.get("error", "").is_empty():
		return {}
	var id := String(result.get("id", ""))
	if line.erp.orders.has(id):
		_order_status[id] = line.erp.orders[id].status
		return {"order": _order_row(line.erp.orders[id])}
	if line.erp.purchases.has(id):
		var po: Dictionary = line.erp.purchases[id]
		_po_status[id] = po.status
		return {"purchase": {"id": id, "code": po.code, "qty": _t(po.qty), "due": _t(po.due)}}
	return {"id": id}


func _log(kind: String, data: Dictionary) -> void:
	var row := {"time": _t(line.erp.now) if line != null and line.erp != null else 0.0, "kind": kind}
	row.merge(data)
	decisions.append(row)


func _order_row(order: Dictionary) -> Dictionary:
	var row := {"id": order.id, "code": order.code, "stage": order.get("stage", ""), "quantity": _t(order.get("quantity", order.boxes)),
		"unit": order.unit, "status": order.status, "center": order.get("center", ""), "priority": order.priority,
		"planned_start": _t(order.start), "planned_finish": _t(order.finish)}
	if order.started >= 0.0:
		row.started = _t(order.started)
	if order.completed >= 0.0:
		row.completed = _t(order.completed)
	for key in ["delay", "warning"]:
		if not String(order.get(key, "")).is_empty():
			row[key] = order[key]
	if not order.get("pegs", []).is_empty():
		row.supplies = order.pegs
	if order.has("demand"):
		row.demand = order.demand
	if order.status == "Created":
		var missing: Dictionary = line.erp.shortages(order)
		if not missing.is_empty():
			row.shortages = _rounded(missing)
	if float(order.get("received_kg", 0.0)) > 0.0:
		row.received_kg = _t(order.received_kg)
	for key in ["logistics_seconds", "material_wait_seconds", "scrapped"]:
		if float(order.get(key, 0.0)) > 0.0:
			row[key] = _t(order[key])
	return row


func _finished_boxes() -> Dictionary:
	var boxes := {}
	for order in line.erp.orders.values():
		if order.get("unit") == "box" and order.status != "Cancelled" and int(order.received) > 0:
			boxes[order.code] = int(boxes.get(order.code, 0)) + int(order.received)
	return boxes


func _demand_rows() -> Array:
	var supply := _finished_boxes()
	var list: Array = line.erp.demands.values()
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.due < b.due or (a.due == b.due and a.id < b.id))
	var rows := []
	for demand in list:
		var have: int = supply.get(demand.code, 0)
		var covered := mini(have, int(demand.boxes))
		supply[demand.code] = have - covered
		var met := covered >= int(demand.boxes)
		var row := {"id": demand.id, "code": demand.code, "boxes": int(demand.boxes), "due": _t(demand.due),
			"covered_boxes": covered, "met": met, "orders": demand.get("converted_orders", [])}
		if demand_met_at.has(demand.id):
			row.met_at = _t(demand_met_at[demand.id])
		rows.append(row)
	return rows


func _demand_summary() -> Dictionary:
	var out := {"total": 0, "met": 0, "overdue": 0}
	for row in _demand_rows():
		out.total += 1
		out.met += int(row.met)
		out.overdue += int(not row.met and line.erp.now > row.due)
	return out


func _rounded(values: Dictionary) -> Dictionary:
	var out := {}
	for key in values:
		out[key] = _t(values[key])
	return out


static func _t(value: Variant) -> float:
	return snappedf(float(value), 0.01)
