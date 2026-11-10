extends RefCounted
## Factory HUD colors and built-in control styling.

const TEXT := Color("#edf5fa")
const MUTED := Color("#a8bdca")
const DIM := Color("#819bab")
const SURFACE := Color("#132432")
const BORDER := Color("#38505f")
const ACCENT := Color("#76e1c0")


static func box(fill: Color, border: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = margin
	style.content_margin_bottom = margin
	return style


static func button_style(button: Button, primary: bool = false) -> void:
	var fill := ACCENT if primary else Color("#1b3140")
	var border := fill if primary else BORDER
	var ink := Color("#102b27") if primary else TEXT
	var normal := box(fill, border, 7, 8)
	var hover := box(fill.lightened(0.12), border.lightened(0.2), 7, 8)
	var pressed := box(Color("#2b665d"), Color("#65bca7"), 7, 8)
	var disabled := box(Color("#192a37"), Color("#314654"), 7, 8)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_hover_color", ink)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_disabled_color", DIM)
	button.add_theme_font_size_override("font_size", 15)
	button.custom_minimum_size.y = 38
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
