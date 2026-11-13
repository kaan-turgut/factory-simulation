extends RefCounted
## Plan one level at a time, allocating shared stock to dated requirements across SKUs.
##
## Planned orders persist in the book. Unfirmed ones are regenerated on every run and keep their
## number while their planning key exists. Firmed ones are never changed by MRP: they count as
## fixed supply and their components are exploded as dependent requirements.
## Lot sizing (EX, FX, PB with min/max/rounding) and safety time come from the material's
## planning settings. Exception messages flag supply that should move, shrink or be cancelled.

const Scheduling = preload("res://erp/scheduling.gd")
const EPS := 0.000001
const RESCHEDULE_TOLERANCE := 1800.0
const RECEIPT_KINDS := ["Open PO", "Scheduled order", "Production proposal", "Purchase proposal",
	"Firmed planned order", "Firmed requisition"]
const SEVERITY := {"start_in_past": 3, "reschedule_in": 3, "supply_late": 3, "no_source": 3,
	"safety_stock": 2, "storage_full": 2, "at_dock": 3, "cancel": 2, "reschedule_out": 1, "excess": 1}

var book
var report
var needs := {}
var supply := {}
var initial := {}
var lots := {}
var _taken := {}


func run(target, ledger, finished: Dictionary) -> void:
	book = ledger
	report = target
	var numbers := {}
	for number in book.planned_orders:
		var item: Dictionary = book.planned_orders[number]
		if item.firmed:
			_taken[item.id] = true
		else:
			numbers[item.id] = number
	for code in book.catalog.materials:
		initial[code] = maxf(0.0, book.total_stock(code) - book.stock(code, "TRANSIT") - float(book.reservations.get(code, 0.0)))
		if book.catalog.materials[code].type == "FERT":
			initial[code] = finished.get(code, 0.0)
	for po in book.purchases.values():
		if po.status != "Received":
			_supply(po.code, po.due, po.qty - po.received, po.id, [], "Open PO", true)
	# Released orders may already claim output that is still to come. That part is spoken for.
	var claimed := {}
	for code in book.catalog.materials:
		if book.catalog.materials[code].procurement == "In-house" and book.catalog.materials[code].type != "FERT":
			claimed[code] = maxf(0.0, float(book.reservations.get(code, 0.0)) - book.stock(code, "SFG-WH") - book.stock(code, "SFG-DECK"))
	var by_finish: Array = book.orders.values()
	by_finish.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("finish", 0.0)) < float(b.get("finish", 0.0)))
	for order in by_finish:
		if order.status == "Cancelled":
			continue
		if order.status in book.OPEN and order.has("stage"):
			var linked: String = order.get("demand", "")
			if linked.is_empty():
				var open_qty: float = order.recipe.target - order.received_kg
				if order.status in ["Released", "In Progress"] and claimed.has(order.code):
					var spoken := minf(float(claimed[order.code]), open_qty)
					claimed[order.code] -= spoken
					open_qty -= spoken
				var first: float = maxf(book.now, order.start + float(order.get("first_output", 0.0))) if order.status != "In Progress" else book.now
				_supply(order.code, maxf(book.now, order.finish), open_qty,
					order.id, _parents(order), "Scheduled order", order.status in ["Created", "Released"], "", first)
			if order.status == "Created":
				_components(order.recipe, order.start, order.get("plan_key", order.id), _family(order), order.finish)
		if not String(order.get("demand", "")).is_empty():
			initial[order.code] = maxf(0.0, float(initial[order.code]) - maxf(0.0, order.received_kg - order.get("dispatched_kg", 0.0)))
	for number in book.planned_orders:
		var item: Dictionary = book.planned_orders[number]
		if not item.firmed:
			continue
		var first_date: float = item.due
		if item.type == "Make" and item.has("start"):
			first_date = item.start + Scheduling.first_output(book.catalog, item.code, float(item.get("quantity", item.qty)))
		_supply(item.code, item.due, item.qty, number, [], "Firmed planned order" if item.type == "Make" else "Firmed requisition", true, item.id, first_date)
		if item.type == "Make":
			var exploded := Scheduling.assignment(book, item.code, item.quantity, item.start, item.version)
			if exploded.error.is_empty():
				_components(exploded.recipe, item.start, item.id, item.family, item.get("finish", item.due))
			else:
				_exception("no_source", item.code, number, item.start, "Firmed order cannot be exploded: " + exploded.error)
	for demand in book.demands.values():
		var linked_orders: Array = demand.get("converted_orders", [demand.converted])
		var uncovered: float = demand.recipe.target
		for id in linked_orders:
			var linked: Dictionary = book.orders.get(id, {})
			if linked.is_empty() or linked.status == "Cancelled":
				continue
			var covered := minf(uncovered, linked.recipe.target)
			uncovered -= covered
			var date: float = linked.completed if linked.completed >= 0.0 else linked.finish
			var late := covered if date > float(demand.due) else 0.0
			report.summary.late += int(late > EPS)
			report._row(demand.code, date, "Linked production", covered, 0.0, covered, late, linked.id, _family(demand))
			if late > EPS and linked.status in book.OPEN:
				_exception("reschedule_in", demand.code, linked.id, date,
					"Finishes %s after demand %s is due" % [_span(date - float(demand.due)), demand.id])
		_need(demand.code, demand.due, uncovered, demand.id, _family(demand))
	var remaining: Array = book.catalog.materials.keys()
	# A component is evaluated after every parent, so all its need dates are known.
	while not remaining.is_empty():
		var children := {}
		for parent in remaining:
			for part in book.catalog.boms.get(parent, {}).get("parts", []):
				children[part.code] = true
		var next: Array = remaining.filter(func(code: String) -> bool: return not children.has(code))
		if next.is_empty():
			break
		for code in next:
			_net(code)
			remaining.erase(code)
	_peg_exceptions()
	_publish(numbers)
	report.rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		# The stock line leads its material, even before past-dated requirements.
		var da: float = -INF if a.kind == "Unreserved stock" else a.date
		var db: float = -INF if b.kind == "Unreserved stock" else b.date
		if da != db:
			return da < db
		if (a["in"] > EPS) != (b["in"] > EPS):
			return a["in"] > EPS
		return a.index < b.index)
	var projected := initial.duplicate()
	var below := {}
	for row in report.rows:
		if row.kind == "Requirement":
			projected[row.code] -= row["out"]
		elif row.kind in RECEIPT_KINDS:
			projected[row.code] += row["in"]
		row.projected = projected[row.code]
		var minimum: float = book.catalog.materials[row.code].minimum
		if row.kind == "Requirement" and minimum > EPS and row.projected < minimum - EPS and not below.has(row.code):
			below[row.code] = true
			_exception("safety_stock", row.code, row.doc, row.date,
				"Projected stock %s falls below safety stock %s" % [_q(row.projected), _q(minimum)])
	_storage_exceptions()
	_decorate_rows()
	_coverage()


func _parents(order: Dictionary) -> Array:
	var result := []
	for id in order.get("pegs", []):
		var parent: Dictionary = book.orders.get(id, {})
		if not parent.is_empty() and parent.status == "Created":
			result.append(parent.get("plan_key", id))
	for requirement in order.get("parent_requirements", [order.get("parent_requirement", "")]):
		if not String(requirement).is_empty() and not book.planning_conversions.has(requirement) \
				and not book.orders.has(requirement) and requirement not in result:
			result.append(requirement)
	return result


func _family(order: Dictionary) -> String:
	return order.get("family", order.recipe.spec.get("family", ""))


func _need(code: String, date: float, amount: float, doc: String, family: String, overlap: Dictionary = {}) -> void:
	if amount <= EPS:
		return
	if not needs.has(code):
		needs[code] = []
	var row := {"date": date, "qty": amount, "doc": doc, "family": family}
	row.merge(overlap)
	needs[code].append(row)


## Dependent requirements of an order or lot. A stage that can start on part of an upstream input
## records its start quantity and finish, so supply may overlap it.
func _components(recipe: Dictionary, start: float, doc: String, family: String, finish: float = -1.0) -> void:
	for component in recipe.needs:
		var overlap := {}
		if finish >= 0.0 and Scheduling.overlaps(book.catalog, recipe.stage, component):
			overlap = {"overlap": true, "start_kg": Scheduling.start_kg(book.catalog, recipe.stage), "finish": finish}
		_need(component, start, recipe.needs[component], doc, family, overlap)


func _supply(code: String, date: float, qty: float, id: String, parents: Array, kind: String, movable: bool, key: String = "", first: float = -1.0) -> void:
	if qty <= EPS:
		return
	if not supply.has(code):
		supply[code] = []
	supply[code].append({"date": date, "qty": qty, "left": qty, "id": id, "parents": parents, "kind": kind,
		"movable": movable, "first_use": INF, "key": key, "first": minf(date, first) if first >= 0.0 else date})


func _by_date(a: Dictionary, b: Dictionary) -> bool:
	return a.date < b.date


func _net(code: String) -> void:
	var requirements: Array = needs.get(code, [])
	var receipts: Array = supply.get(code, [])
	receipts.sort_custom(_by_date)
	if requirements.is_empty():
		for receipt in receipts:
			report._row(code, receipt.date, receipt.kind, receipt.qty, 0.0, receipt.left, 0.0, receipt.id, "", receipt.key)
		_receipt_exceptions(code, receipts)
		return
	requirements.sort_custom(_by_date)
	var settings: Dictionary = book.catalog.planning(code)
	var safety_time: float = settings.safety_time
	var balance: float = initial[code]
	var minimum: float = book.catalog.materials[code].minimum
	lots[code] = []
	report._row(code, book.now, "Unreserved stock", balance, 0.0, balance, 0.0, "", "")
	for need in requirements:
		# Safety time moves the date by which supply must be available.
		var due: float = need.date - safety_time
		var outstanding: float = need.qty + minimum
		# First use an explicitly pegged receipt, then on-hand stock, then other receipts.
		for receipt in receipts:
			if need.doc in receipt.parents and _usable(receipt, need, due):
				outstanding -= _allocate(receipt, outstanding, due)
		var allocated := minf(balance, outstanding)
		balance -= allocated
		outstanding -= allocated
		for receipt in receipts:
			if _usable(receipt, need, due) and (receipt.parents.is_empty() or need.doc in receipt.parents):
				outstanding -= _allocate(receipt, outstanding, due)
		var shortage := maxf(0.0, outstanding)
		var projected := balance - shortage + minimum
		report.summary.requirements += 1
		if shortage <= EPS:
			report.summary.covered += 1
		else:
			report.summary.shortages[code] = true
		report._row(code, need.date, "Requirement", 0.0, need.qty, projected, shortage, need.doc, need.family)
		for receipt in receipts:
			if outstanding <= EPS:
				break
			if _usable(receipt, need, due) or (not receipt.parents.is_empty() and need.doc not in receipt.parents):
				continue
			var late := _allocate(receipt, outstanding, -1.0)
			outstanding -= late
			if late > EPS:
				report.summary.late += 1
				report._row(code, need.date, "Late scheduled receipt", 0.0, 0.0, projected, late,
					receipt.id, need.family, "", receipt.date)
				if receipt.movable:
					_exception("reschedule_in", code, receipt.id, receipt.date,
						"Bring forward by %s to %s for %s" % [_span(receipt.date - due), _clock(due), need.doc])
		var supplied := 0.0
		if outstanding > EPS:
			supplied = _cover(code, need, due, outstanding, projected, settings)
		if outstanding <= EPS or supplied > 0.0:
			balance += minimum + maxf(0.0, supplied - outstanding)
		else:
			balance += maxf(0.0, minimum - outstanding)
	for lot in lots[code]:
		_finish_lot(lot)
	for receipt in receipts:
		report._row(code, receipt.date, receipt.kind, receipt.qty, 0.0,
			receipt.left, 0.0, receipt.id, "", receipt.key)
	_receipt_exceptions(code, receipts)


## A receipt serves a need when it is there by the need date. A need that can start on a first lot
## is also served by a receipt whose first lot is there by then and whose last lot is done by the
## end of the consuming order.
func _usable(receipt: Dictionary, need: Dictionary, due: float) -> bool:
	if receipt.date <= due:
		return true
	return need.get("overlap", false) and receipt.first <= due and receipt.date <= float(need.finish) + EPS


func _allocate(receipt: Dictionary, quantity: float, date: float) -> float:
	var allocated := minf(receipt.left, maxf(0.0, quantity))
	receipt.left -= allocated
	if allocated > EPS and date >= 0.0:
		receipt.first_use = minf(receipt.first_use, date)
	return allocated


# --- Lot sizing --------------------------------------------------------------

## Cover a net shortage with new or enlarged lots. Returns the quantity supplied, which can exceed
## the gap through minimum lots, rounding or fixed lots.
func _cover(code: String, need: Dictionary, due: float, gap: float, projected: float, settings: Dictionary) -> float:
	var supplied := 0.0
	var remaining := gap
	for attempt in 1000:
		if remaining <= EPS:
			break
		var lot: Dictionary = lots[code].back() if not lots[code].is_empty() else {}
		if not lot.is_empty() and settings.lot_size == "PB" and not lot.closed and due < lot.window_end:
			var added := _grow(lot, remaining, settings)
			if added > EPS:
				if need.doc not in lot.docs:
					lot.docs.append(need.doc)
				supplied += added
				remaining -= added
				continue
			lot.closed = true
		var created := _new_lot(code, need, due, remaining, projected, settings)
		if created <= EPS:
			break
		supplied += created
		remaining -= created
	return supplied


func _size(requested: float, settings: Dictionary, unit: String) -> float:
	var quantity := requested
	if settings.lot_size == "FX":
		quantity = settings.fixed_lot
	else:
		quantity = maxf(quantity, settings.min_lot)
		if settings.rounding > 0.0:
			quantity = ceilf(quantity / settings.rounding - EPS) * settings.rounding
		if settings.max_lot > 0.0:
			quantity = minf(quantity, settings.max_lot)
	return ceilf(quantity - EPS) if unit == "ea" else quantity


func _new_lot(code: String, need: Dictionary, due: float, gap: float, projected: float, settings: Dictionary) -> float:
	var item: Dictionary = book.catalog.materials[code]
	var make: bool = item.procurement == "In-house"
	var base := "%s|%s|%s" % ["MAKE" if make else "BUY", need.doc, code]
	var key := base
	var suffix := 2
	while _taken.has(key):
		key = "%s|%d" % [base, suffix]
		suffix += 1
	var data := {"id": key, "type": "Make" if make else "Buy", "doc": need.doc, "docs": [need.doc],
		"code": code, "qty": gap, "family": need.family, "due": due, "need_date": need.date, "firmed": false,
		"closed": false, "window_end": due + float(settings.period_seconds), "exceptions": []}
	if make and need.get("overlap", false):
		data.overlap = true
		data.start_kg = need.start_kg
		data.need_finish = need.finish
	if make:
		var requested: float = ceilf(gap / item.box_kg - EPS) if item.type == "FERT" else _size(gap, settings, item.unit)
		var fitted := _make_assignment(code, requested, due)
		if not fitted.error.is_empty():
			report._row(code, need.date, fitted.error, 0.0, 0.0, projected, gap, need.doc, need.family)
			_exception("no_source", code, need.doc, need.date, fitted.error)
			return 0.0
		data.quantity = fitted.quantity
		data.qty = fitted.assignment.recipe.target
		report.summary.make += 1
	else:
		var supplier: Dictionary = book.catalog.supplier_for(code)
		if supplier.is_empty():
			report._row(code, need.date, "No supplier", 0.0, 0.0, projected, gap, need.doc, need.family)
			_exception("no_source", code, need.doc, need.date, "No supplier for this material")
			return 0.0
		data.supplier = supplier.id
		data.lead = maxf(float(item.lead), float(supplier.lead))
		data.minimum = float(supplier.minimum)
		data.qty = _buy_quantity(_size(gap, settings, item.unit), data.minimum, item.unit)
		data.quantity = data.qty
		report.summary.buy += 1
	_taken[key] = true
	data.row = report._row(code, need.date, "Production proposal" if make else "Purchase proposal", data.qty,
		0.0, projected + data.qty, gap, need.doc, need.family, key, due)
	lots[code].append(data)
	report.proposals[key] = data
	return data.qty


func _grow(lot: Dictionary, wanted: float, settings: Dictionary) -> float:
	var item: Dictionary = book.catalog.materials[lot.code]
	var target: float = lot.quantity + wanted
	if settings.max_lot > 0.0:
		target = minf(target, settings.max_lot)
	target = _size(target, settings, item.unit)
	if target <= lot.quantity + EPS:
		return 0.0
	var before: float = lot.qty
	if lot.type == "Make":
		var fitted := _make_assignment(lot.code, target, lot.due)
		if not fitted.error.is_empty():
			return 0.0
		lot.quantity = fitted.quantity
		lot.qty = fitted.assignment.recipe.target
	else:
		lot.qty = _buy_quantity(target, lot.minimum, item.unit)
		lot.quantity = lot.qty
	lot.row["in"] = lot.qty
	lot.row.short += wanted
	return lot.qty - before


func _buy_quantity(quantity: float, minimum: float, unit: String) -> float:
	var result := maxf(quantity, minimum)
	return ceilf(result - EPS) if unit == "ea" else result


## A finite-capacity-free assignment for a make quantity. Batch resources may round up to whole minimum batches.
func _make_assignment(code: String, quantity: float, due: float) -> Dictionary:
	var item: Dictionary = book.catalog.materials[code]
	var date := maxf(book.now, due)
	var assignment := Scheduling.assignment(book, code, quantity, date, "")
	if not assignment.error.is_empty() and item.type != "FERT":
		for route in Scheduling.alternatives(book.catalog, code, quantity, date):
			var op: Dictionary = route.operations[0]
			if not op.available or op.standard.model != "batch":
				continue
			var std: Dictionary = op.standard
			var batches: int = book.catalog.Standards.batch_count(std, quantity)
			var lot := maxf(quantity, batches * std.min_batch_kg * std.yield_factor)
			var option := Scheduling.assignment(book, code, lot, date, route.production_version)
			if option.error.is_empty():
				return {"error": "", "quantity": lot, "assignment": option}
	if not assignment.error.is_empty():
		return {"error": assignment.error}
	return {"error": "", "quantity": quantity, "assignment": assignment}


## Backward-schedule a lot from its availability date and explode its components.
func _finish_lot(lot: Dictionary) -> void:
	lot.erase("row")
	lot.erase("closed")
	lot.erase("window_end")
	var item: Dictionary = book.catalog.materials[lot.code]
	if lot.type == "Make":
		var fitted := _make_assignment(lot.code, lot.quantity, lot.due)
		if not fitted.error.is_empty():
			_exception("no_source", lot.code, lot.id, lot.due, fitted.error)
			lot.start = lot.due
			lot.finish = lot.due
			return
		var assignment: Dictionary = fitted.assignment
		lot.boxes = lot.quantity if item.type == "FERT" else 0
		lot.duration = assignment.duration
		lot.start = lot.due - assignment.duration
		lot.finish = lot.due
		if lot.get("overlap", false):
			# The consumer starts on a first lot at `due`, so start early enough to have it by then,
			# and early enough to be done when the consumer finishes.
			var first := Scheduling.first_output(book.catalog, lot.code, assignment.recipe.target, float(lot.start_kg))
			lot.start = minf(lot.due - first, float(lot.need_finish) - assignment.duration)
			lot.finish = lot.start + assignment.duration
		lot.first_output = Scheduling.first_output(book.catalog, lot.code, assignment.recipe.target) if lot.code != "" and item.type != "FERT" else 0.0
		lot.version = assignment.route.production_version
		lot.center = assignment.center
		_components(assignment.recipe, lot.start, lot.id, lot.family, lot.finish)
	else:
		lot.start = lot.due - lot.lead
		lot.finish = lot.due
	report.summary.late += int(lot.start < book.now)
	if lot.start < book.now - EPS:
		lot.earliest_finish = book.now + (lot.finish - lot.start)
		_exception("start_in_past", lot.code, lot.id, lot.start, "%s date is %s in the past · earliest availability %s" % [
			"Start" if lot.type == "Make" else "Order", _span(book.now - lot.start), _clock(lot.earliest_finish)])


# --- Exceptions ----------------------------------------------------------------

func _exception(kind: String, code: String, element: String, date: float, message: String) -> void:
	report.exceptions.append({"kind": kind, "severity": SEVERITY[kind], "code": code, "element": element,
		"date": date, "message": message})


func _receipt_exceptions(code: String, receipts: Array) -> void:
	var unit: String = book.catalog.materials[code].unit
	var rounding: float = book.catalog.planning(code).rounding
	for receipt in receipts:
		if not receipt.movable:
			if receipt.left >= receipt.qty - EPS:
				_exception("excess", code, receipt.id, receipt.date, "No requirement for this receipt")
			continue
		if receipt.left >= receipt.qty - EPS:
			_exception("cancel", code, receipt.id, receipt.date, "No requirement · cancel " + receipt.id)
			continue
		if receipt.left > maxf(EPS * 1000.0, rounding):
			_exception("excess", code, receipt.id, receipt.date, "Excess %s %s · reduce the quantity" % [_q(receipt.left), unit])
		if is_finite(receipt.first_use) and receipt.first_use > receipt.first + RESCHEDULE_TOLERANCE:
			_exception("reschedule_out", code, receipt.id, receipt.date,
				"Postpone by %s to %s" % [_span(receipt.first_use - receipt.first), _clock(receipt.first_use)])


## Follow raw-warehouse pallet positions through the dated rows and flag receipts that will not fit.
func _storage_exceptions() -> void:
	var catalog = book.catalog
	var capacity: int = catalog.raw_capacity()
	for po in book.purchases.values():
		if po.status != "Received" and float(po.get("at_dock", 0.0)) > EPS:
			_exception("at_dock", po.code, po.id, po.due, "Waiting at the dock: the raw material warehouse is full")
	if capacity <= 0:
		return
	var held := {}
	var used := 0
	for code in catalog.materials:
		if catalog.pallet_qty(code) <= 0.0:
			continue
		var in_house: float = book.stock(code, "RM-WH")
		# Reserved stock leaves the warehouse with its released order; stock already staged covers it first.
		var staged: float = book.total_stock(code) - in_house
		held[code] = maxf(0.0, in_house - maxf(0.0, float(book.reservations.get(code, 0.0)) - staged))
		used += catalog.positions(code, held[code])
	var flagged := {}
	for row in report.rows:
		if not held.has(row.code):
			continue
		var delta := 0.0
		if row.kind == "Requirement":
			delta = -row["out"]
		elif row.kind in RECEIPT_KINDS:
			delta = row["in"]
		else:
			continue
		var before: float = held[row.code]
		var after := maxf(0.0, before + delta)
		used += catalog.positions(row.code, after) - catalog.positions(row.code, before)
		held[row.code] = after
		if delta <= 0.0 or used <= capacity:
			continue
		var element: String = row.doc
		var proposal: Dictionary = report.proposals.get(row.proposal, {})
		if not proposal.is_empty():
			element = proposal.number
		if flagged.has(element):
			continue
		flagged[element] = true
		var message := "Needs %d of %d raw-warehouse pallet positions on arrival at %s" % [used, capacity, _clock(row.date)]
		_exception("storage_full", row.code, element, row.date, message)
		if not proposal.is_empty():
			proposal.exceptions.append(message)
			if book.planned_orders.has(element):
				book.planned_orders[element].exceptions.append(message)


func _peg_exceptions() -> void:
	for order in book.orders.values():
		if order.status not in ["Created", "Released"]:
			continue
		for id in order.get("pegs", []):
			var parent: Dictionary = book.orders.get(id, {})
			if parent.get("status", "") not in ["Created", "Released"]:
				continue
			var late := Scheduling.supply_late(book.catalog, order, parent)
			if late > EPS:
				var overlapped: bool = Scheduling.overlaps(book.catalog, parent.get("stage", ""), order.code)
				_exception("supply_late", order.code, order.id, order.finish,
					("First lot is %s late for %s (%s)" if overlapped else "Finishes %s after %s (%s) starts") % [_span(late), parent.id, parent.code])


# --- Publishing -----------------------------------------------------------------

## Keep firmed planned orders, replace unfirmed ones and reuse their numbers by planning key.
func _publish(numbers: Dictionary) -> void:
	var kept := {}
	for number in book.planned_orders:
		if book.planned_orders[number].firmed:
			kept[number] = book.planned_orders[number]
	for key in report.proposals:
		var data: Dictionary = report.proposals[key]
		var number: String = numbers.get(key, "")
		if number.is_empty() or kept.has(number):
			book.planned_sequence += 1
			number = "PLO-%05d" % book.planned_sequence
		data.number = number
		kept[number] = data.duplicate(true)
	book.planned_orders = kept
	var by_element := {}
	for exception in report.exceptions:
		by_element[exception.element] = true
	for number in kept:
		var data: Dictionary = kept[number]
		if data.firmed:
			report.proposals[data.id] = data.duplicate(true)
	for key in report.proposals:
		var data: Dictionary = report.proposals[key]
		var messages := []
		for exception in report.exceptions:
			if exception.element in [key, data.number]:
				messages.append(exception.message)
		data.exceptions = messages
		book.planned_orders[data.number].exceptions = messages.duplicate()
	for exception in report.exceptions:
		if report.proposals.has(exception.element):
			exception.element = report.proposals[exception.element].number


func _decorate_rows() -> void:
	var messages := {}
	for exception in report.exceptions:
		var key: String = "%s|%s" % [exception.code, exception.element]
		if not messages.has(key) or exception.severity > messages[key].severity:
			messages[key] = exception
	for row in report.rows:
		var element: String = row.doc
		if not row.proposal.is_empty() and report.proposals.has(row.proposal):
			element = report.proposals[row.proposal].number
		row.element = _element(row)
		row.number = "" if row.kind in ["Requirement", "Unreserved stock"] else element
		# The document that causes a requirement: a demand, a production order or a planned order.
		var source: String = row.doc
		if report.proposals.has(source):
			source = report.proposals[source].number
		elif book.planning_conversions.has(source):
			source = book.planning_conversions[source]
		row.source = source
		var hit: Dictionary = messages.get("%s|%s" % [row.code, element], {})
		if row.kind == "Requirement" and hit.get("kind", "") != "safety_stock":
			hit = {}
		row.exception = hit.get("message", "")
		row.severity = hit.get("severity", 0)


func _element(row: Dictionary) -> String:
	match row.kind:
		"Unreserved stock": return "Stock"
		"Requirement": return "IndReq" if String(row.doc).begins_with("DEM") else "DepReq"
		"Open PO": return "POitem"
		"Scheduled order", "Linked production": return "PrdOrd"
		"Production proposal": return "PlOrd."
		"Purchase proposal": return "PurRqs"
		"Firmed planned order": return "PlOrd.*"
		"Firmed requisition": return "PurRqs*"
		"Late scheduled receipt": return "Resched"
	return "Error"


## One line per planned material for the coverage overview.
func _coverage() -> void:
	for row in report.rows:
		var code: String = row.code
		if not report.coverage.has(code):
			var item: Dictionary = book.catalog.materials[code]
			report.coverage[code] = {"code": code, "available": float(initial.get(code, 0.0)), "safety": item.minimum,
				"lot": book.catalog.lot_caption(code), "requirements": 0, "receipts": 0, "planned": 0,
				"exceptions": 0, "severity": 0, "message": "", "uncovered_from": -1.0, "unit": item.unit}
		var line: Dictionary = report.coverage[code]
		if row.kind == "Requirement":
			line.requirements += 1
			if row.short > EPS and line.uncovered_from < 0.0:
				line.uncovered_from = row.date
		elif row.kind in ["Production proposal", "Purchase proposal", "Firmed planned order", "Firmed requisition"]:
			line.planned += 1
		elif row.kind in RECEIPT_KINDS:
			line.receipts += 1
	for exception in report.exceptions:
		var line: Dictionary = report.coverage.get(exception.code, {})
		if line.is_empty():
			continue
		line.exceptions += 1
		if exception.severity > line.severity:
			line.severity = exception.severity
			line.message = exception.message


static func _q(value: float) -> String:
	return str(snappedf(value, 0.001))


static func _span(seconds: float) -> String:
	var minutes := roundi(absf(seconds) / 60.0)
	return "%d h %02d min" % [minutes / 60, minutes % 60] if minutes >= 60 else "%d min" % minutes


static func _clock(seconds: float) -> String:
	var total := int(maxf(0.0, seconds))
	return "day %d %02d:%02d" % [total / 86400 + 1, (total % 86400) / 3600, (total % 3600) / 60]


static func convert(book, item: Dictionary, edits: Dictionary) -> Dictionary:
	var quantity: float = edits.get("quantity", item.get("quantity", item.qty))
	if item.type == "Buy":
		var bought: Dictionary = book.purchase(item.supplier, item.code, quantity)
		if bought.error.is_empty():
			book.planned_orders.erase(item.get("number", ""))
		return bought
	var start: float = edits.get("start", maxf(book.now, item.start))
	var result: Dictionary = book.create_order(item.code, quantity, start, 5, edits.get("version", item.version))
	if not result.error.is_empty():
		return result
	book.planned_orders.erase(item.get("number", ""))
	var order: Dictionary = book.orders[result.id]
	var earlier: Dictionary = book.orders.get(book.planning_conversions.get(item.id, ""), {})
	order.plan_key = "%s|%s" % [item.id, result.id] if not earlier.is_empty() and earlier.status != "Cancelled" else item.id
	order.parent_requirement = item.doc
	order.parent_requirements = item.get("docs", [item.doc]).duplicate()
	order.family = item.family
	order.planned_order = item.get("number", "")
	book.planning_conversions[order.plan_key] = result.id
	for doc in order.parent_requirements:
		if not book.demands.has(doc):
			continue
		var demand: Dictionary = book.demands[doc]
		if not demand.has("converted_orders"):
			demand.converted_orders = [] if String(demand.converted).is_empty() else [demand.converted]
		demand.converted_orders.append(result.id)
		demand.converted = result.id
		order.demand = doc
	for row in book.orders.values():
		if not row.has("parent_requirement") or row.status == "Cancelled":
			continue
		for requirement in row.get("parent_requirements", [row.parent_requirement]):
			var parent: String = book.planning_conversions.get(requirement, requirement)
			if book.orders.has(parent) and book.orders[parent].status != "Cancelled":
				Scheduling.peg(book, row.id, parent)
	return result
