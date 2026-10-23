class_name EconMarketPanel
extends EconPanelBase

## 本地市场 —— EVE market UI 逻辑重组版（2026-10-01）：
## 结构照 marketbase.py：左列=搜索+分组货物列表(虚拟化 ItemList) | 原生分栏 |
## 右列=Sellers/Buyers 订单簿(虚拟化 ItemList, 上下分离) + 底部下单条。
## 列表全部 ItemList=引擎只画可见行——几十上百行零压力（EVE ScrollEntries 同思路）。

var _search: LineEdit
var _sel_goods := ""
var _filter := ""
var _goods_list: ItemList          # 左列货物（虚拟化）
var _sellers_list: ItemList        # Sellers 订单（虚拟化）
var _buyers_list: ItemList         # Buyers 订单（虚拟化）
var _seller_meta: Array = []       # Sellers 行→offer 字典
var _buyer_meta: Array = []        # Buyers 行→offer 字典
var _trade: EconTradeDialog
var _right_col: VBoxContainer


func _init() -> void:
	super("本地市场")
	_own_scroll = true
	default_size = Vector2(900, 768)   # EVE marketbase.default_width/height（最小 650×435 见 _panel_min）


func _collect_scrolls() -> Array:
	return []  # 全 ItemList


func _collect_itemlists() -> Array:
	return [_goods_list, _sellers_list, _buyers_list]


func _panel_min() -> Vector2:
	return Vector2(650, 435)  # EVE marketbase.default_minSize


func _connect_signals() -> void:
	Economy.market_changed.connect(_sig_refresh)
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.fuel_changed.connect(_sig_refresh)
	Economy.money_changed.connect(_sig_refresh)
	Economy.freighters_changed.connect(_sig_refresh)
	Economy.licenses_changed.connect(_sig_refresh)
	Economy.market_changed.connect(_refresh_ticker)


# ============ ItemList 工厂（EVE 紧凑风格） ============

func _make_list() -> ItemList:
	var l := ItemList.new()
	l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_constant_override("v_separation", 1)
	l.add_theme_constant_override("h_separation", 6)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", EconTheme.TEXT)
	l.add_theme_color_override("font_selected_color", Color(0.9, 0.95, 1.0))
	l.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.05, 0.06, 0.05, 0.9), Color(0, 0, 0, 0), 0, 0))
	l.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sel := EconTheme.style_box(Color(0.11, 0.18, 0.21, 1.0), Color("58A7BF"), 0, 1)
	sel.content_margin_top = 1.0
	sel.content_margin_bottom = 1.0
	l.add_theme_stylebox_override("selected", sel)
	l.add_theme_stylebox_override("selected_focus", sel)
	l.add_theme_stylebox_override("hovered", EconTheme.style_box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 0, 0))
	return l


func _refresh_ticker() -> void:
	# 价格滚动播报: 最近成交 → 底栏跑马灯（2026-10-02）
	var parts: Array[String] = []
	for e in Economy.trade_log.slice(maxi(Economy.trade_log.size() - 12, 0)):
		var g := String(e["g"])
		var nm: String = _disp_name(g) if g.begins_with("lic:") else GameData.good_name(g)
		parts.append("%s %s×%d" % [nm, EconTheme.money(float(e["p"])), int(e["q"])])
	_set_ticker("  ◈  ".join(parts))


func _rebuild() -> void:
	# ---- 顶行: 搜索（EVE 左列顶部搜索框） ----
	var search_row := EconTheme.hbox(6)
	body.add_child(search_row)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索货物…"
	_search.text = _filter
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size = Vector2(0, 24)
	_search.text_changed.connect(func(t): _filter = t)
	_search.text_submitted.connect(func(_t): refresh())
	search_row.add_child(_search)
	# EVE: 市场窗顶部 Market Orders 按钮 → 打开订单窗（OpenMarketOrders）
	var orders_btn := EconTheme.button("我的订单", _open_orders, Vector2(84, 24))
	search_row.add_child(orders_btn)
	# 战时标识（2026-10-02）: 战争期货舰需求上浮、愿意出更高价
	if Economy.war_active():
		search_row.add_child(EconTheme.label(
			"战时 · 军用需求 ×%.1f" % float(GameData.ECON["war_demand_military"]), EconTheme.BAD, 12))

	# ---- 主区: 左列表 | 原生 HSplit | 右列 ----
	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.collapsed = false
	body.add_child(cols)

	_goods_list = _make_list()
	_goods_list.custom_minimum_size = Vector2(190, 0)
	_goods_list.item_selected.connect(_on_goods_selected)
	cols.add_child(_goods_list)

	var right_col := EconTheme.vbox(3)
	# 固定右列 min 宽(2026-10-01 修切换货物时宽度跳动):
	# 蓝图与普通货物的右列内容不同(无卖出按钮/提示行), min 随之变化会顶动 HSplit 分配→整窗跳宽
	right_col.custom_minimum_size = Vector2(430, 0)
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right_col)
	_right_col = right_col

	_fill_goods_list()
	_fill_order_book(right_col)


## 只重填右列（点击货物切换时左列保持不动）
func _refresh_right() -> void:
	if _right_col == null or not is_instance_valid(_right_col):
		refresh()
		return
	var keep := _capture_list_pos([_sellers_list, _buyers_list])
	for c in _right_col.get_children():
		_right_col.remove_child(c)
		c.queue_free()
	_fill_order_book(_right_col)
	_restore_list_pos([_sellers_list, _buyers_list], keep)


# ============ 左列: 货物分组列表（虚拟化） ============

## 市场全部"交易标的" id —— 与 _fill_goods_list 的组表**同一口径**（裸 id + 许可证变体 lic:<装备>）。
## 【2026-10-02 修】原先 _visible_goods 只列裸 id，而组表用 "lic:"+id 构造，
## 于是 `if id in goods` 对许可证永远不成立 → "产品/舰船许可证"两组被整组 continue 掉，
## 市场里根本没有蓝图/许可证分类 ⇒ 产品与舰船（需扣许可证）实际造不出来。
func _market_ids() -> Array:
	var all: Array = []
	all.append_array(GameData.ORES.keys())
	all.append_array(GameData.COMPONENTS.keys())
	for e in GameData.PRODUCTS:
		all.append(e)
		if GameData.requires_license(e):
			all.append("lic:" + e)
	for e in GameData.SHIPS:
		all.append(e)
		if GameData.requires_license(e):
			all.append("lic:" + e)
	return all


## 搜索框过滤（比对显示名，认 lic: 前缀 → 搜"渡鸦"能同时命中船体与它的许可证）
func _visible_goods() -> Array:
	var out: Array = []
	for id in _market_ids():
		if _filter == "" or _filter.to_lower() in _disp_name(String(id)).to_lower():
			out.append(id)
	return out


## "有货"判定：许可证查 licenses 表（原先一律走 stock() → 许可证恒为 0, 有货也不高亮）
func _holding(id: String) -> int:
	if id.begins_with("lic:"):
		return int(Economy.licenses.get(id.substr(4), 0))
	return Economy.stock(id)


func _fill_goods_list() -> void:
	_goods_list.clear()
	var prod_lic: Array = []
	for e in GameData.PRODUCTS.keys():
		if GameData.requires_license(e):
			prod_lic.append("lic:" + e)
	var ship_lic: Array = []
	for e in GameData.SHIPS.keys():
		if GameData.requires_license(e):
			ship_lic.append("lic:" + e)
	var groups := [
		["矿石", GameData.ORES.keys()],
		["空间站组件", GameData.COMPONENTS.keys()],
		["弹药（战舰优先收购）", GameData.product_ids("ammo")],
		["舰用装备（战舰优先收购）", GameData.product_ids("ship_equipment")],
		["小型产品（成品）", GameData.product_ids("general")],
		["探索派遣子系统", GameData.product_ids("mission")],
		["舰船船体（成品）", GameData.SHIPS.keys()],
		["产品许可证（每张 %d 次）" % GameData.LICENSE_USES_PRODUCT, prod_lic],
		["舰船许可证（每张 %d 次）" % GameData.LICENSE_USES_SHIP, ship_lic],
	]
	var goods := _visible_goods()
	var select_idx := -1
	for g in groups:
		var ids: Array = []
		for id in g[1]:
			if id in goods:
				ids.append(id)
		if ids.is_empty():
			continue
		var gi := _goods_list.add_item("▾ %s" % str(g[0]))
		_goods_list.set_item_disabled(gi, true)
		_goods_list.set_item_selectable(gi, false)
		_goods_list.set_item_custom_fg_color(gi, EconTheme.ACCENT)
		_goods_list.set_item_metadata(gi, "")  # 组头无货物 id
		for id in ids:
			var bid := _best_bid(id)
			var price_txt: String = EconTheme.money(bid) if bid > 0.0 else EconTheme.money(_unit_price(id))
			# 许可证行只显示装备名 + 次数（组头已写明"许可证"），避免与同名的船体/成品行混淆
			var label: String
			if String(id).begins_with("lic:"):
				var eq := String(id).substr(4)
				label = "%s（%d 次/张）" % [GameData.equip_name(eq), GameData.license_uses(eq)]
			else:
				label = _disp_name(String(id))
			# Neutral fleets can also supply ore through their market listings.
			var sell_only: bool = not Economy.freighter_sells(id)
			var icon := _cat_icon(id)
			var ii := _goods_list.add_item("%s   %s%s" % [label, price_txt,
				"  ·仅卖" if sell_only else ""])
			if icon != null:
				_goods_list.set_item_icon(ii, icon)
			_goods_list.set_item_metadata(ii, id)
			if _holding(String(id)) > 0:
				_goods_list.set_item_custom_fg_color(ii, EconTheme.GOOD)
			else:
				_goods_list.set_item_custom_fg_color(ii, EconTheme.DIM)  # 零库存=灰(2026-10-02 拍板)
			if id == _sel_goods:
				select_idx = ii
	if select_idx >= 0:
		_goods_list.select(select_idx)


func _on_goods_selected(idx: int) -> void:
	var id := str(_goods_list.get_item_metadata(idx))
	if id == "" or id == _sel_goods:
		return
	_sel_goods = id
	_refresh_right()  # 只重填右侧订单簿——左列不重建（修点击后列表跳动/换行）


# ============ 右列: Sellers/Buyers 双框（虚拟化） + 下单条 ============

func _fill_order_book(parent: VBoxContainer) -> void:
	var id := _sel_goods
	# 守卫与左列同源: 左列能选中的标的都必须有订单簿。
	# 【2026-10-02 修】原守卫只放行 ore/component/product/ship，不放行 lic: ——
	# 于是下面那段许可证订单簿代码（表头"持有 N 次"、Sellers "N 次/张"）全是死代码，
	# 选中许可证只会显示"请在左侧选择货物"。
	if id == "" or not (id in _market_ids()):
		parent.add_child(EconTheme.label("← 在左侧选择货物查看订单簿", EconTheme.DIM, 12))
		_fill_bottom_bar(parent, "")
		return

	# 标题行固定 min 宽(2026-10-02): 长舰名/附加文案曾随品类顶动右列宽度——数据全进「行情」卡
	var head := EconTheme.rich("")
	head.fit_content = false
	head.custom_minimum_size = Vector2(414, 24)
	head.text = "[b][color=#a6c8ee]%s[/color][/b]" % _disp_name(id)
	parent.add_child(head)

	# ---- 价格历史图（EVE 右上; 自绘 _draw 零节点） + 订单簿 上下分 ----
	var vsplit := VSplitContainer.new()
	vsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vsplit.collapsed = false
	parent.add_child(vsplit)
	var chart := PriceChart.new()
	chart.setup(id)
	chart.custom_minimum_size = Vector2(0, 55)  # 2026-10-02 用户: 减半, 露出更多挂单
	vsplit.add_child(chart)

	var book_split := VSplitContainer.new()
	book_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	book_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	book_split.collapsed = false
	vsplit.add_child(book_split)

	# ---- Sellers（要价, 玩家买入） ----
	var sellers_box := EconTheme.vbox(1)
	sellers_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	book_split.add_child(sellers_box)
	sellers_box.add_child(_box_title("Sellers · 货舰 / 中立舰队出售", EconTheme.WARN))
	sellers_box.add_child(EconTheme.label(EconTheme.order_header(), EconTheme.DIM, 11))
	_sellers_list = _make_list()
	_sellers_list.item_activated.connect(func(idx: int): _on_order_click(idx, false))
	sellers_box.add_child(_sellers_list)
	_seller_meta.clear()
	for o in _collect_offers(id, false):
		_seller_meta.append(o)
		var qty_txt := "×%d" % int(o["qty"])
		if id.begins_with("lic:"):
			qty_txt = "×%d(%d次)" % [int(o["qty"]), int(o.get("uses", 0))]  # 压进 order_line 12 字符列
		_sellers_list.add_item(EconTheme.order_line(qty_txt, EconTheme.money(o["price"]),
			str(o["from"]), String(o.get("left_text", "剩 %ds" % int(o.get("left_s", 0))))))
	# 我的挂买并入出售簿（青色 [你] 标）
	# 【2026-10-02 修】挂单行必须显式含"数量 + 限价"（原来只有"余 15/15 等待货舰供货"，看不出价格）
	for bo in Economy.buy_orders:
		if String(bo["goods"]) == id:
			var mi2 := _sellers_list.add_item(EconTheme.order_line(
				"余 %d/%d" % [int(bo["qty"]), int(bo.get("orig", bo["qty"]))],
				_price_txt(float(bo.get("price", 0.0))), "[你·挂买]",
				"剩 %.1f天" % Economy.order_remaining_days(bo)))
			_sellers_list.set_item_custom_fg_color(mi2, EconTheme.GOOD)  # 我的挂单=绿
			_seller_meta.append({"mine_buy": true, "idx": Economy.buy_orders.find(bo)})

	# ---- Buyers（收购, 玩家卖出） ----
	var buyers_box := EconTheme.vbox(1)
	buyers_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	book_split.add_child(buyers_box)
	buyers_box.add_child(_box_title("Buyers · 货舰收购", EconTheme.GOOD))
	buyers_box.add_child(EconTheme.label(EconTheme.order_header(), EconTheme.DIM, 11))
	_buyers_list = _make_list()
	_buyers_list.item_activated.connect(func(idx: int): _on_order_click(idx, true))
	buyers_box.add_child(_buyers_list)
	_buyer_meta.clear()
	var bids: Array = _collect_offers(id, true)
	if id.begins_with("lic:") and bids.is_empty():
		_buyers_list.add_item("（货舰不收购许可证——用掉次数攒逆向）")
		_buyers_list.set_item_custom_fg_color(0, EconTheme.DIM)
		_buyers_list.set_item_selectable(0, false)
	for i in bids.size():
		var o: Dictionary = bids[i]
		_buyer_meta.append(o)
		var mark := "▲" if i == 0 else ""
		_buyers_list.add_item(EconTheme.order_line("%s×%d" % [mark, int(o["qty_left"])],
			EconTheme.money(o["price"]), str(o["from"]), "剩 %ds" % int(o.get("left_s", 0))))
		# 货舰挂单一律白(2026-10-02 拍板): 最优行用▲标记, 不再用色
	# 我的挂卖并入收购簿（货舰到港自动扫, 扫完可再挂——2026-10-01 拍板）
	for so in Economy.sell_orders:
		if Economy.market.is_player_order(so) and String(so["goods"]) == id:
			var mi := _buyers_list.add_item(EconTheme.order_line(
				"余 %d/%d" % [int(so["qty"]), int(so.get("orig", so["qty"]))],
				_price_txt(float(so.get("price", 0.0))), "[你·挂卖]",
				"剩 %.1f天" % Economy.order_remaining_days(so)))
			_buyers_list.set_item_custom_fg_color(mi, EconTheme.GOOD)  # 我的挂单=绿
			_buyer_meta.append({"mine_sell": true, "idx": Economy.sell_orders.find(so)})

	_fill_bottom_bar(parent, id)


func _box_title(txt: String, col: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.06, 0.07, 0.06, 1.0), col, 0, 0))
	var l := EconTheme.label(txt, col, 12)
	p.add_child(l)
	return p


# ============ 底部下单条（EVE 市场底部操作区） ============

func _fill_bottom_bar(parent: VBoxContainer, id: String) -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.08, 0.10, 0.09, 1.0), EconTheme.BORDER, 0, 1))
	parent.add_child(bar)
	var h := EconTheme.hbox(8)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_child(h)
	if id == "":
		h.add_child(EconTheme.label("（未选择货物）", EconTheme.DIM, 12))
		return
	# 纯按钮固定宽（2026-10-02 用户拍板: 参考价/区间/走私溢价/持有/挂单全收进「行情」悬浮卡,
	# 不再往底栏堆文字——各品类切换 UI 宽度恒定）
	var gid := id
	h.add_child(EconTheme.button("卖出", func(): _open_trade_for(gid, false, Economy.stock(gid)), Vector2(110, 28)))
	h.add_child(EconTheme.button("买入", func(): _open_trade_for(gid, true, 1), Vector2(110, 28)))
	h.add_child(EconTheme.button("行情 ⓘ", func(): _open_quote(gid), Vector2(90, 28)))


## 行情悬浮卡（主 UI 之上, ✕ 关闭）: 参考价/可成交区间/走私溢价/持有/挂单 集中展示
var _quote_popup: PanelContainer

func _open_quote(gid: String) -> void:
	if _quote_popup != null and is_instance_valid(_quote_popup):
		_quote_popup.queue_free()
	var pop := PanelContainer.new()
	_quote_popup = pop
	pop.z_index = 80
	pop.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.06, 0.08, 0.08, 0.98), Color("58A7BF"), 6, 1))
	add_child(pop)
	var v := EconTheme.vbox(6)
	pop.add_child(v)
	var head2 := EconTheme.hbox(8)
	v.add_child(head2)
	var t := EconTheme.label("行情 · " + _disp_name(gid), EconTheme.ACCENT, 14)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head2.add_child(t)
	head2.add_child(EconTheme.button("✕", func(): pop.queue_free(), Vector2(28, 22)))
	var sell_ref: float = Economy.suggest_price(gid, false)
	var buy_ref: float = Economy.suggest_price(gid, true)
	var rows: Array = [
		["卖出参考（挂单建议价）", EconTheme.money(sell_ref)],
		["买入参考（挂单建议价）", EconTheme.money(buy_ref)],
	]
	if not gid.begins_with("lic:"):
		var rg: Vector2 = Economy.fillable_range(gid, false)
		var smug_pct := int(round((float(GameData.FUEL["smuggler_price"]) - 1.0) * 100.0))
		rows.append(["货舰可成交卖出区间", "%s – %s（走私 +%d%%）" % [
			EconTheme.money(rg.x), EconTheme.money(rg.y), smug_pct]])
		rows.append(["库存", str(_holding(gid))])
		rows.append(["基准价", EconTheme.money(GameData.good_unit_price(gid))])
	else:
		rows.append(["持有次数", str(_holding(gid))])
		rows.append(["每张可用次数", str(GameData.license_uses(gid.substr(4)))])
	var my_s := 0
	var my_b := 0
	for o in Economy.sell_orders:
		if Economy.market.is_player_order(o) and String(o["goods"]) == gid:
			my_s = int(o["qty"])
	for b2 in Economy.buy_orders:
		if String(b2["goods"]) == gid:
			my_b = int(b2["qty"])
	rows.append(["我的挂单", "卖 %d / 买 %d（点我的订单管理）" % [my_s, my_b]])
	for r in rows:
		var row := EconTheme.hbox(8)
		v.add_child(row)
		var k := EconTheme.label(str(r[0]), EconTheme.DIM, 12)
		k.custom_minimum_size.x = 210
		row.add_child(k)
		row.add_child(EconTheme.label(str(r[1]), EconTheme.TEXT, 13))
	pop.reset_size()
	var vp := get_viewport_rect().size
	pop.global_position = Vector2(
		clampf((vp.x - pop.size.x) * 0.5, 40.0, vp.x - 80.0),
		clampf((vp.y - pop.size.y) * 0.5, 60.0, vp.y - 120.0))


func _on_order_click(idx: int, is_bid: bool) -> void:
	var meta: Array = _buyer_meta if is_bid else _seller_meta
	if idx < 0 or idx >= meta.size():
		return
	var o: Dictionary = meta[idx]
	if o.has("mine_sell") or o.has("mine_buy"):
		_open_orders()  # 我的挂单行 → 订单窗管理（取消/查看成交）
		return
	_open_trade(String(o["goods"]), not is_bid, float(o["price"]))


# ============ 交易弹窗 ============

func _open_trade_for(goods: String, p_is_buy: bool, default_qty: int) -> void:
	# 默认价走 Economy.suggest_price（港内最优对手价 → 最近成交价 → 基准价），与模型同一口径
	_open_trade(goods, p_is_buy, Economy.suggest_price(goods, p_is_buy), default_qty)


func _open_trade(goods: String, p_is_buy: bool, p_price: float, default_qty := 1) -> void:
	if _trade == null or not is_instance_valid(_trade):
		_trade = EconTradeDialog.new()
		add_child(_trade)
		_trade.confirmed.connect(_on_trade_confirmed)
	_trade.setup(goods, p_is_buy, p_price)
	var open_qty := default_qty
	if p_is_buy and default_qty <= 1:
		open_qty = EconTradeDialog.last_qty  # 买入记住上次数量, 不回弹到 1
	_trade._qty_slider.value = mini(maxi(open_qty, 1), int(_trade._qty_slider.max_value))
	_trade._on_slider_changed()
	_trade.visible = true
	_trade.reset_size()
	var vp := get_viewport_rect().size
	_trade.global_position = Vector2(
		clampf((vp.x - _trade.size.x) * 0.5, 40.0, vp.x - 80.0),
		clampf((vp.y - _trade.size.y) * 0.55, 40.0, vp.y - 120.0))


func _on_trade_confirmed(goods: String, qty: int, p_price: float, p_is_buy: bool) -> void:
	var err := ""
	if p_is_buy:
		err = Economy.post_buy(goods, qty, p_price)
	else:
		err = Economy.post_sell(goods, qty, p_price)
	if err != "":
		Economy.post_event("挂单失败：%s" % err, "warn")
	refresh()


# ============ 数据 ============

func _collect_offers(goods_id: String, is_bid: bool) -> Array:
	var out: Array = []
	if not is_bid:
		for order in Economy.sell_orders:
			if not Economy.market.is_player_order(order) and String(order.goods) == goods_id:
				out.append({"goods": goods_id, "price": float(order.price), "qty": int(order.qty),
					"from": String(order.get("owner_name", "中立采矿舰队")),
					"left_text": "剩 %.1f天" % Economy.order_remaining_days(order)})
	for f in Economy.berths:
		for o in (f.buy_offers if is_bid else f.sell_offers):
			if String(o["goods"]) == goods_id:
				var d := {}
				for k in o:
					d[k] = o[k]
				d["from"] = f.name
				d["left_s"] = int(ceilf(Economy.dwell_left(f)))   # "剩余"列: 货舰离站倒计时
				out.append(d)
	if is_bid:
		out.sort_custom(func(a, b): return float(a["price"]) > float(b["price"]))
	else:
		out.sort_custom(func(a, b): return float(a["price"]) < float(b["price"]))
	return out


func _open_orders() -> void:
	var root := get_parent()
	if root is EconUiRoot:
		var ui := root as EconUiRoot
		ui.open_panel_add("orders")  # 叠加弹出: 市场不关（2026-10-01 拍板）
		var op = ui._panels.get("orders")
		if op != null and _panel != null:
			op._panel.position = _panel.position + Vector2(60, 80)
			op._user_moved = true


const _icons := {
	"ore": "res://assets/icons/ore.svg", "ice": "res://assets/icons/ice.svg",
	"ship": "res://assets/icons/ship.svg", "license": "res://assets/icons/license.svg",
	"truss": "res://assets/icons/truss.svg",
}


func _cat_icon(gid: String) -> Texture2D:
	var key := ""
	if gid == GameData.FUEL_ID:
		key = "ice"
	elif gid.begins_with("lic:"):
		key = "license"
	elif GameData.is_ship(gid):
		key = "ship"
	elif GameData.is_component(gid):
		key = "truss"
	elif GameData.is_ore(gid):
		key = "ore"
	if key == "" or not _icons.has(key):
		return null
	return load(_icons[key])


func _disp_name(goods: String) -> String:
	if goods.begins_with("lic:"):
		return "许可证·" + GameData.equip_name(goods.substr(4))
	return GameData.good_name(goods)


## 价格单元格：迁移前的旧挂单可能没有 price（0）→ 显示 —，不要谎报 ₡0
func _price_txt(p: float) -> String:
	return EconTheme.money(p) if p > 0.0 else "—"


func _unit_price(goods: String) -> float:
	if goods.begins_with("lic:"):
		return GameData.license_fee(goods.substr(4))
	return GameData.good_unit_price(goods)


func _best_bid(goods: String) -> float:
	var best := -1.0
	for f in Economy.berths:
		var o: Dictionary = f.buy_offer_for(goods)
		if not o.is_empty() and float(o["price"]) > best:
			best = float(o["price"])
	return best
