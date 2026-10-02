class_name EconBuildPanel
extends EconPanelBase

## 建造面板：物流机库（等级制）/ 建造厂·模块化货柜（叠加制）/ 研究站（等级制）。
## 含走私货舰停靠开关（§5.4）。建造耗时，进度条实时刷新。

var _progress_bars := {}  # module_id -> ProgressBar
var _time_labels := {}    # module_id -> 剩余时间 Label
var _status_labels := {}  # module_id -> 标题行状态 Label


func _init() -> void:
	super("空间站建设")


func _panel_min() -> Vector2:
	return Vector2(520, 0)


## 每帧刷新建造进度（否则进度条只在信号重建时画一次, 看起来卡死）
func _process(_delta: float) -> void:
	if not visible or _progress_bars.is_empty():
		return
	for id in _progress_bars:
		if not Economy.module_jobs.has(id):
			continue
		var mj: Dictionary = Economy.module_jobs[id]
		var pct := clampf(1.0 - mj["left"] / mj["total"], 0.0, 1.0)
		(_progress_bars[id] as ProgressBar).value = pct
		if _time_labels.has(id):
			(_time_labels[id] as Label).text = "剩余 %s" % EconTheme.fmt_time(mj["left"])
		if _status_labels.has(id):
			(_status_labels[id] as Label).text = "建造中 %d%%" % int(pct * 100.0)


func _connect_signals() -> void:
	Economy.modules_changed.connect(_sig_refresh)
	Economy.jobs_changed.connect(_sig_refresh)
	Economy.inventory_changed.connect(_sig_refresh)
	Economy.fuel_changed.connect(_sig_refresh)


func _rebuild() -> void:
	_progress_bars.clear()
	_time_labels.clear()
	_status_labels.clear()
	body.add_child(EconTheme.label(
		"首个建造模块是物流机库（只用低级矿链）。建成后点击站体旁模块可打开对应界面。",
		EconTheme.DIM, 12))
	for id in GameData.MODULES:
		body.add_child(_module_card(id))
		body.add_child(EconTheme.hsep(2))


func _module_card(id: String) -> Control:
	var def: Dictionary = GameData.MODULES[id]
	var m: Dictionary = Economy.module_state(id)
	var card := EconTheme.card()
	var v := EconTheme.vbox(5)
	card.add_child(v)

	# -- 标题行 --
	var head := EconTheme.hbox(10)
	v.add_child(head)
	var name_l := EconTheme.label(def["name"], EconTheme.ACCENT, 16)
	name_l.custom_minimum_size.x = 130
	head.add_child(name_l)
	var status := ""
	if Economy.module_jobs.has(id):
		status = "建造中 %d%%" % int(_job_pct(id))
	elif def.has("levels"):
		status = "Lv.%d" % m["level"] if m["built"] else "未建造"
	else:
		status = "×%d %s" % [m["count"], def.get("unit", "座")] if m["built"] else "未建造"
	var status_l := EconTheme.label(status, EconTheme.WARN if Economy.module_jobs.has(id) else EconTheme.TEXT, 14)
	status_l.custom_minimum_size.x = 90
	head.add_child(status_l)
	if Economy.module_jobs.has(id):
		_status_labels[id] = status_l
	var desc := EconTheme.label(str(def["desc"]), EconTheme.DIM, 12)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(desc)

	# -- 等级/叠加效果 --
	v.add_child(_effect_line(id, m))

	# -- 材料需求 --
	var cost: Dictionary = Economy.module_next_cost(id)
	if cost.is_empty():
		v.add_child(EconTheme.label("已达到最高等级/数量上限", EconTheme.GOOD, 13))
	else:
		var rich := EconTheme.rich("")
		rich.text = "[color=#8ea2bd]消耗[/color]  " + EconTheme.bom_rich(cost)
		v.add_child(rich)

	# -- 建造中进度 --
	if Economy.module_jobs.has(id):
		var mj: Dictionary = Economy.module_jobs[id]
		var pb := EconTheme.progress()
		pb.max_value = 1.0
		pb.value = _job_pct(id)
		_progress_bars[id] = pb
		v.add_child(pb)
		var time_l := EconTheme.label("剩余 %s" % EconTheme.fmt_time(mj["left"]), EconTheme.WARN, 12)
		_time_labels[id] = time_l
		v.add_child(time_l)

	# -- 操作行 --
	var ops := EconTheme.hbox(8)
	v.add_child(ops)
	if not Economy.module_jobs.has(id) and not cost.is_empty():
		var btn_text := "建造"
		if def.has("levels") and m["built"]:
			btn_text = "升级至 Lv.%d" % (m["level"] + 1)
		elif not def.has("levels") and m["built"]:
			btn_text = "加装第 %d %s" % [m["count"] + 1, def.get("unit", "座")]
		var reason := Economy.module_build_block(id)
		var b := EconTheme.button(btn_text, func(): _build(id), Vector2(150, 30))
		b.disabled = reason != ""
		b.tooltip_text = reason
		ops.add_child(b)
		var time_l := EconTheme.label("工期约 %s" % EconTheme.fmt_time(_next_time(id)), EconTheme.DIM, 12)
		ops.add_child(time_l)

	# -- 走私开关（机库专属） --
	if id == "hangar" and m["built"]:
		var sm := CheckButton.new()
		sm.text = "允许走私货舰停靠（暗市渠道：收货溢价 30%、许可证便宜 20%；代价：好感/评级/查抄风险，v0.1 风味）"
		sm.button_pressed = m.get("smuggler_ok", false)
		sm.toggled.connect(func(on): Economy.set_smuggler_ok(on))
		v.add_child(sm)
	return card


func _effect_line(id: String, m: Dictionary) -> Label:
	var def: Dictionary = GameData.MODULES[id]
	var txt := ""
	if def.has("levels"):
		var lv := int(m["level"])
		if lv > 0:
			var cur: Dictionary = def["levels"][lv - 1]
			if id == "hangar":
				txt = "当前：泊位 %d · 可停靠 %s" % [cur["berths"], _ship_names(cur["ships"])]
			else:
				txt = "当前：研究槽 %d · 速度 ×%.2f" % [cur["slots"], cur["speed"]]
	else:
		txt = "当前：%d %s" % [int(m["count"]), def.get("unit", "座")]
	return EconTheme.label(txt, EconTheme.DIM, 12)


func _ship_names(ids: Array) -> String:
	var out: Array[String] = []
	for s in ids:
		out.append(GameData.FREIGHTERS[s]["name"])
	return " / ".join(out)


func _job_pct(id: String) -> float:
	var mj: Dictionary = Economy.module_jobs[id]
	return clampf(1.0 - mj["left"] / mj["total"], 0.0, 1.0)


func _next_time(id: String) -> float:
	var def: Dictionary = GameData.MODULES[id]
	if def.has("levels"):
		return def["levels"][Economy.module_level(id)]["time"]
	return def["time"]


func _build(id: String) -> void:
	var err := Economy.build_module(id)
	if err != "":
		Economy.post_event("建造失败：%s" % err, "warn")
	refresh()
