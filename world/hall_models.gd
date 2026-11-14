extends RefCounted
## The building around the production floor: hall lighting and haze, tall clad walls,
## an open truss roof with high-bay lamps, and warm light pools on the floor.
##
## Walls and roof use a Sims-style cutaway. A wall whose outer face is towards the
## camera keeps casting its shadow but is not drawn. Roof bays between the camera and
## the point it looks at are hidden, so the structure frames the far side of the hall
## without crossing the view. The lamps are emissive and the light pools are one
## additive mesh, so the hall adds no real lights. Everything here is visual.

const Industrial = preload("res://world/industrial_models.gd")
const Grid = preload("res://layout/factory_grid.gd")

const WALL_HEIGHT := 9.0
const TRUSS_DEPTH := 1.6
const TRUSS_SPACING := 12
const FIRST_TRUSS := 3
const BAY_LENGTH := 40.0
const LAMP_SPACING := 10.0
const LAMP_HEIGHT := 7.4
const POOL_SIZE := 8.5
const CUTAWAY_MARGIN := 6.0

const CLADDING := Color("#a7b2b8")
const DADO := Color("#5d6a72")
const STRUCTURE := Color("#6f7c85")
const GALVANIZED := Color("#8e979c")


class Wall:
	var solid: Node3D
	var glazing: Node3D
	var point: Vector3
	var outward: Vector3
	var shown := true

	func show(visible: bool) -> void:
		if visible == shown:
			return
		shown = visible
		glazing.visible = visible
		var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if visible \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		for child in solid.get_children():
			var piece := child as GeometryInstance3D
			if piece != null:
				piece.cast_shadow = mode


var _models: Industrial
var _walls: Array[Wall] = []
var _bays: Array[Node3D] = []
var _lamps: Array[Vector3] = []
var _last_pose := Transform3D()
var _has_pose := false
var _frame: StandardMaterial3D
var _steel: StandardMaterial3D
var _daylight: StandardMaterial3D
var _lens: StandardMaterial3D


func _init(models: Industrial) -> void:
	_models = models
	_frame = models.paint(Color("#3a4750"))
	_steel = models.paint(STRUCTURE)
	_daylight = StandardMaterial3D.new()
	_daylight.albedo_color = Color("#a9c3d3")
	_daylight.roughness = 0.12
	_daylight.metallic = 0.2
	_daylight.emission_enabled = true
	_daylight.emission = Color("#d3e6f2")
	_daylight.emission_energy_multiplier = 0.45
	_lens = StandardMaterial3D.new()
	_lens.albedo_color = Color("#fff4dc")
	_lens.emission_enabled = true
	_lens.emission = Color("#fff0d0")
	_lens.emission_energy_multiplier = 1.4


## Environment, haze and the directional light that stands in for daylight through the roof.
func light(parent: Node3D) -> void:
	var atmosphere := Environment.new()
	atmosphere.background_mode = Environment.BG_COLOR
	# Hazy sky matching the fog, so the grass fades into the horizon.
	atmosphere.background_color = Color("#a9b4ba")
	atmosphere.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	atmosphere.ambient_light_color = Color("#d3dde8")
	atmosphere.ambient_light_energy = 0.46
	# Distance haze: close-ups stay crisp, the far end of the hall softens.
	atmosphere.fog_enabled = true
	atmosphere.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	atmosphere.fog_light_color = Color("#a9b4ba")
	atmosphere.fog_light_energy = 1.0
	atmosphere.fog_sun_scatter = 0.12
	atmosphere.fog_density = 0.0032
	atmosphere.fog_sky_affect = 0.0
	var environment := WorldEnvironment.new()
	environment.environment = atmosphere
	parent.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -28, 0)
	sun.light_color = Color("#fff0da")
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_blur = 1.4
	sun.directional_shadow_max_distance = 133
	parent.add_child(sun)


## Builds walls, roof and floor light pools around a hall of grid.size cells.
## Wall base heights match the existing low perimeter walls (front, rear, sides).
func build(parent: Node3D, grid: Grid, layout: Variant) -> void:
	var width := float(grid.size.x)
	var length := float(grid.size.y)
	var front: Array[float] = []
	for x in range(0, grid.size.x + 1, 8):
		front.append(float(x))
	var side: Array[float] = []
	for z in range(3, grid.size.y, 6):
		side.append(float(z))
	_wall(parent, grid, layout, Vector2(-0.31, -0.155), Vector2(width + 0.31, -0.155), 1.18, front, false)
	_wall(parent, grid, layout, Vector2(-0.31, length + 0.155), Vector2(width + 0.31, length + 0.155), 1.79, front, false)
	_wall(parent, grid, layout, Vector2(-0.155, 0), Vector2(-0.155, length), 1.43, side, true)
	_wall(parent, grid, layout, Vector2(width + 0.155, 0), Vector2(width + 0.155, length), 1.43, side, true)
	var segments := maxi(1, roundi(width / BAY_LENGTH))
	var span := width / segments
	for z in range(FIRST_TRUSS, grid.size.y, TRUSS_SPACING):
		var rear := minf(TRUSS_SPACING, length - z) if z + TRUSS_SPACING <= grid.size.y else 0.0
		for index in segments:
			_bay(parent, grid.to_world(Vector2((index + 0.5) * span, z)), span, rear)
	_pools(parent)


## The node of the hall wall whose outside faces `outward` (a horizontal axis), or null.
## Parts added to it follow the wall's cutaway (shadows only while the wall is hidden).
## Its local frame: x along the wall, y up, +z out of the hall, origin at the wall's middle.
func wall_structure(outward: Vector3) -> Node3D:
	for wall in _walls:
		if wall.outward.dot(outward) > 0.9:
			return wall.solid
	return null


## Shows or hides walls and roof bays for the camera. Cheap; skips work when it has not moved.
func update_view(camera: Camera3D) -> void:
	if camera == null:
		return
	var pose := camera.global_transform
	if _has_pose and pose.is_equal_approx(_last_pose):
		return
	_has_pose = true
	_last_pose = pose
	var eye := pose.origin
	for wall in _walls:
		wall.show((eye - wall.point).dot(wall.outward) < 0.0)
	var forward := -pose.basis.z
	var focus := eye
	if forward.y < -0.05:
		focus = eye + forward * (-eye.y / forward.y)
	var toward := Vector2(eye.x - focus.x, eye.z - focus.z)
	var overhead := toward.length() < 1.0
	toward = toward.normalized()
	for bay in _bays:
		var offset := Vector2(bay.position.x - focus.x, bay.position.z - focus.z)
		bay.visible = not overhead and offset.dot(toward) < -CUTAWAY_MARGIN


# --- Walls -----------------------------------------------------------------------

func _wall(
	parent: Node3D, grid: Grid, layout: Variant, start: Vector2, end: Vector2, base: float,
	columns: Array[float], along_z: bool
) -> void:
	var a := grid.to_world(start)
	var b := grid.to_world(end)
	var middle := (a + b) * 0.5
	var hall_center := grid.to_world(Vector2(grid.size) * 0.5)
	var outward := Vector3((b - a).z, 0, -(b - a).x).normalized()
	if outward.dot(middle - hall_center) < 0.0:
		outward = -outward
	var direction := Vector3.UP.cross(outward)
	var node := Node3D.new()
	node.name = "HallWall"
	node.transform = Transform3D(Basis(direction, Vector3.UP, outward), middle)
	parent.add_child(node)
	var wall := Wall.new()
	wall.point = middle
	wall.outward = outward
	wall.solid = _group(node, "Structure")
	wall.glazing = _group(node, "Clerestory")
	_walls.append(wall)
	var solid := wall.solid
	var span := a.distance_to(b)
	var h := WALL_HEIGHT
	var to_local := node.transform.affine_inverse()

	# Two-tone profiled cladding with a ribbon of clerestory glazing.
	var panel := _models.ribbed(CLADDING)
	_box(solid, Vector3(0, (base + 3.2) * 0.5, 0.05), Vector3(span, 3.2 - base, 0.16), _models.ribbed(DADO))
	_box(solid, Vector3(0, 4.8, 0.05), Vector3(span, 3.2, 0.16), panel)
	_box(solid, Vector3(0, (7.9 + h) * 0.5, 0.05), Vector3(span, h - 7.9, 0.16), panel)
	var glass := _box(wall.glazing, Vector3(0, 7.15, 0.05), Vector3(span, 1.5, 0.06), _daylight)
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for y: float in [6.4, 7.9]:
		_box(solid, Vector3(0, y, 0.0), Vector3(span, 0.12, 0.26), _frame)
	for index in range(1, floori(span / 2.5)):
		_box(solid, Vector3(-span * 0.5 + index * 2.5, 7.15, 0.0), Vector3(0.09, 1.5, 0.2), _frame)
	_box(solid, Vector3(0, h - 0.25, -0.1), Vector3(span, 0.5, 0.36), _frame)

	# Columns, with cable tray and extinguisher stations where the floor is open.
	var stations: Array[float] = []
	for coordinate in columns:
		var at := grid.to_world(Vector2(start.x, coordinate) if along_z else Vector2(coordinate, start.y))
		stations.append((to_local * at).x)
	stations.sort()
	for index in stations.size():
		var x := stations[index]
		_box(solid, Vector3(x, h * 0.5, -0.33), Vector3(0.05, h, 0.36), _frame)
		for z: float in [-0.15, -0.51]:
			_box(solid, Vector3(x, h * 0.5, z), Vector3(0.38, h, 0.05), _frame)
		if _open(grid, layout, node, x, -1.2) and index % 2 == 0:
			_box(solid, Vector3(x, 2.0, -0.54), Vector3(0.26, 0.26, 0.012), _models.signal_red)
			_cylinder(solid, Vector3(x, 0.95, -0.66), 0.09, 0.55, _models.signal_red)
			_box(solid, Vector3(x, 1.27, -0.66), Vector3(0.05, 0.1, 0.05), _frame)
		if index + 1 < stations.size():
			var next := stations[index + 1]
			var middle_x := (x + next) * 0.5
			if not _open(grid, layout, node, middle_x, -1.2):
				continue
			var run := next - x - 0.4
			var tray := _models.paint(GALVANIZED)
			_box(solid, Vector3(middle_x, 5.4, -0.72), Vector3(run, 0.04, 0.4), tray)
			for z: float in [-0.52, -0.92]:
				_box(solid, Vector3(middle_x, 5.46, z), Vector3(run, 0.12, 0.03), tray)
			if along_z and index % 4 == 1:
				# Wall extract fan between columns.
				_cylinder(solid, Vector3(middle_x, 4.3, -0.04), 0.52, 0.22, _frame, true)
				_cylinder(solid, Vector3(middle_x, 4.3, -0.16), 0.46, 0.03, _models.vent, true)
	_pipe_runs(solid, grid, layout, node, stations, along_z)
	_finish(solid)
	_finish(wall.glazing)


func _pipe_runs(solid: Node3D, grid: Grid, layout: Variant, node: Node3D, stations: Array[float], _along_z: bool) -> void:
	# Service pipes on wall brackets: compressed air (blue), cooling water (green) and an
	# insulated hot-water line. Runs stop where a room or machine stands against the wall;
	# there they elbow into the wall. Some bays drop a branch to a valve station.
	var air := _models.paint(Color("#2f6fb0"))
	var water := _models.paint(Color("#3f8a52"))
	var lines := [[4.3, 0.065, air], [4.6, 0.085, water], [4.95, 0.14, _models.cladding]]
	var depth := -0.82
	var open: Array[bool] = []
	for index in range(stations.size() - 1):
		open.append(_open(grid, layout, node, (stations[index] + stations[index + 1]) * 0.5, -1.2))
	for index in open.size():
		if not open[index]:
			continue
		var a := stations[index]
		var b := stations[index + 1]
		for line: Array in lines:
			var y: float = line[0]
			var radius: float = line[1]
			_models.pipe(solid, Vector3(a, y, depth), Vector3(b, y, depth), radius, line[2])
			for end_index in [index, index + 1]:
				var neighbour: int = end_index - 1 if end_index == index else end_index
				var at: float = a if end_index == index else b
				if neighbour < 0 or neighbour >= open.size() or not open[neighbour]:
					_models.joint(solid, Vector3(at, y, depth), radius * 1.15, line[2])
					_models.pipe(solid, Vector3(at, y, depth), Vector3(at, y, -0.06), radius, line[2])
					_box(solid, Vector3(at, y, -0.1), Vector3(radius * 3.2, radius * 3.2, 0.03), _frame)
		# Insulation bands and bracket at the column.
		for band in range(1, floori((b - a) / 1.2)):
			_models.cylinder(solid, Vector3(a + band * 1.2, 4.95, depth), 0.15, 0.05, _models.stainless_dark, Industrial.X, 16)
		_box(solid, Vector3(a, 4.18, depth + 0.12), Vector3(0.07, 0.07, 0.62), _frame)
		_box(solid, Vector3(a, 4.62, -0.55), Vector3(0.07, 0.95, 0.07), _frame)
		if index % 3 == 1:
			# Branch drop: air to a filter-regulator and a ball valve; water to a hose valve.
			var x := (a + b) * 0.5
			_models.joint(solid, Vector3(x, 4.3, depth), 0.06, air)
			_models.pipe(solid, Vector3(x, 4.3, depth), Vector3(x, 1.55, depth), 0.03, air)
			_box(solid, Vector3(x, 1.4, depth), Vector3(0.14, 0.26, 0.12), _models.stainless_dark)
			_models.cylinder(solid, Vector3(x, 1.22, depth), 0.04, 0.14, _models.glass, Industrial.Y, 12)
			_box(solid, Vector3(x + 0.12, 1.75, depth), Vector3(0.16, 0.03, 0.03), _models.signal_red)
			_models.cylinder(solid, Vector3(x, 1.62, depth - 0.06), 0.05, 0.02, _models.gauge, Industrial.Z, 14)
			_models.joint(solid, Vector3(x + 0.5, 4.58, depth), 0.075, water)
			_models.pipe(solid, Vector3(x + 0.5, 4.58, depth), Vector3(x + 0.5, 1.0, depth), 0.04, water)
			_models.cylinder(solid, Vector3(x + 0.5, 1.05, depth - 0.08), 0.08, 0.03, _models.signal_red, Industrial.Z, 14)
			_box(solid, Vector3(x + 0.5, 3.2, depth + 0.02), Vector3(0.08, 0.06, 0.12), _frame)


func _open(grid: Grid, layout: Variant, node: Node3D, x: float, inset: float) -> bool:
	# True when the floor just inside the wall at local x is not occupied by a room or machine.
	if layout == null:
		return true
	var cell := Vector2i(grid.coordinates(node.transform * Vector3(x, 0, inset)).floor())
	for id in layout.objects:
		if layout.objects[id].footprint().has_point(cell):
			return false
	return true


# --- Roof ------------------------------------------------------------------------

func _bay(parent: Node3D, center: Vector3, span: float, rear: float) -> void:
	# One truss segment, the purlins behind it and the lamps they carry.
	var bay := Node3D.new()
	bay.name = "RoofBay"
	bay.position = center
	parent.add_child(bay)
	_bays.append(bay)
	var bottom := WALL_HEIGHT
	var top := WALL_HEIGHT + TRUSS_DEPTH
	_box(bay, Vector3(0, bottom, 0), Vector3(span, 0.16, 0.2), _steel)
	_box(bay, Vector3(0, top, 0), Vector3(span, 0.2, 0.24), _steel)
	var panels := maxi(1, roundi(span / 2.0))
	var pitch := span / panels
	var slope := atan2(TRUSS_DEPTH, pitch)
	var brace := sqrt(pitch * pitch + TRUSS_DEPTH * TRUSS_DEPTH)
	for index in panels + 1:
		_box(bay, Vector3(-span * 0.5 + index * pitch, (bottom + top) * 0.5, 0),
			Vector3(0.09, TRUSS_DEPTH, 0.12), _steel)
	for index in panels:
		var diagonal := _box(bay, Vector3(-span * 0.5 + (index + 0.5) * pitch, (bottom + top) * 0.5, 0),
			Vector3(brace, 0.08, 0.1), _steel)
		diagonal.rotation.z = slope if index % 2 == 0 else -slope
	if rear > 0.0:
		for index in roundi(span / 4.0):
			_box(bay, Vector3(-span * 0.5 + 2.0 + index * 4.0, top + 0.21, -rear * 0.5),
				Vector3(0.12, 0.22, rear), _steel)
		for index in roundi(span / LAMP_SPACING):
			var lamp := Vector3(-span * 0.5 + (index + 0.5) * LAMP_SPACING, LAMP_HEIGHT, -rear * 0.5)
			_cylinder(bay, Vector3(lamp.x, (top + lamp.y) * 0.5, lamp.z), 0.015, top - lamp.y, _steel)
			_cylinder(bay, lamp + Vector3(0, 0.16, 0), 0.38, 0.32, _steel, false, 0.14)
			_cylinder(bay, lamp - Vector3(0, 0.01, 0), 0.34, 0.03, _lens)
			_lamps.append(center + Vector3(lamp.x, 0, lamp.z))
	_finish(bay)
	for child in bay.get_children():
		var piece := child as GeometryInstance3D
		if piece != null:
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _pools(parent: Node3D) -> void:
	# Warm light under each lamp, drawn as one additive mesh instead of real lights.
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow.albedo_color = Color(1.0, 0.86, 0.62, 0.075)
	glow.albedo_texture = _falloff()
	var pools := _group(parent, "LightPools")
	for lamp in _lamps:
		var quad := PlaneMesh.new()
		quad.size = Vector2(POOL_SIZE, POOL_SIZE)
		_add(pools, lamp + Vector3(0, 0.02, 0), quad, glow)
	_finish(pools)
	for child in pools.get_children():
		(child as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _falloff() -> ImageTexture:
	var image := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var distance := Vector2(x - 31.5, y - 31.5).length() / 31.5
			var strength := pow(clampf(1.0 - distance, 0.0, 1.0), 1.8)
			image.set_pixel(x, y, Color(1, 1, 1, strength))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


# --- Helpers ---------------------------------------------------------------------

func _group(parent: Node3D, title: String) -> Node3D:
	var node := Node3D.new()
	node.name = title
	parent.add_child(node)
	return node


func _add(parent: Node3D, at: Vector3, mesh: Mesh, surface: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.position = at
	instance.mesh = mesh
	instance.material_override = surface
	parent.add_child(instance)
	return instance


func _box(parent: Node3D, at: Vector3, size: Vector3, surface: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _add(parent, at, mesh, surface)


func _cylinder(
	parent: Node3D, at: Vector3, radius: float, height: float, surface: Material,
	along_z: bool = false, top_radius: float = -1.0
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if top_radius < 0.0 else top_radius
	mesh.height = height
	mesh.radial_segments = 14
	mesh.rings = 0
	var instance := _add(parent, at, mesh, surface)
	if along_z:
		instance.rotation.x = PI * 0.5
	return instance


func _finish(node: Node3D) -> void:
	_models.batch(node)
