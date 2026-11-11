extends RefCounted
## Detailed models for the rest of the line: dough extruder, ingredient hopper,
## cream mixer, roller conveyors, palletizing conveyor and stock shelving.
##
## Uses the shared industrial kit, so these machines share materials with the ovens
## and enrobers and cost about one draw call per material. Visual only: the floor
## reads simulation state and moves the returned pivots; nothing here writes state.

const Industrial = preload("res://world/industrial_models.gd")
const Equipment = preload("res://world/equipment_view.gd")

const X := Industrial.X
const Y := Industrial.Y
const Z := Industrial.Z
const CREAM := Color("#f1e6c8")

var _kit: Industrial


func _init(kit: Industrial) -> void:
	_kit = kit


# --- Dough extruder ----------------------------------------------------------------

## Builds the extruder under the ingredient deck. Returns the die cutter pivot, which
## turns about X with the extruder's output. `feed` is the hopper outlet in local space.
func build_extruder(station: Equipment, accent: Color, feed: Vector3) -> Node3D:
	var k := _kit
	var root := k.model_root(station, "ExtruderModel")
	var cabinet := k.paint(accent)
	var axis_y := 1.15
	var axis_z := feed.z
	k.box(root, Vector3(0, 0.025, 0), Vector3(4.86, 0.05, 3.7), k.pad)
	k.box(root, Vector3(-0.2, 0.05, 1.82), Vector3(3.6, 0.004, 0.09), k.hazard)
	# Skid with I-beam rails.
	for z: float in [axis_z - 0.45, axis_z + 0.45]:
		k.box(root, Vector3(-0.3, 0.14, z), Vector3(4.3, 0.18, 0.12), k.frame_dark)
	for x: float in [-2.2, -0.8, 0.6, 1.8]:
		k.box(root, Vector3(x, 0.14, axis_z), Vector3(0.12, 0.16, 1.0), k.frame_dark)
	# Main motor, coupling guard and gearbox.
	k.box(root, Vector3(-2.0, 0.42, axis_z), Vector3(0.7, 0.12, 0.62), k.frame_dark)
	k.drive_motor(root, Vector3(-2.0, 0.82, axis_z), 0.3, 0.75, X)
	k.box(root, Vector3(-1.52, 0.82, axis_z), Vector3(0.24, 0.42, 0.42), k.safety)
	k.box(root, Vector3(-1.02, 0.78, axis_z), Vector3(0.76, 1.12, 1.02), cabinet)
	k.box(root, Vector3(-1.02, 1.36, axis_z), Vector3(0.8, 0.05, 1.06), k.frame_dark)
	k.cylinder(root, Vector3(-1.02, 1.42, axis_z + 0.3), 0.05, 0.1, k.polished, Y, 10)
	k.dial(root, Vector3(-1.02, 0.7, axis_z + 0.51), Z)
	# Barrel with heater bands, thermocouples and cooling-water manifold.
	k.cylinder(root, Vector3(0.22, axis_y, axis_z), 0.3, 2.46, k.stainless, X, 24)
	for index in 5:
		var x := -0.5 + index * 0.42
		k.cylinder(root, Vector3(x, axis_y, axis_z), 0.335, 0.16, k.frame_dark, X, 24)
		k.box(root, Vector3(x, axis_y + 0.36, axis_z), Vector3(0.06, 0.06, 0.06), k.motor)
		k.pipe(root, Vector3(x, axis_y + 0.39, axis_z), Vector3(x, axis_y + 0.55, axis_z - 0.3), 0.01, k.seam)
	k.pipe(root, Vector3(-0.6, axis_y - 0.38, axis_z + 0.36), Vector3(1.3, axis_y - 0.38, axis_z + 0.36), 0.022, k.polished)
	k.pipe(root, Vector3(-0.6, axis_y - 0.3, axis_z + 0.36), Vector3(1.3, axis_y - 0.3, axis_z + 0.36), 0.022, k.signal_red)
	for x: float in [-0.3, 0.9]:
		k.box(root, Vector3(x, (axis_y - 0.3 + 0.23) * 0.5, axis_z), Vector3(0.16, axis_y - 0.53, 0.5), k.frame_dark)
	# Feed throat and the drop tube up to the hopper outlet through the deck.
	k.box(root, Vector3(feed.x, axis_y + 0.38, axis_z), Vector3(0.5, 0.3, 0.5), k.stainless_dark)
	k.cylinder(root, Vector3(feed.x, axis_y + 0.56, axis_z), 0.3, 0.06, k.polished, Y, 20)
	var top := feed.y - 0.025
	var bottom := axis_y + 0.6
	k.cylinder(root, Vector3(feed.x, (top + bottom) * 0.5, axis_z), 0.17, top - bottom, k.stainless, Y, 20)
	for y: float in [bottom + 0.4, top - 0.3]:
		k.cylinder(root, Vector3(feed.x, y, axis_z), 0.22, 0.04, k.polished, Y, 20)
	k.box(root, Vector3(feed.x + 0.12, bottom + 0.62, axis_z), Vector3(0.6, 0.1, 0.34), k.stainless_dark)
	k.cylinder(root, Vector3(feed.x + 0.5, bottom + 0.62, axis_z), 0.06, 0.3, k.motor, X, 12)
	k.cylinder(root, Vector3(feed.x, top - 0.12, axis_z), 0.19, 0.16, k.rubber, Y, 20)
	# Die head with breaker plate flange.
	k.cylinder(root, Vector3(1.5, axis_y, axis_z), 0.4, 0.1, k.stainless_dark, X, 24)
	k.cylinder(root, Vector3(1.6, axis_y, axis_z), 0.34, 0.1, k.polished, X, 24)
	for index in 8:
		var angle := index * TAU / 8.0
		k.cylinder(root, Vector3(1.5, axis_y + sin(angle) * 0.35, axis_z + cos(angle) * 0.35),
			0.022, 0.14, k.chrome, X, 8)
	var cutter := k.pivot(root, Vector3(1.7, axis_y, axis_z), "DieCutter")
	k.cylinder(cutter, Vector3.ZERO, 0.07, 0.08, k.frame_dark, X, 14)
	for index in 4:
		var angle := index * TAU / 4.0
		var blade := k.box(cutter, Vector3(0.02, sin(angle) * 0.17, cos(angle) * 0.17),
			Vector3(0.02, 0.05, 0.3), k.chrome)
		blade.rotation.x = angle
	# Guard over the die and the discharge chute towards the raw cart dock.
	k.box(root, Vector3(1.85, axis_y + 0.42, axis_z), Vector3(0.5, 0.04, 0.9), k.safety)
	for z: float in [-0.44, 0.44]:
		k.box(root, Vector3(1.85, axis_y + 0.1, axis_z + z), Vector3(0.5, 0.64, 0.03), k.glass)
	var chute := k.box(root, Vector3(2.0, 0.78, axis_z + 0.75), Vector3(0.55, 0.03, 1.4), k.stainless)
	chute.rotation.x = -0.32
	for x: float in [1.74, 2.26]:
		var lip := k.box(root, Vector3(x, 0.84, axis_z + 0.75), Vector3(0.03, 0.12, 1.4), k.stainless)
		lip.rotation.x = -0.32
	k.leg(root, Vector3(2.0, 0, axis_z + 1.3), 0.58)
	# Control cabinet and stack light at the front left.
	k.box(root, Vector3(-1.6, 0.06, 1.42), Vector3(1.04, 0.12, 0.5), k.frame_dark)
	k.box(root, Vector3(-1.6, 0.92, 1.42), Vector3(1.0, 1.6, 0.46), cabinet)
	k.box(root, Vector3(-1.6, 0.92, 1.654), Vector3(0.01, 1.48, 0.01), k.seam)
	k.box(root, Vector3(-1.25, 0.95, 1.665), Vector3(0.03, 0.22, 0.03), k.polished)
	k.control_face(root, Vector3(-1.85, 1.35, 1.66), Vector3(-1.85, 0.95, 1.656))
	k.box(root, Vector3(-1.6, 0.4, 1.654), Vector3(0.5, 0.2, 0.008), k.vent)
	k.pipe(root, Vector3(-1.4, 1.72, 1.3), Vector3(-1.4, 2.3, 1.3), 0.03, k.frame_dark)
	k.pipe(root, Vector3(-1.4, 2.3, 1.3), Vector3(-1.02, 2.3, axis_z), 0.03, k.frame_dark)
	k.stack_light(station, root, Vector3(-1.85, 1.72, 1.42))
	var dynamic: Array[MeshInstance3D] = [station.beacon]
	k.finish(root, dynamic)
	k.finish(cutter)
	return cutter


# --- Ingredient hopper on the deck -----------------------------------------------

## Bag-tip hopper above the extruder. Sacks waiting to be tipped sit on its grate.
func build_hopper(station: Equipment) -> void:
	var k := _kit
	var root := k.model_root(station, "HopperModel")
	for x: float in [-0.82, 0.82]:
		for z: float in [-0.82, 0.82]:
			k.leg(root, Vector3(x, 0, z), 1.2)
		k.box(root, Vector3(x, 0.45, 0), Vector3(0.04, 0.04, 1.64), k.stainless)
	for z: float in [-0.82, 0.82]:
		k.box(root, Vector3(0, 0.45, z), Vector3(1.64, 0.04, 0.04), k.stainless)
	# Cone, cylindrical bin, rim and grate.
	k.cylinder(root, Vector3(0, 0.08, 0), 0.16, 0.16, k.stainless, Y, 20)
	k.cylinder(root, Vector3(0, 0.55, 0), 0.18, 0.78, k.stainless, Y, 28, 0.96)
	k.cylinder(root, Vector3(0, 1.17, 0), 0.96, 0.46, k.stainless, Y, 28)
	k.cylinder(root, Vector3(0, 1.41, 0), 1.0, 0.04, k.stainless_dark, Y, 28)
	k.cylinder(root, Vector3(0, 1.43, 0), 0.93, 0.02, k.grating, Y, 28)
	for index in 2:
		var bar := k.box(root, Vector3(0, 1.445, 0), Vector3(1.86, 0.025, 0.04), k.stainless_dark)
		bar.rotation.y = index * PI * 0.5
	# Vibrator, level probes, sight glass and the dust hood with its extraction duct.
	k.box(root, Vector3(0.52, 0.62, 0), Vector3(0.12, 0.2, 0.2), k.motor)
	k.cylinder(root, Vector3(-0.5, 1.47, 0.5), 0.05, 0.08, k.frame_dark, Y, 10)
	k.box(root, Vector3(0, 1.2, -0.955), Vector3(0.36, 0.24, 0.02), k.glass)
	k.box(root, Vector3(0, 1.2, -0.95), Vector3(0.42, 0.3, 0.012), k.stainless_dark)
	k.box(root, Vector3(0, 1.82, 0.8), Vector3(1.5, 0.7, 0.3), k.stainless)
	k.box(root, Vector3(0, 2.2, 0.62), Vector3(1.5, 0.06, 0.66), k.stainless)
	k.box(root, Vector3(0, 1.72, 0.648), Vector3(1.3, 0.4, 0.008), k.vent)
	k.cylinder(root, Vector3(0.5, 2.6, 0.8), 0.13, 0.8, k.stainless_dark, Y, 18)
	k.box(root, Vector3(-0.78, 1.5, 1.0), Vector3(0.3, 0.3, 0.12), k.paint(Color("#c9cfd2")))
	k.box(root, Vector3(-0.78, 1.53, 1.064), Vector3(0.14, 0.08, 0.004), k.screen)
	k.finish(root)


# --- Cream mixer -------------------------------------------------------------------

## Jacketed mixing vessel. Returns the agitator coupling, which turns about Y.
func build_cream_mixer(station: Equipment, accent: Color) -> Node3D:
	var k := _kit
	var root := k.model_root(station, "CreamMixerModel")
	var tank := Vector3(0.14, 0, -0.28)
	var radius := 1.05
	k.box(root, Vector3(0, 0.025, 0), Vector3(4.86, 0.05, 4.86), k.pad)
	# Legs on load cells.
	for index in 4:
		var angle := index * PI * 0.5 + PI * 0.25
		var at := tank + Vector3(cos(angle), 0, sin(angle)) * (radius + 0.05)
		k.box(root, at + Vector3(0, 0.07, 0), Vector3(0.3, 0.04, 0.3), k.stainless_dark)
		k.box(root, at + Vector3(0, 0.12, 0), Vector3(0.16, 0.08, 0.16), k.motor)
		k.box(root, at + Vector3(0, 0.62, 0), Vector3(0.12, 0.96, 0.12), k.stainless)
		k.box(root, at.move_toward(tank, 0.1) + Vector3(0, 1.08, 0), Vector3(0.3, 0.12, 0.3), k.stainless)
	# Dished bottom, insulated jacket, bands, dished lid.
	k.cylinder(root, tank + Vector3(0, 0.82, 0), 0.22, 0.32, k.stainless, Y, 28, radius)
	k.cylinder(root, tank + Vector3(0, 1.68, 0), radius, 1.4, k.cladding, Y, 32)
	for y: float in [1.0, 1.68, 2.36]:
		k.cylinder(root, tank + Vector3(0, y, 0), radius + 0.015, 0.05, k.stainless_dark, Y, 32)
	k.cylinder(root, tank + Vector3(0, 2.48, 0), radius, 0.2, k.stainless, Y, 32, radius * 0.72)
	k.cylinder(root, tank + Vector3(0, 2.6, 0), radius * 0.72, 0.04, k.stainless_dark, Y, 32)
	# Manway with clamps, sight light, spray ball inlet and vent filter.
	var manway := tank + Vector3(-0.45, 2.62, 0.3)
	k.cylinder(root, manway, 0.25, 0.1, k.stainless, Y, 24)
	k.cylinder(root, manway + Vector3(0, 0.06, 0), 0.27, 0.03, k.polished, Y, 24)
	for index in 3:
		var angle := index * TAU / 3.0
		k.box(root, manway + Vector3(cos(angle) * 0.27, 0.06, sin(angle) * 0.27), Vector3(0.05, 0.06, 0.05), k.polished)
	k.cylinder(root, tank + Vector3(0.45, 2.66, 0.35), 0.07, 0.14, k.lens, Y, 14)
	k.pipe(root, tank + Vector3(0.45, 2.6, -0.4), tank + Vector3(0.45, 3.0, -0.4), 0.03, k.polished)
	k.cylinder(root, tank + Vector3(-0.5, 2.75, -0.35), 0.08, 0.28, k.gauge, Y, 14)
	# Agitator drive on a bridge: gear motor, gearbox and the turning coupling.
	k.box(root, tank + Vector3(0, 2.66, 0), Vector3(1.2, 0.08, 0.3), k.stainless_dark)
	k.box(root, tank + Vector3(0, 2.94, 0), Vector3(0.44, 0.34, 0.44), k.paint(accent))
	k.drive_motor(root, tank + Vector3(0, 3.32, 0), 0.15, 0.42, Y)
	var coupling := k.pivot(root, tank + Vector3(0, 2.72, 0), "AgitatorCoupling")
	k.cylinder(coupling, Vector3.ZERO, 0.1, 0.08, k.polished, Y, 16)
	for index in 3:
		var arm := k.box(coupling, Vector3(0.0, 0.0, 0.0), Vector3(0.42, 0.03, 0.05), k.safety)
		arm.rotation.y = index * TAU / 3.0
	# Jacket water connections, thermometer and a sight glass.
	k.pipe(root, tank + Vector3(radius, 1.2, 0), tank + Vector3(radius + 0.25, 1.2, 0), 0.03, k.signal_red)
	k.pipe(root, tank + Vector3(radius, 2.1, 0), tank + Vector3(radius + 0.25, 2.1, 0), 0.03, k.motor)
	k.dial(root, tank + Vector3(0, 1.5, radius), Z)
	k.box(root, tank + Vector3(-0.45, 1.68, radius - 0.02), Vector3(0.1, 0.9, 0.06), k.stainless_dark)
	k.box(root, tank + Vector3(-0.45, 1.68, radius + 0.012), Vector3(0.05, 0.8, 0.01), k.glass)
	# Outlet valve, transfer pump and the filling nozzle over the output tray.
	var outlet := tank + Vector3(0, 0.62, 0)
	k.pipe(root, outlet, outlet - Vector3(0, 0.22, 0), 0.05, k.polished)
	k.box(root, outlet - Vector3(0, 0.26, 0), Vector3(0.14, 0.12, 0.14), k.polished)
	k.box(root, outlet - Vector3(0, 0.22, -0.12), Vector3(0.04, 0.04, 0.22), k.signal_red)
	var pump := Vector3(1.25, 0.3, 0.9)
	k.box(root, pump - Vector3(0, 0.2, 0), Vector3(0.8, 0.06, 0.36), k.frame_dark)
	k.cylinder(root, pump - Vector3(0.2, 0, 0), 0.12, 0.2, k.stainless, X, 16)
	k.drive_motor(root, pump + Vector3(0.16, 0, 0), 0.1, 0.32, X)
	k.joint(root, Vector3(outlet.x, 0.3, outlet.z), 0.05, k.polished)
	k.pipe(root, Vector3(outlet.x, 0.3, outlet.z), pump - Vector3(0.3, 0, 0), 0.04, k.polished)
	k.pipe(root, pump - Vector3(0.2, -0.12, 0), pump + Vector3(-0.2, 1.1, 0), 0.035, k.polished)
	k.joint(root, pump + Vector3(-0.2, 1.1, 0), 0.045, k.polished)
	k.pipe(root, pump + Vector3(-0.2, 1.1, 0), Vector3(0.0, 1.4, 1.6), 0.035, k.polished)
	k.joint(root, Vector3(0.0, 1.4, 1.6), 0.045, k.polished)
	k.cylinder(root, Vector3(0.0, 1.22, 1.6), 0.05, 0.32, k.stainless_dark, Y, 14, 0.025)
	k.box(root, Vector3(0.0, 1.4, 1.2), Vector3(0.06, 0.06, 0.8), k.stainless)
	k.leg(root, Vector3(0.0, 0, 1.15), 1.4)
	# Bench for the cream ingredient sacks staged at the mixer.
	k.box(root, Vector3(-2.0, 0.46, -0.36), Vector3(0.9, 0.04, 3.4), k.stainless)
	for z: float in [-1.95, -0.36, 1.23]:
		for x: float in [-2.38, -1.62]:
			k.leg(root, Vector3(x, 0, z), 0.44)
	# Ladder up the back for lid access.
	for x: float in [-0.2, 0.2]:
		k.box(root, tank + Vector3(x, 1.4, -radius - 0.25), Vector3(0.04, 2.8, 0.04), k.safety)
	for index in 8:
		k.cylinder(root, tank + Vector3(0, 0.3 + index * 0.32, -radius - 0.25), 0.015, 0.4, k.safety, X, 8)
	# Control cabinet and operator panel.
	k.box(root, Vector3(1.8, 0.06, -1.9), Vector3(0.94, 0.12, 0.5), k.frame_dark)
	k.box(root, Vector3(1.8, 0.92, -1.9), Vector3(0.9, 1.6, 0.46), k.paint(accent))
	k.box(root, Vector3(1.8, 0.92, -1.664), Vector3(0.01, 1.48, 0.01), k.seam)
	k.control_face(root, Vector3(1.6, 1.32, -1.66), Vector3(2.02, 1.32, -1.664))
	k.box(root, Vector3(1.8, 0.4, -1.664), Vector3(0.5, 0.2, 0.008), k.vent)
	k.cylinder(root, Vector3(1.95, 0.015, 1.25), 0.16, 0.03, k.frame_dark, Y, 16)
	k.cylinder(root, Vector3(1.95, 0.6, 1.25), 0.04, 1.2, k.polished, Y, 12)
	k.pendant(root, Vector3(1.95, 1.3, 1.25))
	k.stack_light(station, root, Vector3(1.55, 1.72, -1.9))
	var dynamic: Array[MeshInstance3D] = [station.beacon]
	k.finish(root, dynamic)
	k.finish(coupling)
	return coupling


# --- Conveyors ---------------------------------------------------------------------

## Powered roller conveyor between two points at belt height, in `parent` space.
func roller_conveyor(parent: Node3D, start: Vector3, end: Vector3, accent: Color, width: float = 1.0) -> Node3D:
	var k := _kit
	var span := end - start
	span.y = 0.0
	var length := span.length()
	var line := k.pivot(parent, start, "RollerConveyor")
	line.rotation.y = -atan2(span.z, span.x)
	var top := start.y
	var frame := k.paint(accent)
	for index in floori((length - 0.08) / 0.12):
		k.cylinder(line, Vector3(0.08 + index * 0.12, -0.04, 0), 0.04, width - 0.06, k.polished, Z, 12)
	for side: float in [-1.0, 1.0]:
		k.box(line, Vector3(length * 0.5, -0.05, side * width * 0.5), Vector3(length, 0.14, 0.04), frame)
		k.box(line, Vector3(length * 0.5, 0.07, side * (width * 0.5 - 0.02)), Vector3(length, 0.03, 0.012), k.polished)
		for index in maxi(1, floori(length / 0.9)):
			k.box(line, Vector3(0.45 + index * 0.9, 0.03, side * (width * 0.5 - 0.01)), Vector3(0.025, 0.08, 0.03), k.polished)
	var bays := maxi(1, ceili((length - 0.3) / 1.8))
	for index in bays + 1:
		var x := lerpf(0.2, length - 0.2, float(index) / bays)
		for z: float in [-width * 0.5 + 0.04, width * 0.5 - 0.04]:
			k.box(line, Vector3(x, -top * 0.5, z), Vector3(0.05, top - 0.24, 0.05), k.stainless)
			k.foot(line, Vector3(x, -top, z))
		k.box(line, Vector3(x, -top + 0.3, 0), Vector3(0.04, 0.04, width - 0.08), k.stainless)
	k.box(line, Vector3(length * 0.5, -0.16, -width * 0.5 - 0.05), Vector3(minf(1.2, length * 0.5), 0.1, 0.06), k.motor)
	k.finish(line)
	return line


## Accumulation table, label applicator and bay stops for the palletizing area.
func build_palletizing(station: Equipment, accent: Color, bays: Array[Vector3]) -> void:
	var k := _kit
	var root := k.model_root(station, "PalletizingModel")
	var table_y := 0.92
	roller_conveyor(root, Vector3(-3.98, table_y, -2.0), Vector3(2.68, table_y, -2.0), accent, 1.45)
	k.box(root, Vector3(2.72, table_y + 0.12, -2.0), Vector3(0.06, 0.3, 1.45), k.safety)
	# Photo-eye posts along the table.
	for x: float in [-1.5, 1.1]:
		k.box(root, Vector3(x, table_y + 0.18, -1.24), Vector3(0.04, 0.36, 0.04), k.stainless)
		k.box(root, Vector3(x, table_y + 0.3, -1.27), Vector3(0.06, 0.06, 0.04), k.seam)
		k.box(root, Vector3(x, table_y + 0.3, -1.29), Vector3(0.02, 0.02, 0.004), k.signal_red)
	# Print-and-apply labeller over the table.
	var labeller := Vector3(0.2, 0, -3.05)
	k.box(root, labeller + Vector3(0, 0.03, 0), Vector3(0.5, 0.06, 0.5), k.frame_dark)
	k.box(root, labeller + Vector3(0, 0.8, 0), Vector3(0.08, 1.6, 0.08), k.stainless)
	k.box(root, labeller + Vector3(0, 1.55, 0.35), Vector3(0.45, 0.4, 0.5), k.paint(Color("#d9dde0")))
	k.box(root, labeller + Vector3(0, 1.6, 0.605), Vector3(0.2, 0.1, 0.008), k.screen)
	k.cylinder(root, labeller + Vector3(-0.12, 1.55, 0.62), 0.12, 0.06, k.gauge, Z, 18)
	k.box(root, labeller + Vector3(0, 1.28, 0.75), Vector3(0.14, 0.2, 0.14), k.polished)
	# Wheel stops behind each pallet bay so pallets sit square.
	for at: Vector3 in bays:
		k.box(root, at + Vector3(0, 0.05, -1.08), Vector3(1.6, 0.1, 0.12), k.hazard)
	k.finish(root)


# --- Shelving ----------------------------------------------------------------------

## Chrome wire shelving with corner posts. `shelves` are deck heights.
func wire_shelving(parent: Node3D, center: Vector3, size: Vector3, shelves: Array, posts_x: Array) -> void:
	var k := _kit
	var root := k.pivot(parent, center, "WireShelving")
	for x: float in posts_x:
		for z: float in [-size.z * 0.5, size.z * 0.5]:
			k.cylinder(root, Vector3(x, size.y * 0.5, z), 0.016, size.y, k.chrome, Y, 10)
			k.cylinder(root, Vector3(x, 0.015, z), 0.03, 0.03, k.rubber, Y, 10)
	for y: float in shelves:
		k.box(root, Vector3(0, y, 0), Vector3(size.x, 0.012, size.z), k.grating)
		for z: float in [-size.z * 0.5, size.z * 0.5]:
			k.cylinder(root, Vector3(0, y + 0.01, z), 0.008, size.x, k.chrome, X, 8)
			k.cylinder(root, Vector3(0, y - 0.03, z), 0.006, size.x, k.chrome, X, 8)
		for x: float in [-size.x * 0.5, size.x * 0.5]:
			k.cylinder(root, Vector3(x, y + 0.01, 0), 0.008, size.z, k.chrome, Z, 8)
	k.finish(root)


## Long-span shelving: painted uprights, orange step beams and mesh decks.
func longspan_shelving(parent: Node3D, center: Vector3, size: Vector3, levels: Array, posts_x: Array) -> void:
	var k := _kit
	var root := k.pivot(parent, center, "LongspanShelving")
	var upright := k.paint(Color("#2f5d8a"))
	var beam := k.paint(Color("#e2752c"))
	for x: float in posts_x:
		for z: float in [-size.z * 0.5, size.z * 0.5]:
			k.box(root, Vector3(x, size.y * 0.5, z), Vector3(0.07, size.y, 0.05), upright)
			k.box(root, Vector3(x, 0.006, z), Vector3(0.14, 0.012, 0.12), k.frame_dark)
		var rises := floori(size.y / 0.55)
		for index in rises:
			var brace := k.box(root, Vector3(x, 0.3 + index * 0.55, 0), Vector3(0.02, 0.02, sqrt(size.z * size.z + 0.3)), upright)
			brace.rotation.x = atan2(0.55, size.z) * (1.0 if index % 2 == 0 else -1.0)
	for y: float in levels:
		for z: float in [-size.z * 0.5, size.z * 0.5]:
			k.box(root, Vector3(0, y - 0.04, z), Vector3(size.x, 0.09, 0.045), beam)
		k.box(root, Vector3(0, y + 0.006, 0), Vector3(size.x, 0.012, size.z - 0.04), k.grating)
	k.finish(root)
