extends RefCounted
## Authoritative chocolate-wafer line. Only fixed simulation ticks move people or material.

const ERP = preload("res://erp/operations.gd")
const Machine = preload("res://simulation/machine.gd")
const Storage = preload("res://simulation/storage.gd")
const Layout = preload("res://layout/factory_layout.gd")
const Settings = preload("res://simulation/factory_settings.gd")
const Operator = preload("res://simulation/operator.gd")
const Cart = preload("res://simulation/wafer_cart.gd")
const Oven = preload("res://simulation/batch_oven.gd")
const Pallet = preload("res://simulation/pallet.gd")

const SPEEDS := [1, 5, 20]
const STEP_SECONDS := 0.25
const STEP_HOURS := STEP_SECONDS / 3600.0
const EPSILON := 1e-8
const CART_HANDLING_SECONDS := 3.0
const COATER_OUTFEED_KG := 36.0
const LIFT_HANDLING_SECONDS := 2.0

enum JobKind { MOVE_CART, LOAD_OVEN, UNLOAD_OVEN, FEED_COATER, LOAD_COATED, UNLOAD_PACK_WIP }
enum LiftPhase { WAIT, TO_PALLET, PICK_UP, TO_STORAGE, DROP_OFF, RETURN }

class FloorJob:
	var kind: JobKind
	var cart: Cart
	var site: Cart.Site
	var point: Vector3
	var title: String
	var run := ""

	func _init(
		action: JobKind, tray: Cart, destination: Cart.Site, at: Vector3, description: String
	) -> void:
		kind = action
		cart = tray
		site = destination
		point = at
		title = description


var layout: Layout
var erp: ERP
var validation_error := ""
var ovens: Dictionary[StringName, Oven] = {}
var coaters: Dictionary[StringName, Machine] = {}
var coater_inputs: Dictionary[StringName, Storage] = {}
var runs := {}
var last_coatings := {}
var pack_last_recipe := {}
var _run := {}
var settings := Settings.defaults()
var playing := false
var multiplier := 1
var elapsed_ticks := 0
var ingredients_taken := 0.0
var dispatched_kg := 0.0
var dispatched_pallets := 0
var boxes_completed := 0
var raw_deliveries := 0
var cooked_deliveries := 0
var forklift_deliveries := 0

var hopper := Storage.new(settings[&"hopper_capacity"])
var cooked_input := Storage.new(settings[&"coater_input"])
var coated_input := Storage.new(12.0)
var pack_wip := Storage.new(settings[&"pack_wip_capacity"])
var extruder := Machine.new(settings[&"extruder_rate"])
var coater := Machine.new(settings[&"coater_rate"])
var packer := Machine.new(settings[&"packing_rate"])
var oven := Oven.new(settings[&"batch_capacity"])
var platform_crew: Array[Operator] = []
var floor_crew: Array[Operator] = []
var carts: Array[Cart] = []
var forklift: Operator
var lift_load: Pallet
var staged_pallets: Array[Pallet] = []
var warehouse: Array[Pallet] = []
var pending_jobs: Array[FloorJob] = []
var floor_assignments: Dictionary[StringName, FloorJob] = {}
var hopper_reserved := 0.0
var raw_at_extruder: Cart
var raw_at_oven: Cart
var cooked_at_oven: Cart
var cooked_at_coater: Cart
var pack_dock: Cart
var warehouse_reserved_slot := -1
var box_progress := 0.0
var box_target := 0.0

var _pending_seconds := 0.0
var _cart_route_owner: StringName = &""
var _lift_phase := LiftPhase.WAIT
var _lift_pickup_slot := -1


func _init(floor_plan: Layout = null) -> void:
	layout = floor_plan if floor_plan != null else Layout.new()
	validation_error = layout.error
	if validation_error.is_empty():
		validation_error = Settings.load_values().error
	if validation_error.is_empty():
		reset()


func enable_erp() -> void:
	if erp != null or not validation_error.is_empty():
		return
	validation_error = layout.validate()
	if not validation_error.is_empty():
		return
	erp = ERP.new()
	validation_error = erp.catalog.error
	if not validation_error.is_empty():
		return
	for center in erp.catalog.work_centers.values():
		var id := StringName(center.equipment)
		if not layout.objects.has(id) or not _equipment_implements(id, center.operation):
			validation_error = "work_centers.json [%s].equipment: %s cannot perform %s." % [center.id, id, center.operation]
			return
		if center.operation == "coat" and Layout.SUPPLY_STATIONS.get(center.supply_location) != id:
			validation_error = "work_centers.json [%s].supply_location: expected the station’s physical supply dock." % center.id
			return
		match center.operation:
			"bake":
				ovens[id] = oven if id == &"Oven" else Oven.new(center.technical.batch_kg)
			"coat":
				coaters[id] = coater if id == &"Coater" else Machine.new(center.technical.rate)
				coater_inputs[id] = cooked_input if id == &"Coater" else Storage.new(center.technical.input_kg)
	_create_coated_carts()
	coated_input = pack_wip
	erp.initialize_supply(layout)


func _equipment_implements(id: StringName, operation: String) -> bool:
	var definition: Layout.Placement = layout.objects[id]
	match operation:
		"extrude":
			return id == &"Extruder"
		"pack":
			return id == &"Packer"
		"bake":
			return definition.ports.has(&"raw_dock") and definition.ports.has(&"cooked_dock")
		"coat":
			return definition.ports.has(&"cooked_dock") and definition.ports.has(&"coated_dock")
	return false


func elapsed_seconds() -> float:
	return elapsed_ticks * STEP_SECONDS


func interpolation() -> float:
	return clampf(_pending_seconds / STEP_SECONDS, 0.0, 1.0)


func set_playing(enabled: bool) -> void:
	playing = enabled
	if not playing:
		for machine in coaters.values():
			machine.idle()
		extruder.idle()
		coater.idle()
		packer.idle()


func set_multiplier(value: int) -> void:
	if value in SPEEDS:
		multiplier = value


func set_setting(key: StringName, requested: float) -> bool:
	if not settings.has(key) or not is_finite(requested) or (erp != null and key in [&"box_kg", &"pallet_boxes"]):
		return false
	var spec: Array = Settings.SPECS[key]
	var value := clampf(snappedf(requested, spec[3]), spec[1], spec[2])
	var ref: Array = Settings.TECHNICAL.get(key, [])
	if erp != null and not ref.is_empty() and not order_at(StringName(ref[0])).is_empty():
		return false
	match key:
		&"hopper_capacity":
			if value + EPSILON < hopper.quantity + hopper_reserved or not hopper.resize(value):
				return false
		&"coater_input":
			if not cooked_input.resize(value):
				return false
		&"batch_capacity":
			if not oven.can_load() or not oven.stock.resize(value):
				return false
		&"coater_input_02":
			if erp != null and not coater_inputs[&"Coater02"].resize(value):
				return false
		&"batch_capacity_02":
			if erp != null and not ovens[&"Oven02"].stock.resize(value):
				return false
		&"coater_rate_02":
			if erp != null:
				coaters[&"Coater02"].configured_rate = value
		&"raw_capacity", &"cooked_capacity", &"coated_cart_capacity":
			if not _resize_carts(key == &"raw_capacity", key == &"coated_cart_capacity", value):
				return false
		&"pack_wip_capacity":
			if not pack_wip.resize(value):
				return false
		&"warehouse_capacity":
			if value < warehouse_count() + int(warehouse_reserved_slot >= 0):
				return false
		&"extruder_rate":
			extruder.configured_rate = value
		&"coater_rate":
			coater.configured_rate = value
		&"packing_rate":
			packer.configured_rate = value
	settings[key] = value
	if erp != null and not ref.is_empty():
		for center in erp.catalog.work_centers.values():
			if center.equipment == ref[0]:
				center.technical[ref[1]] = value * (ref[2] if ref.size() == 3 else 1.0)
				break
		erp.changed()
	return true


func _resize_carts(raw: bool, coated: bool, capacity: float) -> bool:
	for cart in carts:
		if cart.raw == raw and cart.coated == coated and cart.stock.quantity > capacity:
			return false
	for cart in carts:
		if cart.raw == raw and cart.coated == coated:
			cart.stock.resize(capacity)
	return true


func warehouse_count() -> int:
	var count := 0
	for pallet in warehouse:
		if pallet != null:
			count += 1
	return count


func warehouse_mass() -> float:
	return _pallet_mass(warehouse)


func pallets_ready() -> int:
	var count := 0
	for pallet in staged_pallets:
		if pallet != null and pallet.full():
			count += 1
	return count


func dispatch(all_stock: bool) -> int:
	var removed := 0
	for index in warehouse.size():
		var pallet := warehouse[index]
		if pallet == null:
			continue
		if erp != null:
			erp.ship(pallet)
		dispatched_kg += pallet.mass
		warehouse[index] = null
		removed += 1
		if not all_stock:
			break
	dispatched_pallets += removed
	return removed


func material_on_site() -> float:
	var mass := hopper.quantity + box_progress + warehouse_mass() + _pallet_mass(staged_pallets)
	if erp == null:
		mass += oven.stock.quantity + cooked_input.quantity + coated_input.quantity
	else:
		mass += pack_wip.quantity
		for run in runs.values():
			mass += run.oven.stock.quantity + run.input.quantity + run.output.quantity
	if lift_load != null:
		mass += lift_load.mass
	for worker in platform_crew:
		mass += worker.cargo_kg
	for cart in carts:
		mass += cart.stock.quantity
	return mass


func _pallet_mass(pallets: Array[Pallet]) -> float:
	var mass := 0.0
	for pallet in pallets:
		if pallet != null:
			mass += pallet.mass
	return mass


func reset() -> void:
	set_playing(false)
	if erp != null:
		var raw_count := carts.filter(func(cart: Cart) -> bool: return cart.raw).size()
		var coated_count := carts.filter(func(cart: Cart) -> bool: return cart.coated).size()
		if runs.is_empty() and (floor_crew.size() != int(settings[&"floor_count"])
				or raw_count != int(settings[&"raw_count"])
				or coated_count != int(settings[&"coated_cart_count"])
				or carts.size() - raw_count - coated_count != int(settings[&"cooked_count"])):
			_configure_crews_and_carts()
		return
	elapsed_ticks = 0
	_pending_seconds = 0.0
	ingredients_taken = 0.0
	dispatched_kg = 0.0
	dispatched_pallets = 0
	boxes_completed = 0
	raw_deliveries = 0
	cooked_deliveries = 0
	forklift_deliveries = 0
	extruder.reset()
	coater.reset()
	packer.reset()
	hopper.quantity = 0.0
	hopper_reserved = 0.0
	cooked_input.quantity = 0.0
	coated_input.quantity = 0.0
	oven = Oven.new(settings[&"batch_capacity"])
	box_progress = 0.0
	box_target = 0.0
	staged_pallets.fill(null)
	staged_pallets.resize(Layout.PALLET_BAYS)
	warehouse.fill(null)
	warehouse.resize(Layout.WAREHOUSE_SLOTS)
	_configure_crews_and_carts()
	forklift = Operator.new(&"Forklift", "Forklift", layout.lift_home())
	lift_load = null
	warehouse_reserved_slot = -1
	_lift_pickup_slot = -1
	_lift_phase = LiftPhase.WAIT


func _configure_crews_and_carts() -> void:
	raw_at_extruder = null
	raw_at_oven = null
	cooked_at_oven = null
	cooked_at_coater = null
	pack_dock = null
	floor_assignments.clear()
	pending_jobs.clear()
	_cart_route_owner = &""
	platform_crew.clear()
	floor_crew.clear()
	carts.clear()
	for index in 2:
		platform_crew.append(Operator.new(StringName("Platform%d" % (index + 1)),
			"Platform worker %d" % (index + 1), layout.platform_pick(index)))
	for index in int(settings[&"floor_count"]):
		floor_crew.append(Operator.new(StringName("Worker%d" % (index + 1)),
			"Floor worker %d" % (index + 1), layout.crew_home(index)))
	_create_carts(true, int(settings[&"raw_count"]), settings[&"raw_capacity"])
	_create_carts(false, int(settings[&"cooked_count"]), settings[&"cooked_capacity"])
	if erp != null:
		_create_coated_carts()
	raw_at_extruder = carts[0]
	raw_at_extruder.site = Cart.Site.EXTRUDER
	raw_at_extruder.position = layout.port(&"Extruder", &"raw_dock")
	raw_at_extruder.previous_position = layout.port(&"Extruder", &"raw_dock")


func _create_carts(raw: bool, count: int, capacity: float) -> void:
	var prefix := "Raw" if raw else "Cooked"
	for index in count:
		carts.append(Cart.new(StringName("%s%d" % [prefix, index + 1]), raw,
			capacity, layout.cart_home(index, raw)))


func _create_coated_carts() -> void:
	for index in int(settings[&"coated_cart_count"]):
		carts.append(Cart.new(StringName("Coated%d" % (index + 1)), false,
			settings[&"coated_cart_capacity"], layout.coated_cart_home(index), true))


func advance(real_seconds: float) -> void:
	if not validation_error.is_empty() or not playing or not is_finite(real_seconds) or real_seconds <= 0.0:
		return
	_pending_seconds += real_seconds * multiplier
	while _pending_seconds + EPSILON >= STEP_SECONDS:
		_pending_seconds -= STEP_SECONDS
		_step()


func _step() -> void:
	if erp != null:
		_step_routed()
		return
	_pack()
	_transfer(coater, cooked_input, coated_input)
	var output: Storage
	if raw_at_extruder != null and raw_at_extruder.site == Cart.Site.EXTRUDER:
		output = raw_at_extruder.stock
	_transfer(extruder, hopper, output)
	oven.advance(STEP_SECONDS, settings[&"cook_minutes"] * 60.0)
	_advance_platform()
	for cart in carts:
		cart.previous_position = cart.position
	_advance_floor()
	_advance_forklift()
	elapsed_ticks += 1


func _step_routed() -> void:
	erp.clock(elapsed_seconds() + STEP_SECONDS)
	_retire_routes()
	if not erp.feeder_id.is_empty():
		var feed: Dictionary = runs[erp.feeder_id]
		var order: Dictionary = erp.orders[erp.feeder_id]
		if order.dough_issued + EPSILON >= order.recipe.dough_target and hopper.quantity + hopper_reserved <= EPSILON \
				and (raw_at_extruder == null or raw_at_extruder.stock.quantity <= EPSILON):
			feed.fed = true
			erp.feeder_id = ""
	if erp.feeder_id.is_empty() and elapsed_ticks % 4 == 3:
		_dispatch_route()
	if erp.pack_id.is_empty():
		for id in runs:
			var order: Dictionary = erp.orders[id]
			if order.status == "In Progress" and order.packed < order.boxes:
				erp.pack_id = id
				var technical: Dictionary = order.route.operations[3].technical
				packer.configured_rate = technical.rate
				if not pack_last_recipe.is_empty() and (pack_last_recipe.packaging != order.recipe.packaging \
						or pack_last_recipe.spec.box_kg != order.recipe.spec.box_kg \
						or pack_last_recipe.spec.boxes_per_pallet != order.recipe.spec.boxes_per_pallet):
					erp.pack_remaining = technical.setup_seconds
				break
	erp.active_id = ""
	for id in runs:
		if erp.orders[id].status == "In Progress":
			erp.active_id = id
			break
	erp.supply_tick(layout, STEP_SECONDS, minf(settings[&"sack_kg"], hopper.capacity), runs.keys())
	if erp.pack_id.is_empty():
		packer.idle()
	else:
		_open_run(erp.pack_id)
		coated_input = pack_wip
		if erp.pack_remaining > EPSILON:
			packer.record(0.0, STEP_HOURS, Machine.State.SETUP)
			erp.pack_remaining = maxf(0.0, erp.pack_remaining - STEP_SECONDS)
		else:
			_pack()
			var packed := erp.active()
			if packed.packed == packed.boxes:
				pack_last_recipe = packed.recipe
				erp.pack_id = ""
		_close_run()
	extruder.idle()
	for id in runs:
		if erp.orders[id].status != "In Progress":
			continue
		_open_run(id)
		var recipe: Dictionary = erp.active().recipe
		if _run.setup > EPSILON:
			coater.record(0.0, STEP_HOURS, Machine.State.SETUP)
			_run.setup = maxf(0.0, _run.setup - STEP_SECONDS)
		else:
			_coat_erp()
		if id == erp.feeder_id:
			_step_extrusion()
			_advance_platform()
		_step_oven(recipe)
		_close_run()
	if erp.feeder_id.is_empty():
		# Empty scope means the primary order, so use a non-order scope while returning workers home.
		erp.scope_id = "-"
		_advance_platform()
		erp.scope_id = ""
	for cart in carts:
		cart.previous_position = cart.position
	_advance_floor()
	_advance_forklift()
	elapsed_ticks += 1
	erp.coat_remaining = 0.0
	for run in runs.values():
		erp.coat_remaining = maxf(erp.coat_remaining, run.setup)
	erp.sample_kpis(self, STEP_SECONDS)


func _dispatch_route() -> void:
	var chosen := {}
	for order in erp.orders.values():
		if order.status != "Released" or order.start > erp.now or not route_conflicts(order).is_empty():
			continue
		if chosen.is_empty() or order.priority < chosen.priority \
				or (order.priority == chosen.priority and order.start < chosen.start):
			chosen = order
	if chosen.is_empty():
		return
	_begin_route(chosen)
	chosen.status = "In Progress"
	chosen.started = erp.now
	erp.feeder_id = chosen.id
	erp.changed()


func _begin_route(order: Dictionary, restoring: bool = false) -> void:
	var ops: Array = order.route.operations
	var bake: StringName = StringName(ops[1].equipment)
	var coat: StringName = StringName(ops[2].equipment)
	var oven_machine: Oven = ovens[bake]
	var coating: Machine = coaters[coat]
	var input: Storage = coater_inputs[coat]
	var output := Storage.new(COATER_OUTFEED_KG)
	var prior: String = last_coatings.get(coat, "")
	var setup := float(ops[2].technical.setup_seconds) if not prior.is_empty() and prior != order.recipe.coating else 0.0
	if not restoring:
		oven_machine.stock.resize(ops[1].technical.batch_kg)
		input.resize(ops[2].technical.input_kg)
		coating.configured_rate = ops[2].technical.rate
		extruder.configured_rate = ops[0].technical.rate
		last_coatings[coat] = order.recipe.coating
	runs[order.id] = {"id": order.id, "bake": bake, "coat": coat, "oven": oven_machine, "coater": coating,
		"input": input, "output": output, "raw": null, "cooked": null, "intake": null,
		"outbound": null, "pack": null, "cycle": ops[1].technical.cycle_seconds, "setup": setup, "fed": false}


func route_conflicts(order: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for op in order.route.operations:
		if op.type not in ["bake", "coat"]:
			continue
		var equipment := StringName(op.equipment)
		var owner := order_at(equipment)
		if not owner.is_empty() and owner.id != order.id:
			result.append("%s · %s" % [op.description, owner.id])
	return result


func order_at(equipment: StringName) -> Dictionary:
	if erp == null:
		return {}
	if equipment == &"Extruder":
		return erp.orders.get(erp.feeder_id, {})
	if equipment == &"Packer":
		return erp.orders.get(erp.pack_id, {})
	for run in runs.values():
		if equipment == run.bake or equipment == run.coat:
			return erp.orders[run.id]
	return {}


func work_center_status(equipment: StringName) -> String:
	if ovens.has(equipment):
		return ovens[equipment].state_title()
	var machine: Machine = coaters.get(equipment, extruder if equipment == &"Extruder" else packer)
	return Machine.State.keys()[machine.state].capitalize()


func _retire_routes() -> void:
	for id in runs.keys():
		var run: Dictionary = runs[id]
		if erp.orders[id].status in ["Completed", "Closed"] and run.raw == null and run.cooked == null and run.intake == null \
			and run.outbound == null and run.pack == null \
			and not floor_assignments.values().any(func(job: FloorJob) -> bool: return job.run == id):
			run.coater.idle()
			runs.erase(id)


func _open_run(id: String) -> void:
	# Bind the existing station and berth routines to one order for this operation.
	_run = runs[id]
	erp.scope_id = id
	oven = _run.oven
	coater = _run.coater
	cooked_input = _run.input
	coated_input = _run.output
	raw_at_oven = _run.raw
	cooked_at_oven = _run.cooked
	cooked_at_coater = _run.intake


func _close_run() -> void:
	_run.raw = raw_at_oven
	_run.cooked = cooked_at_oven
	_run.intake = cooked_at_coater
	_run = {}
	erp.scope_id = ""
	oven = ovens[&"Oven"]
	coater = coaters[&"Coater"]
	cooked_input = coater_inputs[&"Coater"]
	coated_input = pack_wip
	var original_oven := order_at(&"Oven")
	var original_coater := order_at(&"Coater")
	raw_at_oven = null if original_oven.is_empty() else runs[original_oven.id].raw
	cooked_at_oven = null if original_oven.is_empty() else runs[original_oven.id].cooked
	cooked_at_coater = null if original_coater.is_empty() else runs[original_coater.id].intake


func _step_extrusion() -> void:
	var output: Storage
	if raw_at_extruder != null and raw_at_extruder.site == Cart.Site.EXTRUDER:
		output = raw_at_extruder.stock
	_transfer(extruder, hopper, output)
	if extruder.actual_rate > EPSILON:
		_add_progress("extrude", extruder.actual_rate * STEP_HOURS)
		raw_at_extruder.order_id = erp.feeder_id
		var recipe: Dictionary = erp.active().recipe
		var kg := extruder.actual_rate * STEP_HOURS
		_erp_transform(recipe.dough, kg, recipe.raw, kg, "Extrusion")


func _step_oven(recipe: Dictionary) -> void:
	var previous := oven.state
	if oven.can_load() and oven.owner == &"" and oven.stock.quantity > EPSILON and _raw_finished():
		oven.start(_run.cycle + STEP_SECONDS)
	oven.advance(STEP_SECONDS, _run.cycle)
	if previous == Oven.State.COOKING and oven.state == Oven.State.READY:
		_add_progress("bake", oven.stock.quantity)
		_erp_transform(recipe.raw, oven.stock.quantity, recipe.baked, oven.stock.quantity, "Oven batch")


func _erp_transform(input: String, amount: float, output: String, produced: float, reason: String) -> void:
	erp.flow(input, amount, "WIP", "", "Consumption", reason)
	erp.flow(output, produced, "", "WIP", "SFG Receipt", reason)


func _coat_erp() -> void:
	var order := erp.active()
	if order.is_empty():
		coater.idle()
		return
	var target := coater.configured_rate * STEP_HOURS
	var room := coated_input.free_space()
	var baked_rate: float = order.recipe.baked_rate
	var limit := minf(erp.coating_limit(), cooked_input.quantity / baked_rate)
	var kg := minf(target, minf(room, limit))
	if kg > EPSILON:
		_add_progress("coat", kg)
		erp.coat(kg)
		cooked_input.remove(kg * baked_rate)
		coated_input.apply_transfer(kg, 0.0)
		_erp_transform(order.recipe.baked, kg * baked_rate, order.recipe.coated, kg, "Chocolate coating")
	coater.record(kg, STEP_HOURS, _machine_state(target, kg, room <= limit))


func _raw_finished() -> bool:
	if not _run.fed and (erp.scope_id != erp.feeder_id or not erp.dough_finished() or hopper.quantity + hopper_reserved > EPSILON):
		return false
	for cart in carts:
		if cart.raw and cart.order_id == erp.scope_id and cart.stock.quantity > EPSILON:
			return false
	return true


func _transfer(machine: Machine, input: Storage, output: Storage) -> void:
	var target := machine.configured_rate * STEP_HOURS
	var room := output.free_space() if output != null else 0.0
	var amount := minf(target, minf(input.quantity, room))
	var state := _machine_state(target, amount, room <= input.quantity)
	if amount > 0.0:
		input.remove(amount)
		output.apply_transfer(amount, 0.0)
	machine.record(amount, STEP_HOURS, state)


func _machine_state(target: float, actual: float, output_limited: bool) -> Machine.State:
	if target == 0.0:
		return Machine.State.IDLE
	if actual + EPSILON >= target:
		return Machine.State.RUNNING
	return Machine.State.BLOCKED if output_limited else Machine.State.STARVED


func _pack() -> void:
	if erp != null and erp.active_id.is_empty():
		packer.idle()
		return
	var supply_short := false
	var target := packer.configured_rate * STEP_HOURS
	var available := minf(target, coated_input.quantity)
	var packed := 0.0
	while available > EPSILON:
		var index := _packing_bay()
		if index < 0:
			break
		if erp != null and not erp.can_pack(staged_pallets[index] == null):
			supply_short = true
			break
		if box_progress == 0.0:
			box_target = settings[&"box_kg"] if erp == null else erp.active().recipe.spec.box_kg
		var amount := minf(available, box_target - box_progress)
		box_progress += amount
		packed += amount
		available -= amount
		if box_progress + EPSILON >= box_target:
			var new_pallet := staged_pallets[index] == null
			if new_pallet:
				staged_pallets[index] = _new_pallet()
			var pallet := staged_pallets[index]
			pallet.add_box(box_progress)
			if erp != null:
				var recipe: Dictionary = erp.active().recipe
				_add_progress("pack", box_progress)
				erp.flow(recipe.coated, box_progress, "PACK-WIP", "", "Consumption", "Carton packed")
				erp.flow(pallet.sku, box_progress, "", "WIP", "Packed Receipt", "Carton packed")
				if erp.pack_box(new_pallet):
					pallet.sealed = true
			boxes_completed += 1
			box_progress = 0.0
	coated_input.remove(packed)
	packer.record(packed, STEP_HOURS, _machine_state(target, packed, not supply_short and _packing_bay() < 0))


func _new_pallet() -> Pallet:
	if erp == null:
		return Pallet.new(int(settings[&"pallet_boxes"]))
	var order := erp.active()
	var pallet := Pallet.new(int(order.recipe.spec.boxes_per_pallet))
	pallet.id = "%s-P%04d" % [order.id, floori(float(order.packed) / pallet.target_boxes) + 1]
	pallet.sku = order.code
	pallet.order_id = order.id
	pallet.tint = order.recipe.spec.package_color
	return pallet


func _packing_bay() -> int:
	for index in staged_pallets.size():
		var pallet := staged_pallets[index]
		if pallet != null and not pallet.full() and (erp == null or pallet.order_id == erp.pack_id):
			return index
	return staged_pallets.find(null)


func _advance_platform() -> void:
	for index in platform_crew.size():
		var worker := platform_crew[index]
		worker.advance(STEP_SECONDS, settings[&"platform_speed"])
		if not worker.finished():
			continue
		match worker.state:
			Operator.State.IDLE:
				var sack := settings[&"sack_kg"]
				if erp != null:
					sack = minf(sack, hopper.capacity)
					var awaiting := 0.0
					for other in platform_crew:
						if other.state == Operator.State.LOADING:
							awaiting += other.reserved_kg
					var limit := erp.feed_limit(awaiting)
					if limit + EPSILON < sack and not is_equal_approx(limit, _remaining_dough(awaiting)):
						continue
					sack = minf(sack, limit)
				if sack > EPSILON and hopper.free_space() - hopper_reserved + EPSILON >= sack:
					hopper_reserved += sack
					worker.reserved_kg = sack
					worker.task = "Pick up ingredient sack"
					worker.destination = "Sack staging"
					worker.work(settings[&"pickup_time"], Operator.State.LOADING)
			Operator.State.LOADING:
				if erp != null and not erp.issue_dough(worker.reserved_kg):
					hopper_reserved -= worker.reserved_kg
					worker.reserved_kg = 0.0
					worker.idle()
					continue
				worker.cargo_kg = worker.reserved_kg
				ingredients_taken += worker.cargo_kg
				worker.travel([layout.platform_drop(index)], Operator.State.CARRYING,
					"Carry sack to hopper", "Ingredient hopper")
			Operator.State.CARRYING:
				worker.task = "Discharge ingredient sack"
				worker.work(settings[&"unload_time"], Operator.State.UNLOADING)
			Operator.State.UNLOADING:
				hopper.apply_transfer(worker.cargo_kg, 0.0)
				hopper_reserved = maxf(0.0, hopper_reserved - worker.reserved_kg)
				worker.reserved_kg = 0.0
				worker.cargo_kg = 0.0
				worker.travel([layout.platform_pick(index)], Operator.State.WALKING,
					"Return to staging", "Sack staging")
			Operator.State.WALKING:
				worker.idle()


func _remaining_dough(awaiting: float) -> float:
	var order := erp.active()
	return float(order.recipe.dough_target) - float(order.dough_issued) - awaiting if not order.is_empty() else 0.0


func _advance_floor() -> void:
	for worker in floor_crew:
		worker.advance(STEP_SECONDS, settings[&"floor_speed"])
		if not floor_assignments.has(worker.id):
			continue
		var job := floor_assignments[worker.id]
		if worker.state == Operator.State.PUSHING:
			job.cart.position = worker.position
			job.cart.heading = worker.heading
		if worker.finished():
			if erp != null:
				_open_run(job.run)
			_continue_job(worker, job)
			if erp != null:
				_close_run()
	_assign_floor_jobs()
	pending_jobs = _eligible_jobs()


func _assign_floor_jobs() -> void:
	var idle: Array[Operator] = []
	for worker in floor_crew:
		if worker.state == Operator.State.IDLE:
			idle.append(worker)
	while not idle.is_empty():
		var next: FloorJob
		for job in _eligible_jobs():
			if job.kind != JobKind.MOVE_CART or _cart_route_owner == &"":
				next = job
				break
		if next == null:
			return
		var closest := idle[0]
		for worker in idle:
			if worker.position.distance_squared_to(next.cart.position) \
					< closest.position.distance_squared_to(next.cart.position):
				closest = worker
		if erp != null:
			_open_run(next.run)
		_claim_job(closest, next)
		if erp != null:
			_close_run()
		idle.erase(closest)


func _eligible_jobs() -> Array[FloorJob]:
	if erp == null:
		return _floor_jobs()
	var result: Array[FloorJob] = []
	for id in runs:
		_open_run(id)
		for job in _floor_jobs():
			job.run = id
			result.append(job)
		_close_run()
	return result


func _floor_jobs() -> Array[FloorJob]:
	var jobs: Array[FloorJob] = []
	if erp != null:
		_coated_cart_jobs(jobs)
	if oven.owner == &"":
		if oven.state == Oven.State.READY and _available(cooked_at_oven, Cart.Site.OVEN_COOKED) \
				and cooked_at_oven.stock.free_space() > EPSILON:
			jobs.append(_handling(JobKind.UNLOAD_OVEN, cooked_at_oven, "Unload cooked wafers"))
		if oven.can_load() and oven.stock.free_space() > EPSILON \
				and _available(raw_at_oven, Cart.Site.OVEN_RAW) and raw_at_oven.stock.quantity > EPSILON:
			jobs.append(_handling(JobKind.LOAD_OVEN, raw_at_oven, "Load raw wafers"))
	if _available(cooked_at_coater, Cart.Site.COATER):
		if cooked_at_coater.stock.quantity <= EPSILON:
			jobs.append(_move(cooked_at_coater, Cart.Site.PARKING,
				cooked_at_coater.home, "Return cooked cart"))
		elif cooked_input.free_space() > EPSILON:
			jobs.append(_handling(JobKind.FEED_COATER, cooked_at_coater, "Unload coating intake"))
	if cooked_at_coater == null and _available(cooked_at_oven, Cart.Site.OVEN_COOKED) \
			and cooked_at_oven.stock.quantity > EPSILON:
		jobs.append(_move(cooked_at_oven, Cart.Site.COATER, layout.port(_run.get("coat", &"Coater"), &"cooked_dock"), "Deliver cooked wafers"))
	if (erp == null or erp.scope_id == erp.feeder_id) and raw_at_oven == null and _available(raw_at_extruder, Cart.Site.EXTRUDER) \
			and (raw_at_extruder.stock.free_space() <= EPSILON or _last_raw_cart_ready()):
		jobs.append(_move(raw_at_extruder, Cart.Site.OVEN_RAW, layout.port(_run.get("bake", &"Oven"), &"raw_dock"), "Deliver raw wafers"))
	if _available(raw_at_oven, Cart.Site.OVEN_RAW) and raw_at_oven.stock.quantity <= EPSILON:
		if raw_at_extruder == null:
			jobs.append(_move(raw_at_oven, Cart.Site.EXTRUDER, layout.port(&"Extruder", &"raw_dock"), "Return raw cart"))
		else:
			jobs.append(_move(raw_at_oven, Cart.Site.PARKING, raw_at_oven.home, "Park empty raw cart"))
	if cooked_at_oven == null and oven.state in [Oven.State.COOKING, Oven.State.READY]:
		var cart := _parked_cart(false)
		if cart != null and (erp == null or _can_stage_cooked()):
			jobs.append(_move(cart, Cart.Site.OVEN_COOKED, layout.port(_run.get("bake", &"Oven"), &"cooked_dock"), "Stage cooked cart"))
	if raw_at_extruder == null and (erp == null or erp.scope_id == erp.feeder_id):
		var cart := _parked_cart(true)
		if cart != null:
			jobs.append(_move(cart, Cart.Site.EXTRUDER, layout.port(&"Extruder", &"raw_dock"), "Stage raw cart"))
	return jobs


func _coated_cart_jobs(jobs: Array[FloorJob]) -> void:
	var dock: Cart = _run.pack
	if _available(dock, Cart.Site.PACK_WIP):
		if dock.stock.quantity <= EPSILON:
			jobs.append(_move(dock, Cart.Site.PARKING, dock.home, "Return coated wafer cart"))
		elif erp.scope_id == erp.pack_id and pack_wip.free_space() > EPSILON:
			jobs.append(_handling(JobKind.UNLOAD_PACK_WIP, dock, "Unload coated wafers into packaging WIP"))
	if erp.scope_id != erp.pack_id:
		return
	var cart: Cart = _run.outbound
	if cart == null:
		if _run.output.quantity > EPSILON:
			for parked in carts:
				if parked.coated and _available(parked, Cart.Site.PARKING):
					jobs.append(_move(parked, Cart.Site.COATER_OUT, layout.port(_run.coat, &"coated_dock"), "Stage coated wafer cart"))
					break
		return
	if not _available(cart, Cart.Site.COATER_OUT):
		return
	var order := erp.active()
	var recipe: Dictionary = order.recipe
	var coating_done := float(order.consumed.get(recipe.coating, 0.0)) + EPSILON >= float(recipe.needs[recipe.coating])
	var waiting: float = _run.output.quantity
	if cart.stock.quantity > EPSILON and (cart.stock.free_space() <= EPSILON or (coating_done and waiting <= EPSILON)):
		if pack_dock == null:
			jobs.append(_move(cart, Cart.Site.PACK_WIP, layout.port(&"PackagingWIP", &"coated_dock"), "Deliver coated wafers"))
	elif waiting > EPSILON and (coating_done or waiting + EPSILON >= minf(cart.stock.free_space(), _run.output.capacity)):
		jobs.append(_handling(JobKind.LOAD_COATED, cart, "Load coated wafers"))


func _can_stage_cooked() -> bool:
	# Leave a cart for the oldest unfinished order so shared packing cannot deadlock.
	for id in runs:
		if id == erp.scope_id:
			return true
		var order: Dictionary = erp.orders[id]
		if order.packed < order.boxes:
			return carts.filter(func(cart: Cart) -> bool: return not cart.raw and not cart.coated and _available(cart, Cart.Site.PARKING)).size() > 1
	return false


func _last_raw_cart_ready() -> bool:
	return erp != null and erp.dough_finished() and hopper.quantity + hopper_reserved <= EPSILON \
			and raw_at_extruder.stock.quantity > EPSILON


func _available(cart: Cart, site: Cart.Site) -> bool:
	return cart != null and cart.owner == &"" and cart.site == site


func _parked_cart(raw: bool) -> Cart:
	for cart in carts:
		if not cart.coated and cart.raw == raw and _available(cart, Cart.Site.PARKING):
			return cart
	return null


func _move(cart: Cart, site: Cart.Site, point: Vector3, title: String) -> FloorJob:
	return FloorJob.new(JobKind.MOVE_CART, cart, site, point, title)


func _handling(kind: JobKind, cart: Cart, title: String) -> FloorJob:
	return FloorJob.new(kind, cart, cart.site, cart.position, title)


func _claim_job(worker: Operator, job: FloorJob) -> void:
	floor_assignments[worker.id] = job
	job.cart.owner = worker.id
	if job.kind == JobKind.MOVE_CART:
		_cart_route_owner = worker.id
		_set_berth(job.site, job.cart)
	elif job.kind in [JobKind.LOAD_OVEN, JobKind.UNLOAD_OVEN]:
		oven.owner = worker.id
	worker.travel(layout.route(worker.position, job.cart.position, Layout.WALK_LANE),
		Operator.State.WALKING, job.title, _job_destination(job.cart.site))


func _continue_job(worker: Operator, job: FloorJob) -> void:
	var cart := job.cart
	if worker.state == Operator.State.WALKING:
		if job.kind == JobKind.MOVE_CART:
			_set_berth(cart.site, null)
			cart.site = Cart.Site.TRANSIT
			worker.travel(layout.route(worker.position, job.point, Layout.CART_LANE),
				Operator.State.PUSHING, job.title, _job_destination(job.site))
		else:
			if job.kind == JobKind.LOAD_OVEN:
				oven.state = Oven.State.LOADING
				worker.work(CART_HANDLING_SECONDS, Operator.State.LOADING)
			elif job.kind == JobKind.LOAD_COATED:
				worker.work(CART_HANDLING_SECONDS, Operator.State.LOADING)
			else:
				if job.kind == JobKind.UNLOAD_OVEN:
					oven.state = Oven.State.UNLOADING
				worker.work(CART_HANDLING_SECONDS, Operator.State.UNLOADING)
		return
	match job.kind:
		JobKind.MOVE_CART:
			cart.site = job.site
			_cart_route_owner = &""
			if job.site == Cart.Site.OVEN_RAW:
				raw_deliveries += 1
			elif job.site == Cart.Site.COATER:
				cooked_deliveries += 1
		JobKind.LOAD_OVEN:
			_move_mass(cart.stock, oven.stock)
			oven.owner = &""
			oven.advance(0.0, _run.get("cycle", settings[&"cook_minutes"] * 60.0))
		JobKind.UNLOAD_OVEN:
			_move_mass(oven.stock, cart.stock)
			cart.order_id = job.run
			oven.state = Oven.State.READY if oven.stock.quantity > EPSILON else Oven.State.IDLE
			oven.owner = &""
		JobKind.FEED_COATER:
			_move_mass(cart.stock, cooked_input)
		JobKind.LOAD_COATED:
			_move_mass(_run.output, cart.stock)
			cart.order_id = job.run
		JobKind.UNLOAD_PACK_WIP:
			var amount := cart.stock.remove(pack_wip.free_space())
			pack_wip.apply_transfer(amount, 0.0)
			erp.flow(erp.active().recipe.coated, amount, "WIP", "PACK-WIP", "Transfer", "Coated cart unloaded")
	if cart.stock.quantity <= EPSILON:
		cart.order_id = ""
	cart.owner = &""
	floor_assignments.erase(worker.id)
	worker.idle()


func _job_destination(site: Cart.Site) -> String:
	if not _run.is_empty():
		var ops: Array = erp.active().route.operations
		match site:
			Cart.Site.OVEN_RAW:
				return ops[1].description + " loading"
			Cart.Site.OVEN_COOKED:
				return ops[1].description + " unloading"
			Cart.Site.COATER:
				return ops[2].description + " intake"
			Cart.Site.COATER_OUT:
				return ops[2].description + " outfeed"
	return Cart.SITE_NAMES[site]


func _move_mass(source: Storage, target: Storage) -> void:
	target.apply_transfer(source.remove(target.free_space()), 0.0)


func _set_berth(site: Cart.Site, cart: Cart) -> void:
	match site:
		Cart.Site.EXTRUDER:
			raw_at_extruder = cart
		Cart.Site.OVEN_RAW:
			raw_at_oven = cart
		Cart.Site.OVEN_COOKED:
			cooked_at_oven = cart
		Cart.Site.COATER:
			cooked_at_coater = cart
		Cart.Site.COATER_OUT:
			_run.outbound = cart
		Cart.Site.PACK_WIP:
			_run.pack = cart
			pack_dock = cart


func _advance_forklift() -> void:
	forklift.advance(STEP_SECONDS, settings[&"lift_speed"])
	if not forklift.finished():
		return
	match _lift_phase:
		LiftPhase.WAIT:
			_request_forklift_job()
		LiftPhase.TO_PALLET:
			_lift_phase = LiftPhase.PICK_UP
			forklift.work(LIFT_HANDLING_SECONDS, Operator.State.LOADING)
		LiftPhase.PICK_UP:
			lift_load = staged_pallets[_lift_pickup_slot]
			staged_pallets[_lift_pickup_slot] = null
			_lift_pickup_slot = -1
			_lift_phase = LiftPhase.TO_STORAGE
			forklift.travel(layout.lift_to_slot(forklift.position, warehouse_reserved_slot),
				Operator.State.DRIVING, "Deliver finished pallet", "Warehouse slot %02d" % (warehouse_reserved_slot + 1))
		LiftPhase.TO_STORAGE:
			_lift_phase = LiftPhase.DROP_OFF
			forklift.work(LIFT_HANDLING_SECONDS, Operator.State.UNLOADING)
		LiftPhase.DROP_OFF:
			var return_path := layout.lift_from_slot(warehouse_reserved_slot)
			warehouse[warehouse_reserved_slot] = lift_load
			if erp != null:
				erp.receive_pallet(lift_load)
			lift_load = null
			warehouse_reserved_slot = -1
			forklift_deliveries += 1
			_lift_phase = LiftPhase.RETURN
			forklift.travel(return_path, Operator.State.DRIVING,
				"Return to dispatch lane", "Forklift parking")
		LiftPhase.RETURN:
			forklift.idle()
			_lift_phase = LiftPhase.WAIT


func _request_forklift_job() -> void:
	for index in staged_pallets.size():
		var pallet := staged_pallets[index]
		if pallet == null or not pallet.full():
			continue
		if warehouse_count() >= int(settings[&"warehouse_capacity"]):
			forklift.task = "Waiting for warehouse space"
			forklift.destination = "Forklift parking"
			return
		warehouse_reserved_slot = warehouse.find(null)
		_lift_pickup_slot = index
		_lift_phase = LiftPhase.TO_PALLET
		forklift.travel(layout.route(forklift.position, layout.pallet_approach(index), Layout.LIFT_LANE),
			Operator.State.DRIVING, "Collect full pallet", "Palletizing bay %02d" % (index + 1))
		return
	forklift.idle()


func find_operator(id: StringName) -> Operator:
	if erp != null and id == &"SupplyShuttle":
		return erp.shuttle
	if id == forklift.id:
		return forklift
	for crew in [platform_crew, floor_crew]:
		for worker: Operator in crew:
			if worker.id == id:
				return worker
	return null


func find_cart(id: StringName) -> Cart:
	for cart in carts:
		if cart.id == id:
			return cart
	return null


func _add_progress(operation: String, kg: float) -> void:
	var order := erp.active()
	if not order.has("progress"):
		order.progress = {}
	order.progress[operation] = float(order.progress.get(operation, 0.0)) + kg


func order_wip(id: String) -> Dictionary:
	var totals := {}
	var run: Dictionary = runs.get(id, {})
	if run.is_empty():
		return totals
	var order: Dictionary = erp.orders[id]
	var recipe: Dictionary = order.recipe
	if id == erp.feeder_id:
		totals[recipe.dough] = hopper.quantity
		for worker in platform_crew:
			totals[recipe.dough] += worker.cargo_kg
	totals[recipe.raw] = 0.0
	totals[recipe.baked] = run.input.quantity
	totals[recipe.coated] = run.output.quantity + (box_progress + pack_wip.quantity if id == erp.pack_id else 0.0)
	for cart in carts:
		if cart.order_id == id:
			var code: String = recipe.coated if cart.coated else (recipe.raw if cart.raw else recipe.baked)
			totals[code] += cart.stock.quantity
	var baked: bool = run.oven.state in [Oven.State.READY, Oven.State.UNLOADING]
	totals[recipe.baked if baked else recipe.raw] += run.oven.stock.quantity
	totals[order.code] = lift_load.mass if lift_load != null and lift_load.order_id == id else 0.0
	for pallet in staged_pallets:
		if pallet != null and pallet.order_id == id:
			totals[order.code] += pallet.mass
	for code in totals.keys():
		if totals[code] <= EPSILON:
			totals.erase(code)
	return totals


func erp_wip() -> Dictionary:
	var totals := {}
	for id in runs:
		var stock := order_wip(id)
		for code in stock:
			totals[code] = float(totals.get(code, 0.0)) + stock[code]
	return totals


func erp_pack_wip() -> Dictionary:
	if erp == null or erp.pack_id.is_empty() or pack_wip.quantity <= EPSILON:
		return {}
	return {erp.orders[erp.pack_id].recipe.coated: pack_wip.quantity}


func erp_fg() -> Dictionary:
	var totals := {}
	for pallet in warehouse:
		if pallet != null and not pallet.sku.is_empty():
			totals[pallet.sku] = float(totals.get(pallet.sku, 0.0)) + pallet.mass
	return totals
