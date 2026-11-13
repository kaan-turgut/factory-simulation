extends SceneTree
## Agent API: scenario loading, planning through the ERP, event-driven time, snapshots and scoring.

const API = preload("res://agent/agent_api.gd")
const Link = preload("res://agent/agent_link.gd")
const Line = preload("res://simulation/production_line.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var started := Time.get_ticks_msec()
	_rejections()
	_full_shift()
	_snapshots()
	await _live()
	await _live_link()
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
	var mrp := _call(api, "run_mrp")
	_check(mrp.ok and mrp.planned_orders.size() > 0, "MRP returns planned orders")
	_check(mrp.planned_orders.all(func(p: Dictionary) -> bool: return String(p.number).begins_with("PLO-")), "Planned orders are numbered")
	var result := _call(api, "convert_all")
	_check(result.ok and result.failed.is_empty(), "Convert all planned orders: " + JSON.stringify(result.get("failed", [])))
	_check(_call(api, "run_mrp").planned_orders.is_empty(), "No planned orders remain after converting all")
	return result.created.size()


func _full_shift() -> void:
	var api := API.new()
	var loaded := _call(api, "load_scenario", {"path": "res://scenarios/filled_wafer_12h.json"})
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
	print("  filled wafer run score: ", JSON.stringify(score))
	_check(score.on_time + score.late + score.open_overdue <= score.demands, "Score counts each demand once")
	_check(score.finished_boxes.size() > 0, "Finished boxes are reported")
	_call(api, "log_decision", {"text": "Test decision"})
	_check(_call(api, "run_log").log.any(func(r: Dictionary) -> bool: return r.kind == "decision"), "Decisions are logged")


func _snapshots() -> void:
	var api := API.new()
	_call(api, "load_scenario", {"path": "res://scenarios/constrained_12h.json"})
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


## A game frame: advance the shown line in real time and report played simulation time.
func _frame(api: API, delta: float) -> Dictionary:
	var before: int = api.line.elapsed_ticks
	api.line.advance(delta)
	return api.live_step((api.line.elapsed_ticks - before) * Line.STEP_SECONDS)


func _live() -> void:
	var shown := Line.new()
	shown.enable_erp()
	var api := API.new(shown)
	var replaced := []
	api.on_line_replaced = func(next: Line) -> void: replaced.append(next)
	_check(api.live and api.line == shown and not shown.playing, "Live API attaches to the shown line")
	var loaded := api.handle({"cmd": "load_scenario", "args": {"path": "res://scenarios/filled_wafer_12h.json"}})
	_check(loaded.ok and replaced.size() == 1 and replaced[0] == api.line and api.line != shown, "Live scenario load hands the game a new line")
	_check(not api.line.playing and api.line.erp.demands.size() == 4, "New live shift starts paused with its demands")
	api.handle({"cmd": "convert_all", "args": {}})
	_check(api.handle({"cmd": "set_speed", "args": {"multiplier": 60}}).ok and api.line.multiplier == 60, "Live speed can be set to 60x")
	_check(not api.handle({"cmd": "set_speed", "args": {"multiplier": 7}}).ok, "Unsupported speed is rejected")
	var pending := api.handle({"cmd": "advance", "args": {"seconds": 120}})
	_check(pending.get("pending", false) and api.line.playing and api.busy(), "Live advance plays the shift and replies later")
	_check(not api.handle({"cmd": "advance", "args": {"seconds": 5}}).ok, "A second time command waits for the first")
	_check(api.handle({"cmd": "status"}).ok, "Observations work while time runs")
	var reply := {}
	for frame in 400:
		reply = _frame(api, 1.0 / 30.0)
		if not reply.is_empty():
			break
	_check(not reply.is_empty() and reply.advanced >= 120.0 and reply.advanced < 124.0,
		"Advance replies once the game has played 120 s (%s)" % reply.get("advanced", -1))
	_check(not api.line.playing and not api.busy(), "Agent-paced play pauses after the command")
	_check(api.monitor.observed >= 120.0, "Work center accounting follows played time")
	api.handle({"cmd": "set_auto_release", "args": {"enabled": true}})
	pending = api.handle({"cmd": "run_until", "args": {"max_seconds": 43200, "stop_on": ["order_released"]}})
	reply = {}
	for frame in 30000:
		reply = _frame(api, 1.0 / 30.0)
		if not reply.is_empty():
			break
	_check(reply.get("stopped_by_event", false) and reply.events.any(func(e: Dictionary) -> bool: return e.kind == "order_released")
		and reply.advanced < 43000.0, "Live run_until stops at the first release: %s" % JSON.stringify(reply).left(300))
	_frame(api, 0.5)
	_check(api.handle({"cmd": "snapshot", "args": {"name": "s"}}).ok and api.handle({"cmd": "restore", "args": {"name": "s"}}).ok
		and replaced.size() == 2, "Live restore hands the rewound line to the game")
	var saved := api.handle({"cmd": "save_instance", "args": {"path": "user://agent_test.save"}})
	_check(saved.ok and FileAccess.file_exists("user://agent_test.save"), "Save the agent's run to a named file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://agent_test.save"))
	# Saving as an instance goes to a test folder, never the player's list.
	API.Instances.directory = "user://agent_test_instances"
	API.Instances.import_legacy = false
	var listed := api.handle({"cmd": "save_instance", "args": {"name": "Agent test run"}})
	_check(listed.ok and API.Instances.find(listed.instance).name == "Agent test run"
		and FileAccess.file_exists(API.Instances.path(listed.instance)), "Save the agent's run as a named simulation instance")
	_check(not api.handle({"cmd": "save_instance", "args": {"name": "Agent test run"}}).ok, "Instance names stay unique")
	for file in DirAccess.get_files_at("user://agent_test_instances"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://agent_test_instances".path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://agent_test_instances"))
	API.Instances.directory = "user://instances"


func _live_link() -> void:
	var shown := Line.new()
	shown.enable_erp()
	var link := Link.new(API.new(shown))
	link.allow_shutdown = false
	var port := 18765
	_check(link.listen(port).is_empty(), "Live link listens")
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", port)
	var replies: Array = []
	var send := func(cmd: String, args: Dictionary) -> void:
		client.put_data((JSON.stringify({"cmd": cmd, "args": args}) + "\n").to_utf8_buffer())
	var buffer := PackedByteArray()
	for frame in 600:
		await process_frame
		client.poll()
		if frame == 5:
			send.call("advance", {"seconds": 10})
		if frame == 6:
			send.call("shutdown", {})
		var before: int = link.api.line.elapsed_ticks
		link.api.line.advance(1.0 / 30.0 * 20.0)
		link.tick((link.api.line.elapsed_ticks - before) * Line.STEP_SECONDS)
		link.poll()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED and client.get_available_bytes() > 0:
			buffer.append_array(client.get_partial_data(client.get_available_bytes())[1])
		var text := buffer.get_string_from_utf8()
		replies = Array(text.split("\n", false)).map(func(row: String) -> Variant: return JSON.parse_string(row))
		if replies.size() >= 2:
			break
	_check(replies.size() >= 2 and replies.any(func(r: Dictionary) -> bool: return r.get("advanced", 0.0) >= 10.0),
		"Live link replies to advance after the game played it: " + str(replies))
	_check(replies.any(func(r: Dictionary) -> bool: return not r.ok and "stays open" in String(r.get("error", ""))) and not link.shutdown_requested,
		"An agent cannot shut the live game down")
	client.disconnect_from_host()
	link.stop()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL: " + message)
