extends PanelContainer
## Selectable machines, stock, workers and vehicles share one live inspector.

const Line = preload("res://simulation/production_line.gd")
const Style = preload("res://ui/hud_style.gd")
const Palette = preload("res://ui/status_colors.gd")

signal closed
signal erp_requested(page: int, filter: String)
signal placement_requested
signal setting_requested(key: StringName, value: float)
signal dispatch_requested(all_stock: bool)

const STATIONS := {
	&"RawWarehouse": ["Raw material warehouse", "ERP  ·  RM-WH", []],
	&"SFGWarehouse": ["Wafer stock", "ERP  ·  SFG-WH", []],
	&"Platform": ["Ingredient platform", "LAYOUT  ·  ELEVATED FLOOR", []],
	&"Stairs": ["Platform stairs", "LAYOUT  ·  ACCESS", []],
	&"RawParking": ["Raw cart parking", "LAYOUT  ·  PARKING", []],
	&"CookedParking": ["Cooked cart parking", "LAYOUT  ·  PARKING", []],
	&"CoatedParking": ["Coated cart parking", "LAYOUT  ·  PARKING", []],
	&"PackagingWIP": ["Packaging WIP", "ERP  ·  PACK-WIP", [&"pack_wip_capacity", &"coated_cart_capacity", &"coated_cart_count"]],
	&"CartonBelt": ["Carton conveyor", "LAYOUT  ·  CONNECTION", []],
	&"Hopper": ["Ingredient hopper", "01  ·  MEZZANINE", [&"sack_kg", &"hopper_capacity",
		&"platform_speed", &"pickup_time", &"unload_time"]],
	&"Extruder": ["Wafer extruder", "02  ·  CONTINUOUS PROCESS", [&"extruder_rate", &"raw_capacity", &"raw_count"]],
	&"Oven": ["Oven 01", "03  ·  THERMAL PROCESS", [&"batch_capacity", &"cook_minutes",
		&"cooked_capacity", &"cooked_count"]],
	&"Oven02": ["Oven 02", "THERMAL PROCESS", [&"batch_capacity_02", &"cook_minutes_02", &"cooked_capacity", &"cooked_count"]],
	&"Coater02": ["Coater 02", "CONTINUOUS PROCESS", [&"coater_rate_02", &"coater_input_02"]],
	&"Coater": ["Coater 01", "04  ·  CONTINUOUS PROCESS", [&"coater_rate", &"coater_input"]],
	&"Packer": ["Packaging machine", "05  ·  CARTON LINE", [&"packing_rate", &"box_kg"]],
	&"Palletizer": ["Palletizing bays", "06  ·  OUTBOUND STAGING", [&"pallet_boxes"]],
	&"Warehouse": ["FG warehouse", "07  ·  OUTBOUND STORAGE", [&"warehouse_capacity"]],
	&"Forklift": ["Forklift", "LOGISTICS  ·  ELECTRIC LIFT", [&"lift_speed"]]
}

var _selection: StringName = &""
var _bold: Font
var _tag: Label
var _title: Label
var _grid_info: Label
var _place: Button
var _erp_link: Button
var _state: Label
var _readout: Label
var _settings: VBoxContainer
var _controls: Dictionary[StringName, Array] = {}
var _shipping: HBoxContainer
var _ship_one: Button
var _ship_all: Button
var _feedback: Label


func configure(bold: Font) -> void:
	_bold = bold
	var shell := Style.box(Color("#112331"), Color("#496473"), 12, 15)
	shell.shadow_color = Color("#08141c99")
	shell.shadow_size = 8
	add_theme_stylebox_override("panel", shell)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	add_child(stack)

	var top := HBoxContainer.new()
	stack.add_child(top)
	_tag = _label("", 12, Style.ACCENT, true)
	_tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_tag)
	_place = _button(top, "Place", func() -> void: placement_requested.emit())
	_place.tooltip_text = "Reposition and rotate this station before starting a shift"
	_erp_link = _button(top, "ERP stock", func() -> void:
		var location := {&"RawWarehouse": "RM-WH", &"SFGWarehouse": "SFG-WH", &"PackagingWIP": "PACK-WIP", &"Warehouse": "FG-WH"}
		erp_requested.emit(3, location[_selection]))
	_erp_link.hide()
	var close := _button(top, "×", func() -> void: closed.emit())
	close.custom_minimum_size = Vector2(31, 29)
	close.tooltip_text = "Close the inspector (Esc)"
	_title = _label("", 23, Style.TEXT, true)
	stack.add_child(_title)
	_grid_info = _label("", 13, Style.MUTED)
	stack.add_child(_grid_info)
	_state = _label("", 14, Style.TEXT, true)
	stack.add_child(_state)
	_readout = _label("", 14, Style.MUTED)
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.add_theme_constant_override("line_spacing", 4)
	stack.add_child(_readout)
	stack.add_child(HSeparator.new())
	_settings = VBoxContainer.new()
	_settings.add_theme_constant_override("separation", 5)
	stack.add_child(_settings)
	_shipping = HBoxContainer.new()
	_shipping.add_theme_constant_override("separation", 8)
	stack.add_child(_shipping)
	_ship_one = _button(_shipping, "Dispatch one", func() -> void: dispatch_requested.emit(false))
	_ship_all = _button(_shipping, "Dispatch all", func() -> void: dispatch_requested.emit(true), true)
	_feedback = _label("", 13, Style.ACCENT)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_feedback)
	hide()


func select(id: StringName, line: Line) -> void:
	_selection = id
	var data := _definition(id, line)
	visible = not data.is_empty()
	if not visible:
		return
	_title.text = data[0]
	_tag.text = data[1]
	_shipping.visible = id == &"Warehouse"
	_erp_link.visible = line.erp != null and id in [&"Warehouse", &"RawWarehouse", &"SFGWarehouse", &"PackagingWIP"]
	_feedback.text = ""
	for row in _settings.get_children():
		_settings.remove_child(row)
		row.queue_free()
	_controls.clear()
	for key: StringName in data[2]:
		if line.erp != null and key in [&"box_kg", &"pallet_boxes"]:
			continue
		_add_setting(key, line.settings[key])
	refresh(line)


func set_layout_info(copy: String, description: String, movable: bool, available: bool, placing: bool) -> void:
	_grid_info.visible = not copy.is_empty()
	_grid_info.text = copy
	_grid_info.tooltip_text = description
	_grid_info.mouse_filter = Control.MOUSE_FILTER_PASS
	_place.visible = movable
	_place.disabled = not available
	_place.text = "Cancel" if placing else "Place"
	_place.tooltip_text = "Reposition and rotate this station" if available else "Finish production and park vehicles before moving a station"


func feedback(message: String) -> void:
	_feedback.text = message


func sync_setting(key: StringName, value: float) -> void:
	if not _controls.has(key):
		return
	for control: Range in _controls[key]:
		control.set_value_no_signal(value)


func refresh(line: Line) -> void:
	if not visible:
		return
	if String(_selection).begins_with("FGSlot"):
		var pallet := line.warehouse[String(_selection).trim_prefix("FGSlot").to_int()]
		_status("Stored pallet" if pallet != null else "Empty slot", Palette.FG)
		_readout.text = "%s · %s\nOrder %s · %d boxes · %.2f kg" % [
			pallet.id, pallet.sku, pallet.order_id, pallet.boxes, pallet.mass] if pallet != null else "Pallet dispatched."
		return
	match _selection:
		&"SFGWarehouse":
			var total := 0.0
			for quantity in line.erp.balances["SFG-WH"].values():
				total += float(quantity)
			_status("SFG-WH · Wafer stock", Palette.SFG)
			_readout.text = "%.1f kg received at the tray-cart dock." % total
		&"RawWarehouse":
			_status("RM-WH · Raw inventory", Palette.SFG)
			_readout.text = "Flour and sugar · Oils and inputs · Coatings · Cartons · Labels\nOpen ERP stock to inspect and manage balances."
		&"Hopper":
			_status("Ingredient replenishment", Palette.SFG)
			_readout.text = "On hand   %s\nReserved for incoming sacks   %.1f kg" % [
				_stock(line.hopper), line.hopper_reserved]
		&"Extruder":
			var cart := line.raw_at_extruder
			var output := _stock(cart.stock) if cart != null and cart.site == Line.Cart.Site.EXTRUDER else "Waiting for cart"
			_machine(line.extruder, "Hopper   %s\nRaw cart   %s" % [_stock(line.hopper), output])
		&"Oven", &"Oven02":
			var oven: Line.Oven = line.ovens.get(_selection, line.oven)
			var cooking := oven.state == Line.Oven.State.COOKING
			_status(oven.state_title(), Palette.BLOCKED if cooking else Palette.SFG)
			_readout.text = "Chamber load   %s\nTime remaining   %.1f sim s\nBatches cooked   %d" % [
				_stock(oven.stock), oven.remaining, oven.batches]
		&"Coater", &"Coater02":
			var order := line.order_at(_selection)
			var run: Dictionary = line.runs.get(order.get("id", ""), {})
			var input: Line.Storage = line.coater_inputs.get(_selection, line.cooked_input)
			var output: Line.Storage = run.get("output", line.coated_input if line.erp == null else null)
			_machine(line.coaters.get(_selection, line.coater), "Staging Area   %s\nCoated outfeed   %s" % [
				_stock(input), _stock(output) if output != null else "Empty"])
		&"PackagingWIP":
			_status("Cart receiving buffer", Palette.SFG)
			var order := line.order_at(&"Packer")
			_readout.text = "On hand   %s\nOrder %s · SKU %s\nDock   %s" % [
				_stock(line.pack_wip), order.get("id", "—"), order.get("code", "—"),
				line.pack_dock.title() if line.pack_dock != null else "Open"]
		&"Packer":
			_machine(line.packer, "Coated infeed   %s\nCurrent box   %.1f / %.1f kg\nBoxes completed   %d" % [
				_stock(line.coated_input), line.box_progress,
				line.box_target if line.box_progress > 0.0 else line.settings[&"box_kg"], line.boxes_completed])
		&"Palletizer":
			_status("%d full pallet(s) awaiting pickup" % line.pallets_ready(), Palette.FG)
			var bays := PackedStringArray()
			for index in line.staged_pallets.size():
				var pallet := line.staged_pallets[index]
				var fill := "%d / %d boxes" % [pallet.boxes, pallet.target_boxes] if pallet != null else "Empty"
				bays.append("Bay %02d   %s" % [index + 1, fill])
			_readout.text = "\n".join(bays)
		&"Warehouse":
			var count := line.warehouse_count()
			var capacity := int(line.settings[&"warehouse_capacity"])
			var reserved := int(line.warehouse_reserved_slot >= 0)
			var open := capacity - count - reserved
			var pct := count * 100.0 / capacity if capacity > 0 else 0.0
			_status("%.0f%% occupied  ·  %d open" % [pct, open], Palette.FG)
			_readout.text = "Stored   %d / %d pallets · %.1f kg\nReserved   %d pallet slot(s)\nDispatched   %d pallets · %.1f kg" % [
				count, capacity, line.warehouse_mass(), reserved, line.dispatched_pallets, line.dispatched_kg]
			_ship_one.disabled = count == 0
			_ship_all.disabled = count == 0
		_:
			var worker := line.find_operator(_selection)
			if worker != null:
				_operator(worker, line)
				return
			var cart := line.find_cart(_selection)
			if cart != null:
				_status(cart.state_title(), Palette.SFG if cart.raw else Palette.FG)
				var owner := line.find_operator(cart.owner)
				_readout.text = "On tray   %s\nLocation   %s\nAssigned to   %s" % [
					_stock(cart.stock), Line.Cart.SITE_NAMES[cart.site], owner.title if owner != null else "—"]
				if not cart.order_id.is_empty():
					_readout.text += "\nOrder " + cart.order_id
			else:
				var item := line.layout.definition(_selection)
				_status(item.kind.capitalize(), Palette.SFG)
				_readout.text = "%.2f m high" % item.height

	if line.erp != null and _selection in [&"Hopper", &"Extruder", &"Oven", &"Oven02", &"Coater", &"Coater02", &"Packer"]:
		var order := line.order_at(_selection)
		_readout.text += "\nOrder %s · SKU %s" % [order.get("id", "—"), order.get("code", "—")]
		if _selection == &"Packer" and not order.is_empty():
			_readout.text += "\n%.2f kg / box · %d boxes / pallet" % [
				order.recipe.spec.box_kg, order.recipe.spec.boxes_per_pallet]


func _definition(id: StringName, line: Line) -> Array:
	if STATIONS.has(id):
		return STATIONS[id]
	if line.erp != null and String(id).begins_with("FGSlot"):
		return ["Finished pallet", "ERP  ·  FG-WH", []]
	if id == &"SupplyShuttle" and line.erp != null:
		return ["Material shuttle", "ERP  ·  INTERNAL LOGISTICS", []]
	var worker := line.find_operator(id)
	if worker != null:
		if String(id).begins_with("Platform"):
			return [worker.title, "CREW  ·  INGREDIENT DECK", [&"platform_speed", &"pickup_time", &"unload_time"]]
		return [worker.title, "CREW  ·  FACTORY FLOOR", [&"floor_speed", &"floor_count"]]
	var cart := line.find_cart(id)
	if cart != null:
		var keys := [&"raw_capacity", &"raw_count"] if cart.raw else [&"cooked_capacity", &"cooked_count"]
		if cart.coated:
			keys = [&"coated_cart_capacity", &"coated_cart_count"]
		return [cart.title(), "LOGISTICS  ·  TRAY CART", keys]
	return []


func _machine(machine: Line.Machine, inventories: String) -> void:
	_status(Palette.title(machine.state), Palette.color(machine.state))
	_readout.text = "Setpoint   %.0f kg/h\nActual   %.0f kg/h\n%s\nRun output   %.1f kg" % [
		machine.configured_rate, machine.actual_rate, inventories, machine.total_output]


func _operator(worker: Line.Operator, line: Line) -> void:
	var tint := Palette.IDLE if worker.state == Line.Operator.State.IDLE else Palette.RUNNING
	_status(worker.state_title(), tint)
	var task := worker.task if not worker.task.is_empty() else "Awaiting work"
	var destination := worker.destination if not worker.destination.is_empty() else "—"
	_readout.text = "Task   %s\nDestination   %s" % [task, destination]
	if worker.cargo_kg > 0.0:
		_readout.text += "\nCarrying   %.1f kg" % worker.cargo_kg
	if worker.id == &"Forklift" and line.lift_load != null:
		_readout.text += "\nCarrying   1 pallet · %.1f kg" % line.lift_load.mass


func _status(copy: String, tint: Color) -> void:
	_state.text = "●  " + copy
	_state.modulate = tint


func _stock(stock: Line.Storage) -> String:
	return "%.1f / %.1f kg" % [stock.quantity, stock.capacity]


func _add_setting(key: StringName, value: float) -> void:
	var spec: Array = Line.Settings.SPECS[key]
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	_settings.add_child(row)
	row.add_child(_label(spec[0], 13, Style.TEXT, true))
	var fields := HBoxContainer.new()
	fields.add_theme_constant_override("separation", 10)
	row.add_child(fields)
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	fields.add_child(slider)
	var spin := SpinBox.new()
	spin.name = key
	spin.select_all_on_focus = true
	spin.custom_minimum_size.x = 89
	spin.get_line_edit().add_theme_font_size_override("font_size", 14)
	fields.add_child(spin)
	for control: Range in [slider, spin]:
		control.min_value = spec[1]
		control.max_value = spec[2]
		control.step = spec[3]
		control.value = value
		control.value_changed.connect(func(changed: float) -> void: setting_requested.emit(key, changed))
	_controls[key] = [slider, spin]


func _label(copy: String, size: int, color: Color, bold: bool = false) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", _bold)
	return label


func _button(parent: HBoxContainer, copy: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = copy
	Style.button_style(button, primary)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
