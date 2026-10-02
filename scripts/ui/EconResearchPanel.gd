class_name EconResearchPanel
extends EconPanelBase

## 研究站：逆向等级 → 原图蓝图 → ME/TE 研究（§4）。T2 仅占位（§4.4 拍板）。

var _job_bars: Array = []


func _init() -> void:
	super("研究站 · 逆向与原图")


func _panel_min() -> Vector2:
	return Vector2(600, 0)


func _connect_signals() -> void:
	Economy.research_changed.connect(_sig_refresh)
	Economy.jobs_changed.connect(_sig_refresh)
	Economy.licenses_changed.connect(_sig_refresh)
	Economy.modules_changed.connect(_sig_refresh)


func _process(_delta: float) -> void:
	if not visible or _job_bars.is_empty():
		return
	for e in _job_bars:
		var job: Dictionary = e["job"]
		if Economy.research_jobs.has(job):
			(e["bar"] as ProgressBar).value = clampf(1.0 - job["left"] / job["total"], 0.0, 1.0)


func _rebuild() -> void:
	_job_bars.clear()
	var lv := Economy.module_level("research")
	if lv <= 0:
		body.add_child(EconTheme.label("研究站未建造——科技主线（逆向→原图→ME/TE）从这里开始。", EconTheme.WARN, 14))
		return

	var head := EconTheme.rich("")
	head.text = "[color=#8ea2bd]研究站[/color] Lv.%d    [color=#8ea2bd]研究槽[/color] %d/%d    [color=#8ea2bd]速度[/color] ×%.2f" % [
		lv, Economy.research_jobs.size(), Economy.research_slots(), Economy.research_speed()]
	body.add_child(head)
	body.add_child(EconTheme.label(
		"路径：许可证生产（每批/每艘 逆向+1）→ 攒满研制原图（免许可费）→ 原图继续 ME 材料-2%/级 · TE 工期-4%/级",
		EconTheme.DIM, 12))

	# ---- 进行中研究 ----
	if not Economy.research_jobs.is_empty():
		body.add_child(_section("进行中"))
		for job in Economy.research_jobs:
			var kind_txt: String = {"blueprint": "研制原图", "me": "材料研究 ME", "te": "建造研究 TE"}[job["kind"]]
			var row := EconTheme.hbox(8)
			var name_l := EconTheme.label("%s · %s" % [kind_txt, GameData.equip_name(job["equip"])], EconTheme.TEXT, 13)
			name_l.custom_minimum_size.x = 260
			row.add_child(name_l)
			var pb := EconTheme.progress()
			pb.max_value = 1.0
			pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pb.value = clampf(1.0 - job["left"] / job["total"], 0.0, 1.0)
			row.add_child(pb)
			var t := EconTheme.label(EconTheme.fmt_time(job["left"]), EconTheme.WARN, 12)
			t.custom_minimum_size.x = 80
			row.add_child(t)
			body.add_child(row)
			_job_bars.append({"bar": pb, "job": job})

	# ---- 设备研究行 ----
	body.add_child(_section("设备研究"))
	for equip in GameData.equip_ids():
		body.add_child(_equip_row(equip))

	# ---- T2 占位（§4.4：暂不设计） ----
	body.add_child(_section("T2 科技"))
	var t2_card := EconTheme.card()
	var t2v := EconTheme.vbox(4)
	t2_card.add_child(t2v)
	var t2row := EconTheme.hbox(10)
	t2v.add_child(t2row)
	var t2btn := EconTheme.button("T2 科技化（占位）", func(): pass, Vector2(180, 30))
	t2btn.disabled = true
	t2btn.tooltip_text = "T2 暂不设计（2026-09-30 拍板）：条件为原图 ME+TE 达标 + 研究站 Lv≥2 + 稀有矿投入"
	t2row.add_child(t2btn)
	t2row.add_child(EconTheme.label("需原图 ME+TE 达标 + 研究站 Lv≥2 + 稀有矿投入（活性纳米矿+辉钼晶）——具体规则留待后续版本", EconTheme.DIM, 12))
	body.add_child(t2_card)


func _equip_row(equip: String) -> Control:
	var card := EconTheme.card()
	var v := EconTheme.vbox(3)
	card.add_child(v)

	var head := EconTheme.hbox(10)
	v.add_child(head)
	var name_l := EconTheme.label(GameData.equip_name(equip), EconTheme.TEXT, 14)
	name_l.custom_minimum_size.x = 210
	head.add_child(name_l)

	# 逆向进度
	var rev := int(Economy.reverse.get(equip, 0))
	var rev_max := GameData.reverse_max(equip)
	var rev_pb := EconTheme.progress()
	rev_pb.max_value = rev_max
	rev_pb.value = rev
	rev_pb.custom_minimum_size.x = 110
	head.add_child(rev_pb)
	var rev_l := EconTheme.label("逆向 %d/%d" % [rev, rev_max], EconTheme.DIM, 12)
	rev_l.custom_minimum_size.x = 80
	head.add_child(rev_l)

	# 原图状态 / 研制按钮
	if Economy.blueprints.has(equip):
		var own := EconTheme.label("原图 ✓", EconTheme.GOOD, 13)
		own.custom_minimum_size.x = 70
		head.add_child(own)
	else:
		var reason := Economy.research_block_reason("blueprint", equip)
		var bp := EconTheme.button("研制原图", func(): _research("blueprint", equip), Vector2(100, 26))
		bp.disabled = reason != ""
		bp.tooltip_text = reason + "（需逆向满级后到研究站研制）"
		head.add_child(bp)

	# ME/TE（仅原图持有者）
	if Economy.blueprints.has(equip):
		var me := int(Economy.me_levels.get(equip, 0))
		var te := int(Economy.te_levels.get(equip, 0))
		var me_reason := Economy.research_block_reason("me", equip)
		var te_reason := Economy.research_block_reason("te", equip)
		var me_btn := EconTheme.button("ME +%d/10" % me, func(): _research("me", equip), Vector2(96, 26))
		me_btn.disabled = me_reason != ""
		me_btn.tooltip_text = me_reason
		head.add_child(me_btn)
		var te_btn := EconTheme.button("TE +%d/10" % te, func(): _research("te", equip), Vector2(96, 26))
		te_btn.disabled = te_reason != ""
		te_btn.tooltip_text = te_reason
		head.add_child(te_btn)
		var eff := EconTheme.label("材料 -%d%% · 工期 -%d%%" % [
			me * int(GameData.RESEARCH["me_pct"] * 100),
			te * int(GameData.RESEARCH["te_pct"] * 100)], EconTheme.GOOD, 12)
		head.add_child(eff)
	return card


func _research(kind: String, equip: String) -> void:
	var err := Economy.start_research(kind, equip)
	if err != "":
		Economy.post_event("研究失败：%s" % err, "warn")
	refresh()
