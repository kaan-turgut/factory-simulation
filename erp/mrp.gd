extends RefCounted
## Time-phased lot-for-lot planning. Rows and proposals never post stock.

const StageMRP = preload("res://erp/stage_mrp.gd")

var rows: Array[Dictionary] = []
var proposals := {}
var summary := {}
var exceptions: Array[Dictionary] = []
var coverage := {}
var _book
var _requirements := {}


func run(book, finished_stock: Dictionary) -> void:
	_book = book
	rows.clear()
	proposals.clear()
	exceptions.clear()
	coverage.clear()
	_requirements.clear()
	summary = {"shortages": {}, "buy": 0, "make": 0, "late": 0, "covered": 0, "requirements": 0}
	if book.explicit_planning:
		StageMRP.new().run(self, book, finished_stock)
		return
	var future_fg := {}
	var fg := finished_stock.duplicate()
	for order in book.orders.values():
		if not String(order.get("demand", "")).is_empty() and order.status != "Cancelled":
			var on_hand := float(order.received_kg) - float(order.get("dispatched_kg", 0.0))
			fg[order.code] = maxf(0.0, float(fg.get(order.code, 0.0)) - on_hand)
		elif order.status in book.OPEN:
			if not future_fg.has(order.code):
				future_fg[order.code] = []
			future_fg[order.code].append({"date": order.finish, "qty": (order.boxes - order.received) * order.recipe.spec.box_kg})
		if order.status == "Created":
			_components(order, order.start)
	var demand: Array = book.demands.values()
	demand.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _earlier(a, b, "due"))
	for requirement in demand:
		var code: String = requirement.code
		var available := float(fg.get(code, 0.0))
		for receipt in future_fg.get(code, []):
			if receipt.date <= requirement.due:
				available += receipt.qty
				receipt.qty = 0.0
		var remaining: float = requirement.recipe.target
		var linked: Dictionary = book.orders.get(requirement.converted, {})
		if not linked.is_empty() and linked.status != "Cancelled":
			var committed := minf(remaining, float(linked.recipe.target))
			var finish: float = linked.completed if linked.completed >= 0.0 else linked.finish
			var late := committed if finish > float(requirement.due) else 0.0
			summary.late += int(late > 0.0)
			_row(code, finish, "Linked production", committed, 0.0, available + committed,
				late, linked.id, requirement.recipe.spec.family)
			remaining -= committed
		var boxes := ceili(maxf(0.0, remaining - available) / requirement.recipe.spec.box_kg - 1e-8)
		fg[code] = maxf(0.0, available - remaining)
		var shortage := maxf(0.0, remaining - available)
		_row(code, requirement.due, "Demand", 0.0, requirement.recipe.target, available - remaining,
			shortage, requirement.id, requirement.recipe.spec.family)
		if boxes > 0 and linked.is_empty():
			var recipe: Dictionary = book.catalog.recipe(code, boxes)
			if not recipe.error.is_empty():
				_row(code, requirement.due, "BOM error", 0.0, 0.0, -1.0, 0.0, requirement.id, requirement.recipe.spec.family)
				continue
			var route: Dictionary = book.catalog.route_for(code, boxes, maxf(book.now, requirement.due))
			if route.error.is_empty():
				var projected_start := float(requirement.due) - maxf(float(recipe.spec.lead), book.catalog.estimate(recipe, route) + 120.0)
				route = book.catalog.route_for(code, boxes, maxf(book.now, projected_start), route.production_version)
			if not route.error.is_empty():
				summary.shortages[code] = true
				_row(code, requirement.due, "No eligible route", 0.0, 0.0, -shortage, shortage, requirement.id,
					requirement.recipe.spec.family)
				continue
			var start := float(requirement.due) - maxf(float(recipe.spec.lead), book.catalog.estimate(recipe, route) + 120.0)
			var key: String = "MAKE|" + requirement.id
			proposals[key] = {"id": key, "type": "Make", "doc": requirement.id, "code": code,
				"boxes": boxes, "qty": recipe.target, "start": start, "version": route.production_version}
			summary.make += 1
			summary.late += int(start < book.now)
			_row(code, requirement.due, "Planned production", recipe.target, 0.0, fg[code],
				0.0, requirement.id, recipe.spec.family, key, start)
			_components({"id": requirement.id, "recipe": recipe}, start)
			fg[code] = maxf(0.0, available + recipe.target - requirement.recipe.target)
	for code in _requirements:
		_net_material(code, _requirements[code])
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.index < b.index if a.date == b.date else a.date < b.date)


func _earlier(a: Dictionary, b: Dictionary, key: String) -> bool:
	if a[key] == b[key]:
		return String(a.get("id", a.get("doc", ""))) < String(b.get("id", b.get("doc", "")))
	return float(a[key]) < float(b[key])


func _components(document: Dictionary, start: float) -> void:
	var recipe: Dictionary = document.recipe
	var family: String = recipe.spec.family
	for code in [recipe.dough, recipe.raw, recipe.baked, recipe.coated]:
		var need: float = recipe.target if code == recipe.coated else recipe.dough_target
		var offset := 90.0 if code == recipe.coated else (55.0 if code == recipe.baked else 0.0)
		_row(code, start + offset, "Routing supply", need, need, 0.0, 0.0, document.id, family)
	for code in recipe.needs:
		if not _requirements.has(code):
			_requirements[code] = []
		var offset := 90.0 if code == recipe.coating else (120.0 if _book.catalog.materials[code].type == "VERP" else 0.0)
		_requirements[code].append({"date": start + offset, "qty": recipe.needs[code], "doc": document.id, "family": family})


func _net_material(code: String, needs: Array) -> void:
	needs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _earlier(a, b, "date"))
	var balance: float = _book.available(code)
	_row(code, _book.now, "Available stock", balance, 0.0, balance, 0.0, "", "")
	var receipts := []
	for po in _book.purchases.values():
		if po.code == code and po.status != "Received":
			receipts.append({"date": po.due, "qty": po.qty - po.received, "allocated": 0.0, "id": po.id})
	receipts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _earlier(a, b, "date"))
	var received_index := 0
	var allocated_in_future := 0.0
	for requirement in needs:
		var due: float = requirement.date
		while received_index < receipts.size() and receipts[received_index].date <= due:
			var receipt: Dictionary = receipts[received_index]
			allocated_in_future -= float(receipt.allocated)
			balance = _receipt(code, receipt, balance, allocated_in_future)
			received_index += 1
		var minimum: float = _book.catalog.materials[code].minimum
		var deficit := maxf(0.0, requirement.qty + minimum - balance)
		summary.requirements += 1
		if deficit <= 1e-7:
			summary.covered += 1
		else:
			summary.shortages[code] = true
		var projection: float = balance - requirement.qty - allocated_in_future
		_row(code, due, "BOM requirement", 0.0, requirement.qty, projection,
			deficit, requirement.doc, requirement.family)
		var late_qty := 0.0
		var late_receipt := false
		for index in range(received_index, receipts.size()):
			if deficit - late_qty <= 1e-7:
				break
			var receipt: Dictionary = receipts[index]
			var allocate := minf(deficit - late_qty, float(receipt.qty) - float(receipt.allocated))
			if allocate > 1e-7:
				receipt.allocated += allocate
				late_qty += allocate
				late_receipt = true
				_row(code, due, "Late scheduled receipt", 0.0, 0.0, projection,
					allocate, receipt.id, requirement.family, "", receipt.date)
		summary.late += int(late_receipt)
		var shortage := deficit - late_qty
		balance += late_qty - requirement.qty
		allocated_in_future += late_qty
		if shortage <= 1e-7:
			continue
		var supplier: Dictionary = _book.catalog.supplier_for(code)
		if supplier.is_empty():
			_row(code, due, "No supplier", 0.0, 0.0, projection, shortage, requirement.doc, requirement.family)
			continue
		var qty := maxf(shortage, supplier.minimum)
		if _book.catalog.materials[code].unit == "ea":
			qty = ceilf(qty - 1e-7)
		var start := due - maxf(float(supplier.lead), float(_book.catalog.materials[code].lead))
		var key := "BUY|%s|%s" % [requirement.doc, code]
		proposals[key] = {"id": key, "type": "Buy", "supplier": supplier.id, "doc": requirement.doc,
			"code": code, "qty": qty, "start": start}
		summary.buy += 1
		summary.late += int(start < _book.now)
		balance += qty
		_row(code, due, "Purchase proposal", qty, 0.0, projection + qty, shortage,
			requirement.doc, requirement.family, key, start)
	while received_index < receipts.size():
		var receipt: Dictionary = receipts[received_index]
		allocated_in_future -= float(receipt.allocated)
		balance = _receipt(code, receipt, balance, allocated_in_future)
		received_index += 1


func _receipt(code: String, receipt: Dictionary, balance: float, future_allocated: float) -> float:
	var available: float = balance + receipt.qty - receipt.allocated
	_row(code, receipt.date, "Open PO", receipt.qty, 0.0, available - future_allocated, 0.0, receipt.id, "")
	return available


func _row(code: String, date: float, kind: String, incoming: float, outgoing: float, projected: float,
		short: float, doc: String, family: String, proposal: String = "", action_date: float = -1.0) -> Dictionary:
	var row := {"code": code, "date": date, "kind": kind, "in": incoming, "out": outgoing,
		"projected": projected, "short": short, "doc": doc, "family": family, "proposal": proposal,
		"action_date": action_date, "index": rows.size()}
	rows.append(row)
	return row


## A proposal by planning key or planned order number.
func find(key: String) -> Dictionary:
	if proposals.has(key):
		return proposals[key]
	for item in proposals.values():
		if item.get("number", "") == key:
			return item
	return {}


func convert(key: String, book, finished_stock: Dictionary, edits: Dictionary = {}) -> Dictionary:
	run(book, finished_stock)
	var item: Dictionary = find(key)
	if item.is_empty():
		return {"error": "This proposal is no longer required. Run MRP again."}
	var result: Dictionary
	if book.explicit_planning:
		result = StageMRP.convert(book, item, edits)
	elif item.type == "Buy":
		result = book.purchase(item.supplier, item.code, item.qty)
	else:
		result = book.create_order(item.code, item.boxes, maxf(book.now, item.start), 5, item.version)
		if result.error.is_empty():
			book.demands[item.doc].converted = result.id
			book.orders[result.id].demand = item.doc
	if result.error.is_empty():
		run(book, finished_stock)
	return result


## Convert every proposal accepted by the filter, parents before components so pegging links.
## Returns the created documents and the proposals that failed.
func convert_all(book, finished_stock: Dictionary, accept: Callable = Callable()) -> Dictionary:
	var created: Array[String] = []
	var failed: Array[Dictionary] = []
	var tried := {}
	run(book, finished_stock)
	for attempt in 500:
		var next: Dictionary = {}
		for item in proposals.values():
			if not tried.has(item.id) and (not accept.is_valid() or accept.call(item)):
				next = item
				break
		if next.is_empty():
			break
		tried[next.id] = true
		var result := self.convert(next.id, book, finished_stock)
		if result.error.is_empty():
			created.append(result.id)
		else:
			failed.append({"proposal": next.get("number", next.id), "code": next.code, "error": result.error})
	return {"created": created, "failed": failed}


## Firm or unfirm a planned order. MRP never changes a firmed order.
func firm(number: String, enabled: bool, book, finished_stock: Dictionary) -> String:
	if not book.planned_orders.has(number):
		return "Select a planned order. Run MRP to refresh numbers."
	book.planned_orders[number].firmed = enabled
	book.changed()
	run(book, finished_stock)
	return ""


## Change the quantity or start of a planned order. The change firms it, as in SAP.
func change(number: String, quantity: float, start: float, book, finished_stock: Dictionary) -> String:
	var item: Dictionary = book.planned_orders.get(number, {})
	if item.is_empty():
		return "Select a planned order. Run MRP to refresh numbers."
	if not is_finite(quantity) or quantity <= 0.0 or not is_finite(start) or start < book.now - 0.000001:
		return "Use a positive quantity and a start at or after the current time."
	var material: Dictionary = book.catalog.materials[item.code]
	if item.type == "Make":
		if material.type == "FERT" and not is_equal_approx(quantity, roundf(quantity)):
			return "Finished goods are planned in whole shipping boxes."
		var assignment: Dictionary = StageMRP.Scheduling.assignment(book, item.code, quantity, start, item.version)
		if not assignment.error.is_empty():
			return assignment.error
		item.quantity = quantity
		item.qty = assignment.recipe.target
		item.boxes = quantity if material.type == "FERT" else 0
		item.start = start
		item.duration = assignment.duration
		item.due = start + assignment.duration
		item.finish = item.due
	else:
		if quantity + 0.000001 < float(item.get("minimum", 0.0)):
			return "Below the supplier minimum of %s." % item.minimum
		item.qty = ceilf(quantity - 0.000001) if material.unit == "ea" else quantity
		item.quantity = item.qty
		item.start = start
		item.due = start + float(item.lead)
		item.finish = item.due
	item.erase("earliest_finish")
	item.firmed = true
	book.changed()
	run(book, finished_stock)
	return ""
