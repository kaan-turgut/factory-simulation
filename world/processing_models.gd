extends RefCounted
## Detailed spreader, cutter, cooling tunnel and flow-wrapper models.
##
## Built with the shared industrial kit (generated PBR materials, merged static
## meshes, fine detail without shadows beyond the detail range). Each machine sits
## on the same hygienic stainless conveyor; product travels in +X. Motion is visual
## only and stops whenever the work center is not running.

const Industrial = preload("res://world/industrial_models.gd")

const X := Industrial.X
const Y := Industrial.Y
const Z := Industrial.Z
const WAFER := Color("#ca9250")
const FILLING := Color("#eee1bd")
const CREAM := Color("#f1e6c8")
const BED_Y := 0.97
const BELT_WIDTH := 1.2
const BELT_SPEED := 0.43

var _kit: Industrial
var _station: Node3D
var _root: Node3D
var _accent: Color
var _cabinet: StandardMaterial3D
var _belt: StandardMaterial3D
var _length: float
var _phase := 0.0
var _mode: StringName
var _rollers: Array[Node3D] = []
var _ram: Node3D
var _film: Node3D
var _label_feed: Node3D
var _loads: Array[Node3D] = []
var _finished: Array[Node3D] = []
var _moving: Array[Node3D] = []
## Parts that turn while the line runs: [pivot, local axis, radians per second].
var _spinners: Array = []
var _product: StandardMaterial3D
var _package: StandardMaterial3D
var beacon_mount: Vector3


func _init(kit: Industrial, station: Node3D, mode: StringName, length: float, accent: Color) -> void:
	_kit = kit
	_station = station
	_root = kit.model_root(station, "ProcessingModel")
	_accent = accent
	_cabinet = kit.paint(accent)
	_length = length
	_mode = mode
	_belt = kit.scrolling_belt(Color("#dfe7ea") if mode != &"CoolingTunnel" else Color("#d7e4ea"),
		Vector2(length * 2.0, 1.0))
	_product = kit.make_surface(Color("#e7e2d2"), 0.55, 0.0)
	_package = kit.make_surface(accent.lightened(0.15), 0.45, 0.1)
	_conveyor()
	match mode:
		&"Spreader": _spreader()
		&"Cutter": _cutter()
		&"CoolingTunnel": _tunnel()
		&"GumConditioner":
			_tunnel()
			_climate_unit()
		&"GumSheeter": _sheeter()
		&"FruitFormer": _former()
		&"WalletPacker": _wallet()
		&"BottleFiller": _bottler()
		_: _packaging()
	kit.stack_light(station, _root, beacon_mount)
	var dynamic: Array[MeshInstance3D] = [station.beacon]
	kit.finish(_root, dynamic)
	for part in _moving:
		kit.finish(part)


func belt_load_height() -> float:
	return BED_Y + 0.05


func animate(working: bool, delta: float) -> void:
	if not working or delta <= 0.0:
		return
	_phase += delta
	# The belt texture repeats every 0.5 m; keep it in step with the loads.
	_belt.uv1_offset.x = -fposmod(_phase * BELT_SPEED * (_length - 0.56) * 2.0, 1.0)
	match _mode:
		&"Spreader":
			_rollers[0].rotate_z(-delta * 3.8)
			_rollers[1].rotate_z(delta * 4.4)
		&"Cutter":
			# Dwell above the belt, then lower the blade and retract it.
			var stroke := pow(sin(fposmod(_phase * 1.7, 1.0) * PI), 5.0)
			_ram.position.y = 1.52 - 0.24 * stroke
		&"CoolingTunnel", &"GumConditioner":
			for fan in _rollers:
				fan.rotate_y(-delta * 8.0)
		&"GumSheeter", &"FruitFormer", &"BottleFiller":
			_spin(delta)
		&"WalletPacker":
			_spin(delta)
			_ram.position.y = 1.5 - 0.12 * pow(sin(fposmod(_phase * 1.4, 1.0) * PI), 4.0)
		_:
			_film.rotate_z(delta * 3.6)
			_label_feed.rotate_z(-delta * 4.2)
			# Rotary cross-seal jaws turn once per pack.
			_ram.rotation.z = -fposmod(_phase * PI * 1.5, TAU)
	for index in _loads.size():
		var progress := fposmod(_phase * BELT_SPEED + float(index) / _loads.size(), 1.0)
		_loads[index].position.x = lerpf(-_length * 0.5 + 0.28, _length * 0.5 - 0.28, progress)
		_finished[index].visible = _loads[index].position.x > 0.35


func show_loads(working: bool) -> void:
	for item in _loads:
		item.visible = working


## Colours of the product pieces and their retail packs on the belt.
func tint(product: Color, package: Color) -> void:
	if _product.albedo_color != product:
		_product.albedo_color = product
	if _package.albedo_color != package:
		_package.albedo_color = package


func _spin(delta: float) -> void:
	for row in _spinners:
		(row[0] as Node3D).rotate_object_local(row[1], delta * row[2])


func _spinner(at: Vector3, title: String, axis: Vector3, speed: float) -> Node3D:
	var node := _kit.pivot(_root, at, title)
	_moving.append(node)
	_spinners.append([node, axis, speed])
	return node


# --- Shared conveyor ---------------------------------------------------------------

func _conveyor() -> void:
	var k := _kit
	var half := _length * 0.5
	var top := BED_Y + 0.05
	# Legs every 1.6 m with levelling feet, cross ties and lengthwise stretchers.
	var bays := maxi(2, ceili((_length - 0.5) / 1.6))
	for index in bays + 1:
		var x := lerpf(-half + 0.3, half - 0.3, float(index) / bays)
		for z: float in [-0.55, 0.55]:
			k.leg(_root, Vector3(x, 0, z), BED_Y - 0.08)
		k.box(_root, Vector3(x, 0.28, 0), Vector3(0.05, 0.05, 1.1), k.stainless)
	for z: float in [-0.55, 0.55]:
		k.box(_root, Vector3(0, 0.28, z), Vector3(_length - 0.6, 0.05, 0.05), k.stainless)
	# Side frames, return belt, drip tray and end drums.
	for side: float in [-1.0, 1.0]:
		k.box(_root, Vector3(0, BED_Y - 0.02, side * 0.64), Vector3(_length, 0.17, 0.045), k.stainless)
		k.box(_root, Vector3(0, BED_Y + 0.072, side * 0.665), Vector3(_length, 0.016, 0.07), k.stainless_dark)
		k.box(_root, Vector3(0, BED_Y - 0.11, side * 0.668), Vector3(_length - 0.2, 0.012, 0.004), k.seam)
		# Product guide on brackets.
		k.box(_root, Vector3(0, top + 0.07, side * 0.6), Vector3(_length - 0.1, 0.05, 0.012), k.polished)
		for index in floori(_length / 1.2):
			var x := -half + 0.6 + index * 1.2
			k.box(_root, Vector3(x, top + 0.04, side * 0.628), Vector3(0.03, 0.08, 0.05), k.polished)
	var belt := PlaneMesh.new()
	belt.size = Vector2(_length - 0.08, BELT_WIDTH)
	k.add_mesh(_root, Vector3(0, top, 0), belt, _belt)
	k.box(_root, Vector3(0, top - 0.025, 0), Vector3(_length - 0.08, 0.045, BELT_WIDTH - 0.02), k.seam)
	k.box(_root, Vector3(0, BED_Y - 0.2, 0), Vector3(_length - 0.3, 0.012, BELT_WIDTH - 0.04), k.seam)
	k.box(_root, Vector3(0, 0.46, 0), Vector3(_length - 0.7, 0.02, 1.0), k.stainless_dark)
	for end: float in [-1.0, 1.0]:
		k.cylinder(_root, Vector3(end * (half - 0.04), top - 0.035, 0), 0.04, BELT_WIDTH + 0.04, k.polished, Z, 14)
		for z: float in [-0.68, 0.68]:
			k.cylinder(_root, Vector3(end * (half - 0.04), top - 0.035, z), 0.03, 0.04, k.seam, Z, 10)
	# Drive: gear motor under the discharge end.
	k.box(_root, Vector3(half - 0.32, BED_Y - 0.2, -0.78), Vector3(0.2, 0.2, 0.16), k.motor)
	k.drive_motor(_root, Vector3(half - 0.32, BED_Y - 0.43, -0.78), 0.09, 0.28, Y)


func _cabinet_at(at: Vector3, size: Vector3, facing: float) -> void:
	# Electrical cabinet with door seams, handle and a louvred panel. `facing` is +1 or -1 in Z.
	var k := _kit
	k.box(_root, Vector3(at.x, 0.06, at.z), Vector3(size.x + 0.04, 0.12, size.z + 0.04), k.frame_dark)
	k.box(_root, Vector3(at.x, 0.12 + size.y * 0.5, at.z), size, _cabinet)
	var face := at.z + facing * (size.z * 0.5 + 0.004)
	k.box(_root, Vector3(at.x, 0.12 + size.y * 0.5, face), Vector3(0.01, size.y - 0.12, 0.01), k.seam)
	k.box(_root, Vector3(at.x + size.x * 0.32, 0.12 + size.y * 0.55, face + facing * 0.012),
		Vector3(0.03, 0.2, 0.03), k.polished)
	k.box(_root, Vector3(at.x - size.x * 0.25, 0.4, face), Vector3(size.x * 0.32, 0.22, 0.008), k.vent)
	k.box(_root, Vector3(at.x, 0.12 + size.y + 0.02, at.z), Vector3(size.x + 0.03, 0.04, size.z + 0.03), k.frame_dark)


func _hmi_pedestal(at: Vector3) -> void:
	# Operator panel on a floor pedestal, tilted towards the aisle.
	var k := _kit
	k.cylinder(_root, Vector3(at.x, 0.015, at.z), 0.16, 0.03, k.frame_dark, Y, 16)
	k.cylinder(_root, Vector3(at.x, (at.y - 0.2) * 0.5, at.z), 0.04, at.y - 0.2, k.polished, Y, 12)
	k.box(_root, Vector3(at.x, at.y - 0.18, at.z), Vector3(0.14, 0.08, 0.14), k.stainless_dark)
	k.pendant(_root, at)


# --- Cream spreader ----------------------------------------------------------------

func _spreader() -> void:
	var k := _kit
	var head := -0.3
	# Spreading head: two stainless side housings joined by a bridge, open at the front.
	for z: float in [-0.86, 0.86]:
		k.box(_root, Vector3(head, 1.42, z), Vector3(1.5, 1.0, 0.26), k.stainless)
		k.box(_root, Vector3(head, 1.42, z * 1.155), Vector3(1.3, 0.8, 0.008), k.stainless_dark)
		k.box(_root, Vector3(head + 0.55, 1.42, z * 1.16), Vector3(0.03, 0.18, 0.02), k.polished)
		k.cylinder(_root, Vector3(head - 0.25, 1.22, z * 1.17), 0.08, 0.04, k.polished, Z, 16)
		k.cylinder(_root, Vector3(head + 0.3, 1.2, z * 1.17), 0.07, 0.04, k.polished, Z, 16)
	k.box(_root, Vector3(head, 2.02, 0), Vector3(1.5, 0.24, 1.98), k.stainless)
	for side: float in [-1.0, 1.0]:
		k.cylinder(_root, Vector3(head + side * 0.75, 2.02, 0), 0.12, 1.98, k.stainless, Z, 18)
	k.box(_root, Vector3(head, 2.14, 0.0), Vector3(1.3, 0.008, 1.7), k.stainless_dark)
	# Gear motors that drive the metering rollers, on the rear housing.
	k.box(_root, Vector3(head - 0.25, 1.22, -1.06), Vector3(0.22, 0.22, 0.14), k.motor)
	k.drive_motor(_root, Vector3(head - 0.25, 1.22, -1.28), 0.09, 0.3, Z)
	k.box(_root, Vector3(head + 0.3, 1.2, -1.06), Vector3(0.2, 0.2, 0.14), k.motor)
	k.drive_motor(_root, Vector3(head + 0.3, 1.2, -1.26), 0.08, 0.26, Z)
	# Cream manifold and nozzle bar feeding the gap between the rollers.
	k.box(_root, Vector3(head - 0.05, 1.58, 0), Vector3(0.26, 0.14, 1.5), k.stainless_dark)
	k.box(_root, Vector3(head - 0.05, 1.49, 0), Vector3(0.1, 0.06, 1.3), k.polished)
	_rollers.append(_roller(Vector3(head - 0.25, 1.22, 0), 0.135))
	_rollers.append(_roller(Vector3(head + 0.3, 1.2, 0), 0.114))
	# Doctor blade and cream film between the head and the belt.
	k.box(_root, Vector3(head + 0.48, 1.08, 0), Vector3(0.24, 0.02, 1.26), k.polished).rotation.z = 0.35
	k.box(_root, Vector3(head + 0.12, 1.06, 0), Vector3(0.36, 0.012, 1.15), k.make_surface(CREAM, 0.3, 0.0))
	# Guard rail and warning band across the open front.
	k.box(_root, Vector3(head, 1.72, 1.0), Vector3(1.5, 0.05, 0.05), k.safety)
	k.box(_root, Vector3(head, 1.94, 1.0), Vector3(1.5, 0.09, 0.012), k.hazard)
	# Cream hopper on the bridge with lid and level probe.
	var hopper := Vector3(head - 0.05, 2.14, 0)
	k.cylinder(_root, hopper + Vector3(0, 0.3, 0), 0.24, 0.45, k.stainless, Y, 24, 0.5)
	k.cylinder(_root, hopper + Vector3(0, 0.55, 0), 0.52, 0.05, k.stainless_dark, Y, 24)
	k.cylinder(_root, hopper + Vector3(0, 0.6, 0), 0.47, 0.05, k.stainless, Y, 24)
	k.box(_root, hopper + Vector3(0, 0.66, 0), Vector3(0.3, 0.03, 0.04), k.polished)
	k.cylinder(_root, hopper + Vector3(0.28, 0.7, 0.1), 0.02, 0.25, k.polished, Y, 8)

	# Jacketed cream buffer tank with agitator and transfer pump at the rear.
	var tank := Vector3(-1.85, 0, -1.4)
	for index in 3:
		var angle := index * TAU / 3.0 + 0.4
		k.leg(_root, tank + Vector3(cos(angle) * 0.36, 0, sin(angle) * 0.36), 0.62)
	k.cylinder(_root, tank + Vector3(0, 0.62, 0), 0.12, 0.2, k.stainless, Y, 20, 0.44)
	k.cylinder(_root, tank + Vector3(0, 1.12, 0), 0.46, 0.8, k.stainless, Y, 24)
	for y: float in [0.86, 1.38]:
		k.cylinder(_root, tank + Vector3(0, y, 0), 0.47, 0.04, k.stainless_dark, Y, 24)
	k.cylinder(_root, tank + Vector3(0, 1.56, 0), 0.47, 0.08, k.stainless_dark, Y, 24, 0.3)
	k.cylinder(_root, tank + Vector3(0, 1.68, 0), 0.08, 0.16, k.motor, Y, 12)
	k.drive_motor(_root, tank + Vector3(0, 1.87, 0), 0.08, 0.2, Y)
	k.dial(_root, tank + Vector3(0.3, 1.15, 0.36), Z)
	k.box(_root, tank + Vector3(-0.3, 1.12, 0.37), Vector3(0.06, 0.5, 0.02), k.glass)
	var pump := Vector3(-1.0, 0.24, -1.45)
	k.box(_root, pump + Vector3(0.1, -0.17, 0), Vector3(0.7, 0.06, 0.3), k.frame_dark)
	k.cylinder(_root, pump, 0.11, 0.18, k.stainless, X, 16)
	k.drive_motor(_root, pump + Vector3(0.32, 0, 0), 0.09, 0.3, X)
	k.pipe(_root, tank + Vector3(0, 0.52, 0), tank + Vector3(0, 0.24, 0), 0.03, k.polished)
	k.pipe(_root, tank + Vector3(0, 0.24, 0), pump + Vector3(-0.1, 0, 0.05), 0.03, k.polished)
	k.joint(_root, tank + Vector3(0, 0.24, 0), 0.04, k.polished)
	k.box(_root, tank + Vector3(0.2, 0.3, 0.05), Vector3(0.18, 0.025, 0.025), k.signal_red)
	var riser := Vector3(head - 0.05, 0.24, -1.45)
	k.pipe(_root, pump + Vector3(0, 0.1, 0), riser, 0.03, k.polished)
	k.pipe(_root, riser, riser + Vector3(0, 2.3, 0), 0.03, k.polished)
	k.joint(_root, riser + Vector3(0, 2.3, 0), 0.04, k.polished)
	k.pipe(_root, riser + Vector3(0, 2.3, 0), Vector3(head - 0.05, 2.54, -0.25), 0.03, k.polished)

	_cabinet_at(Vector3(1.75, 0, -1.45), Vector3(0.9, 1.7, 0.45), 1.0)
	_hmi_pedestal(Vector3(1.95, 1.35, 1.05))
	beacon_mount = Vector3(head + 0.55, 2.14, 0.75)
	_load_train(3, Vector3(0.58, 0.06, 0.97), &"spread")


func _roller(at: Vector3, radius: float) -> Node3D:
	var k := _kit
	var roller := k.pivot(_root, at, "MeteringRoller")
	_moving.append(roller)
	k.cylinder(roller, Vector3.ZERO, radius, 1.42, k.polished, Z, 20)
	for z: float in [-0.72, 0.72]:
		k.cylinder(roller, Vector3(0, 0, z), radius * 0.45, 0.06, k.stainless_dark, Z, 12)
	for index in 4:
		var angle := index * PI * 0.5
		var rib := k.box(roller, Vector3(radius, 0, 0).rotated(Vector3.BACK, angle),
			Vector3(0.022, 0.026, 1.38), k.stainless_dark)
		rib.rotation.z = angle
	return roller


# --- Wafer cutter ------------------------------------------------------------------

func _cutter() -> void:
	var k := _kit
	# Portal: painted columns on base plates and a box-section crossbeam.
	for z: float in [-0.92, 0.92]:
		k.box(_root, Vector3(0, 0.03, z), Vector3(0.5, 0.06, 0.45), k.frame_dark)
		k.box(_root, Vector3(0, 1.2, z), Vector3(0.32, 2.3, 0.3), _cabinet)
		k.box(_root, Vector3(0.162, 1.2, z), Vector3(0.006, 2.1, 0.2), k.seam)
	k.box(_root, Vector3(0, 2.28, 0), Vector3(0.6, 0.38, 2.2), _cabinet)
	k.box(_root, Vector3(0, 2.48, 0), Vector3(0.64, 0.03, 2.24), k.frame_dark)
	k.box(_root, Vector3(0.302, 2.28, 0), Vector3(0.008, 0.18, 1.6), k.hazard)
	k.plate(_root, Vector3(0.307, 2.4, 0), "CUTTER", Color("#1b1f22"), 0.0022).rotation.y = PI * 0.5
	# Twin pneumatic cylinders with air lines and valve island.
	for z: float in [-0.48, 0.48]:
		k.cylinder(_root, Vector3(0, 2.75, z), 0.075, 0.5, k.stainless_dark, Y, 18)
		k.cylinder(_root, Vector3(0, 3.02, z), 0.085, 0.04, k.polished, Y, 18)
		k.cylinder(_root, Vector3(0, 2.52, z), 0.085, 0.04, k.polished, Y, 18)
		k.pipe(_root, Vector3(0.09, 2.9, z), Vector3(0.09, 2.9, z * 0.4), 0.008, k.signal_red)
	k.box(_root, Vector3(0.0, 2.6, 0), Vector3(0.18, 0.12, 0.3), k.motor)
	# Moving cutting head.
	_ram = k.pivot(_root, Vector3(0, 1.52, 0), "CuttingHead")
	_moving.append(_ram)
	k.box(_ram, Vector3.ZERO, Vector3(0.34, 0.14, 1.44), k.stainless_dark)
	k.box(_ram, Vector3(0, 0.08, 0), Vector3(0.3, 0.02, 1.4), k.seam)
	k.box(_ram, Vector3(0, -0.15, 0), Vector3(0.05, 0.18, 1.26), k.polished)
	for index in 6:
		k.box(_ram, Vector3(0, -0.25, -0.52 + index * 0.208), Vector3(0.06, 0.04, 0.16), k.chrome)
	for z: float in [-0.48, 0.48]:
		k.cylinder(_ram, Vector3(0, 0.36, z), 0.028, 0.6, k.chrome, Y, 10)
		k.cylinder(_ram, Vector3(0, 0.08, z), 0.06, 0.04, k.polished, Y, 14)
	# Safety light curtains either side of the cut, front and back.
	for x: float in [-0.62, 0.62]:
		for z: float in [-0.72, 0.72]:
			k.box(_root, Vector3(x, 1.5, z), Vector3(0.05, 1.0, 0.05), k.safety)
			k.box(_root, Vector3(x, 1.5, z - signf(z) * 0.026), Vector3(0.024, 0.9, 0.004), k.screen)
	# Infeed and outfeed hoods with hinged guard windows.
	for x: float in [-1.2, 1.2]:
		k.box(_root, Vector3(x, 1.42, 0), Vector3(0.9, 0.04, 1.4), k.stainless)
		for z: float in [-0.7, 0.7]:
			k.box(_root, Vector3(x, 1.22, z), Vector3(0.9, 0.4, 0.03), k.stainless)
			k.box(_root, Vector3(x, 1.22, z * 1.025), Vector3(0.7, 0.26, 0.006), k.glass)
		k.cylinder(_root, Vector3(x, 1.44, 0.72), 0.012, 0.86, k.polished, X, 8)
	# Off-cut chute and bin under the blade.
	k.box(_root, Vector3(0, 0.62, 0), Vector3(0.5, 0.02, 1.1), k.stainless_dark).rotation.z = 0.25
	k.box(_root, Vector3(0.05, 0.22, 0.95), Vector3(0.5, 0.4, 0.42), k.make_surface(Color("#2d6fa8"), 0.6, 0.0))
	_cabinet_at(Vector3(-1.55, 0, -1.45), Vector3(0.95, 1.6, 0.45), 1.0)
	k.pipe(_root, Vector3(-1.3, 1.72, -1.45), Vector3(-1.3, 2.28, -1.45), 0.03, k.frame_dark)
	k.pipe(_root, Vector3(-1.3, 2.28, -1.45), Vector3(-0.3, 2.28, -0.9), 0.03, k.frame_dark)
	_hmi_pedestal(Vector3(1.7, 1.35, 1.05))
	beacon_mount = Vector3(0.0, 2.5, 0.85)
	_load_train(3, Vector3(0.53, 0.066, 0.98), &"cut")


# --- Cooling tunnel ----------------------------------------------------------------

func _tunnel() -> void:
	var k := _kit
	var span := _length - 0.9
	var modules := 4
	var step := span / modules
	var insulated := k.panel_white
	for index in modules:
		var x := -span * 0.5 + (index + 0.5) * step
		# Insulated hood: rear wall, low front wall and a lid with rounded edges.
		k.box(_root, Vector3(x, 1.4, -0.8), Vector3(step - 0.03, 0.8, 0.12), insulated)
		k.box(_root, Vector3(x, 1.02, 0.8), Vector3(step - 0.03, 0.1, 0.12), insulated)
		k.box(_root, Vector3(x, 1.86, 0), Vector3(step - 0.03, 0.24, 1.6), insulated)
		for z: float in [-0.8, 0.8]:
			k.cylinder(_root, Vector3(x, 1.86, z), 0.12, step - 0.03, insulated, X, 16)
		# Lid hinges, lifting handle and a zone temperature display.
		k.box(_root, Vector3(x, 1.67, 0.93), Vector3(step * 0.5, 0.04, 0.025), k.polished)
		k.box(_root, Vector3(x - step * 0.3, 1.92, -0.93), Vector3(0.1, 0.06, 0.03), k.polished)
		k.box(_root, Vector3(x + step * 0.3, 1.92, -0.93), Vector3(0.1, 0.06, 0.03), k.polished)
		k.box(_root, Vector3(x + step * 0.28, 1.82, 0.925), Vector3(0.22, 0.12, 0.02), k.seam)
		k.box(_root, Vector3(x + step * 0.28, 1.82, 0.937), Vector3(0.18, 0.08, 0.004), k.screen)
		# Stainless joint bands between modules.
		k.box(_root, Vector3(x - step * 0.5, 1.5, 0), Vector3(0.05, 0.98, 1.86), k.stainless)
		# Inspection slot frame along the front.
		k.box(_root, Vector3(x, 1.63, 0.86), Vector3(step - 0.03, 0.03, 0.04), k.stainless)
		# Cold air manifold under each lid.
		k.box(_root, Vector3(x, 1.7, -0.3), Vector3(step - 0.2, 0.06, 0.7), k.vent)
	k.box(_root, Vector3(span * 0.5, 1.5, 0), Vector3(0.05, 0.98, 1.86), k.stainless)
	# Entry and exit hoods with strip curtains.
	for end: float in [-1.0, 1.0]:
		var x := end * (span * 0.5 + 0.18)
		k.box(_root, Vector3(x, 1.58, 0), Vector3(0.36, 0.06, 1.5), k.stainless)
		for z: float in [-0.72, 0.72]:
			k.box(_root, Vector3(x, 1.3, z), Vector3(0.36, 0.56, 0.04), k.stainless)
		for index in 7:
			k.box(_root, Vector3(end * (span * 0.5 + 0.02), 1.32, -0.6 + index * 0.2),
				Vector3(0.01, 0.48, 0.17), k.glass)
	# Refrigeration units on the roof, each with a guarded condenser fan.
	for x: float in [-span * 0.25, span * 0.25]:
		k.box(_root, Vector3(x, 2.02, -0.1), Vector3(1.3, 0.1, 1.3), k.frame_dark)
		k.box(_root, Vector3(x, 2.2, -0.1), Vector3(1.2, 0.26, 1.2), k.stainless_dark)
		k.box(_root, Vector3(x, 2.2, 0.505), Vector3(1.0, 0.18, 0.006), k.vent)
		k.cylinder(_root, Vector3(x, 2.36, -0.1), 0.5, 0.06, k.frame_dark, Y, 28)
		k.cylinder(_root, Vector3(x, 2.4, -0.1), 0.06, 0.06, k.frame_dark, Y, 12)
		for index in 4:
			var bar := k.box(_root, Vector3(x, 2.47, -0.1), Vector3(1.0, 0.016, 0.016), k.polished)
			bar.rotation.y = index * PI * 0.25
		k.cylinder(_root, Vector3(x, 2.47, -0.1), 0.48, 0.012, k.polished, Y, 28)
		var fan := k.pivot(_root, Vector3(x, 2.42, -0.1), "CoolingFan")
		_moving.append(fan)
		k.cylinder(fan, Vector3.ZERO, 0.1, 0.06, k.stainless, Y, 14)
		for index in 5:
			var angle := index * TAU / 5
			var blade := k.box(fan, Vector3(0.25, 0, 0).rotated(Vector3.UP, angle),
				Vector3(0.36, 0.012, 0.13), k.stainless)
			blade.rotation = Vector3(0.0, angle + 0.22, 0.3)
		_rollers.append(fan)
		# Insulated refrigerant lines down the rear.
		k.pipe(_root, Vector3(x + 0.4, 2.1, -0.72), Vector3(x + 0.4, 0.5, -0.95), 0.035, k.rubber)
		k.pipe(_root, Vector3(x + 0.5, 2.1, -0.72), Vector3(x + 0.5, 0.5, -0.95), 0.025, k.polished)
	_cabinet_at(Vector3(0.0, 0, -1.5), Vector3(1.2, 1.5, 0.45), 1.0)
	_hmi_pedestal(Vector3(span * 0.5 - 0.2, 1.35, 1.15))
	beacon_mount = Vector3(span * 0.5 - 0.5, 1.98, 0.6)


# --- Horizontal flow wrapper -------------------------------------------------------

func _packaging() -> void:
	var k := _kit
	var jaw := 0.3
	# Main frame: rear cantilever housing that carries every station.
	k.box(_root, Vector3(-0.2, 1.55, -0.86), Vector3(2.4, 1.3, 0.34), _cabinet)
	k.box(_root, Vector3(-0.2, 2.24, -0.86), Vector3(2.44, 0.06, 0.38), k.frame_dark)
	for x: float in [-1.0, 0.0, 0.95]:
		k.box(_root, Vector3(x, 1.55, -0.688), Vector3(0.008, 1.2, 0.008), k.seam)
	k.box(_root, Vector3(-0.7, 1.35, -0.686), Vector3(0.6, 0.3, 0.006), k.vent)
	# Forming box and fin-seal wheels.
	var former := k.box(_root, Vector3(-0.6, 1.18, 0), Vector3(0.5, 0.025, 1.0), k.polished)
	former.rotation.z = 0.22
	for z: float in [-0.12, 0.12]:
		k.cylinder(_root, Vector3(-0.1, 0.92, z), 0.07, 0.04, k.chrome, Y, 16)
	k.box(_root, Vector3(-0.35, 1.09, 0), Vector3(0.6, 0.006, 0.9), k.film)
	# Film reel and dancer arm behind the former.
	k.box(_root, Vector3(-1.2, 1.95, -0.62), Vector3(0.12, 0.5, 0.06), k.frame_dark)
	k.cylinder(_root, Vector3(-1.2, 1.95, -0.33), 0.03, 0.6, k.polished, Z, 10)
	_film = _reel(Vector3(-1.2, 1.95, -0.25), 0.38, 0.5, k.film)
	for x: float in [-0.75, -0.55]:
		k.cylinder(_root, Vector3(x, 1.75 - (x + 0.75), -0.25), 0.025, 0.56, k.polished, Z, 10)
	var web := k.box(_root, Vector3(-0.85, 1.55, -0.25), Vector3(0.7, 0.004, 0.5), k.film)
	web.rotation.z = -0.9
	# Rotary cross-seal jaws in a guarded box.
	for z: float in [-0.62, 0.62]:
		k.box(_root, Vector3(jaw, 1.42, z), Vector3(0.62, 0.9, 0.12), k.stainless)
		k.cylinder(_root, Vector3(jaw, 1.64, z * 1.1), 0.09, 0.05, k.polished, Z, 16)
	k.box(_root, Vector3(jaw, 1.9, 0), Vector3(0.66, 0.06, 1.36), k.stainless)
	_ram = k.pivot(_root, Vector3(jaw, 1.64, 0), "SealingJaw")
	_moving.append(_ram)
	k.cylinder(_ram, Vector3.ZERO, 0.06, 1.18, k.polished, Z, 14)
	for side: float in [-1.0, 1.0]:
		k.box(_ram, Vector3(0, side * 0.2, 0), Vector3(0.1, 0.34, 1.1), k.stainless_dark)
		k.box(_ram, Vector3(0, side * 0.38, 0), Vector3(0.16, 0.06, 1.14), k.safety)
	k.box(_root, Vector3(jaw, 1.68, 0.7), Vector3(0.58, 0.44, 0.012), k.glass)
	k.box(_root, Vector3(jaw, 1.91, 0.7), Vector3(0.62, 0.04, 0.03), k.safety)
	# Label applicator and date coder above the discharge.
	var label_at := Vector3(minf(1.3, _length * 0.5 - 0.6), 1.62, -0.66)
	k.box(_root, label_at + Vector3(0, -0.1, -0.1), Vector3(0.36, 0.5, 0.2), k.stainless_dark)
	_label_feed = _reel(label_at + Vector3(0, 0.1, 0.12), 0.18, 0.14, k.gauge)
	k.box(_root, label_at + Vector3(0.0, -0.5, 0.35), Vector3(0.16, 0.08, 0.28), k.polished)
	k.box(_root, Vector3(label_at.x - 0.45, 1.3, 0.62), Vector3(0.14, 0.12, 0.1), k.seam)
	k.box(_root, Vector3(label_at.x - 0.45, 1.3, 0.676), Vector3(0.06, 0.03, 0.004), k.screen)
	# HMI on a swing arm and the cabinet under the frame.
	k.pipe(_root, Vector3(0.9, 2.24, -0.86), Vector3(0.9, 2.24, 0.55), 0.03, k.polished)
	k.pipe(_root, Vector3(0.9, 2.24, 0.55), Vector3(0.9, 1.75, 0.95), 0.03, k.polished)
	k.joint(_root, Vector3(0.9, 2.24, 0.55), 0.04, k.polished)
	k.pendant(_root, Vector3(0.9, 1.6, 0.98))
	_cabinet_at(Vector3(-0.2, 0, -1.42), Vector3(1.6, 1.05, 0.45), 1.0)
	beacon_mount = Vector3(-1.2, 2.27, -0.86)
	_load_train(3, Vector3(0.43, 0.11, 0.51), &"pack")


func _reel(at: Vector3, radius: float, width: float, surface: Material) -> Node3D:
	var k := _kit
	var reel := k.pivot(_root, at, "FeedReel")
	_moving.append(reel)
	k.cylinder(reel, Vector3.ZERO, radius, width, surface, Z, 24)
	for z: float in [-1.0, 1.0]:
		k.cylinder(reel, Vector3(0, 0, z * (width * 0.5 + 0.01)), radius * 0.4, 0.02, k.stainless_dark, Z, 16)
	k.cylinder(reel, Vector3.ZERO, radius * 0.2, width + 0.08, k.frame_dark, Z, 12)
	k.box(reel, Vector3(0, radius * 0.26, width * 0.5 + 0.025), Vector3(0.04, radius * 0.18, 0.012), k.safety)
	return reel


# --- Product on the belt -----------------------------------------------------------

func _load_train(count: int, size: Vector3, finish: StringName) -> void:
	var k := _kit
	var wafer := k.make_surface(WAFER, 0.8, 0.0)
	var cream := k.make_surface(FILLING, 0.55, 0.0)
	var groove := k.make_surface(WAFER.darkened(0.35), 0.85, 0.0)
	for index in count:
		var item := k.pivot(_root, Vector3(-_length * 0.5 + (index + 0.5) * _length / count,
			belt_load_height(), 0), "BeltLoad")
		_loads.append(item)
		var detail := k.pivot(item, Vector3.ZERO, "FinishedDetail")
		_finished.append(detail)
		if finish in [&"score", &"fruit", &"wallet", &"bottle"]:
			_gum_load(item, detail, size, finish)
			k.finish(detail)
			k.finish(item)
			item.hide()
			continue
		k.box(item, Vector3.UP * size.y * 0.5, size, wafer)
		for x: float in [-0.3, 0.0, 0.3]:
			k.box(item, Vector3(x * size.x, size.y + 0.002, 0), Vector3(0.012, 0.004, size.z * 0.96), groove)
		if finish == &"cut":
			for z: float in [-0.29, 0.0, 0.29]:
				k.box(detail, Vector3(0, size.y * 0.5, z), Vector3(size.x + 0.004, size.y + 0.004, 0.02), k.seam)
		elif finish == &"pack":
			k.box(detail, Vector3(0, 0.092, 0), Vector3(0.47, 0.18, 0.55), k.paint(_accent.lightened(0.19)))
			k.box(detail, Vector3(0, 0.186, 0), Vector3(0.49, 0.012, 0.1), k.film)
			k.box(detail, Vector3(0.09, 0.0921, 0.276), Vector3(0.2, 0.1, 0.004), k.gauge)
		else:
			k.box(detail, Vector3(0, size.y + 0.016, 0), Vector3(size.x, 0.032, size.z), cream)
			k.box(detail, Vector3(0, size.y + 0.048, 0), Vector3(size.x, 0.033, size.z), wafer)
		k.finish(detail)
		k.finish(item)
		item.hide()


func _gum_load(item: Node3D, detail: Node3D, size: Vector3, finish: StringName) -> void:
	var k := _kit
	match finish:
		&"score":
			# Rolled gum sheet; scored into pellets after the scoring head.
			k.box(item, Vector3.UP * size.y * 0.5, size, _product)
			for index in 5:
				k.box(detail, Vector3(-size.x * 0.4 + index * size.x * 0.2, size.y + 0.002, 0),
					Vector3(0.008, 0.004, size.z), k.seam)
			for index in 7:
				k.box(detail, Vector3(0, size.y + 0.002, -size.z * 0.42 + index * size.z * 0.14),
					Vector3(size.x, 0.004, 0.008), k.seam)
		&"fruit":
			# Rows of fruit-shaped centres leaving the rotary die.
			var piece := SphereMesh.new()
			piece.radius = 0.055
			piece.height = 0.1
			piece.radial_segments = 10
			piece.rings = 5
			for row in 4:
				for column in 3:
					k.add_mesh(item, Vector3(-0.12 + column * 0.12, 0.05, -0.27 + row * 0.18), piece, _product)
			var leaf := k.make_surface(Color("#4f9a3a"), 0.6, 0.0)
			for row in 4:
				for column in 3:
					k.box(detail, Vector3(-0.12 + column * 0.12, 0.105, -0.27 + row * 0.18), Vector3(0.03, 0.012, 0.018), leaf)
		&"wallet":
			# Trays of blister wallets, closed into printed cards after the cartoner.
			for row in 3:
				for column in 2:
					var at := Vector3(-0.09 + column * 0.18, 0.012, -0.2 + row * 0.2)
					k.box(item, at, Vector3(0.16, 0.024, 0.11), k.film)
					k.box(detail, at + Vector3(0, 0.014, 0), Vector3(0.164, 0.006, 0.114), _package)
		&"bottle":
			# Bottles stand in rows; caps and labels go on downstream.
			for row in 3:
				for column in 2:
					var at := Vector3(-0.07 + column * 0.14, 0.0, -0.2 + row * 0.2)
					k.cylinder(item, at + Vector3(0, 0.08, 0), 0.055, 0.16, _package, Y, 14)
					k.cylinder(detail, at + Vector3(0, 0.175, 0), 0.04, 0.03, k.gauge, Y, 12)
					k.cylinder(detail, at + Vector3(0, 0.085, 0), 0.057, 0.07, k.film, Y, 14)


# --- Gum sheeter -------------------------------------------------------------------

func _sheeter() -> void:
	var k := _kit
	var half := _length * 0.5
	var top := BED_Y + 0.05
	# Pre-extruder over the infeed: feed hopper, heated barrel, gear motor and a flat sheet die.
	var ex := Vector3(-half + 0.85, 1.52, 0.0)
	for x: float in [ex.x - 0.45, ex.x + 0.45]:
		for z: float in [-0.8, 0.8]:
			k.leg(_root, Vector3(x, 0, z), ex.y - 0.2)
		k.box(_root, Vector3(x, ex.y - 0.2, 0), Vector3(0.08, 0.08, 1.66), k.stainless)
	k.box(_root, ex + Vector3(0, -0.14, 0), Vector3(1.0, 0.06, 0.6), k.frame_dark)
	k.cylinder(_root, ex + Vector3(0.1, 0.06, 0), 0.17, 1.1, k.stainless, X, 22)
	for index in 3:
		k.cylinder(_root, ex + Vector3(-0.2 + index * 0.25, 0.06, 0), 0.19, 0.1, k.frame_dark, X, 22)
	k.cylinder(_root, ex + Vector3(-0.2, 0.52, 0), 0.12, 0.6, k.stainless, Y, 22, 0.4)
	k.cylinder(_root, ex + Vector3(-0.2, 0.83, 0), 0.42, 0.04, k.stainless_dark, Y, 22)
	k.drive_motor(_root, ex + Vector3(-0.72, 0.06, 0), 0.13, 0.36, X)
	k.box(_root, ex + Vector3(0.7, -0.18, 0), Vector3(0.12, 0.42, 1.0), k.polished)
	k.box(_root, ex + Vector3(0.7, -0.38, 0), Vector3(0.05, 0.05, 0.94), k.seam)
	# Three sizing roller pairs thin the sheet; each sits in a painted frame with a gear guard.
	for index in 3:
		var x := -0.95 + index * 0.62
		var radius := 0.15 - index * 0.02
		for z: float in [-0.72, 0.72]:
			k.box(_root, Vector3(x, 1.36, z), Vector3(0.36, 0.78, 0.1), _cabinet)
		k.box(_root, Vector3(x, 1.4, -0.82), Vector3(0.3, 0.34, 0.08), k.safety)
		var roller := _spinner(Vector3(x, top + 0.03 + radius, 0), "SizingRoller", Vector3.BACK, -2.4 - index)
		k.cylinder(roller, Vector3.ZERO, radius, 1.36, k.chrome, Z, 22)
		k.box(roller, Vector3(radius - 0.01, 0, 0), Vector3(0.02, 0.02, 1.34), k.stainless_dark)
		k.cylinder(_root, Vector3(x, top + 0.03 + radius, 0.78), radius * 0.55, 0.05, k.polished, Z, 16)
		k.box(_root, Vector3(x, 1.76, 0), Vector3(0.36, 0.06, 1.54), _cabinet)
	# Dusting powder hopper with its vibrator over the first pair.
	var duster := k.box(_root, Vector3(-0.64, 1.98, 0), Vector3(0.34, 0.3, 1.2), k.stainless)
	duster.rotation.z = 0.0
	k.box(_root, Vector3(-0.64, 1.8, 0), Vector3(0.1, 0.08, 1.1), k.polished)
	k.box(_root, Vector3(-0.42, 2.0, 0.66), Vector3(0.12, 0.12, 0.12), k.motor)
	# Scoring head: longitudinal disc knives and a cross-scoring drum.
	var score := 1.15
	for z: float in [-0.74, 0.74]:
		k.box(_root, Vector3(score, 1.42, z), Vector3(0.62, 0.9, 0.12), _cabinet)
	k.box(_root, Vector3(score, 1.92, 0), Vector3(0.66, 0.12, 1.6), _cabinet)
	k.box(_root, Vector3(score, 1.92, 0.805), Vector3(0.6, 0.08, 0.008), k.hazard)
	var discs := _spinner(Vector3(score - 0.16, top + 0.17, 0), "ScoringDiscs", Vector3.BACK, -3.2)
	k.cylinder(discs, Vector3.ZERO, 0.07, 1.36, k.polished, Z, 14)
	for index in 9:
		k.cylinder(discs, Vector3(0, 0, -0.56 + index * 0.14), 0.15, 0.012, k.chrome, Z, 22)
	var drum := _spinner(Vector3(score + 0.16, top + 0.15, 0), "CrossScorer", Vector3.BACK, -3.2)
	k.cylinder(drum, Vector3.ZERO, 0.13, 1.36, k.chrome, Z, 22)
	for index in 6:
		var blade := k.box(drum, Vector3(0.13, 0, 0).rotated(Vector3.BACK, index * TAU / 6), Vector3(0.05, 0.012, 1.34), k.stainless_dark)
		blade.rotation.z = index * TAU / 6
	k.drive_motor(_root, Vector3(score, 1.42, -0.98), 0.1, 0.3, Z)
	_cabinet_at(Vector3(-0.2, 0, -1.48), Vector3(1.3, 1.5, 0.42), 1.0)
	_hmi_pedestal(Vector3(half - 0.35, 1.35, 1.05))
	beacon_mount = Vector3(score, 1.98, 0.55)
	_load_train(3, Vector3(0.62, 0.026, 0.92), &"score")


# --- Fruit gum former --------------------------------------------------------------

func _former() -> void:
	var k := _kit
	var half := _length * 0.5
	var top := BED_Y + 0.05
	# Batch roller: tapered rollers in a trough turn the mass into a rope.
	var trough := Vector3(-half + 0.75, 1.42, 0)
	for x: float in [trough.x - 0.45, trough.x + 0.45]:
		for z: float in [-0.55, 0.55]:
			k.leg(_root, Vector3(x, 0, z + signf(z) * 0.25), trough.y - 0.2)
	k.box(_root, trough + Vector3(0, -0.12, 0), Vector3(1.1, 0.08, 0.95), k.stainless)
	for z: float in [-0.46, 0.46]:
		k.box(_root, trough + Vector3(0, 0.08, z), Vector3(1.1, 0.34, 0.04), k.stainless)
	for index in 4:
		var cone := _spinner(trough + Vector3(0, 0.02, -0.3 + index * 0.2), "BatchRoller", Vector3.UP, 2.2 * (1 if index % 2 == 0 else -1))
		cone.rotation.z = PI * 0.5
		k.cylinder(cone, Vector3.ZERO, 0.08, 1.0, k.chrome, Y, 16, 0.04)
	k.drive_motor(_root, trough + Vector3(-0.7, -0.05, 0), 0.11, 0.3, X)
	# Rope sizer: pairs of grooved wheels squeeze the rope to size.
	for index in 3:
		var x := -1.35 + index * 0.24
		for side: float in [-1.0, 1.0]:
			var wheel := _spinner(Vector3(x, 1.22, side * 0.075), "RopeSizer", Vector3.UP, 4.0 * side)
			k.cylinder(wheel, Vector3.ZERO, 0.07 - index * 0.008, 0.06, k.chrome, Y, 16)
		k.box(_root, Vector3(x, 1.1, 0), Vector3(0.12, 0.08, 0.3), k.stainless_dark)
	k.box(_root, Vector3(-1.1, 1.08, 0), Vector3(0.9, 0.06, 0.5), k.frame_dark)
	k.cylinder(_root, Vector3(-1.2, 1.21, 0), 0.025, 0.9, _product, X, 10)
	# Rotary die: the die drum stamps the rope into fruit shapes against a plunger drum.
	var die := Vector3(-0.15, 1.5, 0)
	for z: float in [-0.62, 0.62]:
		k.box(_root, die + Vector3(0, -0.05, z), Vector3(0.95, 1.15, 0.1), _cabinet)
	k.box(_root, die + Vector3(0, 0.56, 0), Vector3(0.95, 0.1, 1.34), _cabinet)
	k.box(_root, die + Vector3(0, 0.56, 0.675), Vector3(0.9, 0.07, 0.008), k.hazard)
	var drum := _spinner(die, "RotaryDie", Vector3.BACK, -1.6)
	k.cylinder(drum, Vector3.ZERO, 0.3, 1.0, k.chrome, Z, 28)
	for ring in 4:
		for index in 10:
			var angle := index * TAU / 10 + ring * 0.3
			k.box(drum, Vector3(0.3 * cos(angle), 0.3 * sin(angle), -0.36 + ring * 0.24), Vector3(0.05, 0.05, 0.06), k.seam)
	var plunger := _spinner(die + Vector3(0, 0.0, 0) + Vector3(0.0, 0.0, 0.0), "PlungerDrum", Vector3.BACK, 1.6)
	plunger.position = die + Vector3(0.44, 0.08, 0)
	k.cylinder(plunger, Vector3.ZERO, 0.15, 1.0, k.polished, Z, 22)
	k.drive_motor(_root, die + Vector3(0, 0, -0.95), 0.12, 0.34, Z)
	var chute := k.box(_root, die + Vector3(0.62, -0.32, 0), Vector3(0.6, 0.02, 0.9), k.stainless)
	chute.rotation.z = -0.45
	# Cooling air hood over the outfeed.
	k.box(_root, Vector3(1.45, 1.55, 0), Vector3(1.1, 0.2, 1.3), k.stainless)
	k.box(_root, Vector3(1.45, 1.444, 0), Vector3(1.0, 0.01, 1.2), k.vent)
	for x: float in [0.95, 1.95]:
		for z: float in [-0.62, 0.62]:
			k.box(_root, Vector3(x, 1.25, z), Vector3(0.04, 0.44, 0.04), k.stainless)
	k.cylinder(_root, Vector3(1.45, 1.78, 0), 0.24, 0.26, k.stainless_dark, Y, 20)
	k.drive_motor(_root, Vector3(1.45, 2.04, 0), 0.12, 0.26, Y)
	_cabinet_at(Vector3(0.3, 0, -1.48), Vector3(1.2, 1.5, 0.42), 1.0)
	_hmi_pedestal(Vector3(half - 0.3, 1.35, 1.05))
	beacon_mount = Vector3(die.x, die.y + 0.61, 0.5)
	_load_train(3, Vector3(0.4, 0.1, 0.8), &"fruit")


# --- Wallet blister packer ----------------------------------------------------------

func _wallet() -> void:
	var k := _kit
	var half := _length * 0.5
	# Base film reel under the infeed and the thermoforming station.
	var film := _spinner(Vector3(-half + 0.45, 0.62, 0), "BaseFilmReel", Vector3.BACK, 2.5)
	k.cylinder(film, Vector3.ZERO, 0.28, 0.9, k.film, Z, 22)
	k.cylinder(film, Vector3.ZERO, 0.06, 1.0, k.frame_dark, Z, 12)
	k.box(_root, Vector3(-1.55, 1.5, 0), Vector3(0.8, 0.5, 1.3), k.stainless)
	k.box(_root, Vector3(-1.55, 1.5, 0.655), Vector3(0.6, 0.3, 0.008), k.vent)
	k.box(_root, Vector3(-1.55, 1.2, 0), Vector3(0.7, 0.08, 1.1), k.signal_red)
	for x: float in [-1.9, -1.2]:
		for z: float in [-0.7, 0.7]:
			k.box(_root, Vector3(x, 1.4, z), Vector3(0.06, 0.8, 0.06), k.polished)
	# Vibratory bowl feeder fills the blister pockets with pellets.
	var bowl := Vector3(-0.55, 1.95, -0.1)
	for x: float in [bowl.x - 0.4, bowl.x + 0.4]:
		k.box(_root, Vector3(x, 1.45, -0.8), Vector3(0.08, 1.0, 0.08), _cabinet)
	k.box(_root, Vector3(bowl.x, 1.92, -0.8), Vector3(0.9, 0.08, 0.1), _cabinet)
	k.box(_root, Vector3(bowl.x, 1.7, -0.5), Vector3(0.5, 0.06, 0.6), k.frame_dark)
	k.cylinder(_root, bowl + Vector3(0, -0.14, 0), 0.24, 0.28, k.frame_dark, Y, 20)
	k.cylinder(_root, bowl + Vector3(0, 0.06, 0), 0.44, 0.16, k.polished, Y, 28, 0.48)
	k.cylinder(_root, bowl + Vector3(0, 0.05, 0), 0.4, 0.12, _product, Y, 28)
	var track := k.box(_root, bowl + Vector3(0.28, -0.2, 0.3), Vector3(0.5, 0.03, 0.08), k.chrome)
	track.rotation = Vector3(0, -0.6, -0.7)
	# Lidding foil and the heated sealing platen.
	var foil := _spinner(Vector3(0.45, 2.05, -0.2), "LiddingFoil", Vector3.BACK, -3.0)
	k.cylinder(foil, Vector3.ZERO, 0.22, 0.8, k.chrome, Z, 22)
	k.cylinder(foil, Vector3.ZERO, 0.05, 0.9, k.frame_dark, Z, 12)
	for z: float in [-0.72, 0.72]:
		k.box(_root, Vector3(0.45, 1.6, z), Vector3(0.5, 1.1, 0.1), k.stainless)
	_ram = k.pivot(_root, Vector3(0.45, 1.5, 0), "SealingPlaten")
	_moving.append(_ram)
	k.box(_ram, Vector3.ZERO, Vector3(0.42, 0.14, 1.2), k.stainless_dark)
	k.box(_ram, Vector3(0, -0.09, 0), Vector3(0.4, 0.04, 1.16), k.signal_red)
	for z: float in [-0.4, 0.4]:
		k.cylinder(_ram, Vector3(0, 0.3, z), 0.025, 0.46, k.chrome, Y, 10)
	# Wallet cartoner: printed card magazine, folding station and discharge.
	k.box(_root, Vector3(1.65, 1.48, 0), Vector3(0.95, 0.8, 1.3), _cabinet)
	k.box(_root, Vector3(1.65, 1.48, 0.655), Vector3(0.7, 0.5, 0.008), k.glass)
	for index in 14:
		k.box(_root, Vector3(1.65, 1.9 + index * 0.012, -0.25), Vector3(0.3, 0.008, 0.42), _package)
	k.box(_root, Vector3(1.65, 1.89, -0.25), Vector3(0.36, 0.02, 0.48), k.polished)
	k.pipe(_root, Vector3(-0.1, 2.24, -0.9), Vector3(-0.1, 2.24, 0.5), 0.03, k.polished)
	k.pipe(_root, Vector3(-0.1, 2.24, 0.5), Vector3(-0.1, 1.78, 0.95), 0.03, k.polished)
	k.joint(_root, Vector3(-0.1, 2.24, 0.5), 0.04, k.polished)
	k.box(_root, Vector3(-0.1, 1.2, -0.9), Vector3(0.1, 2.1, 0.1), k.frame_dark)
	k.pendant(_root, Vector3(-0.1, 1.62, 0.98))
	_cabinet_at(Vector3(0.5, 0, -1.48), Vector3(1.4, 1.4, 0.42), 1.0)
	beacon_mount = Vector3(1.65, 1.88, 0.45)
	_load_train(3, Vector3(0.36, 0.03, 0.6), &"wallet")


# --- Bottle filler -----------------------------------------------------------------

func _bottler() -> void:
	var k := _kit
	var half := _length * 0.5
	var top := BED_Y + 0.05
	# Rotary counting filler: product hopper over a turning counting head with filling chutes.
	var filler := Vector3(-0.75, 0, 0)
	k.box(_root, filler + Vector3(0, 1.25, -0.9), Vector3(0.24, 2.5, 0.24), _cabinet)
	k.box(_root, filler + Vector3(0, 2.32, -0.45), Vector3(0.24, 0.2, 0.9), _cabinet)
	k.box(_root, filler + Vector3(0, 0.06, -0.9), Vector3(0.5, 0.12, 0.5), k.frame_dark)
	k.cylinder(_root, filler + Vector3(0, 2.62, 0), 0.16, 0.5, k.stainless, Y, 24, 0.46)
	k.cylinder(_root, filler + Vector3(0, 2.88, 0), 0.48, 0.04, k.stainless_dark, Y, 24)
	var head := _spinner(filler + Vector3(0, 1.95, 0), "CountingHead", Vector3.UP, 1.6)
	k.cylinder(head, Vector3.ZERO, 0.5, 0.3, k.stainless, Y, 28)
	k.cylinder(head, Vector3(0, 0.17, 0), 0.38, 0.04, k.polished, Y, 28)
	for index in 10:
		var angle := index * TAU / 10
		var at := Vector3(cos(angle) * 0.4, -0.38, sin(angle) * 0.4)
		k.cylinder(head, at, 0.035, 0.5, k.polished, Y, 10, 0.05)
		k.box(head, Vector3(cos(angle) * 0.44, 0.0, sin(angle) * 0.44), Vector3(0.06, 0.2, 0.06), k.screen)
	var star := _spinner(filler + Vector3(0, top + 0.08, 0), "StarWheel", Vector3.UP, -1.6)
	k.cylinder(star, Vector3.ZERO, 0.42, 0.03, k.polished, Y, 28)
	for index in 10:
		var angle := index * TAU / 10
		k.box(star, Vector3(cos(angle) * 0.43, 0, sin(angle) * 0.43), Vector3(0.05, 0.035, 0.05), k.seam)
	k.box(_root, filler + Vector3(0, 1.52, 0.7), Vector3(0.9, 0.5, 0.012), k.glass)
	k.box(_root, filler + Vector3(0, 1.79, 0.7), Vector3(0.94, 0.04, 0.03), k.safety)
	# Capper: cap sorting bowl, cap chute and a turning chuck head.
	var capper := Vector3(0.55, 0, 0)
	for z: float in [-0.72, 0.72]:
		k.box(_root, capper + Vector3(0, 1.5, z), Vector3(0.12, 1.0, 0.12), _cabinet)
	k.box(_root, capper + Vector3(0, 2.02, 0), Vector3(0.5, 0.12, 1.56), _cabinet)
	k.cylinder(_root, capper + Vector3(0.05, 2.32, -0.35), 0.32, 0.18, k.polished, Y, 24, 0.36)
	k.cylinder(_root, capper + Vector3(0.05, 2.33, -0.35), 0.28, 0.1, k.gauge, Y, 24)
	var cap_chute := k.box(_root, capper + Vector3(-0.1, 1.85, -0.15), Vector3(0.06, 0.04, 0.5), k.chrome)
	cap_chute.rotation.x = -0.5
	var chucks := _spinner(capper + Vector3(0, 1.62, 0), "CappingChucks", Vector3.UP, 5.0)
	k.cylinder(chucks, Vector3.ZERO, 0.2, 0.12, k.stainless_dark, Y, 20)
	for index in 4:
		var angle := index * TAU / 4
		k.cylinder(chucks, Vector3(cos(angle) * 0.14, -0.2, sin(angle) * 0.14), 0.04, 0.28, k.chrome, Y, 12)
	# Wrap-around labeller.
	var labeller := Vector3(1.55, 0, 0.7)
	k.box(_root, labeller + Vector3(0, 0.62, 0.08), Vector3(0.12, 1.24, 0.12), k.frame_dark)
	k.box(_root, labeller + Vector3(0, 1.32, 0), Vector3(0.5, 0.34, 0.2), k.stainless_dark)
	var reel := _spinner(labeller + Vector3(-0.08, 1.62, 0.02), "LabelReel", Vector3.BACK, -3.5)
	k.cylinder(reel, Vector3.ZERO, 0.17, 0.1, k.gauge, Z, 22)
	k.cylinder(reel, Vector3.ZERO, 0.05, 0.14, k.frame_dark, Z, 12)
	k.box(_root, labeller + Vector3(0.12, 1.12, -0.12), Vector3(0.06, 0.14, 0.12), k.polished)
	_cabinet_at(Vector3(0.2, 0, -1.5), Vector3(1.4, 1.4, 0.42), 1.0)
	_hmi_pedestal(Vector3(half - 0.35, 1.35, 1.05))
	beacon_mount = Vector3(capper.x, 2.08, 0.55)
	_load_train(3, Vector3(0.3, 0.16, 0.62), &"bottle")


# --- Gum conditioning --------------------------------------------------------------

func _climate_unit() -> void:
	# Dehumidifier and climate controller that hold the conditioning air at a set humidity.
	var k := _kit
	var x := -_length * 0.5 + 0.7
	k.box(_root, Vector3(x, 0.06, -1.45), Vector3(1.0, 0.12, 0.6), k.frame_dark)
	k.box(_root, Vector3(x, 0.82, -1.45), Vector3(0.95, 1.4, 0.55), k.panel_white)
	k.box(_root, Vector3(x, 1.1, -1.17), Vector3(0.7, 0.5, 0.008), k.vent)
	k.box(_root, Vector3(x + 0.25, 0.55, -1.168), Vector3(0.22, 0.12, 0.006), k.screen)
	k.pipe(_root, Vector3(x, 1.52, -1.45), Vector3(x, 1.95, -1.45), 0.12, k.stainless_dark)
	k.pipe(_root, Vector3(x, 1.95, -1.45), Vector3(x + 0.6, 1.95, -0.9), 0.12, k.stainless_dark)
	k.joint(_root, Vector3(x, 1.95, -1.45), 0.13, k.stainless_dark)
