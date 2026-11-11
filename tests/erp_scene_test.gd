extends SceneTree

const SCENE = preload("res://scenes/factory.tscn")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var factory := SCENE.instantiate()
	factory.resume_saved = false
	factory.explicit_planning = false
	root.add_child(factory)
	await process_frame
	var terminal = factory.terminal
	var laptop := _button(factory, "ERP")
	_check(laptop != null and laptop.is_visible_in_tree(), "Laptop is available in the factory")
	if laptop == null:
		quit(1)
		return
	factory._set_playing(true)
	laptop.pressed.emit()
	await create_timer(0.55).timeout
	_check(terminal.is_open() and terminal._shell.scale.is_equal_approx(Vector2.ONE), "Laptop opens and animates")
	_check(factory.line.playing and factory.line.elapsed_seconds() >= 0.25, "ERP stays live without auto-pause")
	for name in terminal.MODULES:
		var button := _button(terminal, name)
		_check(button != null, "Workspace exists " + name)
		if button != null:
			button.pressed.emit()
			_check(terminal._title.text == name and (terminal._table.get_root() != null or terminal._board.visible), "Workspace loads " + name)
	var book = factory.line.erp
	var earlier: Dictionary = book.create_order("FG-1001", 1, book.now, 5)
	if not earlier.error.is_empty() or not book.release(earlier.id).is_empty():
		_check(false, "Create and release an earlier order")
		quit(1)
		return
	factory.line.advance(550.0)
	_check(book.orders[earlier.id].status == "Completed", "Earlier order completes before opening Production Orders")
	_button(terminal, "Production Orders").pressed.emit()
	_check(terminal._rows.has(earlier.id), "Production Orders displays completed orders")
	_button(terminal, "Create order").pressed.emit()
	await process_frame
	var dialog: ConfirmationDialog
	for child in terminal.get_children():
		if child is ConfirmationDialog:
			dialog = child
	_check(dialog != null and dialog.visible, "Create order opens confirmation form")
	if dialog != null:
		var pickers := dialog.find_children("*", "OptionButton", true, false)
		var picker: OptionButton = pickers[0] if not pickers.is_empty() else null
		_check(picker != null and picker.item_count == 4, "Order form offers four dark wafer production versions")
		if picker != null:
			picker.select(2)
			picker.item_selected.emit(2)
		dialog.get_ok_button().pressed.emit()
		await process_frame
	_check(book.orders.size() == 2, "Order form posts one new ERP document")
	var order: Dictionary = book.orders.values().back()
	_check(order.version == "PV-1002-03", "Selected version is stored")
	_check(terminal._rows.has(order.id) and terminal._rows.has(earlier.id),
		"New order appears alongside the completed order")
	if not terminal._rows.has(order.id):
		quit(1)
		return
	terminal._rows[order.id].select(0)
	terminal._on_select()
	_button(terminal, "Show route").pressed.emit()
	await create_timer(0.35).timeout
	_check(factory.floor_view._route_overlay != null and not terminal.is_open(), "Selected order is highlighted in 3D")
	_check(factory.floor_view.view_of(&"Oven02") != null and factory.floor_view.view_of(&"Coater02") != null,
		"Alternate equipment is present in the scene")
	factory._select(&"Oven02")
	_check(factory.hud.inspector._selection == &"Oven02", "Oven 02 opens an independent inspector")
	laptop.pressed.emit()
	await create_timer(0.35).timeout
	book.adjust("RM-COAT-1002", -book.stock("RM-COAT-1002", "RM-WH"), "Scene test shortage")
	_button(terminal, "Material Requirements Planning").pressed.emit()
	_button(terminal, "Run MRP").pressed.emit()
	_check(terminal.plan.summary.get("buy", 0) == 1, "MRP workspace runs actual planning")
	_check(terminal._table.columns == 9 and _button(terminal, "Stock/Requirements list") == null,
		"Legacy planning keeps the flat MRP list")
	_button(terminal, "Production Orders").pressed.emit()
	terminal._rows[order.id].select(0)
	terminal._on_select()
	_button(terminal, "Release").pressed.emit()
	_check(order.status == "Created" and "Missing RM-COAT-1002" in terminal._status.text,
		"Release reports the dark coating shortage")
	_check(book.adjust("RM-COAT-1002", 100.0, "Scene test replenishment").is_empty(), "Top up the missing coating")
	terminal._render()
	_check("Missing RM-COAT-1002" not in terminal._detail.text, "Replenishment clears the obsolete shortage warning")
	_button(terminal, "Release").pressed.emit()
	_check(order.status == "Released", "Replenished order releases from the same row")
	_button(terminal, "Pause shift").pressed.emit()
	_check(not factory.line.playing, "ERP pause control pauses the factory")
	_button(terminal, "Play shift").pressed.emit()
	_check(factory.line.playing, "ERP resume control starts the factory")
	_button(terminal, "Close  ×").pressed.emit()
	await create_timer(0.35).timeout
	_check(not terminal.is_open() and not terminal._root.visible and factory.camera.is_processing(), "Close restores the camera")
	_check(terminal._timer.is_stopped(), "Closed ERP stops table refresh polling")
	factory._select(&"RawWarehouse")
	var stock_link := _button(factory.hud.inspector, "ERP stock")
	_check(stock_link != null and stock_link.is_visible_in_tree(), "Raw warehouse links to ERP")
	if stock_link != null:
		stock_link.pressed.emit()
		await process_frame
		_check(terminal._page == 3 and terminal._search.text == "RM-WH", "Warehouse opens its stock location")
	terminal.close()
	await create_timer(0.35).timeout
	factory._select(&"PackagingWIP")
	var wip_link := _button(factory.hud.inspector, "ERP stock")
	_check(wip_link != null and wip_link.is_visible_in_tree(), "Packaging WIP has a stock inspector")
	if wip_link != null:
		wip_link.pressed.emit()
		await process_frame
		_check(terminal._search.text == "PACK-WIP", "Packaging WIP links to its inventory location")
	factory._save_load_error = "Unavailable saved equipment."
	factory._save_shift()
	_check(terminal._status.text.begins_with("Existing save preserved"), "A failed restore protects the existing slot")
	print("ChocoERP scene interaction checks, %d failures." % _failures)
	quit(int(_failures > 0))


func _button(parent: Node, label: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == label:
			return button
	return null


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("FAIL: " + message)
