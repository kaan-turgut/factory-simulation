extends RefCounted
## Chewing gum equipment that is not conveyor based: the Z-blade gum mixer and the
## rotating coating pans. Built with the shared industrial kit; visual only.

const Industrial = preload("res://world/industrial_models.gd")
const Equipment = preload("res://world/equipment_view.gd")

const X := Industrial.X
const Y := Industrial.Y
const Z := Industrial.Z


## Moving parts of the Z-blade mixer. Blades turn only while a batch is mixing.
class MixerModel:
	var blades: Array[Node3D] = []
	var mass: MeshInstance3D
	var colour: StandardMaterial3D

	func animate(mixing: bool, delta: float) -> void:
		mass.visible = mixing
		if not mixing:
			return
		# Sigma blades run at different speeds so the mass is folded, not just stirred.
		blades[0].rotate_object_local(Vector3.RIGHT, delta * 2.2)
		blades[1].rotate_object_local(Vector3.RIGHT, -delta * 3.3)

	func tint(color: Color) -> void:
		if colour.albedo_color != color:
			colour.albedo_color = color


## Moving parts of one coating pan. The drum turns while a batch is coating and the
## charge inside takes the shell colour of the order.
class PanModel:
	var drum: Node3D
	var charge: Node3D
	var colour: StandardMaterial3D

	func animate(coating: bool, delta: float) -> void:
		charge.visible = coating
		if coating:
			drum.rotate_object_local(Vector3.UP, delta * 2.6)

	func tint(color: Color) -> void:
		if colour.albedo_color != color:
			colour.albedo_color = color


var _kit: Industrial


func _init(kit: Industrial) -> void:
	_kit = kit


# --- Z-blade gum mixer -------------------------------------------------------------

func build_mixer(station: Equipment, accent: Color) -> MixerModel:
	var k := _kit
	var model := MixerModel.new()
	var root := k.model_root(station, "GumMixerModel")
	var frame := k.paint(accent)
	var trough := Vector3(0.0, 1.25, -0.35)
	k.box(root, Vector3(0, 0.025, 0), Vector3(4.86, 0.05, 4.86), k.pad)
	k.box(root, Vector3(0, 0.052, 1.9), Vector3(3.6, 0.004, 0.09), k.hazard)
	# Heavy base and two pedestals carrying the trough trunnions and the tilt drive.
	k.box(root, Vector3(0, 0.15, trough.z), Vector3(3.4, 0.2, 1.7), k.frame_dark)
	for side: float in [-1.0, 1.0]:
		k.box(root, Vector3(side * 1.45, 0.82, trough.z), Vector3(0.5, 1.15, 1.4), frame)
		k.box(root, Vector3(side * 1.45, 1.42, trough.z), Vector3(0.56, 0.08, 1.46), k.frame_dark)
		k.cylinder(root, Vector3(side * 1.2, trough.y, trough.z), 0.2, 0.12, k.polished, X, 20)
		for z: float in [-0.45, 0.45]:
			k.cylinder(root, Vector3(side * 1.45, trough.y, trough.z + z), 0.09, 0.6, k.stainless_dark, X, 16)
	# Jacketed double trough: two half cylinders under a flat rim, water jacket connections.
	for z: float in [-0.3, 0.3]:
		k.cylinder(root, trough + Vector3(0, -0.05, z), 0.36, 1.9, k.stainless, X, 26)
	k.box(root, trough + Vector3(0, 0.22, 0), Vector3(1.96, 0.36, 1.32), k.stainless)
	k.box(root, trough + Vector3(0, 0.41, 0), Vector3(2.0, 0.04, 1.38), k.stainless_dark)
	k.box(root, trough + Vector3(0, 0.432, 0), Vector3(1.86, 0.008, 1.22), k.seam)
	for x: float in [-0.6, 0.0, 0.6]:
		k.cylinder(root, trough + Vector3(x, -0.4, 0), 0.03, 0.2, k.signal_red, Y, 10)
	# Mass and blades, seen through the open lid.
	model.colour = k.make_surface(Color("#e7e2d2"), 0.6, 0.0)
	model.mass = k.box(root, trough + Vector3(0, 0.3, 0), Vector3(1.8, 0.1, 1.16), model.colour)
	model.mass.scale = Vector3(1, 1, 1)
	for z: float in [-0.3, 0.3]:
		var blade := k.pivot(root, trough + Vector3(0, 0.05, z), "SigmaBlade")
		k.cylinder(blade, Vector3.ZERO, 0.06, 1.94, k.polished, X, 14)
		for index in 3:
			var arm := k.box(blade, Vector3(-0.6 + index * 0.6, 0.14, 0), Vector3(0.5, 0.06, 0.08), k.chrome)
			arm.rotation.z = 0.5 if index % 2 == 0 else -0.5
			arm.rotation.x = index * TAU / 3
		model.blades.append(blade)
	# Hinged lid opened back, with a sight glass and vent stub.
	var lid := k.pivot(root, trough + Vector3(0, 0.45, -0.69), "MixerLid")
	lid.rotation.x = -1.15
	k.box(lid, Vector3(0, 0.03, 0.69), Vector3(2.0, 0.06, 1.38), k.stainless)
	k.cylinder(lid, Vector3(0.5, 0.08, 0.69), 0.12, 0.04, k.glass, Y, 18)
	k.cylinder(lid, Vector3(-0.5, 0.14, 0.69), 0.07, 0.16, k.stainless_dark, Y, 14)
	k.box(lid, Vector3(0, 0.08, 1.33), Vector3(0.5, 0.05, 0.05), k.polished)
	# Main drive: motor and gearbox on the right pedestal; tilt cylinder on the left.
	k.box(root, Vector3(1.95, 1.0, trough.z), Vector3(0.5, 0.7, 0.8), frame)
	k.drive_motor(root, Vector3(2.0, 1.55, trough.z), 0.2, 0.55, Y)
	k.box(root, Vector3(1.75, 1.25, trough.z + 0.3), Vector3(0.12, 0.3, 0.2), k.safety)
	var tilt := k.pipe(root, Vector3(-1.85, 0.25, trough.z + 0.4), Vector3(-1.75, 1.15, trough.z - 0.2), 0.07, k.stainless_dark)
	tilt.name = "TiltCylinder"
	k.pipe(root, Vector3(-1.75, 1.15, trough.z - 0.2), Vector3(-1.7, 1.45, trough.z - 0.4), 0.035, k.chrome)
	# Discharge apron and a mass tub on a trolley in front.
	var apron := k.box(root, trough + Vector3(0, 0.25, 0.95), Vector3(1.6, 0.03, 0.5), k.stainless)
	apron.rotation.x = 0.5
	var tub := Vector3(0.0, 0.0, 1.35)
	k.box(root, tub + Vector3(0, 0.34, 0), Vector3(1.1, 0.5, 0.7), k.stainless)
	k.box(root, tub + Vector3(0, 0.6, 0), Vector3(1.14, 0.03, 0.74), k.polished)
	for x: float in [-0.45, 0.45]:
		for z: float in [-0.26, 0.26]:
			k.caster(root, tub + Vector3(x, 0.06, z), 0.06)
	# Control cabinet with operator panel, and a guard rail along the open side.
	k.box(root, Vector3(-1.9, 0.06, -1.85), Vector3(0.9, 0.12, 0.5), k.frame_dark)
	k.box(root, Vector3(-1.9, 0.92, -1.85), Vector3(0.86, 1.6, 0.46), frame)
	k.box(root, Vector3(-1.9, 0.92, -1.614), Vector3(0.01, 1.48, 0.01), k.seam)
	k.control_face(root, Vector3(-2.1, 1.32, -1.61), Vector3(-1.7, 1.32, -1.614))
	k.box(root, Vector3(-1.9, 0.4, -1.614), Vector3(0.5, 0.2, 0.008), k.vent)
	k.cylinder(root, Vector3(1.95, 0.015, 1.3), 0.16, 0.03, k.frame_dark, Y, 16)
	k.cylinder(root, Vector3(1.95, 0.6, 1.3), 0.04, 1.2, k.polished, Y, 12)
	k.pendant(root, Vector3(1.95, 1.3, 1.3))
	k.handrail(root, Vector3(-1.25, 0, -1.4), Vector3(1.25, 0, -1.4))
	k.stack_light(station, root, Vector3(-1.65, 1.72, -1.85))
	var dynamic: Array[MeshInstance3D] = [station.beacon, model.mass]
	k.finish(root, dynamic)
	k.finish(lid)
	for blade in model.blades:
		k.finish(blade)
	return model


# --- Rotating coating pan ----------------------------------------------------------

func build_pan(station: Equipment, accent: Color, title: String) -> PanModel:
	var k := _kit
	var model := PanModel.new()
	var root := k.model_root(station, "CoatingPanModel")
	var cabinet := k.stainless_dark
	k.box(root, Vector3(0, 0.025, 0), Vector3(3.86, 0.05, 3.86), k.pad)
	k.box(root, Vector3(0, 0.052, 1.88), Vector3(2.6, 0.004, 0.09), k.hazard)
	# Base cabinet on levelling feet: a lower box and a sloped upper housing for the drive.
	var base := Vector3(0, 0, -0.35)
	for x: float in [-0.72, 0.72]:
		for z: float in [-0.72, 0.72]:
			k.foot(root, base + Vector3(x, 0, z))
	k.box(root, base + Vector3(0, 0.66, 0), Vector3(1.6, 1.08, 1.6), cabinet)
	var shoulder := k.box(root, base + Vector3(0, 1.32, -0.12), Vector3(1.6, 0.5, 1.2), cabinet)
	shoulder.rotation.x = -0.35
	for x: float in [-0.805, 0.805]:
		k.box(root, base + Vector3(x, 0.66, 0), Vector3(0.008, 0.9, 1.4), k.seam)
	k.box(root, base + Vector3(0, 0.12, 0.805), Vector3(1.5, 0.008, 0.008), k.seam)
	# Front control panel: lamp, temperature display, selectors, main switch and socket.
	var panel := base + Vector3(0.48, 0, 0.805)
	k.box(root, panel + Vector3(0, 0.75, 0), Vector3(0.36, 0.95, 0.012), k.stainless)
	k.cylinder(root, panel + Vector3(0, 1.1, 0.012), 0.035, 0.03, k.signal_red, Z, 14)
	k.box(root, panel + Vector3(0, 0.96, 0.01), Vector3(0.16, 0.08, 0.008), k.screen)
	for x: float in [-0.07, 0.07]:
		k.cylinder(root, panel + Vector3(x, 0.84, 0.014), 0.025, 0.03, k.polished, Z, 12)
	k.box(root, panel + Vector3(0, 0.68, 0.01), Vector3(0.14, 0.14, 0.01), k.safety)
	k.cylinder(root, panel + Vector3(0, 0.68, 0.025), 0.045, 0.03, k.signal_red, Z, 14)
	k.cylinder(root, panel + Vector3(0, 0.5, 0.016), 0.05, 0.03, k.motor, Z, 14)
	k.box(root, base + Vector3(-0.3, 0.72, 0.812), Vector3(0.82, 0.2, 0.006), k.gauge)
	k.plate(root, base + Vector3(-0.3, 0.72, 0.817), title.to_upper(), Color("#1f4f8f"), 0.0026)
	# Tilted pan on its drive: the drum turns about its own axis.
	var tilt := k.pivot(root, base + Vector3(0, 1.62, 0.18), "PanTilt")
	tilt.rotation.x = 0.62
	k.cylinder(tilt, Vector3(0, -0.15, 0), 0.24, 0.3, cabinet, Y, 22)
	k.cylinder(tilt, Vector3(0, 0.02, 0), 0.3, 0.06, k.polished, Y, 24)
	var drum := k.pivot(tilt, Vector3(0, 0.95, 0), "CoatingDrum")
	model.drum = drum
	# Open "onion" shell: polished outside, visible inside through the mouth.
	var steel := k.polished.duplicate() as StandardMaterial3D
	steel.cull_mode = BaseMaterial3D.CULL_DISABLED
	k.add_mesh(drum, Vector3.ZERO, _open_shell(0.95, 0.72), steel)
	var rim := TorusMesh.new()
	rim.inner_radius = 0.6
	rim.outer_radius = 0.72
	rim.rings = 36
	rim.ring_segments = 12
	k.add_mesh(drum, Vector3(0, 0.66, 0), rim, k.polished)
	k.cylinder(drum, Vector3(0, -0.92, 0), 0.32, 0.08, k.polished, Y, 24)
	for index in 6:
		var angle := index * TAU / 6
		k.cylinder(drum, Vector3(cos(angle) * 0.24, -0.97, sin(angle) * 0.24), 0.025, 0.04, k.stainless_dark, Y, 8)
	var boss := k.cylinder(drum, Vector3(0.0, 0.1, 0.95), 0.07, 0.06, k.polished, Z, 14)
	boss.name = "InspectionBoss"
	# Charge: coated gum tumbling in the lower lip of the drum, tinted to the shell colour.
	model.colour = k.make_surface(Color("#f4f6f8"), 0.25, 0.0)
	# The charge rests in the low side of the turning drum, level with the floor.
	model.charge = k.pivot(tilt, Vector3(0, 0.95, 0) + Vector3(0, -0.81, 0.58) * 0.08, "Charge")
	model.charge.rotation.x = -0.62
	var heap := SphereMesh.new()
	heap.radius = 0.58
	heap.height = 0.4
	heap.radial_segments = 20
	heap.rings = 8
	k.add_mesh(model.charge, Vector3.ZERO, heap, model.colour)
	for index in 9:
		var angle := index * TAU / 9
		var piece := SphereMesh.new()
		piece.radius = 0.06
		piece.height = 0.1
		piece.radial_segments = 8
		piece.rings = 4
		k.add_mesh(model.charge, Vector3(cos(angle) * 0.32, 0.1, sin(angle) * 0.24), piece, model.colour)
	# Control arm from the photo: a vertical post bent forward to a hanging push-button box.
	var post := base + Vector3(0.7, 0, -0.75)
	k.pipe(root, post + Vector3(0, 1.1, 0), post + Vector3(0, 2.85, 0), 0.035, k.polished)
	k.joint(root, post + Vector3(0, 2.85, 0), 0.045, k.polished)
	k.pipe(root, post + Vector3(0, 2.85, 0), post + Vector3(-0.55, 2.85, 0.0), 0.035, k.polished)
	k.box(root, post + Vector3(-0.7, 2.82, 0.0), Vector3(0.24, 0.3, 0.22), k.frame_dark)
	k.cylinder(root, post + Vector3(-0.7, 2.9, 0.112), 0.04, 0.03, k.signal_red, Z, 14)
	k.box(root, post + Vector3(-0.7, 2.78, 0.112), Vector3(0.14, 0.06, 0.006), k.screen)
	# Hot-air blower and duct blowing into the mouth, plus a syrup dosing tank and spray bar.
	var blower := Vector3(-1.35, 0, -1.05)
	k.box(root, blower + Vector3(0, 0.06, 0), Vector3(0.7, 0.12, 0.7), k.frame_dark)
	k.box(root, blower + Vector3(0, 0.5, 0), Vector3(0.6, 0.7, 0.6), k.paint(accent))
	k.box(root, blower + Vector3(0, 0.5, 0.302), Vector3(0.4, 0.4, 0.006), k.vent)
	k.drive_motor(root, blower + Vector3(0, 1.0, 0), 0.12, 0.3, Y)
	var duct := [blower + Vector3(0.0, 0.85, 0.2), blower + Vector3(0.1, 2.1, 0.5), Vector3(-0.5, 2.55, 0.55), Vector3(-0.15, 2.3, 0.75)]
	for index in range(1, duct.size()):
		k.pipe(root, duct[index - 1], duct[index], 0.08, k.rubber)
		k.joint(root, duct[index], 0.085, k.rubber)
	var tank := Vector3(1.35, 0, -1.1)
	for index in 3:
		var angle := index * TAU / 3 + 0.3
		k.leg(root, tank + Vector3(cos(angle) * 0.2, 0, sin(angle) * 0.2), 0.7)
	k.cylinder(root, tank + Vector3(0, 0.75, 0), 0.06, 0.12, k.stainless, Y, 16, 0.26)
	k.cylinder(root, tank + Vector3(0, 1.1, 0), 0.27, 0.6, k.stainless, Y, 22)
	k.cylinder(root, tank + Vector3(0, 1.44, 0), 0.27, 0.08, k.stainless_dark, Y, 22, 0.12)
	k.dial(root, tank + Vector3(0, 1.15, 0.27), Z)
	k.pipe(root, tank + Vector3(0, 1.48, 0), tank + Vector3(0, 2.65, 0), 0.02, k.polished)
	k.pipe(root, tank + Vector3(0, 2.65, 0), Vector3(0.25, 2.65, 0.55), 0.02, k.polished)
	k.pipe(root, Vector3(0.25, 2.65, 0.55), Vector3(0.1, 2.3, 0.72), 0.02, k.polished)
	k.box(root, Vector3(0.1, 2.27, 0.74), Vector3(0.3, 0.03, 0.05), k.chrome)
	k.stack_light(station, root, base + Vector3(-0.62, 1.58, -0.6))
	var dynamic: Array[MeshInstance3D] = [station.beacon]
	k.finish(root, dynamic)
	k.finish(tilt)
	k.finish(drum)
	k.finish(model.charge)
	return model


## A sphere of `radius` cut open above `cut` along +Y (the pan mouth), as one mesh.
func _open_shell(radius: float, cut: float) -> ArrayMesh:
	const SEGMENTS := 36
	const RINGS := 16
	var top := acos(clampf(cut / radius, -1.0, 1.0))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var point := func(ring: int, segment: int) -> Vector3:
		var polar := lerpf(PI, top, float(ring) / RINGS)
		var around := TAU * segment / SEGMENTS
		return Vector3(sin(polar) * cos(around), cos(polar), sin(polar) * sin(around)) * radius
	for ring in RINGS:
		for segment in SEGMENTS:
			var a: Vector3 = point.call(ring, segment)
			var b: Vector3 = point.call(ring, segment + 1)
			var c: Vector3 = point.call(ring + 1, segment + 1)
			var d: Vector3 = point.call(ring + 1, segment)
			for vertex in [a, c, b, a, d, c]:
				tool.set_normal(vertex.normalized())
				tool.add_vertex(vertex)
	var mesh := tool.commit()
	mesh.set_meta("mergeable", true)
	return mesh


# --- Staged supplies ---------------------------------------------------------------

## Intermediate bulk container (IBC): a 1 m³ tote in a galvanised cage on a pallet.
func ibc(parent: Node3D, at: Vector3, liquid: Color) -> Node3D:
	var k := _kit
	var tote := k.pivot(parent, at, "IBCTote")
	k.box(tote, Vector3(0, 0.07, 0), Vector3(1.2, 0.14, 1.0), k.frame_dark)
	k.box(tote, Vector3(0, 0.62, 0), Vector3(1.12, 0.9, 0.94), k.film)
	for x: float in [-0.58, -0.29, 0.0, 0.29, 0.58]:
		for z: float in [-0.48, 0.48]:
			k.box(tote, Vector3(x, 0.62, z), Vector3(0.025, 0.96, 0.025), k.polished)
	for y: float in [0.3, 0.62, 0.95, 1.1]:
		for z: float in [-0.48, 0.48]:
			k.box(tote, Vector3(0, y, z), Vector3(1.18, 0.025, 0.025), k.polished)
	k.cylinder(tote, Vector3(0, 1.12, 0), 0.08, 0.06, k.make_surface(liquid, 0.4, 0.0), Y, 14)
	k.cylinder(tote, Vector3(0, 0.22, 0.5), 0.05, 0.1, k.motor, Z, 12)
	k.finish(tote)
	return tote
