extends CanvasLayer
## Compact production overview, transport controls, and the contextual inspector.

const Line = preload("res://simulation/production_line.gd")
const Palette = preload("res://ui/status_colors.gd")
const Style = preload("res://ui/hud_style.gd")
const Inspector = preload("res://ui/station_inspector.gd")
const CLOCK := &"Clock"

signal play_requested
signal pause_requested
signal reset_requested
signal speed_requested(multiplier: int)
signal selection_requested(id: StringName)
signal setting_requested(key: StringName, value: float)
signal dispatch_requested(all_stock: bool)
signal home_requested
signal grid_requested(enabled: bool)
signal placement_requested
signal build_requested
signal erp_requested(page: int, filter: String)

var inspector: Inspector
var _root: Control
var _bold := FontVariation.new()
var _values: Dictionary[StringName, Label] = {}
var _details: Dictionary[StringName, Label] = {}
var _meters: Dictionary[StringName, ProgressBar] = {}
var _speed_buttons: Dictionary[int, Button] = {}
var _mode: Label
var _crew_status: Label
var _play: Button
var _pause: Button
var _hint: Label
var _cursor: Label
var _grid_button: Button
var _build_button: Button
var build_panel: Control
var _build_active := false
var _laptop: Button


func _ready() -> void:
	_bold.base_font = ThemeDB.fallback_font
	_bold.variation_embolden = 0.55
	_root = Control.new()
	_root.name = "Interface"
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_overview()
	_build_controls()
	_build_inspector()
	_build_editor_panel()


func enable_erp(enabled: bool) -> void:
	_laptop.visible = enabled


func refresh(line: Line) -> void:
	var seconds := int(line.elapsed_seconds())
	_values[CLOCK].text = "%02d:%02d:%02d" % [floori(seconds / 3600.0),
		floori(seconds / 60.0) % 60, seconds % 60]
	_mode.text = "●  LIVE" if line.playing else "●  PAUSED"
	_mode.modulate = Style.ACCENT if line.playing else Palette.BLOCKED
	_crew_status.text = "%d / %d floor crew busy   ·   %d queued    " % [
		line.floor_assignments.size(), line.floor_crew.size(), line.pending_jobs.size()]
	_play.disabled = line.playing or _build_active
	_pause.disabled = not line.playing
	for speed in _speed_buttons:
		_speed_buttons[speed].set_pressed_no_signal(speed == line.multiplier)

	_values[&"Hopper"].text = "%.0f kg" % line.hopper.quantity
	_details[&"Hopper"].text = "%.0f kg capacity" % line.hopper.capacity
	_meters[&"Hopper"].value = line.hopper.occupancy()
	_machine_card(&"Extruder", line.extruder)
	_machine_card(&"Coater", line.coater)
	_machine_card(&"Packer", line.packer)
	_values[&"Oven"].text = "%.0f / %.0f kg" % [line.oven.stock.quantity, line.oven.stock.capacity]
	_details[&"Oven"].text = line.oven.state_title()
	if line.oven.state == Line.Oven.State.COOKING:
		_details[&"Oven"].text += " · %.0fs" % line.oven.remaining
	_values[&"Palletizer"].text = "%d ready" % line.pallets_ready()
	_details[&"Palletizer"].text = "%d boxes packed" % line.boxes_completed
	var capacity := int(line.settings[&"warehouse_capacity"])
	var count := line.warehouse_count()
	var fraction := float(count) / capacity if capacity > 0 else 0.0
	_values[&"Warehouse"].text = "%d / %d" % [count, capacity]
	_details[&"Warehouse"].text = "%.0f%% full · pallets" % (fraction * 100.0)
	_meters[&"Warehouse"].value = fraction
	inspector.refresh(line)


func set_hint(message: String) -> void:
	_hint.text = message


func set_cursor(copy: String, color: Color = Style.MUTED) -> void:
	_cursor.text = copy
	_cursor.modulate = color


func set_grid_button(enabled: bool) -> void:
	_grid_button.set_pressed_no_signal(enabled)


func set_build_active(active: bool) -> void:
	_build_active = active
	_build_button.set_pressed_no_signal(active)
	build_panel.visible = active
	if active:
		inspector.hide()


func _machine_card(id: StringName, machine: Line.Machine) -> void:
	_values[id].text = "%.0f kg/h" % machine.actual_rate
	_details[id].text = "●  " + Palette.title(machine.state)
	_details[id].modulate = Palette.color(machine.state)


func _build_overview() -> void:
	var overview := VBoxContainer.new()
	overview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overview.add_theme_constant_override("separation", 12)
	_root.add_child(overview)
	overview.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	overview.offset_left = 22
	overview.offset_right = -22
	overview.offset_top = 17

	var heading := _row(12)
	overview.add_child(heading)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", Style.box(Color("#20423f"), Color("#3f7469"), 8, 8))
	heading.add_child(badge)
	badge.add_child(_label("02", 19, Style.ACCENT, true))
	heading.add_child(_label("Chocolate Works", 28, Style.TEXT, true))
	heading.add_child(_label("  /  WAFER FACTORY", 13, Style.DIM, true))
	_spacer(heading)
	_crew_status = _label("", 13, Style.MUTED)
	heading.add_child(_crew_status)
	_mode = _label("", 13, Style.TEXT, true)
	heading.add_child(_mode)

	var cards := _row(8)
	overview.add_child(cards)
	_card(cards, CLOCK, "SIM TIME", "hh : mm : ss", Style.ACCENT)
	_card(cards, &"Hopper", "01  INGREDIENTS", "", Palette.SFG, true)
	_card(cards, &"Extruder", "02  EXTRUDER", "", Palette.SFG)
	_card(cards, &"Oven", "03  OVEN 01", "", Palette.FG)
	_card(cards, &"Coater", "04  COATER 01", "", Palette.FG)
	_card(cards, &"Packer", "05  PACKAGING", "", Palette.FG)
	_card(cards, &"Palletizer", "06  PALLETS", "", Palette.FG)
	_card(cards, &"Warehouse", "07  WAREHOUSE", "", Palette.FG, true)


func _card(
	parent: HBoxContainer, id: StringName, title: String, detail: String, tint: Color,
	with_meter: bool = false
) -> void:
	var shell := PanelContainer.new()
	var resting := Style.box(Style.SURFACE, Style.BORDER, 9, 9)
	var hovering := Style.box(Color("#1b3542"), tint.darkened(0.42), 9, 9)
	shell.add_theme_stylebox_override("panel", resting)
	shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(shell)
	if id != CLOCK:
		shell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		shell.tooltip_text = "Inspect " + title.substr(4).strip_edges().to_lower()
		shell.mouse_entered.connect(func() -> void:
			shell.add_theme_stylebox_override("panel", hovering))
		shell.mouse_exited.connect(func() -> void:
			shell.add_theme_stylebox_override("panel", resting))
		shell.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
				selection_requested.emit(id))
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 3)
	shell.add_child(stack)
	stack.add_child(_label(title, 12, tint, true))
	var value := _label("—", 21, Style.TEXT, true)
	stack.add_child(value)
	_values[id] = value
	var caption := _label(detail, 13, Style.MUTED)
	stack.add_child(caption)
	_details[id] = caption

	var meter := ProgressBar.new()
	meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.custom_minimum_size.y = 4
	meter.max_value = 1.0
	meter.step = 0.0
	meter.show_percentage = false
	var track := Style.box(Color("#253e4d"), Color("#253e4d"), 2, 0)
	var fill := Style.box(tint, tint, 2, 0)
	track.set_border_width_all(0)
	fill.set_border_width_all(0)
	meter.add_theme_stylebox_override("background", track)
	meter.add_theme_stylebox_override("fill", fill)
	stack.add_child(meter)
	meter.modulate.a = 1.0 if with_meter else 0.0
	if with_meter:
		_meters[id] = meter


func _build_controls() -> void:
	var bottom := VBoxContainer.new()
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.add_theme_constant_override("separation", 8)
	_root.add_child(bottom)
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_left = 22
	bottom.offset_right = -22
	bottom.offset_top = -18
	bottom.offset_bottom = -18

	_hint = _label("Select equipment or crew to inspect it. Press Play to start the shift.", 15, Style.TEXT)
	var tips := _row(16)
	bottom.add_child(tips)
	tips.add_child(_hint)
	_spacer(tips)
	_cursor = _label("", 14, Color.WHITE, true)
	tips.add_child(_cursor)
	var shell := PanelContainer.new()
	shell.add_theme_stylebox_override("panel", Style.box(Style.SURFACE, Style.BORDER, 10, 9))
	bottom.add_child(shell)
	var controls := _row(8)
	shell.add_child(controls)

	_play = _button(controls, "▶  Play", func() -> void: play_requested.emit(), true)
	_play.tooltip_text = "Start the simulation (Space)"
	_pause = _button(controls, "Pause", func() -> void: pause_requested.emit())
	_pause.tooltip_text = "Pause the simulation (Space)"
	var reset := _button(controls, "Reset", func() -> void: reset_requested.emit())
	reset.tooltip_text = "Pause an ERP shift and apply fleet settings between orders."

	controls.add_child(_label("   SPEED", 12, Style.DIM, true))
	var group := ButtonGroup.new()
	for speed: int in Line.SPEEDS:
		var button := _button(controls, "%d×" % speed,
			func() -> void: speed_requested.emit(speed))
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size.x = 44
		_speed_buttons[speed] = button

	_spacer(controls)
	controls.add_child(_label("WASD · RMB Orbit · MMB Pan · Scroll",
		13, Style.MUTED))
	_build_button = _button(controls, "Build Mode", func() -> void: build_requested.emit())
	_build_button.toggle_mode = true
	_build_button.tooltip_text = "Edit factory layout (B)"
	_grid_button = _button(controls, "Grid", func() -> void: grid_requested.emit(_grid_button.button_pressed))
	_grid_button.toggle_mode = true
	_grid_button.tooltip_text = "Toggle the 1 m grid (G)"
	var home := _button(controls, "Home view", func() -> void: home_requested.emit())
	home.tooltip_text = "Return to the starting view (Home)"
	_laptop = _button(controls, "ERP", func() -> void: erp_requested.emit(-1, ""), true)
	_laptop.tooltip_text = "Open ChocoERP laptop (E)"
	var icon := Image.new()
	icon.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="22" height="18" viewBox="0 0 22 18"><path d="M4 2h14v11H4zM1 14h20v2H1z" fill="none" stroke="#132432" stroke-width="1.7" stroke-linejoin="round"/></svg>')
	_laptop.icon = ImageTexture.create_from_image(icon)
	_laptop.hide()


func _build_inspector() -> void:
	inspector = Inspector.new()
	inspector.name = "StationInspector"
	_root.add_child(inspector)
	inspector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	inspector.offset_left = -340
	inspector.offset_right = -22
	inspector.offset_top = 181
	inspector.offset_bottom = 181
	inspector.configure(_bold)
	inspector.erp_requested.connect(func(page: int, filter: String) -> void: erp_requested.emit(page, filter))
	inspector.placement_requested.connect(func() -> void: placement_requested.emit())
	inspector.closed.connect(func() -> void: selection_requested.emit(&""))
	inspector.setting_requested.connect(func(key: StringName, value: float) -> void: setting_requested.emit(key, value))
	inspector.dispatch_requested.connect(func(all_stock: bool) -> void: dispatch_requested.emit(all_stock))


func _build_editor_panel() -> void:
	build_panel = preload("res://ui/build_panel.gd").new()
	_root.add_child(build_panel)
	build_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	build_panel.offset_left = -337
	build_panel.offset_right = -22
	build_panel.offset_top = 181
	build_panel.offset_bottom = 181


func _label(copy: String, size: int, color: Color, bold: bool = false) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", _bold)
	return label


func _row(gap: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", gap)
	return row


func _spacer(parent: HBoxContainer) -> void:
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)


func _button(parent: HBoxContainer, copy: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = copy
	Style.button_style(button, primary)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
