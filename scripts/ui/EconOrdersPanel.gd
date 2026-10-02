class_name EconOrdersPanel
extends EconPanelBase

## 我的订单（EVE marketOrdersWnd 复刻）：虚拟化 ItemList 单列
## [卖] 货物名 余量/原始 —— 选中行取消对应挂单。

var _orders_list: ItemList


func _init() -> void:
	super("我的订单")
	_own_scroll = true
	default_size = Vector2(600, 500)   # EVE marketOrdersWnd 默认尺寸


func _panel_min() -> Vector2:
	return Vector2(300, 300)  # EVE marketOrdersWnd.default_minSize (300,300)


func _collect_itemlists() -> Array:
	return [_orders_list]


func _connect_signals() -> void:
	Economy.market_changed.connect(_sig_refresh)
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.licenses_changed.connect(_sig_refresh)
	Economy.freighters_changed.connect(_sig_refresh)


func _rebuild() -> void:
	var expiring := 0
	for o in Economy.sell_orders + Economy.buy_orders:
		if Economy.order_remaining_days(o) <= 0.5:
			expiring += 1
	var head := EconTheme.rich("")
	head.text = "[color=#8ea2bd]挂卖[/color] %d 单    [color=#8ea2bd]挂买[/color] %d 单    %s" % [
		Economy.sell_orders.size(), Economy.buy_orders.size(),
		"[color=#F39058]⚠ %d 单即将到期[/color]" % expiring if expiring > 0 else "（选中行后点取消；到期自动退回）"]
	body.add_child(head)

	var list := ItemList.new()
	_orders_list = list
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("v_separation", 1)
	list.add_theme_font_size_override("font_size", 12)
	list.add_theme_color_override("font_color", EconTheme.TEXT)
	list.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.05, 0.06, 0.05, 0.9), Color(0, 0, 0, 0), 0, 0))
	list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sel := EconTheme.style_box(Color(0.11, 0.18, 0.21, 1.0), Color("58A7BF"), 0, 1)
	list.add_theme_stylebox_override("selected", sel)
	list.add_theme_stylebox_override("selected_focus", sel)
	body.add_child(list)

	# 行布局: 卖单在前(绿标), 买单在后(橙标); meta 记挂单稳定 uid（2026-10-01 修陈旧下标:
	# market_changed 每秒触发整表重建, 成交/到期会移位数组——记下标会误撤别的单, uid 恒稳）
	var meta: Array = []
	for i in Economy.sell_orders.size():
		var o: Dictionary = Economy.sell_orders[i]
		var sold: int = int(o.get("orig", o["qty"])) - int(o["qty"])
		list.add_item("[卖] %s @%s   余 %d/%d   成交 %d   剩 %.1f 天" % [
			GameData.good_name(String(o["goods"])), _price_txt(o), int(o["qty"]),
			int(o.get("orig", o["qty"])), sold, Economy.order_remaining_days(o)])
		list.set_item_custom_fg_color(i, EconTheme.GOOD)
		meta.append({"uid": int(o.get("uid", -1)), "is_sell": true})
	for j in Economy.buy_orders.size():
		var b: Dictionary = Economy.buy_orders[j]
		var filled: int = int(b.get("orig", b["qty"])) - int(b["qty"])
		var li := list.add_item("[买] %s @%s   余 %d/%d   成交 %d   剩 %.1f 天" % [
			_buy_name(String(b["goods"])), _price_txt(b), int(b["qty"]),
			int(b.get("orig", b["qty"])), filled, Economy.order_remaining_days(b)])
		list.set_item_custom_fg_color(li, EconTheme.WARN)
		meta.append({"uid": int(b.get("uid", -1)), "is_sell": false})
	list.item_selected.connect(func(idx: int): _sel = [meta, idx])

	var ops := EconTheme.hbox(8)
	body.add_child(ops)
	ops.add_child(EconTheme.button("取消选中挂单", _cancel_selected, Vector2(130, 28)))
	ops.add_child(EconTheme.button("全部刷新", refresh, Vector2(90, 28)))


var _sel: Array = []


func _cancel_selected() -> void:
	if _sel.size() < 2:
		Economy.post_event("先选中一行挂单", "warn")
		return
	var meta: Array = _sel[0]
	var idx: int = _sel[1]
	if idx < 0 or idx >= meta.size():
		return
	var m: Dictionary = meta[idx]
	var ok := false
	if bool(m["is_sell"]):
		ok = Economy.cancel_sell_by_uid(int(m["uid"]))  # 按稳定 uid 现查真实下标
	else:
		ok = Economy.cancel_buy_by_uid(int(m["uid"]))
	if not ok:
		Economy.post_event("该挂单已成交或到期消失", "warn")
	_sel.clear()
	refresh()


func _buy_name(goods: String) -> String:
	if goods.begins_with("lic:"):
		return "许可证·" + GameData.equip_name(goods.substr(4))
	return GameData.good_name(goods)


## 限价显示（旧存档的挂单没有 price 字段 → 显示占位符）
func _price_txt(o: Dictionary) -> String:
	var p: float = float(o.get("price", 0.0))
	return EconTheme.money(p) if p > 0.0 else "—"
