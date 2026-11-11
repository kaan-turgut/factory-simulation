extends RefCounted
## Plan one level at a time, allocating shared stock to dated requirements across SKUs.

const Scheduling = preload("res://erp/scheduling.gd")
const EPS := 0.000001

var book
var report
var needs := {}
var supply := {}
var initial := {}


func run(target, ledger, finished: Dictionary) -> void:
	book = ledger
	report = target
	for code in book.catalog.materials:
		initial[code] = maxf(0.0, book.total_stock(code) - book.stock(code, "TRANSIT") - float(book.reservations.get(code, 0.0)))
		if book.catalog.materials[code].type == "FERT":
			initial[code] = finished.get(code, 0.0)
	for po in book.purchases.values():
		if po.status != "Received":
			_supply(po.code, po.due, po.qty - po.received, po.id, [], "Open PO")
	for order in book.orders.values():
		if order.status == "Cancelled":
			continue
		if order.status in book.OPEN and order.has("stage"):
			var linked: String = order.get("demand", "")
			if linked.is_empty():
				_supply(order.code, maxf(book.now, order.finish), order.recipe.target - order.received_kg,
					order.id, _parents(order), "Scheduled order")
			if order.status == "Created":
				_components(order.recipe, order.start, order.get("plan_key", order.id), _family(order))
		if not String(order.get("demand", "")).is_empty():
			initial[order.code] = maxf(0.0, float(initial[order.code]) - maxf(0.0, order.received_kg - order.get("dispatched_kg", 0.0)))
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
	report.rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.date != b.date:
			return a.date < b.date
		if (a["in"] > EPS) != (b["in"] > EPS):
			return a["in"] > EPS
		return a.index < b.index)
	var projected := initial.duplicate()
	for row in report.rows:
		if row.kind == "Requirement":
			projected[row.code] -= row["out"]
		elif row.kind in ["Open PO", "Scheduled order", "Production proposal", "Purchase proposal"]:
			projected[row.code] += row["in"]
		row.projected = projected[row.code]


func _parents(order: Dictionary) -> Array:
	var result := []
	for id in order.get("pegs", []):
		var parent: Dictionary = book.orders.get(id, {})
		if not parent.is_empty() and parent.status == "Created":
			result.append(parent.get("plan_key", id))
	var requirement: String = order.get("parent_requirement", "")
	if not requirement.is_empty() and not book.planning_conversions.has(requirement) and not book.orders.has(requirement):
		result.append(requirement)
	return result


func _family(order: Dictionary) -> String:
	return order.get("family", order.recipe.spec.get("family", ""))


func _need(code: String, date: float, amount: float, doc: String, family: String) -> void:
	if amount <= EPS:
		return
	if not needs.has(code):
		needs[code] = []
	needs[code].append({"date": date, "qty": amount, "doc": doc, "family": family})


func _components(recipe: Dictionary, start: float, doc: String, family: String) -> void:
	for component in recipe.needs:
		_need(component, start, recipe.needs[component], doc, family)


func _supply(code: String, date: float, qty: float, id: String, parents: Array, kind: String) -> void:
	if qty <= EPS:
		return
	if not supply.has(code):
		supply[code] = []
	supply[code].append({"date": date, "qty": qty, "left": qty, "id": id, "parents": parents, "kind": kind})


func _by_date(a: Dictionary, b: Dictionary) -> bool:
	return a.date < b.date


func _net(code: String) -> void:
	var requirements: Array = needs.get(code, [])
	if requirements.is_empty():
		return
	requirements.sort_custom(_by_date)
	var receipts: Array = supply.get(code, [])
	receipts.sort_custom(_by_date)
	var balance: float = initial[code]
	var minimum: float = book.catalog.materials[code].minimum
	report._row(code, book.now, "Unreserved stock", balance, 0.0, balance, 0.0, "", "")
	for need in requirements:
		var due: float = need.date
		var outstanding: float = need.qty + minimum
		# First use an explicitly pegged receipt, then on-hand stock, then other receipts.
		for receipt in receipts:
			if need.doc in receipt.parents and receipt.date <= due:
				outstanding -= _allocate(receipt, outstanding)
		var allocated := minf(balance, outstanding)
		balance -= allocated
		outstanding -= allocated
		for receipt in receipts:
			if receipt.date <= due and (receipt.parents.is_empty() or need.doc in receipt.parents):
				outstanding -= _allocate(receipt, outstanding)
		var shortage := maxf(0.0, outstanding)
		var projected := balance - shortage + minimum
		report.summary.requirements += 1
		if shortage <= EPS:
			report.summary.covered += 1
		else:
			report.summary.shortages[code] = true
		report._row(code, due, "Requirement", 0.0, need.qty, projected, shortage, need.doc, need.family)
		for receipt in receipts:
			if outstanding <= EPS:
				break
			if receipt.date <= due or (not receipt.parents.is_empty() and need.doc not in receipt.parents):
				continue
			var late := _allocate(receipt, outstanding)
			outstanding -= late
			if late > EPS:
				report.summary.late += 1
				report._row(code, due, "Late scheduled receipt", 0.0, 0.0, projected, late,
					receipt.id, need.family, "", receipt.date)
		var replenished := 0.0
		if outstanding > EPS:
			replenished = _proposal(code, need, outstanding, projected)
		if outstanding <= EPS or replenished > 0.0:
			balance += minimum + maxf(0.0, replenished - outstanding)
		else:
			balance += maxf(0.0, minimum - outstanding)
	for receipt in receipts:
		report._row(code, receipt.date, receipt.kind, receipt.qty, 0.0,
			receipt.left, 0.0, receipt.id, "")


func _allocate(receipt: Dictionary, quantity: float) -> float:
	var allocated := minf(receipt.left, maxf(0.0, quantity))
	receipt.left -= allocated
	return allocated


func _proposal(code: String, need: Dictionary, gap: float, projected: float) -> float:
	var due: float = need.date
	var item: Dictionary = book.catalog.materials[code]
	var make: bool = item.procurement == "In-house"
	var key := "%s|%s|%s" % ["MAKE" if make else "BUY", need.doc, code]
	var data := {"id": key, "type": "Make" if make else "Buy", "doc": need.doc,
		"code": code, "qty": gap, "family": need.family, "due": due}
	if make:
		data.quantity = ceilf(gap / item.box_kg - EPS) if item.type == "FERT" else gap
		var assignment := Scheduling.assignment(book, code, data.quantity, maxf(book.now, due), "")
		if not assignment.error.is_empty():
			report._row(code, due, assignment.error, 0.0, 0.0, projected, gap, need.doc, need.family)
			return 0.0
		data.qty = assignment.recipe.target
		data.boxes = data.quantity if item.type == "FERT" else 0
		data.start = due - assignment.duration
		data.version = assignment.route.production_version
		_components(assignment.recipe, data.start, key, need.family)
		report.summary.make += 1
	else:
		var supplier: Dictionary = book.catalog.supplier_for(code)
		if supplier.is_empty():
			report._row(code, due, "No supplier", 0.0, 0.0, projected, gap, need.doc, need.family)
			return 0.0
		data.supplier = supplier.id
		data.qty = maxf(gap, supplier.minimum)
		if item.unit == "ea":
			data.qty = ceilf(data.qty - EPS)
		data.start = due - maxf(float(item.lead), float(supplier.lead))
		report.summary.buy += 1
	report.proposals[key] = data
	report.summary.late += int(data.start < book.now)
	report._row(code, due, "Production proposal" if make else "Purchase proposal", data.qty,
		0.0, projected + data.qty, gap, need.doc, need.family, key, data.start)
	return data.qty


static func convert(book, item: Dictionary, edits: Dictionary) -> Dictionary:
	var quantity: float = edits.get("quantity", item.get("quantity", item.qty))
	if item.type == "Buy":
		return book.purchase(item.supplier, item.code, quantity)
	var start: float = edits.get("start", maxf(book.now, item.start))
	var result: Dictionary = book.create_order(item.code, quantity, start, 5, edits.get("version", item.version))
	if not result.error.is_empty():
		return result
	var order: Dictionary = book.orders[result.id]
	var earlier: Dictionary = book.orders.get(book.planning_conversions.get(item.id, ""), {})
	order.plan_key = "%s|%s" % [item.id, result.id] if not earlier.is_empty() and earlier.status != "Cancelled" else item.id
	order.parent_requirement = item.doc
	order.family = item.family
	book.planning_conversions[order.plan_key] = result.id
	if book.demands.has(item.doc):
		var demand: Dictionary = book.demands[item.doc]
		if not demand.has("converted_orders"):
			demand.converted_orders = [] if String(demand.converted).is_empty() else [demand.converted]
		demand.converted_orders.append(result.id)
		demand.converted = result.id
		order.demand = item.doc
	for row in book.orders.values():
		if not row.has("parent_requirement") or row.status == "Cancelled":
			continue
		var parent: String = book.planning_conversions.get(row.parent_requirement, row.parent_requirement)
		if book.orders.has(parent) and book.orders[parent].status != "Cancelled":
			Scheduling.peg(book, row.id, parent)
	return result
