extends SceneTree
## Agent API: scenario loading, planning through the ERP, event-driven time, snapshots and scoring.

const API = preload("res://agent/agent_api.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var started := Time.get_ticks_msec()
	_rejections()
	_full_shift()
	_snapshots()
	print("Agent API: %d checks, %d failures (%.1f s)." % [_checks, _failures, (Time.get_ticks_msec() - started) / 1000.0])
	quit(int(_failures > 0))


func _call(api: API, cmd: String, args: Dictionary = {}) -> Dictionary:
	# Round-trip through JSON, as a remote agent would.
	var request: Variant = JSON.parse_string(JSON.stringify({"cmd": cmd, "args": args}))
	var response: Dictionary = api.handle(request)
	return JSON.parse_string(JSON.stringify(response))


func _rejections() -> void:
	var api := API.new()
	_check(_call(api, "describe").commands.has("run_until"), "Describe lists commands")
	_check(not _call(api, "fly").ok, "Unknown command is rejected")
	var created := _call(api, "create_order", {"code": "NOPE", "quantity": 5})
	_check(not created.ok and not String(created.error).is_empty(), "ERP errors are returned to the agent")
	_check(not _call(api, "release", {"id": "MO-404"}).ok, "Releasing a missing order fails")
	_check(not _call(api, "advance", {"seconds": -1}).ok, "Negative time is rejected")


func _plan_everything(api: API) -> int:
	var converted := 0
	for attempt in 40:
		var mrp := _call(api, "run_mrp")
		if mrp.proposals.is_empty():
			break
		var result := _call(api, "convert_proposal", {"id": mrp.proposals[0].id})
		_check(result.ok, "Convert %s: %s" % [mrp.proposals[0].id, result.get("error", "")])
		if not result.ok:
			break
		converted += 1
	return converted


func _full_shift() -> void:
	var api := API.new()
	var loaded := _call(api, "load_scenario", {"path": "res://scenarios/filled_wafer_shift.json"})
	_check(loaded.ok and loaded.demands.size() == 4, "Load scenario with four demands: " + String(loaded.get("error", "")))
	_check(_call(api, "material", {"code": "FG-2001", "quantity": 48}).options.size() > 0, "Material lookup lists eligible work centers")
	var converted := _plan_everything(api)
	_check(converted >= 4, "MRP proposals convert into orders (%d)" % converted)
	var orders: Array = _call(api, "orders", {"status": "open"}).orders
	_check(orders.size() > 0 and orders.all(func(o: Dictionary) -> bool: return o.status == "Created"), "Converted orders wait as Created")
	_call(api, "set_auto_release", {"enabled": true})
	var horizon: float = loaded.horizon_seconds
	var completed := 0
	for hop in 400:
		var step := _call(api, "run_until", {"max_seconds": horizon - api.line.erp.now, "stop_on": ["order_completed"]})
		_check(step.ok, "run_until succeeds")
		completed += step.events.filter(func(e: Dictionary) -> bool: return e.kind == "order_completed").size()
		if not step.stopped_by_event or api.line.erp.now >= horizon - 0.5:
			break
	_check(completed > 0, "Orders complete during the shift (%d)" % completed)
	var centers: Array = _call(api, "work_centers").work_centers
	var working: Array = centers.filter(func(c: Dictionary) -> bool: return c.seconds.working > 0.0)
	_check(working.size() >= 3, "Work center accounting records working time on several centers")
	for center in centers:
		var total := 0.0
		for value in center.seconds.values():
			total += value
		_check(absf(total - api.monitor.observed) < 0.5, "Time buckets add up for " + center.id)
	var score := _call(api, "score")
	print("  filled wafer shift score: ", JSON.stringify(score))
	_check(score.on_time + score.late + score.open_overdue <= score.demands, "Score counts each demand once")
	_check(score.finished_boxes.size() > 0, "Finished boxes are reported")
	_call(api, "log_decision", {"text": "Test decision"})
	_check(_call(api, "run_log").log.any(func(r: Dictionary) -> bool: return r.kind == "decision"), "Decisions are logged")


func _snapshots() -> void:
	var api := API.new()
	_call(api, "load_scenario", {"path": "res://scenarios/constrained_shift.json"})
	_check(is_equal_approx(api.line.operating_factors[&"Oven"], 0.5), "Scenario operating factor applied")
	_plan_everything(api)
	_call(api, "set_auto_release", {"enabled": true})
	_check(_call(api, "snapshot", {"name": "base"}).ok, "Snapshot saved")
	_call(api, "advance", {"seconds": 1800})
	var after := _call(api, "status")
	var journal_size: int = api.line.erp.movements.size()
	_check(_call(api, "restore", {"name": "base"}).ok, "Snapshot restored")
	_check(is_zero_approx(api.line.erp.now) and api.monitor.observed == 0.0, "Restore rewinds the clock and monitor")
	_call(api, "advance", {"seconds": 1800})
	_check(api.line.erp.movements.size() == journal_size and _call(api, "status").orders_by_status == after.orders_by_status,
		"Replaying from a snapshot is deterministic")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
