extends RefCounted
## Renders authoritative mover positions. All model parts are reused across runs.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Operator = Line.Operator
const Primitives = preload("res://world/primitives.gd")
const Equipment = preload("res://world/equipment_view.gd")
const Stock = preload("res://world/stock_models.gd")
const Industrial = preload("res://world/industrial_models.gd")

const RUBBER := Color("#29373f")
const STEEL := Color("#667982")
const SILVER := Color("#a4b6b9")
const PALE := Color("#deeceb")
const TEAL := Color("#59a8a2")
const AMBER := Color("#e7a23e")
const JACK_ORANGE := Color("#eb9a2c")
## Workers are the CC0 Quaternius characters prepared in Blender (see CREDITS.md). The clips come
## with them: Idle, Walk, Carry, Carry_Idle, Cart_Push, PickUp_Table (and Interact, Push).
const WORKER_FILES: Array[String] = ["worker_male_dark", "worker_female_light", "worker_male_light", "worker_female_dark"]
## Ground speed of the walk clip at normal playback, in metres per second.
const WALK_REFERENCE := 1.22
const MIN_STRIDE_RATE := 0.6
const MAX_STRIDE_RATE := 2.2
## Centre of a carried sack in the worker's frame, and its size. The sack rides on the spine bone.
const CARRY_ANCHOR := Vector3(0, 1.27, 0.33)
const CARRIED_SACK_SCALE := 0.55
## The cart handle sits at the worker's own position, so the model steps back to hold it.
const CART_STAND_BACK := -0.33
const JACK_STAND_BACK := -0.61

class CrewModel:
	var view: Equipment
	var body: Node3D
	var player: AnimationPlayer
	var sack: Node3D
	var clip := &""
	var handler := false
	var settled := 0.0


var _draw: Primitives
var _stock: Stock
var _kit: Industrial
var _parent: Node3D
var views: Dictionary[StringName, Equipment] = {}
var _crew: Dictionary[StringName, CrewModel] = {}
var _worker_materials: Dictionary[String, StandardMaterial3D] = {}
var _worker_count := 0
var _cart_coating := {}
var _forklift: Equipment
var _forks: Node3D
var _mast: Node3D
var _load: Stock.PalletView
var _jack_forks: Node3D
var _jack_handle: Node3D
var _jack_load: Node3D
var _jack_ingredients: Node3D
var _jack_packaging: Node3D


func _init(parent: Node3D, draw: Primitives, stock: Stock, erp_enabled: bool, kit: Industrial) -> void:
	_parent = parent
	_draw = draw
	_stock = stock
	_kit = kit
	for index in 2:
		_build_worker(StringName("Platform%d" % (index + 1)), true)
	for index in Layout.MAX_CREW:
		_build_worker(StringName("Worker%d" % (index + 1)), false)
	if erp_enabled:
		_build_worker(Line.ERP.MATERIAL_HANDLER_ID, false, true)
		_build_pallet_jack(views[Line.ERP.MATERIAL_HANDLER_ID])
	for index in Layout.MAX_CARTS:
		_build_cart(StringName("Raw%d" % (index + 1)), true)
		_build_cart(StringName("Cooked%d" % (index + 1)), false)
		if erp_enabled:
			_build_cart(StringName("Coated%d" % (index + 1)), false, true)
	_build_forklift()


func select(id: StringName) -> void:
	for key in views:
		views[key].select(key == id)


func refresh(line: Line) -> void:
	for id in _crew:
		views[id].set_active(line.find_operator(id) != null)
		if not views[id].visible:
			_crew[id].player.active = false
	for id in views:
		if not (String(id).begins_with("Raw") or String(id).begins_with("Cooked") or String(id).begins_with("Coated")):
			continue
		var cart := line.find_cart(id)
		views[id].set_active(cart != null)
		if cart != null:
			views[id].fill_slots(cart.stock.occupancy())
			if line.erp == null:
				continue
			var material := cart.material
			if material.is_empty() and cart.coated and not cart.order_id.is_empty():
				material = line.erp.orders[cart.order_id].code
			if _cart_coating.get(id, "") == material:
				continue
			_cart_coating[id] = material
			var spec: Dictionary = line.erp.catalog.materials.get(material, {})
			var tint := _draw.material(Color(spec.get("coating_color", "#d8bd83")))
			for wafer in views[id].inventory_slots:
				(wafer.get_child(0) as MeshInstance3D).material_override = tint
	_load.refresh(line.lift_load)
	var fork_y := 0.07
	if line.lift_load != null:
		fork_y = 0.28
		if line.forklift.state == Operator.State.UNLOADING and line.warehouse_reserved_slot >= 0:
			# Raise to the rack level over the first part of the handling time, then drop the forks clear of the beam.
			var reach := line.layout.warehouse_height(line.warehouse_reserved_slot)
			var done := 1.0 - line.forklift.remaining / line.storage_handling_seconds(line.warehouse_reserved_slot)
			if reach > 0.0:
				fork_y = lerpf(0.28, 0.28 + reach, clampf(done / 0.6, 0.0, 1.0)) - 0.21 * clampf((done - 0.6) / 0.4, 0.0, 1.0)
			else:
				fork_y = lerpf(0.28, 0.07, done)
	_forks.position.y = fork_y
	_mast.position.y = maxf(0.0, fork_y - 0.28) * 0.5
	if _jack_load != null and line.erp != null:
		_refresh_jack_load(line.erp)


func _refresh_jack_load(book: Line.ERP) -> void:
	_jack_load.visible = int(book.shipment.get("phase", -1)) > 0
	if not _jack_load.visible:
		return
	var ingredients := false
	var packaging := false
	for code in book.shipment.items:
		if book.catalog.materials[code].type == "VERP":
			packaging = true
		else:
			ingredients = true
	_jack_ingredients.visible = ingredients
	_jack_packaging.visible = packaging
	_jack_ingredients.position.x = -0.21 if packaging else 0.0
	_jack_packaging.position.x = 0.21 if ingredients else 0.0


var freight_cage: Node3D


func animate(line: Line, delta: float) -> void:
	var alpha := line.interpolation()
	var t := line.elapsed_seconds() + alpha * Line.STEP_SECONDS
	var turn := 1.0 if line.elapsed_ticks == 0 else 1.0 - exp(-18.0 * delta) if line.playing else 0.0
	for operator in line.platform_crew:
		_pose_worker(operator, alpha, turn, delta, line)
	for operator in line.floor_crew:
		_pose_worker(operator, alpha, turn, delta, line)
	if _jack_load != null and line.erp != null:
		var handler := line.erp.material_handler
		_pose_worker(handler, alpha, 1.0 if delta == 0.0 else turn, delta, line)
		if freight_cage != null:
			_move_cage(handler, line.layout, alpha)
		var unloading := handler.state == Operator.State.UNLOADING
		var lift := clampf(handler.remaining, 0.0, 1.0) if unloading else 1.0
		_jack_forks.position.y = 0.065 * lift if _jack_load.visible else 0.0
		_jack_handle.rotation.x = -0.35 + sin(t * 8.0) * 0.16 if unloading else -0.35
	for cart in line.carts:
		var view := views[cart.id]
		view.position = cart.previous_position.lerp(cart.position, alpha)
		view.rotation.y = lerp_angle(view.rotation.y, cart.heading, turn)
	_forklift.position = line.forklift.previous_position.lerp(line.forklift.position, alpha)
	_forklift.rotation.y = lerp_angle(_forklift.rotation.y, line.forklift.heading, turn)


## The cage follows the handler while he stands in it; otherwise it waits where he left it.
func _move_cage(handler: Operator, layout: Line.Layout, alpha: float) -> void:
	var at := handler.previous_position.lerp(handler.position, alpha)
	var base := layout.freight_lift_base()
	var inside := absf(at.x - base.x) < 1.4 and absf(at.z - base.z) < 1.3
	var top := layout.freight_lift_top().y
	var level := at.y if inside else (top if at.y > top * 0.5 else 0.0)
	freight_cage.position.y = clampf(level, 0.0, top)


func _pose_worker(worker: Operator, alpha: float, turn: float, delta: float, line: Line) -> void:
	var model := _crew[worker.id]
	model.view.position = worker.previous_position.lerp(worker.position, alpha)
	model.view.rotation.y = lerp_angle(model.view.rotation.y, worker.heading, turn)
	var carrying := worker.cargo_kg > 0.0
	# Ground speed in metres per simulated second, from the last fixed step.
	var speed := worker.position.distance_to(worker.previous_position) / Line.STEP_SECONDS
	var moving := speed > 0.15
	var pushing := worker.state in [Operator.State.PUSHING, Operator.State.MOVING_PALLET_JACK]
	var handling := worker.state in [Operator.State.LOADING, Operator.State.UNLOADING]
	var clip := &"Idle"
	if pushing:
		clip = &"Cart_Push" if moving else &"Idle"
	elif handling:
		clip = &"Carry_Idle" if carrying else &"PickUp_Table"
	elif moving:
		clip = &"Carry" if carrying else &"Walk"
	elif carrying:
		clip = &"Carry_Idle"
	if clip != model.clip:
		model.clip = clip
		model.player.play(clip, 0.25)
	# Feet follow the real speed of the worker on screen, within sensible limits.
	var rate := 1.0
	if clip in [&"Walk", &"Carry", &"Cart_Push"]:
		rate = clampf(speed * float(line.multiplier) / WALK_REFERENCE, MIN_STRIDE_RATE, MAX_STRIDE_RATE)
	elif clip == &"PickUp_Table":
		rate = 0.7
	model.player.speed_scale = rate
	# A skeleton that is not moving costs nothing, so idle workers freeze once their pose has
	# blended in, and everyone stops while the simulation is paused.
	model.settled = model.settled + delta if clip == &"Idle" else 0.0
	model.player.active = line.playing and model.settled < 0.7
	var stand_back := JACK_STAND_BACK if model.handler else (CART_STAND_BACK if clip == &"Cart_Push" else 0.0)
	model.body.position.z = lerpf(model.body.position.z, stand_back, 1.0 - exp(-8.0 * delta)) if line.playing \
		else stand_back
	model.sack.visible = carrying


func _view(id: StringName, size: Vector3, tint: Color, offset: Vector3 = Vector3.ZERO) -> Equipment:
	var view := Equipment.new()
	_parent.add_child(view)
	view.configure(id, _draw, size, "", tint, false, offset)
	views[id] = view
	return view


func _build_worker(id: StringName, platform: bool, handler: bool = false) -> void:
	var model := CrewModel.new()
	var vest := Color("#809bdf") if platform else Color("#e2a050")
	var hat := Color("#b7dcf9") if platform else Color("#f7d468")
	if handler:
		vest = TEAL
		hat = PALE
	model.handler = handler
	model.view = _view(id, Vector3(1.24, 1.95, 2.70), hat, Vector3(0, 0, 0.13)) if handler \
		else _view(id, Vector3(0.92, 1.95, 0.85), hat)
	model.body = Node3D.new()
	model.body.position.z = JACK_STAND_BACK if handler else 0.0
	model.view.add_child(model.body)
	var scene: PackedScene = load("res://assets/characters/%s.glb" % WORKER_FILES[_worker_count % WORKER_FILES.size()])
	_worker_count += 1
	var rig := scene.instantiate() as Node3D
	model.body.add_child(rig)
	model.player = _find_node(rig, "AnimationPlayer") as AnimationPlayer
	model.player.get_animation(&"PickUp_Table").loop_mode = Animation.LOOP_LINEAR
	var skeleton := _find_node(rig, "Skeleton3D") as Skeleton3D
	for child in skeleton.get_children():
		if child is MeshInstance3D:
			_tint_worker(child, vest)
	# The carried sack rides on the spine, so it sways with the body.
	var attachment := BoneAttachment3D.new()
	attachment.bone_name = "spine_03"
	skeleton.add_child(attachment)
	var rest := skeleton.get_bone_global_rest(skeleton.find_bone("spine_03"))
	model.sack = _stock.sack(attachment, Vector3.ZERO)
	var placement := rest.affine_inverse() * Transform3D(Basis(), CARRY_ANCHOR)
	model.sack.transform = Transform3D(placement.basis * Basis.from_scale(Vector3.ONE * CARRIED_SACK_SCALE), placement.origin)
	model.sack.hide()
	model.player.play(&"Idle")
	model.clip = &"Idle"
	_crew[id] = model


## Gives the vest and cap their role colour without touching the shared model materials.
func _tint_worker(mesh_instance: MeshInstance3D, color: Color) -> void:
	for surface in mesh_instance.mesh.get_surface_count():
		var source := mesh_instance.mesh.surface_get_material(surface) as StandardMaterial3D
		if source == null or source.resource_name != "Tint":
			continue
		var key := color.to_html()
		if not _worker_materials.has(key):
			var copy := source.duplicate() as StandardMaterial3D
			copy.albedo_color = color
			_worker_materials[key] = copy
		mesh_instance.set_surface_override_material(surface, _worker_materials[key])


func _find_node(node: Node, type: String) -> Node:
	if node.is_class(type):
		return node
	for child in node.get_children():
		var found := _find_node(child, type)
		if found != null:
			return found
	return null


func _build_pallet_jack(parent: Equipment) -> void:
	var jack := _pivot(parent, Vector3.ZERO)
	jack.name = "ManualPalletJack"
	for x: float in [-0.18, 0.18]:
		_wheel(jack, Vector3(x, 0.12, 0.12), 0.12, 0.105)
	_draw.box(jack, Vector3(0, 0.18, 0.14), Vector3(0.44, 0.19, 0.32), STEEL)
	_draw.cylinder(jack, Vector3(0, 0.32, 0.21), 0.13, 0.27, SILVER)
	_draw.cylinder(jack, Vector3(0, 0.49, 0.21), 0.073, 0.14, STEEL)
	_jack_forks = _pivot(jack, Vector3.ZERO)
	_draw.box(_jack_forks, Vector3(0, 0.18, 0.38), Vector3(0.74, 0.22, 0.22), JACK_ORANGE)
	for x: float in [-0.27, 0.27]:
		_draw.box(_jack_forks, Vector3(x, 0.115, 0.91), Vector3(0.19, 0.094, 1.12), JACK_ORANGE)
		_draw.cylinder(_jack_forks, Vector3(x, 0.115, 1.46), 0.095, 0.094, JACK_ORANGE)
		for z: float in [1.24, 1.38]:
			_wheel(jack, Vector3(x, 0.061, z), 0.061, 0.091)
	_jack_handle = _pivot(jack, Vector3(0, 0.21, 0.03))
	_draw.cylinder(_jack_handle, Vector3(0, 0.45, 0), 0.038, 0.90, RUBBER)
	for x: float in [-0.16, 0.16]:
		_draw.box(_jack_handle, Vector3(x, 0.98, 0), Vector3(0.059, 0.24, 0.064), RUBBER)
	for y: float in [0.87, 1.08]:
		_draw.box(_jack_handle, Vector3(0, y, 0), Vector3(0.37, 0.065, 0.069), RUBBER)
	_jack_load = _pivot(_jack_forks, Vector3(0, 0.17, 0.94))
	for x: float in [-0.49, 0, 0.49]:
		_draw.box(_jack_load, Vector3(x, 0.04, 0), Vector3(0.13, 0.08, 1.01), Stock.WOOD.darkened(0.20))
	for z: float in [-0.42, -0.21, 0, 0.21, 0.42]:
		_draw.box(_jack_load, Vector3(0, 0.11, z), Vector3(1.11, 0.065, 0.17), Stock.WOOD)
	_jack_ingredients = _pivot(_jack_load, Vector3.ZERO)
	for y: float in [0.25, 0.43, 0.61]:
		var sack := _stock.sack(_jack_ingredients, Vector3(0, y, 0), 0.78)
		sack.rotation.y = PI * 0.5 if y == 0.43 else 0.0
	_jack_packaging = _pivot(_jack_load, Vector3.ZERO)
	_stock.carton(_jack_packaging, Vector3(0, 0.32, 0), Vector3(0.59, 0.34, 0.70))
	_stock.carton(_jack_packaging, Vector3(0.02, 0.58, -0.03), Vector3(0.51, 0.18, 0.62))
	_draw.batch_static(_jack_load)
	_draw.batch_static(_jack_handle)
	_draw.batch_static(_jack_forks)
	_draw.batch_static(jack)
	_jack_load.hide()


func _build_cart(id: StringName, raw: bool, coated: bool = false) -> void:
	var tint := Color("#b88bc7") if coated else (TEAL if raw else AMBER)
	var view := _view(id, Layout.CART_BODY, tint, Layout.CART_OFFSET)
	var tray := _pivot(view, Vector3(0, 0, 0.67))
	var k := _kit
	var band := k.paint(tint)
	# Stainless rack trolley on swivel casters with a rear push handle.
	for x: float in [-0.44, 0.44]:
		for z: float in [-0.5, 0.5]:
			k.caster(tray, Vector3(x, 0.075, z), 0.075, z > 0.0)
			k.cylinder(tray, Vector3(x * 1.12, 0.84, z * 1.14), 0.02, 1.28, k.polished, Industrial.Y, 10)
			k.cylinder(tray, Vector3(x * 1.12, 0.2, z * 1.14), 0.045, 0.06, k.rubber, Industrial.Y, 12)
	for z: float in [-0.57, 0.57]:
		k.box(tray, Vector3(0, 0.2, z), Vector3(1.0, 0.04, 0.03), k.stainless)
	for x: float in [-0.49, 0.49]:
		k.box(tray, Vector3(x, 0.2, 0), Vector3(0.03, 0.04, 1.14), k.stainless)
	for y: float in [0.41, 0.90, 1.39]:
		k.box(tray, Vector3(0, y, 0), Vector3(0.98, 0.026, 1.14), k.stainless)
		for z: float in [-0.57, 0.57]:
			k.box(tray, Vector3(0, y + 0.02, z), Vector3(0.98, 0.04, 0.012), k.polished)
		k.box(tray, Vector3(0, y - 0.03, -0.575), Vector3(0.6, 0.05, 0.008), band)
		for x: float in [-0.236, 0.236]:
			var color := Stock.CHOCOLATE if coated else (Stock.RAW if raw else Stock.COOKED)
			var wafers := _stock.wafer(tray, Vector3(x, y + 0.013, 0), color, Vector3(0.42, 0.22, 1.02))
			view.inventory_slots.append(wafers)
	for x: float in [-0.4, 0.4]:
		k.pipe(tray, Vector3(x, 1.05, -0.57), Vector3(x, 1.05, -0.7), 0.016, k.polished)
	k.cylinder(tray, Vector3(0, 1.05, -0.7), 0.018, 0.82, k.polished, Industrial.X, 10)
	k.cylinder(tray, Vector3(0, 1.05, -0.7), 0.024, 0.5, band, Industrial.X, 10)
	_draw.batch_static(tray)


func _build_forklift() -> void:
	_forklift = _view(&"Forklift", Vector3(2.23, 2.98, 3.4), AMBER)
	var k := _kit
	var body := k.paint(Color("#e6a72e"))
	var dark := k.paint(Color("#2b3135"))
	# Drive wheels at the front, steer wheels under the counterweight.
	for x: float in [-0.66, 0.66]:
		_tyre(_forklift, Vector3(x, 0.33, 0.54), 0.33, 0.28)
		_tyre(_forklift, Vector3(x * 0.88, 0.25, -0.95), 0.25, 0.2)
	# Chassis, fenders, counterweight and engine hood.
	k.box(_forklift, Vector3(0, 0.42, -0.25), Vector3(1.2, 0.46, 1.95), body)
	for x: float in [-0.66, 0.66]:
		k.box(_forklift, Vector3(x, 0.72, 0.54), Vector3(0.32, 0.05, 0.78), dark)
		k.box(_forklift, Vector3(x * 1.02, 0.38, 0.12), Vector3(0.28, 0.08, 0.3), k.grating)
	k.box(_forklift, Vector3(0, 0.75, -1.05), Vector3(1.42, 0.86, 0.48), dark)
	k.cylinder(_forklift, Vector3(0, 0.75, -1.29), 0.43, 1.42, dark, Industrial.X, 20)
	k.box(_forklift, Vector3(0, 1.185, -1.1), Vector3(1.42, 0.02, 0.6), body)
	for x: float in [-0.6, 0.6]:
		k.box(_forklift, Vector3(x, 0.95, -1.705), Vector3(0.12, 0.08, 0.04), k.signal_red)
	k.box(_forklift, Vector3(0, 0.88, -0.6), Vector3(1.1, 0.5, 0.75), body)
	k.box(_forklift, Vector3(0, 1.13, -0.6), Vector3(1.0, 0.02, 0.66), k.seam)
	# Seat with backrest, armrest and the operator cowl.
	k.box(_forklift, Vector3(0, 1.2, -0.62), Vector3(0.5, 0.12, 0.46), k.rubber)
	var backrest := k.box(_forklift, Vector3(0, 1.48, -0.86), Vector3(0.5, 0.48, 0.1), k.rubber)
	backrest.rotation.x = -0.15
	k.box(_forklift, Vector3(0.3, 1.32, -0.6), Vector3(0.08, 0.06, 0.38), k.rubber)
	k.box(_forklift, Vector3(0, 0.98, 0.35), Vector3(1.1, 0.6, 0.38), body)
	k.box(_forklift, Vector3(0, 1.3, 0.38), Vector3(0.7, 0.05, 0.3), dark)
	k.pipe(_forklift, Vector3(0, 1.28, 0.3), Vector3(0, 1.52, 0.08), 0.03, dark)
	var wheel := k.cylinder(_forklift, Vector3(0, 1.53, 0.07), 0.17, 0.03, k.rubber, Industrial.Y, 18)
	wheel.rotation.x = -0.9
	for index in 3:
		k.pipe(_forklift, Vector3(0.18 + index * 0.06, 1.3, 0.42), Vector3(0.18 + index * 0.06, 1.48, 0.36), 0.01, k.seam)
		k.joint(_forklift, Vector3(0.18 + index * 0.06, 1.48, 0.36), 0.018, k.signal_red if index == 0 else k.seam)
	# LPG cylinder on its bracket behind the seat.
	k.cylinder(_forklift, Vector3(0, 1.48, -1.16), 0.16, 0.82, k.paint(Color("#e9ecea")), Industrial.X, 18)
	k.box(_forklift, Vector3(0, 1.3, -1.16), Vector3(0.9, 0.04, 0.24), dark)
	# Overhead guard: four posts, frame and slats.
	for x: float in [-0.6, 0.6]:
		k.pipe(_forklift, Vector3(x, 1.18, -1.0), Vector3(x, 2.2, -1.0), 0.04, dark)
		k.pipe(_forklift, Vector3(x, 1.25, 0.5), Vector3(x, 2.2, 0.3), 0.04, dark)
		k.box(_forklift, Vector3(x, 2.22, -0.35), Vector3(0.08, 0.06, 1.4), dark)
		k.cylinder(_forklift, Vector3(x * 0.95, 2.05, 0.36), 0.06, 0.08, k.lens, Industrial.Z, 14)
	for index in 6:
		k.box(_forklift, Vector3(0, 2.23, -0.95 + index * 0.24), Vector3(1.24, 0.03, 0.06), dark)
	var beacon := k.make_surface(Color("#ffb020"), 0.3, 0.0)
	beacon.emission_enabled = true
	beacon.emission = Color("#ffae2a")
	beacon.emission_energy_multiplier = 1.2
	k.cylinder(_forklift, Vector3(0.45, 2.3, -0.95), 0.07, 0.12, beacon, Industrial.Y, 14)
	# Mast: outer and inner channels, cross ties, lift cylinder and chains.
	_mast = _pivot(_forklift, Vector3.ZERO)
	for x: float in [-0.44, 0.44]:
		k.box(_forklift, Vector3(x, 1.25, 0.97), Vector3(0.09, 2.3, 0.15), dark)
		k.box(_mast, Vector3(x * 0.82, 1.3, 1.04), Vector3(0.07, 2.2, 0.08), k.stainless_dark)
		k.box(_forklift, Vector3(x * 0.5, 1.2, 1.09), Vector3(0.025, 2.0, 0.015), k.seam)
	for y: float in [0.25, 1.4, 2.36]:
		k.box(_forklift, Vector3(0, y, 0.97), Vector3(0.96, 0.08, 0.12), dark)
	k.cylinder(_forklift, Vector3(0, 1.05, 0.96), 0.05, 1.6, k.chrome, Industrial.Y, 12)
	k.cylinder(_forklift, Vector3(0, 0.42, 0.96), 0.07, 0.5, dark, Industrial.Y, 12)
	_forks = _pivot(_forklift, Vector3(0, 0.07, 0))
	k.box(_forks, Vector3(0, 0.3, 1.13), Vector3(1.1, 0.36, 0.06), dark)
	for x in 6:
		k.box(_forks, Vector3(-0.5 + x * 0.2, 0.85, 1.13), Vector3(0.035, 0.75, 0.03), dark)
	k.box(_forks, Vector3(0, 1.22, 1.13), Vector3(1.1, 0.05, 0.04), dark)
	for x: float in [-0.53, 0.53]:
		k.box(_forks, Vector3(x, 0.27, 1.18), Vector3(0.12, 0.5, 0.05), k.stainless_dark)
		k.box(_forks, Vector3(x, 0.07, 1.78), Vector3(0.12, 0.05, 1.2), k.stainless_dark)
	_draw.batch_static(_forks)
	_draw.batch_static(_mast)
	_load = _stock.pallet(_forks, Vector3(0, 0.11, 1.65))
	_draw.batch_static(_forklift)


func _tyre(parent: Node3D, at: Vector3, radius: float, width: float) -> void:
	var k := _kit
	k.cylinder(parent, at, radius, width, k.rubber, Industrial.X, 22)
	k.cylinder(parent, at, radius * 0.62, width + 0.012, k.paint(Color("#c7342a")), Industrial.X, 18)
	k.cylinder(parent, at, radius * 0.25, width + 0.03, k.polished, Industrial.X, 10)


func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = at
	parent.add_child(pivot)
	return pivot


func _wheel(parent: Node3D, at: Vector3, radius: float, width: float) -> void:
	var tire := _draw.cylinder(parent, at, radius, width, RUBBER)
	tire.rotation_degrees.z = 90.0
	var hub := _draw.cylinder(parent, at, radius * 0.58, width + 0.012, SILVER)
	hub.rotation_degrees.z = 90.0
