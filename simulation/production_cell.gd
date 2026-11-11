extends RefCounted
## Reusable stock-to-stock cell. Jobs use the line's existing worker and cart reservations.
const Storage = preload("res://simulation/storage.gd")
const Machine = preload("res://simulation/machine.gd")
const EPS := 0.00000001

var inputs := {}
var output: Storage
var machine: Machine
var standard := {}
var partial := 0.0
var remaining := 0.0
var batch_output := 0.0
var produced := 0.0
var fed := 0.0
var inside := 0.0
var cohorts: Array = []
var batch_count := 0
var handling := false
var state := "Idle"


func _init(operation: Dictionary, recipe: Dictionary, model: Machine = null) -> void:
	standard = operation.standard.duplicate(true)
	output = Storage.new(operation.technical.output_kg)
	machine = model if model != null else Machine.new(0.0)
	for code in recipe.internals:
		inputs[code] = Storage.new(operation.technical.input_kg)


func advance(line, order: Dictionary, run: Dictionary) -> void:
	var dt: float = line.STEP_SECONDS
	var factor: float = line.operating_factors.get(run.equipment, 1.0)
	var nominal: float = line.erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec)
	if nominal > EPS:
		factor = minf(factor, order.route.operations[0].technical.get("design_rate", INF) / nominal)
	if run.setup > EPS:
		run.setup = maxf(0.0, run.setup - dt)
		state = "Setup / Changeover"
		machine.record(0.0, dt / 3600, Machine.State.SETUP)
		return
	var before := produced + partial
	match standard.model:
		"batch":
			if remaining > EPS:
				remaining = maxf(0.0, remaining - dt * factor)
				state = "Mixing"
				if remaining <= EPS:
					output.apply_transfer(batch_output, 0)
					produced += batch_output
					line._add_progress(order.stage, batch_output)
					line.erp.flow(order.code, batch_output, "", "WIP", "WIP Produced", "Cream batch complete")
					batch_output = 0
					batch_count += 1
			else:
				state = "Ready" if output.quantity > EPS else "Waiting for a batch load"
		"residence":
			_cool(line, order, dt, factor)
		"packaging":
			_pack(line, order, dt, factor)
		_:
			_process(line, order, dt, factor)
	var made := produced + partial - before
	var rate: float = line.erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec)
	machine.configured_rate = rate * factor
	var status := Machine.State.RUNNING if made > EPS or remaining > EPS or inside > EPS else Machine.State.STARVED
	if output.free_space() <= EPS:
		status = Machine.State.BLOCKED
	machine.record(made, dt / 3600, status)
	if made > EPS:
		line._start_stage()


func _process(line, order: Dictionary, dt: float, factor: float) -> void:
	var rates: Dictionary = order.recipe.mass_inputs
	var amount := minf(output.free_space(), order.recipe.target - produced)
	amount = minf(amount, line.erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec) * factor * dt / 3600)
	for code in inputs:
		amount = minf(amount, inputs[code].quantity / rates[code])
	if amount <= EPS:
		state = "Blocked" if output.free_space() <= EPS else "Waiting for input carts"
		return
	for code in inputs:
		var used: float = inputs[code].remove(amount * rates[code])
		line.erp.flow(code, used, "WIP", "", "WIP Used", "Process input")
	output.apply_transfer(amount, 0)
	produced += amount
	line._add_progress(order.stage, amount)
	line.erp.flow(order.code, amount, "", "WIP", "WIP Produced", order.stage)
	line._record_scrap(order, amount, standard.yield_factor)
	state = "Running"


func _cool(line, order: Dictionary, dt: float, factor: float) -> void:
	var stock: Storage = inputs[order.recipe.input]
	var step_limit: float = line.erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec) * factor * dt / 3600
	var amount := minf(step_limit, minf(stock.quantity, minf(standard.internal_kg - inside, order.recipe.target - fed)))
	if amount > EPS:
		stock.remove(amount)
		inside += amount
		fed += amount
		cohorts.append([line.erp.now + standard.residence_seconds, amount])
		line._start_stage()
	var exit_room := minf(step_limit, output.free_space())
	while not cohorts.is_empty() and cohorts[0][0] <= line.erp.now and exit_room > EPS:
		var ready := minf(cohorts[0][1], exit_room)
		exit_room -= ready
		output.apply_transfer(ready, 0)
		inside -= ready
		produced += ready
		cohorts[0][1] -= ready
		line._add_progress(order.stage, ready)
		line._stage_transform(order.recipe.input, ready, order.code, ready, "Cooling residence completed")
		if cohorts[0][1] <= EPS:
			cohorts.pop_front()
	if inside > EPS:
		state = "Cooling"
	else:
		state = "Waiting for output cart" if fed + EPS >= order.recipe.target else "Waiting for input carts"


func _pack(line, order: Dictionary, dt: float, factor: float) -> void:
	var stock: Storage = inputs[order.recipe.input]
	var box: float = order.recipe.spec.box_kg
	var amount := minf(stock.quantity, standard.rate * factor * box * dt / 3600)
	var before := stock.quantity
	while amount > EPS and order.packed < order.boxes and output.free_space() + EPS >= box:
		if not line.erp.can_pack(false):
			break
		var moved := minf(amount, box - partial)
		stock.remove(moved)
		partial += moved
		amount -= moved
		line._start_stage()
		if partial + EPS >= box:
			for code in order.recipe.packaging:
				line.erp._consume(order, code, 1, order.route.operations[0].supply_location, "Carton formed")
			order.packed += 1
			line.boxes_completed += 1
			line._add_progress("pack", box)
			line.erp.flow(order.recipe.input, box, "WIP", "", "WIP Used", "Carton packed")
			line.erp.flow(order.code, box, "", "WIP", "Packed Receipt", "Carton packed")
			output.apply_transfer(box, 0)
			produced += box
			partial = 0
	state = "Packaging" if stock.quantity < before else "Waiting for wafers or packaging supplies"


func batch_size(order: Dictionary) -> float:
	var capacity: float = standard.batch_kg * standard.yield_factor
	var count := ceili(order.recipe.target / capacity - EPS)
	return minf(order.recipe.target - produced, order.recipe.target / count)


func jobs(line, run: Dictionary, order: Dictionary) -> Array:
	var result := []
	var active: bool = order.status == "In Progress"
	var dock = run.store
	var intake = run.intake
	var outbound = run.outbound
	var pallet = run.pack
	var cart_type = line.Cart
	var kinds = line.JobKind
	var stock_point: Vector3 = line.layout.port(&"SFGWarehouse", &"stock_dock")
	var operation: Dictionary = order.route.operations[0]
	var in_port := StringName(operation.input_port)
	var out_port := StringName(operation.output_port)
	if line._available(dock, cart_type.Site.SFG_DOCK):
		if dock.stock.quantity > EPS:
			if dock.material == order.code:
				result.append(line._handling(kinds.SFG_UNLOAD, dock, "Receive " + order.code))
			else:
				result.append(line._move(dock, cart_type.Site.CELL_IN, line.layout.port(run.equipment, in_port), "Deliver " + dock.material))
		elif not dock.material.is_empty() and active:
			result.append(line._handling(kinds.SFG_LOAD, dock, "Collect reserved " + dock.material))
		else:
			result.append(line._move(dock, cart_type.Site.PARKING, dock.home, "Return stock cart"))
	if line._available(intake, cart_type.Site.CELL_IN):
		if intake.stock.quantity > EPS:
			result.append(line._handling(kinds.CELL_INPUT, intake, "Unload " + intake.material))
		elif standard.model == "batch" and active and _can_load_raw(line, order, run):
			result.append(line._handling(kinds.CELL_BATCH, intake, "Load cream ingredients"))
		else:
			result.append(line._move(intake, cart_type.Site.PARKING, intake.home, "Return input cart"))
	if line._available(outbound, cart_type.Site.CELL_OUT):
		if outbound.stock.quantity > EPS:
			if standard.model == "packaging":
				if line.pallet_dock == null:
					result.append(line._move(outbound, cart_type.Site.PALLET_DOCK, line.layout.port(&"Palletizer", &"cart_dock"), "Deliver boxed wafers"))
			elif line.sfg_dock == null:
				result.append(line._move(outbound, cart_type.Site.SFG_DOCK, stock_point, "Deliver " + order.code))
		elif output.quantity > EPS:
			result.append(line._handling(kinds.CELL_OUTPUT, outbound, "Load " + order.code))
		else:
			result.append(line._move(outbound, cart_type.Site.PARKING, outbound.home, "Return output cart"))
	if line._available(pallet, cart_type.Site.PALLET_DOCK):
		if pallet.stock.quantity > EPS:
			if _pallet_slot(line, order) >= 0:
				result.append(line._handling(kinds.CELL_PALLET, pallet, "Palletize boxed wafers"))
		else:
			result.append(line._move(pallet, cart_type.Site.PARKING, pallet.home, "Return carton cart"))
	# Hold carts only during an actual delivery or collection, to preserve the shared pool.
	if active and run.setup <= EPS:
		if outbound == null and output.quantity > EPS:
			var cart = line._parked_category("cooked")
			if cart != null:
				var load_limit: float = minf(cart.stock.capacity, output.capacity)
				if standard.model == "packaging":
					var box: float = order.recipe.spec.box_kg
					load_limit = floorf(load_limit / box + EPS) * box
				if load_limit > EPS and (output.quantity + EPS >= load_limit or produced + EPS >= order.recipe.target
						or standard.model == "batch"):
					result.append(_move(line, cart, cart_type.Site.CELL_OUT, line.layout.port(run.equipment, out_port), "Collect cell output", order.code))
		if intake == null and standard.model == "batch" and _can_load_raw(line, order, run):
			var cart = line._parked_category("cooked")
			if cart != null:
				result.append(line._move(cart, cart_type.Site.CELL_IN, line.layout.port(run.equipment, in_port), "Load cream mixer"))
		elif intake == null and line.sfg_dock == null:
			for code in inputs:
				if float(order.remaining.get(code, 0)) <= EPS or inputs[code].free_space() <= EPS or line.erp.stock(code, "SFG-WH") <= EPS:
					continue
				var cart = line._parked_category("cooked")
				if cart != null:
					result.append(_move(line, cart, cart_type.Site.SFG_DOCK, stock_point, "Collect " + code, code))
				break
	return result


func _move(line, cart, site: int, point: Vector3, title: String, code: String):
	var job = line._move(cart, site, point, title)
	job.material = code
	return job


func _can_load_raw(line, order: Dictionary, run: Dictionary) -> bool:
	if handling or remaining > EPS or batch_output > EPS or produced + EPS >= order.recipe.target:
		return false
	var batch := batch_size(order)
	if output.free_space() + EPS < batch:
		return false
	for code in order.recipe.mass_inputs:
		if line.erp.stock(code, order.route.operations[0].supply_location) + EPS < batch * order.recipe.mass_inputs[code]:
			return false
	return true


func _pallet_slot(line, order: Dictionary) -> int:
	for index in line.staged_pallets.size():
		var pallet = line.staged_pallets[index]
		if pallet != null and pallet.order_id == order.id and not pallet.full():
			return index
	return line.staged_pallets.find(null)


func handle(line, run: Dictionary, order: Dictionary, job) -> void:
	var cart = job.cart
	match job.kind:
		line.JobKind.CELL_INPUT:
			var stock: Storage = inputs[cart.material]
			stock.apply_transfer(cart.stock.remove(stock.free_space()), 0)
		line.JobKind.CELL_OUTPUT:
			var amount: float = minf(output.quantity, cart.stock.free_space())
			if standard.model == "packaging":
				amount = floorf(amount / order.recipe.spec.box_kg + EPS) * order.recipe.spec.box_kg
			cart.stock.apply_transfer(output.remove(amount), 0)
			cart.material = order.code
			cart.order_id = order.id
		line.JobKind.CELL_BATCH:
			batch_output = batch_size(order)
			for code in order.recipe.mass_inputs:
				line.erp._consume(order, code, batch_output * order.recipe.mass_inputs[code],
					order.route.operations[0].supply_location, "Load cream mixer")
			line.ingredients_taken += batch_output / standard.yield_factor
			remaining = standard.cycle_seconds
			line._start_stage()
			handling = false
			line._record_scrap(order, batch_output, standard.yield_factor)
		line.JobKind.CELL_PALLET:
			var box: float = order.recipe.spec.box_kg
			while cart.stock.quantity + EPS >= box:
				var index: int = _pallet_slot(line, order)
				if index < 0:
					break
				if line.staged_pallets[index] == null:
					var location: String = order.route.operations[0].supply_location
					if line.erp.stock("PK-PALLET", location) < 1:
						break
					line.erp._consume(order, "PK-PALLET", 1, location, "Pallet opened")
					var pallet = line.Pallet.new(order.recipe.spec.boxes_per_pallet)
					pallet.id = "%s-P%04d" % [order.id, order.get("pallet_sequence", 0) + 1]
					order.pallet_sequence = order.get("pallet_sequence", 0) + 1
					pallet.order_id = order.id
					pallet.sku = order.code
					pallet.tint = order.recipe.spec.package_color
					line.staged_pallets[index] = pallet
				line.staged_pallets[index].add_box(cart.stock.remove(box))
				order.palletized = order.get("palletized", 0) + 1
				if order.palletized == order.boxes:
					line.staged_pallets[index].sealed = true


func mass() -> float:
	var total := output.quantity + partial + inside + batch_output
	for stock in inputs.values():
		total += stock.quantity
	return total


func wip(order: Dictionary) -> Dictionary:
	var totals := {order.code: output.quantity + batch_output}
	for code in inputs:
		totals[code] = inputs[code].quantity
	if inside + partial > EPS:
		totals[order.recipe.input] = float(totals.get(order.recipe.input, 0)) + inside + partial
	return totals


func snapshot() -> Dictionary:
	var state_data := {}
	for key in ["partial", "remaining", "batch_output", "produced", "fed", "inside", "cohorts", "batch_count", "handling", "state"]:
		state_data[key] = get(key)
	state_data.output = output.quantity
	state_data.inputs = {}
	for code in inputs:
		state_data.inputs[code] = inputs[code].quantity
	state_data.machine = [machine.configured_rate, machine.actual_rate, machine.state, machine.total_output]
	return state_data.duplicate(true)


func restore(data: Dictionary) -> void:
	for key in ["partial", "remaining", "batch_output", "produced", "fed", "inside", "cohorts", "batch_count", "handling", "state"]:
		set(key, data[key])
	output.quantity = data.output
	for code in inputs:
		inputs[code].quantity = data.inputs[code]
	machine.configured_rate = data.machine[0]
	machine.actual_rate = data.machine[1]
	machine.state = data.machine[2]
	machine.total_output = data.machine[3]
