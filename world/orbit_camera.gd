extends Camera3D
## Orbits a floor-level focus, with screen-relative keyboard and mouse panning.

signal floor_clicked(position: Vector2)

const MIN_DISTANCE := 12.0
const MAX_DISTANCE := 105.0
const HOME_DISTANCE := 69.0
const HOME_YAW := 0.11
const HOME_PITCH := 0.88
const INSPECTOR_SHIFT := 148.0

var _target_focus := Vector3(0.0, 0.2, 0.0)
var _home_focus := _target_focus
var _home_distance := HOME_DISTANCE
var _max_distance := MAX_DISTANCE
var _pan_extent := Vector2(42.0, 24.0)
var _focus := _target_focus
var _target_yaw := HOME_YAW
var _yaw := HOME_YAW
var _target_pitch := HOME_PITCH
var _pitch := HOME_PITCH
var _target_distance := HOME_DISTANCE
var _distance := HOME_DISTANCE
var _layout_zoom := 1.0
var _inspector_open := false
var _rotating := false
var _panning := false


func _ready() -> void:
	_update_transform()


func _process(delta: float) -> void:
	if not get_window().has_focus():
		_rotating = false
		_panning = false
	var edit := get_viewport().gui_get_focus_owner() as LineEdit
	if edit == null or not edit.is_editing():
		_keyboard_pan(delta)
	var layout_zoom := 1.18 if _inspector_open else 1.0
	var shift := INSPECTOR_SHIFT if _inspector_open else 0.0
	if _focus.is_equal_approx(_target_focus) and is_equal_approx(_yaw, _target_yaw) \
			and is_equal_approx(_pitch, _target_pitch) and is_equal_approx(_distance, _target_distance) \
			and is_equal_approx(_layout_zoom, layout_zoom) \
			and is_equal_approx(h_offset, _units_per_pixel() * shift):
		return
	var weight := 1.0 - exp(-12.0 * delta)
	_focus = _focus.lerp(_target_focus, weight)
	_yaw = lerpf(_yaw, _target_yaw, weight)
	_pitch = lerpf(_pitch, _target_pitch, weight)
	_distance = lerpf(_distance, _target_distance, weight)
	_layout_zoom = lerpf(_layout_zoom, layout_zoom, weight)
	h_offset = lerpf(h_offset, _units_per_pixel() * shift, weight)
	_update_transform()


func set_inspector_open(open: bool) -> void:
	_inspector_open = open


func fit_factory(center: Vector3, cells: Vector2i) -> void:
	_home_focus = center + Vector3(0, 0.2, 0)
	_home_distance = HOME_DISTANCE * maxf(cells.x / 64.0, cells.y / 26.0)
	_max_distance = maxf(MAX_DISTANCE, _home_distance * 1.52)
	_pan_extent = Vector2(cells) * 0.5 + Vector2(10.0, 11.0)
	far = maxf(180.0, _max_distance * 1.5)
	home()
	_focus = _target_focus
	_distance = _target_distance
	_update_transform()


func home() -> void:
	_target_focus = _home_focus
	_target_yaw = _yaw + wrapf(HOME_YAW - _yaw, -PI, PI)
	_target_pitch = HOME_PITCH
	_target_distance = _home_distance


func _update_transform() -> void:
	var direction := Vector3(
		sin(_yaw) * cos(_pitch),
		sin(_pitch),
		cos(_yaw) * cos(_pitch)
	)
	position = _focus + direction * _distance * _layout_zoom
	look_at(_focus)


func _keyboard_pan(delta: float) -> void:
	var direction := Vector2.ZERO
	direction.x = float(_key(KEY_D, KEY_RIGHT)) - float(_key(KEY_A, KEY_LEFT))
	direction.y = float(_key(KEY_S, KEY_DOWN)) - float(_key(KEY_W, KEY_UP))
	if direction != Vector2.ZERO:
		_pan(direction.normalized() * delta * 420.0)


func _key(first: Key, second: Key) -> bool:
	return Input.is_physical_key_pressed(first) or Input.is_key_pressed(second)


func _pan(screen_delta: Vector2) -> void:
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var toward_camera := Vector3(sin(_yaw), 0.0, cos(_yaw))
	_target_focus += (right * screen_delta.x + toward_camera * screen_delta.y) * _units_per_pixel()
	_target_focus.x = clampf(_target_focus.x, _home_focus.x - _pan_extent.x, _home_focus.x + _pan_extent.x)
	_target_focus.z = clampf(_target_focus.z, _home_focus.z - _pan_extent.y, _home_focus.z + _pan_extent.y)


func _units_per_pixel() -> float:
	var height := get_viewport().get_visible_rect().size.y
	return 2.0 * _distance * _layout_zoom * tan(deg_to_rad(fov) * 0.5) / height


func _input(event: InputEvent) -> void:
	# Finish an active drag even if it crosses an overlay on release.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = false
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = false
	if event is InputEventMouseMotion:
		if _rotating:
			_target_yaw -= event.relative.x * 0.007
			_target_pitch = clampf(_target_pitch + event.relative.y * 0.005, 0.29, 1.42)
			get_viewport().set_input_as_handled()
		elif _panning:
			_pan(-event.relative)
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_target_distance = clampf(_target_distance * 0.88, MIN_DISTANCE, _max_distance)
			MOUSE_BUTTON_WHEEL_DOWN:
				_target_distance = clampf(_target_distance / 0.88, MIN_DISTANCE, _max_distance)
			MOUSE_BUTTON_RIGHT:
				_rotating = true
			MOUSE_BUTTON_MIDDLE:
				_panning = true
			MOUSE_BUTTON_LEFT:
				var focus_owner := get_viewport().gui_get_focus_owner()
				if focus_owner != null:
					focus_owner.release_focus()
				floor_clicked.emit(event.position)
