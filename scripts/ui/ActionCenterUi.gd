extends PanelContainer

## MissionOps 行动中心 · 可玩 MVP 主界面(蓝图 §16 + 长程施工令 2026-10-05)
## 一个窗口完成全部核心操作: 选队伍→选任务→派遣→看结果→成长→再派。
## F6 或点击巢穴打开同一窗口。四个分页: 行动 / 酒馆 / 舰船装配 / 战报。

signal dispatch_requested(team_id: String, task_id: String)

const PHOTON := Color("58A7bf")
const PANEL_BG := Color(0.05, 0.07, 0.09, 0.97)
const PANEL2 := Color(0.07, 0.09, 0.12, 0.95)
const LINE := Color(0.16, 0.21, 0.27)
const TXT := Color(0.88, 0.93, 1.0)
const DIM := Color(0.52, 0.60, 0.72)
const GOOD := Color(0.45, 0.9, 0.55)
const WARN := Color("f39058")
const AMBER := Color("e0b34c")

var _tabs: TabContainer
var _main_page: VBoxContainer
var _tavern_page: VBoxContainer
var _ships_page: VBoxContainer
var _reports_page: VBoxContainer

# 顶部状态
var _money_lab: Label
var _ep_lab: Label
var _fleet_lab: Label

# 左栏: 队伍
var _team_list: VBoxContainer
var _selected_team: String = ""

# 中栏: 任务
var _task_list: VBoxContainer
var _selected_task: String = ""

# 右栏: 行动详情
var _detail_box: VBoxContainer
var _detail_team: Label
var _detail_task: Label
var _detail_gaps: Label
var _detail_prob: Label
var _detail_rewards: Label
var _dispatch_btn: Button

# 底部: 行动记录
var _log_box: HBoxContainer
var _log_label: RichTextLabel

# 酒馆页
var _tavern_candidates: VBoxContainer
var _tavern_roster: VBoxContainer

# 舰船页
var _ship_roster: VBoxContainer
var _ship_slots: HBoxContainer
var _equip_inventory: VBoxContainer
var _selected_ship: String = ""

# 战报页
var _reports_list: VBoxContainer


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 40
	offset_top = 30
	offset_right = -40
	offset_bottom = -30
	add_theme_stylebox_override("panel", _box(PANEL_BG, 2))
	_build()
	MissionOps.mission_completed.connect(_on_mission_done)
	MissionOps.board_refreshed.connect(_refresh_all)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F6:
		visible = not visible
		if visible:
			_refresh_all()


# ── 工厂函数 ──
func _box(bg: Color, bw := 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = LINE
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _label(txt: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _btn(txt: String, cb: Callable, minsize := Vector2(80, 26)) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = minsize
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(cb)
	return b


# ── 构建主界面 ──
func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	_build_top_bar(root)
	_build_tab_container(root)
	_build_main_page()
	_build_tavern_page()
	_build_ships_page()
	_build_reports_page()


func _build_top_bar(parent: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 16)
	parent.add_child(bar)

	var title := _label("行动中心", 16, PHOTON)
	bar.add_child(title)

	_money_lab = _label("₡ 0", 12, GOOD)
	bar.add_child(_money_lab)
	_ep_lab = _label("EP 0", 12, PHOTON)
	bar.add_child(_ep_lab)
	_fleet_lab = _label("队伍 0/0", 12, DIM)
	bar.add_child(_fleet_lab)

	var close := _btn("✕ 关闭", func(): visible = false, Vector2(60, 24))
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar.add_child(close)


func _build_tab_container(parent: VBoxContainer) -> void:
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_constant_override("separation", 4)
	parent.add_child(_tabs)


# ═══════════ 主页(行动) ═══════════
func _build_main_page() -> void:
	_main_page = VBoxContainer.new()
	_main_page.name = "行动"
	_tabs.add_child(_main_page)

	# 三栏
	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.collapsed = false
	_main_page.add_child(cols)

	# 左栏: 队伍
	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size = Vector2(200, 0)
	left_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(left_panel)
	var left_v := VBoxContainer.new()
	left_v.add_theme_constant_override("separation", 4)
	left_panel.add_child(left_v)
	left_v.add_child(_label("行动队", 12, PHOTON))
	_team_list = VBoxContainer.new()
	_team_list.add_theme_constant_override("separation", 2)
	left_v.add_child(_team_list)
	var create_team_btn := _btn("+ 新建队伍", _on_create_team)
	left_v.add_child(create_team_btn)

	# 中栏: 任务
	var mid_panel := PanelContainer.new()
	mid_panel.custom_minimum_size = Vector2(260, 0)
	mid_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(mid_panel)
	var mid_v := VBoxContainer.new()
	mid_v.add_theme_constant_override("separation", 4)
	mid_panel.add_child(mid_v)
	mid_v.add_child(_label("任务", 12, PHOTON))
	_task_list = VBoxContainer.new()
	_task_list.add_theme_constant_override("separation", 2)
	mid_v.add_child(_task_list)

	# 右栏: 行动详情
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(220, 0)
	right_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(right_panel)
	var right_v := VBoxContainer.new()
	right_v.add_theme_constant_override("separation", 4)
	right_panel.add_child(right_v)
	right_v.add_child(_label("行动详情", 12, PHOTON))
	_detail_box = right_v

	_detail_team = _label("未选择队伍", 11, DIM)
	right_v.add_child(_detail_team)
	_detail_task = _label("未选择任务", 11, DIM)
	right_v.add_child(_detail_task)
	_detail_gaps = _label("", 10, WARN)
	right_v.add_child(_detail_gaps)
	_detail_prob = _label("", 12, PHOTON)
	right_v.add_child(_detail_prob)
	_detail_rewards = _label("", 10, DIM)
	right_v.add_child(_detail_rewards)

	_dispatch_btn = _btn("派 遣", _on_dispatch, Vector2(160, 36))
	_dispatch_btn.add_theme_font_size_override("font_size", 15)
	_dispatch_btn.disabled = true
	right_v.add_child(_dispatch_btn)

	# 底部: 行动记录
	var log_panel := PanelContainer.new()
	log_panel.custom_minimum_size = Vector2(0, 60)
	log_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	_main_page.add_child(log_panel)
	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.fit_content = true
	_log_label.scroll_active = true
	_log_label.text = "[color=#5a6a80]行动记录: 暂无——派遣一支队伍开始[/color]"
	log_panel.add_child(_log_label)


# ═══════════ 酒馆页 ═══════════
func _build_tavern_page() -> void:
	_tavern_page = VBoxContainer.new()
	_tavern_page.name = "酒馆"
	_tabs.add_child(_tavern_page)

	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tavern_page.add_child(cols)

	# 左: 候选
	var cand_panel := PanelContainer.new()
	cand_panel.custom_minimum_size = Vector2(300, 0)
	cand_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(cand_panel)
	var cand_v := VBoxContainer.new()
	cand_v.add_theme_constant_override("separation", 4)
	cand_panel.add_child(cand_v)
	cand_v.add_child(_label("候选人", 12, PHOTON))
	_tavern_candidates = VBoxContainer.new()
	_tavern_candidates.add_theme_constant_override("separation", 4)
	cand_v.add_child(_tavern_candidates)

	# 右: 在册
	var rost_panel := PanelContainer.new()
	rost_panel.custom_minimum_size = Vector2(300, 0)
	rost_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(rost_panel)
	var rost_v := VBoxContainer.new()
	rost_v.add_theme_constant_override("separation", 4)
	rost_panel.add_child(rost_v)
	rost_v.add_child(_label("在册舰长", 12, PHOTON))
	_tavern_roster = VBoxContainer.new()
	_tavern_roster.add_theme_constant_override("separation", 4)
	rost_v.add_child(_tavern_roster)


# ═══════════ 舰船装配页 ═══════════
func _build_ships_page() -> void:
	_ships_page = VBoxContainer.new()
	_ships_page.name = "舰船装配"
	_tabs.add_child(_ships_page)

	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ships_page.add_child(cols)

	# 左: 舰船名册
	var fleet_panel := PanelContainer.new()
	fleet_panel.custom_minimum_size = Vector2(240, 0)
	fleet_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(fleet_panel)
	var fleet_v := VBoxContainer.new()
	fleet_v.add_theme_constant_override("separation", 4)
	fleet_panel.add_child(fleet_v)
	fleet_v.add_child(_label("舰船名册", 12, PHOTON))
	_ship_roster = VBoxContainer.new()
	_ship_roster.add_theme_constant_override("separation", 2)
	fleet_v.add_child(_ship_roster)
	var commission_btn := _btn("+ 启用舰船(从库存)", _on_commission_ship)
	fleet_v.add_child(commission_btn)

	# 中: 四槽
	var slot_panel := PanelContainer.new()
	slot_panel.custom_minimum_size = Vector2(220, 0)
	slot_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(slot_panel)
	var slot_v := VBoxContainer.new()
	slot_v.add_theme_constant_override("separation", 4)
	slot_panel.add_child(slot_v)
	slot_v.add_child(_label("装备槽", 12, PHOTON))
	_ship_slots = HBoxContainer.new()
	_ship_slots.add_theme_constant_override("separation", 8)
	slot_v.add_child(_ship_slots)

	# 右: 库存
	var inv_panel := PanelContainer.new()
	inv_panel.custom_minimum_size = Vector2(240, 0)
	inv_panel.add_theme_stylebox_override("panel", _box(PANEL2))
	cols.add_child(inv_panel)
	var inv_v := VBoxContainer.new()
	inv_v.add_theme_constant_override("separation", 4)
	inv_panel.add_child(inv_v)
	inv_v.add_child(_label("装备与材料库存", 12, PHOTON))
	_equip_inventory = VBoxContainer.new()
	_equip_inventory.add_theme_constant_override("separation", 2)
	inv_v.add_child(_equip_inventory)


# ═══════════ 战报页 ═══════════
func _build_reports_page() -> void:
	_reports_page = VBoxContainer.new()
	_reports_page.name = "战报"
	_tabs.add_child(_reports_page)

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _box(PANEL2))
	_reports_page.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	v.add_child(_label("已完成行动", 12, PHOTON))
	_reports_list = VBoxContainer.new()
	_reports_list.add_theme_constant_override("separation", 6)
	v.add_child(_reports_list)


# ═══════════ 刷新 ═══════════
func _refresh_all() -> void:
	_refresh_top()
	_refresh_teams()
	_refresh_tasks()
	_refresh_details()
	_refresh_tavern()
	_refresh_ships()
	_refresh_reports()


func _refresh_top() -> void:
	_money_lab.text = "₡ %d" % int(Economy.money)
	_ep_lab.text = "EP %d" % MissionOps.ep()
	var busy: int = MissionOps.active.size()
	var total: int = MissionOps.teams.size()
	_fleet_lab.text = "队伍 %d/%d 在途 %d" % [total, MissionOps.fleet_cap(), busy]


func _refresh_teams() -> void:
	for c in _team_list.get_children():
		c.queue_free()
	if MissionOps.teams.is_empty():
		_team_list.add_child(_label("(无队伍——新建一支)", 10, DIM))
		return
	for tid in MissionOps.teams:
		var team: Dictionary = MissionOps.teams[tid]
		var cid: String = team.get("captain_id", "")
		var cap: Dictionary = MissionOps.captains.get(cid, {})
		var cap_name: String = cap.get("name", "?")
		var busy := MissionOps._team_busy(tid)
		var ship_count: int = team.get("ship_uids", []).size()

		var btn := Button.new()
		btn.text = "%s · %s · %d船 %s" % [team.get("name", "?"), cap_name, ship_count,
			"在途" if busy else "空闲"]
		btn.custom_minimum_size = Vector2(0, 28)
		btn.add_theme_font_size_override("font_size", 11)
		btn.toggle_mode = true
		btn.button_pressed = (tid == _selected_team)
		if tid == _selected_team:
			btn.add_theme_color_override("font_color", PHOTON)
		else:
			btn.add_theme_color_override("font_color", TXT if not busy else DIM)
		btn.pressed.connect(_on_select_team.bind(tid))
		_team_list.add_child(btn)


func _refresh_tasks() -> void:
	for c in _task_list.get_children():
		c.queue_free()
	var tasks: Array[Dictionary] = MissionOps.get_board_tasks()
	var current_layer := ""
	for entry in tasks:
		var layer: String = entry["layer"]
		if layer != current_layer:
			current_layer = layer
			_task_list.add_child(_label("── %s ──" % ("常驻" if layer == "resident" else "轮换"), 9, DIM))
		var def: Dictionary = entry["def"]
		var cd_txt := ""
		if entry["cooldown"]:
			var cd: int = int(entry["cd_remain"])
			cd_txt = " [冷却%d:%02d]" % [cd / 60, cd % 60]

		var btn := Button.new()
		btn.text = "%s [%s·%d分%s]" % [def["name"], def["diff"], int(def["dur_sec"]) / 60, cd_txt]
		btn.custom_minimum_size = Vector2(0, 26)
		btn.add_theme_font_size_override("font_size", 10)
		btn.toggle_mode = true
		btn.button_pressed = (entry["id"] == _selected_task)
		btn.add_theme_color_override("font_color",
			PHOTON if entry["id"] == _selected_task else (DIM if entry["cooldown"] else TXT))
		btn.pressed.connect(_on_select_task.bind(entry["id"]))
		_task_list.add_child(btn)


func _refresh_details() -> void:
	if _selected_team == "" or _selected_task == "":
		_detail_team.text = "未选择队伍"
		_detail_task.text = "未选择任务"
		_detail_gaps.text = ""
		_detail_prob.text = ""
		_detail_rewards.text = ""
		_dispatch_btn.disabled = true
		return

	var team: Dictionary = MissionOps.teams.get(_selected_team, {})
	var cid: String = team.get("captain_id", "")
	var cap: Dictionary = MissionOps.captains.get(cid, {})
	var def: Dictionary = MissionDefs.TASKS.get(_selected_task, {})

	_detail_team.text = "队伍: %s(%s)" % [team.get("name", "?"), cap.get("name", "?")]
	_detail_task.text = "任务: %s [%s·%d分]" % [def.get("name", "?"), def.get("diff", "?"),
		int(def.get("dur_sec", 0)) / 60]

	# 装备缺口
	var gaps: Array[String] = MissionOps.check_equip_req(_selected_task, _selected_team)
	if gaps.is_empty():
		_detail_gaps.text = "✓ 条件满足" 
		_detail_gaps.add_theme_color_override("font_color", GOOD)
	else:
		_detail_gaps.text = "✗ 缺: " + " · ".join(gaps) + "\n  → 去舰船装配页安装装备"
		_detail_gaps.add_theme_color_override("font_color", WARN)

	# 成功率
	var p := MissionDefs.success_probability(def, cap)
	_detail_prob.text = "成功率: %d%%" % int(p * 100)
	_detail_prob.add_theme_color_override("font_color", GOOD if p >= 0.6 else (AMBER if p >= 0.4 else WARN))

	# 奖励预览
	var ep_val: int = int(def.get("ep", 0))
	var credits: int = int(def.get("credits", 0))
	var mat_name: String = MissionDefs.EXP_MATERIALS.get(
		MissionDefs.drop_material(def.get("kind", "")), {}).get("label", "")
	_detail_rewards.text = "奖励: EP+%d · ₡%d · %s" % [ep_val, credits, mat_name]

	# 派遣按钮状态
	var can_dispatch := true
	var why := ""
	if MissionOps._team_busy(_selected_team):
		can_dispatch = false
		why = "队伍在途"
	elif not gaps.is_empty():
		can_dispatch = false
		why = "条件不足"
	_dispatch_btn.disabled = not can_dispatch
	_dispatch_btn.text = why if not can_dispatch else "派 遣"


func _refresh_tavern() -> void:
	for c in _tavern_candidates.get_children():
		c.queue_free()
	for c in _tavern_roster.get_children():
		c.queue_free()

	if MissionOps.recruit_pool.is_empty():
		_tavern_candidates.add_child(_label("(招募池空, 等待刷新)", 10, DIM))
	for cand in MissionOps.recruit_pool:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _box(PANEL2))
		_tavern_candidates.add_child(card)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		card.add_child(h)
		var tier_col: Color = RARE_C if cand.get("tier") == "rare" else TXT
		var info := _label("%s [%s·%s] ₡%d" % [cand.get("name", "?"),
			MissionDefs.TIERS[cand.get("tier", "normal")].get("label", ""),
			MissionDefs.SPEC_LABEL.get(cand.get("spec", ""), ""), int(cand.get("fee", 0))],
			11, tier_col)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(info)
		var hire := _btn("雇佣", _on_hire.bind(cand.get("cid", "")))
		h.add_child(hire)

	if MissionOps.captains.is_empty():
		_tavern_roster.add_child(_label("(无在册舰长)", 10, DIM))
	for cid in MissionOps.captains:
		var cap: Dictionary = MissionOps.captains[cid]
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _box(PANEL2))
		_tavern_roster.add_child(card)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		card.add_child(h)
		var status_col := GOOD if cap.get("status") == "idle" else WARN
		var info := _label("%s Lv%d [%s·%s] %s" % [cap.get("name", "?"),
			int(cap.get("level", 1)),
			MissionDefs.TIERS[cap.get("tier", "normal")].get("label", ""),
			MissionDefs.SPEC_LABEL.get(cap.get("spec", ""), ""),
			cap.get("status", "?")], 11, status_col)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(info)
		if cap.get("status") == "idle":
			var fire := _btn("解雇", _on_fire.bind(cid))
			h.add_child(fire)


const RARE_C := Color("cc99ff")


func _refresh_ships() -> void:
	for c in _ship_roster.get_children():
		c.queue_free()
	for c in _ship_slots.get_children():
		c.queue_free()
	for c in _equip_inventory.get_children():
		c.queue_free()

	if MissionOps.fleet.is_empty():
		_ship_roster.add_child(_label("(无名册舰船)", 10, DIM))
	for uid in MissionOps.fleet:
		var ship: Dictionary = MissionOps.fleet[uid]
		var btn := Button.new()
		btn.text = "%s(%s)" % [ship.get("name", "?"),
			GameData.SHIPS.get(ship.get("def_id", ""), {}).get("name", "?")]
		btn.custom_minimum_size = Vector2(0, 26)
		btn.add_theme_font_size_override("font_size", 10)
		btn.toggle_mode = true
		btn.button_pressed = (uid == _selected_ship)
		btn.pressed.connect(_on_select_ship.bind(uid))
		_ship_roster.add_child(btn)

	# 选中舰船的四槽
	if _selected_ship != "" and MissionOps.fleet.has(_selected_ship):
		var ship: Dictionary = MissionOps.fleet[_selected_ship]
		var fitted: Dictionary = ship.get("fitted", {})
		for slot_id in MissionDefs.SLOT_ORDER:
			var eq_id: String = fitted.get(slot_id, "")
			var slot_label: String = MissionDefs.SLOT_LABEL.get(slot_id, slot_id)
			var slot_btn := Button.new()
			if eq_id == "":
				slot_btn.text = "%s\n(空)" % slot_label
				slot_btn.add_theme_color_override("font_color", DIM)
			else:
				var eq_label: String = MissionDefs.EQUIPMENT.get(eq_id.replace("_up", ""), {}).get("label", eq_id)
				slot_btn.text = "%s\n%s" % [slot_label, eq_label + ("+" if eq_id.ends_with("_up") else "")]
				slot_btn.add_theme_color_override("font_color", PHOTON)
			slot_btn.custom_minimum_size = Vector2(90, 48)
			slot_btn.add_theme_font_size_override("font_size", 9)
			slot_btn.pressed.connect(_on_remove_equip.bind(_selected_ship, slot_id))
			_ship_slots.add_child(slot_btn)
	else:
		_ship_slots.add_child(_label("选择左侧舰船查看装备", 10, DIM))

	# 装备库存
	var has_items := false
	for eq_id in MissionOps.inventory:
		var count: int = int(MissionOps.inventory[eq_id])
		if count <= 0:
			continue
		has_items = true
		var label_txt := ""
		if MissionDefs.EQUIPMENT.has(eq_id.replace("_up", "")):
			var eq_def: Dictionary = MissionDefs.EQUIPMENT[eq_id.replace("_up", "")]
			label_txt = "%s %s ×%d" % [eq_def.get("label", eq_id),
				"(升级)" if eq_id.ends_with("_up") else "", count]
		elif MissionDefs.EXP_MATERIALS.has(eq_id):
			label_txt = "[材料] %s ×%d" % [MissionDefs.EXP_MATERIALS[eq_id].get("label", eq_id), count]
		elif eq_id == "frag_generic":
			label_txt = "[碎片] 蓝图碎片 ×%d" % count
		elif eq_id == "reverse_material":
			label_txt = "[素材] 逆向素材 ×%d" % count
		else:
			continue
		var item := _label(label_txt, 10, TXT)
		_equip_inventory.add_child(item)
		# 装备可安装按钮
		if MissionDefs.EQUIPMENT.has(eq_id.replace("_up", "")) and _selected_ship != "":
			var inst := _btn("安装→%s" % MissionOps.fleet.get(_selected_ship, {}).get("name", "?"),
				_on_install_equip.bind(_selected_ship, eq_id), Vector2(120, 20))
			_equip_inventory.add_child(inst)
	if not has_items:
		_equip_inventory.add_child(_label("(库存空)", 10, DIM))


func _refresh_reports() -> void:
	for c in _reports_list.get_children():
		c.queue_free()
	var r: Dictionary = MissionOps.last_report()
	if r.is_empty():
		_reports_list.add_child(_label("(暂无已完成行动)", 10, DIM))
		return
	var success: bool = bool(r.get("success", false))
	var partial: bool = bool(r.get("partial", false))
	var result_txt := "成功" if success else ("部分成功" if partial else "失败")
	var result_col := GOOD if success else (AMBER if partial else WARN)
	var summary := _label("%s · %s · EP+%d · ₡%d" % [r.get("task", "?"), result_txt,
		int(r.get("ep", 0)), int(r.get("credits", 0))], 12, result_col)
	_reports_list.add_child(summary)
	# 战利品
	var loot: Dictionary = r.get("loot", {})
	for item in loot.get("dropped", []):
		_reports_list.add_child(_label("  获得: %s ×%d" % [item.get("label", "?"), int(item.get("qty", 1))], 10, GOOD))
	for item in loot.get("destroyed", []):
		_reports_list.add_child(_label("  焚毁: %s ×%d" % [item.get("label", "?"), int(item.get("qty", 1))], 10, WARN))


# ═══════════ 事件 ═══════════
func _on_select_team(tid: String) -> void:
	_selected_team = tid
	_refresh_teams()
	_refresh_details()


func _on_select_task(task_id: String) -> void:
	_selected_task = task_id
	_refresh_tasks()
	_refresh_details()


func _on_create_team() -> void:
	# 找一个空闲舰长
	var cid := ""
	for c in MissionOps.captains:
		if MissionOps.captains[c]["status"] == "idle":
			var in_team := false
			for tid in MissionOps.teams:
				if MissionOps.teams[tid].get("captain_id", "") == c:
					in_team = true
					break
			if not in_team:
				cid = c
				break
	if cid == "":
		_log_label.text = "[color=#f39058]无可用舰长——先去酒馆雇佣, 或等待在途舰长返回[/color]"
		return
	var team_num: int = MissionOps.teams.size() + 1
	var r: Dictionary = MissionOps.create_team("第%d队" % team_num, cid)
	if not r.get("ok", false):
		_log_label.text = "[color=#f39058]建队失败: %s[/color]" % r.get("why", "?")
		return
	_selected_team = r.get("team_id", "")
	_refresh_all()


func _on_dispatch() -> void:
	if _selected_team == "" or _selected_task == "":
		return
	var r: Dictionary = MissionOps.dispatch(_selected_team, _selected_task)
	if r.get("ok", false):
		var ends: float = float(r.get("ends_wall", 0))
		var remain: int = int(ends - MissionOps._now())
		_log_label.text = "[color=#73e68d]◆ 派遣成功! 剩余 %d:%02d[/color]" % [remain / 60, remain % 60]
		_refresh_all()
	else:
		_log_label.text = "[color=#f39058]派遣失败: %s[/color]" % r.get("why", "?")
		_refresh_details()


func _on_mission_done(report: Dictionary) -> void:
	var partial: bool = bool(report.get("partial", false))
	if report.get("success", false):
		_log_label.text = "[color=#73e68d]◆ %s · 成功 · EP+%d · ₡%d[/color]" % [
			report.get("task", "?"), int(report.get("ep", 0)), int(report.get("credits", 0))]
	elif partial:
		_log_label.text = "[color=#e0b34c]◆ %s · 部分成功 · EP+%d · ₡%d[/color]" % [
			report.get("task", "?"), int(report.get("ep", 0)), int(report.get("credits", 0))]
	else:
		_log_label.text = "[color=#f39058]◆ %s · 失败[/color]" % report.get("task", "?")
	_refresh_all()


func _on_hire(cid: String) -> void:
	var r: Dictionary = MissionOps.hire_captain(cid)
	if not r.get("ok", false):
		_log_label.text = "[color=#f39058]雇佣失败: %s[/color]" % r.get("why", "?")
	_refresh_all()


func _on_fire(cid: String) -> void:
	var r: Dictionary = MissionOps.dismiss_captain(cid)
	if not r.get("ok", false):
		_log_label.text = "[color=#f39058]解雇失败: %s[/color]" % r.get("why", "?")
	_refresh_all()


func _on_select_ship(uid: String) -> void:
	_selected_ship = uid
	_refresh_ships()


func _on_commission_ship() -> void:
	# 找库存中有的船型
	for def_id in GameData.SHIPS:
		if int(Economy.inv.get(def_id, 0)) > 0:
			var r: Dictionary = MissionOps.commission_ship(def_id)
			if r.get("ok", false):
				_selected_ship = r.get("uid", "")
			else:
				_log_label.text = "[color=#f39058]启用失败: %s[/color]" % r.get("why", "?")
			_refresh_all()
			return
	_log_label.text = "[color=#f39058]库存无船——需先建造(或用试玩档)[/color]"


func _on_install_equip(ship_uid: String, eq_id: String) -> void:
	var r: Dictionary = MissionOps.install_equipment(ship_uid, eq_id)
	if not r.get("ok", false):
		_log_label.text = "[color=#f39058]安装失败: %s[/color]" % r.get("why", "?")
	_refresh_ships()


func _on_remove_equip(ship_uid: String, slot: String) -> void:
	var r: Dictionary = MissionOps.remove_equipment(ship_uid, slot)
	if not r.get("ok", false) and r.get("why", "") != "该槽位为空":
		_log_label.text = "[color=#f39058]卸下失败: %s[/color]" % r.get("why", "?")
	_refresh_ships()


## 兼容旧测试(⑬备战顺序: 满编时不扣押金)
func _one_click_prep() -> void:
	_on_create_team()
