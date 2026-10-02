class_name EconHangarPanel
extends EconPanelBase

## 物流机库：泊位状态总览（2026-09-30 市场化改版）。
## 交易已改为"本地市场"挂单制——货舰到港自动与市场挂单成交，此面板只看泊位与停留倒计时。

var _dwell_labels := {}   # Freighter -> Label


func _init() -> void:
	super("物流机库 · 泊位")


func _panel_min() -> Vector2:
	return Vector2(520, 0)


func _connect_signals() -> void:
	Economy.freighters_changed.connect(_sig_refresh)
	Economy.modules_changed.connect(_sig_refresh)
	Economy.fuel_changed.connect(_sig_refresh)
	Economy.money_changed.connect(_sig_refresh)      # 许可证按钮的可用性/价格
	Economy.licenses_changed.connect(_sig_refresh)   # 机库是唯一显示"持有 N 次"的面板


func _process(_delta: float) -> void:
	if not visible or Economy.berths.is_empty():
		return
	for f in Economy.berths:
		if _dwell_labels.has(f) and is_instance_valid(_dwell_labels[f]):
			# 剩余时长走 Economy.dwell_left（单一来源：与超时判定/订单簿同一口径）
			(_dwell_labels[f] as Label).text = "停留剩余 %d 秒" % int(ceilf(Economy.dwell_left(f)))


func _rebuild() -> void:
	_dwell_labels.clear()
	if Economy.module_level("hangar") <= 0:
		body.add_child(EconTheme.label("物流机库未建造——先在空间站建造面板建它。", EconTheme.WARN, 14))
		return

	var lv := Economy.module_level("hangar")
	var lv_def: Dictionary = GameData.MODULES["hangar"]["levels"][lv - 1]
	var head := EconTheme.rich("")
	head.text = "[color=#8ea2bd]泊位[/color] %d/%d    [color=#8ea2bd]可停靠[/color] %s    [color=#8ea2bd]燃料[/color] %d（到港/离港 -%d）" % [
		Economy.berths.size(), lv_def["berths"], _ship_names(lv_def["ships"]),
		int(Economy.fuel), int(GameData.FUEL["visit_cost"])]
	body.add_child(head)
	body.add_child(EconTheme.label("货舰自动与「本地市场」挂单成交，停留 60 秒。", EconTheme.DIM, 12))

	for f in Economy.berths:
		body.add_child(_berth_card(f))
	for i in Economy.berths_available():
		body.add_child(EconTheme.label("泊位 %d：（空闲）等待下一次来船…" % [Economy.berths.size() + i + 1], EconTheme.DIM, 13))

	body.add_child(EconTheme.hsep(4))
	var sm_row := EconTheme.hbox(10)
	body.add_child(sm_row)
	var sm_ok: bool = Economy.module_state("hangar").get("smuggler_ok", false)
	var cost_txt := "召唤走私货舰（燃料 %d + %s）" % [
		int(GameData.FUEL["smuggler_fuel"]), EconTheme.money(GameData.FUEL["smuggler_fee"])]
	var sm_btn := EconTheme.button(cost_txt, _summon_smuggler, Vector2(340, 30))
	sm_btn.disabled = not sm_ok
	sm_btn.tooltip_text = "" if sm_ok else "需在物流机库开启走私停靠"
	sm_row.add_child(sm_btn)
	sm_row.add_child(EconTheme.label("走私船同样自动交易，收货 +30% 溢价、许可证 -20%", EconTheme.DIM, 12))

	# ---- 许可证现货（2026-10-02 补：此前只有文案提到"机库购买"，实际没有入口）----
	# 与货舰渠道并存：货舰浮动价（普通 1.0~1.1×、走私 0.8×），这里是稳定官价。
	body.add_child(EconTheme.hsep(4))
	body.add_child(_section("许可证现货 · 官价（材料成本 ×%d%%）" % int(GameData.LICENSE_FEE_RATE * 100.0)))
	for equip in GameData.equip_ids():
		body.add_child(_license_row(equip))


func _berth_card(f: Freighter) -> Control:
	var card := EconTheme.card()
	var v := EconTheme.vbox(4)
	card.add_child(v)
	var head := EconTheme.hbox(8)
	v.add_child(head)
	var name_l := EconTheme.label(f.name, EconTheme.RARE if f.is_smuggler else EconTheme.TEXT, 14)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_l)
	var dwell_l := EconTheme.label("", EconTheme.WARN, 13)
	_dwell_labels[f] = dwell_l
	head.add_child(dwell_l)
	var pb := EconTheme.progress()
	pb.max_value = f.cap
	pb.value = f.cargo_units
	v.add_child(pb)
	var info := EconTheme.label("舱位 %d/%d · 资金 %s · 自动撮合市场挂单中" % [
		int(f.cargo_units), int(f.cap), EconTheme.money(f.funds)], EconTheme.DIM, 12)
	v.add_child(info)
	return card


func _summon_smuggler() -> void:
	var err := Economy.summon_smuggler()
	if err != "":
		Economy.post_event("召唤失败：%s" % err, "warn")
	refresh()


## 许可证现货行：每张含 license_uses() 次（舰船 3 / 产品 30），买一次到账一整张
func _license_row(equip: String) -> Control:
	var row := EconTheme.hbox(8)
	var uses := GameData.license_uses(equip)
	var nm := EconTheme.label("%s（%d 次/张）" % [GameData.equip_name(equip), uses], EconTheme.TEXT, 13)
	nm.custom_minimum_size.x = 250
	row.add_child(nm)
	var own := int(Economy.licenses.get(equip, 0))
	row.add_child(EconTheme.label("持有 %d 次" % own, EconTheme.GOOD if own > 0 else EconTheme.DIM, 12))
	var fee := GameData.license_fee(equip)
	var price_l := EconTheme.label(EconTheme.money(fee), EconTheme.WARN, 13)
	price_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(price_l)
	var b := EconTheme.button("购买 %d 次" % uses, func(): _buy_license(equip), Vector2(110, 26))
	b.disabled = Economy.money < fee
	row.add_child(b)
	return row


func _buy_license(equip: String) -> void:
	var err := Economy.buy_license(equip, 1)
	if err != "":
		Economy.post_event("购买失败：%s" % err, "warn")
	refresh()


func _ship_names(ids: Array) -> String:
	var out: Array[String] = []
	for s in ids:
		out.append(GameData.FREIGHTERS[s]["name"])
	return " / ".join(out)
