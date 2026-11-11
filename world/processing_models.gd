extends RefCounted
## Visual-only mechanics for the spreader, cutter, cooling tunnel and packaging lines.

const Primitives = preload("res://world/primitives.gd")

const FRAME := Color("#344752")
const STAINLESS := Color("#afbec2")
const BRUSHED := Color("#728791")
const SHELL := Color("#d9e0df")
const BELT := Color("#253941")
const RUBBER := Color("#202f37")
const SAFETY := Color("#e2ad54")
const SCREEN := Color("#8ed3c6")
const WAFER := Color("#ca9250")
const FILLING := Color("#eee1bd")
const BED_Y := 0.97

var _draw: Primitives
var _root: Node3D
var _accent: Color
var _length: float
var _phase := 0.0
var _mode: StringName
var _rollers: Array[Node3D] = []
var _ram: Node3D
var _film: Node3D
var _label_feed: Node3D
var _loads: Array[Node3D] = []
var _finished: Array[Node3D] = []
var beacon_mount: Vector3


func _init(draw: Primitives, parent: Node3D, mode: StringName, length: float, accent: Color) -> void:
	_draw = draw
	_root = _pivot(parent, Vector3.ZERO, "ProcessingModel")
	_accent = accent
	_length = length
	_mode = mode
	# Use more of the existing bays. Line 01 keeps the height of its linked carton belt.
	_root.scale = Vector3(1.0, 1.0 if mode == &"Packer" else 1.16, 1.28)
	_chassis()
	_conveyor()
	match mode:
		&"Spreader": _spreader()
		&"Cutter": _cutter()
		&"CoolingTunnel": _tunnel()
		_: _packaging()
	beacon_mount *= _root.scale
	_draw.batch_static(_root)


func belt_load_height() -> float:
	return (BED_Y + 0.055) * _root.scale.y


func animate(working: bool, delta: float) -> void:
	if not working or delta <= 0.0:
		return
	_phase += delta
	match _mode:
		&"Spreader":
			_rollers[0].rotate_z(-delta * 3.8)
			_rollers[1].rotate_z(-delta * 4.4)
		&"Cutter":
			# Dwell above the belt, then lower the blade and retract it.
			var stroke := pow(sin(fposmod(_phase * 1.7, 1.0) * PI), 5.0)
			_ram.position.y = 1.52 - 0.24 * stroke
		&"CoolingTunnel":
			for fan in _rollers:
				fan.rotate_y(-delta * 8.0)
		_:
			_film.rotate_z(delta * 3.6)
			_label_feed.rotate_z(-delta * 4.2)
			_ram.position.y = 1.64 - 0.22 * pow(sin(_phase * PI * 1.5), 4.0)
	for index in _loads.size():
		var progress := fposmod(_phase * 0.43 + float(index) / _loads.size(), 1.0)
		_loads[index].position.x = lerpf(-_length * 0.5 + 0.28, _length * 0.5 - 0.28, progress)
		_finished[index].visible = _loads[index].position.x > 0.35


func _chassis() -> void:
	var span := _length - 0.34
	_box(Vector3(0, 0.11, 0), Vector3(span, 0.18, 2.56), FRAME)
	_box(Vector3(0, 0.43, 0), Vector3(span - 0.22, 0.49, 2.28), BRUSHED)
	for side: float in [-1.0, 1.0]:
		_box(Vector3(0, 0.59, side * 1.14), Vector3(span - 0.24, 0.14, 0.054), _accent)
		for x: float in [-span * 0.28, 0.0, span * 0.28]:
			_box(Vector3(x, 0.35, side * 1.154), Vector3(span * 0.23, 0.28, 0.057), SHELL)
			_box(Vector3(x + span * 0.065, 0.38, side * 1.19), Vector3(0.13, 0.038, 0.028), FRAME)


func _conveyor() -> void:
	for x: float in [-_length * 0.5 + 0.55, _length * 0.5 - 0.55]:
		for z: float in [-0.70, 0.70]:
			_box(Vector3(x, 0.48, z), Vector3(0.14, 0.89, 0.14), STAINLESS)
			_box(Vector3(x, 0.09, z), Vector3(0.27, 0.13, 0.27), RUBBER)
		_box(Vector3(x, 0.50, 0), Vector3(0.13, 0.12, 1.48), FRAME)
	_box(Vector3(0, BED_Y - 0.10, 0), Vector3(_length - 0.04, 0.22, 1.54), FRAME)
	_box(Vector3(0, BED_Y + 0.015, 0), Vector3(_length - 0.12, 0.06, 1.30), BELT)
	for z: float in [-0.72, 0.72]:
		_box(Vector3(0, BED_Y + 0.08, z), Vector3(_length, 0.11, 0.12), STAINLESS)
		_box(Vector3(0, BED_Y - 0.115, z * 1.09), Vector3(_length - 0.13, 0.10, 0.025), _accent)
	for end: float in [-1.0, 1.0]:
		var x := end * (_length * 0.5 - 0.13)
		_cross_cylinder(_root, Vector3(x, BED_Y + 0.013, 0), 0.062, 1.29, BRUSHED)
		_box(Vector3(x, BED_Y - 0.06, 0.80), Vector3(0.18, 0.16, 0.12), STAINLESS)


func _spreader() -> void:
	# Jacketed cream tank, tapered discharge and metering head above an open sheet belt.
	var tank := Vector3(-1.0, 1.93, -0.80)
	var valve := Vector3(tank.x, 1.23, tank.z)
	var bend := Vector3(-0.28, valve.y, valve.z)
	_box(Vector3(tank.x, 0.73, tank.z), Vector3(1.28, 0.93, 0.96), _accent)
	_draw.cylinder(_root, tank, 0.66, 0.76, STAINLESS)
	_draw.cylinder(_root, tank - Vector3.UP * 0.52, 0.25, 0.32, BRUSHED, 0.63)
	_draw.cylinder(_root, tank + Vector3.UP * 0.39, 0.69, 0.10, FRAME)
	_draw.cylinder(_root, tank + Vector3(0.09, 0.48, -0.09), 0.28, 0.11, _accent)
	_box(tank + Vector3(0.26, 0.0, 0.61), Vector3(0.08, 0.50, 0.065), FILLING)
	_pipe(tank - Vector3.UP * 0.59, valve, 0.086)
	_pipe(valve, bend, 0.086)
	_pipe(bend, Vector3(-0.28, 1.48, -0.67), 0.086)
	for z: float in [-0.78, 0.78]:
		_box(Vector3(0.06, 1.38, z), Vector3(1.04, 0.76, 0.15), _accent)
	_box(Vector3(-0.14, 1.67, 0), Vector3(0.72, 0.17, 1.70), SHELL)
	_box(Vector3(-0.28, 1.54, 0), Vector3(0.18, 0.15, 1.24), FILLING)
	_rollers.append(_roller(Vector3(-0.32, 1.25, 0), 0.135))
	_rollers.append(_roller(Vector3(0.54, 1.21, 0), 0.114))
	_box(Vector3(0.38, 1.29, 0.95), Vector3(0.54, 0.42, 0.31), FRAME)
	_controls(Vector3(1.53, 1.48, 0.94))
	beacon_mount = Vector3(1.53, 1.68, 0.94)
	_load_train(3, Vector3(0.58, 0.06, 0.97), &"spread")


func _cutter() -> void:
	# Bridge guides, cylinder and guarded guillotine.
	for z: float in [-0.89, 0.89]:
		_box(Vector3(0, 1.48, z), Vector3(0.39, 1.39, 0.26), FRAME)
		_box(Vector3(0.66, 1.24, z), Vector3(0.81, 0.43, 0.10), _accent)
		_box(Vector3(-0.68, 1.35, z), Vector3(0.74, 0.64, 0.10), SHELL)
		_box(Vector3(-0.68, 1.34, z * 1.069), Vector3(0.58, 0.12, 0.026), BRUSHED)
	_box(Vector3(0, 2.12, 0), Vector3(1.16, 0.45, 2.16), _accent)
	_box(Vector3(0, 2.37, 0), Vector3(1.04, 0.08, 1.87), STAINLESS)
	_draw.cylinder(_root, Vector3(0, 1.91, 0), 0.21, 0.41, FRAME)
	for z: float in [-0.54, 0.54]:
		_draw.cylinder(_root, Vector3(0, 1.70, z), 0.046, 0.62, STAINLESS)
	_ram = _pivot(_root, Vector3(0, 1.52, 0), "CuttingHead")
	_draw.box(_ram, Vector3.ZERO, Vector3(0.33, 0.15, 1.41), BRUSHED)
	_draw.box(_ram, Vector3(0, -0.13, 0), Vector3(0.068, 0.21, 1.21), SHELL)
	for index in 6:
		_draw.box(_ram, Vector3(0, -0.24, -0.52 + index * 0.21),
			Vector3(0.072, 0.05, 0.16), STAINLESS)
	_draw.batch_static(_ram)
	_hazard_strip(Vector3(0, 1.96, 1.09), 1.04)
	_box(Vector3(-0.96, 0.51, -1.07), Vector3(1.26, 0.73, 0.56), SHELL)
	_controls(Vector3(1.40, 1.45, 0.93))
	beacon_mount = Vector3(0, 2.41, 0.73)
	_load_train(3, Vector3(0.53, 0.066, 0.98), &"cut")


func _tunnel() -> void:
	# Insulated chambers with a continuous inspection opening above the belt.
	for index in 4:
		var x := -2.43 + index * 1.62
		_box(Vector3(x, 2.10, 0), Vector3(1.55, 0.26, 2.31), _accent)
		_box(Vector3(x, 1.48, -1.05), Vector3(1.54, 1.12, 0.22), SHELL)
		_box(Vector3(x, 1.83, 1.05), Vector3(1.54, 0.42, 0.22), SHELL)
		_box(Vector3(x, 1.03, 1.05), Vector3(1.54, 0.20, 0.22), _accent)
		for side: float in [-1.0, 1.0]:
			_box(Vector3(x + side * 0.74, 1.51, 1.06), Vector3(0.10, 1.10, 0.23), STAINLESS)
		_box(Vector3(x + 0.51, 1.85, 1.18), Vector3(0.19, 0.040, 0.030), FRAME)
	for end: float in [-1.0, 1.0]:
		_box(Vector3(end * 3.20, 1.82, 0), Vector3(0.19, 0.51, 2.08), BRUSHED)
		for z: float in [-0.98, 0.98]:
			_box(Vector3(end * 3.20, 1.37, z), Vector3(0.18, 0.87, 0.16), FRAME)
		for index in 5:
			_box(Vector3(end * 3.24, 1.52, -0.48 + index * 0.24),
				Vector3(0.04, 0.32, 0.21), BELT)
	for x: float in [-1.60, 1.60]:
		_draw.cylinder(_root, Vector3(x, 2.27, 0.08), 0.55, 0.13, FRAME)
		var fan := _pivot(_root, Vector3(x, 2.35, 0.08), "CoolingFan")
		_draw.cylinder(fan, Vector3.ZERO, 0.12, 0.060, STAINLESS)
		for index in 5:
			var angle := index * TAU / 5
			var blade := _draw.box(fan, Vector3(0.28, 0, 0).rotated(Vector3.UP, angle),
				Vector3(0.38, 0.045, 0.13), STAINLESS)
			blade.rotation.y = angle + 0.22
		_draw.batch_static(fan)
		_rollers.append(fan)
	_controls(Vector3(2.73, 1.41, 1.25))
	beacon_mount = Vector3(2.73, 2.23, 0.82)


func _packaging() -> void:
	# Film-fed wrapper with a sealing station and downstream carton transfer.
	for x: float in [-1.12, 1.12]:
		for z: float in [-0.93, 0.93]:
			_box(Vector3(x, 1.53, z), Vector3(0.18, 1.18, 0.20), BRUSHED)
	_box(Vector3(0, 2.12, 0), Vector3(2.50, 0.55, 2.08), _accent)
	_box(Vector3(0, 2.43, 0), Vector3(2.32, 0.072, 1.90), SHELL)
	_box(Vector3(-0.55, 1.38, -0.59), Vector3(0.76, 0.54, 0.48), SHELL)
	_box(Vector3(0.08, 1.43, -0.91), Vector3(1.99, 0.78, 0.13), FRAME)
	_box(Vector3(0.71, 1.74, 0.86), Vector3(0.39, 0.13, 0.16), SAFETY)
	_ram = _pivot(_root, Vector3(0.30, 1.64, 0), "SealingJaw")
	_draw.box(_ram, Vector3.ZERO, Vector3(0.26, 0.23, 1.19), STAINLESS)
	_draw.box(_ram, Vector3(0, -0.145, 0), Vector3(0.14, 0.076, 1.16), SAFETY)
	_film = _reel(Vector3(-1.56, 1.91, -0.67), 0.40, 0.72, SHELL)
	_label_feed = _reel(Vector3(1.32, 1.60, -0.80), 0.23, 0.37, FILLING)
	var web := _box(Vector3(-1.20, 1.56, -0.51), Vector3(0.49, 0.02, 0.60), STAINLESS)
	web.rotation.z = -0.84
	_box(Vector3(1.40, 1.10, 0), Vector3(0.36, 0.12, 1.42), BRUSHED)
	_box(Vector3(1.52, 0.53, -0.62), Vector3(0.91, 0.67, 0.55), _accent)
	_controls(Vector3(0.95, 1.59, 1.12))
	beacon_mount = Vector3(0.91, 2.466, 0.72)
	_load_train(3, Vector3(0.43, 0.11, 0.51), &"pack")


func _load_train(count: int, size: Vector3, finish: StringName) -> void:
	for index in count:
		var item := _pivot(_root, Vector3(-_length * 0.5 + (index + 0.5) * _length / count,
			BED_Y + 0.05, 0), "BeltLoad")
		item.scale = Vector3.ONE / _root.scale
		_loads.append(item)
		var detail := _pivot(item, Vector3.ZERO, "FinishedDetail")
		_finished.append(detail)
		_draw.box(item, Vector3.UP * size.y * 0.5, size, WAFER)
		if finish == &"cut":
			for z: float in [-0.29, 0.0, 0.29]:
				_draw.box(detail, Vector3(0, size.y + 0.005, z), Vector3(size.x, 0.013, 0.030), BELT)
			_draw.batch_static(detail)
		elif finish == &"pack":
			_draw.box(detail, Vector3(0, 0.092, 0), Vector3(0.47, 0.18, 0.55), _accent.lightened(0.19))
			_draw.box(detail, Vector3(0.09, 0.186, 0), Vector3(0.075, 0.013, 0.47), SHELL)
		else:
			_draw.box(detail, Vector3(0, 0.075, 0), Vector3(size.x, 0.032, size.z), FILLING)
			_draw.box(detail, Vector3(0, 0.105, 0), Vector3(size.x, 0.033, size.z), WAFER)
		item.hide()


func show_loads(working: bool) -> void:
	for item in _loads:
		item.visible = working


func _roller(at: Vector3, radius: float) -> Node3D:
	var roller := _pivot(_root, at, "MeteringRoller")
	_cross_cylinder(roller, Vector3.ZERO, radius, 1.26, BRUSHED)
	for index in 4:
		var angle := index * PI * 0.5
		var rib := _draw.box(roller, Vector3(radius, 0, 0).rotated(Vector3.BACK, angle),
			Vector3(0.024, 0.029, 1.25), STAINLESS)
		rib.rotation.z = angle
	_draw.batch_static(roller)
	return roller


func _reel(at: Vector3, radius: float, width: float, tint: Color) -> Node3D:
	var reel := _pivot(_root, at, "FeedReel")
	_cross_cylinder(reel, Vector3.ZERO, radius, width, tint)
	for z: float in [-1.0, 1.0]:
		_cross_cylinder(reel, Vector3(0, 0, z * (width + 0.02) * 0.5), radius * 0.81, 0.04, BRUSHED)
		_cross_cylinder(reel, Vector3(0, 0, z * (width + 0.12) * 0.5), radius * 0.25, 0.07, FRAME)
	_draw.box(reel, Vector3(0, radius * 0.55, width * 0.5 + 0.04),
		Vector3(0.055, radius * 0.46, 0.018), SAFETY)
	_draw.batch_static(reel)
	return reel


func _controls(at: Vector3) -> void:
	_box(Vector3(at.x, at.y * 0.5, at.z), Vector3(0.095, at.y, 0.095), BRUSHED)
	_box(at, Vector3(0.53, 0.40, 0.17), FRAME)
	_box(at + Vector3(0, 0.043, 0.089), Vector3(0.38, 0.17, 0.025), SCREEN)
	_box(at + Vector3(0.13, -0.12, 0.095), Vector3(0.074, 0.068, 0.025), SAFETY)


func _hazard_strip(at: Vector3, length: float) -> void:
	_box(at, Vector3(length, 0.11, 0.034), SAFETY)
	for index in floori(length / 0.11):
		var stripe := _box(at + Vector3(-length * 0.5 + 0.06 + index * 0.11, 0, 0.024),
			Vector3(0.037, 0.09, 0.015), FRAME)
		stripe.rotation.z = 0.37


func _pipe(from: Vector3, to: Vector3, radius: float) -> void:
	var delta := to - from
	var tube := _draw.cylinder(_root, from + delta * 0.5, radius, delta.length(), BRUSHED)
	tube.quaternion = Quaternion(Vector3.UP, delta.normalized())


func _cross_cylinder(parent: Node3D, at: Vector3, radius: float, width: float, tint: Color) -> void:
	_draw.cylinder(parent, at, radius, width, tint).rotation.x = PI * 0.5


func _box(at: Vector3, size: Vector3, tint: Color) -> MeshInstance3D:
	return _draw.box(_root, at, size, tint)


func _pivot(parent: Node3D, at: Vector3, title: String) -> Node3D:
	var node := Node3D.new()
	node.name = title
	node.position = at
	parent.add_child(node)
	return node
