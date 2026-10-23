class_name EconInventoryPanel
extends EconPanelBase

## Stack-based warehouse view. Quantities remain in the existing economy inventory.
const ItemIcons := preload("res://scripts/ui/InventoryIcons.gd")
const SLOT_SIZE := Vector2(92, 116)
const CATEGORY_KEYS := ["", "ore", "fuel", "component", "ammo", "ship_equipment", "general", "mission", "ship"]
const CATEGORY_NAMES := {"": "全部物品", "ore": "矿石", "fuel": "燃料", "component": "空间站组件",
	"ammo": "弹药", "ship_equipment": "舰用装备", "general": "其他商品", "mission": "派遣子系统", "ship": "舰船"}
const USES := {
	"truss": "空间站的承重结构，用于建造机库、建造厂及其他模块。",
	"cabin": "密封结构舱体，用于空间站模块建设。",
	"ecu": "电子控制组件，用于空间站建设和精密设备制造。",
	"fueltank": "储存低温燃料的舱体，用于模块建设与设备制造。",
	"kineticAmmo": "基础舰用弹药，由低级矿物制造。战舰访客会优先收购。",
	"thermalMissile": "使用多种低级矿物制造的热能导弹。战舰访客会优先收购。",
	"heavyTorpedo": "消耗大量矿物制造的重型反舰弹药。战舰访客会优先收购。",
	"plasmaAmmo": "使用电浆凝矿制造的高级弹药。战舰会购买作为补给，也会从市场优先收购。",
	"armorPlate": "由大量低级矿物制造的附加装甲。战舰访客会优先收购。",
	"resistanceMembrane": "使用少量高级矿物制造的防护薄膜。战舰访客会优先收购。",
	"nanoArmorRepairer": "混合低级和高级矿物制造的装甲修复装备。战舰访客会优先收购。",
	"smallArms": "批量生产的轻型军需商品，可挂单出售给来访船只。",
	"heavyArms": "重型地面军需商品，可挂单出售给来访船只。",
	"nanoRepair": "以活性纳米矿制造的修复耗材，可作为军需商品出售。",
}

var _category := ""
var _filter := ""
var _show_unowned := false
var _selected_id := ""
var _summary: Label
var _wallet: Label
var _grid_scroll: ScrollContainer
var _grid: GridContainer
var _detail_scroll: ScrollContainer
var _detail: VBoxContainer
var _empty_hint: Label
var _slots := {}
var _shown_ids: Array = []
var _detail_key := ""
var _refresh_pending := false


func _init() -> void:
	super("空间站仓库 · 背包")
	_own_scroll = true
	default_size = Vector2(1000, 620)


func _panel_min() -> Vector2:
	return Vector2(700, 400)


func _connect_signals() -> void:
	Economy.inventory_changed.connect(_on_inventory_changed)
	Economy.fuel_changed.connect(_on_inventory_changed)
	Economy.money_changed.connect(_on_inventory_changed)


func _collect_scrolls() -> Array:
	return [_grid_scroll, _detail_scroll] if is_instance_valid(_grid_scroll) else []


func _rebuild() -> void:
	var top := EconTheme.hbox(12)
	body.add_child(top)
	_summary = EconTheme.label("", EconTheme.DIM, 12)
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_summary)
	_wallet = EconTheme.label("", EconTheme.ACCENT, 15)
	top.add_child(_wallet)
	var toolbar := EconTheme.hbox(8)
	body.add_child(toolbar)
	var categories := OptionButton.new()
	for key in CATEGORY_KEYS:
		categories.add_item(CATEGORY_NAMES[key])
	categories.selected = CATEGORY_KEYS.find(_category)
	categories.item_selected.connect(func(index: int):
		_category = CATEGORY_KEYS[index]
		_fill_grid())
	toolbar.add_child(categories)
	var search := LineEdit.new()
	search.name = "BackpackSearch"
	search.placeholder_text = "搜索物品"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text = _filter
	search.text_changed.connect(func(value: String):
		_filter = value
		_fill_grid())
	toolbar.add_child(search)
	var unowned := CheckButton.new()
	unowned.text = "显示未持有"
	unowned.button_pressed = _show_unowned
	unowned.toggled.connect(func(value: bool):
		_show_unowned = value
		_fill_grid())
	toolbar.add_child(unowned)

	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.custom_minimum_size.y = 300
	columns.split_offset = 670
	body.add_child(columns)
	var left := EconTheme.vbox(6)
	left.custom_minimum_size.x = 300
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	_empty_hint = EconTheme.label("", EconTheme.DIM, 13)
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_empty_hint)
	_grid_scroll = ScrollContainer.new()
	# Allow the scroll area to shrink below the grid's previous column width.
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_grid_scroll)
	_grid = GridContainer.new()
	_grid.name = "BackpackGrid"
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid_scroll.add_child(_grid)
	_grid_scroll.resized.connect(_adapt_columns)
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.custom_minimum_size.x = 240
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(_detail_scroll)
	_detail = EconTheme.vbox(10)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.add_child(_detail)
	_detail_key = ""
	_slots.clear()
	_fill_grid()
	body.add_child(EconTheme.label("同类物品自动堆叠 · 右下角显示数量 · 点击图标查看详情", EconTheme.DIM, 11))
	call_deferred("_adapt_columns")


func _all_ids() -> Array:
	var ids := GameData.ORES.keys() + GameData.COMPONENTS.keys() + GameData.PRODUCTS.keys() + GameData.SHIPS.keys()
	for id in Economy.inv:
		if not ids.has(id):
			ids.append(id)
	return ids


func _category_for(id: String) -> String:
	if id == GameData.FUEL_ID:
		return "fuel"
	if GameData.is_product(id):
		return "mission" if GameData.PRODUCTS[id].get("is_equip", false) else String(GameData.PRODUCTS[id].get("group", "general"))
	var category := GameData.cat_of(id)
	return category if category in ["ore", "component", "ship"] else "general"


func _visible_ids() -> Array:
	var out := []
	var query := _filter.strip_edges().to_lower()
	for id in _all_ids():
		if not _show_unowned and Economy.stock(id) <= 0:
			continue
		if _category != "" and _category_for(id) != _category:
			continue
		if query != "" and not query in (GameData.good_name(id) + " " + String(CATEGORY_NAMES[_category_for(id)])).to_lower():
			continue
		out.append(id)
	return out


func _fill_grid() -> void:
	if not is_instance_valid(_grid):
		return
	var scroll := _grid_scroll.scroll_vertical
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_slots.clear()
	_shown_ids = _visible_ids()
	if not _shown_ids.has(_selected_id):
		_selected_id = String(_shown_ids[0]) if not _shown_ids.is_empty() else ""
	for id in _shown_ids:
		_grid.add_child(_make_slot(id))
	_pad_grid()
	_empty_hint.visible = _shown_ids.is_empty()
	_empty_hint.text = "没有匹配的物品。" if _filter != "" or _category != "" else "仓库还是空的。采集矿物或制造商品后，它们会出现在这里。"
	_update_summary()
	_show_details()
	_grid_scroll.set_deferred("scroll_vertical", scroll)


func _make_slot(id: String) -> Button:
	var button := EconTheme.button("", _select_good.bind(id), SLOT_SIZE)
	button.set_meta("goods_id", id)
	var art := TextureRect.new()
	art.texture = ItemIcons.for_good(id)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.position = Vector2(14, 7)
	art.size = Vector2(64, 64)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(art)
	var amount := EconTheme.label("", EconTheme.TEXT, 11)
	amount.position = Vector2(40, 58)
	amount.size = Vector2(46, 18)
	amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	amount.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var badge := EconTheme.style_box(Color(0.035, 0.05, 0.065, 0.92), Color.TRANSPARENT, 3, 0)
	badge.content_margin_left = 3
	badge.content_margin_right = 3
	badge.content_margin_top = 1
	badge.content_margin_bottom = 1
	amount.add_theme_stylebox_override("normal", badge)
	button.add_child(amount)
	var name_label := EconTheme.label(GameData.good_name(id), EconTheme.TEXT, 11)
	name_label.position = Vector2(3, 80)
	name_label.size = Vector2(86, 32)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.max_lines_visible = 2
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name_label)
	if GameData.RARE_IDS.has(id) or id == "plasmaAmmo":
		var tag := EconTheme.label("稀有" if GameData.RARE_IDS.has(id) else "高级", EconTheme.RARE, 9)
		tag.position = Vector2(5, 3)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(tag)
	_slots[id] = {"button": button, "art": art, "amount": amount, "name": name_label}
	_update_slot(id)
	return button


func _update_slot(id: String) -> void:
	var slot: Dictionary = _slots[id]
	var quantity := Economy.stock(id)
	var selected := id == _selected_id
	var tint := ItemIcons.accent(id)
	var bg := Color(0.08, 0.15, 0.19) if selected else Color(0.045, 0.065, 0.08)
	var border := EconTheme.ACCENT if selected else tint.darkened(0.7)
	slot.button.add_theme_stylebox_override("normal", EconTheme.style_box(bg, border, 5, 2 if selected else 1))
	slot.art.modulate = Color.WHITE if quantity > 0 else Color(0.4, 0.43, 0.48, 0.65)
	slot.amount.text = _stack_text(quantity)
	slot.amount.add_theme_color_override("font_color", EconTheme.TEXT if quantity > 0 else EconTheme.DIM)
	slot.name.add_theme_color_override("font_color", EconTheme.TEXT if quantity > 0 else EconTheme.DIM)
	slot.button.tooltip_text = "%s\n%s · 数量 %s\n单位参考价 %s" % [GameData.good_name(id), CATEGORY_NAMES[_category_for(id)],
		EconTheme.comma(quantity), _unit_price_text(id)]


func _stack_text(quantity: int) -> String:
	if quantity >= 1000000:
		return "%.1fM" % (float(quantity) / 1000000.0)
	if quantity >= 10000:
		return "%.1fk" % (float(quantity) / 1000.0)
	return str(quantity)


func _unit_price_text(id: String) -> String:
	var cents := roundi(GameData.good_unit_price(id) * 100.0)
	var whole := EconTheme.money(floorf(float(cents) / 100.0))
	return whole if cents % 100 == 0 else "%s.%02d" % [whole, cents % 100]


func _pad_grid() -> void:
	for child in _grid.get_children():
		if not child.has_meta("goods_id"):
			_grid.remove_child(child)
			child.queue_free()
	var count := maxi(_grid.columns * 2 - _shown_ids.size(), (_grid.columns - _shown_ids.size() % _grid.columns) % _grid.columns)
	for index in count:
		var empty := Panel.new()
		empty.custom_minimum_size = SLOT_SIZE
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.04, 0.055, 0.065, 0.4), Color(0.12, 0.16, 0.18, 0.6), 5))
		_grid.add_child(empty)


func _adapt_columns() -> void:
	if not is_instance_valid(_grid_scroll) or not is_instance_valid(_grid):
		return
	var columns := maxi(1, floori((_grid_scroll.size.x - 16.0 + 8.0) / (SLOT_SIZE.x + 8.0)))
	if _grid.columns != columns:
		_grid.columns = columns
		_pad_grid()


func _select_good(id: String) -> void:
	var previous := _selected_id
	_selected_id = id
	if _slots.has(previous):
		_update_slot(previous)
	_update_slot(id)
	_show_details()
	_detail_scroll.scroll_vertical = 0


func _on_inventory_changed() -> void:
	if not visible or _refresh_pending:
		return
	_refresh_pending = true
	call_deferred("_refresh_stock")


func _refresh_stock() -> void:
	_refresh_pending = false
	if not visible or not is_instance_valid(_grid):
		return
	if _visible_ids() != _shown_ids:
		_fill_grid()
	else:
		for id in _shown_ids:
			_update_slot(id)
		_update_summary()
		_show_details()


func _update_summary() -> void:
	var kinds := 0
	var value := 0.0
	for id in _all_ids():
		var quantity := Economy.stock(id)
		if quantity > 0:
			kinds += 1
			value += float(quantity) * GameData.good_unit_price(id)
	_summary.text = "已持有 %d 类 · 当前显示 %d 类 · 库存估值 %s" % [kinds, _shown_ids.size(), EconTheme.money(value)]
	_wallet.text = "钱包 " + EconTheme.money(Economy.money)


func _show_details() -> void:
	var key := "%s:%d" % [_selected_id, Economy.stock(_selected_id)]
	if key == _detail_key:
		return
	_detail_key = key
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	if _selected_id == "":
		_detail.add_child(_wrapped("选择一个物品格子查看详情。", EconTheme.DIM, 14))
		return
	var id := _selected_id
	var art := TextureRect.new()
	art.texture = ItemIcons.for_good(id)
	art.custom_minimum_size = Vector2(88, 88)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail.add_child(art)
	_detail.add_child(_wrapped(GameData.good_name(id), EconTheme.TEXT, 18))
	_detail.add_child(_wrapped(String(CATEGORY_NAMES[_category_for(id)]), ItemIcons.accent(id), 12))
	_detail.add_child(_info_row("持有数量", EconTheme.comma(Economy.stock(id))))
	_detail.add_child(_info_row("单位参考价", _unit_price_text(id)))
	_detail.add_child(_info_row("物品总估值", EconTheme.money(GameData.good_unit_price(id) * Economy.stock(id))))
	_detail.add_child(_wrapped(_description(id), EconTheme.DIM, 13))
	if GameData.is_open_recipe(id):
		_detail.add_child(_wrapped("初始配方 · 无需许可证或蓝图", EconTheme.GOOD, 12))
	if GameData.is_product(id):
		_detail.add_child(_wrapped("每批产出 %d 件" % int(GameData.PRODUCTS[id].batch), EconTheme.DIM, 12))
	if GameData.cat_of(id) != "":
		_detail.add_child(EconTheme.button("前往市场", _open_market.bind(id)))
	if GameData.is_component(id) or GameData.is_product(id) or GameData.is_ship(id):
		_detail.add_child(EconTheme.button("查看制造", func(): get_parent().open_panel_add("factory")))


func _description(id: String) -> String:
	if id == GameData.FUEL_ID:
		return "燃料冰矿入库后计入燃料库存，用于来访船只停靠，以及战舰和中立采矿舰队补给。"
	if GameData.is_ore(id):
		var role: String = GameData.ORES[id].get("role", "制造原料")
		return role.get_slice("·", 1) + "。可用于制造和建设，也可在市场出售。"
	if USES.has(id):
		return USES[id]
	if GameData.is_ship(id):
		return "制造完成的舰船商品，可出售给来访船只。"
	if GameData.is_product(id) and GameData.PRODUCTS[id].get("is_equip", false):
		return "探索派遣用子系统。新制造的子系统存入行动中心装备库。"
	return "存放在空间站仓库中的物品。"


func _info_row(title: String, value: String) -> Control:
	var row := EconTheme.hbox(8)
	var label := EconTheme.label(title, EconTheme.DIM, 12)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(EconTheme.label(value, EconTheme.TEXT, 13))
	return row


func _wrapped(text: String, color: Color, font_size: int) -> Label:
	var label := EconTheme.label(text, color, font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _open_market(id: String) -> void:
	var ui := get_parent()
	ui._panels.market._sel_goods = id
	ui._panels.market._filter = ""
	ui.open_panel_add("market")
