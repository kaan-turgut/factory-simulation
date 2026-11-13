extends RefCounted
## Detailed process equipment: batch wafer ovens and chocolate enrobers.
##
## The models are built from Godot primitive meshes and a small shared set of PBR
## materials. Their textures (brushed steel, painted steel, ribbed cladding, wire
## belt, perforated vents and hazard stripes) are generated once at startup, so no
## image files are needed. Static parts are merged per material, so each machine
## costs roughly one draw call per material it uses. Small details stop drawing
## and casting shadows when the camera is far away.
##
## Everything here is visual. Simulation state is only read, never written.

const Primitives = preload("res://world/primitives.gd")
const Equipment = preload("res://world/equipment_view.gd")
const Stock = preload("res://world/stock_models.gd")

const X := 0
const Y := 1
const Z := 2
## Fine detail is merged per material, so it is cheap; it only stops drawing beyond the whole hall.
const DETAIL_RANGE := 170.0
## Small plate text is clutter from afar.
const PLATE_RANGE := 48.0
const MILK := Color("#86533f")


## Moving parts of one oven, used by the floor's existing door and heater logic.
class OvenModel:
	var root: Node3D
	var door: Node3D
	var heater: Node3D


## Moving parts of one enrober. Motion follows the coater's recorded output, so it
## stops when production stops and speeds up with the simulation multiplier.
class EnroberModel:
	const BELT_LENGTH := 4.84
	const BELT_REPEAT := 24.0
	const TRAVEL_PER_KG := 0.6
	const SPROCKET_RADIUS := 0.15
	const OUTFEED_START := 1.12
	const OUTFEED_SPAN := 1.25

	var root: Node3D
	var belt: StandardMaterial3D
	var chocolate: StandardMaterial3D
	var curtain: Node3D
	var loads: Node3D
	var sprocket: Node3D
	var _running := true
	var _output := -1.0

	func animate(output_kg: float, running: bool) -> void:
		if running != _running:
			_running = running
			curtain.visible = running
			loads.visible = running
		if is_equal_approx(output_kg, _output):
			return
		_output = output_kg
		var travel := output_kg * TRAVEL_PER_KG
		belt.uv1_offset.x = -fposmod(travel * BELT_REPEAT / BELT_LENGTH, 1.0)
		sprocket.rotation.z = -fposmod(travel / SPROCKET_RADIUS, TAU)
		var count := loads.get_child_count()
		for index in count:
			var item := loads.get_child(index) as Node3D
			item.position.x = OUTFEED_START + fposmod(travel + index * OUTFEED_SPAN / count, OUTFEED_SPAN)

	func tint(color: Color) -> void:
		if chocolate.albedo_color != color:
			chocolate.albedo_color = color


var _draw: Primitives
var _stock: Stock
var _paints: Dictionary[Color, StandardMaterial3D] = {}
var _concrete: Dictionary[Color, StandardMaterial3D] = {}
var _ribbed: Dictionary[Color, StandardMaterial3D] = {}
var _flat: Array[Material] = []

var stainless: StandardMaterial3D
var stainless_dark: StandardMaterial3D
var polished: StandardMaterial3D
var frame_dark: StandardMaterial3D
var seam: StandardMaterial3D
var glass: StandardMaterial3D
var cladding: StandardMaterial3D
var safety: StandardMaterial3D
var signal_red: StandardMaterial3D
var motor: StandardMaterial3D
var screen: StandardMaterial3D
var lens: StandardMaterial3D
var gauge: StandardMaterial3D
var pad: StandardMaterial3D
var hazard: StandardMaterial3D
var vent: StandardMaterial3D
var glow: StandardMaterial3D
var rubber: StandardMaterial3D
var grating: StandardMaterial3D
var panel_white: StandardMaterial3D
var film: StandardMaterial3D
var chrome: StandardMaterial3D

var _brushed_rough: ImageTexture
var _brushed_normal: ImageTexture
var _grime: ImageTexture
var _peel_normal: ImageTexture
var _rib_normal: ImageTexture
var _mesh_albedo: ImageTexture
var _belt_albedo: ImageTexture
var _grating_albedo: ImageTexture


func _init(draw: Primitives, stock: Stock) -> void:
	_draw = draw
	_stock = stock
	_build_textures()
	_build_materials()


# --- Ovens -----------------------------------------------------------------------

func build_oven(station: Equipment, title: String, accent: Color) -> OvenModel:
	var model := OvenModel.new()
	var root := model_root(station, "OvenModel")
	model.root = root
	var cabinet := paint(accent)

	# Housekeeping pad, plinth and the insulated stainless chamber.
	box(root, Vector3(0, 0.025, 0), Vector3(4.86, 0.05, 3.86), pad)
	box(root, Vector3(-0.42, 0.052, 1.88), Vector3(3.2, 0.004, 0.09), hazard)
	box(root, Vector3(-0.35, 0.175, -0.125), Vector3(3.56, 0.25, 2.8), frame_dark)
	box(root, Vector3(-0.35, 1.675, -0.125), Vector3(3.6, 2.75, 2.85), stainless)
	box(root, Vector3(-0.35, 3.15, -0.125), Vector3(3.68, 0.2, 2.93), stainless_dark)
	for z: float in [-0.85, -0.1, 0.65]:
		for x: float in [-2.156, 1.456]:
			box(root, Vector3(x, 1.675, z), Vector3(0.012, 2.7, 0.018), seam)
	for x: float in [-1.25, -0.35, 0.55]:
		box(root, Vector3(x, 1.675, -1.556), Vector3(0.018, 2.7, 0.012), seam)
	box(root, Vector3(-0.35, 1.0, -1.558), Vector3(1.2, 0.5, 0.012), vent)
	# Door gasket and the rack ramp in front of the chamber.
	box(root, Vector3(-0.425, 2.905, 1.303), Vector3(3.05, 0.04, 0.008), seam)
	for x: float in [-1.93, 1.08]:
		box(root, Vector3(x, 1.63, 1.303), Vector3(0.04, 2.55, 0.008), seam)
	box(root, Vector3(-0.425, 0.2, 1.57), Vector3(2.9, 0.035, 0.58), stainless_dark).rotation.x = 0.42

	# Hinged door. The pivot keeps the hinge on the left so the floor's swing animation applies.
	var door := pivot(root, Vector3(-1.90, 1.63, 1.36), "OvenDoor")
	model.door = door
	box(door, Vector3(1.475, 0, 0), Vector3(2.95, 2.48, 0.11), stainless)
	box(door, Vector3(1.475, 0.32, 0.06), Vector3(1.86, 0.96, 0.012), seam)
	box(door, Vector3(1.475, 0.32, 0.068), Vector3(1.72, 0.82, 0.01), glass)
	box(door, Vector3(1.475, -1.05, 0.058), Vector3(2.85, 0.3, 0.008), stainless_dark)
	box(door, Vector3(1.475, 0.95, 0.058), Vector3(0.62, 0.11, 0.006), safety)
	cylinder(door, Vector3(2.70, 0.05, 0.16), 0.03, 1.1, polished, Y, 12)
	for y: float in [-0.42, 0.52]:
		cylinder(door, Vector3(2.70, y, 0.10), 0.02, 0.12, polished, Z, 10)
	for y: float in [-0.9, 0.0, 0.9]:
		cylinder(door, Vector3(0.0, y, 0.0), 0.045, 0.22, polished, Y, 12)
	plate(door, Vector3(1.475, 0.95, 0.0625), "HOT SURFACE", Color("#1b1f22"), 0.0014)

	# Glowing chamber seen through the window while cooking, with rack shelves.
	var heater := pivot(door, Vector3(1.475, 0.32, 0.075), "OvenGlow")
	model.heater = heater
	box(heater, Vector3.ZERO, Vector3(1.70, 0.80, 0.004), glow)
	for index in 4:
		box(heater, Vector3(0, -0.27 + index * 0.18, 0.003), Vector3(1.70, 0.03, 0.004), seam)
	for x: float in [-0.55, 0.55]:
		box(heater, Vector3(x, 0, 0.003), Vector3(0.03, 0.80, 0.004), seam)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 0, 0.9)
	light.light_color = Color("#ff9a52")
	light.light_energy = 1.2
	light.omni_range = 3.0
	light.shadow_enabled = false
	heater.add_child(light)

	# Control cabinet with HMI, emergency stop and stack light.
	box(root, Vector3(1.94, 0.1, 0.5), Vector3(0.9, 0.1, 1.52), frame_dark)
	box(root, Vector3(1.94, 1.25, 0.5), Vector3(0.88, 2.4, 1.5), cabinet)
	for x: float in [1.53, 2.35]:
		box(root, Vector3(x, 1.3, 1.256), Vector3(0.012, 2.1, 0.012), seam)
	for y: float in [0.25, 2.35]:
		box(root, Vector3(1.94, y, 1.256), Vector3(0.83, 0.012, 0.012), seam)
	box(root, Vector3(2.28, 1.25, 1.275), Vector3(0.04, 0.3, 0.04), polished)
	control_face(root, Vector3(1.92, 1.72, 1.265), Vector3(1.72, 1.3, 1.262))
	for x: float in [1.95, 2.08]:
		cylinder(root, Vector3(x, 1.3, 1.27), 0.028, 0.03, seam, Z, 10)
	for y: float in [0.7, 2.0]:
		box(root, Vector3(2.386, y, 0.5), Vector3(0.012, 0.4, 0.7), vent)
	box(root, Vector3(1.94, 2.89, -0.15), Vector3(0.16, 0.88, 0.1), frame_dark)
	box(root, Vector3(1.12, 3.3, -0.15), Vector3(1.64, 0.07, 0.2), frame_dark)
	stack_light(station, root, Vector3(2.15, 2.45, 0.95))

	# Gas train and burner on the left side: yellow gas line, valve, regulator and gauge.
	box(root, Vector3(-2.33, 1.05, -0.55), Vector3(0.34, 0.75, 0.9), motor)
	cylinder(root, Vector3(-2.505, 1.1, -0.55), 0.06, 0.02, glass, X, 12)
	cylinder(root, Vector3(-2.36, 0.07, 0.45), 0.07, 0.04, frame_dark, Y, 12)
	pipe(root, Vector3(-2.36, 0.05, 0.45), Vector3(-2.36, 1.55, 0.45), 0.032, safety)
	pipe(root, Vector3(-2.36, 1.55, 0.45), Vector3(-2.36, 1.55, -0.1), 0.032, safety)
	pipe(root, Vector3(-2.36, 1.55, -0.1), Vector3(-2.36, 1.42, -0.1), 0.032, safety)
	joint(root, Vector3(-2.36, 1.55, 0.45), 0.04, safety)
	joint(root, Vector3(-2.36, 1.55, -0.1), 0.04, safety)
	box(root, Vector3(-2.36, 0.85, 0.45), Vector3(0.11, 0.14, 0.11), polished)
	box(root, Vector3(-2.36, 0.93, 0.56), Vector3(0.03, 0.03, 0.24), signal_red)
	cylinder(root, Vector3(-2.36, 1.15, 0.45), 0.07, 0.1, motor, Y, 14)
	dial(root, Vector3(-2.36, 1.3, 0.45), X)

	# Steam hood over the door with its vent stack and damper.
	box(root, Vector3(-0.425, 3.22, 1.55), Vector3(3.1, 0.12, 0.6), stainless)
	box(root, Vector3(-0.425, 3.13, 1.84), Vector3(3.1, 0.18, 0.025), stainless)
	box(root, Vector3(-0.425, 3.155, 1.55), Vector3(2.9, 0.01, 0.5), vent)
	plate(root, Vector3(-0.425, 3.13, 1.8535), title.to_upper(), Color("#1d2830"), 0.0026)
	cylinder(root, Vector3(-0.425, 3.865, 1.45), 0.11, 1.17, stainless, Y, 16)
	cylinder(root, Vector3(-0.425, 3.7, 1.45), 0.125, 0.05, stainless_dark, Y, 16)
	box(root, Vector3(-0.245, 3.7, 1.45), Vector3(0.22, 0.025, 0.025), signal_red)
	rain_cap(root, Vector3(-0.425, 4.45, 1.45), 0.2, 0.08)

	# Insulated flue with bands and a rain cap, fed by the combustion blower.
	cylinder(root, Vector3(-1.35, 3.30, -0.85), 0.34, 0.1, stainless_dark, Y, 20)
	cylinder(root, Vector3(-1.35, 4.475, -0.85), 0.24, 2.45, cladding, Y, 20)
	for y: float in [3.8, 4.4, 5.0, 5.6]:
		cylinder(root, Vector3(-1.35, y, -0.85), 0.252, 0.035, stainless_dark, Y, 20)
	cylinder(root, Vector3(-1.35, 5.72, -0.85), 0.3, 0.05, stainless_dark, Y, 20)
	rain_cap(root, Vector3(-1.35, 5.745, -0.85), 0.42, 0.18)
	box(root, Vector3(0.55, 3.28, -0.85), Vector3(0.95, 0.06, 0.55), frame_dark)
	cylinder(root, Vector3(0.25, 3.62, -0.85), 0.3, 0.2, motor, X, 20)
	box(root, Vector3(0.62, 3.34, -0.85), Vector3(0.3, 0.08, 0.2), frame_dark)
	drive_motor(root, Vector3(0.62, 3.55, -0.85), 0.17, 0.42, X)
	pipe(root, Vector3(0.15, 3.62, -0.85), Vector3(-1.12, 3.62, -0.85), 0.09, stainless_dark)

	# Rear utilities: water line, drain and electrical conduit.
	pipe(root, Vector3(1.45, 0.6, -1.63), Vector3(-1.9, 0.6, -1.63), 0.022, polished)
	pipe(root, Vector3(-1.9, 0.6, -1.63), Vector3(-1.9, 0.05, -1.63), 0.022, polished)
	joint(root, Vector3(-1.9, 0.6, -1.63), 0.03, polished)
	for x: float in [-1.4, -0.4, 0.6]:
		box(root, Vector3(x, 0.6, -1.6), Vector3(0.04, 0.08, 0.06), frame_dark)
	pipe(root, Vector3(1.45, 2.85, -1.62), Vector3(-2.0, 2.85, -1.62), 0.03, frame_dark)

	var dynamic: Array[MeshInstance3D] = [station.beacon]
	finish(root, dynamic)
	finish(door)
	finish(heater)
	return model


# --- Enrobers --------------------------------------------------------------------

func build_enrober(station: Equipment, title: String, accent: Color) -> EnroberModel:
	var model := EnroberModel.new()
	var root := model_root(station, "EnroberModel")
	model.root = root
	var cabinet := paint(accent)
	model.chocolate = make_surface(MILK, 0.16, 0.0)
	model.belt = make_surface(Color("#c7d0d4"), 0.4, 0.55)
	model.belt.albedo_texture = _mesh_albedo
	model.belt.uv1_scale = Vector3(EnroberModel.BELT_REPEAT, 6.0, 1.0)
	_flat.append(model.belt)

	box(root, Vector3(0, 0.025, 0), Vector3(4.86, 0.05, 3.86), pad)

	# Stainless frame on levelling feet carrying the wire belt end to end.
	for x: float in [-2.32, -1.05, 1.05, 2.32]:
		for z: float in [-0.52, 0.82]:
			box(root, Vector3(x, 0.5, z), Vector3(0.07, 0.9, 0.07), stainless)
			cylinder(root, Vector3(x, 0.065, z), 0.06, 0.03, polished, Y, 12)
	for z: float in [-0.52, 0.82]:
		box(root, Vector3(0, 0.94, z), Vector3(4.8, 0.12, 0.06), stainless)
		for x: float in [-1.685, 1.685]:
			box(root, Vector3(x, 0.3, z), Vector3(1.27, 0.05, 0.05), stainless)
	for x: float in [-2.32, 2.32]:
		box(root, Vector3(x, 0.3, 0.15), Vector3(0.06, 0.06, 1.34), stainless)
	var belt := PlaneMesh.new()
	belt.size = Vector2(EnroberModel.BELT_LENGTH, 1.2)
	add_mesh(root, Vector3(0, 1.0, 0.15), belt, model.belt)
	box(root, Vector3(0, 0.9, 0.15), Vector3(4.84, 0.02, 1.18), seam)
	for x: float in [-2.42, 2.42]:
		cylinder(root, Vector3(x, 0.95, 0.15), 0.055, 1.26, polished, Z, 16)
	for z: float in [-0.42, 0.72]:
		box(root, Vector3(-1.75, 1.07, z), Vector3(1.4, 0.03, 0.02), polished)
		for x: float in [-2.3, -1.2]:
			box(root, Vector3(x, 1.03, z), Vector3(0.02, 0.06, 0.02), polished)
	box(root, Vector3(1.7, 0.86, 0.15), Vector3(1.4, 0.03, 1.2), stainless_dark)

	# Tempering tank below the curtain, with sight glass, thermometer and drain.
	box(root, Vector3(0, 0.45, 0.15), Vector3(1.9, 0.8, 1.46), stainless)
	box(root, Vector3(0, 0.87, 0.15), Vector3(1.96, 0.05, 1.52), stainless_dark)
	for x: float in [-0.32, 0.32]:
		box(root, Vector3(x, 0.45, 0.882), Vector3(0.012, 0.78, 0.008), seam)
	box(root, Vector3(0.62, 0.55, 0.883), Vector3(0.36, 0.14, 0.008), seam)
	box(root, Vector3(0.62, 0.55, 0.889), Vector3(0.3, 0.09, 0.006), glass)
	dial(root, Vector3(-0.62, 0.6, 0.88), Z)
	pipe(root, Vector3(-0.85, 0.18, 0.88), Vector3(-0.85, 0.18, 1.02), 0.03, polished)
	box(root, Vector3(-0.85, 0.24, 1.0), Vector3(0.2, 0.025, 0.025), signal_red)

	# Chocolate pump and heated riser to the flow pan above the belt.
	box(root, Vector3(0.05, 0.1, -0.95), Vector3(0.85, 0.1, 0.4), frame_dark)
	cylinder(root, Vector3(-0.15, 0.32, -0.95), 0.13, 0.26, stainless_dark, X, 16)
	box(root, Vector3(0.05, 0.32, -0.95), Vector3(0.12, 0.16, 0.16), safety)
	drive_motor(root, Vector3(0.3, 0.32, -0.95), 0.12, 0.36, X)
	pipe(root, Vector3(-0.15, 0.32, -0.82), Vector3(-0.15, 0.32, -0.58), 0.04, polished)
	pipe(root, Vector3(-0.15, 0.45, -0.95), Vector3(-0.15, 1.97, -0.95), 0.045, polished)
	joint(root, Vector3(-0.15, 1.97, -0.95), 0.055, polished)
	pipe(root, Vector3(-0.15, 1.97, -0.95), Vector3(-0.15, 1.97, -0.5), 0.045, polished)
	box(root, Vector3(-0.15, 1.94, 0.15), Vector3(0.32, 0.14, 1.3), stainless)

	# Hot-water set that keeps the tank jacket tempered.
	box(root, Vector3(1.0, 0.45, -1.55), Vector3(0.5, 0.8, 0.5), cabinet)
	dial(root, Vector3(1.0, 0.65, -1.3), Z)
	pipe(root, Vector3(0.88, 0.62, -1.3), Vector3(0.88, 0.62, -0.58), 0.025, signal_red)
	pipe(root, Vector3(0.78, 0.32, -1.3), Vector3(0.78, 0.32, -0.58), 0.025, motor)

	# Premelt kettle with agitator drive, feeding the tank.
	var kettle := Vector3(-1.75, 0, -1.3)
	for index in 3:
		var angle := index * TAU / 3.0 + 0.5
		cylinder(root, kettle + Vector3(cos(angle) * 0.3, 0.2, sin(angle) * 0.3), 0.03, 0.3, polished, Y, 10)
	cylinder(root, kettle + Vector3(0, 0.38, 0), 0.12, 0.14, stainless, Y, 24, 0.42)
	cylinder(root, kettle + Vector3(0, 0.85, 0), 0.42, 0.8, stainless, Y, 24)
	for y: float in [0.7, 1.0]:
		cylinder(root, kettle + Vector3(0, y, 0), 0.425, 0.03, stainless_dark, Y, 24)
	cylinder(root, kettle + Vector3(0, 1.28, 0), 0.44, 0.06, stainless_dark, Y, 24)
	cylinder(root, kettle + Vector3(0, 1.42, 0), 0.1, 0.22, motor, Y, 14)
	drive_motor(root, kettle + Vector3(0, 1.63, 0), 0.09, 0.2, Y)
	pipe(root, kettle + Vector3(0, 0.31, 0), kettle + Vector3(0, 0.22, 0), 0.03, polished)
	pipe(root, kettle + Vector3(0, 0.22, 0), kettle + Vector3(0, 0.22, 0.9), 0.03, polished)
	pipe(root, kettle + Vector3(0, 0.22, 0.9), Vector3(-0.95, 0.22, -0.4), 0.03, polished)
	joint(root, kettle + Vector3(0, 0.22, 0), 0.04, polished)
	joint(root, kettle + Vector3(0, 0.22, 0.9), 0.04, polished)
	box(root, kettle + Vector3(0.12, 0.27, 0.45), Vector3(0.2, 0.025, 0.025), signal_red)

	# Coating hood: stainless canopy with an open, guarded inspection front.
	box(root, Vector3(0, 1.77, -0.55), Vector3(2.04, 1.3, 0.04), stainless)
	for x: float in [-1.0, 1.0]:
		box(root, Vector3(x, 1.77, 0.185), Vector3(0.04, 1.3, 1.47), stainless)
	box(root, Vector3(0, 2.44, 0.185), Vector3(2.08, 0.06, 1.51), stainless)
	box(root, Vector3(0, 2.22, 0.92), Vector3(2.04, 0.38, 0.04), stainless)
	plate(root, Vector3(0, 2.22, 0.9405), title.to_upper(), Color("#1d2830"), 0.0026)
	box(root, Vector3(0, 1.14, 0.93), Vector3(2.04, 0.04, 0.04), safety)
	for x: float in [-0.34, 0.34]:
		box(root, Vector3(x, 1.585, 0.93), Vector3(0.035, 0.9, 0.035), safety)
	cylinder(root, Vector3(0, 2.02, 0.95), 0.02, 2.0, polished, X, 10)
	for x: float in [-0.6, 0.6]:
		box(root, Vector3(x, 2.06, 0.965), Vector3(0.18, 0.03, 0.03), polished)

	# Air knife and blower that remove excess coating.
	cylinder(root, Vector3(0.45, 1.3, 0.15), 0.04, 1.25, polished, Z, 12)
	box(root, Vector3(0.45, 1.24, 0.15), Vector3(0.05, 0.05, 1.2), stainless_dark)
	pipe(root, Vector3(0.45, 1.34, 0.15), Vector3(0.45, 2.4, 0.15), 0.07, stainless_dark)
	cylinder(root, Vector3(0.45, 2.62, 0.15), 0.3, 0.3, stainless_dark, Y, 20)
	drive_motor(root, Vector3(0.45, 2.93, 0.15), 0.15, 0.32, Y)
	stack_light(station, root, Vector3(-0.8, 2.47, 0.75))

	# Belt drive on the outfeed side: gear motor and a visible sprocket.
	box(root, Vector3(2.3, 0.62, 1.0), Vector3(0.22, 0.22, 0.18), motor)
	drive_motor(root, Vector3(2.0, 0.62, 1.0), 0.1, 0.35, X)
	cylinder(root, Vector3(2.42, 0.95, 0.95), 0.02, 0.34, polished, Z, 10)
	cylinder(root, Vector3(2.42, 0.95, 1.11), 0.06, 0.02, polished, Z, 14)
	var sprocket := pivot(root, Vector3(2.3, 0.62, 1.11), "BeltSprocket")
	model.sprocket = sprocket
	cylinder(sprocket, Vector3.ZERO, EnroberModel.SPROCKET_RADIUS, 0.025, polished, Z, 18)
	cylinder(sprocket, Vector3(0, 0, 0.02), 0.04, 0.05, seam, Z, 10)
	for index in 4:
		var spoke := box(sprocket, Vector3(0, 0, 0.016), Vector3(0.26, 0.03, 0.012), seam)
		spoke.rotation.z = index * PI * 0.25
	box(root, Vector3(2.36, 0.785, 1.11), Vector3(0.04, 0.33, 0.012), seam)

	# Control cabinet at the rear and an operator pedestal at the front.
	box(root, Vector3(1.95, 1.0, -1.45), Vector3(0.85, 1.9, 0.6), cabinet)
	for x: float in [1.55, 2.35]:
		box(root, Vector3(x, 1.0, -1.144), Vector3(0.012, 1.8, 0.012), seam)
	box(root, Vector3(2.25, 1.1, -1.13), Vector3(0.035, 0.25, 0.035), polished)
	box(root, Vector3(1.95, 0.4, -1.144), Vector3(0.5, 0.3, 0.008), vent)
	pipe(root, Vector3(1.7, 1.95, -1.3), Vector3(1.7, 2.3, -1.3), 0.03, frame_dark)
	pipe(root, Vector3(1.7, 2.3, -1.3), Vector3(0.8, 2.3, -0.57), 0.03, frame_dark)
	joint(root, Vector3(1.7, 2.3, -1.3), 0.035, frame_dark)
	cylinder(root, Vector3(1.55, 0.06, 1.4), 0.15, 0.02, frame_dark, Y, 16)
	cylinder(root, Vector3(1.55, 0.6, 1.4), 0.035, 1.1, polished, Y, 12)
	pendant(root, Vector3(1.55, 1.36, 1.4))

	# Product: uncoated sheets queued at the infeed (stock level), coated pieces at the outfeed.
	for index in 6:
		station.inventory_slots.append(_stock.wafer(root, Vector3(-2.25 + index * 0.21, 1.005, 0.15),
			Stock.COOKED, Vector3(0.17, 0.09, 0.95)))
	var curtain := pivot(root, Vector3.ZERO, "ChocolateCurtain")
	model.curtain = curtain
	box(curtain, Vector3(-0.15, 1.435, 0.15), Vector3(0.022, 0.87, 1.12), model.chocolate)
	box(curtain, Vector3(0.15, 1.012, 0.15), Vector3(0.6, 0.012, 1.1), model.chocolate)
	var loads := pivot(root, Vector3.ZERO, "CoatedPieces")
	model.loads = loads
	for index in 5:
		box(loads, Vector3(EnroberModel.OUTFEED_START, 1.035, 0.15), Vector3(0.17, 0.05, 0.95), model.chocolate)

	var dynamic: Array[MeshInstance3D] = [station.beacon]
	finish(root, dynamic)
	finish(sprocket)
	finish(curtain)
	return model


# --- Shared assemblies -----------------------------------------------------------

func stack_light(station: Equipment, parent: Node3D, base: Vector3) -> void:
	cylinder(parent, base + Vector3(0, 0.15, 0), 0.022, 0.3, polished, Y, 10)
	cylinder(parent, base + Vector3(0, 0.365, 0), 0.06, 0.13, lens, Y, 16)
	var lamp := StandardMaterial3D.new()
	lamp.roughness = 0.3
	lamp.emission_enabled = true
	lamp.emission_energy_multiplier = 0.8
	station.beacon = cylinder(parent, base + Vector3(0, 0.505, 0), 0.06, 0.13, lamp, Y, 16)
	cylinder(parent, base + Vector3(0, 0.59, 0), 0.062, 0.04, seam, Y, 16)


func control_face(parent: Node3D, display: Vector3, stop: Vector3) -> void:
	box(parent, display, Vector3(0.5, 0.36, 0.03), seam)
	box(parent, display + Vector3(0, 0.01, 0.018), Vector3(0.44, 0.28, 0.006), screen)
	box(parent, stop, Vector3(0.15, 0.15, 0.024), safety)
	cylinder(parent, stop + Vector3(0, 0, 0.028), 0.05, 0.04, signal_red, Z, 14)


func pendant(parent: Node3D, at: Vector3) -> void:
	# Operator panel tilted back towards a standing operator.
	var tilt := Basis(Vector3.RIGHT, -0.3)
	box(parent, at, Vector3(0.48, 0.36, 0.09), seam).basis = tilt
	box(parent, at + tilt * Vector3(0, 0.02, 0.047), Vector3(0.40, 0.24, 0.006), screen).basis = tilt
	var stop := cylinder(parent, at + tilt * Vector3(0.19, -0.14, 0.06), 0.035, 0.035, signal_red, Z, 12)
	stop.basis = tilt * stop.basis


func dial(parent: Node3D, at: Vector3, axis: int) -> void:
	var out := Vector3.BACK if axis == Z else Vector3.LEFT
	pipe(parent, at, at + out * 0.1, 0.012, polished)
	cylinder(parent, at + out * 0.115, 0.072, 0.025, seam, axis, 16)
	cylinder(parent, at + out * 0.12, 0.065, 0.03, gauge, axis, 16)


func drive_motor(parent: Node3D, at: Vector3, radius: float, length: float, axis: int) -> void:
	# Cooling-finned electric motor with fan cowl and terminal box.
	var along := Vector3.RIGHT if axis == X else Vector3.UP
	var across := Vector3.UP if axis == X else Vector3.BACK
	cylinder(parent, at, radius, length, motor, axis, 18)
	for index in 4:
		var offset := (-0.3 + index * 0.2) * length
		cylinder(parent, at + along * offset, radius * 1.08, length * 0.04, frame_dark, axis, 18)
	cylinder(parent, at + along * (length * 0.5 + 0.02), radius * 0.85, 0.05, frame_dark, axis, 16)
	box(parent, at + across * radius, Vector3(0.12, 0.08, 0.11) * clampf(radius / 0.15, 0.7, 1.3), motor)


func rain_cap(parent: Node3D, top: Vector3, radius: float, lift: float) -> void:
	for index in 3:
		var angle := index * TAU / 3.0
		var leg := top + Vector3(cos(angle), 0, sin(angle)) * radius * 0.45
		box(parent, leg + Vector3(0, lift * 0.5, 0), Vector3(0.02, lift, 0.02), stainless_dark)
	cylinder(parent, top + Vector3(0, lift + 0.1, 0), radius, 0.2, stainless_dark, Y, 20, radius * 0.1)


func foot(parent: Node3D, at: Vector3) -> void:
	# Hygienic levelling foot: threaded stem and a round pad.
	cylinder(parent, at + Vector3(0, 0.06, 0), 0.018, 0.12, polished, Y, 8)
	cylinder(parent, at + Vector3(0, 0.012, 0), 0.055, 0.024, polished, Y, 14)


func leg(parent: Node3D, at: Vector3, height: float, surface: Material = null) -> void:
	# Square stainless tube from the floor to `height`, standing on a levelling foot.
	var tube := stainless if surface == null else surface
	box(parent, Vector3(at.x, 0.12 + (height - 0.12) * 0.5, at.z), Vector3(0.06, height - 0.12, 0.06), tube)
	foot(parent, Vector3(at.x, 0, at.z))


func handrail(parent: Node3D, from: Vector3, to: Vector3, surface: Material = null, height: float = 1.05) -> void:
	# Tubular guard rail: posts about every 1.6 m, a top rail, a knee rail and a toe board.
	var tube := safety if surface == null else surface
	var span := to - from
	var count := maxi(1, ceili(span.length() / 1.6))
	for index in count + 1:
		var at := from.lerp(to, float(index) / count)
		cylinder(parent, at + Vector3.UP * height * 0.5, 0.024, height, tube, Y, 10)
	for y: float in [height, height * 0.5]:
		pipe(parent, from + Vector3.UP * y, to + Vector3.UP * y, 0.022, tube)
	if span.length() > 0.01:
		var kick := box(parent, (from + to) * 0.5 + Vector3.UP * 0.06, Vector3(0.012, 0.12, span.length()), tube)
		kick.basis = Basis.looking_at(span.normalized(), Vector3.UP)


func caster(parent: Node3D, at: Vector3, radius: float, swivel: bool = true) -> void:
	# Polyurethane caster wheel in a pressed-steel fork with a top plate.
	var top := at.y + radius + 0.04
	box(parent, Vector3(at.x, top + 0.008, at.z), Vector3(0.1, 0.016, 0.1), polished)
	if swivel:
		cylinder(parent, Vector3(at.x, top - 0.01, at.z), 0.03, 0.03, polished, Y, 10)
	for side: float in [-1.0, 1.0]:
		box(parent, Vector3(at.x + side * 0.032, at.y + radius * 0.55, at.z), Vector3(0.008, radius + 0.06, radius * 1.2), polished)
	cylinder(parent, at, radius, 0.045, rubber, X, 16)
	cylinder(parent, at, radius * 0.55, 0.05, polished, X, 12)


func scrolling_belt(tint: Color, repeat: Vector2) -> StandardMaterial3D:
	# Food-grade belt with faint cross ribs. Each conveyor owns one so it can scroll.
	var belt := make_surface(tint, 0.55, 0.0)
	belt.albedo_texture = _belt_albedo
	belt.uv1_scale = Vector3(repeat.x, repeat.y, 1.0)
	_flat.append(belt)
	return belt


func mark_flat(surface: Material) -> void:
	# Treat as fine detail: no shadow, not drawn beyond the detail range.
	if not surface in _flat:
		_flat.append(surface)


# --- Geometry helpers ------------------------------------------------------------

func model_root(station: Node3D, title: String) -> Node3D:
	return pivot(station, Vector3.ZERO, title)


func pivot(parent: Node3D, at: Vector3, title: String) -> Node3D:
	var node := Node3D.new()
	node.name = title
	node.position = at
	parent.add_child(node)
	return node


func add_mesh(parent: Node3D, at: Vector3, mesh: Mesh, surface: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.position = at
	instance.mesh = mesh
	instance.material_override = surface
	parent.add_child(instance)
	return instance


func box(parent: Node3D, at: Vector3, size: Vector3, surface: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return add_mesh(parent, at, mesh, surface)


func cylinder(
	parent: Node3D, at: Vector3, radius: float, height: float, surface: Material,
	axis: int = Y, segments: int = 20, top_radius: float = -1.0
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = segments
	mesh.rings = 0
	var instance := add_mesh(parent, at, mesh, surface)
	if axis == X:
		instance.rotation.z = PI * 0.5
	elif axis == Z:
		instance.rotation.x = PI * 0.5
	return instance


func pipe(parent: Node3D, from: Vector3, to: Vector3, radius: float, surface: Material) -> MeshInstance3D:
	var delta := to - from
	assert(delta.length() > 0.001, "Pipe ends must differ")
	var instance := cylinder(parent, from + delta * 0.5, radius, delta.length(), surface, Y, 12)
	var direction := delta.normalized()
	if direction.dot(Vector3.UP) < -0.999:
		instance.rotation.x = PI
	elif direction.dot(Vector3.UP) < 0.999:
		instance.quaternion = Quaternion(Vector3.UP, direction)
	return instance


func joint(parent: Node3D, at: Vector3, radius: float, surface: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	return add_mesh(parent, at, mesh, surface)


func plate(parent: Node3D, at: Vector3, text: String, tint: Color, pixel: float) -> Label3D:
	var label := Label3D.new()
	label.position = at
	label.text = text
	label.font_size = 48
	label.pixel_size = pixel
	label.modulate = tint
	label.outline_size = 0
	label.double_sided = false
	label.visibility_range_end = PLATE_RANGE
	parent.add_child(label)
	return label


func finish(root: Node3D, dynamic: Array[MeshInstance3D] = []) -> void:
	# Merge static parts per material, then drop shadows and far drawing for fine detail.
	_draw.batch_static(root, dynamic)
	for child in root.get_children():
		var piece := child as MeshInstance3D
		if piece == null or piece in dynamic:
			continue
		var surface := piece.material_override
		if surface == null and piece.mesh != null and piece.mesh.get_surface_count() > 0:
			surface = piece.mesh.surface_get_material(0)
		if surface in _flat:
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			piece.visibility_range_end = DETAIL_RANGE


# --- Materials -------------------------------------------------------------------

func paint(color: Color) -> StandardMaterial3D:
	# Painted steel with a faint orange-peel finish, shared by colour.
	if not _paints.has(color):
		var surface := make_surface(color, 0.52, 0.12)
		_detail(surface, null, null, _peel_normal, 0.18, 3.0)
		_paints[color] = surface
	return _paints[color]


func batch(node: Node3D) -> void:
	# Merge a node's static primitive children per material.
	_draw.batch_static(node)


func concrete(color: Color) -> StandardMaterial3D:
	# Floor slab: faint trowel blotches and grain, shared by shade.
	if not _concrete.has(color):
		var surface := make_surface(color, 0.88, 0.0)
		_detail(surface, _grime, null, _peel_normal, 0.12, 0.3)
		_concrete[color] = surface
	return _concrete[color]


func ribbed(color: Color) -> StandardMaterial3D:
	# Profiled wall cladding with horizontal ribs about every 25 cm.
	if not _ribbed.has(color):
		var surface := make_surface(color, 0.55, 0.2)
		_detail(surface, null, null, _rib_normal, 0.45, 1.0)
		_ribbed[color] = surface
	return _ribbed[color]


func _build_materials() -> void:
	stainless = make_surface(Color("#cdd6db"), 0.34, 0.55)
	_detail(stainless, null, _brushed_rough, _brushed_normal, 0.08, 0.8)
	stainless_dark = make_surface(Color("#949fa6"), 0.4, 0.5)
	_detail(stainless_dark, null, _brushed_rough, _brushed_normal, 0.08, 0.8)
	polished = make_surface(Color("#dfe6e9"), 0.2, 0.62)
	frame_dark = paint(Color("#2c3840"))
	motor = paint(Color("#3f5f7f"))
	safety = paint(Color("#e6b52c"))
	signal_red = make_surface(Color("#c0352b"), 0.35, 0.05)
	cladding = make_surface(Color("#b9c1c4"), 0.38, 0.55)
	_detail(cladding, null, null, _rib_normal, 0.6, 2.5)
	pad = make_surface(Color("#6a7175"), 0.9, 0.0)
	_detail(pad, _grime, null, _peel_normal, 0.15, 1.2)
	seam = make_surface(Color("#1b232a"), 0.7, 0.1)
	glass = make_surface(Color("#1d2a33"), 0.06, 0.35)
	screen = make_surface(Color("#122a2e"), 0.25, 0.0)
	screen.emission_enabled = true
	screen.emission = Color("#6fd0c2")
	screen.emission_energy_multiplier = 0.55
	lens = make_surface(Color("#d7dcd8"), 0.25, 0.0)
	gauge = make_surface(Color("#f0efe8"), 0.4, 0.0)
	glow = make_surface(Color("#3a1608"), 0.8, 0.0)
	glow.emission_enabled = true
	glow.emission = Color("#ff7a2e")
	glow.emission_energy_multiplier = 1.3
	hazard = make_surface(Color.WHITE, 0.7, 0.0)
	_detail(hazard, _hazard_texture(), null, null, 0.0, 3.0)
	vent = make_surface(Color.WHITE, 0.6, 0.3)
	_detail(vent, _vent_texture(), null, null, 0.0, 6.0)
	rubber = make_surface(Color("#1e2327"), 0.85, 0.0)
	chrome = make_surface(Color("#e8edf0"), 0.12, 0.85)
	panel_white = paint(Color("#e4e8e6"))
	film = make_surface(Color("#e9eef0"), 0.22, 0.25)
	grating = make_surface(Color.WHITE, 0.55, 0.6)
	_detail(grating, _grating_albedo, null, null, 0.0, 3.0)
	_flat.append_array([seam, glass, screen, gauge, hazard, vent, lens, glow])


func make_surface(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var surface := StandardMaterial3D.new()
	surface.albedo_color = color
	surface.roughness = roughness
	surface.metallic = metallic
	surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return surface


func _detail(
	surface: StandardMaterial3D, albedo: Texture2D, roughness: Texture2D, normal: Texture2D,
	normal_scale: float, scale: float
) -> void:
	# Object-space triplanar mapping keeps texel size constant on merged, rotated parts.
	if albedo != null:
		surface.albedo_texture = albedo
	if roughness != null:
		surface.roughness_texture = roughness
		surface.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	if normal != null:
		surface.normal_enabled = true
		surface.normal_texture = normal
		surface.normal_scale = normal_scale
	surface.uv1_triplanar = true
	surface.uv1_triplanar_sharpness = 4.0
	surface.uv1_scale = Vector3.ONE * scale


# --- Generated textures ----------------------------------------------------------

func _build_textures() -> void:
	# Brushed steel: one random value per row, stretched across the tile into streaks.
	var noise := FastNoiseLite.new()
	noise.seed = 11
	noise.frequency = 0.08
	noise.fractal_octaves = 4
	var rows := noise.get_seamless_image(16, 64)
	var random := RandomNumberGenerator.new()
	random.seed = 4242
	var rough := Image.create_empty(1, 64, false, Image.FORMAT_RGBA8)
	var height := Image.create_empty(1, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		var value := rows.get_pixel(0, y).r * 0.75 + random.randf() * 0.25
		rough.set_pixel(0, y, _gray(lerpf(0.78, 1.0, value)))
		height.set_pixel(0, y, _gray(value))
	rough.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	height.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	height.bump_map_to_normal_map(1.0)
	_brushed_rough = _texture(rough)
	_brushed_normal = _texture(height, true)

	# Low-frequency grime so large panels are not perfectly uniform.
	var blotches := FastNoiseLite.new()
	blotches.seed = 3
	blotches.frequency = 0.05
	var stain := blotches.get_seamless_image(64, 64)
	var grime := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var shade := lerpf(0.9, 1.0, stain.get_pixel(x, y).r)
			grime.set_pixel(x, y, _gray(shade))
	_grime = _texture(grime)

	# Orange-peel paint and concrete grain.
	var peel := FastNoiseLite.new()
	peel.seed = 19
	peel.frequency = 0.3
	var bumps := peel.get_seamless_image(64, 64)
	bumps.convert(Image.FORMAT_RGBA8)
	bumps.bump_map_to_normal_map(1.0)
	_peel_normal = _texture(bumps, true)

	# Ribbed cladding bands for the insulated flue.
	var ribs := Image.create_empty(1, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		ribs.set_pixel(0, y, _gray(0.5 + 0.5 * sin(y * TAU / 16.0)))
	ribs.resize(64, 64, Image.INTERPOLATE_NEAREST)
	ribs.bump_map_to_normal_map(1.0)
	_rib_normal = _texture(ribs, true)

	# Wire mesh belt: bright cross wires that make belt travel visible.
	var weave := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	weave.fill(Color(0.16, 0.17, 0.18))
	for y in range(0, 32, 4):
		weave.fill_rect(Rect2i(0, y, 32, 1), Color(0.42, 0.44, 0.45))
	for x in range(0, 32, 8):
		weave.fill_rect(Rect2i(x, 0, 2, 32), Color(0.9, 0.92, 0.93))
	_mesh_albedo = _texture(weave)

	# Plastic modular belt: light base with darker hinge lines across the travel direction.
	var modules := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	modules.fill(Color(0.93, 0.94, 0.93))
	for x in range(0, 32, 8):
		modules.fill_rect(Rect2i(x, 0, 1, 32), Color(0.66, 0.69, 0.70))
	for y in range(0, 32, 16):
		modules.fill_rect(Rect2i(0, y, 32, 1), Color(0.82, 0.84, 0.84))
	_belt_albedo = _texture(modules)

	# Bar grating for decks, treads and rack decking.
	var bars := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	bars.fill(Color(0.17, 0.19, 0.21))
	for x in range(0, 32, 4):
		bars.fill_rect(Rect2i(x, 0, 2, 32), Color(0.72, 0.75, 0.77))
	for y in range(0, 32, 16):
		bars.fill_rect(Rect2i(0, y, 32, 2), Color(0.62, 0.65, 0.67))
	_grating_albedo = _texture(bars)


func _hazard_texture() -> ImageTexture:
	var stripes := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var yellow := (((x + y) >> 4) & 1) == 0
			stripes.set_pixel(x, y, Color("#e6b52c") if yellow else Color("#1d2125"))
	return _texture(stripes)


func _vent_texture() -> ImageTexture:
	var holes := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	holes.fill(Color("#7d878c"))
	for y in range(2, 32, 8):
		for x in range(2, 32, 8):
			holes.fill_rect(Rect2i(x, y, 4, 4), Color("#14191d"))
	return _texture(holes)


func _gray(value: float) -> Color:
	return Color(value, value, value)


func _texture(image: Image, normal: bool = false) -> ImageTexture:
	image.generate_mipmaps(normal)
	return ImageTexture.create_from_image(image)
