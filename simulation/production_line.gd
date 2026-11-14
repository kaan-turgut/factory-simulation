extends RefCounted
## Authoritative chocolate-wafer line. Only fixed simulation ticks move people or material.

const Cell = preload("res://simulation/production_cell.gd")
const ERP = preload("res://erp/operations.gd")
const Machine = preload("res://simulation/machine.gd")
const Storage = preload("res://simulation/storage.gd")
const Layout = preload("res://layout/factory_layout.gd")
const Settings = preload("res://simulation/factory_settings.gd")
const Operator = preload("res://simulation/operator.gd")
const Cart = preload("res://simulation/wafer_cart.gd")
const Oven = preload("res://simulation/batch_oven.gd")
const Pallet = preload("res://simulation/pallet.gd")

const SPEEDS := [1, 5, 20, 60]
const STEP_SECONDS := 0.25
const STEP_HOURS := STEP_SECONDS / 3600.0
const EPSILON := Storage.MASS_EPSILON
const STEP_EPSILON := 1e-8
const CART_HANDLING_SECONDS := 3.0
const COATER_OUTFEED_KG := 36.0
const LIFT_HANDLING_SECONDS := 2.0
## Extra mast time per rack level above the floor when the forklift stores or retrieves a pallet.
const LIFT_LEVEL_SECONDS := 1.5

enum JobKind { MOVE_CART, LOAD_OVEN, UNLOAD_OVEN, FEED_COATER, LOAD_COATED, UNLOAD_PACK_WIP, SFG_LOAD, SFG_UNLOAD, CELL_INPUT, CELL_OUTPUT, CELL_BATCH, CELL_PALLET }
enum LiftPhase { WAIT, TO_PALLET, PICK_UP, TO_STORAGE, DROP_OFF, RETURN }

class FloorJob:
	var kind: JobKind
	var cart: Cart
	var site: Cart.Site
	var point: Vector3
	var title: String
	var run := ""
	var material := ""

	func _init(
		action: JobKind, tray: Cart, destination: Cart.Site, at: Vector3, description: String
	) -> void:
		kind = action
		cart = tray
		site = destination
		point = at
		title = description


var layout: Layout
var layout_file_stamp := 0.0
var erp: ERP
var validation_error := ""
var ovens: Dictionary[StringName, Oven] = {}
var coaters: Dictionary[StringName, Machine] = {}
var coater_inputs: Dictionary[StringName, Storage] = {}
var runs := {}
var last_coatings := {}
var resource_last := {}
var operating_factors := {}
var scrapped_kg := 0.0
var cell_machines := {}
var pallet_dock: Cart
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
var sfg_dock: Cart
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


func enable_erp(explicit: bool = true) -> void:
	if erp != null or not validation_error.is_empty():
		return
	validation_error = layout.validate()
	if not validation_error.is_empty():
		return
	erp = ERP.new()
	erp.explicit_planning = explicit
	validation_error = erp.catalog.error
	if not validation_error.is_empty():
		return
	for center in erp.catalog.work_centers.values():
		var id := StringName(center.equipment)
		if not layout.objects.has(id) or not _equipment_implements(id, center.operation):
			validation_error = "work_centers.json [%s].equipment: %s cannot perform %s." % [center.id, id, center.operation]
			return
		if center.has("input_port") and (center.input_port != "input_dock" or center.output_port != "output_dock"):
			validation_error = "work_centers.json [%s]: cell ports must reference its validated input and output docks." % center.id
			return
		if center.get("supply_location", "") != "" and not Layout.supplies(center.supply_location, id):
			validation_error = "work_centers.json [%s].supply_location: expected the station’s physical supply dock." % center.id
			return
		match center.operation:
			"bake":
				ovens[id] = oven if id == &"Oven" else Oven.new(center.technical.batch_kg)
			"coat":
				coaters[id] = coater if id == &"Coater" else Machine.new(center.technical.rate)
				coater_inputs[id] = cooked_input if id == &"Coater" else Storage.new(center.technical.input_kg)
		if id not in [&"Hopper", &"Extruder", &"Oven", &"Oven02", &"Coater", &"Coater02", &"Packer"]:
			cell_machines[id] = Machine.new(0)
		operating_factors[id] = 1.0
	_create_coated_carts()
	if elapsed_ticks == 0 and raw_at_extruder != null and raw_at_extruder.stock.quantity <= EPSILON:
		raw_at_extruder.site = Cart.Site.PARKING
		raw_at_extruder.position = raw_at_extruder.home
		raw_at_extruder.previous_position = raw_at_extruder.home
		raw_at_extruder.heading = layout.cart_heading(raw_at_extruder.home)
		raw_at_extruder = null
	coated_input = pack_wip
	erp.initialize_supply(layout)


func _equipment_implements(id: StringName, operation: String) -> bool:
	var definition: Layout.Placement = layout.objects[id]
	match operation:
		"mix":
			return id == &"Hopper"
		"extrude":
			return id == &"Extruder"
		"pack":
			return id == &"Packer" or (definition.ports.has(&"input_dock") and definition.ports.has(&"output_dock"))
		"cream", "spread", "cut", "cool", "gum_mix", "gum_form", "gum_condition", "gum_coat":
			return definition.ports.has(&"input_dock") and definition.ports.has(&"output_dock")
		"bake":
			return definition.ports.has(&"raw_dock") and definition.ports.has(&"cooked_dock")
		"coat":
			return definition.ports.has(&"cooked_dock") and definition.ports.has(&"coated_dock")
	return false


func layout_edit_problem(moving: Array = []) -> String:
	if playing:
		return "Pause the simulation before moving equipment."
	if not runs.is_empty():
		return "An order is using the line. Finish production before editing."
	if not floor_assignments.is_empty() or _lift_phase != LiftPhase.WAIT 			or (erp != null and not erp.shipment.is_empty()):
		return "A transport task is active. Let the crew finish before editing."
	if hopper.quantity > EPSILON or hopper_reserved > EPSILON or oven.stock.quantity > EPSILON 			or cooked_input.quantity > EPSILON or coated_input.quantity > EPSILON or box_progress > EPSILON:
		return "Production equipment contains work in progress."
	for cart in carts:
		if cart.stock.quantity > EPSILON:
			return "A cart contains work in progress."
	if &"Extruder" in moving and raw_at_extruder != null:
		return "A raw cart is attached to the extruder. Let the crew park it first."
	if &"Warehouse" in moving and warehouse_count() > 0:
		return "Dispatch the warehouse stock before moving the warehouse."
	if &"Palletizer" in moving and _pallet_mass(staged_pallets) > EPSILON:
		return "Clear the staged pallets before moving the packaging area."
	return ""


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
	if erp != null and erp.explicit_planning and not ref.is_empty() and ref[1] in ["rate", "batch_kg", "cycle_seconds"]:
		return false
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


func set_operating_factor(equipment: StringName, percent: float) -> bool:
	if erp == null or not erp.explicit_planning or not operating_factors.has(equipment) or not is_finite(percent):
		return false
	operating_factors[equipment] = clampf(percent / 100.0, 0.5, 1.2)
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
			if run.has("cell"):
				mass += run.cell.mass()
				continue
			mass += run.output.quantity
			if run.oven != null:
				mass += run.oven.stock.quantity
			if run.input != null:
				mass += run.input.quantity
		for location in ERP.SFG_LOCATIONS:
			for quantity in erp.balances[location].values():
				mass += float(quantity)
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
	warehouse.resize(layout.warehouse_slot_count())
	_configure_crews_and_carts()
	forklift = Operator.new(&"Forklift", "Forklift", layout.lift_home())
	lift_load = null
	warehouse_reserved_slot = -1
	_lift_pickup_slot = -1
	_lift_phase = LiftPhase.WAIT


## ERP mode: rebuild the crew and cart fleet to the configured counts once nothing is running.
## Returns true when the fleet matches the settings afterwards.
func sync_fleet() -> bool:
	if erp == null:
		return false
	var raw_count := carts.filter(func(cart: Cart) -> bool: return cart.raw).size()
	var coated_count := carts.filter(func(cart: Cart) -> bool: return cart.coated).size()
	if floor_crew.size() == int(settings[&"floor_count"]) and raw_count == int(settings[&"raw_count"]) \
			and coated_count == int(settings[&"coated_cart_count"]) \
			and carts.size() - raw_count - coated_count == int(settings[&"cooked_count"]):
		return true
	var busy := not runs.is_empty() or not floor_assignments.is_empty() \
		or carts.any(func(cart: Cart) -> bool: return cart.stock.quantity > EPSILON)
	if busy:
		return false
	_configure_crews_and_carts()
	return true


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
	_add_floor_crew(int(settings[&"floor_count"]))
	_create_carts(true, int(settings[&"raw_count"]), settings[&"raw_capacity"])
	_create_carts(false, int(settings[&"cooked_count"]), settings[&"cooked_capacity"])
	if erp != null:
		_create_coated_carts()
	if erp == null:
		raw_at_extruder = carts[0]
		raw_at_extruder.site = Cart.Site.EXTRUDER
		raw_at_extruder.position = layout.port(&"Extruder", &"raw_dock")
		raw_at_extruder.previous_position = raw_at_extruder.position


func _add_floor_crew(count: int) -> void:
	for index in range(floor_crew.size(), count):
		floor_crew.append(Operator.new(StringName("Worker%d" % (index + 1)),
			"Floor worker %d" % (index + 1), layout.crew_home(index)))


func _create_carts(raw: bool, count: int, capacity: float) -> void:
	var prefix := "Raw" if raw else "Cooked"
	for index in count:
		var home := layout.cart_home(index, raw)
		var cart := Cart.new(StringName("%s%d" % [prefix, index + 1]), raw, capacity, home)
		cart.heading = layout.cart_heading(home)
		carts.append(cart)


func _create_coated_carts() -> void:
	for index in int(settings[&"coated_cart_count"]):
		var home := layout.coated_cart_home(index)
		var cart := Cart.new(StringName("Coated%d" % (index + 1)), false, settings[&"coated_cart_capacity"], home, true)
		cart.heading = layout.cart_heading(home)
		carts.append(cart)


func advance(real_seconds: float) -> void:
	if not validation_error.is_empty() or not playing or not is_finite(real_seconds) or real_seconds <= 0.0:
		return
	_pending_seconds += real_seconds * multiplier
	while _pending_seconds + STEP_EPSILON >= STEP_SECONDS:
		_pending_seconds -= STEP_SECONDS
		_step()


func _step() -> void:
	if erp != null:
		if erp.explicit_planning and not runs.values().any(func(run: Dictionary) -> bool: return not run.has("stage")):
			_step_explicit()
		else:
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


func _step_explicit() -> void:
	erp.clock(elapsed_seconds() + STEP_SECONDS)
	_retire_routes()
	if elapsed_ticks % 4 == 3:
		_dispatch_stages()
		if runs.is_empty():
			sync_fleet()
	erp.active_id = ""
	erp.coat_remaining = 0.0
	erp.pack_remaining = 0.0
	for id in runs:
		if erp.orders[id].status == "In Progress":
			erp.active_id = id
			break
	erp.supply_tick(layout, STEP_SECONDS, minf(settings[&"sack_kg"], hopper.capacity), runs.keys())
	if erp.feeder_id.is_empty():
		extruder.idle()
		erp.scope_id = "-"
		_advance_platform()
		erp.scope_id = ""
	if erp.pack_id.is_empty():
		packer.idle()
	for id in runs:
		var order: Dictionary = erp.orders[id]
		if order.status != "In Progress":
			continue
		_open_run(id)
		if _run.has("cell"):
			_run.cell.advance(self, order, _run)
		else:
			_advance_original_stage(order)
		if elapsed_ticks % 4 == 3 and order.status == "In Progress":
			if _run.has("cell"):
				var state: String = _run.cell.state
				var waiting := state.begins_with("Waiting") or state in ["Blocked", "Ready"]
				if waiting:
					order.logistics_seconds += 1.0
				_set_delay(order, state if waiting or _run.setup > EPSILON else "")
			else:
				_monitor_stage(order)
		_close_run()
	for cart in carts:
		cart.previous_position = cart.position
	_advance_floor()
	_advance_forklift()
	elapsed_ticks += 1
	erp.sample_kpis(self, STEP_SECONDS)


func _advance_original_stage(order: Dictionary) -> void:
	if order.has("standard"):
		var factor: float = operating_factors.get(_run.equipment, 1.0)
		var standard: Dictionary = order.standard
		if standard.model != "batch":
			var rate := minf(erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec) * factor,
				order.route.operations[0].technical.get("design_rate", INF))
			match order.stage:
				"extrude": extruder.configured_rate = rate
				"coat": coater.configured_rate = rate
				"pack": packer.configured_rate = rate
	match order.stage:
		"mix":
			_advance_platform()
		"extrude":
			_advance_platform()
			_step_extrusion()
		"bake":
			_step_oven(order.recipe)
			if oven.state != Oven.State.COOKING:
				order.oven_wait_seconds += STEP_SECONDS
		"coat":
			if _run.setup > EPSILON:
				coater.record(0.0, STEP_HOURS, Machine.State.SETUP)
				_run.setup = maxf(0.0, _run.setup - STEP_SECONDS)
			else:
				_coat_erp()
			erp.coat_remaining = maxf(erp.coat_remaining, _run.setup)
		"pack":
			if _run.setup > EPSILON:
				packer.record(0.0, STEP_HOURS, Machine.State.SETUP)
				_run.setup = maxf(0.0, _run.setup - STEP_SECONDS)
			else:
				coated_input = pack_wip
				_pack()
			erp.pack_remaining = _run.setup


func _monitor_stage(order: Dictionary) -> void:
	var delay := ""
	match order.stage:
		"mix":
			if not erp.dough_finished() and erp.feed_limit(0.0) <= EPSILON:
				delay = "Waiting for ingredients at the staging deck"
		"extrude":
			if extruder.state == Machine.State.BLOCKED:
				delay = "Waiting for a raw cart"
			elif extruder.state == Machine.State.STARVED:
				delay = "Waiting for a sack at the hopper"
		"bake":
			if oven.state in [Oven.State.IDLE, Oven.State.LOADING]:
				delay = "Waiting for raw wafers or an oven load"
			elif oven.state in [Oven.State.READY, Oven.State.UNLOADING]:
				delay = "Waiting for a worker and an unloading cart"
		"coat":
			if _run.setup > EPSILON:
				delay = "Coating changeover"
			elif coater.state in [Machine.State.BLOCKED, Machine.State.STARVED]:
				delay = "Waiting for wafer carts or coating supplies"
		"pack":
			if _run.setup > EPSILON:
				delay = "Packaging changeover"
			elif packer.state in [Machine.State.BLOCKED, Machine.State.STARVED]:
				delay = "Waiting for carts, packaging supplies or pallet space"
	if order.packed > 0 and order.packed == order.boxes and order.stage == "pack":
		delay = "Waiting for forklift or warehouse capacity"
	if not delay.is_empty() and _run.setup <= EPSILON:
		order.logistics_seconds += 1.0
	_set_delay(order, delay)


func _set_delay(order: Dictionary, reason: String) -> void:
	if order.delay != reason:
		order.delay = reason
		erp.changed()


func _dispatch_stages() -> void:
	var ready: Array[Dictionary] = []
	for id in erp.dispatch_queue:
		var order: Dictionary = erp.orders[id]
		if order.start <= erp.now:
			ready.append(order)
	ready.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.start < b.start if a.start != b.start else (a.priority < b.priority if a.priority != b.priority else a.id < b.id))
	for order in ready:
		var equipment := StringName(order.route.operations[0].equipment)
		if not order_at(equipment).is_empty() or (order.stage in ["mix", "extrude"] and not erp.feeder_id.is_empty()):
			_set_delay(order, "Work center or shared staging crew occupied")
		elif not ERP.Scheduling.in_calendar(erp.catalog, order.center, erp.now, erp.now + 1.0):
			_set_delay(order, "Work center calendar is closed")
		else:
			_begin_stage(order)
			erp.dispatch_queue.erase(order.id)
			order.status = "In Progress"
			order.assigned_at = erp.now
			order.delay = "Waiting for setup or physical components"
			erp.changed()


func _begin_stage(order: Dictionary, restoring: bool = false) -> void:
	var op: Dictionary = order.route.operations[0]
	var equipment := StringName(op.equipment)
	var tech: Dictionary = op.technical
	var stage: String = order.stage
	var bake := equipment if stage == "bake" else &""
	var coat := equipment if stage == "coat" else &""
	var run := {"id": order.id, "stage": stage, "equipment": equipment, "bake": bake, "coat": coat,
		"oven": ovens.get(bake), "coater": coaters.get(coat), "input": coater_inputs.get(coat),
		"output": Storage.new(COATER_OUTFEED_KG), "raw": null, "cooked": null, "intake": null,
		"outbound": null, "pack": null, "store": null, "cycle": tech.get("cycle_seconds", 0.0),
		"setup": 0.0, "fed": false}
	runs[order.id] = run
	if not String(op.get("input_port", "")).is_empty():
		run.cell = Cell.new(op, order.recipe, cell_machines[equipment])
		run.output = run.cell.output
	if restoring:
		return
	if order.has("standard"):
		run.setup = erp.catalog.Standards.changeover(erp.catalog, resource_last.get(equipment, {}),
			order.recipe.spec, stage, order.standard.setup_seconds, order.get("setup_rules", {}))
		resource_last[equipment] = order.recipe.spec.duplicate(true)
	if run.has("cell"):
		return
	match stage:
		"mix", "extrude":
			erp.feeder_id = order.id
			if stage == "extrude":
				extruder.configured_rate = tech.rate
		"bake":
			var batch: float = tech.batch_kg
			if order.has("standard"):
				var total: float = order.recipe.target / order.standard.yield_factor
				var count := erp.catalog.Standards.batch_count(order.standard, order.recipe.target)
				if total - (count - 1) * batch < order.standard.min_batch_kg:
					batch = total / count
			run.oven.stock.resize(batch)
		"coat":
			run.input.resize(tech.input_kg)
			run.coater.configured_rate = tech.rate
			var prior: String = last_coatings.get(coat, "")
			if not order.has("standard") and not prior.is_empty() and prior != order.recipe.coating:
				run.setup = tech.setup_seconds
			last_coatings[coat] = order.recipe.coating
		"pack":
			erp.pack_id = order.id
			packer.configured_rate = tech.rate
			if not order.has("standard") and not pack_last_recipe.is_empty() and (pack_last_recipe.packaging != order.recipe.packaging \
					or pack_last_recipe.spec.box_kg != order.recipe.spec.box_kg \
					or pack_last_recipe.spec.boxes_per_pallet != order.recipe.spec.boxes_per_pallet):
				run.setup = tech.setup_seconds
			pack_last_recipe = order.recipe


func _start_stage() -> void:
	var order := erp.active()
	if order.has("stage") and order.started < 0.0:
		order.started = erp.now
		erp.changed()


func _stage_jobs() -> Array[FloorJob]:
	var jobs: Array[FloorJob] = []
	if _run.has("cell"):
		jobs.assign(_run.cell.jobs(self, _run, erp.active()))
		return jobs
	var order := erp.active()
	var stage: String = order.stage
	var active: bool = order.status == "In Progress"
	var stock_point := layout.port(&"SFGWarehouse", &"stock_dock")
	var dock: Cart = _run.store
	var input: Cart
	var site := Cart.Site.PARKING
	var destination := Vector3.ZERO
	var category := ""
	if stage == "bake":
		input = raw_at_oven
		site = Cart.Site.OVEN_RAW
		destination = layout.port(_run.bake, &"raw_dock")
		category = "raw"
	elif stage == "coat":
		input = cooked_at_coater
		site = Cart.Site.COATER
		destination = layout.port(_run.coat, &"cooked_dock")
		category = "cooked"
	elif stage == "pack":
		input = _run.pack
		site = Cart.Site.PACK_WIP
		destination = layout.port(&"PackagingWIP", &"coated_dock")
		category = "coated"
	var requesting := active and not category.is_empty() and input == null \
		and float(order.remaining.get(order.recipe.input, 0.0)) > EPSILON
	if _available(dock, Cart.Site.SFG_DOCK):
		var input_cart := _cart_matches(dock, category)
		if input_cart and dock.stock.quantity > EPSILON:
			jobs.append(_move(dock, site, destination, "Deliver " + order.recipe.input))
		elif input_cart and requesting and erp.stock(order.recipe.input, "SFG-WH") > EPSILON:
			jobs.append(_handling(JobKind.SFG_LOAD, dock, "Collect reserved " + order.recipe.input))
		elif not input_cart and dock.stock.quantity > EPSILON:
			jobs.append(_handling(JobKind.SFG_UNLOAD, dock, "Receive " + order.code + " into stock"))
		else:
			jobs.append(_move(dock, Cart.Site.PARKING, dock.home, "Return stock cart"))
	if _available(input, site):
		if input.stock.quantity <= EPSILON:
			jobs.append(_move(input, Cart.Site.PARKING, input.home, "Return empty input cart"))
		elif active:
			if stage == "bake" and oven.owner == &"" and oven.can_load():
				jobs.append(_handling(JobKind.LOAD_OVEN, input, "Load raw wafers"))
			elif stage == "coat" and cooked_input.free_space() > EPSILON:
				jobs.append(_handling(JobKind.FEED_COATER, input, "Unload coating intake"))
			elif stage == "pack" and pack_wip.free_space() > EPSILON:
				jobs.append(_handling(JobKind.UNLOAD_PACK_WIP, input, "Unload packaging WIP"))
	if stage == "extrude":
		var finished := erp.dough_finished() and hopper.quantity + hopper_reserved <= EPSILON
		if _available(raw_at_extruder, Cart.Site.EXTRUDER):
			if raw_at_extruder.stock.quantity > EPSILON and sfg_dock == null \
					and (finished or raw_at_extruder.stock.free_space() <= EPSILON):
				jobs.append(_move(raw_at_extruder, Cart.Site.SFG_DOCK, stock_point, "Deliver raw wafers to stock"))
			elif not active and raw_at_extruder.stock.quantity <= EPSILON:
				jobs.append(_move(raw_at_extruder, Cart.Site.PARKING, raw_at_extruder.home, "Return raw cart"))
		elif active and not finished and raw_at_extruder == null:
			var empty := _parked_cart(true)
			if empty != null:
				jobs.append(_move(empty, Cart.Site.EXTRUDER, layout.port(&"Extruder", &"raw_dock"), "Stage raw cart"))
	elif stage == "bake":
		if _available(cooked_at_oven, Cart.Site.OVEN_COOKED):
			if cooked_at_oven.stock.quantity > EPSILON and sfg_dock == null:
				jobs.append(_move(cooked_at_oven, Cart.Site.SFG_DOCK, stock_point, "Deliver baked wafers to stock"))
			elif active and oven.state == Oven.State.READY and oven.owner == &"":
				jobs.append(_handling(JobKind.UNLOAD_OVEN, cooked_at_oven, "Unload baked wafers"))
			elif not active and cooked_at_oven.stock.quantity <= EPSILON:
				jobs.append(_move(cooked_at_oven, Cart.Site.PARKING, cooked_at_oven.home, "Return baked cart"))
		elif active and cooked_at_oven == null and oven.state in [Oven.State.COOKING, Oven.State.READY]:
			var empty := _parked_cart(false)
			if empty != null:
				jobs.append(_move(empty, Cart.Site.OVEN_COOKED, layout.port(_run.bake, &"cooked_dock"), "Stage baked cart"))
	elif stage == "coat":
		var out: Cart = _run.outbound
		if _available(out, Cart.Site.COATER_OUT):
			var waiting: float = _run.output.quantity
			var finished: bool = float(order.get("progress", {}).get("coat", 0.0)) + EPSILON >= order.recipe.target
			if out.stock.quantity > EPSILON and (out.stock.free_space() <= EPSILON or (finished and waiting <= EPSILON)):
				if sfg_dock == null:
					jobs.append(_move(out, Cart.Site.SFG_DOCK, stock_point, "Deliver coated wafers to stock"))
			elif active and waiting > EPSILON and (finished or waiting + EPSILON >= minf(out.stock.free_space(), _run.output.capacity)):
				jobs.append(_handling(JobKind.LOAD_COATED, out, "Load coated wafers"))
			elif not active and out.stock.quantity <= EPSILON:
				jobs.append(_move(out, Cart.Site.PARKING, out.home, "Return coated cart"))
		elif active and out == null and _run.output.quantity > EPSILON:
			var empty := _parked_category("coated")
			if empty != null:
				jobs.append(_move(empty, Cart.Site.COATER_OUT, layout.port(_run.coat, &"coated_dock"), "Stage coated cart"))
	if requesting and sfg_dock == null:
		var empty := _parked_category(category)
		if empty != null:
			jobs.append(_move(empty, Cart.Site.SFG_DOCK, stock_point, "Collect a stock cart"))
	return jobs


func _cart_matches(cart: Cart, category: String) -> bool:
	match category:
		"raw": return cart.raw
		"cooked": return not cart.raw and not cart.coated
		"coated": return cart.coated
	return false


func _parked_category(category: String) -> Cart:
	for cart in carts:
		if _cart_matches(cart, category) and _available(cart, Cart.Site.PARKING):
			return cart
	return null


func _stage_wip(order: Dictionary, run: Dictionary) -> Dictionary:
	var totals: Dictionary = run.cell.wip(order) if run.has("cell") else {}
	if run.has("cell"):
		for cart in carts:
			if cart.order_id == order.id and not cart.material.is_empty():
				totals[cart.material] = float(totals.get(cart.material, 0.0)) + cart.stock.quantity
		for pallet in staged_pallets:
			if pallet != null and pallet.order_id == order.id:
				totals[order.code] = float(totals.get(order.code, 0.0)) + pallet.mass
		if lift_load != null and lift_load.order_id == order.id:
			totals[order.code] = float(totals.get(order.code, 0.0)) + lift_load.mass
		for code in totals.keys():
			if totals[code] <= EPSILON:
				totals.erase(code)
		return totals
	var code: String = order.code
	var input: String = order.recipe.input
	match order.stage:
		"mix", "extrude":
			if erp.feeder_id == order.id:
				var carried := hopper.quantity if order.stage == "extrude" else 0.0
				for worker in platform_crew:
					carried += worker.cargo_kg
				totals[code if order.stage == "mix" else input] = carried
		"bake":
			var baked: bool = run.oven.state in [Oven.State.READY, Oven.State.UNLOADING]
			totals[code if baked else input] = run.oven.stock.quantity
		"coat":
			totals[input] = run.input.quantity
			totals[code] = run.output.quantity
		"pack":
			totals[input] = pack_wip.quantity + box_progress if erp.pack_id == order.id else 0.0
			totals[code] = lift_load.mass if lift_load != null and lift_load.order_id == order.id else 0.0
			for pallet in staged_pallets:
				if pallet != null and pallet.order_id == order.id:
					totals[code] += pallet.mass
	for cart in carts:
		if cart.order_id != order.id:
			continue
		var output: bool = (order.stage == "extrude" or (order.stage == "bake" and not cart.raw) or (order.stage == "coat" and cart.coated))
		var material := code if output else input
		totals[material] = float(totals.get(material, 0.0)) + cart.stock.quantity
	for material in totals.keys():
		if totals[material] <= EPSILON:
			totals.erase(material)
	return totals


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
	if erp.explicit_planning:
		return
	var chosen := {}
	for order in erp.orders.values():
		if order.has("stage") or order.status != "Released" or order.start > erp.now or not route_conflicts(order).is_empty():
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
	if order.has("stage"):
		_begin_stage(order, restoring)
		return
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
		if not order.has("stage") and op.type not in ["bake", "coat"]:
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
		var order: Dictionary = erp.orders.get(erp.feeder_id, {})
		return {} if order.get("stage") == "mix" else order
	if equipment == &"Packer":
		return erp.orders.get(erp.pack_id, {})
	for run in runs.values():
		if equipment == run.get("equipment", &"") or equipment == run.bake or equipment == run.coat:
			return erp.orders[run.id]
	return {}


func active_cell(equipment: StringName) -> Cell:
	if not cell_machines.has(equipment):
		return null
	var order := order_at(equipment)
	return runs.get(order.get("id", ""), {}).get("cell")


func standard_readout(equipment: StringName, order: Dictionary) -> String:
	var standard: Dictionary = order.get("standard", {})
	if standard.is_empty():
		return "Standard Rate · Assign a material order to this work center."
	var factor: float = operating_factors.get(equipment, 1.0)
	var output: float = order.get("progress", {}).get(order.stage, 0)
	var end: float = order.completed if order.completed >= 0 else erp.now
	var actual := output * 3600 / maxf(STEP_SECONDS, end - order.started) if order.started >= 0 else 0.0
	var equivalent := erp.catalog.Standards.kg_per_hour(standard, order.recipe.spec)
	var op: Dictionary = order.route.operations[0]
	var effective := minf(equivalent * factor, op.technical.get("design_rate", INF))
	var rate_text := "%.1f %s" % [standard.rate * effective / equivalent, standard.unit] if equivalent > 0 \
		else "%.1f s cycle" % (standard.cycle_seconds / factor)
	if equivalent > 0 and standard.unit != "kg/h":
		actual *= standard.rate / equivalent
	return "Standard Rate   %s\nOperating Rate Factor   %.0f%% · Effective   %s\nActual average   %.1f %s" % [
		erp.catalog.Standards.caption(standard), factor * 100, rate_text, actual, standard.get("unit", "kg/h")]


func work_center_status(equipment: StringName) -> String:
	var order := order_at(equipment)
	var run: Dictionary = runs.get(order.get("id", ""), {})
	if run.has("cell"):
		return run.cell.state
	if cell_machines.has(equipment):
		return "Idle"
	if equipment == &"Hopper":
		return "Preparing" if not order_at(equipment).is_empty() else "Idle"
	if ovens.has(equipment):
		return ovens[equipment].state_title()
	var machine: Machine = coaters.get(equipment, extruder if equipment == &"Extruder" else packer)
	return Machine.State.keys()[machine.state].capitalize()


func _retire_routes() -> void:
	for id in runs.keys():
		var run: Dictionary = runs[id]
		if erp.orders[id].status in ["Completed", "Closed"] and run.raw == null and run.cooked == null and run.intake == null \
			and run.outbound == null and run.pack == null and run.get("store") == null \
			and (id != erp.feeder_id or raw_at_extruder == null) \
			and not floor_assignments.values().any(func(job: FloorJob) -> bool: return job.run == id):
			if run.coater != null:
				run.coater.idle()
			if run.has("cell"):
				run.cell.machine.idle()
			if erp.feeder_id == id:
				erp.feeder_id = ""
			if erp.pack_id == id:
				erp.pack_id = ""
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
	if _available(raw_at_extruder, Cart.Site.EXTRUDER):
		output = raw_at_extruder.stock
	var order := erp.active()
	var recipe: Dictionary = order.recipe
	var yield_factor: float = order.get("standard", {}).get("yield_factor", 1.0)
	var target := extruder.configured_rate * STEP_HOURS
	var free := output.free_space() if output != null else 0.0
	var available := hopper.quantity * yield_factor
	var amount := minf(target, minf(free, available))
	if amount > EPSILON:
		hopper.remove(amount / yield_factor)
		output.apply_transfer(amount, 0)
		_add_progress("extrude", amount)
		raw_at_extruder.order_id = erp.feeder_id
		if _run.has("stage"):
			raw_at_extruder.material = order.code
			_start_stage()
			_stage_transform(recipe.input, amount / yield_factor, order.code, amount, "Extrusion")
			_record_scrap(order, amount, yield_factor)
		else:
			_erp_transform(recipe.dough, amount, recipe.raw, amount, "Extrusion")
	extruder.record(amount, STEP_HOURS, _machine_state(target, amount, free <= available))


func _step_oven(recipe: Dictionary) -> void:
	var previous := oven.state
	if oven.can_load() and oven.owner == &"" and oven.stock.quantity > EPSILON and _raw_finished():
		oven.start(_run.cycle + STEP_SECONDS)
	oven.advance(STEP_SECONDS * (operating_factors.get(_run.equipment, 1.0) if erp.active().has("standard") else 1.0), _run.cycle)
	if previous == Oven.State.COOKING and oven.state == Oven.State.READY:
		if _run.has("stage"):
			var order := erp.active()
			var yield_factor: float = order.get("standard", {}).get("yield_factor", 1.0)
			var input := oven.stock.quantity
			oven.stock.quantity = input * yield_factor
			_add_progress("bake", oven.stock.quantity)
			_stage_transform(recipe.input, input, order.code, oven.stock.quantity, "Oven batch")
			_record_scrap(order, oven.stock.quantity, yield_factor)
		else:
			_add_progress("bake", oven.stock.quantity)
			_erp_transform(recipe.raw, oven.stock.quantity, recipe.baked, oven.stock.quantity, "Oven batch")


func _erp_transform(input: String, amount: float, output: String, produced: float, reason: String) -> void:
	erp.flow(input, amount, "WIP", "", "Consumption", reason)
	erp.flow(output, produced, "", "WIP", "SFG Receipt", reason)


func _stage_transform(input: String, amount: float, output: String, produced: float, reason: String) -> void:
	erp.flow(input, amount, "WIP", "", "WIP Used", reason)
	erp.flow(output, produced, "", "WIP", "WIP Produced", reason)


func _record_scrap(order: Dictionary, produced: float, yield_factor: float) -> void:
	var loss := produced * (1.0 / yield_factor - 1.0)
	if loss > EPSILON:
		order.scrapped += loss
		scrapped_kg += loss
		var reason: String = order.get("standard", {}).get("yield_loss_reason", "Standard yield loss")
		erp.flow(order.code, loss, "WIP", "", "Scrap", reason)


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
		if order.has("stage"):
			_start_stage()
			_stage_transform(order.recipe.baked, kg * baked_rate, order.recipe.coated, kg, "Chocolate coating")
			_record_scrap(order, kg, order.get("standard", {}).get("yield_factor", 1.0))
		else:
			_erp_transform(order.recipe.baked, kg * baked_rate, order.recipe.coated, kg, "Chocolate coating")
	coater.record(kg, STEP_HOURS, _machine_state(target, kg, room <= limit))


func _raw_finished() -> bool:
	if _run.get("stage") == "bake":
		var order := erp.active()
		if float(order.remaining.get(order.recipe.input, 0.0)) > EPSILON:
			return false
	elif not _run.fed and (erp.scope_id != erp.feeder_id or not erp.dough_finished() or hopper.quantity + hopper_reserved > EPSILON):
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
		if erp != null:
			_start_stage()
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
				erp.flow(recipe.coated, box_progress, "PACK-WIP", "", "WIP Used" if erp.active().has("stage") else "Consumption", "Carton packed")
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
		var pace := Operator.carry_pace(worker.cargo_kg) if worker.state == Operator.State.CARRYING else 1.0
		worker.advance(STEP_SECONDS, settings[&"platform_speed"] * pace)
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
				if erp == null or erp.active().get("stage") != "extrude":
					var yield_factor: float = erp.active().get("standard", {}).get("yield_factor", 1.0) if erp != null else 1.0
					ingredients_taken += worker.cargo_kg / yield_factor
				if erp != null and erp.active().get("stage") == "mix":
					var order := erp.active()
					_record_scrap(order, worker.cargo_kg, order.get("standard", {}).get("yield_factor", 1.0))
					_start_stage()
				worker.travel([layout.platform_drop(index)], Operator.State.CARRYING,
					"Carry sack to hopper", "Ingredient hopper")
			Operator.State.CARRYING:
				worker.task = "Discharge ingredient sack"
				var unload: float = settings[&"unload_time"]
				if erp != null and erp.active().get("stage") == "mix":
					var rate: float = erp.active().route.operations[0].technical.rate * operating_factors.get(&"Hopper", 1.0)
					unload = maxf(unload, worker.cargo_kg * 3600.0 * platform_crew.size() / rate)
				worker.work(unload, Operator.State.UNLOADING)
			Operator.State.UNLOADING:
				if erp != null and erp.active().get("stage") == "mix":
					_add_progress("mix", worker.cargo_kg)
					erp.receive_stage(erp.active(), worker.cargo_kg)
				else:
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
		var pace := 1.0
		if worker.state == Operator.State.PUSHING and floor_assignments.has(worker.id):
			pace = Operator.cart_pace(floor_assignments[worker.id].cart.stock.quantity)
		worker.advance(STEP_SECONDS, settings[&"floor_speed"] * pace)
		if not floor_assignments.has(worker.id):
			continue
		var job := floor_assignments[worker.id]
		if worker.state == Operator.State.PUSHING:
			job.cart.position = worker.position
			job.cart.heading = worker.heading
		if worker.finished():
			if not job.run.is_empty():
				_open_run(job.run)
			_continue_job(worker, job)
			if not job.run.is_empty():
				_close_run()
	_assign_floor_jobs()


func _assign_floor_jobs() -> void:
	pending_jobs = _eligible_jobs()
	var idle: Array[Operator] = []
	for worker in floor_crew:
		if worker.state == Operator.State.IDLE:
			idle.append(worker)
	while not idle.is_empty():
		var next: FloorJob
		for job in pending_jobs:
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
		if not next.run.is_empty():
			_open_run(next.run)
		_claim_job(closest, next)
		if not next.run.is_empty():
			_close_run()
		idle.erase(closest)
		pending_jobs = _eligible_jobs()


func _eligible_jobs() -> Array[FloorJob]:
	if erp == null:
		return _floor_jobs()
	var result: Array[FloorJob] = []
	if runs.is_empty() and _available(raw_at_extruder, Cart.Site.EXTRUDER) and raw_at_extruder.stock.quantity <= EPSILON:
		result.append(_move(raw_at_extruder, Cart.Site.PARKING, raw_at_extruder.home, "Park idle extruder cart"))
	for id in runs:
		_open_run(id)
		for job in (_stage_jobs() if _run.has("stage") else _floor_jobs()):
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
	var path := layout.route(worker.position, job.cart.position, layout.walk_lane)
	if path.is_empty() and not worker.position.is_equal_approx(job.cart.position):
		return
	floor_assignments[worker.id] = job
	if not job.material.is_empty():
		job.cart.material = job.material
	job.cart.owner = worker.id
	if job.kind == JobKind.MOVE_CART:
		_cart_route_owner = worker.id
		_set_berth(job.site, job.cart)
	elif job.kind in [JobKind.LOAD_OVEN, JobKind.UNLOAD_OVEN]:
		oven.owner = worker.id
	elif job.kind == JobKind.CELL_BATCH:
		_run.cell.handling = true
	worker.travel(path, Operator.State.WALKING, job.title, _job_destination(job.cart.site))


func _continue_job(worker: Operator, job: FloorJob) -> void:
	var cart := job.cart
	if worker.state == Operator.State.WALKING:
		if job.kind == JobKind.MOVE_CART:
			var path := layout.route(worker.position, job.point, layout.cart_lane)
			if path.is_empty() and not worker.position.is_equal_approx(job.point):
				return
			_set_berth(cart.site, null)
			cart.site = Cart.Site.TRANSIT
			worker.travel(path, Operator.State.PUSHING, job.title, _job_destination(job.site))
		else:
			if job.kind in [JobKind.CELL_INPUT, JobKind.CELL_OUTPUT, JobKind.CELL_BATCH, JobKind.CELL_PALLET]:
				var duration := CART_HANDLING_SECONDS
				if _run.cell.standard.model == "batch":
					duration = _run.cell.standard.loading_seconds if job.kind == JobKind.CELL_BATCH else _run.cell.standard.unloading_seconds
				worker.work(duration, Operator.State.LOADING if job.kind == JobKind.CELL_BATCH else Operator.State.UNLOADING)
				return
			if job.kind == JobKind.LOAD_OVEN:
				oven.state = Oven.State.LOADING
				worker.work(erp.active().get("standard", {}).get("loading_seconds", CART_HANDLING_SECONDS) if erp != null else CART_HANDLING_SECONDS, Operator.State.LOADING)
			elif job.kind in [JobKind.LOAD_COATED, JobKind.SFG_LOAD]:
				worker.work(CART_HANDLING_SECONDS, Operator.State.LOADING)
			else:
				if job.kind == JobKind.UNLOAD_OVEN:
					oven.state = Oven.State.UNLOADING
				var duration := CART_HANDLING_SECONDS
				if erp != null and job.kind == JobKind.UNLOAD_OVEN:
					duration = erp.active().get("standard", {}).get("unloading_seconds", duration)
				worker.work(duration, Operator.State.UNLOADING)
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
			if erp != null:
				_start_stage()
			_move_mass(cart.stock, oven.stock)
			oven.owner = &""
			oven.advance(0.0, _run.get("cycle", settings[&"cook_minutes"] * 60.0))
		JobKind.UNLOAD_OVEN:
			_move_mass(oven.stock, cart.stock)
			cart.order_id = job.run
			cart.material = erp.active().code if not job.run.is_empty() else ""
			oven.state = Oven.State.READY if oven.stock.quantity > EPSILON else Oven.State.IDLE
			oven.owner = &""
		JobKind.FEED_COATER:
			_move_mass(cart.stock, cooked_input)
		JobKind.LOAD_COATED:
			_move_mass(_run.output, cart.stock)
			cart.order_id = job.run
			cart.material = erp.active().get("code", "") if _run.has("stage") else ""
		JobKind.UNLOAD_PACK_WIP:
			var amount := cart.stock.remove(pack_wip.free_space())
			pack_wip.apply_transfer(amount, 0.0)
			erp.flow(erp.active().recipe.coated, amount, "WIP", "PACK-WIP", "Transfer", "Coated cart unloaded")
		JobKind.CELL_INPUT, JobKind.CELL_OUTPUT, JobKind.CELL_BATCH, JobKind.CELL_PALLET:
			_run.cell.handle(self, _run, erp.active(), job)
		JobKind.SFG_LOAD:
			var order := erp.active()
			var code: String = cart.material if _run.has("cell") else order.recipe.input
			var amount := minf(cart.stock.free_space(), minf(erp.stock(code, "SFG-WH"), order.remaining.get(code, 0.0)))
			if _run.has("cell"):
				amount = minf(amount, _run.cell.inputs[code].free_space())
			if amount > EPSILON:
				erp._consume(order, code, amount, "SFG-WH", "Issue reserved material to production cart")
				cart.stock.apply_transfer(amount, 0.0)
				cart.order_id = job.run
				cart.material = code
		JobKind.SFG_UNLOAD:
			erp.receive_stage(erp.active(), cart.stock.remove(cart.stock.quantity))
	if cart.stock.quantity <= EPSILON:
		cart.order_id = ""
		if job.kind != JobKind.MOVE_CART or job.site != Cart.Site.SFG_DOCK:
			cart.material = ""
	cart.owner = &""
	floor_assignments.erase(worker.id)
	worker.idle()


func _job_destination(site: Cart.Site) -> String:
	if not _run.is_empty():
		var ops: Array = erp.active().route.operations
		if _run.has("stage") and site in [Cart.Site.OVEN_RAW, Cart.Site.OVEN_COOKED, Cart.Site.COATER, Cart.Site.COATER_OUT, Cart.Site.CELL_IN, Cart.Site.CELL_OUT]:
			return ops[0].description + " · " + Cart.SITE_NAMES[site]
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
		Cart.Site.CELL_IN:
			cooked_at_coater = cart
		Cart.Site.CELL_OUT:
			_run.outbound = cart
		Cart.Site.PALLET_DOCK:
			_run.pack = cart
			pallet_dock = cart
		Cart.Site.SFG_DOCK:
			_run.store = cart
			sfg_dock = cart
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
				Operator.State.DRIVING, "Deliver finished pallet", slot_name(warehouse_reserved_slot))
		LiftPhase.TO_STORAGE:
			_lift_phase = LiftPhase.DROP_OFF
			forklift.work(storage_handling_seconds(warehouse_reserved_slot), Operator.State.UNLOADING)
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


## Time to lift a pallet into the slot and clear the forks: the floor takes the base time, each rack level adds mast travel.
func storage_handling_seconds(slot: int) -> float:
	return LIFT_HANDLING_SECONDS + LIFT_LEVEL_SECONDS * layout.warehouse_level(slot)


func slot_name(slot: int) -> String:
	var level := layout.warehouse_level(slot)
	var position := slot % layout.warehouse_position_count()
	return "Warehouse slot %02d" % (position + 1) if layout.warehouse_slot_count() == layout.warehouse_position_count() \
		else "Warehouse bay %02d · %s" % [position + 1, "floor" if level == 0 else "level %d" % level]


func _request_forklift_job() -> void:
	for index in staged_pallets.size():
		var pallet := staged_pallets[index]
		if pallet == null or not pallet.full():
			continue
		var slot := warehouse.find(null)
		if slot < 0:
			forklift.task = "Waiting for warehouse space"
			forklift.destination = "Forklift parking"
			return
		warehouse_reserved_slot = slot
		_lift_pickup_slot = index
		_lift_phase = LiftPhase.TO_PALLET
		forklift.travel(layout.route(forklift.position, layout.pallet_approach(index), layout.lift_lane),
			Operator.State.DRIVING, "Collect full pallet", "Palletizing bay %02d" % (index + 1))
		return
	forklift.idle()


func find_operator(id: StringName) -> Operator:
	if erp != null and id == ERP.MATERIAL_HANDLER_ID:
		return erp.material_handler
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
	if run.has("stage"):
		return _stage_wip(order, run)
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
