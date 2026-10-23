extends PanelContainer

## M2: KILLREPORT 战报弹窗(蓝图 §7 v4u 简化×渲染风)
## 监听 MissionOps.mission_completed 信号, 自动弹出显示战报。
## v4u 结构: 头栏→meta→LOOT 底色行→双按钮;  F7 手动查看最近战报。

signal confirmed

const PHOTON := Color("58a7bf")
const PANEL_BG := Color(0.05, 0.07, 0.09, 0.98)
const LINE := Color(0.16, 0.21, 0.27)
const TXT := Color(0.88, 0.93, 1.0)
const DIM := Color(0.52, 0.60, 0.72)
const GOOD := Color(0.45, 0.9, 0.55)
const WARN := Color("f39058")
const RARE_C := Color("cc99ff")

var _title: Label
var _meta: Label
var _victim: Label
var _members_box: VBoxContainer
var _loot_box: VBoxContainer
var _total: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(480, 0)
	add_theme_stylebox_override("panel", _box(PANEL_BG))
	_build()
	MissionOps.mission_completed.connect(_on_report)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F7:
		var r: Dictionary = MissionOps.last_report()
		if not r.is_empty():
			_show_report(r)
			visible = true


func _box(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	return sb


func _label(txt: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _build() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)

	var bar := HBoxContainer.new()
	_title = _label("☠ KILL REPORT", 15, WARN)
	bar.add_child(_title)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(24, 24)
	close.pressed.connect(func(): visible = false)
	bar.add_child(close)
	v.add_child(bar)

	_meta = _label("", 11, DIM)
	v.add_child(_meta)

	_victim = _label("", 12, TXT)
	v.add_child(_victim)

	v.add_child(_label("INVOLVED", 11, PHOTON))
	_members_box = VBoxContainer.new()
	v.add_child(_members_box)

	v.add_child(_label("LOOT", 11, PHOTON))
	_loot_box = VBoxContainer.new()
	v.add_child(_loot_box)

	_total = _label("", 13, GOOD)
	v.add_child(_total)

	var btns := HBoxContainer.new()
	var log_btn := Button.new()
	log_btn.text = "存入日志"
	log_btn.custom_minimum_size = Vector2(100, 28)
	log_btn.pressed.connect(func(): visible = false)
	btns.add_child(log_btn)
	var ok_btn := Button.new()
	ok_btn.text = "确认 · 收取战利品"
	ok_btn.custom_minimum_size = Vector2(160, 28)
	ok_btn.pressed.connect(func():
		confirmed.emit()
		visible = false
	)
	btns.add_child(ok_btn)
	v.add_child(btns)


func _on_report(r: Dictionary) -> void:
	_show_report(r)
	visible = true


func _show_report(r: Dictionary) -> void:
	# 头栏 + meta
	var task: String = str(r.get("task", "?"))
	var success: bool = bool(r.get("success", false))
	var partial: bool = bool(r.get("partial", false))
	var result_label: String = "成功" if success else ("部分成功" if partial else "失败")
	_title.text = ("☠ %s · %s" % [task, result_label])
	_meta.text = "seed #%d · %.0f秒" % [int(r.get("seed", 0)), float(r.get("duration", 0))]

	# 受害者
	var victim: Dictionary = r.get("victim", {})
	_victim.text = "目标: %s(%s · %s)" % [victim.get("name", "?"),
		victim.get("ship", "?"), victim.get("corporation", "?")]

	# 参战方
	for c in _members_box.get_children():
		c.queue_free()
	var members: Array = r.get("members", [])
	for m in members:
		var line: String = "%s · %s" % [str(m.get("name", "?")), str(m.get("role", ""))]
		if m.get("final_blow", false):
			line += " [FINAL BLOW]"
		_members_box.add_child(_label(line, 11, TXT if m.get("final_blow") else DIM))

	# 战利品(底色行)
	for c in _loot_box.get_children():
		c.queue_free()
	var loot: Dictionary = r.get("loot", {})
	var total_credits: float = 0.0
	var des_list: Array = loot.get("destroyed", [])
	var drop_list: Array = loot.get("dropped", [])
	for item in des_list:
		var row := _loot_row(item, true)
		_loot_box.add_child(row)
	for item in drop_list:
		var row := _loot_row(item, false)
		_loot_box.add_child(row)
	if r.has("credits"):
		total_credits = float(r["credits"])
		if total_credits > 0:
			_loot_box.add_child(_loot_label("信用点 ₡%d" % int(total_credits), GOOD))
	# 总计
	if success or partial:
		_total.text = "总收益: EP+%d · ₡%d%s" % [int(r.get("ep", 0)), int(total_credits),
			" (部分×0.6)" if partial else ""]
	else:
		_total.text = "任务失败 · 无奖励"
	if r.has("route_safety_gain"):
		_total.text += " · 航道安全+%.1f" % float(r.route_safety_gain)
	elif r.get("route_safety_pending", false):
		_total.text += " · 航道安全收益待结算"


func _loot_row(item: Dictionary, destroyed: bool) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	if destroyed:
		sb.bg_color = Color(0.5, 0.25, 0.15, 0.15)
		sb.border_color = Color(0.65, 0.35, 0.2, 0.5)
	else:
		sb.bg_color = Color(0.2, 0.5, 0.3, 0.12)
		sb.border_color = Color(0.25, 0.5, 0.35, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	var label_txt := "%s%s ×%d" % [str(item.get("label", "?")),
		" (" + str(item.get("slot", "")) + ")" if item.get("slot") else "",
		int(item.get("qty", 1))]
	var l := _label(label_txt, 11, WARN if destroyed else GOOD)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	p.add_child(h)
	return p


func _loot_label(txt: String, col: Color) -> Label:
	return _label(txt, 11, col)
