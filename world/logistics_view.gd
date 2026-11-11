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
const SHIRT := Color("#2e3f55")
const TROUSERS := Color("#2b3a4c")
const BOOTS := Color("#1b1f22")
const GLOVES := Color("#3b6fb6")
const REFLECTIVE := Color("#e9eef0")
const SKIN_TONES: Array[Color] = [Color("#e0b18e"), Color("#c68a62"), Color("#8d5a3b"), Color("#f1c9a5"), Color("#a86e4b"), Color("#6b4430")]
const HAIR: Array[Color] = [Color("#2a1f1a"), Color("#5a3a22"), Color("#1a1a1a"), Color("#8a6a45"), Color("#3d2b1f")]

class CrewModel:
	var view: Equipment
	var body: Node3D
	var limbs: Array[Node3D] = []
	var sack: Node3D


var _draw: Primitives
var _stock: Stock
var _kit: Industrial
var _parent: Node3D
var views: Dictionary[StringName, Equipment] = {}
var _crew: Dictionary[StringName, CrewModel] = {}
var _cart_coating := {}
var _forklift: Equipment
var _forks: Node3D
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
	_forks.position.y = 0.07
	if line.lift_load != null:
		var lift_height := 1.0
		if line.forklift.state == Operator.State.UNLOADING:
			lift_height = line.forklift.remaining / Line.LIFT_HANDLING_SECONDS
		_forks.position.y = lerpf(0.07, 0.28, lift_height)
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


func animate(line: Line, delta: float) -> void:
	var alpha := line.interpolation()
	var t := line.elapsed_seconds() + alpha * Line.STEP_SECONDS
	var turn := 1.0 if line.elapsed_ticks == 0 else 1.0 - exp(-18.0 * delta) if line.playing else 0.0
	for operator in line.platform_crew:
		_pose_worker(operator, alpha, t, turn)
	for operator in line.floor_crew:
		_pose_worker(operator, alpha, t, turn)
	if _jack_load != null and line.erp != null:
		var handler := line.erp.material_handler
		_pose_worker(handler, alpha, t, 1.0 if delta == 0.0 else turn)
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


func _pose_worker(worker: Operator, alpha: float, t: float, turn: float) -> void:
	var model := _crew[worker.id]
	model.view.position = worker.previous_position.lerp(worker.position, alpha)
	model.view.rotation.y = lerp_angle(model.view.rotation.y, worker.heading, turn)
	var pushing := worker.state in [Operator.State.PUSHING, Operator.State.MOVING_PALLET_JACK]
	var walking := pushing or worker.state in [Operator.State.WALKING, Operator.State.CARRYING]
	var hands_forward := worker.cargo_kg > 0.0 or pushing
	var stride := sin(t * 10.0 + float(worker.id.hash() % 19)) if walking else 0.0
	model.limbs[0].rotation.x = stride * 0.55
	model.limbs[1].rotation.x = -stride * 0.55
	var handling := worker.state in [Operator.State.LOADING, Operator.State.UNLOADING]
	if hands_forward:
		model.limbs[2].rotation.x = -1.25
		model.limbs[3].rotation.x = -1.25
	elif handling:
		model.limbs[2].rotation.x = -0.9 + sin(t * 7.0) * 0.34
		model.limbs[3].rotation.x = -0.9 - sin(t * 7.0) * 0.34
	else:
		model.limbs[2].rotation.x = -stride * 0.46
		model.limbs[3].rotation.x = stride * 0.46
	model.body.position.y = absf(stride) * 0.065
	model.sack.visible = worker.cargo_kg > 0.0


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
	model.view = _view(id, Vector3(1.24, 1.95, 2.70), hat, Vector3(0, 0, 0.13)) if handler \
		else _view(id, Vector3(0.92, 1.95, 0.85), hat)
	var look := absi(String(id).hash())
	var skin := SKIN_TONES[look % SKIN_TONES.size()]
	var hair := HAIR[(look / 7) % HAIR.size()]
	model.body = Node3D.new()
	model.body.position.z = -0.79 if handler else 0.0
	model.view.add_child(model.body)
	var body := model.body
	# Hips, work shirt and a hi-vis vest with reflective bands.
	_draw.box(body, Vector3(0, 0.96, 0), Vector3(0.32, 0.16, 0.2), TROUSERS)
	_draw.cylinder(body, Vector3(0, 1.2, 0), 0.15, 0.48, SHIRT, 0.19).scale.z = 0.68
	_draw.cylinder(body, Vector3(0, 1.2, 0.002), 0.158, 0.4, vest, 0.198).scale.z = 0.7
	for y: float in [1.07, 1.27]:
		_draw.cylinder(body, Vector3(0, y, 0.002), 0.168 + (y - 1.07) * 0.18, 0.035, REFLECTIVE).scale.z = 0.71
	for side: float in [-1.0, 1.0]:
		_draw.sphere(body, Vector3(side * 0.19, 1.4, 0), Vector3(0.14, 0.12, 0.13), SHIRT)
	_draw.box(body, Vector3(0.08, 1.33, 0.14), Vector3(0.06, 0.08, 0.012), PALE)
	# Neck, head, hair and a cap with a brim.
	_draw.cylinder(body, Vector3(0, 1.49, 0), 0.045, 0.1, skin)
	_draw.sphere(body, Vector3(0, 1.61, 0.005), Vector3(0.2, 0.24, 0.22), skin)
	_draw.sphere(body, Vector3(0, 1.635, -0.02), Vector3(0.21, 0.2, 0.2), hair)
	_draw.box(body, Vector3(0, 1.6, 0.11), Vector3(0.03, 0.05, 0.03), skin.darkened(0.08))
	_draw.sphere(body, Vector3(0, 1.69, 0.0), Vector3(0.235, 0.17, 0.25), hat)
	_draw.cylinder(body, Vector3(0, 1.665, 0.06), 0.135, 0.014, hat).scale.z = 1.25
	for side: float in [-1.0, 1.0]:
		var leg := _pivot(body, Vector3(side * 0.09, 0.92, 0))
		_draw.cylinder(leg, Vector3(0, -0.42, 0), 0.058, 0.8, TROUSERS, 0.078)
		_draw.cylinder(leg, Vector3(0, -0.62, 0), 0.066, 0.035, REFLECTIVE)
		_draw.box(leg, Vector3(0, -0.865, 0.035), Vector3(0.11, 0.11, 0.25), BOOTS)
		_draw.batch_static(leg)
		model.limbs.append(leg)
	for side: float in [-1.0, 1.0]:
		var arm := _pivot(body, Vector3(side * 0.225, 1.4, 0.0))
		_draw.cylinder(arm, Vector3(0, -0.15, 0), 0.048, 0.3, SHIRT, 0.056)
		_draw.cylinder(arm, Vector3(0, -0.42, 0), 0.04, 0.28, SHIRT, 0.047)
		_draw.sphere(arm, Vector3(0, -0.6, 0.01), Vector3(0.085, 0.11, 0.085), GLOVES)
		_draw.batch_static(arm)
		model.limbs.append(arm)
	model.sack = _stock.sack(body, Vector3(0, 1.22, 0.55), 0.84)
	model.sack.hide()
	_draw.batch_static(body)
	_crew[id] = model


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
	for x: float in [-0.44, 0.44]:
		k.box(_forklift, Vector3(x, 1.25, 0.97), Vector3(0.09, 2.3, 0.15), dark)
		k.box(_forklift, Vector3(x * 0.82, 1.3, 1.04), Vector3(0.07, 2.2, 0.08), k.stainless_dark)
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
