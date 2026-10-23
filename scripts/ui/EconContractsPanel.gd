extends EconPanelBase

var _patrol_labels := {}

func _init() -> void:
	super("生产委托 · 争议星系")
	default_size = Vector2(850, 650)


func _panel_min() -> Vector2:
	return Vector2(660, 400)


func _connect_signals() -> void:
	Economy.diplomacy.changed.connect(_sig_refresh)
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.money_changed.connect(_sig_refresh)
	Economy.research_changed.connect(_sig_refresh)


func _rebuild() -> void:
	_patrol_labels.clear()
	var r: Node = Economy.diplomacy
	r.ensure_board()
	var lore := EconTheme.label("联盟与帝国共同宣称主权，这片星系仍是海盗活动的无主之地。", EconTheme.DIM, 13)
	lore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(lore)
	body.add_child(EconTheme.label("援助一方会引起另一方怀疑。委托接取后不失效；每 3 天补充可接委托。", EconTheme.WARN, 12))
	for fid in r.FACTIONS:
		var review := EconTheme.hbox(8)
		var status := EconTheme.label("%s怀疑 %.0f/300 · %s" % [r.faction_name(fid), r.suspicion[fid], r.stage_name(fid)], EconTheme.TEXT, 13)
		status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		review.add_child(status)
		if float(r.patrols[fid].left) > 0.0:
			var remaining := EconTheme.label("舰队驻留 · 余 %s" % EconTheme.fmt_time(r.patrols[fid].left), EconTheme.WARN, 12)
			_patrol_labels[fid] = remaining
			review.add_child(remaining)
		var faction: String = fid
		var bribe := EconTheme.button("贿赂 %s · -100" % EconTheme.money(r.BRIBE_PRICE), func(): _result(r.bribe(faction)))
		bribe.disabled = not r.inspectors[fid] or r.stage(fid) != 1 or Economy.money < r.BRIBE_PRICE
		review.add_child(bribe)
		body.add_child(review)
	for fid in r.FACTIONS:
		body.add_child(_section(r.faction_name(fid) + " · 生产委托"))
		for item in r.contracts:
			if item.faction == fid:
				body.add_child(_contract_card(item))


func _contract_card(item: Dictionary) -> Control:
	var card := EconTheme.card()
	var box := EconTheme.vbox(6)
	card.add_child(box)
	var head := EconTheme.hbox(8)
	box.add_child(head)
	var title := EconTheme.label(item.title, EconTheme.TEXT, 14)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var id: String = item.id
	var r: Node = Economy.diplomacy
	var text := {"available": "接受委托", "accepted": "交付库存", "completed": "已完成"}
	var action := EconTheme.button(text[item.status], func(): _result(r.accept(id) if item.status == "available" else r.deliver(id)))
	action.disabled = item.status == "completed" or (item.status == "accepted" and not Economy.can_pay(item.cost))
	action.tooltip_text = "库存不足，补齐后即可交付" if item.status == "accepted" and not Economy.can_pay(item.cost) else ""
	head.add_child(action)
	var materials := EconTheme.rich("")
	materials.text = "交付：" + EconTheme.bom_rich(item.cost)
	box.add_child(materials)
	box.add_child(EconTheme.label("报酬 %s · 永久蓝图：%s%s" % [EconTheme.money(item.money), GameData.good_name(item.blueprint),
		"（已拥有）" if Economy.blueprints.has(item.blueprint) else ""], EconTheme.GOOD, 12))
	box.add_child(EconTheme.label("完成后%s怀疑 +35" % r.faction_name(r.opposite(item.faction)), EconTheme.WARN, 12))
	return card


func _result(error: String) -> void:
	if error != "": Economy.post_event(error, "warn")
	refresh()


func _process(_delta: float) -> void:
	if not visible: return
	for fid in _patrol_labels:
		if is_instance_valid(_patrol_labels[fid]):
			_patrol_labels[fid].text = "舰队驻留 · 余 %s" % EconTheme.fmt_time(Economy.diplomacy.patrols[fid].left)
