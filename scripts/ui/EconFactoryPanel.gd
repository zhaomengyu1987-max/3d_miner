class_name EconFactoryPanel
extends EconPanelBase

## 建造厂：组件（可手搓）/ 小型产品 / 舰船 制造（§3/§5.1）。
## 许可证次数制：无原图时消耗许可证；有原图免许可费并享受 ME/TE。
## 产线并行：1 手工线 + 每座建造厂 +2。

var _job_bars: Array = []  # [{bar, job}]
var _left_scroll: ScrollContainer
var _right_scroll: ScrollContainer


func _init() -> void:
	super("建造厂 · 制造")
	_own_scroll = true  # 双栏自管滚动: 左右各自独立滑块


func _collect_scrolls() -> Array:
	var out := []
	if _left_scroll != null:
		out.append(_left_scroll)
	if _right_scroll != null:
		out.append(_right_scroll)
	return out


func _panel_min() -> Vector2:
	return Vector2(640, 0)


func _connect_signals() -> void:
	Economy.jobs_changed.connect(_sig_refresh)
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.licenses_changed.connect(_sig_refresh)
	Economy.research_changed.connect(_sig_refresh)
	Economy.modules_changed.connect(_sig_refresh)


func _process(_delta: float) -> void:
	if not visible or _job_bars.is_empty():
		return
	for e in _job_bars:
		var job: Dictionary = e["job"]
		if Economy.prod_jobs.has(job):
			(e["bar"] as ProgressBar).value = clampf(1.0 - job["left"] / job["total"], 0.0, 1.0)


func _rebuild() -> void:
	_job_bars.clear()
	var factories := Economy.factory_count()

	var head := EconTheme.rich("")
	head.text = "[color=#8ea2bd]产线[/color] %d/%d    [color=#8ea2bd]排队[/color] %d 单    [color=#8ea2bd]建造厂[/color] %d 座（工期 -%d%% · 材料 -%d%%）" % [
		Economy.prod_jobs.size(), Economy.max_lines(), Economy.order_queue.size(), factories,
		factories * int(GameData.ECON["factory_time_pct"] * 100),
		factories * int(GameData.ECON["factory_mat_pct"] * 100)]
	body.add_child(head)
	if factories <= 0:
		body.add_child(EconTheme.label(
			"无建造厂：组件可手搓（1 条手工产线）；小型产品与舰船需要先建造厂。", EconTheme.WARN, 12))
	body.add_child(EconTheme.label(
		"产线满时继续点击制造会自动排队（下单即锁料，取消全额退还）。", EconTheme.DIM, 12))

	# ---- 双栏: 左=物品目录, 右=制造进度/排队（各自独立滚动, 2026-09-30 拍板） ----
	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.collapsed = false
	cols.add_theme_constant_override("separation", 0)
	body.add_child(cols)
	var left_scroll := ScrollContainer.new()
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	left_scroll.custom_minimum_size = Vector2(0, 0)
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left_scroll)
	_left_scroll = left_scroll
	var left := EconTheme.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)
	var right_scroll := ScrollContainer.new()
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	right_scroll.custom_minimum_size = Vector2(240, 0)
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(right_scroll)
	_right_scroll = right_scroll
	var right := EconTheme.vbox(8)
	right_scroll.add_child(right)

	left.add_child(_section("空间站组件（矿石直接制造）"))
	for id in GameData.COMPONENTS:
		left.add_child(_equip_row(id))
	left.add_child(_section("小型产品（许可证/原图）"))
	for id in GameData.PRODUCTS:
		left.add_child(_equip_row(id))
	left.add_child(_section("舰船（纯商品：卖给来访货舰——玩家不操舰）"))
	for id in GameData.SHIPS:
		left.add_child(_equip_row(id))

	right.add_child(_section("进行中"))
	if Economy.prod_jobs.is_empty():
		right.add_child(EconTheme.label("（产线空闲）", EconTheme.DIM, 13))
	for job in Economy.prod_jobs:
		right.add_child(_job_row(job))
	right.add_child(_section("排队中"))
	if Economy.order_queue.is_empty():
		right.add_child(EconTheme.label("（无排队订单）", EconTheme.DIM, 13))
	for i in Economy.order_queue.size():
		right.add_child(_order_row(i))


func _job_row(job: Dictionary) -> Control:
	var row := EconTheme.vbox(3)
	var name_l := EconTheme.label("%s ×%d" % [
		GameData.good_name(job["equip"]), job["batches"]], EconTheme.TEXT, 13)
	row.add_child(name_l)
	var pb := EconTheme.progress()
	pb.max_value = 1.0
	pb.value = clampf(1.0 - job["left"] / job["total"], 0.0, 1.0)
	row.add_child(pb)
	var t := EconTheme.label("剩余 %s" % EconTheme.fmt_time(job["left"]), EconTheme.WARN, 12)
	row.add_child(t)
	_job_bars.append({"bar": pb, "job": job})
	return row


func _order_row(i: int) -> Control:
	var order: Dictionary = Economy.order_queue[i]
	var row := EconTheme.hbox(6)
	var oname := EconTheme.label("%s ×%d" % [
		GameData.good_name(order["equip"]), order["batches"]], EconTheme.DIM, 13)
	oname.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(oname)
	var idx: int = i
	row.add_child(EconTheme.button("取消", func(): _cancel(idx), Vector2(60, 24)))
	return row


func _equip_row(equip: String) -> Control:
	var card := EconTheme.card()
	var v := EconTheme.vbox(3)
	card.add_child(v)

	var head := EconTheme.hbox(10)
	v.add_child(head)
	var name_text := GameData.good_name(equip)
	if GameData.is_product(equip):
		name_text += "（批量 %d）" % GameData.PRODUCTS[equip]["batch"]
	var name_l := EconTheme.label(name_text, EconTheme.TEXT, 14)
	name_l.custom_minimum_size.x = 240
	head.add_child(name_l)

	# 许可证状态
	if not GameData.is_component(equip):
		var lic := EconTheme.label(_license_text(equip), _license_color(equip), 12)
		lic.custom_minimum_size.x = 190
		head.add_child(lic)

	var t := EconTheme.label("%s/批" % EconTheme.fmt_time(Economy.effective_time(equip)), EconTheme.DIM, 12)
	head.add_child(t)

	var rich := EconTheme.rich("")
	rich.text = "[color=#8ea2bd]BOM[/color]  " + EconTheme.bom_rich(Economy.effective_materials(equip))
	v.add_child(rich)

	var ops := EconTheme.hbox(6)
	v.add_child(ops)
	for n: int in [1, 5]:
		var batches: int = n
		var reason := Economy.production_block_reason(equip, batches)
		var b := EconTheme.button("制造 ×%d" % batches, func(): _produce(equip, batches), Vector2(110, 26))
		b.disabled = reason != ""
		b.tooltip_text = reason
		ops.add_child(b)
	return card


func _license_text(equip: String) -> String:
	if Economy.blueprints.has(equip):
		return "原图已获（免许可费）"
	var uses := int(Economy.licenses.get(equip, 0))
	if uses > 0:
		return "许可证 ×%d 次" % uses
	return "无许可证（机库购买）"


func _license_color(equip: String) -> Color:
	if Economy.blueprints.has(equip):
		return EconTheme.GOOD
	if int(Economy.licenses.get(equip, 0)) > 0:
		return EconTheme.WARN
	return EconTheme.BAD


func _produce(equip: String, batches: int) -> void:
	var err := Economy.start_production(equip, batches)
	if err != "":
		Economy.post_event("制造失败：%s" % err, "warn")
	refresh()


func _cancel(index: int) -> void:
	Economy.cancel_order(index)
	refresh()
