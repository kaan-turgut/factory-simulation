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
	## Cartons are one MultiMesh: one draw call per pallet, the shown count is the
	## visible instance count and the product's printed board is the material.
	var root := Node3D.new()
	var cartons := MultiMeshInstance3D.new()
	var stock
	var shown := -1
	var product := "?"

	func refresh(pallet: Pallet, show_empty: bool = false) -> void:
		root.visible = show_empty or pallet != null
		var count := 0
		if pallet != null:
			var displayed := mini(pallet.target_boxes, cartons.multimesh.instance_count)
			count = ceili(float(pallet.boxes) * displayed / pallet.target_boxes)
		var key := "" if pallet == null else "%s|%s" % [pallet.sku, pallet.tint]
		if product != key:
			product = key
			cartons.material_override = stock.printed_board(pallet.sku if pallet != null else "",
				pallet.tint if pallet != null else "")
		if shown != count:
			shown = count
			cartons.multimesh.visible_instance_count = count
			cartons.visible = count > 0


var _draw: Primitives
var _wood: Dictionary[Color, StandardMaterial3D] = {}
var _board: Dictionary[Color, StandardMaterial3D] = {}
var _wafer: Dictionary[Color, StandardMaterial3D] = {}
var _grain: ImageTexture
var _flutes: ImageTexture
var _sack_mesh: ArrayMesh
var _sack_surface: StandardMaterial3D
var _waffle: ImageTexture
var _tape: StandardMaterial3D
var _printed: Dictionary[String, StandardMaterial3D] = {}
var _carton_mesh: ArrayMesh


func _init(draw: Primitives) -> void:
	_draw = draw
	_build_textures()
	_tape = StandardMaterial3D.new()
	_tape.albedo_color = Color("#c9a874")
	_tape.roughness = 0.35


## Kiln-dried pallet timber with grain, shared by shade.
func wood(color: Color) -> StandardMaterial3D:
	if not _wood.has(color):
		_wood[color] = _textured(color, _grain, 0.85, 2.0)
	return _wood[color]


## Corrugated board with faint flutes, shared by tint (product cartons are tinted).
func cardboard(color: Color) -> StandardMaterial3D:
	if not _board.has(color):
		_board[color] = _textured(color, _flutes, 0.9, 3.0)
	return _board[color]


## Board surface for instanced rack loads: each instance colour tints the flutes.
func instanced_board() -> StandardMaterial3D:
	var surface := _textured(Color.WHITE, _flutes, 0.9, 3.0)
	surface.vertex_color_use_as_albedo = true
	return surface


## The shared sack mesh and a tintable copy of its woven surface, for instanced stacks.
func instanced_sack() -> Array:
	if _sack_mesh == null:
		_build_sack()
	var surface: StandardMaterial3D = _sack_surface.duplicate()
	surface.vertex_color_use_as_albedo = true
	return [_sack_mesh, surface]


func _wafer_sheet(color: Color) -> StandardMaterial3D:
	if not _wafer.has(color):
		_wafer[color] = _textured(color, _waffle, 0.8, 9.0)
	return _wafer[color]


func _textured(color: Color, texture: Texture2D, roughness: float, scale: float) -> StandardMaterial3D:
	var surface := StandardMaterial3D.new()
	surface.albedo_color = color
	surface.albedo_texture = texture
	surface.roughness = roughness
	surface.uv1_triplanar = true
	surface.uv1_triplanar_sharpness = 4.0
	surface.uv1_scale = Vector3.ONE * scale
	surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return surface


func _build_textures() -> void:
	# Small generated tiles; values near 1 so the material colour stays in charge.
	var noise := FastNoiseLite.new()
	noise.seed = 71
	noise.frequency = 0.09
	var streaks := noise.get_seamless_image(64, 8)
	var grain := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var value := streaks.get_pixel(x, y % 8).r
			var ring := 0.5 + 0.5 * sin(y * 0.55 + value * 6.0)
			var shade := lerpf(0.78, 1.0, ring * 0.6 + value * 0.4)
			grain.set_pixel(x, y, Color(shade, shade, shade))
	_grain = _tile(grain)
	var flutes := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		var shade := 0.93 + 0.07 * sin(y * TAU / 4.0)
		for x in 32:
			flutes.set_pixel(x, y, Color(shade, shade * 0.99, shade * 0.97))
	_flutes = _tile(flutes)
	var waffle := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	waffle.fill(Color(1, 1, 1))
	for i in 16:
		for j in [0, 1, 8, 9]:
			waffle.set_pixel(i, j, Color(0.72, 0.68, 0.64))
			waffle.set_pixel(j, i, Color(0.72, 0.68, 0.64))
	_waffle = _tile(waffle)


func _tile(image: Image) -> ImageTexture:
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func sack(parent: Node3D, at: Vector3, scale_factor: float = 1.0) -> Node3D:
	# 25 kg woven sack lying flat. One shared mesh and material, so stacks merge cheaply.
	var bag := Node3D.new()
	bag.position = at
	bag.scale = Vector3.ONE * scale_factor
	parent.add_child(bag)
	if _sack_mesh == null:
		_build_sack()
	var body := MeshInstance3D.new()
	body.mesh = _sack_mesh
	body.material_override = _sack_surface
	bag.add_child(body)
	return bag


## Filled sack: a slumped pillow whose thickness falls to the stitched seams at both
## ends, with pinched corners, a slightly flatter underside and a short seam flange.
func _build_sack() -> void:
	const LENGTH := 1.0
	const WIDTH := 0.6
	const THICK := 0.34
	const FLANGE := 0.025
	const COLUMNS := 14
	const ROWS := 9
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_smooth_group(0)
	for face: float in [1.0, -1.0]:
		var grid: Array[Vector3] = []
		var uvs: Array[Vector2] = []
		for row in ROWS + 1:
			var v := lerpf(-1.0, 1.0, float(row) / ROWS)
			for column in COLUMNS + 1:
				var u := lerpf(-1.0, 1.0, float(column) / COLUMNS)
				# Fuller in the middle, pinched to the seam at the ends, rounded at the sides.
				var fill := pow(maxf(0.0, 1.0 - pow(absf(u), 4.0)), 0.55) \
					* pow(maxf(0.0, 1.0 - pow(absf(v), 2.6)), 0.5)
				var slump := 1.0 - 0.1 * (1.0 - u * u) * (1.0 - v * v)
				var height := THICK * 0.5 * fill * slump * (1.0 if face > 0.0 else 0.82)
				var x := u * LENGTH * 0.5 * (1.0 - 0.07 * v * v)
				var z := v * WIDTH * 0.5 * (1.0 - 0.1 * pow(absf(u), 6.0))
				grid.append(Vector3(x, height * face, z))
				uvs.append(Vector2((u + 1.0) * 0.5, (v + 1.0) * 0.25 + (0.0 if face > 0.0 else 0.5)))
		for row in ROWS:
			for column in COLUMNS:
				var a := row * (COLUMNS + 1) + column
				var quad := [a, a + 1, a + COLUMNS + 2, a + COLUMNS + 1]
				var order := [0, 1, 2, 0, 2, 3] if face > 0.0 else [0, 2, 1, 0, 3, 2]
				for index in order:
					tool.set_uv(uvs[quad[index]])
					tool.add_vertex(grid[quad[index]])
	# Stitched seam flanges at both ends, visible from above and below.
	tool.set_smooth_group(1)
	for end: float in [-1.0, 1.0]:
		for face: float in [1.0, -1.0]:
			var inner := end * LENGTH * 0.5
			var outer := end * (LENGTH * 0.5 + FLANGE)
			var y := 0.004 * face
			var corners := [Vector3(inner, y, -WIDTH * 0.36), Vector3(outer, y, -WIDTH * 0.34),
				Vector3(outer, y, WIDTH * 0.34), Vector3(inner, y, WIDTH * 0.36)]
			var order := [0, 1, 2, 0, 2, 3] if (end * face) > 0.0 else [0, 2, 1, 0, 3, 2]
			for index in order:
				tool.set_uv(Vector2(0.985, 0.985))
				tool.add_vertex(corners[index])
	tool.generate_normals()
	_sack_mesh = tool.commit()
	_sack_mesh.set_meta("mergeable", true)
	_sack_surface = StandardMaterial3D.new()
	_sack_surface.albedo_texture = _sack_texture()
	_sack_surface.roughness = 0.92
	_sack_surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


func _sack_texture() -> ImageTexture:
	# Top half of the image is the printed face, bottom half the plain back.
	const W := 256
	const H := 256
	var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 5
	noise.frequency = 0.035
	var base := Color("#d6c8a6")
	for y in H:
		for x in W:
			# Fine woven tape: alternating warp and weft every 2 px, plus faint soiling.
			var weave := 0.035 if ((x >> 1) + (y >> 1)) % 2 == 0 else -0.035
			var soil := (noise.get_noise_2d(x, y) + 1.0) * 0.5
			var shade := 1.0 + weave - soil * 0.08
			var edge := minf(minf(x, W - 1 - x) / 10.0, 1.0)
			shade -= (1.0 - edge) * 0.12
			image.set_pixel(x, y, Color(base.r * shade, base.g * shade, base.b * shade))
	# Printed panel on the face: coloured bands, a product block and text lines.
	var ink := Color("#a23a2c")
	var navy := Color("#22406b")
	image.fill_rect(Rect2i(70, 20, 116, 6), ink)
	image.fill_rect(Rect2i(70, 102, 116, 6), ink)
	image.fill_rect(Rect2i(88, 36, 80, 22), navy)
	for line in 3:
		image.fill_rect(Rect2i(92 + line * 4, 66 + line * 9, 72 - line * 8, 4), navy.lightened(0.15))
	image.fill_rect(Rect2i(150, 88, 22, 8), Color("#1d1d1d"))
	# Stitch lines near both ends.
	for y in range(0, H, 6):
		for x in [6, W - 7]:
			image.fill_rect(Rect2i(x, y, 2, 3), Color("#9a8a66"))
	# Swatch used by the seam flanges: folded, stitched edge.
	image.fill_rect(Rect2i(W - 8, H - 8, 8, 8), Color("#a99a76"))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func wafer(parent: Node3D, at: Vector3, color: Color, size: Vector3) -> Node3D:
	var stack := Node3D.new()
	stack.position = at
	parent.add_child(stack)
	_draw.box(stack, Vector3(0, size.y * 0.5, 0), size, color).material_override = _wafer_sheet(color)
	# Sheet edges on the long sides show the layered stack.
	for index in 3:
		var y := size.y * (0.25 + index * 0.25)
		for z: float in [-0.5, 0.5]:
			_draw.box(stack, Vector3(0, y, z * (size.z + 0.004)), Vector3(size.x * 0.98, 0.006, 0.004), color.darkened(0.3))
	return stack


func carton(parent: Node3D, at: Vector3, size: Vector3) -> MeshInstance3D:
	# Regular slotted carton: tape over the centre seam and a shipping label.
	var box := _draw.box(parent, at, size, CARTON)
	box.material_override = cardboard(CARTON)
	var tape := _draw.box(box, Vector3(0, size.y * 0.5 + 0.003, 0), Vector3(0.06, 0.006, size.z + 0.004), CARTON)
	tape.material_override = _tape
	_draw.box(box, Vector3(0, size.y * 0.5 + 0.002, 0), Vector3(size.x - 0.01, 0.002, 0.004), CARTON.darkened(0.3))
	_draw.box(box, Vector3(size.x * 0.19, 0, size.z * 0.5 + 0.004),
		Vector3(size.x * 0.32, size.y * 0.4, 0.006), PAPER)
	_draw.box(box, Vector3(size.x * 0.19, -size.y * 0.07, size.z * 0.5 + 0.008),
		Vector3(size.x * 0.22, size.y * 0.08, 0.002), Color("#2a2a2a"))
	return box


## Block pallet: bottom boards, nine blocks, stringer boards and a slatted top deck.
func pallet_deck(parent: Node3D, at: Vector3, size: Vector2, height: float = 0.144) -> void:
	var board := height * 0.15
	var block := height - board * 3.0
	var light := wood(WOOD)
	var dark := wood(WOOD.darkened(0.2))
	for z: float in [-0.5, 0.0, 0.5]:
		var row := Vector3(at.x, at.y + board * 0.5, at.z + z * (size.y - 0.1))
		_draw.box(parent, row, Vector3(size.x, board, 0.1), WOOD).material_override = light
		for x: float in [-0.5, 0.0, 0.5]:
			var post := _draw.box(parent, row + Vector3(x * (size.x - 0.14), board * 0.5 + block * 0.5, 0),
				Vector3(0.14, block, 0.1), WOOD)
			post.material_override = dark
		_draw.box(parent, row + Vector3(0, board + block, 0), Vector3(size.x, board, 0.1), WOOD).material_override = light
	var slats := 7
	for index in slats:
		var x := at.x - size.x * 0.5 + 0.055 + index * (size.x - 0.11) / (slats - 1)
		_draw.box(parent, Vector3(x, at.y + height - board * 0.5, at.z), Vector3(0.11, board, size.y), WOOD).material_override = light


const CARTON_SIZE := Vector3(0.74, 0.34, 0.55)
const CARTON_ART := "res://assets/cartons/%s.png"
## Atlas regions in assets/cartons/*.png (1024 x 768), kept in step with
## tools/cartons/build_cartons.py: long sides, short ends, top flaps, underside.
const ART_FRONT := Rect2(0.0 / 1024, 0.0 / 768, 1024.0 / 1024, 472.0 / 768)
const ART_END := Rect2(0.0 / 1024, 476.0 / 768, 472.0 / 1024, 292.0 / 768)
const ART_TOP := Rect2(480.0 / 1024, 476.0 / 768, 392.0 / 1024, 292.0 / 768)
const ART_BASE := Rect2(884.0 / 1024, 480.0 / 768, 136.0 / 1024, 284.0 / 768)


func pallet(parent: Node3D, at: Vector3) -> PalletView:
	var view := PalletView.new()
	view.stock = self
	view.root.position = at
	parent.add_child(view.root)
	pallet_deck(view.root, Vector3.ZERO, Vector2(1.69, 1.36), 0.23)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = carton_mesh()
	multi.instance_count = 12
	var index := 0
	for level in 3:
		for z in 2:
			for x in 2:
				multi.set_instance_transform(index, Transform3D(Basis.IDENTITY,
					Vector3(-0.385 + x * 0.77, 0.40 + level * 0.36, -0.30 + z * 0.60)))
				index += 1
	view.cartons.multimesh = multi
	view.cartons.name = "Cartons"
	view.root.add_child(view.cartons)
	_draw.batch_static(view.root)
	view.refresh(null)
	return view


## Shipping carton with its print mapped from the product atlas: both long sides show
## the brand panel, both ends the flavour panel, the top the taped flaps.
func carton_mesh() -> ArrayMesh:
	if _carton_mesh != null:
		return _carton_mesh
	var h := CARTON_SIZE * 0.5
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Each face: centre normal, right and up axes (as seen from outside), half extents, atlas rect.
	var faces := [
		[Vector3.BACK, Vector3.RIGHT, Vector3.UP, Vector2(h.x, h.y), ART_FRONT],
		[Vector3.FORWARD, Vector3.LEFT, Vector3.UP, Vector2(h.x, h.y), ART_FRONT],
		[Vector3.RIGHT, Vector3.FORWARD, Vector3.UP, Vector2(h.z, h.y), ART_END],
		[Vector3.LEFT, Vector3.BACK, Vector3.UP, Vector2(h.z, h.y), ART_END],
		[Vector3.UP, Vector3.RIGHT, Vector3.FORWARD, Vector2(h.x, h.z), ART_TOP],
		[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, Vector2(h.x, h.z), ART_BASE],
	]
	for face in faces:
		var normal: Vector3 = face[0]
		var right: Vector3 = face[1]
		var up: Vector3 = face[2]
		var half: Vector2 = face[3]
		var art: Rect2 = face[4]
		var center := normal * h
		var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
		var points: Array[Vector3] = []
		var uvs: Array[Vector2] = []
		for corner: Vector2 in corners:
			points.append(center + right * corner.x * half.x + up * corner.y * half.y)
			uvs.append(art.position + art.size * Vector2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5))
		for i in [0, 2, 1, 0, 3, 2]:
			tool.set_normal(normal)
			tool.set_uv(uvs[i])
			tool.add_vertex(points[i])
	tool.generate_tangents()
	_carton_mesh = tool.commit()
	return _carton_mesh


## Printed board for a product's cartons, shared by every pallet of it. Products without
## artwork (and sandbox pallets) get plain kraft board with a label, tinted by package colour.
func printed_board(sku: String, tint: String) -> StandardMaterial3D:
	var key := "%s|%s" % [sku, tint]
	if _printed.has(key):
		return _printed[key]
	var path := CARTON_ART % sku
	var art := not sku.is_empty() and ResourceLoader.exists(path)
	var surface := StandardMaterial3D.new()
	surface.albedo_texture = load(path if art else CARTON_ART % "generic")
	if not art and not tint.is_empty():
		surface.albedo_color = Color(tint).lightened(0.35)
	surface.roughness = 0.88
	surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_printed[key] = surface
	return surface
