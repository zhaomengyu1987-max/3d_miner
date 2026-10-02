class_name EconUiRoot
extends CanvasLayer

## 制造系统 UI 根（Economy autoload 创建）：HUD + 全部面板 + 模块悬浮窗 + 矿石提示。
## - 空间站本体点击 → show_station_popup：小悬浮窗列出各模块方形按钮（未建=灰，建成=亮）
## - 矿石悬停 → show_ore_tip：鼠标旁跟随显示矿种/档位/储量（描边在 BeltOre 侧）
## - ESC 优先关悬浮窗→关面板，全关后落回设置面板

const PanelBase := preload("res://scripts/ui/EconPanelBase.gd")
const InventoryPanel := preload("res://scripts/ui/EconInventoryPanel.gd")
const BuildPanel := preload("res://scripts/ui/EconBuildPanel.gd")
const HangarPanel := preload("res://scripts/ui/EconHangarPanel.gd")
const MarketPanel := preload("res://scripts/ui/EconMarketPanel.gd")
const FactoryPanel := preload("res://scripts/ui/EconFactoryPanel.gd")
const ResearchPanel := preload("res://scripts/ui/EconResearchPanel.gd")
const OrdersPanel := preload("res://scripts/ui/EconOrdersPanel.gd")

## 供 SettingsPanel 静态查询：制造界面是否开着（开则 ESC 不呼出设置）
static var modal_open := false

## 面板全局缩放档位（右下角 －/＋ 调整, 0.6~1.5）
static var ui_scale := 1.0

## 窗口布局持久化（EVE 式: 位置/尺寸/折叠/缩放跨会话记住）
const LAYOUT_PATH := "user://window_layout.json"


static func any_modal_open() -> bool:
	return modal_open


var _panels := {}
var _open_stack: Array = []   # 叠开顺序（ESC 逐层关）
var _popup: PanelContainer
var _popup_layer: CanvasLayer      # 悬浮窗独立高层(16): 面板打开时保持可见可点
var _popup_blocker: Control
var _popup_scroll: ScrollContainer
var _popup_collapsed := false
var _popup_dragging := false
var _popup_drag_off := Vector2.ZERO
var _tip: Label
var _tip_ore: BeltOre


func zoom_step(dir: int) -> void:
	ui_scale = clampf(ui_scale + 0.1 * dir, 0.6, 1.5)
	for p in _panels.values():
		if p.has_method("_apply_zoom"):
			p._apply_zoom()


## EVE only_tint_active_window：活动窗口全亮, 其余微暗
func set_active_panel(active) -> void:
	for p in _panels.values():
		if p.has_method("set_tint"):
			p.set_tint(p == active)


func _ready() -> void:
	add_to_group("econ_ui")
	layer = 15
	_build_popup()
	_build_tip()
	add_child(EconHud.new())
	_panels["inventory"] = InventoryPanel.new()
	_panels["build"] = BuildPanel.new()
	_panels["hangar"] = HangarPanel.new()
	_panels["market"] = MarketPanel.new()
	_panels["factory"] = FactoryPanel.new()
	_panels["research"] = ResearchPanel.new()
	_panels["orders"] = OrdersPanel.new()
	for key in _panels:
		var p = _panels[key]
		add_child(p)
		p.panel_id = key
		p.closed.connect(_on_panel_closed)
	load_window_layout()
	# 调试钩子: ECON_DEBUG_OPEN=market 等环境变量可让指定面板自动打开（截图验证用）
	var dbg := OS.get_environment("ECON_DEBUG_OPEN")
	if dbg != "" and _panels.has(dbg):
		call_deferred("open_panel", dbg)


## ===== 窗口栈叠管理（EVE WindowStack） =====

## 拖动释放: 被拖面板顶边落在某可见面板标题栏区且水平重叠 → 并入（返回是否并入）
func try_stack_on_drop(dragged) -> bool:
	if not (dragged is EconPanelBase) or dragged.stack_host != "" or not dragged.stack_members.is_empty():
		return false
	var dp: PanelContainer = dragged._panel
	for key in _panels:
		var other = _panels[key]
		if other == dragged or not other.visible:
			continue
		if other.stack_host != "":
			continue
		if not (other is EconPanelBase):
			continue
		var op := (other as EconPanelBase)._panel
		# EVE 规格: 水平重叠 + 被拖窗顶边落在目标[标题栏,标题栏+2倍header]区间
		var h_overlap: bool = dp.position.x < op.position.x + op.size.x - 20.0 			and dp.position.x + dp.size.x > op.position.x + 20.0
		var top_in_header: bool = dp.position.y >= op.position.y - 8.0 			and dp.position.y <= op.position.y + 60.0
		if h_overlap and top_in_header:
			(other as EconPanelBase).dock_member(dragged)
			return true
	return false


## 关闭整栈（宿主关闭时全收）
func close_stack(host_id: String) -> void:
	var host = _panels.get(host_id)
	if host == null:
		return
	for mid in (host as EconPanelBase).stack_members.duplicate():
		var mp = _panels.get(mid)
		if mp != null:
			mp.stack_host = ""
			mp.close()
	(host as EconPanelBase).stack_members.clear()
	host.close()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_window_layout()


func _on_panel_closed() -> void:
	modal_open = false
	save_window_layout()


func save_window_layout() -> void:
	var data := {"_ui_scale": ui_scale}
	for key in _panels:
		var pb = _panels[key]
		if pb.get("_panel") == null:
			continue
		data[key] = {"x": pb._panel.position.x, "y": pb._panel.position.y,
			"w": pb._panel.custom_minimum_size.x, "h": pb._panel.custom_minimum_size.y,
			"collapsed": pb._collapsed, "moved": pb._user_moved,
			"split": pb._split_ratio, "vs": pb._vs_ratio, "host": pb.stack_host}
	var f := FileAccess.open(LAYOUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


func load_window_layout() -> void:
	if not FileAccess.file_exists(LAYOUT_PATH):
		return
	var f := FileAccess.open(LAYOUT_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	ui_scale = clampf(float(parsed.get("_ui_scale", 1.0)), 0.6, 1.5)
	for key in parsed:
		if key == "_ui_scale" or not _panels.has(key):
			continue
		var pb = _panels[key]
		var d: Dictionary = parsed[key]
		pb._user_moved = bool(d.get("moved", false))
		var vp := get_viewport().get_visible_rect().size as Vector2
		# 存档宽度钳制到视口 92%（旧存档可能存了超出当前分辨率的宽, 2026-09-30 修出屏）
		var w: float = clampf(float(d.get("w", 0)), 0.0, vp.x * 0.92)
		var h: float = clampf(float(d.get("h", 0)), 0.0, vp.y * 0.92)
		if w > 0.0:
			pb._panel.size = Vector2(w, h)  # 只设 size——min 保持代码声明, 窗口可再缩回
		pb._panel.position = Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
		if bool(d.get("collapsed", false)) and not pb._collapsed:
			pb._toggle_collapse()
		pb._split_ratio = clampf(float(d.get("split", 0.72)), 0.3, 0.8)
		pb._vs_ratio = clampf(float(d.get("vs", 0.5)), 0.2, 0.8)
		pb._apply_zoom()
		pb._size_inited = true   # 有存档布局 → default_size 不参与（存档尺寸优先）
	# 栈关系重放（所有面板就绪后）
	for key in parsed:
		if key == "_ui_scale" or not _panels.has(key):
			continue
		var host_id := str((parsed[key] as Dictionary).get("host", ""))
		if host_id != "" and host_id != key and _panels.has(host_id):
			(_panels[host_id] as EconPanelBase).dock_member(_panels[key])


func open_panel(id: String) -> void:
	if not _panels.has(id):
		return
	close_all()
	hide_station_popup()
	_panels[id].open()
	modal_open = true


func close_all() -> void:
	for p in _panels.values():
		p.close()
	modal_open = false


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	# 悬浮窗标题拖拽: 动作跟随全局鼠标(可拖出标题条范围不脱手)
	if _popup_dragging:
		if event is InputEventMouseMotion:
			_popup.position = _popup.get_global_mouse_position() - _popup_drag_off
			return
		if event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_popup_dragging = false
			return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		hide_station_popup()
		if not _open_stack.is_empty():
			var top: String = _open_stack[-1]
			_open_stack.pop_back()
			if _panels.has(top):
				_panels[top].close()
			modal_open = not _open_stack.is_empty()
			get_viewport().set_input_as_handled()
			return
		for p in _panels.values():
			if p.visible:
				close_all()
				get_viewport().set_input_as_handled()
				return
		get_viewport().set_input_as_handled()  # 悬浮窗开着时 ESC 只关它


func _process(_delta: float) -> void:
	# 矿种跟随提示: 目标失效/面板打开即隐藏
	if _tip_ore != null:
		if not is_instance_valid(_tip_ore) or not _tip_ore.visible or modal_open:
			_tip_ore = null
			_tip.visible = false
		else:
			var oid := GameData.asset_to_ore(_tip_ore.ore_name)
			var name_txt: String = GameData.good_name(oid) if oid != "" else _tip_ore.ore_name
			_tip.text = "%s · %s档 · %d" % [name_txt, _tip_ore.tier, _tip_ore.amount]
			_tip.position = _tip.get_viewport().get_mouse_position() + Vector2(18, 20)


# ---------- 空间站模块悬浮窗 ----------

func _build_popup() -> void:
	# 全屏透明拦截层: 点窗口外任意处关闭
	_popup_blocker = Control.new()
	_popup_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_popup_blocker.visible = false
	_popup_blocker.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			hide_station_popup())
	add_child(_popup_blocker)

	# 悬浮窗放独立 CanvasLayer(16): 面板(15)打开时悬浮窗仍在最上层可点, 不消失
	_popup_layer = CanvasLayer.new()
	_popup_layer.layer = 16
	add_child(_popup_layer)

	_popup = PanelContainer.new()
	_popup.add_theme_stylebox_override("panel", EconTheme.style_box(EconTheme.PANEL, EconTheme.BORDER, 8, 1))
	_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	_popup.visible = false
	_popup_layer.add_child(_popup)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_popup.add_child(margin)
	var v := EconTheme.vbox(8)
	margin.add_child(v)
	var t := EconTheme.title("空间站", 15)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_STOP
	t.mouse_default_cursor_shape = Control.CURSOR_MOVE
	t.gui_input.connect(_on_popup_title_input)
	t.tooltip_text = "拖动标题移动窗口 · 双击折叠/展开"
	v.add_child(t)
	# 滚动区: 按钮多于可视高度时出纵向滚动条（2026-09-30 拍板）
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(244, 216)
	v.add_child(scroll)
	_popup_scroll = scroll
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(grid)
	# 功能入口（HUD 按键已全部移除, 统一走悬浮窗）
	grid.add_child(_make_function_button("仓库", "inventory"))
	grid.add_child(_make_function_button("空间站建造", "build"))
	grid.add_child(_make_function_button("商品制造", "factory"))
	grid.add_child(_make_icon_button("res://assets/icons/market_logo.svg", "market", "市场交易"))
	grid.add_child(_make_function_button("我的订单", "orders"))
	# 建筑模块（建成开对应面板, 未建进建造面板）
	for id in GameData.MODULES:
		# 无人机/护卫舰是量产单元, 统一走"空间站建造"面板, 悬浮窗不单列（2026-09-30 拍板）
		if id == "drone" or id == "corvette":
			continue
		grid.add_child(_make_module_button(id))


## 图标 logo 按钮（菜单页用）: hover 时上方浮字提示
func _make_icon_button(tex_path: String, panel_id: String, tip: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(108, 64)
	b.tooltip_text = tip
	# Button 非容器, 子 TextureRect 实际 size=0 → 曾显示空按钮;
	# 正确做法=Button 内置 icon 槽 + 双向居中
	b.icon = load(tex_path)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_stylebox_override("normal", EconTheme.style_box(EconTheme.PANEL2, EconTheme.BORDER.darkened(0.3), 6))
	b.add_theme_stylebox_override("hover", EconTheme.style_box(EconTheme.PANEL2.lightened(0.1), Color("58A7BF"), 6))
	b.add_theme_stylebox_override("pressed", EconTheme.style_box(EconTheme.PANEL2.darkened(0.1), Color("58A7BF"), 6))
	# 自定义 hover 浮字（即时, 非系统 tooltip 延迟）
	var tip_l := EconTheme.label(tip, Color("58A7BF"), 13)
	tip_l.visible = false
	tip_l.position = Vector2(8, -22)
	tip_l.z_index = 50
	b.add_child(tip_l)
	b.mouse_entered.connect(func():
		tip_l.visible = true
		b.modulate = Color(1.25, 1.25, 1.25))
	b.mouse_exited.connect(func():
		tip_l.visible = false
		b.modulate = Color.WHITE)
	b.pressed.connect(func(): open_panel(panel_id))
	return b


## 功能入口按钮（无建成状态, 高亮样式）
func _make_function_button(text: String, panel_id: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(108, 64)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", EconTheme.TEXT)
	b.add_theme_color_override("font_hover_color", EconTheme.ACCENT)
	b.add_theme_stylebox_override("normal", EconTheme.style_box(EconTheme.PANEL2, EconTheme.ACCENT.darkened(0.25), 6))
	b.add_theme_stylebox_override("hover", EconTheme.style_box(EconTheme.PANEL2.lightened(0.08), EconTheme.ACCENT, 6))
	b.add_theme_stylebox_override("pressed", EconTheme.style_box(EconTheme.PANEL2.darkened(0.1), EconTheme.ACCENT, 6))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# 打开面板时不关闭悬浮窗（2026-09-30 拍板: 站体菜单保持显示）
	b.pressed.connect(func(): open_panel(panel_id))
	return b


func _make_module_button(id: String) -> Button:
	var b := Button.new()
	b.text = str(GameData.MODULES[id]["name"])
	b.custom_minimum_size = Vector2(108, 64)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(_open_module_panel.bind(id))
	b.set_meta("module_id", id)
	return b


## 每次弹出时按建成状态刷新按钮配色
func _refresh_popup_buttons() -> void:
	for b in _popup.find_children("*", "Button", true, false):
		var id := str(b.get_meta("module_id", ""))
		if id == "":
			continue
		var built: bool = Economy.module_level(id) > 0 or Economy.module_count(id) > 0
		var border := EconTheme.ACCENT if built else EconTheme.BORDER.darkened(0.3)
		var bg := EconTheme.PANEL2 if built else EconTheme.PANEL2.darkened(0.25)
		b.add_theme_color_override("font_color", EconTheme.TEXT if built else EconTheme.DIM)
		b.add_theme_color_override("font_hover_color", EconTheme.ACCENT)
		b.add_theme_stylebox_override("normal", EconTheme.style_box(bg, border, 6))
		b.add_theme_stylebox_override("hover", EconTheme.style_box(bg.lightened(0.08), EconTheme.ACCENT, 6))
		b.add_theme_stylebox_override("pressed", EconTheme.style_box(bg.darkened(0.1), EconTheme.ACCENT, 6))
		var m: Dictionary = Economy.module_state(id)
		if built:
			var status := "Lv.%d" % m["level"] if m["level"] > 0 else "×%d" % m["count"]
			b.tooltip_text = "%s（%s）——点击打开" % [GameData.MODULES[id]["name"], status]
		else:
			b.tooltip_text = "%s（未建造）——点击去建造" % GameData.MODULES[id]["name"]


func show_station_popup(screen_pos: Vector2) -> void:
	_refresh_popup_buttons()
	_popup_collapsed = false
	if _popup_scroll != null:
		_popup_scroll.visible = true
	_popup_blocker.visible = true
	_popup.visible = true
	_popup.reset_size()
	var ps := _popup.get_combined_minimum_size()
	var vp := get_viewport().get_visible_rect().size
	var pos := screen_pos + Vector2(16, 16)
	pos.x = clampf(pos.x, 4.0, maxf(vp.x - ps.x - 4.0, 4.0))
	pos.y = clampf(pos.y, 4.0, maxf(vp.y - ps.y - 4.0, 4.0))
	_popup.position = pos


func hide_station_popup() -> void:
	if _popup != null:
		_popup.visible = false
		_popup_dragging = false
	if _popup_blocker != null:
		_popup_blocker.visible = false


## 标题栏：按住拖动窗口, 双击折叠/展开
func _on_popup_title_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		if ev.double_click:
			_toggle_popup_collapse()
			return
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_popup_dragging = true
			_popup_drag_off = _popup.get_global_mouse_position() - _popup.position


func _toggle_popup_collapse() -> void:
	_popup_collapsed = not _popup_collapsed
	if _popup_scroll != null:
		_popup_scroll.visible = not _popup_collapsed
	if _popup_collapsed:
		_popup.reset_size()
		var ps := _popup.get_combined_minimum_size()
		var vp := get_viewport().get_visible_rect().size
		_popup.position.x = clampf(_popup.position.x, 4.0, maxf(vp.x - ps.x - 4.0, 4.0))
		_popup.position.y = clampf(_popup.position.y, 4.0, maxf(vp.y - ps.y - 4.0, 4.0))


## 悬浮窗按钮 → 建成开对应面板, 未建进建造面板（悬浮窗保持显示）
func _open_module_panel(id: String) -> void:
	match id:
		"hangar":
			open_panel("hangar" if Economy.module_level("hangar") > 0 else "build")
		"factory":
			open_panel("factory" if Economy.module_count("factory") > 0 else "build")
		"research":
			open_panel("research" if Economy.module_level("research") > 0 else "build")
		_:
			open_panel("build")


# ---------- 矿石悬停提示 ----------

func _build_tip() -> void:
	_tip = Label.new()
	_tip.add_theme_font_size_override("font_size", 14)
	_tip.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_tip.add_theme_color_override("font_outline_color", Color(0.02, 0.05, 0.1, 0.95))
	_tip.add_theme_constant_override("outline_size", 6)
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.z_index = 60
	_tip.visible = false
	add_child(_tip)


func show_ore_tip(ore: BeltOre) -> void:
	_tip_ore = ore
	_tip.visible = true


func hide_ore_tip(ore: BeltOre) -> void:
	if _tip_ore == ore:
		_tip_ore = null
		_tip.visible = false
