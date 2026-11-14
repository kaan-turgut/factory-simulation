extends SceneTree
## Run with: godot --headless --path . --script res://tests/worker_pace_test.gd
## Crew walking speeds are realistic and drop with the load being carried, pushed or pulled.

const Line = preload("res://simulation/production_line.gd")
const Operator = Line.Operator
const API = preload("res://agent/agent_api.gd")
const Save = preload("res://erp/save_game.gd")
const STEP := Line.STEP_SECONDS

var _failures := 0


func _initialize() -> void:
	_pace_functions()
	_defaults()
	_speeds_in_a_running_order()
	_old_saves()
	print("Worker pace: %d failures." % _failures)
	quit(int(_failures > 0))


func _pace_functions() -> void:
	_check(is_equal_approx(Operator.carry_pace(0.0), 1.0), "No load, no slowdown")
	_check(is_equal_approx(Operator.carry_pace(25.0), 0.8), "A 25 kg sack in both arms costs 20% of the pace")
	_check(Operator.cart_pace(0.0) < 1.0, "Even an empty cart is slower than walking")
	_check(Operator.cart_pace(0.0) > Operator.cart_pace(65.0), "A loaded cart is slower than an empty one")
	_check(Operator.cart_pace(1000.0) >= Operator.MIN_LOADED_PACE, "The slowdown has a floor")
	_check(Operator.jack_pace(500.0) < Operator.jack_pace(0.0), "A loaded pallet jack is slower than an empty one")
	_check(Operator.jack_pace(5000.0) >= Operator.MIN_JACK_PACE, "The pallet jack slowdown has a floor")


func _defaults() -> void:
	var line := Line.new()
	line.enable_erp()
	var walking: float = line.settings[&"floor_speed"]
	_check(walking >= 1.2 and walking <= 1.6, "Floor crew walk at a normal pace (%.2f m/s)" % walking)
	var platform: float = line.settings[&"platform_speed"]
	_check(platform >= 1.2 and platform <= 1.6, "Platform crew walk at a normal pace (%.2f m/s)" % platform)


## Every step is checked against the pace its situation allows. A step on which the state changed
## belongs to the previous state, so it is skipped.
func _speeds_in_a_running_order() -> void:
	var api := API.new()
	var line: Line = api.line
	var book = line.erp
	api.handle({"cmd": "create_demand", "args": {"code": "FG-1001", "boxes": 6, "due": 600}})
	api.handle({"cmd": "run_mrp", "args": {}})
	api.handle({"cmd": "convert_all", "args": {}})
	api.handle({"cmd": "set_auto_release", "args": {"enabled": true}})
	line.set_playing(true)
	var floor_speed: float = line.settings[&"floor_speed"]
	var platform_speed: float = line.settings[&"platform_speed"]
	var last := {}
	var top_walking := 0.0
	var top_empty_cart := 0.0
	var top_loaded_cart := 0.0
	var top_sack := 0.0
	var top_jack_loaded := 0.0
	var top_jack_empty := 0.0
	var wrong := []
	for tick in 8000:
		line.advance(STEP)
		for worker in line.platform_crew + line.floor_crew:
			var before = last.get(worker.id, -1)
			last[worker.id] = worker.state
			var speed := worker.position.distance_to(worker.previous_position) / STEP
			if before != worker.state or speed <= 0.001:
				continue
			if worker.state == Operator.State.WALKING and worker in line.floor_crew:
				top_walking = maxf(top_walking, speed)
				if speed > floor_speed + 1e-3:
					wrong.append("walking %.2f" % speed)
			elif worker.state == Operator.State.PUSHING and line.floor_assignments.has(worker.id):
				var load: float = line.floor_assignments[worker.id].cart.stock.quantity
				var allowed := floor_speed * Operator.cart_pace(load)
				if speed > allowed + 1e-3:
					wrong.append("pushing %.2f > %.2f" % [speed, allowed])
				if load > 40.0:
					top_loaded_cart = maxf(top_loaded_cart, speed)
				else:
					top_empty_cart = maxf(top_empty_cart, speed)
			elif worker.state == Operator.State.CARRYING and worker in line.platform_crew:
				var allowed := platform_speed * Operator.carry_pace(worker.cargo_kg)
				if speed > allowed + 1e-3:
					wrong.append("carrying %.2f > %.2f" % [speed, allowed])
				top_sack = maxf(top_sack, speed)
		var handler = book.material_handler
		var handler_before = last.get(&"handler", -1)
		last[&"handler"] = handler.state
		if handler.state == Operator.State.MOVING_PALLET_JACK and handler_before == handler.state:
			var speed: float = handler.position.distance_to(handler.previous_position) / STEP
			if speed > 0.001:
				if int(book.shipment.get("phase", -1)) >= 1:
					top_jack_loaded = maxf(top_jack_loaded, speed)
				else:
					top_jack_empty = maxf(top_jack_empty, speed)
		if book.orders.values().all(func(order: Dictionary) -> bool: return order.status == "Completed"):
			break
	_check(wrong.is_empty(), "No step is faster than its load allows: " + ", ".join(wrong.slice(0, 4)))
	_check(top_walking > 0.0 and top_walking <= floor_speed + 1e-3, "Floor crew walk at their set speed (%.2f)" % top_walking)
	_check(top_loaded_cart > 0.0 and top_loaded_cart < top_walking - 0.2 and top_loaded_cart < 1.1,
		"A loaded cart moves at about a metre a second (%.2f vs %.2f walking)" % [top_loaded_cart, top_walking])
	_check(top_empty_cart == 0.0 or top_empty_cart < top_walking, "An empty cart is slower than walking too")
	_check(top_sack > 0.0 and top_sack < platform_speed - 0.1, "A carried sack slows the platform crew (%.2f vs %.2f)" % [top_sack, platform_speed])
	_check(top_jack_loaded > 0.0 and top_jack_empty > 0.0 and top_jack_loaded < top_jack_empty - 0.05,
		"A loaded pallet jack is slower than an empty one (%.2f vs %.2f)" % [top_jack_loaded, top_jack_empty])
	_check(top_jack_empty <= 1.4 + 1e-3, "The material handler walks at a normal pace (%.2f)" % top_jack_empty)


func _old_saves() -> void:
	var line := Line.new()
	line.enable_erp()
	var data := Save.snapshot(line)
	data.settings[&"floor_speed"] = 2.4
	data.settings[&"platform_speed"] = 1.8
	data.erase("pace")
	var restored := Save.restore(data.duplicate(true))
	_check(restored.error.is_empty(), "An old save loads")
	if restored.error.is_empty():
		_check(is_equal_approx(restored.line.settings[&"floor_speed"], 1.4)
			and is_equal_approx(restored.line.settings[&"platform_speed"], 1.4),
			"Untouched old crew speeds move to the realistic pace")
	data.settings[&"floor_speed"] = 2.0
	data.erase("pace")
	restored = Save.restore(data.duplicate(true))
	_check(restored.error.is_empty() and is_equal_approx(restored.line.settings[&"floor_speed"], 2.0),
		"A speed the owner chose is kept")
	data.settings[&"floor_speed"] = 2.4
	data.pace = Save.WALK_PACE_VERSION
	restored = Save.restore(data.duplicate(true))
	_check(restored.error.is_empty() and is_equal_approx(restored.line.settings[&"floor_speed"], 2.4),
		"A current save keeps 2.4 m/s if the owner set it")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
