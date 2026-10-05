extends PanelContainer

## MissionOps 任务板 · M1 极简悬浮窗(蓝图 §7/§16.0 SOP)。
## 临时入口: F6 开关(M2 起挂 EconUiRoot 面板链)。
## 结构: 任务卡 4 张(派遣=自动选首个空闲编队) / INVOLVED 3 卡状态 / 最新战报。
## 全静态, EconTheme 色板, 虚拟化留待 M2(ItemList)。

const PHOTON := Color("58a7bf")
const PANEL_BG := Color(0.055, 0.075, 0.10, 0.97)
const ROW_BG := Color(0.07, 0.09, 0.12)
const LINE := Color(0.16, 0.21, 0.27)
const TXT := Color(0.88, 0.93, 1.0)
const DIM := Color(0.52, 0.60, 0.72)
const GOOD := Color(0.45, 0.9, 0.55)
const WARN := Color("f39058")

var _list_box: VBoxContainer
var _team_lab: Label
var _ep_lab: Label
var _report_lab: RichTextLabel


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(560, 0)
	add_theme_stylebox_override("panel", _box(PANEL_BG))
	_build()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F6:
		visible = not visible
		if visible:
			_refresh()


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
	v.add_theme_constant_override("separation", 8)
	add_child(v)

	var head := HBoxContainer.new()
	head.add_child(_label("MISSION BOARD · 任务板", 14, PHOTON))
	_ep_lab = _label("EP 0", 12, GOOD)
	_ep_lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ep_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_ep_lab)
	v.add_child(head)

	_team_lab = _label("编队: —", 12, DIM)
	v.add_child(_team_lab)

	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 6)
	v.add_child(_list_box)

	var prep := Button.new()
	prep.text = "一键备战(雇首名候选 · 建一队)"
	prep.pressed.connect(_one_click_prep)
	v.add_child(prep)

	_report_lab = RichTextLabel.new()
	_report_lab.fit_content = true
	_report_lab.bbcode_enabled = true
	_report_lab.custom_minimum_size = Vector2(0, 64)
	_report_lab.text = "[color=#8599b8]战报: 暂无——派遣一支编队开始。[/color]"
	v.add_child(_report_lab)

	MissionOps.mission_completed.connect(_on_mission_done)
	MissionOps.board_refreshed.connect(_refresh)


func _one_click_prep() -> void:
	# 顺序(审查 P2): 先复用在岗未编队舰长 → 再查容量 → 最后才考虑雇佣, 不先扣钱。
	var cid := ""
	for c in MissionOps.captains:
		if MissionOps.captains[c]["status"] == "idle" and not _cap_in_team(c):
			cid = c
			break
	if cid == "" and MissionOps.teams.size() >= MissionDefs.MAX_TEAMS:
		_flash("行动舰队已满(%d 队)——先完成在途任务或扩容巢穴" % MissionDefs.MAX_TEAMS)
		return
	if cid == "":
		if MissionOps.recruit_pool.is_empty():
			var wait := int(maxf(0.0, MissionOps.pool_refresh_at - Time.get_unix_time_from_system()))
			_flash("招募池待刷新(%d 秒后)" % wait)
			return
		var cand: Dictionary = MissionOps.recruit_pool[0]
		var r: Dictionary = MissionOps.hire_captain(cand["cid"])
		if not r["ok"]:
			_flash(r["why"])
			return
		cid = r["cid"]
	var r2: Dictionary = MissionOps.create_team("一队", cid)
	if not r2["ok"]:
		_flash(r2["why"])
		return
	_refresh()


func _cap_in_team(cid: String) -> bool:
	for tid in MissionOps.teams:
		if MissionOps.teams[tid]["captain_id"] == cid:
			return true
	return false


func _flash(msg: String) -> void:
	_report_lab.text = "[color=#f39058]%s[/color]" % msg


func _on_mission_done(report: Dictionary) -> void:
	_refresh()
	if report.get("success", false):
		_report_lab.text = ("[color=#73e68d]◆ %s · 成功[/color]  +EP%d  +₡%d  (seed #%d)\n[color=#5a6a80]详情结算弹窗 M2 接入[/color]"
			% [report["task"], report["ep"], int(report["credits"]), report["seed"]])
	else:
		_report_lab.text = ("[color=#f39058]◆ %s · 失败[/color]  无奖励 (seed #%d)"
			% [report["task"], report["seed"]])


func _refresh() -> void:
	for c in _list_box.get_children():
		c.queue_free()
	_ep_lab.text = "EP %d" % MissionOps.ep()
	var idle := MissionOps.first_idle_team()
	if idle != "":
		_team_lab.text = "编队: %s · 在岗" % MissionOps.teams[idle]["name"]
	else:
		_team_lab.text = "编队: 无可用(先一键备战)"
	for tid in MissionDefs.TASKS:
		var def: Dictionary = MissionDefs.TASKS[tid]
		var row := HBoxContainer.new()
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ok := idle != ""
		info.add_child(_label("%s  [%s · %s · %d秒]"
			% [def["name"], def["diff"], MissionDefs.SPEC_LABEL[def["spec"]], int(def["dur_sec"])],
			13, TXT if ok else DIM))
		info.add_child(_label("EP %d · ₡%d · %s" % [def["ep"], int(def["credits"]), def["desc"]],
			11, DIM))
		row.add_child(info)
		var btn := Button.new()
		btn.text = "派遣"
		btn.disabled = not ok
		btn.pressed.connect(_dispatch.bind(tid))
		row.add_child(btn)
		_list_box.add_child(row)


func _dispatch(task_id: String) -> void:
	var tid := MissionOps.first_idle_team()
	if tid == "":
		_flash("无可用编队")
		return
	var r: Dictionary = MissionOps.dispatch(tid, task_id)
	if r["ok"]:
		_refresh()
	else:
		_flash(r["why"])
