extends CanvasLayer
## ChocoERP terminal. One table per view, bounded journal rendering, refresh only while open.

const Line = preload("res://simulation/production_line.gd")
const Book = Line.ERP
const Scheduling = Book.Scheduling
const ScheduleBoard = preload("res://ui/scheduling_board.gd")
const SCHEDULE_PAGE := 12
const STANDARDS_PAGE := 13
const Plan = preload("res://erp/mrp.gd")
const Style = preload("res://ui/hud_style.gd")

signal closed
signal play_requested(enabled: bool)
signal save_requested
signal load_requested
signal locate_requested(location: String)
signal route_requested(id: String)

const MODULES := ["Dashboard", "Material Master", "Bill of Materials", "Inventory Management",
	"Material Requirements Planning", "Production Orders", "Procurement", "Goods Movements", "Reports and Analytics",
	"Routing Master", "Work Center Master", "Production Versions", "Detailed Scheduling", "Production Standards"]
const INK := Color("#182d42")
const MUTED := Color("#50677b")
const BLUE := Color("#1969a4")
const PAPER := Color("#f5f8fc")

var line: Line
var plan := Plan.new()
var _page := 0
var _selected := {}
var _rows := {}
var _revision := -1
var _board_time := -1.0
var _pending_page := false
var _suppliers := false
var _proposals_only := false
var _exceptions_only := false
var _mrp_material := ""
var _schedule_report := false
var _open := false
var _root: Control
var _dimmer: ColorRect
var _shell: PanelContainer
var _title: Label
var _summary: Label
var _status: Label
var _clock: Label
var _pause: Button
var _auto_release: CheckButton
var _search: LineEdit
var _family: LineEdit
var _date_filter: LineEdit
var _table: Tree
var _detail: RichTextLabel
var _board: VBoxContainer
var _filters: HBoxContainer
var _actions: HFlowContainer
var _nav: Array[Button] = []
var _tween: Tween
var _timer: Timer


func _ready() -> void:
	layer = 20
	_build()
	_root.hide()
	_timer = Timer.new()
	_timer.wait_time = 0.5
	add_child(_timer)
	_timer.timeout.connect(_poll)


func bind(factory_line: Line) -> void:
	line = factory_line
	plan = Plan.new()
	_board.bind(line)
	_revision = -1
	if _open:
		_render()


func is_open() -> bool:
	return _open


func open(page: int = -1, query: String = "") -> void:
	if page >= 0:
		_page = page
		_search.set_text(query)
		_family.clear()
		_date_filter.clear()
		_selected = {}
		_suppliers = false
	if _tween != null:
		_tween.kill()
	_open = true
	_root.show()
	_timer.start()
	_set_page(_page, false)
	_shell.pivot_offset = _shell.size
	_shell.scale = Vector2(0.12, 0.09)
	_dimmer.modulate.a = 0.0
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_shell, "scale", Vector2.ONE, 0.26)
	_tween.tween_property(_dimmer, "modulate:a", 1.0, 0.25)


func close() -> void:
	if not _open:
		return
	_open = false
	_timer.stop()
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(_shell, "scale", Vector2(0.12, 0.09), 0.19)
	_tween.tween_property(_dimmer, "modulate:a", 0.0, 0.19)
	_tween.chain().tween_callback(func() -> void:
		_root.hide()
		closed.emit())


func notice(message: String) -> void:
	_status.text = message


func _poll() -> void:
	if not _open:
		return
	_clock.text = Book.date(line.elapsed_seconds())
	_pause.text = "Pause shift" if line.playing else "Play shift"
	if _page == SCHEDULE_PAGE:
		if _board_time != line.erp.now or _revision != line.erp.revision:
			_board_time = line.erp.now
			_board.refresh()
		if _revision != line.erp.revision and not _board.picked.is_empty():
			_select_board_order(_board.picked)
		_revision = line.erp.revision
		return
	if line.erp.revision != _revision and _page not in [1, 2, 4, 9, 11, STANDARDS_PAGE]:
		_render()


func _build() -> void:
	_root = Control.new()
	_root.name = "ChocoERP"
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dimmer = ColorRect.new()
	_dimmer.color = Color("#081322ba")
	_root.add_child(_dimmer)
	_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shell = PanelContainer.new()
	_root.add_child(_shell)
	_shell.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shell.offset_left = 34
	_shell.offset_right = -34
	_shell.offset_top = 27
	_shell.offset_bottom = -28
	_shell.add_theme_stylebox_override("panel", Style.box(PAPER, Color("#6c859c"), 13, 16))
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	_shell.add_child(stack)
	var header := HBoxContainer.new()
	stack.add_child(header)
	header.add_child(_label("ChocoERP", 26, BLUE))
	header.add_child(_label("   /   PLANT OPERATIONS", 13, MUTED))
	_spacer(header)
	_clock = _label("", 14, MUTED)
	header.add_child(_clock)
	_pause = _button(header, "Pause shift", func() -> void:
		play_requested.emit(not line.playing)
		_poll())
	_auto_release = CheckButton.new()
	_auto_release.text = "Auto Release"
	_auto_release.tooltip_text = "Release planned orders when their BOM components are in stock. Orders still wait for their scheduled start."
	Style.button_style(_auto_release)
	_auto_release.toggled.connect(func(enabled: bool) -> void:
		line.erp.auto_release = enabled
		line.erp.changed()
		notice("Auto Release is on. Orders will release as stock becomes available during the shift." if enabled
			else "Auto Release is off. Use Release to authorize planned orders."))
	header.add_child(_auto_release)
	_button(header, "Save", func() -> void: save_requested.emit())
	_button(header, "Load", func() -> void:
		_form("Load saved shift", [], func(_values: Dictionary) -> String:
			load_requested.emit()
			return ""))
	_button(header, "Close  ×", close)
	stack.add_child(HSeparator.new())
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(body)
	var sidebar_scroll := ScrollContainer.new()
	sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar_scroll.custom_minimum_size.x = 255
	body.add_child(sidebar_scroll)
	var sidebar := VBoxContainer.new()
	sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar.custom_minimum_size.x = 206
	sidebar.add_theme_constant_override("separation", 6)
	sidebar_scroll.add_child(sidebar)
	sidebar.add_child(_label("WORKSPACES", 13, MUTED))
	for index in MODULES.size():
		var button := _button(sidebar, MODULES[index], _set_page.bind(index))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_nav.append(button)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	body.add_child(content)
	_title = _label("", 23, INK)
	content.add_child(_title)
	_summary = _label("", 14, MUTED)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_summary)
	_filters = HBoxContainer.new()
	content.add_child(_filters)
	_search = _filter(_filters, "Search by code, description or status")
	_family = _filter(_filters, "Product family")
	_date_filter = _filter(_filters, "Due through sim minute")
	_actions = HFlowContainer.new()
	content.add_child(_actions)
	_table = Tree.new()
	_table.name = "ERPTable"
	_table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_table.custom_minimum_size.y = 210
	_table.hide_root = true
	_table.select_mode = Tree.SELECT_ROW
	_table.column_titles_visible = true
	_table.add_theme_stylebox_override("panel", Style.box(Color.WHITE, Color("#cad5e0"), 5, 2))
	var hover := Style.box(Color("#edf5fc"), Color("#d6e6f4"), 3, 2)
	var selected := Style.box(Color("#d5edff"), Color("#a2c8e3"), 3, 2)
	var focused := Style.box(Color("#c7e5fa"), Color("#84b8de"), 3, 2)
	_table.add_theme_stylebox_override("hovered", hover)
	_table.add_theme_stylebox_override("hovered_dimmed", hover)
	_table.add_theme_stylebox_override("selected", selected)
	_table.add_theme_stylebox_override("hovered_selected", selected)
	_table.add_theme_stylebox_override("selected_focus", focused)
	_table.add_theme_stylebox_override("hovered_selected_focus", focused)
	for color_key in ["font_color", "font_selected_color", "font_hovered_color",
			"font_hovered_dimmed_color", "font_hovered_selected_color"]:
		_table.add_theme_color_override(color_key, INK)
	_table.add_theme_color_override("title_button_color", INK)
	_table.add_theme_stylebox_override("title_button_normal", Style.box(Color("#e6eef6"), Color("#dae3ec"), 0, 5))
	_table.add_theme_stylebox_override("title_button_hover", Style.box(Color("#d5edff"), Color("#a2c8e3"), 0, 5))
	_table.add_theme_stylebox_override("title_button_pressed", Style.box(Color("#c7e5fa"), Color("#84b8de"), 0, 5))
	_table.add_theme_constant_override("v_separation", 7)
	_table.add_theme_font_size_override("font_size", 14)
	_table.item_selected.connect(_on_select)
	_table.item_activated.connect(_on_activate)
	content.add_child(_table)
	_board = ScheduleBoard.new()
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.hide()
	_board.selected.connect(_select_board_order)
	_board.details_requested.connect(_open_order)
	_board.feedback.connect(notice)
	content.add_child(_board)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = false
	_detail.custom_minimum_size.y = 88
	_detail.add_theme_color_override("default_color", INK)
	_detail.add_theme_font_size_override("normal_font_size", 14)
	content.add_child(_detail)
	_status = _label("Ready", 14, BLUE)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_status)


func _filter(parent: Control, hint: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = hint
	edit.custom_minimum_size.x = 155
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_color_override("font_color", INK)
	edit.add_theme_color_override("font_placeholder_color", MUTED)
	edit.add_theme_stylebox_override("normal", Style.box(Color.WHITE, Color("#bfcfdc"), 5, 6))
	edit.text_changed.connect(func(_value: String) -> void: _render())
	parent.add_child(edit)
	return edit


func _set_page(index: int, clear_search: bool = true) -> void:
	if index != _page:
		_mrp_material = ""
	_page = index
	_selected = {}
	_suppliers = false
	if clear_search:
		_search.clear()
		_family.clear()
		_date_filter.clear()
	for i in _nav.size():
		_nav[i].modulate = Color("#a9e6ff") if i == _page else Color.WHITE
	for child in _actions.get_children():
		_actions.remove_child(child)
		child.queue_free()
	var scheduling := _page == SCHEDULE_PAGE
	_board.visible = scheduling
	_table.visible = not scheduling
	_filters.visible = not scheduling
	_detail.custom_minimum_size.y = 56 if scheduling else 88
	_family.visible = _page in [4, STANDARDS_PAGE]
	_date_filter.visible = _page == 4
	_build_actions()
	_render()


func _refresh_actions() -> void:
	for child in _actions.get_children():
		_actions.remove_child(child)
		child.queue_free()
	_build_actions()


func _build_actions() -> void:
	match _page:
		1:
			_action("Edit material", _edit_material)
			_action("Clone product", _clone_product)
			_action("Locate stock", _locate)
		2:
			_action("Edit component", _edit_component)
			_action("Add component", _edit_component.bind(true))
			_action("Edit BOM header", _edit_header)
		3:
			_action("Transfer", _transfer)
			_action("Adjust RM stock", _adjust)
			_action("Dispatch one pallet", func() -> void:
				notice("Dispatched %d pallet(s)." % line.dispatch(false))
				_render())
			_action("Locate stock", _locate)
		4:
			_action("Run MRP", _run_mrp)
			if not line.erp.explicit_planning:
				pass
			elif _mrp_material.is_empty():
				_action("Stock/Requirements list", func() -> void: _open_material(String(_selected.get("material", ""))))
			else:
				_action("← Coverage list", func() -> void: _open_material(""))
			_action("Create demand", _new_demand)
			if line.erp.explicit_planning:
				_action("Load filled-wafer example", _example_demands)
			_action("Convert proposal", _convert)
			if line.erp.explicit_planning:
				_action("Convert all shown", _convert_shown)
				_action("Firm / unfirm", _toggle_firm)
				_action("Change planned order", _change_planned)
			if not _mrp_material.is_empty() or not line.erp.explicit_planning:
				var proposals := _button(_actions, "Proposals only", func() -> void:
					_proposals_only = not _proposals_only
					_render())
				proposals.toggle_mode = true
				proposals.button_pressed = _proposals_only
			if line.erp.explicit_planning:
				var exceptions := _button(_actions, "Exceptions only", func() -> void:
					_exceptions_only = not _exceptions_only
					_render())
				exceptions.toggle_mode = true
				exceptions.button_pressed = _exceptions_only
		5:
			_action("Create order", _new_order)
			_action("Release", func() -> void: _order_action("release"))
			_action("Priority / start", _priority)
			if line.erp.explicit_planning:
				_action("Check stock", _check_components)
				_action("Peg supply", _peg_order)
				_action("Supply orders", _open_supply_order)
				_action("Component inventory", _component_inventory)
			_action("Cancel", func() -> void: _confirm_order("Cancelled"))
			_action("Close order", func() -> void: _order_action("Closed"))
			if not line.erp.explicit_planning:
				_action("Setup times", _setup)
			_action("Select version", _select_order_version)
			_action("Show route", _highlight_order)
		6:
			_action("Create purchase order", _new_purchase)
			_action("Suppliers / POs", func() -> void:
				_suppliers = not _suppliers
				_selected = {}
				_render())
		8:
			_action("Schedule adherence / Shift history", func() -> void:
				_schedule_report = not _schedule_report
				_render())
		STANDARDS_PAGE:
			_action("Reload Standards", _reload_standards)
		SCHEDULE_PAGE:
			_action("New stage order", _new_order)
			_action("Release selected", func() -> void: _order_action("release"))
			_action("Order details", func() -> void: _open_order(String(_selected.get("id", ""))))


func _render() -> void:
	if line == null or line.erp == null or not _open:
		return
	var book := line.erp
	_revision = book.revision
	_title.text = MODULES[_page]
	_clock.text = Book.date(line.elapsed_seconds())
	_pause.text = "Pause shift" if line.playing else "Play shift"
	_auto_release.visible = book.explicit_planning
	_auto_release.set_pressed_no_signal(book.auto_release)
	_rows.clear()
	_table.clear()
	match _page:
		0: _dashboard()
		1: _materials()
		2: _bom()
		3: _inventory()
		4: _mrp()
		5: _orders()
		6: _procurement()
		7: _movements()
		8: _reports()
		9: _routing_master()
		10: _work_center_master()
		11: _production_versions()
		STANDARDS_PAGE: _production_standards()
		SCHEDULE_PAGE:
			_summary.text = "Drag planned bars to move them in time or assign an eligible machine. Double-click for details. Thin bars show actual execution."
			_board.refresh()
			if not _board.picked.is_empty():
				_select_board_order(_board.picked)
			return
	var old_key := String(_selected.get("key", ""))
	if _rows.has(old_key):
		_rows[old_key].select(0)
		_selected = _rows[old_key].get_metadata(0)
	_detail.text = String(_selected.get("detail", "Select a row to see transaction or master-data details."))


func _header(columns: Array, summary: String) -> TreeItem:
	_table.columns = columns.size()
	for index in columns.size():
		_table.set_column_title(index, columns[index])
		_table.set_column_expand(index, true)
		_table.set_column_expand_ratio(index, 1)
		_table.set_column_clip_content(index, true)
		var minimum := {"Material": 116, "Description": 114, "Need date": 98, "MRP element": 124,
			"Receipt": 65, "Demand": 66, "Projected": 80, "Short": 54, "Document": 84, "Date": 98,
			"Element data": 120, "Requirement": 80, "Available qty": 90, "Start / order": 98, "Exception": 230,
			"Rec./reqd.": 90, "Lot size": 120, "Uncovered from": 104, "Top exception": 240, "Safety": 60, "Available": 86, "PlOrds": 58, "Exc.": 40}
		_table.set_column_custom_minimum_width(index, int(minimum.get(columns[index], 50)))
	_summary.text = summary
	return _table.create_item()


func _row(parent: TreeItem, values: Array, metadata: Dictionary = {}, filter: bool = true) -> TreeItem:
	var words := PackedStringArray()
	for value in values:
		words.append(str(value))
	var query := _search.text.strip_edges().to_lower()
	if filter and not query.is_empty() and not " ".join(words).to_lower().contains(query):
		return null
	var row := _table.create_item(parent)
	for index in mini(words.size(), _table.columns):
		row.set_text(index, words[index])
		if words[index] in ["In Progress", "Received", "Completed"]:
			row.set_custom_color(index, Color("#176b47"))
		elif words[index] in ["Late", "Cancelled", "Short"]:
			row.set_custom_color(index, Color("#a14532"))
	row.set_metadata(0, metadata)
	if metadata.has("key"):
		_rows[metadata.key] = row
	return row


func _on_select() -> void:
	var row := _table.get_selected()
	if row != null:
		_selected = row.get_metadata(0)
		_detail.text = String(_selected.get("detail", ""))


func _on_activate() -> void:
	if _page == 4 and _mrp_material.is_empty() and _selected.has("material"):
		_open_material(_selected.material)


func _dashboard() -> void:
	var b := line.erp
	var active := PackedStringArray()
	var root := _header(["Indicator", "Current value"], "LINE-01  ·  Live operational overview")
	var open_orders := 0
	var pending_po := 0
	var shortages := {}
	for item in b.orders.values():
		if item.status in b.OPEN:
			open_orders += 1
		if item.status == "In Progress":
			active.append("%s · %s · %s" % [item.id, item.code, item.route.description])
		if item.status == "Created":
			shortages.merge(b.shortages(item), true)
	for po in b.purchases.values():
		pending_po += int(po.status != "Received")
	for pair in [
		["Active orders", " / ".join(active) if not active.is_empty() else "—"],
		["Today's production", _qty(b.today_kg()) + " kg received"],
		["Open orders / purchases", "%d orders / %d purchase orders" % [open_orders, pending_po]],
		["Material shortages", ", ".join(PackedStringArray(shortages.keys())) if not shortages.is_empty() else "—"],
		["Finished warehouse", "%d / %d pallets · %s kg" % [line.warehouse_count(), line.warehouse.size(), _qty(line.warehouse_mass())]],
		["Setup remaining", "%s s coating / %s s packing" % [_qty(b.coat_remaining), _qty(b.pack_remaining)]],
		["Shortage idle time", "%s sim min (sampled)" % _qty(b.delay_seconds / 60.0)],
		["Run utilization", _utilization()]
	]:
		_row(root, pair)


func _materials() -> void:
	var b := line.erp
	var root := _header(["Material", "Description", "Type", "Unit", "Supply", "Location", "Lot size", "Status"],
		"Search across material codes, categories and descriptions.")
	for code in b.catalog.materials:
		var item: Dictionary = b.catalog.materials[code]
		var settings: Dictionary = b.catalog.planning(code)
		var detail := "%s · Safety stock %s %s · Lead %s min · Lot size %s · Safety time %s min" % [item.name, _qty(item.minimum),
			item.unit, _qty(item.lead / 60.0), b.catalog.lot_caption(code), _qty(settings.safety_time / 60.0)]
		if item.type == "FERT":
			detail += "\n%s / %s · %s · Pack %s kg × %d = %s kg per shipping box\n%d boxes per pallet · %s kg net per pallet · BOM %s · %s\nShelf life %d days · Standard batch %s kg" % [
				item.coating, item.wafer, item.family, _qty(item.pack_kg), item.packs_per_box, _qty(item.box_kg),
				item.boxes_per_pallet, _qty(item.boxes_per_pallet * item.box_kg), item.bom, "%d production versions" % b.catalog.production_versions.values().filter(
					func(row: Dictionary) -> bool: return row.product == code).size(), item.shelf_days, _qty(item.batch_kg)]
			if line.erp.explicit_planning:
				var operations := PackedStringArray()
				var feeders := PackedStringArray()
				for material in b.catalog.manufacturing_flow(code):
					var stage := Scheduling.stage_for(b.catalog, material)
					operations.append("%s %s" % [stage.capitalize(), material])
					if stage in ["spread", "gum_coat"]:
						var inputs := PackedStringArray()
						for part in b.catalog.boms[material].parts:
							inputs.append(part.code)
						feeders.append("%s needs %s" % [material, " + ".join(inputs)])
				detail += "\nIndependent orders · " + "  /  ".join(operations)
				if not feeders.is_empty():
					detail += "\n" + "\n".join(feeders)
				var options := PackedStringArray()
				for route in Scheduling.alternatives(b.catalog, code, 1.0, b.now):
					var op: Dictionary = route.operations[0]
					var label := "%s · %s" % [op.description, b.catalog.Standards.caption(op.get("standard", {}))]
					if op.available and label not in options:
						options.append(label)
				detail += "\nPackaging alternatives · " + ", ".join(options)
		if item.has("dimensions_mm"):
			detail += "\nCut dimensions %s mm · %s kg per piece" % [str(item.dimensions_mm), _qty(item.piece_kg)]
		_row(root, [code, item.name, item.type, item.unit, item.procurement, item.location, b.catalog.lot_caption(code),
			"Active" if item.active else "Inactive"],
			{"key": code, "code": code, "location": item.location, "detail": detail})


func _bom() -> void:
	var root := _header(["Material hierarchy", "Description", "Qty / base", "Unit", "Scrap %", "Version"],
		"Expand a product and its semi-finished components. Quantities are per parent BOM base.")
	var catalog := line.erp.catalog
	for code in catalog.boms:
		if catalog.materials[code].type != "FERT":
			continue
		var title: String = catalog.materials[code].name
		var query := _search.text.strip_edges().to_lower()
		if not query.is_empty() and not (code + " " + title).to_lower().contains(query):
			continue
		_bom_node(root, code, "", 0.0, 0.0, code, {})


func _bom_node(parent: TreeItem, code: String, parent_code: String, quantity: float, scrap: float,
		path: String, seen: Dictionary) -> void:
	var catalog := line.erp.catalog
	var bom: Dictionary = catalog.boms.get(code, {})
	var name: String = catalog.materials[code].name
	var key := path
	var row := _row(parent, [code, name, _qty(quantity) if not parent_code.is_empty() else _qty(bom.get("base", 0.0)),
		catalog.materials[code].unit, _qty(scrap * 100.0), "v%d%s" % [bom.get("version", 0), "" if bom.get("active", true) else " · inactive"]],
		{"key": key, "code": code, "parent": parent_code, "quantity": quantity, "scrap": scrap,
			"detail": "%s · %s\nParent %s · BOM base %s %s" % [code, name, parent_code, _qty(bom.get("base", 0.0)), catalog.materials[code].unit]}, false)
	if seen.has(code):
		return
	seen[code] = true
	for part in bom.get("parts", []):
		_bom_node(row, part.code, code, part.qty, part.scrap, path + "/" + part.code, seen)
	seen.erase(code)
	row.collapsed = not bom.is_empty()


func _inventory() -> void:
	var b := line.erp
	var root := _header(["Material", "Description", "Location", "On hand", "Reserved", "Available", "In transit", "Unit"],
		"Raw stock comes from the ledger. WIP and finished goods come from physical buffers and pallets.")
	for code in b.catalog.materials:
		var item: Dictionary = b.catalog.materials[code]
		if item.procurement != "External":
			continue
		var reserve := float(b.reservations.get(code, 0.0))
		for location in b.RAW_LOCATIONS:
			var qty := b.stock(code, location)
			var allocated := minf(reserve, qty)
			reserve -= allocated
			if qty <= Book.EPS and location != "RM-WH":
				continue
			_inventory_row(root, code, location, qty, allocated)
	for location in Book.SFG_LOCATIONS:
		for code in b.balances[location]:
			var qty := b.stock(code, location)
			if qty > Book.EPS:
				_inventory_row(root, code, location, qty, minf(qty, b.reservations.get(code, 0.0)))
	var packaging_wip := line.erp_pack_wip()
	var upstream_wip := line.erp_wip()
	for code in packaging_wip:
		upstream_wip[code] -= packaging_wip[code]
	for pair in [["WIP", upstream_wip], ["PACK-WIP", packaging_wip], ["FG-WH", line.erp_fg()]]:
		for code in pair[1]:
			if pair[1][code] > Book.EPS:
				_inventory_row(root, code, pair[0], pair[1][code], pair[1][code] if pair[0] in ["WIP", "PACK-WIP"] else 0.0)


func _inventory_row(root: TreeItem, code: String, location: String, qty: float, reserved: float) -> void:
	var item: Dictionary = line.erp.catalog.materials[code]
	var moving := location == "TRANSIT"
	_row(root, [code, item.name, location, _qty(0.0 if moving else qty), _qty(reserved),
		_qty(0.0 if moving else maxf(0.0, qty - reserved)), _qty(qty if moving else 0.0), item.unit],
		{"key": code + location, "code": code, "location": location,
			"detail": "%s · %s · %s %s\nReservations are assigned across locations for display." % [
				code, line.erp.catalog.locations[location], _qty(qty), item.unit]})


func _mrp() -> void:
	if not line.erp.explicit_planning:
		_mrp_flat()
	elif _mrp_material.is_empty():
		_mrp_coverage()
	else:
		_mrp_material_list(_mrp_material)


func _mrp_note() -> String:
	var summary := plan.summary
	if summary.is_empty():
		return "Create demand or an order, then run MRP. Convert selected buy or make proposals explicitly."
	return "%d shortage materials   ·   %d buy proposals   ·   %d make proposals   ·   %d late risks   ·   %d/%d covered   ·   %d exceptions" % [
		summary.shortages.size(), summary.buy, summary.make, summary.late, summary.covered, summary.requirements, plan.exceptions.size()]


## Collective view, like MD06 / Monitor Material Coverage: one line per planned material, worst exception first.
func _mrp_coverage() -> void:
	var root := _header(["Material", "Description", "Lot size", "Safety", "Available", "Uncovered from",
		"PlOrds", "Exc.", "Top exception"], _mrp_note() + "\nDouble-click a material for its stock/requirements list.")
	_table.set_column_expand_ratio(8, 3)
	var catalog := line.erp.catalog
	var lines: Array = plan.coverage.values()
	lines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.severity != b.severity:
			return a.severity > b.severity
		var ua: float = a.uncovered_from if a.uncovered_from >= 0.0 else INF
		var ub: float = b.uncovered_from if b.uncovered_from >= 0.0 else INF
		return ua < ub if ua != ub else a.code < b.code)
	for entry in lines:
		var item: Dictionary = catalog.materials[entry.code]
		if _exceptions_only and entry.exceptions == 0:
			continue
		if not _family.text.is_empty() and not String(item.get("family", "")).to_lower().contains(_family.text.to_lower()):
			continue
		if _date_filter.text.is_valid_float() and (entry.uncovered_from < 0.0 or entry.uncovered_from > _date_filter.text.to_float() * 60.0):
			continue
		var settings: Dictionary = catalog.planning(entry.code)
		var row := _row(root, [entry.code, item.name, entry.lot, _qty(entry.safety), _qty(entry.available),
			Book.date(entry.uncovered_from) if entry.uncovered_from >= 0.0 else "Covered", entry.planned, entry.exceptions, entry.message],
			{"key": entry.code, "material": entry.code, "code": entry.code,
				"detail": "%s · %s · %s %s available · safety stock %s · safety time %s min\nLot size %s (%s) · %d requirements · %d receipts · %d planned orders" % [
					entry.code, item.name, _qty(entry.available), entry.unit, _qty(entry.safety), _qty(settings.safety_time / 60.0),
					entry.lot, catalog.LOT_PROCEDURES[settings.lot_size], entry.requirements, entry.receipts, entry.planned]})
		_severity_color(row, entry.severity, 8)


## Single-material view, like MD04: dated MRP elements with a running available quantity.
func _mrp_material_list(code: String) -> void:
	var catalog := line.erp.catalog
	var item: Dictionary = catalog.materials.get(code, {})
	var settings: Dictionary = catalog.planning(code)
	var entry: Dictionary = plan.coverage.get(code, {})
	var note := "%s · %s · %s · Lot size %s · Safety stock %s %s · Safety time %s min · Lead %s min · Available %s" % [
		code, item.get("name", ""), item.get("type", ""), catalog.lot_caption(code), _qty(item.get("minimum", 0.0)), item.get("unit", ""),
		_qty(settings.safety_time / 60.0), _qty(item.get("lead", 0.0) / 60.0), _qty(entry.get("available", 0.0))]
	var root := _header(["Date", "MRP element", "Element data", "Rec./reqd.", "Available", "Start / order", "Exception"],
		note + "\nPlOrd.* and PurRqs* are firmed: MRP keeps them unchanged.")
	_table.set_column_expand_ratio(6, 3)
	var i := 0
	for row in plan.rows:
		i += 1
		if row.code != code:
			continue
		if _proposals_only and row.proposal.is_empty():
			continue
		if _exceptions_only and String(row.get("exception", "")).is_empty():
			continue
		if _date_filter.text.is_valid_float() and float(row.date) > _date_filter.text.to_float() * 60.0:
			continue
		var proposal: Dictionary = plan.proposals.get(row.proposal, {})
		var data: String = row.get("number", "")
		if row.kind == "Requirement":
			data = row.get("source", row.doc)
		elif not proposal.is_empty():
			data = "%s · for %s" % [proposal.number, ", ".join(PackedStringArray(proposal.get("docs", [proposal.doc])))]
		elif row.element == "Error":
			data = row.kind
		var start := ""
		if not proposal.is_empty():
			var planned: float = proposal.get("start", row.date)
			start = Book.date(planned) if planned >= 0.0 else "before start"
		elif row.action_date >= 0.0:
			start = Book.date(row.action_date)
		var quantity := ""
		if row["out"] > 0:
			quantity = "-" + _qty(row["out"])
		elif row["in"] > 0 and row.kind != "Unreserved stock":
			quantity = _qty(row["in"])
		var when := Book.date(row.date) if row.date >= 0.0 else "before start"
		var tree_row := _row(root, [when, row.element, data, quantity, _qty(row.projected), start, row.get("exception", "")],
			{"key": row.proposal if not row.proposal.is_empty() else str(i), "proposal": row.proposal, "code": code,
				"number": proposal.get("number", ""), "detail": _mrp_row_detail(row, proposal)})
		_severity_color(tree_row, int(row.get("severity", 0)), 6)


func _mrp_row_detail(row: Dictionary, proposal: Dictionary) -> String:
	if proposal.is_empty():
		var text := "%s · %s · %s" % [row.element, row.kind, row.get("source", row.doc)]
		if row.kind == "Requirement":
			text += "\nRequired %s for %s · short before new proposals %s" % [Book.date(row.date), row.get("source", row.doc), _qty(row.short)]
		if not String(row.get("exception", "")).is_empty():
			text += "\n" + row.exception
		return text
	var lines := PackedStringArray()
	lines.append("%s %s · %s · %s %s%s" % ["Planned order" if proposal.type == "Make" else "Purchase requisition", proposal.number,
		proposal.code, _qty(proposal.get("quantity", proposal.qty)), "boxes" if proposal.get("boxes", 0) > 0 else line.erp.catalog.materials[proposal.code].unit,
		" · FIRMED" if proposal.firmed else ""])
	if proposal.type == "Make":
		lines.append("Start %s · available %s · %s on %s" % [Book.date(proposal.start), Book.date(proposal.finish),
			proposal.get("version", ""), proposal.get("center", "")])
	else:
		lines.append("Order by %s · delivery %s · supplier %s" % [Book.date(proposal.start), Book.date(proposal.finish), proposal.get("supplier", "")])
	lines.append("Covers " + ", ".join(PackedStringArray(proposal.get("docs", [proposal.doc]))))
	for message in proposal.get("exceptions", []):
		lines.append("⚠ " + message)
	return "\n".join(lines)


func _severity_color(row: TreeItem, severity: int, column: int) -> void:
	if row == null or severity <= 0:
		return
	row.set_custom_color(column, Color("#a14532") if severity >= 3 else Color("#9a6a00") if severity == 2 else Color("#50677b"))
	if severity >= 3:
		row.set_custom_color(0, Color("#a14532"))


## The original flat list, kept for the legacy combined-route planning mode.
func _mrp_flat() -> void:
	var root := _header(["Material", "Description", "Need date", "MRP element", "Receipt", "Demand", "Projected", "Short", "Document"], _mrp_note())
	var b := line.erp
	var i := 0
	for row in plan.rows:
		i += 1
		if _proposals_only and row.proposal.is_empty():
			continue
		if not _family.text.is_empty() and not String(row.family).to_lower().contains(_family.text.to_lower()):
			continue
		if _date_filter.text.is_valid_float() and float(row.date) > _date_filter.text.to_float() * 60.0:
			continue
		_row(root, [row.code, b.catalog.materials[row.code].name, Book.date(row.date), row.kind,
			_qty(row["in"]), _qty(row["out"]), _qty(row.projected), _qty(row.short), row.doc],
			{"key": row.proposal if not row.proposal.is_empty() else str(i), "proposal": row.proposal,
				"detail": "%s · %s · need %s\nAction date %s · unit %s · %s" % [
					row.kind, row.doc, Book.date(row.date), Book.date(row.action_date) if row.action_date >= 0 else "Past / none",
					b.catalog.materials[row.code].unit, "Short / late risk" if row.short > 0 else "Covered"]})


func _open_material(code: String) -> void:
	if not code.is_empty() and not plan.coverage.has(code):
		notice("Select a material in the coverage list. Run MRP first.")
		return
	_mrp_material = code
	_selected = {}
	_refresh_actions()
	_render()


func _orders() -> void:
	var root := _header(["Order", "Material", "Work center / route", "Planned", "Received", "Priority", "Status"],
		"Each release reserves immediate BOM components. Semi-finished goods use kilograms and packaging orders use shipping boxes.")
	for order in line.erp.orders.values():
		if order.has("stage"):
			_row(root, [order.id, order.code, order.center, "%s %s" % [_qty(order.quantity), order.unit],
				"%s %s" % [_qty(order.received), order.unit], order.priority, order.status],
				{"key": order.id, "id": order.id, "detail": _stage_detail(order)})
			continue
		var missing := line.erp.shortages(order) if order.status == "Created" else {}
		var warning: String = "" if order.status == "Created" else order.warning
		if order.status in ["Created", "Released"]:
			var conflicts := line.route_conflicts(order)
			if not conflicts.is_empty():
				warning = "Queues behind " + ", ".join(conflicts)
		if not missing.is_empty():
			warning += ("\n" if not warning.is_empty() else "") + "Missing " + _amounts(missing)
		var detail := "%s · %s v%d · %s · BOM v%d\n%s sim min processing estimate · Planned %s to %s\n%s\nReceived %s kg · Packed %d boxes · WIP %s\nConsumed %s\n%s" % [
			order.id, order.route.id, order.route.version, order.version, order.recipe.bom_version, _qty(order.estimate / 60.0),
			Book.date(order.start), Book.date(order.finish), _operation_lines(order.route, order.get("progress", {})),
			_qty(order.received_kg), order.packed, _amounts(line.order_wip(order.id)), _amounts(order.consumed), warning]
		_row(root, [order.id, order.code, order.route.id, order.boxes, order.received, order.priority, order.status],
			{"key": order.id, "id": order.id, "detail": detail})


func _stage_detail(order: Dictionary) -> String:
	var gaps := line.erp.shortages(order) if order.status == "Created" else {}
	var auto_problem: String = order.get("auto_release_error", "") if order.status == "Created" and gaps.is_empty() else ""
	var upstream := PackedStringArray()
	for row in line.erp.orders.values():
		if order.id in row.get("pegs", []):
			upstream.append(row.id)
	var started := Book.date(order.started) if order.started >= 0.0 else "—"
	var finished := Book.date(order.completed) if order.completed >= 0.0 else "—"
	var produced: float = order.get("progress", {}).get(order.stage, 0.0)
	var queue := maxf(0.0, (order.started if order.started >= 0.0 else line.erp.now) - order.start)
	return ("%s · %s · %s · BOM v%d
Planned %s → %s · Actual %s → %s
"
		+ "Planned duration %.1f min · Planned setup %.1f min\n%s\n"
		+ "Released %s %s · Produced %.2f kg · Received %.2f kg · Remaining %.2f kg · Scrap %.2f kg
"
		+ "Components %s · Reserved %s · Consumed %s · WIP %s
"
		+ "Supply orders %s · Supplies %s · Queue %.1f min · Logistics %.1f min · Oven wait %.1f min · Material shortage %.1f min
%s") % [
		order.id, order.code, order.version, order.recipe.bom_version, Book.date(order.start), Book.date(order.finish),
		started, finished, order.estimate / 60, order.route.operations[0].get("setup_seconds", 0) / 60,
		line.standard_readout(StringName(order.route.operations[0].equipment), order), _qty(order.released_quantity), order.unit, produced, order.received_kg,
		maxf(0.0, order.recipe.target - produced), order.scrapped, _amounts(order.recipe.needs),
		_amounts(order.remaining), _amounts(order.consumed), _amounts(line.order_wip(order.id)), ", ".join(upstream),
		", ".join(PackedStringArray(order.pegs)), queue / 60.0, order.logistics_seconds / 60.0,
		order.oven_wait_seconds / 60.0, order.material_wait_seconds / 60.0,
		" ".join(PackedStringArray([order.delay, "Missing " + _amounts(gaps) if not gaps.is_empty() else "",
			auto_problem, Scheduling.dependency_warning(line.erp, order)]))]


func _select_board_order(id: String) -> void:
	var order: Dictionary = line.erp.orders.get(id, {})
	if order.has("stage"):
		_selected = {"id": id, "key": id}
		_detail.text = _stage_detail(order)


func _open_order(id: String) -> void:
	if id.is_empty():
		notice("Select a scheduled order.")
		return
	_set_page(5)
	if _rows.has(id):
		_rows[id].select(0)
		_on_select()


func _check_components() -> void:
	var order: Dictionary = line.erp.orders.get(_selected.get("id", ""), {})
	if order.get("status") != "Created":
		notice("Select a planned order to check its components.")
		return
	var missing := line.erp.shortages(order)
	notice("All immediate components are available." if missing.is_empty() else "Missing " + _amounts(missing))


func _component_inventory() -> void:
	var order: Dictionary = line.erp.orders.get(_selected.get("id", ""), {})
	if order.is_empty():
		notice("Select an order first.")
		return
	var gaps := line.erp.shortages(order) if order.status == "Created" else {}
	var code: String = gaps.keys()[0] if not gaps.is_empty() else order.recipe.needs.keys()[0]
	_set_page(3)
	_search.text = code
	_render()


func _open_supply_order() -> void:
	var id := String(_selected.get("id", ""))
	var options := []
	for order in line.erp.orders.values():
		if id in order.get("pegs", []):
			options.append([order.id, "%s · %s · %s" % [order.id, order.code, order.status]])
	if options.is_empty():
		notice("No upstream orders are pegged to the selection.")
	elif options.size() == 1:
		_open_order(options[0][0])
	else:
		_form("Open pegged supply", [["order", "Upstream order", options]], func(v: Dictionary) -> String:
			_open_order(v.order)
			return "")


func _peg_order() -> void:
	var id := String(_selected.get("id", ""))
	if id.is_empty():
		notice("Select the upstream production order first.")
		return
	_form("Peg supply from " + id, [["parent", "Downstream order ID", ""]], func(v: Dictionary) -> String:
		return Scheduling.peg(line.erp, id, v.parent))


func _procurement() -> void:
	var b := line.erp
	if _suppliers:
		var root := _header(["Supplier", "Name", "Lead min", "Minimum", "Price / unit"], "Fictional supplier master")
		for supplier in b.catalog.suppliers.values():
			_row(root, [supplier.id, supplier.name, _qty(supplier.lead / 60.0), supplier.minimum, supplier.price],
				{"key": supplier.id, "detail": ", ".join(PackedStringArray(supplier.codes))})
		return
	var root := _header(["PO", "Supplier", "Material", "Ordered", "Received", "Expected", "Status"],
		"Open purchases receive automatically when simulated time reaches the delivery date.")
	for po in b.purchases.values():
		_row(root, [po.id, po.supplier, po.code, _qty(po.qty), _qty(po.received), Book.date(po.due), po.status],
			{"key": po.id, "detail": "%s · %s · %s per %s" % [po.id, b.catalog.suppliers[po.supplier].name, _qty(po.price), b.catalog.materials[po.code].unit]})


func _movements() -> void:
	var root := _header(["Movement", "Time", "Material", "Quantity", "From → To", "Type", "Document"],
		"Latest 200 postings. Continuous process flows are grouped in 15 simulated-second windows.")
	for row in line.erp.journal():
		_row(root, [row.id, Book.date(row.time), row.code, _qty(row.qty) + " " + row.unit,
			row["from"] + " → " + row.to, row.type, row.document],
			{"key": row.id, "detail": "%s · %s through %s\n%s" % [row.document, Book.date(row.time), Book.date(row.last), row.reason]})


func _reports() -> void:
	if _schedule_report:
		var workload := {}
		var late := 0
		for order in line.erp.orders.values():
			if not order.has("stage") or order.status == "Cancelled":
				continue
			if order.status in Book.OPEN:
				workload[order.center] = float(workload.get(order.center, 0.0)) + order.estimate / 60.0
			late += int(_is_late(order))
		var schedule_root := _header(["Order", "Material", "Center", "Plan start", "Actual start", "Plan finish",
			"Actual finish", "Queue min", "Timing"], "%d late · Open workload in minutes %s" % [late, _amounts(workload)])
		for order in line.erp.orders.values():
			if not order.has("stage") or order.status == "Cancelled":
				continue
			_row(schedule_root, [order.id, order.code, order.center, Book.date(order.start),
				Book.date(order.started) if order.started >= 0 else "—", Book.date(order.finish),
				Book.date(order.completed) if order.completed >= 0 else "—",
				_qty(maxf(0.0, (order.started if order.started >= 0 else line.erp.now) - order.start) / 60.0),
				"Late" if _is_late(order) else order.status],
				{"key": order.id, "detail": _stage_detail(order)})
		return
	var root := _header(["Sample time", "Today's FG kg", "Stock kg", "Active order", "Short orders", "Delay min"],
		"Recorded once per simulated minute. Current utilization  " + _utilization())
	for row in line.erp.history.slice(maxi(0, line.erp.history.size() - 200)):
		_row(root, [Book.date(row.time), _qty(row.kg), _qty(row.warehouse), row.order, row.shortages, _qty(row.delay / 60.0)])


func _is_late(order: Dictionary) -> bool:
	return (order.completed if order.completed >= 0 else line.erp.now) > order.finish


func _utilization() -> String:
	var b := line.erp
	var parts := PackedStringArray()
	for center in b.catalog.work_centers.values():
		parts.append("%s %d%%" % [center.description,
			roundi(100.0 * b.utilization.get(center.equipment, 0.0) / maxf(1.0, b.now))])
	return " · ".join(parts)


func _routing_master() -> void:
	var catalog := line.erp.catalog
	var root := _header(["Routing", "Description", "Version", "Machines", "Validity"],
		"Stage routes execute independently. The WAFER templates retain their full operation sequences for reference.")
	for route in catalog.routings.values():
		var resolved: Dictionary = route.duplicate(true)
		var machine_names := PackedStringArray()
		for op in resolved.operations:
			var center: Dictionary = catalog.work_centers[op.work_center]
			machine_names.append(center.description)
			op.merge({"description": center.description, "technical": center.technical, "available": center.available})
			if resolved.operations.size() == 1:
				for version in catalog.production_versions.values():
					if version.routing != route.id:
						continue
					var standard := catalog.Standards.resolve(catalog, version.product, op, line.erp.now, route.id, version.id)
					if standard.error.is_empty():
						op.standard = standard.standard
					break
		var versions := PackedStringArray()
		for version in catalog.production_versions.values():
			if version.routing == route.id and version.active:
				versions.append("%s (%s)" % [version.id, version.product])
		_row(root, [route.id, route.description, int(route.version), " → ".join(machine_names), _validity(route)],
			{"key": route.id, "detail": _operation_lines(resolved, {}, true) + "\nVersions · " + ", ".join(versions)})


func _work_center_master() -> void:
	var root := _header(["Center", "Equipment", "Operation", "Technical", "Availability", "Order"],
		"Master availability and live resource commitments are shown separately.")
	for center in line.erp.catalog.work_centers.values():
		var id := StringName(center.equipment)
		var order := line.order_at(id)
		var part := line.layout.objects[id]
		_row(root, [center.id, center.description, center.operation.capitalize(), _technical(center.technical),
			"Available" if center.available else "Offline", order.get("id", "—")], {"key": center.id,
			"detail": "%s · %s · Grid (%d, %d) · %d × %d m\nDesign limits %s\nFamilies %s · Coatings %s\nLive state %s · Assigned %s\nEligible materials %s" % [
				center.id, center.description, part.cell.x, part.cell.y, part.footprint().size.x, part.footprint().size.y,
				_technical(center.technical), ", ".join(PackedStringArray(center.categories)),
				"All family coatings" if center.coatings.is_empty() else ", ".join(PackedStringArray(center.coatings)),
				line.work_center_status(id), order.get("id", "—"), ", ".join(PackedStringArray(center.materials))]})


func _production_versions() -> void:
	var catalog := line.erp.catalog
	var root := _header(["Version", "Product", "BOM", "Routing", "Lot size", "Validity"],
		"Search by SKU or production version. Validity uses simulated dates.")
	for version in catalog.production_versions.values():
		var route: Dictionary = catalog.routings[version.routing]
		_row(root, [version.id, version.product, "v%d" % version.bom_version,
			"%s v%d" % [version.routing, version.routing_version], "%s–%s %s" % [_qty(version.min_quantity), _qty(version.max_quantity), version.lot_unit],
			_validity(version)], {"key": version.id, "detail": "%s · %s\n%s\n%s" % [
				version.product, catalog.materials[version.product].name, route.description, _validity(version)]})


func _production_standards() -> void:
	var catalog := line.erp.catalog
	var root := _header(["Material", "Description", "Operation", "Work Center", "Capability", "Standard"],
		"Search by material, product, operation, or work center. Select a row for batch limits, yield, and setup.")
	var product_matches := {}
	var query := _search.text.strip_edges().to_lower()
	if not query.is_empty():
		for product in catalog.materials.values():
			if product.type == "FERT" and (product.code + " " + product.name).to_lower().contains(query):
				for code in catalog.manufacturing_flow(product.code):
					product_matches[code] = true
	for material in catalog.materials.values():
		var stage := Scheduling.stage_for(catalog, material.code)
		if stage.is_empty() or (not _family.text.is_empty() and not material.get("family", "").to_lower().contains(_family.text.to_lower())):
			continue
		var alternatives := Scheduling.alternatives(catalog, material.code, 1.0, line.erp.now)
		for center in catalog.work_centers.values():
			if center.operation != stage:
				continue
			var standard := {}
			var state := "Ineligible"
			var status := "The work center does not list this material."
			if material.code in center.materials:
				state = "Unavailable"
				status = "No active production version or standard at the current date."
				for route in alternatives:
					var op: Dictionary = route.operations[0]
					if op.work_center != center.id:
						continue
					standard = op.get("standard", {})
					state = "Eligible" if op.available else "Unavailable"
					status = op.get("standard_error", "Resource is offline." if not op.available else "Eligible for scheduling.")
					if op.available:
						break
			var caption := "—" if standard.is_empty() else catalog.Standards.caption(standard)
			var detail := "%s · %s\n%s" % [center.description, material.get("family", ""), status]
			if not standard.is_empty():
				detail += "\n%s v%d · %s · Yield %.1f%% · Planned scrap %.1f%%\nBase setup %.1f s. Additional cleaning depends on the preceding material." % [
					standard.id, standard.version, caption, standard.yield_factor * 100, standard.scrap_expectation * 100, standard.setup_seconds]
				if standard.model == "batch":
					detail += "\nMinimum batch %.1f kg" % standard.min_batch_kg
			_row(root, [material.code, material.name, stage.capitalize(), center.description, state, caption],
				{"key": "%s/%s" % [material.code, center.id], "detail": detail}, not product_matches.has(material.code))


func _reload_standards() -> void:
	var problem := line.erp.catalog.reload_standards()
	if problem.is_empty():
		line.erp.changed()
		notice("Reloaded production standards and cleaning rules. Re-select the version on affected drafts.")
		_render()
	else:
		notice(problem)


func _example_demands() -> void:
	var book := line.erp
	var count := 0
	for example in book.catalog.planning_examples.values():
		for row in example.demands:
			if book.demands.values().any(func(item: Dictionary) -> bool:
				return item.code == row.code and item.get("example") == example.id):
				continue
			var created := book.create_demand(row.code, row.boxes, book.now + row.due)
			if created.error.is_empty():
				book.demands[created.id].example = example.id
				count += 1
	_run_mrp()
	notice("Added %d example demands. Convert the proposals to plan their orders." % count)


func _validity(row: Dictionary) -> String:
	if not row.active:
		return "Inactive"
	return "%s – %s" % [Book.date(row.valid_from), Book.date(row.valid_to) if row.valid_to > 0 else "open"]


func _operation_lines(route: Dictionary, progress: Dictionary = {}, show_handling: bool = false) -> String:
	var rows := PackedStringArray()
	for op in route.operations:
		var done := " · %s kg processed" % _qty(progress.get(op.type, 0.0)) if not progress.is_empty() else ""
		rows.append("%02d %s · %s%s%s" % [op.number, op.description, line.erp.catalog.Standards.caption(op.standard) if op.has("standard") else _technical(op.technical), done,
			" · Offline" if not op.get("available", true) else ""])
		if show_handling:
			rows.append("    %s → %s · %s" % [op.get("input", ""), op.get("output", ""), op.get("handling", "")])
	return "\n".join(rows)


func _technical(technical: Dictionary) -> String:
	var parts := PackedStringArray()
	var units := {"rate": "kg/h max", "batch_kg": "kg/batch", "cycle_seconds": "s/cycle",
		"input_kg": "kg intake", "output_kg": "kg outfeed", "internal_kg": "kg internal", "setup_seconds": "s legacy setup"}
	for field in units:
		if technical.has(field):
			parts.append("%s %s" % [_qty(technical[field]), units[field]])
	return " · ".join(parts)


func _select_order_version() -> void:
	var order: Dictionary = line.erp.orders.get(_selected.get("id", ""), {})
	if order.get("status") != "Created":
		notice("Select a created order to change its production version.")
		return
	_production_form(order)


func _highlight_order() -> void:
	var id: String = _selected.get("id", "")
	if id.is_empty():
		notice("Select an order first.")
		return
	close()
	route_requested.emit(id)


func _production_form(existing: Dictionary = {}) -> void:
	if line.erp.explicit_planning:
		_stage_form(existing)
		return
	var fields := [["version", "Production version", []]]
	if existing.is_empty():
		fields = [["code", "Finished material", "FG-1002"], ["boxes", "Shipping boxes", "13"],
			["start", "Start after sim minutes", "0"], ["priority", "Priority 1–9", "5"]] + fields
	_form("Create production order" if existing.is_empty() else "Select production version", fields,
		func(v: Dictionary) -> String:
			if v.version.is_empty():
				return "Choose an eligible production version."
			if not existing.is_empty():
				return line.erp.select_version(existing.id, v.version)
			return _result(line.erp.create_order(v.code, v.boxes.to_int(),
				line.erp.now + _number(v.start) * 60.0, v.priority.to_int(), v.version)),
		func(inputs: Dictionary, preview: Label, refill: bool) -> void:
			_update_version_picker(inputs, preview, refill, existing))


func _stage_form(existing: Dictionary = {}) -> void:
	if not existing.is_empty() and not existing.has("stage"):
		notice("Cancel this legacy order and create a stage order.")
		return
	var fields := [["start", "Planned start at simulated minute", str(maxf(line.erp.now, existing.get("start", 0.0)) / 60.0)],
		["version", "Production version / work center", []]]
	if existing.is_empty():
		fields = [["code", "Manufactured material", []], ["quantity", "Kilograms for SFG / shipping boxes for FG", "10"],
			["priority", "Priority 1–9", "5"]] + fields
	_form("Schedule stage order" if existing.is_empty() else "Reschedule " + existing.id, fields,
		func(v: Dictionary) -> String:
			if v.version.is_empty():
				return "Choose an eligible work center."
			var start := _number(v.start) * 60.0
			if not existing.is_empty():
				return line.erp.reschedule(existing.id, start, v.version)
			return _result(line.erp.create_order(v.code, _number(v.quantity), start, v.priority.to_int(), v.version)),
		func(inputs: Dictionary, preview: Label, _refill: bool) -> void:
			_stage_preview(inputs, preview, existing))


func _stage_preview(inputs: Dictionary, preview: Label, existing: Dictionary) -> void:
	var book := line.erp
	if existing.is_empty() and inputs.code.item_count == 0:
		for material in book.catalog.materials.values():
			if not Scheduling.stage_for(book.catalog, material.code).is_empty():
				inputs.code.add_item("%s · %s" % [material.code, material.name])
				inputs.code.set_item_metadata(inputs.code.item_count - 1, material.code)
		inputs.code.select(0)
	var code: String = inputs.code.get_selected_metadata() if existing.is_empty() else existing.code
	var quantity: float = _number(inputs.quantity.text) if existing.is_empty() else existing.quantity
	var start := maxf(book.now, _number(inputs.start.text) * 60.0)
	var picker: OptionButton = inputs.version
	var wanted := String(picker.get_selected_metadata()) if picker.selected >= 0 else String(existing.get("version", ""))
	picker.clear()
	for route in Scheduling.alternatives(book.catalog, code, quantity, start):
		var op: Dictionary = route.operations[0]
		picker.add_item("%s · %s%s" % [op.description, route.production_version, " · " + op.get("standard_error", "Offline") if not op.available else ""])
		var index := picker.item_count - 1
		picker.set_item_metadata(index, route.production_version)
		picker.set_item_disabled(index, not op.available)
		if op.available and (picker.selected < 0 or picker.is_item_disabled(picker.selected) or wanted == route.production_version):
			picker.select(index)
	if picker.selected < 0 or picker.is_item_disabled(picker.selected):
		preview.text = "No eligible version for this material, quantity and date."
		return
	var data := Scheduling.assignment(book, code, quantity, start, String(picker.get_selected_metadata()), existing.get("id", ""))
	if not data.error.is_empty():
		preview.text = data.error
		return
	var slot := Scheduling.fit(book, code, quantity, start, String(picker.get_selected_metadata()), existing.get("id", ""))
	var available: float = slot.get("start", INF)
	if slot.error.is_empty():
		data = slot
	var gaps := book.shortages({"stage": data.recipe.stage, "route": data.route, "recipe": data.recipe})
	preview.text = "%s · %s
%.1f sim minutes estimated · first slot %s → %s
Immediate components %s
%s" % [
		data.center, book.catalog.Standards.caption(data.route.operations[0].standard), data.duration / 60.0,
		Book.date(available) if is_finite(available) else "Unavailable",
		Book.date(available + data.duration) if is_finite(available) else "Unavailable", _amounts(data.recipe.needs),
		"Available to reserve" if gaps.is_empty() else "Release blocked · " + _amounts(gaps)]


func _update_version_picker(inputs: Dictionary, preview: Label, refill: bool, existing: Dictionary) -> void:
	var book := line.erp
	var code: String = inputs.code.text.strip_edges() if existing.is_empty() else existing.code
	var boxes: int = inputs.boxes.text.to_int() if existing.is_empty() else existing.boxes
	var when: float = book.now + _number(inputs.start.text) * 60.0 if existing.is_empty() else maxf(book.now, existing.start)
	var picker: OptionButton = inputs.version
	if refill:
		var wanted := String(picker.get_selected_metadata()) if picker.selected >= 0 else String(existing.get("version", ""))
		picker.clear()
		for row in book.catalog.production_versions.values():
			if row.product != code:
				continue
			var route := book.catalog.route_for(code, boxes, when, row.id, false)
			if not route.error.is_empty():
				continue
			var unavailable: bool = route.operations.any(func(op: Dictionary) -> bool: return not op.available)
			picker.add_item("%s · %s%s" % [row.id, route.description, " · Offline" if unavailable else ""])
			var index := picker.item_count - 1
			picker.set_item_metadata(index, row.id)
			picker.set_item_disabled(index, unavailable)
			if not unavailable and (picker.selected < 0 or wanted == row.id):
				picker.select(index)
		if picker.selected >= 0 and picker.is_item_disabled(picker.selected):
			picker.select(-1)
	if picker.selected < 0:
		preview.text = "No available version for this SKU, lot size and date."
		return
	var recipe := book.catalog.recipe(code, boxes)
	if not recipe.error.is_empty():
		preview.text = recipe.error
		return
	var route := book.catalog.route_for(code, boxes, when, String(picker.get_selected_metadata()))
	if not route.error.is_empty():
		preview.text = route.error
		return
	var conflicts := line.route_conflicts({"id": existing.get("id", ""), "route": route})
	var shared := PackedStringArray()
	for operation in [route.operations[0], route.operations[3]]:
		var owner := line.order_at(StringName(operation.equipment))
		if not owner.is_empty():
			shared.append("%s · %s" % [operation.description, owner.id])
	preview.text = "BOM v%d · %s kg · %.1f sim min processing estimate\n%s\n%s%s" % [
		route.bom_version, _qty(recipe.target), book.catalog.estimate(recipe, route) / 60.0,
		_operation_lines(route), "Queues behind " + ", ".join(conflicts) if not conflicts.is_empty()
			else "No oven or coater conflict.",
		" Shared now · " + ", ".join(shared) if not shared.is_empty() else ""]



func _new_order() -> void:
	_production_form()


func _new_demand() -> void:
	_form("Create independent demand", [["code", "Finished material", "FG-1002"],
		["boxes", "Shipping boxes", "13"], ["due", "Due after sim minutes", "10"]],
		func(v: Dictionary) -> String:
			return _result(line.erp.create_demand(v.code, v.boxes.to_int(), line.erp.now + _number(v.due) * 60.0)))


func _new_purchase() -> void:
	_form("Submit purchase order", [["supplier", "Supplier ID", "SUP-02"],
		["code", "External material", "RM-COAT-1002"], ["qty", "Quantity in base unit", "13"]],
		func(v: Dictionary) -> String: return _result(line.erp.purchase(v.supplier, v.code, _number(v.qty))))


func _priority() -> void:
	var id := String(_selected.get("id", ""))
	var order: Dictionary = line.erp.orders.get(id, {})
	if order.is_empty() or order.status not in ["Created", "Released"]:
		notice("Select a pending order.")
		return
	_form("Schedule " + id, [["priority", "Priority 1–9", str(order.priority)],
		["start", "Planned start at sim minute", _qty(order.start / 60.0)]],
		func(v: Dictionary) -> String:
			var start := _number(v.start) * 60.0
			if not is_finite(start) or start < 0.0:
				return "Enter a nonnegative simulated minute."
			if order.has("stage") and not is_equal_approx(start, float(order.start)):
				var conflict := line.erp.reschedule(id, start)
				if not conflict.is_empty():
					return conflict
			var error := line.erp.prioritize(id, v.priority.to_int())
			if error.is_empty() and not order.has("stage"):
				order.finish += start - order.start
				order.start = start
			return error)


func _setup() -> void:
	var b := line.erp
	var alternate: Dictionary = b.catalog.center_at(&"Coater02")
	_form("Setup times for future releases", [["coat", "Coater 01 · sim minutes", _qty(b.coat_setup_seconds / 60.0)],
		["alternate", "Coater 02 · sim minutes", _qty(alternate.technical.setup_seconds / 60.0)],
		["pack", "Packaging · sim minutes", _qty(b.pack_setup_seconds / 60.0)]],
		func(v: Dictionary) -> String:
			var coat := _number(v.coat)
			var coat2 := _number(v.alternate)
			var pack := _number(v.pack)
			for duration in [coat, coat2, pack]:
				if not Line.Settings.Master.number(duration, 0, 1440):
					return "Enter 0–1440 simulated minutes."
			b.coat_setup_seconds = coat * 60.0
			b.pack_setup_seconds = pack * 60.0
			b.catalog.center_at(&"Coater").technical.setup_seconds = b.coat_setup_seconds
			b.catalog.center_at(&"Packer").technical.setup_seconds = b.pack_setup_seconds
			alternate.technical.setup_seconds = coat2 * 60.0
			b.changed()
			return "")


func _order_action(action: String) -> void:
	var id := String(_selected.get("id", ""))
	if id.is_empty():
		notice("Select a production order.")
		return
	var result := line.erp.release(id) if action == "release" else line.erp.transition(id, action)
	notice("Updated " + id if result.is_empty() else result)
	_render()


func _confirm_order(status: String) -> void:
	var id := String(_selected.get("id", ""))
	if id.is_empty():
		notice("Select a production order.")
		return
	_form("Cancel " + id + " and release its reservation?", [],
		func(_v: Dictionary) -> String: return line.erp.transition(id, status))


func _transfer() -> void:
	_form("Post location transfer", [["code", "Material", _selected.get("code", "RM-FLOUR")],
		["qty", "Quantity in base unit", "25"], ["source", "From location", "RM-WH"],
		["target", "To location", "RM-STAGE"], ["reason", "Reason", "Manual replenishment"]],
		func(v: Dictionary) -> String:
			return line.erp.manual_transfer(v.code, _number(v.qty), v.source, v.target, v.reason))


func _adjust() -> void:
	_form("Adjust raw warehouse stock", [["code", "Material", _selected.get("code", "RM-FLOUR")],
		["qty", "Signed quantity in base unit", "-1"], ["reason", "Reason", "Physical count"]],
		func(v: Dictionary) -> String: return line.erp.adjust(v.code, _number(v.qty), v.reason))


func _run_mrp() -> void:
	plan.run(line.erp, line.erp_fg())
	notice("MRP calculated at " + Book.date(line.erp.now))
	_render()


func _convert() -> void:
	var key := String(_selected.get("proposal", ""))
	if key.is_empty():
		notice("Select a purchase or planned production proposal.")
		return
	var item: Dictionary = plan.proposals.get(key, {})
	if line.erp.explicit_planning and not item.is_empty():
		var fields := [["quantity", "Quantity (shipping boxes for finished goods)", item.get("quantity", item.qty)]]
		if item.type == "Make":
			fields.append(["start", "Planned start at simulated minute", maxf(line.erp.now, item.start) / 60.0])
			fields.append(["version", "Production version", item.version])
		_form("Schedule planned order" if item.type == "Make" else "Convert purchase proposal", fields,
			func(v: Dictionary) -> String:
				var edits := {"quantity": _number(v.quantity)}
				if v.has("start"):
					edits.merge({"start": _number(v.start) * 60.0, "version": v.version})
				var result := plan.convert(key, line.erp, line.erp_fg(), edits)
				if result.error.is_empty() and item.type == "Make":
					_set_page(SCHEDULE_PAGE)
					_board.picked = result.id
				return _result(result))
	else:
		_form("Convert selected proposal to a document?", [], func(_v: Dictionary) -> String:
			return _result(plan.convert(key, line.erp, line.erp_fg())))


## Whether a proposal belongs to the current MRP view. Evaluated live, because MRP regroups
## lots while earlier ones convert.
func _shown(item: Dictionary) -> bool:
	if not _mrp_material.is_empty():
		if item.code != _mrp_material or (_exceptions_only and item.get("exceptions", []).is_empty()):
			return false
	else:
		var entry: Dictionary = plan.coverage.get(item.code, {})
		var material: Dictionary = line.erp.catalog.materials[item.code]
		if _exceptions_only and entry.get("exceptions", 0) == 0:
			return false
		if not _family.text.is_empty() and not String(material.get("family", "")).to_lower().contains(_family.text.to_lower()):
			return false
	return not _date_filter.text.is_valid_float() or float(item.get("start", 0.0)) <= _date_filter.text.to_float() * 60.0


func _shown_proposals() -> Array:
	return plan.proposals.values().filter(_shown).map(func(item: Dictionary) -> String: return item.id)


func _convert_shown() -> void:
	var count := _shown_proposals().size()
	if count == 0:
		notice("No planned orders in this view. Run MRP or clear the filters.")
		return
	_form("Convert the %d planned orders and requisitions in this view?" % count, [], func(_values: Dictionary) -> String:
		var result: Dictionary = plan.convert_all(line.erp, line.erp_fg(), _shown)
		var message := "Created %d documents." % result.created.size()
		if not result.failed.is_empty():
			message += " %d failed: %s" % [result.failed.size(), "; ".join(PackedStringArray(result.failed.map(
				func(row: Dictionary) -> String: return "%s %s" % [row.proposal, row.error])))]
		notice(message)
		return "")


func _selected_planned() -> Dictionary:
	var item: Dictionary = plan.proposals.get(String(_selected.get("proposal", "")), {})
	if item.is_empty() or not line.erp.planned_orders.has(item.get("number", "")):
		notice("Select a planned order or requisition in a stock/requirements list.")
		return {}
	return item


func _toggle_firm() -> void:
	var item := _selected_planned()
	if item.is_empty():
		return
	var error: String = plan.firm(item.number, not item.firmed, line.erp, line.erp_fg())
	notice(error if not error.is_empty() else "%s %s." % [item.number, "unfirmed: MRP may change or delete it" if item.firmed else "firmed: MRP keeps it unchanged"])
	_render()


func _change_planned() -> void:
	var item := _selected_planned()
	if item.is_empty():
		return
	var unit: String = "shipping boxes" if item.get("boxes", 0) > 0 else line.erp.catalog.materials[item.code].unit
	_form("Change %s · %s" % [item.number, item.code], [["quantity", "Quantity in " + unit, _qty(item.get("quantity", item.qty))],
		["start", "%s at simulated minute" % ("Start" if item.type == "Make" else "Order date"), _qty(maxf(line.erp.now, item.start) / 60.0)]],
		func(v: Dictionary) -> String:
			var error: String = plan.change(item.number, _number(v.quantity), _number(v.start) * 60.0, line.erp, line.erp_fg())
			if error.is_empty():
				notice("%s changed and firmed." % item.number)
			return error)


func _edit_material() -> void:
	var code := String(_selected.get("code", ""))
	var catalog := line.erp.catalog
	var item: Dictionary = catalog.materials.get(code, {})
	if item.is_empty():
		notice("Select a material.")
		return
	var fields := [["name", "Description", item.name], ["minimum", "Safety stock in base unit", _qty(item.minimum)],
		["lead", "Lead time · simulated minutes", _qty(item.lead / 60.0)], ["active", "Active (yes / no)", "yes" if item.active else "no"]]
	if item.type == "FERT":
		fields.append_array([["pack", "Net kg per consumer pack", _qty(item.pack_kg)],
			["packs", "Packs per shipping box", str(item.packs_per_box)],
			["pallet", "Shipping boxes per pallet", str(item.boxes_per_pallet)]])
	var settings: Dictionary = catalog.planning(code)
	var procedures := [[settings.lot_size, "%s · %s" % [settings.lot_size, catalog.LOT_PROCEDURES[settings.lot_size]]]]
	for key in catalog.LOT_PROCEDURES:
		if key != settings.lot_size:
			procedures.append([key, "%s · %s" % [key, catalog.LOT_PROCEDURES[key]]])
	fields.append_array([["lot_size", "MRP lot size", procedures],
		["fixed_lot", "Fixed lot (FX) in base unit", _qty(settings.fixed_lot)],
		["period", "Period length (PB) · simulated minutes", _qty(settings.period_seconds / 60.0)],
		["min_lot", "Minimum lot", _qty(settings.min_lot)], ["max_lot", "Maximum lot (0 = none)", _qty(settings.max_lot)],
		["rounding", "Rounding value (0 = none)", _qty(settings.rounding)],
		["safety_time", "Safety time · simulated minutes", _qty(settings.safety_time / 60.0)]])
	_form("Edit " + code, fields, func(v: Dictionary) -> String:
		var planning := {"lot_size": v.lot_size, "fixed_lot": _number(v.fixed_lot), "period_seconds": _number(v.period) * 60.0,
			"min_lot": _number(v.min_lot), "max_lot": _number(v.max_lot), "rounding": _number(v.rounding),
			"safety_time": _number(v.safety_time) * 60.0}
		for key in planning:
			if key != "lot_size" and not is_finite(planning[key]):
				return "Enter numbers for the MRP settings."
		var backup: Dictionary = catalog.planning(code)
		var problem := catalog.set_planning(code, planning)
		if not problem.is_empty():
			return "MRP settings: " + problem
		var error := catalog.edit_material(code, v.name, _number(v.minimum), _number(v.lead) * 60.0,
			v.active.to_lower() == "yes", _number(v.get("pack", "0")),
			String(v.get("packs", "0")).to_int(), String(v.get("pallet", "0")).to_int())
		if error.is_empty():
			line.erp.changed()
		else:
			catalog.set_planning(code, backup)
		return error)


func _clone_product() -> void:
	var code := String(_selected.get("code", ""))
	_form("Clone selected finished product", [["code", "New stable code", "FG-1006"],
		["name", "Description", "New wafer variant"]], func(v: Dictionary) -> String:
		var error := line.erp.catalog.clone_product(code, v.code, v.name)
		if error.is_empty():
			line.erp.changed()
		return error)


func _edit_header() -> void:
	var code := String(_selected.get("code", ""))
	var b := line.erp
	var current: Dictionary = b.catalog.boms.get(code, {})
	if current.is_empty():
		notice("Select a BOM parent.")
		return
	_form("Edit BOM " + code, [["base", "Base quantity in parent unit", _qty(current.base)],
		["active", "Active (yes / no)", "yes" if current.active else "no"]],
		func(v: Dictionary) -> String:
			var error := b.catalog.save_bom(code, _number(v.base), current.parts, v.active.to_lower() == "yes")
			if error.is_empty():
				b.changed()
			return error)


func _edit_component(adding: bool = false) -> void:
	var child := String(_selected.get("code", ""))
	var parent := String(_selected.get("parent", ""))
	var b := line.erp
	if parent.is_empty() or adding:
		parent = child
		child = ""
	var bom: Dictionary = b.catalog.boms.get(parent, {})
	if bom.is_empty():
		notice("Select a BOM parent to add a component, or select an existing component.")
		return
	_form("Component in " + parent, [["code", "Component material", child],
		["qty", "Quantity per BOM base (0 removes)", _qty(_selected.get("quantity", 0.0))],
		["scrap", "Scrap percentage", _qty(float(_selected.get("scrap", 0.0)) * 100.0)]],
		func(v: Dictionary) -> String:
			if not b.catalog.materials.has(v.code) or not is_finite(_number(v.qty)) or _number(v.qty) < 0:
				return "Use a known component and a nonnegative quantity."
			var parts: Array = bom.parts.duplicate(true)
			for index in range(parts.size() - 1, -1, -1):
				if parts[index].code == child:
					parts.remove_at(index)
			if _number(v.qty) > 0.0:
				parts.append({"code": v.code, "qty": _number(v.qty), "unit": b.catalog.materials[v.code].unit,
					"scrap": _number(v.scrap) / 100.0})
			var error := b.catalog.save_bom(parent, bom.base, parts, bom.active)
			if error.is_empty():
				b.changed()
			return error)


func _locate() -> void:
	var location := String(_selected.get("location", ""))
	if location.is_empty():
		notice("Select a material or stock row first.")
		return
	close()
	locate_requested.emit(location)


func _form(title: String, fields: Array, submit: Callable, update: Callable = Callable()) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.ok_button_text = "Confirm"
	dialog.dialog_hide_on_ok = false
	add_child(dialog)
	var form := VBoxContainer.new()
	form.custom_minimum_size.x = 440
	dialog.add_child(form)
	var inputs := {}
	for field in fields:
		form.add_child(_label(field[1], 14, Color.WHITE))
		if field[2] is Array:
			var picker := OptionButton.new()
			picker.name = field[0]
			for option in field[2]:
				picker.add_item(option[1])
				picker.set_item_metadata(picker.item_count - 1, option[0])
			form.add_child(picker)
			inputs[field[0]] = picker
		else:
			var edit := LineEdit.new()
			edit.name = field[0]
			edit.text = str(field[2])
			form.add_child(edit)
			inputs[field[0]] = edit
	if update.is_valid():
		var preview := _label("", 13, Color("#daeaf6"))
		preview.custom_minimum_size = Vector2(450, 130)
		preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		form.add_child(preview)
		for input in inputs.values():
			if input is LineEdit:
				input.text_changed.connect(func(_value: String) -> void: update.call(inputs, preview, true))
			elif input is OptionButton:
				input.item_selected.connect(func(_index: int) -> void: update.call(inputs, preview, false))
		update.call(inputs, preview, true)
	var feedback := _label("", 14, Color("#ffc289"))
	feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(feedback)
	dialog.confirmed.connect(func() -> void:
		var values := {}
		for key in inputs:
			var input: Control = inputs[key]
			if input is OptionButton:
				values[key] = String(input.get_selected_metadata()) if input.selected >= 0 else ""
			else:
				values[key] = input.text.strip_edges()
		var before := _status.text
		var error: String = submit.call(values)
		if error.is_empty():
			dialog.hide()
			if _status.text == before:
				notice("Transaction saved." if fields.size() > 0 else "Done.")
			_render()
			dialog.queue_free()
		else:
			feedback.text = error)
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	dialog.popup_centered()


func _result(result: Dictionary) -> String:
	if result.error.is_empty():
		notice("Created " + result.id)
	return result.error


func _number(copy: String) -> float:
	return copy.to_float() if copy.is_valid_float() else NAN


func _qty(value: float) -> String:
	return String.num(value, 4)


func _amounts(values: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in values:
		parts.append("%s %s" % [key, _qty(values[key])])
	return ", ".join(parts) if not parts.is_empty() else "—"


func _action(copy: String, callback: Callable) -> void:
	var button := _button(_actions, copy, callback)
	button.add_theme_font_size_override("font_size", 13)


func _button(parent: Control, copy: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = copy
	Style.button_style(button)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _label(copy: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	return label


func _spacer(parent: Control) -> void:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)
