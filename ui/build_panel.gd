extends PanelContainer
## Compact controls for the layout editing session.

const Style = preload("res://ui/hud_style.gd")

signal action_requested(action: String)

var _title: Label
var _details: Label
var _status: Label
var _saved: Label
var _buttons: Dictionary[String, Button] = {}


func _ready() -> void:
	add_theme_stylebox_override("panel", Style.box(Style.SURFACE, Style.BORDER, 12, 14))
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 7)
	add_child(stack)
	_label(stack, "BUILD MODE", 12, Style.ACCENT)
	_title = _label(stack, "", 21, Style.TEXT)
	_details = _label(stack, "", 14, Style.MUTED)
	_status = _label(stack, "", 14, Style.ACCENT)
	stack.add_child(HSeparator.new())
	_actions(stack, [["move", "Move"], ["rotate", "Rotate"], ["cancel", "Cancel"]])
	_actions(stack, [["undo", "Undo"], ["redo", "Redo"], ["default", "Default"]])
	_actions(stack, [["save", "Save Layout"], ["load", "Load Layout"]])
	_saved = _label(stack, "", 13, Style.MUTED)
	_label(stack, "Drag to move · R / Shift+R to rotate\nEsc cancels · ⌘Z / ⇧⌘Z undo / redo\nB exits · Right drag orbits · Z / X zoom", 12, Style.MUTED)
	hide()


func update_selection(title: String, details: String, status: String, tint: Color, movable: bool, placing: bool) -> void:
	_title.text = title
	_details.text = details
	_status.text = status
	_status.add_theme_color_override("font_color", tint)
	_buttons.move.disabled = not movable or placing
	_buttons.rotate.disabled = not movable
	_buttons.cancel.disabled = not placing


func update_history(dirty: bool, undo: bool, redo: bool) -> void:
	_saved.text = "Unsaved layout changes" if dirty else "No unsaved layout changes"
	_buttons.undo.disabled = not undo
	_buttons.redo.disabled = not redo


func _actions(parent: VBoxContainer, actions: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	parent.add_child(row)
	for item in actions:
		var id: String = item[0]
		var button := Button.new()
		button.text = item[1]
		Style.button_style(button, id == "save")
		button.pressed.connect(func() -> void: action_requested.emit(id))
		row.add_child(button)
		_buttons[id] = button


func _label(parent: Control, copy: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label
