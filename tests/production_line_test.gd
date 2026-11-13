extends SceneTree
## Run with godot --headless --path . --script res://tests/production_line_test.gd

const Line = preload("res://simulation/production_line.gd")
const Machine = Line.Machine
const Cart = Line.Cart
const Oven = Line.Oven
const Operator = Line.Operator
const STEP := Line.STEP_SECONDS

var _failures := 0
var _scenarios := 0


func _initialize() -> void:
	_ingredient_delivery()
	_raw_cart_transport()
	_oven_cycle()
	_mismatched_loads()
	_continuous_processing()
	_packaging_settings()
	_forklift_and_storage()
	_upstream_block_and_resume()
	_pause_speed_and_reset()
	_reservations_bounds_and_mass()
	print("%d chocolate factory scenarios, %d failures." % [_scenarios, _failures])
	quit(1 if _failures else 0)


func _ingredient_delivery() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_setting(&"hopper_capacity", 25.0)
	line.set_setting(&"extruder_rate", 0.0)
	var worker := line.platform_crew[0]
	var origin := worker.position
	line.set_playing(true)
	line.advance(STEP)
	_near(line.hopper_reserved, 25.0, "Two workers cannot reserve the same hopper space")
	_check(line.platform_crew[1].state == Operator.State.IDLE, "Second feeder waits")
	_check(not line.set_setting(&"hopper_capacity", 20.0), "Hopper resize protects incoming sack")
	line.set_setting(&"sack_kg", 30.0)
	line.advance(1.5)
	_near(line.ingredients_taken, 0.0, "Pickup takes time")
	line.advance(0.75)
	_near(worker.cargo_kg, 25.0, "In-progress sack keeps its original mass")
	_near(line.hopper.quantity, 0.0, "Carried sack has not reached the hopper")
	_check(worker.position.distance_to(origin) > 0.0, "Sack carrier walks")
	_check(worker.position.distance_to(origin) <= line.settings[&"platform_speed"] * STEP + 1e-4,
		"Platform worker advances at most one tick of walking")
	if _until(line, func() -> bool: return worker.state == Operator.State.UNLOADING,
			30.0, "Worker reaches hopper"):
		line.advance(1.75)
		_near(line.hopper.quantity, 0.0, "Unloading duration is respected")
		line.advance(STEP)
		_near(line.hopper.quantity, 25.0, "One sack delivered to hopper")
	line.advance(20.0)
	_near(line.hopper_reserved, 0.0, "Full hopper prevents new reservations")
	_near(line.ingredients_taken, line.material_on_site(), "Hopper mass conserved")
	_check(worker.position.is_equal_approx(origin), "Worker returns to the staging area")


func _raw_cart_transport() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_setting(&"raw_count", 1.0)
	line.set_setting(&"raw_capacity", 15.0)
	line.reset()
	line.set_playing(true)
	line.advance(STEP)
	_check(line.extruder.state == Machine.State.STARVED, "Extruder starts without material")
	var cart := line.raw_at_extruder
	var dock := cart.position
	if not _until(line, func() -> bool: return cart.site == Cart.Site.TRANSIT,
			70.0, "Full cart is assigned and picked up"):
		return
	_near(cart.stock.quantity, 15.0, "Only full raw cart is sent")
	_check(line.raw_at_extruder == null, "Single-cart pool leaves the extruder without a tray")
	_check(cart.position.is_equal_approx(dock), "Cart does not jump on pickup")
	line.advance(STEP)
	_check(line.extruder.state == Machine.State.BLOCKED and line.extruder.actual_rate == 0.0,
		"No replacement cart blocks the extruder")
	_check(cart.position.distance_to(dock) > 0.0, "Pushed cart moves visibly")
	_check(line.raw_deliveries == 0 and line.oven.stock.quantity == 0.0,
		"Oven cannot receive material before the cart arrives")
	_check(line.raw_at_oven == cart and cart.owner != &"", "Oven berth and cart are reserved")
	_until(line, func() -> bool: return line.oven.stock.quantity > 0.0, 55.0,
		"Worker loads the delivered tray")
	_until(line, func() -> bool: return line.raw_at_extruder == cart and cart.site == Cart.Site.EXTRUDER,
		65.0, "Empty tray is pushed back and reused")


func _oven_cycle() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_playing(true)
	if not _until(line, func() -> bool: return line.oven.stock.quantity > 0.0, 160.0,
			"First raw tray reaches oven"):
		return
	_near(line.oven.stock.quantity, 50.0, "Default first tray is smaller than a batch")
	_check(line.oven.state == Oven.State.LOADING, "Partial load waits")
	if not _until(line, func() -> bool: return line.oven.state == Oven.State.COOKING, 150.0,
			"Second delivery triggers batch"):
		return
	_near(line.oven.stock.quantity, 75.0, "Oven cooks exactly its batch capacity")
	_near(line.raw_at_oven.stock.quantity, 25.0, "Oversize delivery leaves its excess on the cart")
	var cycle := line.settings[&"cook_minutes"] * 60.0
	_near(line.oven.remaining, cycle, "Configured minutes become simulated seconds")
	_check(not line.set_setting(&"batch_capacity", 80.0), "Active oven batch capacity is locked")
	line.set_setting(&"cook_minutes", 0.10)
	line.advance(cycle - STEP)
	_check(line.oven.state == Oven.State.COOKING and line.oven.batches == 0,
		"Changing the next duration does not finish the current batch early")
	line.advance(STEP)
	_check(line.oven.state == Oven.State.READY and line.oven.batches == 1, "Oven finishes on time")
	if not _until(line, func() -> bool: return line.oven.state == Oven.State.UNLOADING, 100.0,
			"Worker reaches the cooked batch"):
		return
	_near(line.cooked_at_oven.stock.quantity, 0.0, "Cooked tray remains empty during timed handling")
	line.advance(Line.CART_HANDLING_SECONDS)
	_near(line.oven.stock.quantity, 30.0, "Batch remainder stays in oven after partial unloading")
	_near(line.cooked_at_oven.stock.quantity, 45.0, "Worker fills a bounded cooked tray")
	_near(line.cooked_input.quantity, 0.0, "Coater waits for cart travel and handoff")
	_until(line, func() -> bool: return line.cooked_input.quantity > 0.0, 100.0,
		"Cooked tray reaches and feeds coating")


func _mismatched_loads() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_setting(&"floor_count", 1.0)
	line.set_setting(&"raw_count", 1.0)
	line.set_setting(&"cooked_count", 1.0)
	line.set_setting(&"raw_capacity", 88.0)
	line.set_setting(&"batch_capacity", 35.0)
	line.set_setting(&"cooked_capacity", 17.0)
	line.set_setting(&"coater_input", 11.0)
	line.reset()
	line.set_playing(true)
	line.advance(1500.0)
	_check(line.warehouse_count() > 0 and line.oven.batches >= 3,
		"One worker and one cart of each type handle incompatible capacities")
	_check(line.raw_deliveries < line.cooked_deliveries, "Large raw carts span batches and smaller cooked deliveries")
	_mass_balance(line, "Mismatched line")


func _continuous_processing() -> void:
	_scenarios += 1
	var line := _packing_line(20.0)
	line.advance(STEP)
	_near(line.coater.actual_rate, 3600.0, "Coating uses configured kilograms per simulated hour")
	_near(line.coated_input.quantity, 0.25, "Coater transfers a quarter-second of output")
	_near(line.packer.actual_rate, 0.0, "Direct transfer reaches packaging on the following tick")
	line.advance(1.75)
	_check(line.boxes_completed == 0, "Partial box stays in the packer")
	_near(line.box_progress, 1.75, "Partially packaged mass is tracked")
	line.advance(STEP)
	_check(line.boxes_completed == 1 and line.staged_pallets[0].boxes == 1,
		"Exact box threshold creates one carton")
	_near(line.packer.actual_rate, 3600.0, "Packer is constrained by available coating output")
	_check(line.packer.state == Machine.State.STARVED, "Limited input shows starvation")
	line.advance(2.0)
	_check(line.staged_pallets[0].full(), "Pallet becomes ready at the configured box count")
	line.advance(25.0)
	_check(line.pallets_ready() == 3 and line.boxes_completed == 6,
		"Finite palletizing bays prevent unbounded boxes")
	_check(line.packer.state == Machine.State.BLOCKED, "Full pallet staging stops packaging")
	_near(line.packer.actual_rate, 0.0, "Blocked packaging transfers no mass")
	_mass_balance(line, "Packed material")


func _packaging_settings() -> void:
	_scenarios += 1
	var line := _packing_line(20.0)
	line.advance(1.5)
	_near(line.box_progress, 1.25, "A box is already being filled")
	line.set_setting(&"box_kg", 3.0)
	line.advance(0.75)
	_check(line.boxes_completed == 1, "Box size edit applies to the next carton")
	_near(line.staged_pallets[0].mass, 2.0, "First carton kept its original mass")
	line.set_setting(&"pallet_boxes", 1.0)
	line.advance(3.0)
	_check(line.staged_pallets[0].target_boxes == 2 and line.staged_pallets[0].full(),
		"An active pallet keeps its original target")
	_near(line.staged_pallets[0].mass, 5.0, "Different-size boxes keep exact pallet mass")
	line.advance(3.0)
	_check(line.staged_pallets[1].target_boxes == 1 and line.staged_pallets[1].full(),
		"New pallet uses edited target")
	_mass_balance(line, "Changed carton and pallet sizes")


func _forklift_and_storage() -> void:
	_scenarios += 1
	var line := _packing_line(20.0, 1)
	var home := line.forklift.position
	if not _until(line, func() -> bool: return line.warehouse_reserved_slot >= 0,
			15.0, "Ready pallet dispatches the forklift"):
		return
	_check(line.warehouse_count() == line.warehouse.size() - 1 and line.warehouse_reserved_slot == line.warehouse.size() - 1
		and line.lift_load == null and line.pallets_ready() > 0,
		"Dispatch reserves the last, highest rack slot while the pallet still sits at staging")
	_check(not line.set_setting(&"warehouse_capacity", 0.0), "Warehouse capacity is fixed")
	line.advance(STEP)
	_check(line.forklift.position.distance_to(home) > 0.0, "Forklift drives to the pickup")
	if not _until(line, func() -> bool: return line.lift_load != null, 30.0,
			"Forklift collects pallet after arrival and handling"):
		return
	_near(line.lift_load.mass, 4.0, "Loaded pallet mass is carried in transit")
	_check(line.warehouse_count() == line.warehouse.size() - 1, "Lift load has not arrived at warehouse")
	_mass_balance(line, "Pallet in transit")
	_until(line, func() -> bool: return line.warehouse_count() == line.warehouse.size(), 90.0,
		"Driving and lifting fill the last rack position")
	line.advance(60.0)
	_check(line.warehouse_count() == line.warehouse.size() and line.forklift_deliveries == 1 and line.pallets_ready() == 3,
		"Full storage stops subsequent deliveries and fills staging")
	_check(line.forklift.task == "Waiting for warehouse space", "Forklift reports full warehouse")
	_check(line.dispatch(false) == 1, "Dispatch frees one occupied slot")
	_near(line.dispatched_kg, 4.0, "Dispatched inventory preserves exact mass")
	_until(line, func() -> bool: return line.forklift_deliveries == 2, 60.0,
		"Forklift resumes after dispatch")
	_mass_balance(line, "Dispatched storage")


func _upstream_block_and_resume() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_playing(true)
	_until(line, func() -> bool: return line.warehouse_count() == line.warehouse.size(), 200000.0, "Default run fills every rack position")
	line.advance(1500.0)
	_check(line.warehouse_count() == line.warehouse.size() and line.pallets_ready() == 3, "Default run fills all space")
	_check(line.packer.state == Machine.State.BLOCKED and line.coater.state == Machine.State.BLOCKED
		and line.extruder.state == Machine.State.BLOCKED, "Blockage reaches the upstream machines")
	var output := line.extruder.total_output
	var deliveries := line.forklift_deliveries
	_check(line.dispatch(true) == line.warehouse.size(), "Dispatch all empties stored pallets")
	line.advance(200.0)
	_check(line.forklift_deliveries > deliveries, "Warehouse accepts new loads after dispatch")
	_until(line, func() -> bool: return line.extruder.total_output > output, 500.0,
		"Upstream extrusion resumes after dispatch")
	_mass_balance(line, "Restarted full line")


func _pause_speed_and_reset() -> void:
	_scenarios += 1
	var reference := Line.new()
	reference.set_playing(true)
	reference.advance(530.0)
	for speed: int in Line.SPEEDS:
		var line := Line.new()
		line.set_multiplier(speed)
		line.set_playing(true)
		var chunks := 463
		for frame in chunks:
			line.advance(530.0 / speed / chunks)
		_check(line.elapsed_ticks == reference.elapsed_ticks, "Same tick count at %d×" % speed)
		_check(line.warehouse_count() == reference.warehouse_count()
			and line.boxes_completed == reference.boxes_completed, "Same throughput at equal simulated time")
		_near(line.material_on_site(), reference.material_on_site(), "Frame partition preserves inventories")
		_check(line.forklift.position.is_equal_approx(reference.forklift.position),
			"Frame partition preserves transport positions")
	reference.advance(0.125)
	reference.set_playing(false)
	var position := reference.forklift.position
	var stock := reference.material_on_site()
	var tick := reference.elapsed_ticks
	reference.advance(120.0)
	_check(reference.elapsed_ticks == tick and reference.forklift.position == position,
		"Pause freezes clock and forklift")
	_near(reference.material_on_site(), stock, "Pause freezes inventories")
	reference.set_playing(true)
	reference.advance(0.125)
	_check(reference.elapsed_ticks == tick + 1, "Resume preserves partial tick")
	reference.set_setting(&"extruder_rate", 1234.0)
	_near(reference.extruder.configured_rate, 1234.0, "Live setpoint accepts whole kilograms per hour")
	reference.set_setting(&"floor_count", 3.0)
	_check(reference.floor_crew.size() == 9, "Changing crew count keeps live assignments")
	reference.reset()
	_check(reference.floor_crew.size() == 3 and reference.elapsed_ticks == 0 and not reference.playing,
		"Reset applies fleet changes and pauses")
	_check(reference.floor_assignments.is_empty() and reference.warehouse_reserved_slot < 0,
		"Reset clears task claims")
	_near(reference.material_on_site() + reference.dispatched_kg, 0.0, "Reset clears all material and totals")


func _reservations_bounds_and_mass() -> void:
	_scenarios += 1
	var line := Line.new()
	line.set_setting(&"floor_count", 4.0)
	line.set_setting(&"raw_count", 4.0)
	line.set_setting(&"cooked_count", 4.0)
	line.reset()
	line.set_playing(true)
	for tick in 6800:
		if tick % 1911 == 0:
			line.set_setting(&"raw_capacity", 49.5 + tick % 11)
			line.set_setting(&"cooked_capacity", 45.0 + tick % 13)
			line.set_setting(&"coater_rate", 6250 + tick % 1000)
			line.set_setting(&"packing_rate", 7350 + tick % 1000)
			line.set_setting(&"cook_minutes", 0.35 + (tick % 7) * 0.05)
			line.set_setting(&"pallet_boxes", 4 + tick % 5)
		if tick in [4400, 5700]:
			line.dispatch(true)
		line.advance(STEP)
		_check_invariants(line, tick)
	_check(line.forklift_deliveries > 8, "Stress run exercises repeat deliveries and dispatch")
	_check(line.cooked_deliveries > 5, "Stress run exercises multiple cart assignments")


func _check_invariants(line: Line, tick: int) -> void:
	var claimed: Array[StringName] = []
	var push_routes := 0
	for worker_id in line.floor_assignments:
		var job := line.floor_assignments[worker_id]
		_check(job.cart.id not in claimed and job.cart.owner == worker_id,
			"Unique cart ownership at tick %d" % tick)
		claimed.append(job.cart.id)
		if job.kind == Line.JobKind.MOVE_CART:
			push_routes += 1
		elif job.kind in [Line.JobKind.LOAD_OVEN, Line.JobKind.UNLOAD_OVEN]:
			_check(line.oven.owner == worker_id, "Unique oven handling reservation")
	_check(push_routes <= 1, "Shared cart aisle has at most one moving assignment")
	for cart in line.carts:
		_bounds(cart.stock, "Cart")
		_check(cart.owner == &"" or cart.id in claimed, "Cart has no orphaned task owner")
		_check(cart.position.distance_to(cart.previous_position) <= line.settings[&"floor_speed"] * STEP + 1e-4,
			"Cart moves no faster than its pusher")
	_check(line.hopper.quantity + line.hopper_reserved <= line.hopper.capacity + Line.EPSILON,
		"Ingredient reservations fit the hopper")
	for storage: Line.Storage in [line.hopper, line.oven.stock, line.cooked_input, line.coated_input]:
		_bounds(storage, "Station")
	_check(line.warehouse_count() + int(line.warehouse_reserved_slot >= 0)
		<= line.warehouse.size(), "Warehouse includes reservations in its bound")
	if line.warehouse_reserved_slot >= 0:
		_check(line.warehouse[line.warehouse_reserved_slot] == null, "Reserved slot is vacant")
	for pallet in line.staged_pallets:
		if pallet != null:
			_check(pallet.boxes > 0 and pallet.boxes <= pallet.target_boxes, "Pallet never overfills")
	_check(line.box_progress >= 0.0 and line.box_progress <= line.box_target, "In-progress carton stays bounded")
	_mass_balance(line, "All inventories at tick %d" % tick)


func _packing_line(input: float, free_slots: int = 0) -> Line:
	var line := Line.new()
	line.set_setting(&"hopper_capacity", 1.0)
	line.set_setting(&"coater_rate", 3600.0)
	line.set_setting(&"packing_rate", 7200.0)
	line.set_setting(&"box_kg", 2.0)
	line.set_setting(&"pallet_boxes", 2.0)
	for index in line.warehouse.size() - free_slots:
		var pallet := Line.Pallet.new(1)
		pallet.add_box(4.0)
		line.warehouse[index] = pallet
	# Seed cooked wafers to isolate the final stages in these unit scenarios.
	line.cooked_input.apply_transfer(input, 0.0)
	line.ingredients_taken = input + line.warehouse_mass()
	line.set_playing(true)
	return line


func _until(line: Line, condition: Callable, seconds: float, description: String) -> bool:
	for tick in ceili(seconds / STEP):
		if condition.call():
			return true
		line.advance(STEP)
	var reached: bool = condition.call()
	_check(reached, description)
	return reached


func _bounds(storage: Line.Storage, description: String) -> void:
	_check(storage.quantity >= 0.0 and storage.quantity <= storage.capacity,
		description + " inventory stays within capacity")


func _mass_balance(line: Line, description: String) -> void:
	_near(line.material_on_site() + line.dispatched_kg, line.ingredients_taken, description)


func _near(actual: float, expected: float, description: String) -> void:
	_check(absf(actual - expected) < 1e-6, "%s (got %.9f, expected %.9f)" % [description, actual, expected])


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		if _failures <= 30:
			printerr("FAIL: " + description)
