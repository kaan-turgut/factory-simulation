extends Control
## Opening page: create a new simulation instance, or continue or rename a saved one.

const Style = preload("res://ui/hud_style.gd")
const Instances = preload("res://erp/instances.gd")
const Book = preload("res://erp/operations.gd")
const FACTORY := "res://scenes/factory.tscn"

var _bold := FontVariation.new()
var _name: LineEdit
var _feedback: Label
var _list: VBoxContainer


func _ready() -> void:
	get_tree().auto_accept_quit = true
	var args := OS.get_cmdline_user_args()
	# Agent and test launches go straight to an unsaved simulation instance.
	if "--agent-port" in args or "--new-instance" in args or "--fresh-shift" in args:
		_open.call_deferred({})
		return
	_bold.base_font = ThemeDB.fallback_font
	_bold.variation_embolden = 0.55
	_build()
	refresh()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	backdrop.color = Color("#0c1822")
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 0)
	panel.add_theme_stylebox_override("panel", Style.box(Style.SURFACE, Style.BORDER, 14, 28))
	center.add_child(panel)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	panel.add_child(stack)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 12)
	stack.add_child(heading)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", Style.box(Color("#20423f"), Color("#3f7469"), 8, 8))
	badge.add_child(_label("02", 19, Style.ACCENT, true))
	heading.add_child(badge)
	heading.add_child(_label("Chocolate Works", 30, Style.TEXT, true))
	heading.add_child(_label("  /  WAFER FACTORY", 13, Style.DIM, true))
	stack.add_child(_label("Start a new simulation instance or continue one you saved earlier.", 15, Style.MUTED))
	stack.add_child(HSeparator.new())

	stack.add_child(_label("NEW SIMULATION INSTANCE", 12, Style.DIM, true))
	var create := HBoxContainer.new()
	create.add_theme_constant_override("separation", 10)
	stack.add_child(create)
	_name = LineEdit.new()
	_name.name = "InstanceName"
	_name.placeholder_text = "Name"
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.custom_minimum_size.y = 38
	_name.add_theme_font_size_override("font_size", 15)
	_name.text_submitted.connect(func(_text: String) -> void: _create())
	create.add_child(_name)
	_button(create, "Create and open", _create, true)
	_feedback = _label("", 14, Color("#ffc289"))
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_feedback)

	stack.add_child(_label("SAVED SIMULATION INSTANCES", 12, Style.DIM, true))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 330
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stack.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	var footer := HBoxContainer.new()
	stack.add_child(footer)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_button(footer, "Quit", func() -> void: get_tree().quit())


func refresh() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var rows := Instances.list()
	_name.text = _next_name(rows)
	if rows.is_empty():
		_list.add_child(_label("No saved simulation instances yet.", 15, Style.MUTED))
		return
	for row in rows:
		_list.add_child(_instance_row(row))


func _instance_row(row: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.name = "Instance_" + String(row.id)
	card.add_theme_stylebox_override("panel", Style.box(Color("#182d3c"), Color("#2c4352"), 8, 12))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	card.add_child(line)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(text)
	text.add_child(_label(String(row.name), 17, Style.TEXT, true))
	var details := PackedStringArray()
	var seconds := float(row.get("sim_seconds", -1.0))
	var stamp := Time.get_datetime_string_from_unix_time(int(row.updated), true).left(16)
	if not row.get("saved", false):
		details.append("Not started yet · created " + stamp)
	else:
		if seconds >= 0.0:
			details.append("Simulation time " + Book.date(seconds))
		details.append("Last saved " + stamp)
	text.add_child(_label("  ·  ".join(details), 13, Style.DIM))
	_button(line, "Rename", _rename.bind(row))
	_button(line, "Delete", _confirm_delete.bind(row))
	_button(line, "Continue" if row.get("saved", false) else "Start", _continue.bind(row), true)
	return card


func _create() -> void:
	var result := Instances.create(_name.text)
	if not result.error.is_empty():
		_feedback.text = result.error
		return
	_open({"id": result.id, "new": true})


func _continue(row: Dictionary) -> void:
	# An instance that never got its first save starts as a new simulation under its name.
	_open({"id": row.id, "new": not row.get("saved", false)})


func _rename(row: Dictionary) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Rename simulation instance"
	dialog.ok_button_text = "Rename"
	dialog.dialog_hide_on_ok = false
	var form := VBoxContainer.new()
	form.custom_minimum_size.x = 380
	dialog.add_child(form)
	var edit := LineEdit.new()
	edit.text = row.name
	edit.max_length = Instances.NAME_LIMIT
	form.add_child(edit)
	var problem := _label("", 14, Color("#ffc289"))
	form.add_child(problem)
	add_child(dialog)
	var submit := func() -> void:
		var error := Instances.rename(row.id, edit.text)
		if error.is_empty():
			dialog.queue_free()
			refresh()
		else:
			problem.text = error
	dialog.confirmed.connect(submit)
	edit.text_submitted.connect(func(_text: String) -> void: submit.call())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()
	edit.grab_focus()
	edit.select_all()


func _confirm_delete(row: Dictionary) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete simulation instance"
	dialog.dialog_text = "Delete \"%s\"? Its saved progress is removed permanently and cannot be recovered." % row.name
	dialog.ok_button_text = "Delete"
	dialog.confirmed.connect(func() -> void:
		var error := Instances.delete(row.id)
		_feedback.text = error
		refresh())
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _open(request: Dictionary) -> void:
	Instances.pending = request
	get_tree().change_scene_to_file(FACTORY)


static func _next_name(rows: Array) -> String:
	var used := {}
	for row in rows:
		used[String(row.name).to_lower()] = true
	var index := rows.size() + 1
	while used.has(("Simulation %d" % index).to_lower()):
		index += 1
	return "Simulation %d" % index


func _label(copy: String, size: int, color: Color, bold: bool = false) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", _bold)
	return label


func _button(parent: Control, copy: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = copy
	Style.button_style(button, primary)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
