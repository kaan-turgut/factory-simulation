extends SceneTree
## Coordinate, geometry and placement scenarios independent of the rendered scene.

const Layout = preload("res://layout/factory_layout.gd")
const Grid = Layout.Grid
const Placement = Layout.Placement
const Rules = Layout.Rules
const Line = preload("res://simulation/production_line.gd")

var _failures := 0


func _initialize() -> void:
	_coordinates()
	_rotation()
	_clearance()
	_elevation()
	_factory_constraints()
	_relocated_production()
	print("6 factory grid scenarios, %d failures." % _failures)
	quit(1 if _failures else 0)


func _coordinates() -> void:
	var grid := Grid.new(Vector2i(10, 6), Vector3(-32, 0, 13))
	_check(grid.to_world(Vector2.ZERO) == grid.origin, "Origin is the front-left corner")
	_check(grid.to_world(Vector2(1, 1), 3.5) == Vector3(-31, 3.5, 12), "One meter right and rear")
	_check(grid.coordinates(grid.to_world(Vector2(2.25, 5.75))) == Vector2(2.25, 5.75),
		"Continuous world coordinates round-trip without snapping")
	_check(grid.cell_at(grid.cell_center(Vector2i(9, 5))) == Vector2i(9, 5), "Last cell round-trips")
	_check(grid.cell_at(grid.to_world(Vector2(-0.01, 0))) == Vector2i(-1, 0), "Negative coordinates floor")
	_check(not grid.bounds().has_point(grid.cell_at(grid.to_world(Vector2(10, 2)))),
		"The far boundary is outside the half-open grid")


func _rotation() -> void:
	var grid := Grid.new(Vector2i(20, 20))
	var item := Placement.new(&"Test", &"machine", Vector2i(6, 7), Vector2i(4, 2), 2.1,
		0.0, 1, Vector4i(1, 2, 3, 4), {&"out": Vector3(2, 1, 0)})
	_check(item.footprint() == Rect2i(6, 7, 2, 4), "Quarter-turn swaps width and length")
	_check(item.required_area() == Rect2i(2, 6, 8, 8), "Asymmetric clearances rotate with the body")
	_check(item.port(grid, &"out").is_equal_approx(Vector3(7, 1, -11)), "Port rotates around footprint center")
	var half: Placement = item.at(item.cell, 2)
	_check(half.footprint() == Rect2i(6, 7, 4, 2), "Half-turn preserves rectangular dimensions")
	var full: Placement = item.at(item.cell, 4)
	_check(full.turns == 0 and full.port(grid, &"out") == Vector3(10, 1, -8), "Four turns restore orientation")


func _clearance() -> void:
	var grid := Grid.new(Vector2i(20, 20))
	var oven := Placement.new(&"Fixed", &"machine", Vector2i(6, 6), Vector2i(4, 3), 3.0,
		0.0, 0, Vector4i(1, 1, 1, 1))
	var plan := {oven.id: oven}
	var aisles: Array[Rect2i] = [Rect2i(0, 0, 20, 2)]
	var trial := Placement.new(&"Trial", &"machine", Vector2i(9, 6), Vector2i(3, 3), 3.0)
	_check("overlaps" in Rules.validate(grid, trial, plan, aisles), "Reject overlapping occupied cells")
	trial.cell = Vector2i(10, 6)
	_check("clearance" in Rules.validate(grid, trial, plan, aisles), "Protect neighboring clearance")
	trial.cell = Vector2i(11, 6)
	_check(Rules.validate(grid, trial, plan, aisles).is_empty(), "Touching a clearance boundary is legal")
	trial.cell = Vector2i(16, 6)
	trial.clearance = Vector4i(0, 0, 2, 0)
	_check("wall" in Rules.validate(grid, trial, plan, aisles), "A clearance may not cross the wall")
	trial.cell = Vector2i(10, 1)
	_check("aisle" in Rules.validate(grid, trial, plan, aisles), "Reject placement in reserved access area")


func _elevation() -> void:
	var grid := Grid.new(Vector2i(20, 20))
	var body := Placement.new(&"Body", &"machine", Vector2i(3, 3), Vector2i(4, 4), 3.0)
	var deck := Placement.new(&"Deck", &"platform", Vector2i(2, 2), Vector2i(8, 8), 0.2, 3.5)
	var item := Placement.new(&"Hopper", &"machine", Vector2i(3, 3), Vector2i(3, 3), 2.0, 3.5)
	var empty: Array[Rect2i] = []
	_check(Rules.validate(grid, item, {body.id: body, deck.id: deck}, empty).is_empty(),
		"An elevated machine can share the ground machine's X–Z cells")
	_check("support" in Rules.validate(grid, item, {body.id: body}, empty), "Reject floating equipment")
	body.height = 4.0
	_check("overlaps" in Rules.validate(grid, item, {body.id: body, deck.id: deck}, empty),
		"Ground equipment tall enough to intersect the upper layer still collides")


func _factory_constraints() -> void:
	var plan := Layout.new()
	var expanded_size := Layout.DEFAULT_SIZE + Vector2i(19, 4)
	var expanded := Layout.new(expanded_size)
	_check(plan.validate().is_empty() and expanded.validate().is_empty(), "Default and expanded halls validate")
	_check(plan.grid.origin == expanded.grid.origin and expanded.grid.size == expanded_size,
		"Changing hall dimensions preserves the origin")
	_check(expanded.center(&"Warehouse").x - plan.center(&"Warehouse").x == 19.0,
		"Warehouse stays at the right end of an expanded hall")
	for id: StringName in [&"RawWarehouse", &"Warehouse"]:
		_check(plan.objects[id].footprint().end.y == plan.grid.size.y - 1
			and expanded.objects[id].footprint().end.y == expanded.grid.size.y - 1,
			"The warehouse follows the rear wall at both hall sizes")
	var oven := plan.objects[&"Oven"]
	_check("overlaps" in plan.validate_move(&"Oven", plan.objects[&"Coater"].cell, 0),
		"A move cannot claim another machine's cells")
	_check("route" in plan.validate_move(&"Oven", Vector2i(18, 16), 1),
		"A footprint can fit while its rotated cart approach is obstructed")
	_check("belt" in plan.validate_move(&"Packer", Vector2i(59, 17), 0),
		"Packaging stays connected to the outbound carton conveyor")
	_check(not plan.move(&"Oven", Vector2i(-1, 16), 0).is_empty() and plan.objects[&"Oven"] == oven,
		"Failed placement leaves the original plan intact")
	_check(plan.definition(&"CoatedBelt") == null and plan.definition(&"CartonBelt").kind == &"conveyor",
		"Only the outbound carton conveyor remains")
	for id: StringName in [&"Oven", &"Oven02", &"Coater", &"Coater02"]:
		_check(plan.objects[id].cell.y > Layout.CART_LANE, "%s is on the production side of the cart aisle" % id)
	_check(plan.objects[&"PackagingWIP"].footprint().end.y < plan.objects[&"Packer"].cell.y,
		"Packaging WIP sits in front of the packer")


func _relocated_production() -> void:
	var plan := Layout.new()
	var old_dock := plan.port(&"Oven", &"raw_dock")
	_check(plan.move(&"Oven", Vector2i(16, 16), 1).is_empty(), "Valid rotated oven can be placed")
	_check(plan.port(&"Oven", &"raw_dock") != old_dock and plan.validate().is_empty(),
		"Both geometry and loading destinations use the updated plan")
	var line := Line.new(plan)
	line.set_setting(&"batch_capacity", 80.0)
	line.set_playing(true)
	line.advance(660.0)
	_check(line.warehouse_count() > 0 and line.oven.stock.capacity == 80.0,
		"Relocated line delivers stock with independent batch capacity")
	_check(absf(line.material_on_site() + line.dispatched_kg - line.ingredients_taken) < 1e-6,
		"Relocated production conserves mass")


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + description)
