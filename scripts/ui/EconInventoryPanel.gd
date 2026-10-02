class_name EconInventoryPanel
extends EconPanelBase

## 仓库：矿石（含燃料）/组件/产品/舰船 库存与基准单价总览。


func _init() -> void:
	super("仓库")


func _panel_min() -> Vector2:
	return Vector2(440, 0)


func _connect_signals() -> void:
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.fuel_changed.connect(_sig_refresh)
	Economy.money_changed.connect(_sig_refresh)


func _rebuild() -> void:
	body.add_child(_money_row())

	body.add_child(_section("矿石（BOM 原料）"))
	for id in GameData.ORES:
		if id == GameData.FUEL_ID:
			continue
		body.add_child(_goods_row(id))

	body.add_child(_section("燃料"))
	var frow := _goods_row(GameData.FUEL_ID)
	body.add_child(frow)
	var note := EconTheme.label("    燃料冰矿入库即燃料：公共货舰到港/离港消耗，有燃料才来船", EconTheme.DIM, 12)
	body.add_child(note)

	body.add_child(_section("空间站组件"))
	for id in GameData.COMPONENTS:
		body.add_child(_goods_row(id))

	body.add_child(_section("小型产品"))
	for id in GameData.PRODUCTS:
		body.add_child(_goods_row(id))

	body.add_child(_section("舰船（纯商品，卖给来访货舰）"))
	for id in GameData.SHIPS:
		body.add_child(_goods_row(id))


func _money_row() -> PanelContainer:
	var c := EconTheme.card()
	var h := EconTheme.hbox(16)
	c.add_child(h)
	h.add_child(EconTheme.label("货币", EconTheme.DIM, 14))
	var m := EconTheme.label(EconTheme.money(Economy.money), EconTheme.ACCENT, 17)
	h.add_child(m)
	var tip := EconTheme.label("许可费与走私召唤是主要货币消耗（下水道）", EconTheme.DIM, 12)
	tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(tip)
	return c


func _goods_row(id: String) -> Control:
	var qty := Economy.stock(id)
	var price := GameData.good_unit_price(id)
	var c := PanelContainer.new()
	c.add_theme_stylebox_override("panel", EconTheme.style_box(EconTheme.PANEL2, EconTheme.BORDER.darkened(0.2), 4))
	var h := EconTheme.hbox(10)
	c.add_child(h)
	var name_l := EconTheme.label(GameData.good_name(id), EconTheme.TEXT, 14)
	name_l.custom_minimum_size.x = 150
	h.add_child(name_l)
	var cat := GameData.cat_of(id)
	if cat == "ore" and GameData.ORES[id]["path"] == "":
		name_l.add_theme_color_override("font_color", EconTheme.DIM)
		name_l.text += "（待模型）"
	var q := EconTheme.label(EconTheme.comma(qty), EconTheme.GOOD if qty > 0 else EconTheme.DIM, 14)
	q.custom_minimum_size.x = 110
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(q)
	var p := EconTheme.label("%s/单位" % EconTheme.money(price), EconTheme.DIM, 13)
	p.custom_minimum_size.x = 110
	p.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(p)
	if id in GameData.RARE_IDS:
		var tag := EconTheme.label("稀有", EconTheme.RARE, 12)
		h.add_child(tag)
	return c
