class_name EconTradeDialog
extends PanelContainer

## EVE 式交易确认小窗（2026-09-30 拍板：下单时单独弹窗, 避免主窗口信息过载）。
## 买入窗: 单价×数量=预计花费 → 挂买单; 卖出窗: 单价×数量=预计收入 → 挂卖单。
## 轻量自由窗: 标题栏可拖动, ✕ 关闭。

signal confirmed(goods: String, qty: int, price: float, is_buy: bool)

static var last_qty := 1   # 记住上次确认数量（重开弹窗不回弹到顶）
signal dismissed

var goods := ""
var is_buy := true
var price := 0.0        # 打开时的默认价（= Economy.suggest_price, 窗内可改）

var _mode_label: Label
var _qty_slider: HSlider
var _qty_label: Label
var _sum_label: Label
var _warn_label: Label
var _sum_caption: Label
var _ok_btn: Button
var _price_spin: SpinBox
var _dragging := false
var _drag_off := Vector2.ZERO


func _ready() -> void:
	add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.05, 0.07, 0.11, 0.97), EconTheme.ACCENT, 6, 1))
	custom_minimum_size = Vector2(320, 0)
	var v := EconTheme.vbox(8)
	add_child(v)

	# ---- 标题栏（可拖） ----
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", EconTheme.style_box(Color(0.11, 0.15, 0.22, 1.0), EconTheme.BORDER, 0, 1))
	v.add_child(bar)
	var head := EconTheme.hbox(8)
	bar.add_child(head)
	var title_l := EconTheme.label("交易", EconTheme.ACCENT, 14)
	title_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_l.mouse_filter = Control.MOUSE_FILTER_STOP
	title_l.mouse_default_cursor_shape = Control.CURSOR_MOVE
	title_l.gui_input.connect(_on_title_input)
	head.add_child(title_l)
	head.add_child(EconTheme.button("✕", close, Vector2(28, 20)))

	# ---- 方向 + 货物名 ----
	_mode_label = EconTheme.label("", EconTheme.WARN, 14)
	v.add_child(_mode_label)

	# ---- 单价（可改: 限价挂单, 对齐 EVE 的价格输入框语义） ----
	var price_row := EconTheme.hbox(10)
	v.add_child(price_row)
	price_row.add_child(EconTheme.label("单价（可改）", EconTheme.DIM, 12))
	_price_spin = SpinBox.new()
	_price_spin.min_value = 0.01
	_price_spin.max_value = 1000000.0
	_price_spin.step = 0.01
	_price_spin.custom_minimum_size = Vector2(140, 26)
	_price_spin.value_changed.connect(func(_v: float): _update_sum())
	_price_spin.get_line_edit().text_changed.connect(func(_t: String): _update_sum())
	price_row.add_child(_price_spin)
	var ref_l := EconTheme.label("", EconTheme.DIM, 11)
	ref_l.name = "RefPrice"
	price_row.add_child(ref_l)

	# ---- 数量: 数字滑块（2026-09-30 拍板: 不用 1/5/10/全部 按钮） ----
	var qty_row := EconTheme.vbox(4)
	v.add_child(qty_row)
	var qty_head := EconTheme.hbox(8)
	qty_row.add_child(qty_head)
	qty_head.add_child(EconTheme.label("数量", EconTheme.DIM, 12))
	_qty_label = EconTheme.label("1", EconTheme.ACCENT, 15)
	qty_head.add_child(_qty_label)
	_qty_slider = HSlider.new()
	_qty_slider.min_value = 1
	_qty_slider.step = 1
	_qty_slider.custom_minimum_size = Vector2(0, 22)
	_qty_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_qty_slider.value_changed.connect(func(_val: float): _on_slider_changed())
	qty_row.add_child(_qty_slider)

	# ---- 合计 ----
	var sum_row := EconTheme.hbox(10)
	v.add_child(sum_row)
	_sum_caption = EconTheme.label("", EconTheme.DIM, 12)
	sum_row.add_child(_sum_caption)
	_sum_label = EconTheme.label("—", EconTheme.GOOD, 15)
	sum_row.add_child(_sum_label)

	# ---- 限价提示（2026-10-02: 挂价超出货舰可成交区间时明确告知, 避免"挂了永远不成交"）----
	_warn_label = EconTheme.label("", EconTheme.WARN, 12)
	_warn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_warn_label)

	# ---- 按钮 ----
	var ops := EconTheme.hbox(8)
	ops.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(ops)
	_ok_btn = EconTheme.button("确认挂单", _on_confirm, Vector2(130, 30))
	ops.add_child(_ok_btn)
	ops.add_child(EconTheme.button("取消", close, Vector2(90, 30)))

	_refresh_mode()
	_update_sum()


func setup(p_goods: String, p_is_buy: bool, p_price: float) -> void:
	goods = p_goods
	is_buy = p_is_buy
	price = p_price
	if _mode_label != null:
		_refresh_mode()
		_set_price(p_price)                       # 预填参考价 + 同步输入框文本（引擎不会自动回写）
		# 卖出上限=当前库存, 买入上限=500（滑块范围跟随）
		var cap := 500
		if is_buy:
			# 买入上限按可负担封顶(2026-10-01 修硬编码 500): 高价品(舰船)滑块粒度才有意义
			cap = clampi(int(Economy.money / maxf(price, 0.01)), 1, 500)
			if price > 10000.0:
				cap = mini(cap, 10)  # 舰船级单价再收窄
		else:
			if goods.begins_with("lic:"):
				cap = maxi(int(Economy.licenses.get(goods.substr(4), 0)), 1)
			else:
				cap = maxi(Economy.stock(goods), 1)
		_qty_slider.max_value = cap
		_qty_slider.value = mini(int(_qty_slider.value), cap)
		_on_slider_changed()


func _refresh_mode() -> void:
	var mode_txt := "买入 · " if is_buy else "卖出 · "
	var name_txt: String = _disp_name(goods) if goods != "" else "?"
	_mode_label.text = mode_txt + name_txt
	_mode_label.add_theme_color_override("font_color", EconTheme.WARN if is_buy else EconTheme.GOOD)
	_sum_caption.text = "预计花费" if is_buy else "预计收入"
	_sum_caption.add_theme_color_override("font_color", EconTheme.DIM)
	_sum_label.add_theme_color_override("font_color", EconTheme.WARN if is_buy else EconTheme.GOOD)


func _disp_name(g: String) -> String:
	if g.begins_with("lic:"):
		return "许可证·" + GameData.equip_name(g.substr(4))
	return GameData.good_name(g)


func _qty() -> int:
	if _qty_slider == null:
		return 1
	return maxi(int(_qty_slider.value), 1)


func _on_slider_changed() -> void:
	if _qty_label != null:
		_qty_label.text = str(_qty())
	_update_sum()


## 当前限价: 非编辑态以 Range.value 为准。
## 引擎的 SpinBox 在程序化改 value 时不会回写 LineEdit 文本（spin_box.cpp: _value_changed 不调
## _update_text, 只有编辑/失焦事件才刷新）, 所以优先读文本会读到陈旧价。
func _price() -> float:
	if _price_spin == null:
		return maxf(price, 0.01)
	var le := _price_spin.get_line_edit()
	if le != null and le.has_focus() and le.text.strip_edges().is_valid_float():
		return maxf(le.text.strip_edges().to_float(), 0.01)
	return maxf(_price_spin.value, 0.01)


## 程序化设价（同时同步输入框文本, 否则玩家眼里还是旧价）
func _set_price(v: float) -> void:
	if _price_spin == null:
		return
	_price_spin.value = maxf(v, 0.01)
	var le := _price_spin.get_line_edit()
	if le != null:
		le.text = String.num(_price_spin.value, 2)


func _update_sum() -> void:
	if _sum_label == null:
		return
	var p := _price()
	_sum_label.text = EconTheme.money(p * float(_qty()))
	if _warn_label == null:
		return
	if is_buy and not Economy.freighter_sells(goods):
		_warn_label.text = "货舰不出售此货物 —— 挂买不会成交（挂单 3 天后自动撤销）"
		return
	var rg := Economy.fillable_range(goods, is_buy)
	if is_buy and p < rg.x - 0.005:
		_warn_label.text = "出价低于货舰要价下限 %s —— 要等到有船肯降价供货" % EconTheme.money(rg.x)
	elif not is_buy and p > rg.y + 0.005:
		var smug_pct := int(round((float(GameData.FUEL["smuggler_price"]) - 1.0) * 100.0))
		_warn_label.text = "要价高于货舰收购上限 %s —— 除走私船（+%d%%）外无人接手，可能挂到到期退回" % [
			EconTheme.money(rg.y), smug_pct]
	else:
		_warn_label.text = ""


func _on_confirm() -> void:
	var q := _qty()
	if q > 0:
		last_qty = q
		confirmed.emit(goods, q, _price(), is_buy)
	close()


func close() -> void:
	visible = false
	dismissed.emit()


func _on_title_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_dragging = true
		_drag_off = get_global_mouse_position() - global_position


func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		global_position = get_global_mouse_position() - _drag_off
	elif event is InputEventMouseButton and not event.pressed:
		_dragging = false
