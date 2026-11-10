extends RefCounted
## Primitive models for all material forms. Cart and pallet contents are preallocated.

const Primitives = preload("res://world/primitives.gd")
const Pallet = preload("res://simulation/pallet.gd")

const WOOD := Color("#97714f")
const CARTON := Color("#dba36a")
const PAPER := Color("#f2ebd6")
const SACK := Color("#d9c8a0")
const RAW := Color("#f4dfa9")
const COOKED := Color("#dfa862")
const CHOCOLATE := Color("#783c30")

class PalletView:
	var root := Node3D.new()
	var boxes: Array[MeshInstance3D] = []
	var draw: Primitives
	var shown := -1
	var color_code := ""

	func refresh(pallet: Pallet, show_empty: bool = false) -> void:
		root.visible = show_empty or pallet != null
		var count := 0
		if pallet != null:
			var displayed := mini(pallet.target_boxes, boxes.size())
			count = ceili(float(pallet.boxes) * displayed / pallet.target_boxes)
		var tint := pallet.tint if pallet != null and not pallet.tint.is_empty() else ""
		if color_code != tint:
			color_code = tint
			var surface := draw.material(Color(tint) if not tint.is_empty() else CARTON)
			for box in boxes:
				box.material_override = surface
		if shown != count:
			shown = count
			for index in boxes.size():
				boxes[index].visible = index < count


var _draw: Primitives


func _init(draw: Primitives) -> void:
	_draw = draw


func sack(parent: Node3D, at: Vector3, scale_factor: float = 1.0) -> Node3D:
	var bag := Node3D.new()
	bag.position = at
	bag.scale = Vector3.ONE * scale_factor
	parent.add_child(bag)
	_draw.sphere(bag, Vector3.ZERO, Vector3(0.98, 0.39, 0.68), SACK)
	_draw.box(bag, Vector3(0, 0.164, 0), Vector3(0.22, 0.023, 0.46), Color("#8d8062"))
	_draw.box(bag, Vector3(0, 0.181, 0.06), Vector3(0.14, 0.016, 0.19), PAPER)
	_draw.sphere(bag, Vector3(0.43, 0, 0), Vector3(0.22, 0.15, 0.23), SACK.darkened(0.12))
	return bag


func wafer(parent: Node3D, at: Vector3, color: Color, size: Vector3) -> Node3D:
	var stack := Node3D.new()
	stack.position = at
	parent.add_child(stack)
	_draw.box(stack, Vector3(0, size.y * 0.5, 0), size, color)
	for x: float in [-0.24, 0.0, 0.24]:
		_draw.box(stack, Vector3(x * size.x, size.y, 0),
			Vector3(size.x * 0.035, 0.015, size.z * 0.92), color.darkened(0.24))
	return stack


func carton(parent: Node3D, at: Vector3, size: Vector3) -> MeshInstance3D:
	var box := _draw.box(parent, at, size, CARTON)
	_draw.box(box, Vector3(0, size.y * 0.5 + 0.008, 0), Vector3(size.x * 0.23, 0.015, size.z), PAPER)
	_draw.box(box, Vector3(size.x * 0.19, 0, size.z * 0.5 + 0.008),
		Vector3(size.x * 0.39, size.y * 0.34, 0.015), PAPER)
	return box


func pallet(parent: Node3D, at: Vector3) -> PalletView:
	var view := PalletView.new()
	view.draw = _draw
	view.root.position = at
	parent.add_child(view.root)
	for z: float in [-0.5, 0.0, 0.5]:
		_draw.box(view.root, Vector3(0, 0.075, z), Vector3(1.69, 0.15, 0.17), WOOD.darkened(0.22))
	for x in 5:
		_draw.box(view.root, Vector3(-0.68 + x * 0.34, 0.185, 0), Vector3(0.26, 0.09, 1.36), WOOD)
	for level in 3:
		for z in 2:
			for x in 2:
				view.boxes.append(carton(view.root, Vector3(-0.385 + x * 0.77, 0.40 + level * 0.36,
					-0.30 + z * 0.60), Vector3(0.74, 0.34, 0.55)))
	_draw.batch_static(view.root, view.boxes)
	view.refresh(null)
	return view
