extends RefCounted
## Renders authoritative mover positions. All model parts are reused across runs.

const Line = preload("res://simulation/production_line.gd")
const Layout = Line.Layout
const Operator = Line.Operator
const Primitives = preload("res://world/primitives.gd")
const Equipment = preload("res://world/equipment_view.gd")
const Stock = preload("res://world/stock_models.gd")

const RUBBER := Color("#29373f")
const STEEL := Color("#667982")
const SILVER := Color("#a4b6b9")
const PALE := Color("#deeceb")
const TEAL := Color("#59a8a2")
const AMBER := Color("#e7a23e")

class CrewModel:
	var view: Equipment
	var body: Node3D
	var limbs: Array[Node3D] = []
	var sack: Node3D


var _draw: Primitives
var _stock: Stock
var _parent: Node3D
var views: Dictionary[StringName, Equipment] = {}
var _crew: Dictionary[StringName, CrewModel] = {}
var _cart_coating := {}
var _forklift: Equipment
var _forks: Node3D
var _load: Stock.PalletView


func _init(parent: Node3D, draw: Primitives, stock: Stock, erp_enabled: bool) -> void:
	_parent = parent
	_draw = draw
	_stock = stock
	for index in 2:
		_build_worker(StringName("Platform%d" % (index + 1)), true)
	for index in Layout.MAX_CREW:
		_build_worker(StringName("Worker%d" % (index + 1)), false)
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


func animate(line: Line, delta: float) -> void:
	var alpha := line.interpolation()
	var t := line.elapsed_seconds() + alpha * Line.STEP_SECONDS
	var turn := 1.0 if line.elapsed_ticks == 0 else 1.0 - exp(-18.0 * delta) if line.playing else 0.0
	for operator in line.platform_crew:
		_pose_worker(operator, alpha, t, turn)
	for operator in line.floor_crew:
		_pose_worker(operator, alpha, t, turn)
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
	var walking := worker.state in [Operator.State.WALKING, Operator.State.CARRYING, Operator.State.PUSHING]
	var hands_forward := worker.cargo_kg > 0.0 or worker.state == Operator.State.PUSHING
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


func _build_worker(id: StringName, platform: bool) -> void:
	var model := CrewModel.new()
	var vest := Color("#809bdf") if platform else Color("#e2a050")
	var hat := Color("#b7dcf9") if platform else Color("#f7d468")
	model.view = _view(id, Vector3(0.92, 1.95, 0.85), hat)
	model.body = Node3D.new()
	model.view.add_child(model.body)
	_draw.box(model.body, Vector3(0, 1.17, 0), Vector3(0.61, 0.57, 0.38), vest)
	_draw.box(model.body, Vector3(0, 1.09, 0.006), Vector3(0.63, 0.075, 0.402), PALE)
	_draw.sphere(model.body, Vector3(0, 1.59, 0.04), Vector3(0.37, 0.43, 0.36), Color("#c7906c"))
	_draw.cylinder(model.body, Vector3(0, 1.80, 0.04), 0.24, 0.15, hat, 0.15)
	_draw.cylinder(model.body, Vector3(0, 1.734, 0.065), 0.25, 0.054, hat)
	for side: float in [-1.0, 1.0]:
		var leg := _pivot(model.body, Vector3(side * 0.17, 0.94, 0))
		_draw.box(leg, Vector3(0, -0.38, 0), Vector3(0.23, 0.79, 0.24), Color("#344b63"))
		_draw.box(leg, Vector3(0, -0.85, 0.067), Vector3(0.26, 0.18, 0.36), RUBBER)
		model.limbs.append(leg)
	for side: float in [-1.0, 1.0]:
		var arm := _pivot(model.body, Vector3(side * 0.37, 1.37, 0.01))
		_draw.box(arm, Vector3(0, -0.22, 0), Vector3(0.17, 0.46, 0.19), vest.darkened(0.19))
		_draw.sphere(arm, Vector3(0, -0.48, 0), Vector3(0.17, 0.19, 0.18), Color("#c7906c"))
		model.limbs.append(arm)
	model.sack = _stock.sack(model.body, Vector3(0, 1.22, 0.55), 0.84)
	model.sack.hide()
	_crew[id] = model


func _build_cart(id: StringName, raw: bool, coated: bool = false) -> void:
	var tint := Color("#b88bc7") if coated else (TEAL if raw else AMBER)
	var view := _view(id, Layout.CART_BODY, tint, Layout.CART_OFFSET)
	var tray := _pivot(view, Vector3(0, 0, 0.67))
	for x: float in [-0.48, 0.48]:
		for z: float in [-0.51, 0.51]:
			_wheel(tray, Vector3(x, 0.15, z), 0.15, 0.13)
			_draw.box(tray, Vector3(x, 0.89, z), Vector3(0.065, 1.37, 0.065), SILVER)
	for y: float in [0.41, 0.90, 1.39]:
		_draw.box(tray, Vector3(0, y, 0), Vector3(1.05, 0.085, 1.22), STEEL)
		_draw.box(tray, Vector3(0, y + 0.02, -0.62), Vector3(1.05, 0.10, 0.062), tint)
		for x: float in [-0.236, 0.236]:
			var color := Stock.CHOCOLATE if coated else (Stock.RAW if raw else Stock.COOKED)
			var wafers := _stock.wafer(tray, Vector3(x, y + 0.045, 0), color, Vector3(0.42, 0.22, 1.02))
			view.inventory_slots.append(wafers)
	_draw.box(tray, Vector3(0, 1.18, -0.73), Vector3(1.0, 0.09, 0.12), tint)
	_draw.batch_static(tray)


func _build_forklift() -> void:
	_forklift = _view(&"Forklift", Vector3(2.23, 2.98, 3.4), AMBER)
	for x: float in [-0.81, 0.81]:
		for z: float in [-0.89, 0.54]:
			_wheel(_forklift, Vector3(x, 0.34, z), 0.34, 0.34)
	_draw.box(_forklift, Vector3(0, 0.64, -0.22), Vector3(1.55, 0.68, 2.19), AMBER)
	_draw.box(_forklift, Vector3(0, 0.99, -0.89), Vector3(1.48, 0.39, 0.82), AMBER)
	_draw.box(_forklift, Vector3(0, 1.16, -0.50), Vector3(0.62, 0.27, 0.61), RUBBER)
	_draw.box(_forklift, Vector3(0, 1.42, -0.77), Vector3(0.62, 0.45, 0.16), RUBBER)
	for x: float in [-0.68, 0.68]:
		for z: float in [-0.85, 0.43]:
			_draw.box(_forklift, Vector3(x, 1.69, z), Vector3(0.12, 1.8, 0.12), RUBBER)
		_draw.box(_forklift, Vector3(x * 0.80, 1.36, 0.94), Vector3(0.15, 2.33, 0.18), STEEL)
	_draw.box(_forklift, Vector3(0, 2.60, -0.23), Vector3(1.58, 0.15, 1.66), AMBER)
	_draw.cylinder(_forklift, Vector3(0.52, 2.76, -0.65), 0.115, 0.18, Color("#ffe178"))
	_forks = _pivot(_forklift, Vector3(0, 0.07, 0))
	for x: float in [-0.53, 0.53]:
		_draw.box(_forks, Vector3(x, 0.06, 1.57), Vector3(0.18, 0.12, 1.30), RUBBER)
	_load = _stock.pallet(_forks, Vector3(0, 0.11, 1.65))
	_draw.batch_static(_forklift)


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
