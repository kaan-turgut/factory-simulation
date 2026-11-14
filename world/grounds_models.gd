extends RefCounted
## The factory grounds outside the hall: grass, a public road, the main gate with a security
## gatehouse and barriers, an internal ring road, the staff car park, a garden with a pond,
## truck docks with articulated lorries at both warehouses, a trailer park and a perimeter fence.
##
## Everything is relative to the hall, so any plan size works. Vehicles and plants are
## downloaded models (assets/site, see CREDITS.md and tools/blender/build_site_props.py);
## trailers, the gatehouse, barriers, fence and markings are built from primitives. Parts are
## merged per material in a few zones so each zone costs about one draw call per material and
## zones outside the view are culled. There are no real lights. Visual only.

const Industrial = preload("res://world/industrial_models.gd")
const Hall = preload("res://world/hall_models.gd")
const Layout = preload("res://layout/factory_layout.gd")

const SITE_MODELS := "res://assets/site/%s.glb"
const CARS := ["car_sedan", "car_hatchback", "car_suv", "car_sports", "car_sedan", "car_hatchback", "car_suv", "pickup", "van"]
const CAR_COLORS := [
	Color("#e9ebec"), Color("#b9bec2"), Color("#1d2126"), Color("#4a5056"), Color("#1f3550"),
	Color("#8f1f22"), Color("#e9ebec"), Color("#b9bec2"), Color("#2f4a3a"), Color("#c9b99a"),
	Color("#3a6ea5"), Color("#1d2126")]
const HAULIERS := [
	[Color("#eef0f0"), Color("#c8302a")], [Color("#1f4f8f"), Color("#e9b730")],
	[Color("#e3e6e7"), Color("#2c7a4b")], [Color("#b9bec2"), Color("#1d2126")],
	[Color("#7a1f2b"), Color("#eef0f0")]]
const TRACTOR_COLORS := [Color("#eef0f0"), Color("#1f4f8f"), Color("#c8302a"), Color("#2b2f33"), Color("#e9b730")]

## Ground heights (tops). The hall plinth top is at -0.08.
const GRASS_Y := -0.12
const ROAD_Y := -0.095
const PAVING_Y := -0.075
const TRAILER_LENGTH := 13.6
const BAY_WIDTH := 2.5
const BAY_DEPTH := 5.0

var _kit: Industrial
var _layout: Layout
var _root: Node3D
var _zone: Node3D
var _parts: Dictionary[String, Array] = {}
var _tints: Dictionary[String, Material] = {}
var _random := RandomNumberGenerator.new()

var _grass: StandardMaterial3D
var _lawn: StandardMaterial3D
var _asphalt: StandardMaterial3D
var _paving: StandardMaterial3D
var _kerb: StandardMaterial3D
var _marking: StandardMaterial3D
var _yellow: StandardMaterial3D
var _soil: StandardMaterial3D
var _hedge: StandardMaterial3D
var _fence: StandardMaterial3D
var _fence_mesh: StandardMaterial3D
var _water: StandardMaterial3D
var _white: StandardMaterial3D
var _dark: StandardMaterial3D
var _window: StandardMaterial3D
var _wood: StandardMaterial3D

# Hall edges in floor coordinates: west, east, front (+Z, towards the default camera) and rear.
var _west: float
var _east: float
var _front: float
var _rear: float
# Site boundary (the fence line).
var _site: Rect2


func build(parent: Node3D, layout: Layout, kit: Industrial, hall: Hall) -> Node3D:
	_kit = kit
	_layout = layout
	_random.seed = 7319
	var grid := layout.grid
	_west = grid.origin.x
	_east = grid.origin.x + grid.size.x
	_front = grid.origin.z
	_rear = grid.origin.z - grid.size.y
	_site = Rect2(_west - 34.0, _rear - 26.0, (_east + 46.0) - (_west - 34.0), (_front + 46.0) - (_rear - 26.0))
	_root = Node3D.new()
	_root.name = "Grounds"
	parent.add_child(_root)
	_materials()

	_begin("GroundsBase")
	_ground()
	_roads()
	_finish()

	_begin("GroundsFront")
	_car_park(Rect2(_west - 18.0, _front + 21.0, (_east - 38.0) - (_west - 18.0), 18.5))
	_front_strip()
	_finish()

	_begin("GroundsGarden")
	_garden(Rect2(_east - 34.0, _front + 21.0, 49.0, 23.0))
	_finish()

	_begin("GroundsGate")
	_gate(_east + 23.5)
	_finish()

	_begin("GroundsEast")
	_docks(hall, &"Warehouse", 1.0)
	_trailer_park()
	_finish()

	_begin("GroundsWest")
	_docks(hall, &"RawWarehouse", -1.0)
	_west_strip()
	_finish()

	_begin("GroundsRear")
	_rear_strip()
	_finish()

	_begin("GroundsFence")
	_perimeter()
	_finish()
	return _root


## Floor-plane rectangle the camera may pan over, so the grounds can be visited.
func site_rect() -> Rect2:
	return _site.grow(6.0)


# --- Materials -------------------------------------------------------------------

func _materials() -> void:
	_grass = _textured(_noise_texture(Color("#3a5a2b"), Color("#566f38"), 21, 0.05), 0.95, 0.12)
	_lawn = _textured(_noise_texture(Color("#42672f"), Color("#5f8340"), 37, 0.09), 0.92, 0.25)
	_asphalt = _textured(_noise_texture(Color("#3b3e41"), Color("#55585b"), 5, 0.6), 0.86, 0.5)
	_paving = _kit.concrete(Color("#b9b6ad"))
	_kerb = _kit.concrete(Color("#c9c7c0"))
	_marking = _kit.make_surface(Color("#e8e9e4"), 0.7, 0.0)
	_yellow = _kit.make_surface(Color("#e6b52c"), 0.7, 0.0)
	_kit.mark_flat(_marking)
	_kit.mark_flat(_yellow)
	_soil = _textured(_noise_texture(Color("#3d2c20"), Color("#5a4232"), 9, 0.5), 1.0, 0.6)
	_kit.mark_flat(_soil)
	_hedge = _textured(_noise_texture(Color("#2c5427"), Color("#4f7d3a"), 13, 0.7), 0.9, 1.6)
	_fence = _kit.paint(Color("#3b5a45"))
	_fence_mesh = _kit.make_surface(Color("#3b5a45"), 0.6, 0.3)
	_fence_mesh.albedo_texture = _mesh_texture()
	_fence_mesh.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_fence_mesh.alpha_scissor_threshold = 0.5
	_fence_mesh.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fence_mesh.uv1_triplanar = true
	_fence_mesh.uv1_world_triplanar = true
	_fence_mesh.uv1_scale = Vector3(4.0, 4.0, 4.0)
	_kit.mark_flat(_fence_mesh)
	_water = _kit.make_surface(Color("#2d5560"), 0.04, 0.2)
	_white = _kit.paint(Color("#eceeed"))
	_dark = _kit.paint(Color("#2b3238"))
	_window = _kit.make_surface(Color("#9fbac8"), 0.06, 0.3)
	_window.emission_enabled = true
	_window.emission = Color("#c8dce6")
	_window.emission_energy_multiplier = 0.25
	_wood = _kit.make_surface(Color("#8a6143"), 0.8, 0.0)


func _textured(texture: Texture2D, roughness: float, scale: float) -> StandardMaterial3D:
	# World-space triplanar, so merged and differently sized slabs share one material.
	var surface := _kit.make_surface(Color.WHITE, roughness, 0.0)
	surface.albedo_texture = texture
	surface.uv1_triplanar = true
	surface.uv1_world_triplanar = true
	surface.uv1_triplanar_sharpness = 4.0
	surface.uv1_scale = Vector3.ONE * scale
	return surface


func _noise_texture(dark: Color, light: Color, seed: int, frequency: float) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed = seed
	noise.frequency = frequency
	noise.fractal_octaves = 4
	var source := noise.get_seamless_image(128, 128)
	var image := Image.create_empty(128, 128, false, Image.FORMAT_RGB8)
	var grain := RandomNumberGenerator.new()
	grain.seed = seed
	for y in 128:
		for x in 128:
			var value := clampf(source.get_pixel(x, y).r + grain.randf_range(-0.08, 0.08), 0.0, 1.0)
			image.set_pixel(x, y, dark.lerp(light, value))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _mesh_texture() -> ImageTexture:
	# Welded mesh: 4 mm wires on a 50 x 200 mm grid, one tile = 25 cm.
	var image := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var wire := x % 13 < 2 or y < 3
			image.set_pixel(x, y, Color(1, 1, 1, 1.0 if wire else 0.0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


# --- Zones and helpers -----------------------------------------------------------

func _begin(title: String) -> void:
	_zone = Node3D.new()
	_zone.name = title
	_root.add_child(_zone)


func _finish() -> void:
	_kit.finish(_zone)


func _slab(area: Rect2, top: float, thickness: float, surface: Material) -> void:
	# A flat slab over an x/z rectangle (Rect2 x = world x, y = world z).
	var center := area.get_center()
	_kit.box(_zone, Vector3(center.x, top - thickness * 0.5, center.y),
		Vector3(area.size.x, thickness, area.size.y), surface)


func _stripe(from: Vector3, to: Vector3, width: float, surface: Material = null, lift: float = 0.012) -> void:
	# A painted line on the road between two points.
	var delta := to - from
	var piece := _kit.box(_zone, (from + to) * 0.5 + Vector3(0, lift * 0.5, 0),
		Vector3(width, lift, delta.length()), _marking if surface == null else surface)
	piece.rotation.y = atan2(delta.x, delta.z)


func _piece(at: Vector3, size: Vector3, surface: Material, yaw: float = 0.0) -> MeshInstance3D:
	var piece := _kit.box(_zone, at, size, surface)
	piece.rotation.y = yaw
	return piece


func _prop(at: Vector3, yaw: float) -> Node3D:
	var node := Node3D.new()
	node.position = at
	node.rotation.y = yaw
	_zone.add_child(node)
	return node


func _commit(prop: Node3D) -> void:
	# Flatten a prop's parts into the zone so they merge with everything else.
	for child in prop.get_children():
		var part := child as Node3D
		var placed := prop.transform * part.transform
		prop.remove_child(part)
		_zone.add_child(part)
		part.transform = placed
	_zone.remove_child(prop)
	prop.free()


func _model(name: String, at: Vector3, yaw: float = 0.0, scale: float = 1.0, tint: Variant = null) -> void:
	# Places a downloaded model as mergeable single-material parts. `tint` recolours the
	# material named `<name>_paint` (vehicle bodywork).
	for part: Array in _model_parts(name):
		var surface: Material = part[1]
		if tint != null and surface != null and surface.resource_name.ends_with("_paint"):
			surface = _tinted(surface, tint)
		var piece := MeshInstance3D.new()
		piece.mesh = part[0]
		piece.material_override = surface
		piece.transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale), at)
		_zone.add_child(piece)


func _model_parts(name: String) -> Array:
	if _parts.has(name):
		return _parts[name]
	var parts: Array = []
	var scene := load(SITE_MODELS % name) as PackedScene
	if scene != null:
		var root := scene.instantiate()
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var source := node as MeshInstance3D
			var placed := _relative(root, source)
			for surface in source.mesh.get_surface_count():
				var tool := SurfaceTool.new()
				tool.append_from(source.mesh, surface, placed)
				var mesh := tool.commit()
				mesh.set_meta("mergeable", true)
				parts.append([mesh, _prepare(source.get_active_material(surface))])
		root.free()
	else:
		push_warning("Grounds: missing model " + name)
	_parts[name] = parts
	return parts


func _prepare(surface: Material) -> Material:
	# Leaves and petals use alpha scissor instead of blending; everything else is opaque.
	# Car glass gets a glossy finish.
	var base := surface as BaseMaterial3D
	if base == null:
		return surface
	if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		if base.albedo_texture != null:
			base.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			base.alpha_scissor_threshold = 0.45
			base.cull_mode = BaseMaterial3D.CULL_DISABLED
		else:
			base.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	var title := base.resource_name.to_lower()
	if title.contains("window") or title.contains("glass"):
		base.roughness = 0.08
		base.metallic = 0.35
		base.albedo_color = Color("#1a242c")
	elif title.ends_with("_paint"):
		base.roughness = 0.32
		base.metallic = 0.25
	return base


func _tinted(surface: Material, tint: Color) -> Material:
	var key := "%s/%s" % [surface.resource_name, tint.to_html()]
	if not _tints.has(key):
		var copy := surface.duplicate() as BaseMaterial3D
		copy.albedo_color = tint
		copy.albedo_texture = null
		_tints[key] = copy
	return _tints[key]


func _relative(root: Node, node: Node3D) -> Transform3D:
	var placed := node.transform
	var parent := node.get_parent()
	while parent != root and parent is Node3D:
		placed = (parent as Node3D).transform * placed
		parent = parent.get_parent()
	return placed


func _tree(at: Vector2, kinds: Array = ["tree_oak_a", "tree_oak_b", "tree_oak_c", "tree_birch_a", "tree_birch_b"]) -> void:
	var kind: String = kinds[_random.randi() % kinds.size()]
	_model(kind, Vector3(at.x, GRASS_Y, at.y), _random.randf() * TAU, _random.randf_range(1.05, 1.4))


func _pick_car() -> String:
	return CARS[_random.randi() % CARS.size()]


func _car_color() -> Color:
	return CAR_COLORS[_random.randi() % CAR_COLORS.size()]


# --- Ground and roads ------------------------------------------------------------

func _ground() -> void:
	# Grass to the horizon; the haze blends it into the sky colour.
	var center := _site.get_center()
	_kit.box(_zone, Vector3(center.x, GRASS_Y - 0.15, center.y), Vector3(1600, 0.3, 1600), _grass)


func _roads() -> void:
	var s := _site
	# Public road outside the front fence, with verges and a centre line.
	var public := Rect2(-800.0 + s.get_center().x, s.end.y + 6.0, 1600.0, 8.0)
	_slab(public, ROAD_Y, 0.2, _asphalt)
	for x in range(int(public.position.x / 6.0) * 6, int(public.end.x), 6):
		if absf(x - s.get_center().x) < 260.0:
			_stripe(Vector3(x, ROAD_Y, public.get_center().y), Vector3(x + 3.0, ROAD_Y, public.get_center().y), 0.14)
	for z: float in [public.position.y + 0.25, public.end.y - 0.25]:
		_stripe(Vector3(s.get_center().x - 260.0, ROAD_Y, z), Vector3(s.get_center().x + 260.0, ROAD_Y, z), 0.12)
	# Footway along the site side of the public road.
	_slab(Rect2(public.position.x, s.end.y + 2.5, public.size.x, 3.0), PAVING_Y, 0.2, _paving)

	# Internal ring road, 7 m wide.
	var front := Rect2(_west - 27.0, _front + 14.0, (_east + 27.0) - (_west - 27.0), 7.0)
	var east := Rect2(_east + 20.0, _rear - 18.0, 7.0, (_front + 21.0) - (_rear - 18.0))
	var west := Rect2(_west - 27.0, _rear - 18.0, 7.0, (_front + 21.0) - (_rear - 18.0))
	var rear := Rect2(_west - 27.0, _rear - 18.0, (_east + 27.0) - (_west - 27.0), 7.0)
	for road in [front, east, west, rear]:
		_slab(road, ROAD_Y, 0.2, _asphalt)
	_centre_line(Vector3(front.position.x + 8.0, ROAD_Y, front.get_center().y), Vector3(front.end.x - 8.0, ROAD_Y, front.get_center().y))
	_centre_line(Vector3(rear.position.x + 8.0, ROAD_Y, rear.get_center().y), Vector3(rear.end.x - 8.0, ROAD_Y, rear.get_center().y))
	_centre_line(Vector3(east.get_center().x, ROAD_Y, east.position.y + 8.0), Vector3(east.get_center().x, ROAD_Y, east.end.y - 8.0))
	_centre_line(Vector3(west.get_center().x, ROAD_Y, west.position.y + 8.0), Vector3(west.get_center().x, ROAD_Y, west.end.y - 8.0))
	# Gate road from the ring road out to the public road, wide enough for two lanes and an island.
	_slab(Rect2(_east + 16.0, _front + 21.0, 15.0, s.end.y + 6.0 - (_front + 21.0)), ROAD_Y, 0.2, _asphalt)
	# Kerbs along the hall-side edge of the front road.
	_slab(Rect2(_west - 20.0, _front + 13.8, (_east + 20.0) - (_west - 20.0), 0.2), ROAD_Y + 0.12, 0.3, _kerb)
	# Paved apron around the hall, starting where the hall plinth ends.
	_slab(Rect2(_west - 1.5, _front + 0.36, (_east - _west) + 3.0, 2.64), PAVING_Y, 0.2, _paving)
	_slab(Rect2(_west - 1.5, _rear - 3.0, (_east - _west) + 3.0, 2.64), PAVING_Y, 0.2, _paving)


func _centre_line(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	var direction := (to - from).normalized()
	var at := 0.0
	while at + 3.0 <= length:
		_stripe(from + direction * at, from + direction * (at + 3.0), 0.12)
		at += 6.0


# --- Car park --------------------------------------------------------------------

func _car_park(area: Rect2) -> void:
	# Two rows of bays facing a central aisle, behind a planted verge with two entrances.
	# Trees stand in islands every 12 bays; lamp posts line the aisle.
	_slab(area, ROAD_Y + 0.003, 0.2, _asphalt)
	var verge := Rect2(area.position, Vector2(area.size.x, 2.0))
	var row_one := area.position.y + 2.0
	var aisle := Rect2(area.position.x, row_one + BAY_DEPTH, area.size.x, 6.5)
	var row_two := aisle.end.y
	var bays := int(area.size.x / BAY_WIDTH)
	var entrances: Array[int] = [int(bays * 0.25), int(bays * 0.75)]
	# Verge with kerbs, grass and a low hedge, broken at the entrances.
	var cursor := area.position.x
	for entrance: int in entrances + [bays + 3]:
		var stop := area.position.x + (entrance - 1) * BAY_WIDTH if entrance <= bays else area.end.x
		if stop > cursor:
			var strip := Rect2(cursor, verge.position.y, stop - cursor, verge.size.y)
			_slab(strip, ROAD_Y + 0.16, 0.3, _kerb)
			_slab(strip.grow(-0.15), ROAD_Y + 0.18, 0.3, _lawn)
			_piece(Vector3(strip.get_center().x, ROAD_Y + 0.6, strip.get_center().y), Vector3(strip.size.x - 1.0, 0.9, 0.8), _hedge)
		cursor = area.position.x + (entrance + 2) * BAY_WIDTH
	# Bays: white lines, wheel stops, and cars in about two thirds of them.
	for row in 2:
		var top := row_one if row == 0 else row_two
		var facing := PI if row == 0 else 0.0
		for index in bays:
			var x := area.position.x + index * BAY_WIDTH
			var entrance_bay := false
			for entrance: int in entrances:
				if row == 0 and index >= entrance - 1 and index <= entrance + 1:
					entrance_bay = true
			if entrance_bay:
				continue
			var island := index % 12 == 6
			if island:
				var bed := Rect2(x + 0.15, top + 0.15, BAY_WIDTH - 0.3, BAY_DEPTH - 0.3)
				_slab(bed, ROAD_Y + 0.16, 0.3, _kerb)
				_slab(bed.grow(-0.15), ROAD_Y + 0.18, 0.3, _soil)
				_tree(bed.get_center(), ["tree_birch_a", "tree_birch_b", "tree_oak_c"])
				continue
			_stripe(Vector3(x, ROAD_Y, top), Vector3(x, ROAD_Y, top + BAY_DEPTH), 0.1)
			_stripe(Vector3(x + BAY_WIDTH, ROAD_Y, top), Vector3(x + BAY_WIDTH, ROAD_Y, top + BAY_DEPTH), 0.1)
			var stop_z := top + 0.6 if row == 0 else top + BAY_DEPTH - 0.6
			_piece(Vector3(x + BAY_WIDTH * 0.5, ROAD_Y + 0.06, stop_z), Vector3(1.5, 0.12, 0.16), _yellow)
			if _random.randf() < 0.68:
				var car := _pick_car()
				var yaw := facing + _random.randf_range(-0.03, 0.03)
				var drift := _random.randf_range(-0.12, 0.12)
				_model(car, Vector3(x + BAY_WIDTH * 0.5 + drift, ROAD_Y, top + BAY_DEPTH * 0.5), yaw, 1.0, _car_color())
	# Accessible bays beside the east entrance, marked in blue.
	var blue := _kit.make_surface(Color("#2f6fb0"), 0.7, 0.0)
	_kit.mark_flat(blue)
	for index in 3:
		var x: float = area.position.x + (entrances[1] + 3 + index) * BAY_WIDTH + BAY_WIDTH * 0.5
		_piece(Vector3(x, ROAD_Y + 0.008, row_one + 1.8), Vector3(1.4, 0.012, 1.4), blue)
	# Aisle arrows and lamp posts.
	for index in range(1, int(area.size.x / 20.0)):
		var x := area.position.x + index * 20.0
		_stripe(Vector3(x - 1.0, ROAD_Y, aisle.get_center().y), Vector3(x + 1.0, ROAD_Y, aisle.get_center().y), 0.3)
		var lamp_z := row_two + BAY_DEPTH + 0.6
		_model("street_light", Vector3(x + 1.25, ROAD_Y, lamp_z), PI)
	# Back boundary: kerb, grass bank and a hedge in front of the fence.
	var bank := Rect2(area.position.x, row_two + BAY_DEPTH, area.size.x, _site.end.y - (row_two + BAY_DEPTH))
	_slab(Rect2(bank.position, Vector2(bank.size.x, 0.25)), ROAD_Y + 0.16, 0.3, _kerb)
	_slab(Rect2(bank.position + Vector2(0, 0.25), bank.size - Vector2(0, 0.25)), GRASS_Y + 0.03, 0.2, _lawn)
	_piece(Vector3(bank.get_center().x, ROAD_Y + 0.75, bank.end.y - 2.2), Vector3(bank.size.x, 1.6, 1.1), _hedge)
	for index in int(bank.size.x / 16.0):
		_tree(Vector2(bank.position.x + 8.0 + index * 16.0, bank.end.y - 4.5))
	# "STAFF PARKING" sign at each entrance.
	for entrance: int in entrances:
		var x := area.position.x + entrance * BAY_WIDTH + BAY_WIDTH * 0.5
		_sign(Vector3(x - 4.6, ROAD_Y, area.position.y + 1.0), 0.0, "STAFF PARKING", Color("#1f4f8f"))


func _sign(at: Vector3, yaw: float, text: String, color: Color) -> void:
	# A post-mounted sign panel with the text on both faces.
	var prop := _prop(at, yaw)
	for x: float in [-0.7, 0.7]:
		_kit.box(prop, Vector3(x, 1.0, 0), Vector3(0.08, 2.0, 0.08), _kit.stainless_dark)
	_kit.box(prop, Vector3(0, 1.75, 0), Vector3(1.9, 0.55, 0.05), _kit.paint(color))
	for side: float in [1.0, -1.0]:
		var label := Label3D.new()
		label.text = text
		label.font_size = 40
		label.pixel_size = 0.006
		label.outline_size = 0
		label.modulate = Color("#f4f6f5")
		label.position = at + Vector3(0, 1.75, 0) + Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.03 * side)
		label.rotation.y = yaw + (0.0 if side > 0.0 else PI)
		label.double_sided = false
		label.visibility_range_end = 90.0
		_zone.add_child(label)
	_commit(prop)


# --- Front of the hall -----------------------------------------------------------

func _front_strip() -> void:
	# Lawn between the hall apron and the front road, with low shrubs and flower beds
	# (nothing tall, so the view into the hall stays open), and a footpath with crossings.
	var lawn := Rect2(_west - 20.0, _front + 3.0, (_east + 20.0) - (_west - 20.0), 10.8)
	_slab(lawn, GRASS_Y + 0.03, 0.2, _lawn)
	var path := Rect2(_west - 1.5, _front + 3.0, (_east - _west) + 3.0, 2.0)
	_slab(path, PAVING_Y, 0.2, _paving)
	for x: float in [_west + 22.0, _west + 70.0]:
		_slab(Rect2(x - 1.5, _front + 5.0, 3.0, 9.0), PAVING_Y, 0.2, _paving)
		for stripe in 6:
			var z := _front + 14.5 + stripe * 1.1
			_piece(Vector3(x, ROAD_Y + 0.006, z), Vector3(3.0, 0.012, 0.55), _marking)
	var x := _west + 2.0
	while x < _east - 2.0:
		if absf(x - (_west + 22.0)) > 4.0 and absf(x - (_west + 70.0)) > 4.0:
			var bed := Rect2(x, _front + 7.0, 6.0, 2.4)
			_slab(bed, GRASS_Y + 0.12, 0.2, _soil)
			for index in 9:
				var kind: String = ["flowers_a", "flower_group", "flowers_b", "flowers_a", "bush"][(index + int(x)) % 5]
				var scale := 0.6 if kind == "bush" else 1.6
				var row := 0.45 if index % 2 == 0 else -0.45
				_model(kind, Vector3(bed.position.x + 0.5 + index * 0.62, GRASS_Y + 0.12, bed.get_center().y + row), _random.randf() * TAU, scale)
		x += 9.0


# --- Garden ----------------------------------------------------------------------

func _garden(area: Rect2) -> void:
	# A staff garden: lawn crossed by paved paths meeting at a round pond with a fountain,
	# benches around it, flower beds along the paths, picnic tables, hedges and trees.
	_slab(area, GRASS_Y + 0.03, 0.2, _lawn)
	var center := area.get_center()
	_slab(Rect2(area.position.x, center.y - 1.0, area.size.x, 2.0), PAVING_Y, 0.2, _paving)
	_slab(Rect2(center.x - 1.0, area.position.y, 2.0, area.size.y), PAVING_Y, 0.2, _paving)
	# Plaza and pond.
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y - 0.1, center.y), 7.0, 0.2, _paving, Industrial.Y, 40)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 0.2, center.y), 4.4, 0.55, _kerb, Industrial.Y, 40)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 0.42, center.y), 4.05, 0.2, _water, Industrial.Y, 40)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 0.8, center.y), 0.35, 1.0, _kerb, Industrial.Y, 16)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 1.35, center.y), 1.1, 0.12, _kerb, Industrial.Y, 24)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 1.42, center.y), 0.95, 0.04, _water, Industrial.Y, 24)
	_kit.cylinder(_zone, Vector3(center.x, PAVING_Y + 1.7, center.y), 0.18, 0.55, _kerb, Industrial.Y, 12)
	for index in 6:
		var angle := TAU * index / 6.0 + PI / 6.0
		var at := Vector3(center.x + sin(angle) * 6.0, PAVING_Y, center.y + cos(angle) * 6.0)
		_model("bench", at, angle + PI)
	# Flower beds along the paths, between the plaza and the garden edge.
	for side: float in [-1.0, 1.0]:
		for along: float in [-1.0, 1.0]:
			var bed_x := center.x + side * (area.size.x * 0.25 + 1.5)
			var bed := Rect2(bed_x - 6.0, center.y + along * 2.2 - 0.7, 12.0, 1.4)
			_slab(bed, GRASS_Y + 0.14, 0.2, _soil)
			for index in 13:
				var kind: String = ["flowers_a", "flower_group", "flowers_b", "bush_flowers"][(index + int(side + along * 2.0) + 4) % 4]
				var scale := 0.55 if kind == "bush_flowers" else 1.5
				_model(kind, Vector3(bed.position.x + 0.6 + index * 0.9, GRASS_Y + 0.14, bed.get_center().y + (0.3 if index % 2 == 0 else -0.3)), _random.randf() * TAU, scale)
	# Picnic tables in the corner quarters and trees around the edge.
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var at := center + Vector2(corner.x * area.size.x * 0.3, corner.y * area.size.y * 0.27)
		if corner.y > 0.0:
			_picnic_table(Vector3(at.x, GRASS_Y + 0.05, at.y), _random.randf_range(-0.3, 0.3))
		else:
			_model("bush_flowers", Vector3(at.x, GRASS_Y + 0.05, at.y), _random.randf() * TAU, 0.9)
	var trees := [Vector2(0.08, 0.15), Vector2(0.2, 0.85), Vector2(0.42, 0.88), Vector2(0.62, 0.86),
		Vector2(0.86, 0.82), Vector2(0.94, 0.3), Vector2(0.06, 0.6), Vector2(0.68, 0.14)]
	for spot: Vector2 in trees:
		_tree(area.position + area.size * spot)
	# Hedge along the road side, with gaps for the paths.
	for side: float in [-1.0, 1.0]:
		var half := (area.size.x * 0.5 - 1.6) * 0.5
		var hedge_x := center.x + side * (1.6 + half)
		_piece(Vector3(hedge_x, GRASS_Y + 0.6, area.position.y + 0.8), Vector3(half * 2.0 - 0.6, 1.1, 0.8), _hedge)
	for index in 5:
		_model("bush", Vector3(area.end.x - 1.4, GRASS_Y + 0.05, area.position.y + 3.0 + index * 4.4), _random.randf() * TAU, 0.9)


func _picnic_table(at: Vector3, yaw: float) -> void:
	var prop := _prop(at, yaw)
	_kit.box(prop, Vector3(0, 0.74, 0), Vector3(1.9, 0.05, 0.8), _wood)
	for side: float in [-1.0, 1.0]:
		_kit.box(prop, Vector3(0, 0.44, side * 0.7), Vector3(1.9, 0.045, 0.3), _wood)
		for end: float in [-0.75, 0.75]:
			var leg := _kit.box(prop, Vector3(end, 0.37, side * 0.32), Vector3(0.07, 0.8, 0.07), _wood)
			leg.rotation.x = side * 0.42
	_commit(prop)


# --- Main gate and security gatehouse --------------------------------------------

func _gate(center_x: float) -> void:
	# Two lanes split by a kerbed island carrying the gatehouse. Entering traffic keeps right
	# (east lane). Barriers stop each lane at the gatehouse; the sliding gate stands open.
	var fence_z := _site.end.y
	var island := Rect2(center_x - 2.0, fence_z - 13.0, 4.0, 17.0)
	_slab(island, ROAD_Y + 0.16, 0.3, _kerb)
	_slab(island.grow(-0.2), ROAD_Y + 0.17, 0.3, _paving)
	# Island nose bollards and bins.
	for z: float in [island.position.y + 0.5, island.end.y - 0.5]:
		_kit.cylinder(_zone, Vector3(center_x, ROAD_Y + 0.6, z), 0.12, 0.9, _yellow, Industrial.Y, 12)
	var house_z := fence_z - 5.0
	_gatehouse(Vector3(center_x, ROAD_Y + 0.17, house_z))
	# Canopy over both lanes on four columns.
	var canopy_z := house_z
	for x: float in [center_x - 7.3, center_x + 7.3]:
		for z: float in [canopy_z - 3.0, canopy_z + 3.0]:
			_kit.box(_zone, Vector3(x, 2.6, z), Vector3(0.25, 5.4, 0.25), _dark)
	_piece(Vector3(center_x, 5.45, canopy_z), Vector3(15.6, 0.4, 7.0), _white)
	_piece(Vector3(center_x, 5.2, canopy_z + 3.52), Vector3(15.6, 0.5, 0.06), _kit.paint(Color("#7a3b1f")))
	_piece(Vector3(center_x, 5.2, canopy_z - 3.52), Vector3(15.6, 0.5, 0.06), _kit.paint(Color("#7a3b1f")))
	for x: float in [center_x - 4.6, center_x + 4.6]:
		_piece(Vector3(x, 5.22, canopy_z), Vector3(1.4, 0.04, 0.7), _kit.lens)
	var title := Label3D.new()
	title.text = "CHOCOLATE WORKS"
	title.font_size = 64
	title.pixel_size = 0.009
	title.outline_size = 0
	title.modulate = Color("#f3e3c6")
	title.position = Vector3(center_x, 5.2, canopy_z + 3.56)
	title.double_sided = false
	title.visibility_range_end = 140.0
	_zone.add_child(title)
	# Barriers: entering lane closed, leaving lane open. Intercom posts at the driver's side.
	_barrier(Vector3(center_x + 2.1, ROAD_Y + 0.17, house_z + 3.2), 0.0, false)
	_barrier(Vector3(center_x - 2.1, ROAD_Y + 0.17, house_z - 3.2), PI, true)
	_intercom(Vector3(center_x + 2.3, ROAD_Y + 0.17, house_z + 4.6), PI * 0.5)
	_intercom(Vector3(center_x - 2.3, ROAD_Y + 0.17, house_z - 4.6), -PI * 0.5)
	# Stop lines, lane arrows and speed humps.
	_stripe(Vector3(center_x + 2.0, ROAD_Y, house_z + 4.0), Vector3(center_x + 7.5, ROAD_Y, house_z + 4.0), 0.4)
	_stripe(Vector3(center_x - 7.5, ROAD_Y, house_z - 4.0), Vector3(center_x - 2.0, ROAD_Y, house_z - 4.0), 0.4)
	for side: float in [-1.0, 1.0]:
		var hump_z := house_z - side * 10.0
		for index in 6:
			var piece := _piece(Vector3(center_x + side * 4.75 - 2.25 + index * 0.9, ROAD_Y + 0.05, hump_z),
				Vector3(0.9, 0.1, 1.0), _yellow if index % 2 == 0 else _dark)
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# A van waits at the entry barrier; a box truck leaves under the raised one.
	_model("van", Vector3(center_x + 4.75, ROAD_Y, house_z + 7.0), PI, 1.0, Color("#eef0f0"))
	_model("box_truck", Vector3(center_x - 4.75, ROAD_Y, house_z - 1.5), 0.0, 1.0, Color("#7a3b1f"))
	# Gate posts and the open sliding gate parked along the fence.
	for x: float in [center_x - 8.5, center_x + 8.5]:
		_kit.box(_zone, Vector3(x, 1.4, fence_z), Vector3(0.3, 2.8, 0.3), _fence)
		_kit.box(_zone, Vector3(x, 2.9, fence_z), Vector3(0.36, 0.08, 0.36), _fence)
	var gate := Rect2(center_x + 8.7, fence_z - 0.35, 17.0, 0.2)
	_kit.box(_zone, Vector3(gate.get_center().x, 0.15, gate.get_center().y), Vector3(gate.size.x, 0.1, 0.1), _fence)
	_kit.box(_zone, Vector3(gate.get_center().x, 2.2, gate.get_center().y), Vector3(gate.size.x, 0.1, 0.1), _fence)
	_kit.box(_zone, Vector3(gate.get_center().x, 1.18, gate.get_center().y), Vector3(gate.size.x, 2.0, 0.02), _fence_mesh)
	for index in 6:
		_kit.box(_zone, Vector3(gate.position.x + index * gate.size.x / 5.0, 1.2, gate.get_center().y),
			Vector3(0.08, 2.1, 0.08), _fence)
	# Company sign at the entrance and CCTV on a pole.
	_sign(Vector3(center_x + 11.0, ROAD_Y, fence_z + 2.0), 0.0, "GOODS IN  ›  GATE 1", Color("#7a3b1f"))
	var pole := Vector3(center_x - 9.6, ROAD_Y, fence_z - 1.5)
	_kit.cylinder(_zone, pole + Vector3(0, 3.0, 0), 0.08, 6.0, _kit.stainless_dark, Industrial.Y, 10)
	for yaw: float in [0.6, -2.4]:
		var camera := _piece(pole + Vector3(0, 5.7, 0) + Basis(Vector3.UP, yaw) * Vector3(0, 0, 0.25),
			Vector3(0.16, 0.16, 0.42), _white, yaw)
		camera.rotation.x = -0.25
	for x: float in [center_x - 11.0, center_x + 11.0]:
		_model("street_light", Vector3(x, ROAD_Y, fence_z - 3.0), PI * 0.5 if x < center_x else -PI * 0.5)


func _gatehouse(base: Vector3) -> void:
	# A glazed security cabin: plinth, white lower panels, a band of windows on all sides,
	# a flat roof with a deep fascia, a door facing the site, and a desk with monitors inside.
	var prop := _prop(base, 0.0)
	var size := Vector3(3.2, 0.0, 5.0)
	_kit.box(prop, Vector3(0, 0.1, 0), Vector3(size.x + 0.2, 0.2, size.z + 0.2), _kit.concrete(Color("#8d8a83")))
	for side in 4:
		var along_x := side < 2
		var sign_value := -1.0 if side % 2 == 0 else 1.0
		var span := size.x if along_x else size.z
		var at := Vector3(0, 0, sign_value * size.z * 0.5) if along_x else Vector3(sign_value * size.x * 0.5, 0, 0)
		var wall := Vector3(span, 0, 0.12) if along_x else Vector3(0.12, 0, span)
		_kit.box(prop, at + Vector3(0, 0.7, 0), wall + Vector3(0, 1.0, 0), _white)
		_kit.box(prop, at + Vector3(0, 1.75, 0), wall * Vector3(0.98, 0, 0.5) + Vector3(0, 1.1, 0), _window)
		_kit.box(prop, at + Vector3(0, 2.62, 0), wall + Vector3(0, 0.64, 0), _white)
		for post in 3:
			var offset := (post - 1) * span * 0.49
			var mullion := Vector3(offset, 1.75, 0) if along_x else Vector3(0, 1.75, offset)
			_kit.box(prop, at + mullion, Vector3(0.08, 1.12, 0.14) if along_x else Vector3(0.14, 1.12, 0.08), _dark)
		_kit.box(prop, at + Vector3(0, 1.2, 0), wall * Vector3(1.0, 0, 1.6) + Vector3(0, 0.06, 0), _dark)
	# Door on the north face (towards the site).
	_kit.box(prop, Vector3(0.6, 1.2, -size.z * 0.5 - 0.02), Vector3(0.95, 2.1, 0.06), _kit.paint(Color("#5d6a72")))
	_kit.box(prop, Vector3(0.6, 1.55, -size.z * 0.5 - 0.06), Vector3(0.6, 0.7, 0.02), _window)
	# Roof with fascia, rooftop unit and a beacon.
	_kit.box(prop, Vector3(0, 3.05, 0), Vector3(size.x + 1.2, 0.25, size.z + 1.2), _white)
	for side: float in [-1.0, 1.0]:
		_kit.box(prop, Vector3(side * (size.x * 0.5 + 0.62), 2.95, 0), Vector3(0.04, 0.45, size.z + 1.24), _kit.paint(Color("#7a3b1f")))
		_kit.box(prop, Vector3(0, 2.95, side * (size.z * 0.5 + 0.62)), Vector3(size.x + 1.24, 0.45, 0.04), _kit.paint(Color("#7a3b1f")))
	_kit.box(prop, Vector3(0.4, 3.4, 1.0), Vector3(1.0, 0.5, 0.8), _kit.stainless_dark)
	_kit.cylinder(prop, Vector3(-1.0, 3.3, -1.6), 0.09, 0.2, _kit.glow, Industrial.Y, 10)
	# Inside: desk under the window with monitors, a chair and a key cabinet.
	_kit.box(prop, Vector3(1.2, 0.9, 0), Vector3(0.7, 0.05, 3.6), _wood)
	_kit.box(prop, Vector3(1.2, 0.45, 0), Vector3(0.6, 0.85, 0.05), _dark)
	for index in 3:
		var monitor := Vector3(1.35, 1.2, -1.0 + index * 1.0)
		_kit.box(prop, monitor, Vector3(0.05, 0.36, 0.6), _dark)
		_kit.box(prop, monitor + Vector3(-0.03, 0, 0), Vector3(0.01, 0.3, 0.54), _kit.screen)
	_kit.box(prop, Vector3(0.4, 0.5, 0.2), Vector3(0.5, 0.08, 0.5), _dark)
	_kit.box(prop, Vector3(0.15, 0.85, 0.2), Vector3(0.06, 0.6, 0.5), _dark)
	_kit.box(prop, Vector3(-1.4, 1.5, 2.0), Vector3(0.12, 0.7, 0.5), _kit.paint(Color("#c8302a")))
	_commit(prop)
	var label := Label3D.new()
	label.text = "SECURITY"
	label.font_size = 48
	label.pixel_size = 0.0075
	label.outline_size = 0
	label.modulate = Color("#f3e3c6")
	label.double_sided = false
	label.visibility_range_end = 110.0
	label.position = base + Vector3(0, 2.95, size.z * 0.5 + 0.66)
	_zone.add_child(label)
	var back := label.duplicate() as Label3D
	back.position = base + Vector3(0, 2.95, -size.z * 0.5 - 0.66)
	back.rotation.y = PI
	_zone.add_child(back)


func _barrier(pivot: Vector3, yaw: float, raised: bool) -> void:
	# Boom barrier: a cabinet on the island and a red and white boom across the lane.
	var prop := _prop(pivot, yaw)
	_kit.box(prop, Vector3(0, 0.55, 0), Vector3(0.36, 1.1, 0.36), _kit.paint(Color("#e9b730")))
	_kit.box(prop, Vector3(0, 1.12, 0), Vector3(0.4, 0.06, 0.4), _dark)
	var boom := Node3D.new()
	boom.position = Vector3(0.0, 0.95, 0.22)
	boom.rotation.z = 1.35 if raised else 0.0
	prop.add_child(boom)
	for index in 10:
		var tone := _signal_white() if index % 2 == 0 else _kit.signal_red
		_kit.box(boom, Vector3(0.25 + index * 0.53, 0, 0), Vector3(0.53, 0.1, 0.06), tone)
	if not raised:
		_kit.box(prop, Vector3(5.3, 0.45, 0.22), Vector3(0.08, 0.9, 0.08), _dark)
	# Flatten the boom into the prop, then the prop into the zone.
	for child in boom.get_children():
		var part := child as Node3D
		var placed := boom.transform * part.transform
		boom.remove_child(part)
		prop.add_child(part)
		part.transform = placed
	prop.remove_child(boom)
	boom.free()
	_commit(prop)


func _signal_white() -> StandardMaterial3D:
	return _white


func _intercom(at: Vector3, yaw: float) -> void:
	var prop := _prop(at, yaw)
	_kit.box(prop, Vector3(0, 0.7, 0), Vector3(0.14, 1.4, 0.14), _kit.stainless_dark)
	_kit.box(prop, Vector3(0, 1.45, 0.05), Vector3(0.3, 0.42, 0.2), _dark)
	_kit.box(prop, Vector3(0, 1.5, 0.16), Vector3(0.16, 0.12, 0.01), _kit.screen)
	_commit(prop)


# --- Lorries, trailers and docks -------------------------------------------------

func _lorry(at: Vector3, yaw: float, livery: int, tractor: int, coupled: bool) -> void:
	# An articulated lorry facing `yaw`: tractor unit (downloaded) and a 13.6 m box trailer.
	# Without a tractor the trailer stands on its landing legs. `at` is the trailer's front.
	var basis := Basis(Vector3.UP, yaw)
	if coupled:
		_model("tractor_unit", at + basis * Vector3(0, 0, 0.55), yaw, 1.0, TRACTOR_COLORS[tractor % TRACTOR_COLORS.size()])
	_trailer(at, yaw, HAULIERS[livery % HAULIERS.size()], not coupled)


func _trailer(front: Vector3, yaw: float, livery: Array, legs_down: bool) -> void:
	var prop := _prop(front, yaw)
	var length := TRAILER_LENGTH
	var body: Color = livery[0]
	var stripe: Color = livery[1]
	var mid := -length * 0.5
	_kit.box(prop, Vector3(0, 2.62, mid), Vector3(2.55, 2.75, length), _kit.ribbed(body))
	_kit.box(prop, Vector3(0, 4.02, mid), Vector3(2.57, 0.06, length + 0.02), _kit.paint(body.darkened(0.12)))
	for side: float in [-1.0, 1.0]:
		_kit.box(prop, Vector3(side * 1.285, 1.55, mid), Vector3(0.02, 0.22, length), _kit.paint(stripe))
		_kit.box(prop, Vector3(side * 1.285, 3.6, mid - 1.0), Vector3(0.02, 0.5, length * 0.55), _kit.paint(stripe))
		# Side under-run guard and chassis rails.
		_kit.box(prop, Vector3(side * 1.18, 0.75, -5.2), Vector3(0.05, 0.25, 6.4), _kit.stainless_dark)
		_kit.box(prop, Vector3(side * 0.5, 1.12, mid), Vector3(0.18, 0.3, length - 0.2), _dark)
	# Rear doors, lock bars, lights and bumper.
	var rear := -length
	_kit.box(prop, Vector3(0, 2.62, rear - 0.02), Vector3(2.5, 2.7, 0.04), _kit.paint(body.darkened(0.06)))
	for x: float in [-0.9, -0.35, 0.35, 0.9]:
		_kit.box(prop, Vector3(x, 2.6, rear - 0.06), Vector3(0.05, 2.6, 0.04), _kit.stainless_dark)
	_kit.box(prop, Vector3(0, 2.62, rear - 0.05), Vector3(0.02, 2.7, 0.04), _dark)
	for x: float in [-1.05, 1.05]:
		_kit.box(prop, Vector3(x, 1.0, rear - 0.05), Vector3(0.36, 0.14, 0.05), _kit.signal_red)
	_kit.box(prop, Vector3(0, 0.62, rear + 0.1), Vector3(2.3, 0.14, 0.12), _dark)
	# Three axles with twin-width tyres.
	for axle in 3:
		var z := rear + 1.3 + axle * 1.36
		for side: float in [-1.0, 1.0]:
			_kit.cylinder(prop, Vector3(side * 0.95, 0.5, z), 0.5, 0.56, _kit.rubber, Industrial.X, 18)
			_kit.cylinder(prop, Vector3(side * 1.24, 0.5, z), 0.24, 0.02, _kit.stainless_dark, Industrial.X, 12)
		_kit.box(prop, Vector3(0, 0.95, z), Vector3(2.0, 0.12, 0.16), _dark)
	# Landing legs: down to the ground on a parked trailer, lifted when coupled.
	for side: float in [-1.0, 1.0]:
		var foot := 0.08 if legs_down else 0.5
		var leg_height := 1.2 - foot
		_kit.box(prop, Vector3(side * 0.85, foot + leg_height * 0.5, -2.6), Vector3(0.14, leg_height, 0.14), _kit.paint(Color("#3a4046")))
		_kit.box(prop, Vector3(side * 0.85, foot - 0.03, -2.6), Vector3(0.32, 0.06, 0.32), _dark)
	_commit(prop)


func _docks(hall: Hall, warehouse: StringName, side: float) -> void:
	# Loading docks on the outside of the hall wall beside a warehouse that stands against it:
	# sectional doors with foam shelters on the wall, bumpers, a hazard-striped dock edge,
	# painted guide lines and lorries backed up to most of them. `side` is +1 for the east wall, -1 for the west.
	if not _layout.objects.has(warehouse) or hall == null:
		return
	var placement = _layout.objects[warehouse]
	var footprint: Rect2i = placement.footprint()
	var grid := _layout.grid
	var touches := footprint.end.x >= grid.size.x - 1 if side > 0.0 else footprint.position.x <= 1
	if not touches:
		return
	var wall := hall.wall_structure(Vector3(side, 0, 0))
	if wall == null:
		return
	# Doors sit midway between the wall columns (grid rows 3, 9, 15, …), 6 m apart.
	var line := (_east + 0.155) if side > 0.0 else (_west - 0.155)
	var wall_x := line + side * 0.155
	var rows: Array[int] = []
	for row in range(footprint.position.y + 3, footprint.end.y - 2):
		if row % 6 == 0:
			rows.append(row)
	if rows.is_empty():
		return
	var near := grid.to_world(Vector2(0, rows[0])).z
	var far := grid.to_world(Vector2(0, rows.back())).z
	var to_wall := (wall.get_parent() as Node3D).transform.affine_inverse()
	var apron := Rect2(minf(wall_x, wall_x + side * 20.0), minf(near, far) - 4.0, 20.0, absf(near - far) + 8.0)
	_slab(apron, ROAD_Y + 0.004, 0.2, _kit.concrete(Color("#9a9890")))
	for index in rows.size():
		var z := grid.to_world(Vector2(0, rows[index])).z
		# Door and foam shelter belong to the wall so they follow its cutaway. The wall faces
		# away from any camera that could see them, so they mostly show as shadow; the
		# warehouse room's own wall hides the inside of the hall wall.
		var parts: Array[MeshInstance3D] = []
		parts.append(_kit.box(_zone, Vector3(line + side * 0.16, 1.65, z), Vector3(0.04, 3.2, 3.0), _kit.ribbed(Color("#3f6f9f"))))
		parts.append(_kit.box(_zone, Vector3(wall_x + side * 0.35, 3.55, z), Vector3(0.6, 0.5, 3.6), _dark))
		for z_side: float in [-1.0, 1.0]:
			parts.append(_kit.box(_zone, Vector3(wall_x + side * 0.35, 1.75, z + z_side * 1.65), Vector3(0.6, 3.6, 0.3), _dark))
		parts.append(_kit.box(_zone, Vector3(wall_x + side * 0.12, 3.95, z + 2.0), Vector3(0.2, 0.18, 0.3), _kit.lens))
		for part in parts:
			var placed := to_wall * part.transform
			_zone.remove_child(part)
			wall.add_child(part)
			part.transform = placed
		# Bumpers and the hazard-striped dock edge stay visible below the cut-away wall.
		for z_side: float in [-1.0, 1.0]:
			_kit.box(_zone, Vector3(wall_x + side * 0.15, 1.0, z + z_side * 1.2), Vector3(0.3, 0.32, 0.25), _kit.rubber)
		_kit.box(_zone, Vector3(wall_x + side * 0.12, 0.25, z), Vector3(0.24, 0.5, 3.0), _kit.hazard)
		# Guide lines and the lorry.
		for z_side: float in [-1.0, 1.0]:
			_stripe(Vector3(wall_x + side * 1.0, ROAD_Y + 0.004, z + z_side * 1.9),
				Vector3(wall_x + side * 18.0, ROAD_Y + 0.004, z + z_side * 1.9), 0.15, _yellow)
		var number := Label3D.new()
		number.text = "%d" % (index + 1)
		number.font_size = 64
		number.pixel_size = 0.02
		number.outline_size = 0
		number.modulate = Color("#e8e9e4")
		number.position = Vector3(wall_x + side * 4.0, ROAD_Y + 0.02, z)
		number.rotation = Vector3(-PI * 0.5, side * PI * 0.5, 0)
		number.visibility_range_end = 80.0
		_zone.add_child(number)
		var slot := index + (0 if side > 0.0 else 3)
		if slot % 5 == 3:
			continue
		var front := Vector3(wall_x + side * (0.5 + TRAILER_LENGTH), ROAD_Y, z)
		var facing := PI * 0.5 * side
		if slot % 4 == 2 and side > 0.0:
			_trailer(front, facing, HAULIERS[slot % HAULIERS.size()], true)
		elif side < 0.0 and slot % 3 == 1:
			_model("box_truck", Vector3(wall_x + side * 5.6, ROAD_Y, z), facing, 1.0, Color("#eef0f0"))
		else:
			_lorry(front, facing, slot, slot + 1, true)
	_kit.batch(wall)


func _trailer_park() -> void:
	# Trailers waiting on their landing legs along the east fence, with a box truck and vans.
	var x := _site.end.x - 1.5
	var top := _rear - 4.0
	var bottom := _front + 8.0
	_slab(Rect2(_east + 27.0, top - 4.0, x + 1.0 - (_east + 27.0), bottom - top + 8.0), ROAD_Y + 0.002, 0.2, _asphalt)
	var z := top
	var index := 0
	while z < bottom:
		_stripe(Vector3(x - 15.5, ROAD_Y, z - 1.85), Vector3(x, ROAD_Y, z - 1.85), 0.12)
		if index % 4 != 3:
			if index % 5 == 2:
				_model("box_truck", Vector3(x - 6.0, ROAD_Y, z), -PI * 0.5, 1.0, Color("#1f4f8f"))
			else:
				_trailer(Vector3(x - 15.0, ROAD_Y, z), -PI * 0.5, HAULIERS[(index + 2) % HAULIERS.size()], true)
		z += 3.7
		index += 1
	# Vans along the front of the trailer park.
	for slot in 4:
		_model("van", Vector3(_east + 30.5 + slot * 3.0, ROAD_Y, bottom + 1.5), PI, 1.0, [Color("#eef0f0"), Color("#7a3b1f"), Color("#eef0f0"), Color("#b9bec2")][slot])


func _west_strip() -> void:
	# Between the west ring road and the fence: grass and a tree belt.
	var strip := Rect2(_site.position.x, _rear - 11.0, (_west - 27.0) - _site.position.x, (_front + 14.0) - (_rear - 11.0))
	_slab(strip, GRASS_Y + 0.03, 0.2, _lawn)
	var z := strip.position.y + 3.0
	while z < strip.end.y - 2.0:
		_tree(Vector2(strip.get_center().x + _random.randf_range(-1.0, 1.0), z), ["tree_pine", "tree_oak_b", "tree_birch_a"])
		z += _random.randf_range(8.0, 12.0)
	# Shrubs along the west wall towards the front corner.
	for index in 6:
		_model("bush", Vector3(_west - 4.0 - (index % 2) * 6.0, GRASS_Y, _front - 26.0 + index * 4.4), _random.randf() * TAU, 1.0)


func _rear_strip() -> void:
	# Behind the hall: grass between the apron and the rear road, a skip bay and a tree belt
	# along the rear fence.
	_slab(Rect2(_west - 20.0, _rear - 11.0, (_east + 20.0) - (_west - 20.0), 8.0), GRASS_Y + 0.03, 0.2, _lawn)
	var belt := Rect2(_site.position.x, _site.position.y, _site.size.x, (_rear - 18.0) - _site.position.y)
	_slab(belt, GRASS_Y + 0.03, 0.2, _lawn)
	var x := belt.position.x + 4.0
	while x < belt.end.x - 3.0:
		_tree(Vector2(x, belt.get_center().y + _random.randf_range(-1.0, 1.0)), ["tree_pine", "tree_oak_a", "tree_birch_b"])
		x += _random.randf_range(10.0, 15.0)
	# Skip bay: concrete pad, two open skips and a baled-cardboard stack.
	var pad := Rect2(_east - 30.0, _rear - 10.5, 14.0, 7.0)
	_slab(pad, PAVING_Y, 0.2, _kit.concrete(Color("#9a9890")))
	for index in 2:
		var at := Vector3(pad.position.x + 3.5 + index * 6.5, PAVING_Y, pad.get_center().y)
		var skip := _prop(at, 0.0)
		var tone := _kit.paint([Color("#2f6fb0"), Color("#3f8a52")][index])
		var load := _kit.concrete(Color("#9b7a55"))
		_kit.box(skip, Vector3(0, 0.05, 0), Vector3(3.6, 0.1, 1.8), tone)
		for side: float in [-1.0, 1.0]:
			var wall := _kit.box(skip, Vector3(side * 2.0, 0.75, 0), Vector3(0.1, 1.4, 1.8), tone)
			wall.rotation.z = side * -0.35
			_kit.box(skip, Vector3(0, 0.75, side * 0.9), Vector3(3.6, 1.4, 0.08), tone)
		_kit.box(skip, Vector3(0, 0.95, 0), Vector3(3.4, 0.9, 1.6), load)
		_commit(skip)


# --- Perimeter fence -------------------------------------------------------------

func _perimeter() -> void:
	# 2.4 m welded-mesh fence on posts every 3 m, with an opening for the main gate.
	var s := _site
	var gate_from := _east + 15.0
	var gate_to := _east + 32.0
	var corners := [s.position, Vector2(s.end.x, s.position.y), s.end, Vector2(s.position.x, s.end.y)]
	for index in 4:
		var a: Vector2 = corners[index]
		var b: Vector2 = corners[(index + 1) % 4]
		if index == 2:
			# Front run (east to west) with the gate gap.
			_fence_run(a, Vector2(gate_to, a.y))
			_fence_run(Vector2(gate_from, a.y), b)
		else:
			_fence_run(a, b)
	# A row of trees outside the fence along the front road and the sides, for a horizon.
	var x := s.position.x - 30.0
	while x < s.end.x + 30.0:
		_tree(Vector2(x, s.end.y + 18.0 + _random.randf_range(0.0, 3.0)), ["tree_oak_a", "tree_oak_b", "tree_pine"])
		x += _random.randf_range(11.0, 17.0)
	for z_index in 9:
		var z := s.position.y + 6.0 + z_index * s.size.y / 9.0
		_tree(Vector2(s.position.x - 8.0 - _random.randf_range(0.0, 6.0), z), ["tree_pine", "tree_birch_a"])
		_tree(Vector2(s.end.x + 8.0 + _random.randf_range(0.0, 6.0), z), ["tree_pine", "tree_oak_c"])


func _fence_run(a: Vector2, b: Vector2) -> void:
	var length := a.distance_to(b)
	if length < 0.5:
		return
	var direction := (b - a) / length
	var middle := (a + b) * 0.5
	var yaw := atan2(direction.x, direction.y)
	_piece(Vector3(middle.x, 1.25, middle.y), Vector3(0.02, 2.3, length), _fence_mesh, yaw)
	for height: float in [0.12, 2.4]:
		_piece(Vector3(middle.x, height, middle.y), Vector3(0.05, 0.06, length), _fence, yaw)
	var posts := maxi(1, int(length / 3.0))
	for index in posts + 1:
		var at := a + direction * (length * index / posts)
		_kit.box(_zone, Vector3(at.x, 1.2, at.y), Vector3(0.08, 2.5, 0.08), _fence)
