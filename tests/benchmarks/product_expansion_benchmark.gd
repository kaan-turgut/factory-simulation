extends SceneTree
## Headless by default. Pass "filled" to include the concurrent product-family workload.
const Line = preload("res://simulation/production_line.gd")
const Plan = preload("res://erp/mrp.gd")
const FactoryScene = preload("res://scenes/factory.tscn")

var _error := ""


func _initialize() -> void:
	var mode := OS.get_cmdline_user_args()
	if "render" in mode:
		_rendered.call_deferred("filled" in mode)
	else:
		_headless("filled" in mode)


func _prepare(line: Line, filled: bool) -> bool:
	if line.erp == null or not line.validation_error.is_empty():
		_error = line.validation_error
		return false
	var book := line.erp
	var demand: Array = [["FG-2001", 40, 4200], ["FG-2005", 24, 4300]] if filled else [["FG-1001", 8, 900]]
	for row in demand:
		var result := book.create_demand(row[0], row[1], row[2])
		if not result.error.is_empty():
			_error = result.error
			return false
	var plan := Plan.new()
	plan.run(book, {})
	for attempt in 40:
		if plan.proposals.is_empty():
			book.auto_release = true
			line.set_playing(true)
			return true
		var proposal: Dictionary = plan.proposals.values()[0]
		var result := plan.convert(proposal.id, book, {})
		if not result.error.is_empty():
			_error = result.error
			return false
	_error = "Benchmark order conversion did not converge."
	return false


func _headless(filled: bool) -> void:
	for count in [1, 4, 8]:
		var lines: Array[Line] = []
		for index in count:
			var line := Line.new()
			line.enable_erp()
			if not _prepare(line, filled):
				printerr(_error)
				quit(1)
				return
			lines.append(line)
		var durations := PackedFloat64Array()
		var max_orders := 0
		var max_workers := 0
		var push_ticks := 0
		var active_ticks := 0
		for tick in (88000 if filled else 12000):
			var started := Time.get_ticks_usec()
			for line in lines:
				line.advance(Line.STEP_SECONDS)
			var duration := Time.get_ticks_usec() - started
			var active := false
			for line in lines:
				active = active or not line.runs.is_empty()
				max_orders = maxi(max_orders, line.runs.size())
				max_workers = maxi(max_workers, line.floor_assignments.size())
				if line.warehouse_count() >= int(line.settings[&"warehouse_capacity"]):
					line.dispatch(true)
			for worker in lines[0].floor_crew:
				push_ticks += int(worker.state == Line.Operator.State.PUSHING)
			if active:
				durations.append(duration)
				active_ticks += 1
		print("BENCH ", JSON.stringify({"case": "filled" if filled else "classic", "lines": count,
			"active_tick_us": _stats(durations), "active_ticks": active_ticks, "peak_orders": max_orders,
			"peak_workers": max_workers, "worker_push_seconds": push_ticks * Line.STEP_SECONDS,
			"fg_kg": lines[0].warehouse_mass() + lines[0].dispatched_kg}))
	quit()


func _rendered(filled: bool) -> void:
	root.set_flag(Window.FLAG_NO_FOCUS, true)
	var factory := FactoryScene.instantiate()
	factory.resume_saved = false
	root.add_child(factory)
	factory.set_process(false)
	var line: Line = factory.line
	if not _prepare(line, filled):
		printerr(_error)
		quit(1)
		return
	for interval in (12000 if filled else 3000):
		line.advance(1.0)
		if filled:
			if line.runs.size() >= 2 and line.floor_assignments.size() >= 2:
				break
		elif line.packer.actual_rate > 0:
			break
	line.set_multiplier(20)
	var renderer := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(renderer, true)
	var render := PackedFloat64Array()
	var frames := 0
	var started := 0
	var drawn := 0
	for frame in 195:
		if frame == 45:
			started = Time.get_ticks_usec()
			drawn = Engine.get_frames_drawn()
		line.advance(1.0 / 30.0)
		factory._refresh()
		factory.floor_view.animate(line, 1.0 / 30.0)
		await process_frame
		if frame >= 45:
			render.append(RenderingServer.viewport_get_measured_render_time_cpu(renderer))
		frames += 1
	print("BENCH ", JSON.stringify({"case": "native concurrent filled orders" if filled else "native classic packaging", "frames": frames - 45,
		"fps": (Engine.get_frames_drawn() - drawn) * 1000000.0 / (Time.get_ticks_usec() - started),
		"render_cpu_ms": _stats(render), "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"memory_mib": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0}))
	quit()


func _stats(values: PackedFloat64Array) -> Array:
	if values.is_empty():
		return []
	values.sort()
	return [values[values.size() / 2], values[floori(values.size() * 0.95)]]
