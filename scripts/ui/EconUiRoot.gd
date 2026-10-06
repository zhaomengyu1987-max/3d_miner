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
## 测试可重定向（同 Economy.save_path 约定）
var layout_path := LAYOUT_PATH
## 布局存档高度下限: 旧存档里可能存了折叠高度(32) ⇒ 会把窗口开成一条标题栏
const LAYOUT_MIN_H := 160.0


static func any_modal_open() -> bool:
	return modal_open


var _panels := {}
var _open_stack: Array = []   # 叠开顺序（ESC 逐层关）
var _popup: PanelContainer
var _popup_layer: CanvasLayer      # 悬浮窗独立高层(16): 面板打开时保持可见可点
var _popup_blocker: Control
## 共享全屏输入隔离层（独立低层 13, 见 _ready 的层级不变式）
var _modal_backdrop: ColorRect
var _backdrop_layer: CanvasLayer
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
## 活动窗口 = 最前面（2026-10-02 用户拍板"点哪个哪个优先显示在最前方"）:
## 除了染色, 还把该面板移到兄弟节点末尾 ⇒ 绘制在其它窗口之上, 输入也优先。
func set_active_panel(active) -> void:
	for p in _panels.values():
		if p.has_method("set_tint"):
			p.set_tint(p == active)
	if active != null and is_instance_valid(active):
		active.move_to_front()
		_lower_popup()                  # 点了面板 ⇒ 菜单让位（不再永远压在最上面）
		var pid: String = (active as EconPanelBase).panel_id
		if pid != "" and _open_stack.has(pid):
			_open_stack.erase(pid)      # 置顶后它是最上层: ESC 应先关它
			_open_stack.append(pid)


func _ready() -> void:
	add_to_group("econ_ui")
	layer = 15
	# 共享**输入隔离**层（2026-10-02）: 原先每扇窗各带一块 MOUSE_FILTER_STOP 的全屏背板,
	# 多开时最上层那块会把点击**全部**吃掉 ⇒ 下面的窗点都点不到（"点击置顶"无从谈起）。
	# 现在只留这一块, 且**完全透明**: 用户明确"点功能后全屏变半透明深色"是 bug。
	# ColorRect 全透明照样接收鼠标事件（mouse_filter 与颜色无关）, 世界点击仍被隔离。
	#
	# ⚠ 必须放**独立低层 13**（而不是本层 15）: 菜单让位时降到 14, 若拦截层在 15 就会把
	# 菜单重新盖住 ⇒ 点了一个功能后点不动第二个（2026-10-02 用户报, 同一坑踩了两次）。
	# 层级不变式: 拦截层 13 < 菜单让位 14 < 面板/根 15 < 菜单前景 16。
	_backdrop_layer = CanvasLayer.new()
	_backdrop_layer.layer = 13
	add_child(_backdrop_layer)
	_modal_backdrop = ColorRect.new()
	_modal_backdrop.color = Color(0, 0, 0, 0)
	_modal_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_backdrop.visible = false
	_backdrop_layer.add_child(_modal_backdrop)
	_build_popup()
	_build_tip()
	add_child(EconHud.new())
	# 顶部新闻播报条（世界叙事 + WorldState 角标, 2026-10-02）:
	# 放在面板**之前**加入 ⇒ 面板画在它上面, 不会被它压住; 它自己是 IGNORE 不挡点击。
	add_child(preload("res://scripts/ui/NewsTicker.gd").new())
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
	# 关掉的窗从叠开栈里摘掉（否则 ESC 会去关一个已经关了的窗, 白按一次）
	for i in range(_open_stack.size() - 1, -1, -1):
		var k: String = _open_stack[i]
		if not _panels.has(k) or not (_panels[k] as EconPanelBase).visible:
			_open_stack.remove_at(i)
	_sync_backdrop()
	save_window_layout()


func save_window_layout() -> void:
	var data := {"_ui_scale": ui_scale}
	for key in _panels:
		var pb = _panels[key]
		if pb.get("_panel") == null:
			continue
		# 从未打开过的面板没有有效尺寸（size 是布局垃圾值, 实测 research 会存成 h=12）⇒ 跳过
		if not pb.visible and not pb._size_inited:
			continue
		# 存**实际窗口尺寸**，不是 custom_minimum_size（2026-10-02 修"打开只剩最小状态"）:
		# 后者对自管滚动的面板(build/factory/hangar/research)恒为 0 ⇒ 存档写成 h=0;
		# 折叠时它又等于 COLLAPSED_HEIGHT(32) ⇒ 打开成一条标题栏。实测旧存档正是如此:
		# orders h=32 collapsed=true、build/factory/hangar/research h=0。
		# 折叠只在本次会话内有效, 存档永远写展开高度。
		var w: float = maxf(pb._panel.size.x, pb._panel.custom_minimum_size.x)
		var h: float = maxf(pb._panel.size.y, pb._panel.custom_minimum_size.y)
		if pb._collapsed:
			h = maxf(pb._expanded_h, LAYOUT_MIN_H)
		data[key] = {"x": pb._panel.position.x, "y": pb._panel.position.y,
			"w": w, "h": h,
			"moved": pb._user_moved,
			"split": pb._split_ratio, "vs": pb._vs_ratio, "host": pb.stack_host}
	var f := FileAccess.open(layout_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


func load_window_layout() -> void:
	if not FileAccess.file_exists(layout_path):
		return
	var f := FileAccess.open(layout_path, FileAccess.READ)
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
		# 高度下限 LAYOUT_MIN_H: 旧存档可能存了折叠高度(32) ⇒ 顺手夹回可用高度（自愈被污染的存档）
		var h: float = clampf(float(d.get("h", 0)), LAYOUT_MIN_H, vp.y * 0.92)
		if w > 0.0:
			pb._panel.size = Vector2(w, h)  # 只设 size——min 保持代码声明, 窗口可再缩回
		pb._panel.position = Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
		# **不恢复折叠态**: 折叠只是"当前显示状态", 从存档带回来会导致打开即一条标题栏
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


## 叠加打开（多开）: **不关闭已有面板** —— 悬浮窗各入口、市场里的"我的订单"都走这条,
## 于是"建造厂 + 市场交易"可以同时开着。_open_stack 记叠开顺序, ESC 逐层关（先关最上层）。
## 【2026-10-02 修】市场面板(_open_orders)一直调用 open_panel_add("orders")，
## 但该方法此前**根本不存在** ⇒ 点"我的订单"报 Invalid call 且毫无反应（多开从未落地）。
func open_panel_add(id: String, keep_popup := false) -> void:
	if not _panels.has(id):
		return
	if not _open_stack.has(id):
		_open_stack.append(id)
	# 层叠偏移: 已有几扇可见窗就右下偏几个 28px, 避免新窗完全盖住旧窗
	var n := 0
	for k in _open_stack:
		if k != id and _panels.has(k) and (_panels[k] as EconPanelBase).visible:
			n += 1
	(_panels[id] as EconPanelBase).cascade_offset = Vector2(28, 28) * float(n)
	if keep_popup:
		if _popup_blocker != null:
			_popup_blocker.visible = false
		if _popup != null:
			_popup.visible = true
	_panels[id].open()
	modal_open = true
	_sync_backdrop()


## 菜单与面板共用"最后交互者在上"的规则（2026-10-02 用户报"空间站界面被设定为永远最顶层"）:
## 打开菜单 / 抓它的标题栏 → 层 16（浮在面板之上）; 点任意面板 → 菜单降到层 14（让位给面板）。
## 这样它不再是"永远最顶层", 但要用时仍能一键回到最前。
const POPUP_LAYER_FRONT := 16
const POPUP_LAYER_BACK := 14


func _raise_popup() -> void:
	if _popup_layer != null:
		_popup_layer.layer = POPUP_LAYER_FRONT


func _lower_popup() -> void:
	if _popup_layer != null and _popup != null and _popup.visible:
		_popup_layer.layer = POPUP_LAYER_BACK


## 共享背板可见性 = 是否有面板开着
func _sync_backdrop() -> void:
	if _modal_backdrop != null:
		_modal_backdrop.visible = modal_open


## 独占打开面板（会先关掉其它面板；多开请用 open_panel_add）。
## keep_popup=true 时**悬浮窗保持打开**（2026-10-02 用户拍板: 站体菜单不自动关）：
## 只撤掉全屏遮罩（否则会挡住新面板），窗口本体在 CanvasLayer 14（面板 15）继续可点。
func open_panel(id: String, keep_popup := false) -> void:
	if not _panels.has(id):
		return
	close_all()
	if keep_popup:
		if _popup_blocker != null:
			_popup_blocker.visible = false
		if _popup != null:
			_popup.visible = true
	else:
		hide_station_popup()
	_panels[id].open()
	modal_open = true
	_sync_backdrop()


func close_all() -> void:
	for p in _panels.values():
		p.close()
	modal_open = false
	_sync_backdrop()


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
	# 悬浮窗与它的全屏遮罩一起放独立 CanvasLayer(16): **在共享背板(15)与功能面板(15)之上**。
	# 【2026-10-02 回退+修正】上一版把悬浮窗降到 14（想让面板显示在它上方），结果:
	# ①共享变暗背板(15, 全屏 STOP)把它整个盖住 ⇒ 点第二个功能没反应、整个菜单也变暗;
	# ②面板(15)也压着它 ⇒ 点在菜单格子上的点击落到面板按钮上（把窗口折叠/关掉）。
	# 悬浮窗是"启动器", 必须始终可点; 它盖住新面板的问题改用**自动让位**解决
	# 悬浮窗不再自动让位（2026-10-02 用户反馈"菜单会位移"）: 它就待在你放的位置,
	# 面板打开时它浮在最上层(16), 照样可点; 挡住谁由你自己拖一下。
	# 遮罩必须与悬浮窗同层且**先加**(画在下面), 否则遮罩会盖住悬浮窗导致按钮点不动。
	_popup_layer = CanvasLayer.new()
	_popup_layer.layer = 16
	add_child(_popup_layer)

	# 全屏透明拦截层: 点窗口外任意处关闭
	_popup_blocker = Control.new()
	_popup_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_popup_blocker.visible = false
	_popup_blocker.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			hide_station_popup())
	_popup_layer.add_child(_popup_blocker)

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
	# 标题行: [可拖动的标题（占满）] [✕ 关闭] —— 用户 2026-10-02 报"缺少 ✕ 关闭按钮"
	var title_row := EconTheme.hbox(4)
	v.add_child(title_row)
	var t := EconTheme.title("空间站", 15)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.mouse_filter = Control.MOUSE_FILTER_STOP
	t.mouse_default_cursor_shape = Control.CURSOR_MOVE
	t.gui_input.connect(_on_popup_title_input)
	t.tooltip_text = "拖动标题移动窗口 · 双击折叠/展开"
	title_row.add_child(t)
	var popup_close := EconTheme.button("✕", hide_station_popup, Vector2(24, 20))
	popup_close.tooltip_text = "关闭空间站菜单（ESC 同效）"
	title_row.add_child(popup_close)
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
	var fn_icons := preload("res://scripts/ui/EconIcons.gd")
	grid.add_child(_make_fn_icon_button(fn_icons.png_icon("inventory"), "仓库", "inventory"))
	grid.add_child(_make_fn_icon_button(fn_icons.png_icon("build"), "空间站建造", "build"))
	grid.add_child(_make_fn_icon_button(fn_icons.png_icon("orders"), "我的订单", "orders"))
	# 图标入口走"代码手绘像素画"（EconIcons）: 原实现引用 res://assets/icons/market_logo.svg,
	# 而该文件从未存在 ⇒ Button.icon = null ⇒ 按钮空白（2026-10-02 修）。
	# 这里用 preload 而不是全局类名: 新建脚本的 class_name 要等编辑器扫描后才会进
	# .godot/global_script_class_cache.cfg，release/headless 运行下未必已登记。
	var icons := preload("res://scripts/ui/EconIcons.gd")
	grid.add_child(_make_icon_button(icons.market_logo(), "market", "市场交易"))
	# 建造厂（模块按钮）与"商品制造"（功能按钮）本来就进同一个面板 ⇒ 2026-10-02 合并成一颗
	grid.add_child(_make_icon_button(icons.factory_logo(), "factory", "建造厂 · 商品制造", "factory"))
	# 建筑模块（建成开对应面板, 未建进建造面板）
	for id in GameData.MODULES:
		# 无人机/护卫舰是量产单元, 统一走"空间站建造"面板, 悬浮窗不单列（2026-09-30 拍板）
		# 建造厂已合并到上面的图标入口
		if id == "drone" or id == "corvette" or id == "factory":
			continue
		grid.add_child(_make_module_button(id))


## 图标按钮（菜单页用）: hover 时上方浮字提示。
## 传 Texture2D 而不是路径 —— 曾经路径写错(文件不存在)导致按钮空白（2026-10-02 修）；
## 图标为 null 时退化成文字按钮，保证**永远不会再出现空白按钮**。
## module_id 非空 = 建筑模块入口（按建成状态染色, 未建时进建造面板）。
## 统一站点按钮(R7: 所有按钮同尺寸/同样式/图标+文字并列)
## icon 可为 null(退化纯文字); module_id 非空 = 建筑模块入口(按建成状态染色)
func _make_station_button(icon: Texture2D, text: String, panel_id: String, module_id := "") -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(108, 64)
	b.tooltip_text = text
	# 图标 + 文字并列
	if icon != null:
		b.icon = icon
		b.expand_icon = false
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.text = text
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", EconTheme.TEXT)
	b.add_theme_color_override("font_hover_color", EconTheme.ACCENT)
	# 统一样式(圆角6/同色系)
	b.add_theme_stylebox_override("normal", EconTheme.style_box(EconTheme.PANEL2, EconTheme.BORDER.darkened(0.3), 6))
	b.add_theme_stylebox_override("hover", EconTheme.style_box(EconTheme.PANEL2.lightened(0.1), Color("58A7BF"), 6))
	b.add_theme_stylebox_override("pressed", EconTheme.style_box(EconTheme.PANEL2.darkened(0.1), Color("58A7BF"), 6))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# hover 亮化
	b.mouse_entered.connect(func(): b.modulate = Color(1.2, 1.2, 1.2))
	b.mouse_exited.connect(func(): b.modulate = Color.WHITE)
	# 点击行为
	if module_id != "":
		b.set_meta("module_id", module_id)
		b.pressed.connect(_open_module_panel.bind(module_id, true))
	else:
		b.pressed.connect(func(): open_panel_add(panel_id, true))
	return b


## 兼容旧调用(R7 统一后保留接口)
func _make_icon_button(icon: Texture2D, panel_id: String, tip: String, module_id := "") -> Button:
	return _make_station_button(icon, tip, panel_id, module_id)


func _make_fn_icon_button(icon: Texture2D, text: String, panel_id: String) -> Button:
	return _make_station_button(icon, text, panel_id)


func _make_function_button(text: String, panel_id: String) -> Button:
	return _make_station_button(null, text, panel_id)


func _make_module_button(id: String) -> Button:
	var icons := preload("res://scripts/ui/EconIcons.gd")
	var icon: Texture2D = icons.module_icon(id)
	return _make_station_button(icon, str(GameData.MODULES[id]["name"]), id, id)


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
	_raise_popup()                      # 弹出即置前（此后点面板会让位）
	_popup_collapsed = false
	if _popup_scroll != null:
		_popup_scroll.visible = true
	# 只在"没有功能面板打开"时才启用全屏拦截层（点窗口外关闭菜单）。
	# 面板开着时若也启用: 该层在悬浮窗同层且全屏 STOP ⇒ 会把面板的点击全吃掉。
	_popup_blocker.visible = not modal_open
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
			_raise_popup()      # 抓标题栏 = 要用它 ⇒ 回到最前（与面板"点谁谁在前"一致）
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
func _open_module_panel(id: String, keep_popup := false) -> void:
	# 多开: 模块入口也用叠加打开（建了开对应面板, 未建进建造面板）
	match id:
		"hangar":
			open_panel_add("hangar" if Economy.module_level("hangar") > 0 else "build", keep_popup)
		"factory":
			open_panel_add("factory" if Economy.module_count("factory") > 0 else "build", keep_popup)
		"research":
			open_panel_add("research" if Economy.module_level("research") > 0 else "build", keep_popup)
		_:
			open_panel_add("build", keep_popup)


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
