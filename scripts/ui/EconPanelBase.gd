class_name EconPanelBase
extends Control

## EVE 窗口系统复刻（行为规格取自国服客户端 code.ccp → carbonui/window/*.pyj）：
## - 标题栏拖动：拖动中显示吸附边线（吸附视口边缘+其他窗口边缘, SNAP_DISTANCE=8px）
## - 折叠：○/□ 指示钮单击 / 双击标题, 保宽度, 高度收成标题条（带 0.15s 动画）
## - 缩放：四边+右下拖角（EVE edge/corner 贴图）, 缩放中同样吸附, 最小尺寸强制
## - 防出屏：标题栏至少保留 OFFSCREEN_KEEP 像素可见（AdjustWindowPositionToFitScreen）
## - 活动窗口染色（only_tint_active_window）：非活动窗口轻微变暗
## - 布局持久化：位置/尺寸/折叠/缩放档位

signal closed

const HEADER_OPENED_TEX := preload("res://assets/ui/window_header_opened_16px.png")
const HEADER_CLOSED_TEX := preload("res://assets/ui/window_header_closed_16px.png")

# —— EVE 行为常量（carbonui/window 规格） ——
const HEADER_HEIGHT := 30.0
const COLLAPSED_HEIGHT := 32.0   # EVE 源码 WindowHeaderBase.COLLAPSED_HEIGHT=32
const SNAP_DISTANCE := 16.0  # EVE 源码 snap.SNAP_DISTANCE=16
const EDGE_HOT := 8.0             # EVE 源码 ResizeHandle size=8 命中热区（视觉厚度仅 1px）
const MIN_WIN := Vector2(160, 120)
const COLLAPSE_ANIM := 0.15

var body: VBoxContainer
var _scroll: ScrollContainer
var _panel: PanelContainer
var _frame: Control
var _header_cont: PanelContainer
var _header_title: Label
var _zoom_label: Label
var _grip: TextureRect
var _collapse_btn: TextureButton
var _footer: HBoxContainer
var _ticker_box: Control
var _ticker_label: Label
var _edge_zone: Control                    # 隐形边缘缩放热区（EVE: 柄不可见, 光标即提示）
var _edge_hovers := {}                     # side -> 光标形状
var _snap_v: ColorRect                    # 垂直吸附指示线
var _snap_h: ColorRect                    # 水平吸附指示线
var _own_scroll := false
## 帧内冻结的滚动位置：一次提交会在同一帧触发 2~4 次全量重建（Economy 信号 + 处理函数显式
## refresh()），只有第一次捕获到的是真实位置 —— 之后重建出的新控件滚动值还是 0。详见 refresh()。
var _refresh_frame := -1
var _frame_scroll_vals: Array = []
var _frame_list_vals: Array = []
## 帧内合并：本帧是否已排队一次重建（见 refresh）
var _rebuild_queued := false
## 累计重建次数（性能观察 / 回归测试用：同帧多次 refresh 应只 +1）
var rebuilds := 0
var _title := ""

# ---- 窗口栈叠（EVE WindowStack 复刻, 2026-10-01） ----
var panel_id := ""                  # 由 EconUiRoot 注册时赋值
var stack_host := ""                # 非空=自己寄宿在该面板（成员）
var stack_members: Array = []       # 非空=自己是宿主, 成员 panel_id 列表
var active_member := ""             # 宿主当前显示的成员 id（空=显示自己）
var _tab_bar: HBoxContainer

var _dragging := false
var _collapsed := false
var _expanded_h := 0.0
var _user_moved := false
## 首次打开的默认窗口尺寸（Vector2.ZERO = 用 _panel_min; 有存档布局时不生效）
var default_size := Vector2.ZERO
var _size_inited := false
var _resize_side := -1                    # -1 无 / 0左 1上 2右 3下 4右下角
var _resizing := false


func _init(p_title: String) -> void:
	_title = p_title


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false

	var backdrop := ColorRect.new()
	backdrop.color = EconTheme.BG
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	_frame = Control.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = _panel_min()
	# EVE 窗体：深色半透底 + 1px 亮边
	_panel.add_theme_stylebox_override("panel", EconTheme.style_box(EconTheme.PANEL, EconTheme.BORDER, 2, 1))
	_panel.gui_input.connect(_on_panel_gui_input)
	_frame.add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 1)
	_panel.add_child(margin)

	var root := EconTheme.vbox(0)
	margin.add_child(root)

	# ---- 标题栏（拖动 / 双击折叠 / ○□ 指示钮） ----
	_header_cont = PanelContainer.new()
	_header_cont.custom_minimum_size = Vector2(0, HEADER_HEIGHT)
	var hsb := EconTheme.style_box(Color(0.075, 0.07, 0.063, 1.0), Color(0, 0, 0, 0), 0, 0)
	hsb.set_border_width(SIDE_TOP, 1)
	hsb.border_color = Color(0.17, 0.17, 0.16)   # EVE 标题栏顶 1px 亮线 #2b2b28
	_header_cont.add_theme_stylebox_override("panel", hsb)
	root.add_child(_header_cont)
	var head := EconTheme.hbox(6)
	_header_cont.add_child(head)
	_header_title = EconTheme.title(_title)
	_header_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_title.mouse_filter = Control.MOUSE_FILTER_STOP
	_header_title.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_header_title.gui_input.connect(_on_header_input)
	_header_title.tooltip_text = "拖动移动窗口 · 双击折叠/展开"
	head.add_child(_header_title)
	_collapse_btn = TextureButton.new()
	_collapse_btn.texture_normal = HEADER_OPENED_TEX
	_collapse_btn.ignore_texture_size = true
	_collapse_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_collapse_btn.custom_minimum_size = Vector2(18, 18)
	_collapse_btn.tooltip_text = "折叠/展开窗口"
	_collapse_btn.pressed.connect(_toggle_collapse)
	head.add_child(_collapse_btn)
	head.add_child(EconTheme.button("✕", _close_stack, Vector2(30, 22)))

	# 标签条（栈叠时显示在标题栏下方, EVE tab_navigation 规格）
	_tab_bar = EconTheme.hbox(4)
	_tab_bar.visible = false
	root.add_child(_tab_bar)

	# ---- 内容区 ----
	if _own_scroll:
		body = EconTheme.vbox(8)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(body)
	else:
		_scroll = ScrollContainer.new()
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(_scroll)
		body = EconTheme.vbox(8)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.add_child(body)

	# ---- 底栏: 视觉缩放 ----
	_footer = EconTheme.hbox(6)
	_footer.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(_footer)
	# 价格播报跑马灯槽（2026-10-02 市场用; 默认隐藏——子类 _set_ticker 启用）
	_ticker_box = Control.new()
	_ticker_box.custom_minimum_size = Vector2(260, 18)
	_ticker_box.clip_contents = true
	_ticker_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker_box.visible = false
	_footer.add_child(_ticker_box)
	_ticker_label = EconTheme.label("", EconTheme.GOOD, 12)
	_ticker_label.position = Vector2(260, 0)
	_ticker_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker_box.add_child(_ticker_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.add_child(spacer)
	_footer.add_child(EconTheme.button("－", _zoom_out, Vector2(34, 22)))
	_zoom_label = EconTheme.label("100%", EconTheme.DIM, 12)
	_footer.add_child(_zoom_label)
	_footer.add_child(EconTheme.button("＋", _zoom_in, Vector2(34, 22)))

	# ---- 边缘缩放热区（EVE: 完全不可见, 鼠标到边光标变化即可拖窗口边） ----
	_edge_zone = Control.new()
	_edge_zone.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 由 _panel 自身的 gui_input 驱动
	_frame.add_child(_edge_zone)

	# ---- 吸附指示线（EVE: 贴窗口边的短亮条, 不是横贯全屏的线） ----
	_snap_v = ColorRect.new()
	_snap_v.color = Color(EconTheme.ACCENT.r, EconTheme.ACCENT.g, EconTheme.ACCENT.b, 0.55)
	_snap_v.visible = false
	_snap_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_snap_v)
	_snap_h = ColorRect.new()
	_snap_h.color = Color(EconTheme.ACCENT.r, EconTheme.ACCENT.g, EconTheme.ACCENT.b, 0.55)
	_snap_h.visible = false
	_snap_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_snap_h)

	# 视口自适应: 声明宽超出视口 95% 时收窄（否则小分辨率下面板天生出屏）
	var vps := get_viewport_rect().size
	_panel.custom_minimum_size.x = minf(_panel.custom_minimum_size.x, vps.x * 0.95)
	_connect_signals()


## 子类灌入跑马灯文本（空串隐藏）
func _set_ticker(text: String) -> void:
	if _ticker_label == null:
		return
	_ticker_label.text = text
	_ticker_box.visible = text != ""
	if text != "":
		_ticker_label.position.x = _ticker_box.size.x


func _ticker_step(delta: float) -> void:
	if _ticker_box == null or not _ticker_box.visible:
		return
	var w := _ticker_label.get_minimum_size().x
	_ticker_label.position.x -= 28.0 * delta
	if _ticker_label.position.x < -w:
		_ticker_label.position.x = _ticker_box.size.x


func _process(_delta: float) -> void:
	if _panel == null or _edge_zone == null:
		return
	_sync_stack_member()
	_ticker_step(_delta)
	if _vs_pending >= 0.0 and _vs_pair.size() == 2:
		_apply_vsplit(_vs_pair[0], _vs_pair[1])
		_vs_pending = -1.0
	_edge_zone.position = _panel.position
	_edge_zone.size = _panel.size
	# 吸附指示线保险丝: 非拖拽/缩放状态强制隐藏（松手在窗口外时 _input 收不到 release）
	if not _dragging and not _resizing:
		_snap_v.visible = false
		_snap_h.visible = false


## EVE 式边缘缩放：无任何可见柄。鼠标在窗口边缘 6px 热区内→光标变双向箭头;
## 按下即从该边拖窗口边（角=同时宽高）。返回 -1 表示不在边缘。
func _edge_side_at(local_pos: Vector2, size: Vector2) -> int:
	var e := EDGE_HOT
	var near_l: bool = local_pos.x < e
	var near_r: bool = local_pos.x > size.x - e
	var near_t: bool = local_pos.y < e
	var near_b: bool = local_pos.y > size.y - e
	if near_l and near_t:
		return 5
	if near_r and near_b:
		return 4
	if near_l and near_b:
		return 6
	if near_r and near_t:
		return 7
	if near_l:
		return 0
	if near_r:
		return 2
	if near_t:
		return 1
	if near_b:
		return 3
	return -1


func _cursor_for_side(side: int) -> int:
	match side:
		0, 2:
			return Control.CURSOR_HSIZE
		1, 3:
			return Control.CURSOR_VSIZE
		4, 6:
			return Control.CURSOR_FDIAGSIZE
		5, 7:
			return Control.CURSOR_BDIAGSIZE
	return Control.CURSOR_ARROW


func _panel_min() -> Vector2:
	return Vector2(560, 200)


func _connect_signals() -> void:
	pass


func open() -> void:
	visible = true
	_capture_scroll_now()      # 跨开关窗保持滚动位置
	_rebuild_body_now()        # 开窗必须同步建好: 下面 _apply_zoom/_do_center 依赖内容尺寸
	_apply_zoom()
	_set_active()
	if not stack_members.is_empty():
		_refresh_tab_bar()
		_apply_stack_visibility()
	if _user_moved:
		call_deferred("_clamp_into_view")  # 存档里的位置可能出屏: 打开时强制收回（2026-09-30 修）
	elif not _user_moved:
		call_deferred("_do_center")


## 打开时把窗口强制收回视口: 尺寸 ≤95% 屏, 且整个窗口(含右下拖角)必须在屏内
func _clamp_into_view() -> void:
	if _panel == null:
		return
	var vp := get_viewport_rect().size
	_panel.size = Vector2(minf(_panel.size.x, vp.x * 0.95), minf(_panel.size.y, vp.y * 0.95))
	_panel.custom_minimum_size = Vector2(
		minf(_panel.custom_minimum_size.x, _panel.size.x),
		minf(_panel.custom_minimum_size.y, _panel.size.y))
	_panel.position.x = clampf(_panel.position.x, 4.0, maxf(vp.x - _panel.size.x - 4.0, 4.0))
	_panel.position.y = clampf(_panel.position.y, 4.0, maxf(vp.y - _panel.size.y - 4.0, 4.0))


func close() -> void:
	visible = false
	closed.emit()


## 记录当前滚动位置：本帧第一次调用生效，同帧后续调用复用冻结值（见 refresh 注释）
func _capture_scroll_now() -> void:
	_refresh_frame = Engine.get_process_frames()
	_frame_scroll_vals.clear()
	for s in _collect_scrolls():
		if s != null and is_instance_valid(s):
			_frame_scroll_vals.append((s as ScrollContainer).scroll_vertical)
	_frame_list_vals.clear()
	for l in _collect_itemlists():
		if l != null and is_instance_valid(l):
			_frame_list_vals.append(l.get_v_scroll_bar().value)


## 立即拆掉 body 重建，并按冻结值延迟恢复滚动（open() 与帧末合并重建共用）
func _rebuild_body_now() -> void:
	rebuilds += 1
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	_rebuild()
	_fit_scroll()
	call_deferred("_fit_scroll")
	call_deferred("_restore_scrolls", _frame_scroll_vals.duplicate())   # 刷新不重置滚动位置
	call_deferred("_restore_itemlists", _frame_list_vals.duplicate())   # ItemList 同理


func refresh() -> void:
	if not visible:
		return
	# 【帧内冻结 · 2026-10-02 修"提交订单/制造后滑块回顶"】
	# 一次提交会经 Economy 信号(_sig_refresh) + 处理函数显式 refresh() 在同一帧触发 2~4 次
	# 全量重建。第一次捕获到的是真实滚动位置，但重建出的新控件滚动值仍是 0（恢复是延迟的），
	# 后续 refresh 若再捕获就会拿到一串 0，并在延迟队列里把正确的恢复值覆盖掉 ⇒ 滑块回顶。
	# 因此本帧的滚动值只认第一次捕获。
	if Engine.get_process_frames() != _refresh_frame:
		_capture_scroll_now()
	# 【帧内合并 · 2026-10-02 性能】同帧多次请求只真正重建一次，且在**帧末**执行 ——
	# 那时读到的必然是本帧最终状态，所以既不丢更新、也不回顶（原实现是每次请求整棵重建）。
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_flush_rebuild")


func _flush_rebuild() -> void:
	_rebuild_queued = false
	if visible:
		_rebuild_body_now()


## 参与滚动位置保持的 ItemList（虚拟化列表面板覆写登记）。
## 【SOP 约定（2026-10-01）】任何含列表/滚动区的面板必须二选一登记：
## ScrollContainer → _collect_scrolls(); ItemList → _collect_itemlists()。
## 未登记 = 数据刷新时滚动回顶（用户已三次踩中）。
func _collect_itemlists() -> Array:
	return []


## ItemList 滚动保持: 经内部 VScrollBar value（ItemList 无公开 scroll_position）
func _capture_list_pos(arr: Array) -> Array:
	var vals: Array = []
	for l in arr:
		if l != null and is_instance_valid(l):
			vals.append((l as ItemList).get_v_scroll_bar().value)
		else:
			vals.append(0.0)
	return vals


func _restore_list_pos(arr: Array, vals: Array) -> void:
	for i in mini(arr.size(), vals.size()):
		var l = arr[i]
		if l != null and is_instance_valid(l):
			(l as ItemList).get_v_scroll_bar().set_deferred("value", vals[i])


func _restore_itemlists(vals: Array) -> void:
	_restore_list_pos(_collect_itemlists(), vals)
	call_deferred("_restore_itemlists_again", vals)
	call_deferred("_restore_itemlists_third", vals)


func _restore_itemlists_third(vals: Array) -> void:
	call_deferred("_restore_itemlists_again", vals)


## 兜底只补"没生效"的位置(目标 > 0 但当前仍 ≈ 0), 不无条件重写 ——
## 否则用户在这几帧里自己滚了会被硬拽回去。
func _restore_itemlists_again(vals: Array) -> void:
	var lists := _collect_itemlists()
	for i in mini(lists.size(), vals.size()):
		var l = lists[i]
		if l == null or not is_instance_valid(l):
			continue
		var want := float(vals[i])
		var bar := (l as ItemList).get_v_scroll_bar()
		if want > 0.5 and bar.value < 0.5:
			bar.value = want


## 参与滚动位置保持的容器（双栏面板覆写登记左右列）
func _collect_scrolls() -> Array:
	return [_scroll] if _scroll != null else []


func _restore_scrolls(vals: Array) -> void:
	# set_deferred: 重建内容布局完成后再应用滚动位置, 否则会被布局重置回顶部
	var scrolls := _collect_scrolls()
	for i in mini(scrolls.size(), vals.size()):
		var sc := scrolls[i] as ScrollContainer
		if sc != null and is_instance_valid(sc):
			sc.set_deferred("scroll_vertical", float(vals[i]))
	call_deferred("_restore_scrolls_again", vals)  # 二次兜底(长列表一帧布局不完)


func _restore_scrolls_again(vals: Array) -> void:
	_apply_scroll_vals(vals)
	# 三次兜底: 跨帧。新建子树常要下一帧才算完布局(scroll 上限还是 0, 值被夹掉) ——
	# 纯 ScrollContainer 面板此前两次恢复都在同一帧 ⇒ 必然回顶（2026-10-02 修）。
	call_deferred("_restore_scrolls_final", vals)


func _restore_scrolls_final(vals: Array) -> void:
	_apply_scroll_vals(vals)


## 只补没生效的位置(目标 > 0 但当前仍 ≈ 0)
func _apply_scroll_vals(vals: Array) -> void:
	var scrolls := _collect_scrolls()
	for i in mini(scrolls.size(), vals.size()):
		var sc := scrolls[i] as ScrollContainer
		if sc == null or not is_instance_valid(sc):
			continue
		var want := float(vals[i])
		if want > 0.5 and sc.scroll_vertical < 0.5:
			sc.scroll_vertical = want


func _rebuild() -> void:
	pass


func _sig_refresh() -> void:
	refresh()


func _section(text: String) -> Label:
	var l := EconTheme.label("— %s —" % text, EconTheme.ACCENT, 15)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _fit_scroll() -> void:
	if body == null or _user_moved:
		return  # 用户手动调整过窗口尺寸: 不再自适应, 尊重用户布局
	var max_h := get_viewport_rect().size.y * 0.58
	if _own_scroll:
		# 双栏面板: 按内容整体自适应窗口高（标题+底栏+边距余量）
		var content := body.get_combined_minimum_size().y + 96.0
		_panel.custom_minimum_size.y = clampf(content, 220.0, max_h)
		return
	if _scroll == null:
		return
	var c := body.get_combined_minimum_size().y
	_scroll.custom_minimum_size.y = clampf(c, 100.0, max_h)


# ================= 标题栏拖动（带吸附/防出屏） =================

func _on_header_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		if ev.double_click:
			_dragging = false
			_toggle_collapse()
			return
		if ev.button_index == MOUSE_BUTTON_LEFT:
			_dragging = true


## 拖动/缩放共用的吸附轴候选：视口边缘 + 其他可见窗口的边
func _snap_axes() -> Array:
	var xs: Array = [0.0]
	var ys: Array = [0.0]
	var vp := get_viewport_rect().size
	xs.append(vp.x)
	ys.append(vp.y)
	var root := get_parent()
	if root is EconUiRoot:
		for other in (root as EconUiRoot)._panels.values():
			if other == self or not other.visible or other._panel == null:
				continue
			var op: Vector2 = other._panel.position
			var os: Vector2 = other._panel.size
			xs.append(op.x)
			xs.append(op.x + os.x)
			ys.append(op.y)
			ys.append(op.y + os.y)
	return [xs, ys]


## 拖动中吸附: 返回修正后的位置并显示指示线
func _apply_drag_snap(pos: Vector2, size: Vector2) -> Vector2:
	var axes := _snap_axes()
	var xs: Array = axes[0]
	var ys: Array = axes[1]
	var best_x := -1.0
	var best_dx := SNAP_DISTANCE
	for ax in xs:
		for edge_x in [float(ax), float(ax) - size.x]:
			var d: float = absf(pos.x - edge_x)
			if d < best_dx:
				best_dx = d
				best_x = edge_x
	var best_y := -1.0
	var best_dy := SNAP_DISTANCE
	for ay in ys:
		for edge_y in [float(ay), float(ay) - size.y]:
			var d: float = absf(pos.y - edge_y)
			if d < best_dy:
				best_dy = d
				best_y = edge_y
	var vp := get_viewport_rect().size
	if best_x >= 0.0:
		pos.x = best_x
		_snap_v.visible = true
		_snap_v.position.x = clampf(best_x, 0.0, vp.x - 2.0)
		_snap_v.position.y = 0.0
		_snap_v.size = Vector2(2, vp.y)
	else:
		_snap_v.visible = false
	if best_y >= 0.0:
		pos.y = best_y
		_snap_h.visible = true
		_snap_h.position.y = clampf(best_y, 0.0, vp.y - 2.0)
		_snap_h.position.x = 0.0
		_snap_h.size = Vector2(vp.x, 2)
	else:
		_snap_h.visible = false
	return pos


func _hide_snap_indicators() -> void:
	_snap_v.visible = false
	_snap_h.visible = false


# ================= 折叠（EVE: 保宽度, 动画收成标题条） =================

func _toggle_collapse() -> void:
	_dragging = false
	_collapsed = not _collapsed
	if _scroll != null:
		_scroll.visible = not _collapsed
	if _own_scroll and body != null:
		body.visible = not _collapsed
	if _footer != null:
		_footer.visible = not _collapsed
	if _collapse_btn != null:
		_collapse_btn.texture_normal = HEADER_CLOSED_TEX if _collapsed else HEADER_OPENED_TEX
	if _collapsed:
		# 折叠前记住展开高度（取 size/min 较大者——打开瞬间布局未更新时 size 滞后）
		_expanded_h = maxf(_panel.size.y, _panel.custom_minimum_size.y)
	_panel.custom_minimum_size.y = COLLAPSED_HEIGHT if _collapsed else maxf(_expanded_h, _panel_min().y)
	var target_h: float = COLLAPSED_HEIGHT if _collapsed else maxf(_expanded_h, _panel.custom_minimum_size.y)
	var tw := create_tween()
	tw.tween_property(_panel, "size:y", target_h, COLLAPSE_ANIM).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_clamp_panel()
	_persist_layout()


# ================= 缩放（四边 + 拖角, 带吸附/最小尺寸） =================

func _apply_resize(mm: InputEventMouseMotion) -> void:
	var vp := get_viewport_rect().size
	var min_w := maxf(MIN_WIN.x, _panel_min().x)
	var min_h := maxf(MIN_WIN.y, 120.0)
	var pos := _panel.position
	var size := _panel.size
	var axes := _snap_axes()
	var xs: Array = axes[0]
	var ys: Array = axes[1]
	match _resize_side:
		2:  # 右
			size.x = clampf(size.x + mm.relative.x, min_w, vp.x * 0.95)
			for ax in xs:
				if absf(pos.x + size.x - float(ax)) < SNAP_DISTANCE:
					size.x = float(ax) - pos.x
					_show_snap_v(float(ax), vp)
					break
			if size.x < min_w or size.x > vp.x * 0.95:
				_snap_v.visible = false
		3:  # 下
			size.y = clampf(size.y + mm.relative.y, min_h, vp.y * 0.95)
			for ay in ys:
				if absf(pos.y + size.y - float(ay)) < SNAP_DISTANCE:
					size.y = float(ay) - pos.y
					_show_snap_h(float(ay), vp)
					break
			if size.y < min_h or size.y > vp.y * 0.95:
				_snap_h.visible = false
		0:  # 左
			var nx := clampf(pos.x + mm.relative.x, 0.0, pos.x + size.x - min_w)
			size.x = size.x - (nx - pos.x)
			for ax in xs:
				if absf(nx - float(ax)) < SNAP_DISTANCE:
					nx = float(ax)
					size.x = (pos.x + size.x) - nx
					_show_snap_v(float(ax), vp)
					break
			pos.x = nx
		1:  # 上
			var ny := clampf(pos.y + mm.relative.y, 0.0, pos.y + size.y - min_h)
			size.y = size.y - (ny - pos.y)
			for ay in ys:
				if absf(ny - float(ay)) < SNAP_DISTANCE:
					ny = float(ay)
					size.y = (pos.y + size.y) - ny
					_show_snap_h(float(ay), vp)
					break
			pos.y = ny
		4:  # 右下角: 宽高同时
			size.x = clampf(size.x + mm.relative.x, min_w, vp.x * 0.95)
			size.y = clampf(size.y + mm.relative.y, min_h, vp.y * 0.95)
			for ax in xs:
				if absf(pos.x + size.x - float(ax)) < SNAP_DISTANCE:
					size.x = float(ax) - pos.x
					_show_snap_v(float(ax), vp)
					break
			for ay in ys:
				if absf(pos.y + size.y - float(ay)) < SNAP_DISTANCE:
					size.y = float(ay) - pos.y
					_show_snap_h(float(ay), vp)
					break
		5:  # 左上角
			var nx5 := clampf(pos.x + mm.relative.x, 0.0, pos.x + size.x - min_w)
			var ny5 := clampf(pos.y + mm.relative.y, 0.0, pos.y + size.y - min_h)
			size.x = size.x - (nx5 - pos.x)
			size.y = size.y - (ny5 - pos.y)
			pos.x = nx5
			pos.y = ny5
		6:  # 左下角
			var nx6 := clampf(pos.x + mm.relative.x, 0.0, pos.x + size.x - min_w)
			size.x = size.x - (nx6 - pos.x)
			size.y = clampf(size.y + mm.relative.y, min_h, vp.y * 0.95)
			pos.x = nx6
		7:  # 右上角
			size.x = clampf(size.x + mm.relative.x, min_w, vp.x * 0.95)
			var ny7 := clampf(pos.y + mm.relative.y, 0.0, pos.y + size.y - min_h)
			size.y = size.y - (ny7 - pos.y)
			pos.y = ny7
	_panel.position = pos
	_panel.size = size
	_panel.custom_minimum_size = Vector2(maxf(min_w, 1.0), maxf(min_h, 1.0))
	# 手动缩放后释放内容区自适应高度——窗口缩多小内容区就跟多小, 超出部分滚动
	if _scroll != null:
		_scroll.custom_minimum_size.y = 0.0


func _show_snap_v(ax: float, vp: Vector2) -> void:
	_snap_v.visible = true
	_snap_v.position = Vector2(clampf(ax, 0.0, vp.x - 2.0), 0.0)
	_snap_v.size = Vector2(2, vp.y)


func _show_snap_h(ay: float, vp: Vector2) -> void:
	_snap_h.visible = true
	_snap_h.position = Vector2(0.0, clampf(ay, 0.0, vp.y - 2.0))
	_snap_h.size = Vector2(vp.x, 2)


# ================= 全局拖动/缩放运动处理 =================

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not _dragging and not _resizing:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			var pos := _panel.position + mm.relative
			# 吸附（拖动中显示吸附边线, EVE ShowSnapEdges_Moving）
			pos = _apply_drag_snap(pos, _panel.size)
			_panel.position = pos
			_user_moved = true
			_clamp_panel_offscreen()
		elif _resizing and _resize_side >= 0:
			_apply_resize(mm)
			_user_moved = true
	elif event is InputEventMouseButton and not event.pressed:
		if _dragging:
			# EVE 栈叠: 顶边落在别的窗口标题栏区 → 并入成标签（2026-10-01）
			var root := get_parent()
			if root is EconUiRoot and (root as EconUiRoot).try_stack_on_drop(self):
				_dragging = false
				_resizing = false
				return
		if _dragging or _resizing:
			_hide_snap_indicators()
			_persist_layout()
		_dragging = false
		_resizing = false


## EVE 允许窗口拖出屏幕（保留 50px 边缘可抓, 防整窗丢失）——拖向上不再卡住
func _clamp_panel_offscreen() -> void:
	var vp := get_viewport_rect().size
	_panel.position.x = clampf(_panel.position.x, 50.0 - _panel.size.x, vp.x - 50.0)
	_panel.position.y = clampf(_panel.position.y, 50.0 - _panel.size.y, vp.y - 50.0)


func _clamp_panel() -> void:
	_clamp_panel_offscreen()


func _do_center() -> void:
	if _user_moved or not visible or _panel == null:
		return
	_panel.reset_size()
	# 首次打开且无存档布局 → 用 default_size（EVE 的默认窗口尺寸, 如市场 900×768）
	if not _size_inited:
		_size_inited = true
		if default_size != Vector2.ZERO:
			var vs := get_viewport_rect().size
			_panel.size = Vector2(minf(default_size.x, vs.x * 0.95), minf(default_size.y, vs.y * 0.95))
	var vp := get_viewport_rect().size
	_panel.position = Vector2(
		clampf((vp.x - _panel.size.x) * 0.5, 4.0, maxf(vp.x - _panel.size.x - 4.0, 4.0)),
		clampf((vp.y - _panel.size.y) * 0.5, 4.0, maxf(vp.y - _panel.size.y - 4.0, 4.0)))


# ================= 双栏分隔条（可拖调整左右占比） =================

var _split_ratio := 0.72   # 左列宽度占比
var _split_dragging := false


## 在 HBox 的两列之间插入可拖分隔条; 拖动实时改两列 stretch_ratio
func _make_split(cols: HBoxContainer, left: Control, right: Control) -> void:
	var d := ColorRect.new()
	d.color = Color(1, 1, 1, 0.1)   # EVE DividerLine: 白 10%
	d.custom_minimum_size = Vector2(3, 0)
	d.mouse_filter = Control.MOUSE_FILTER_STOP
	d.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	d.tooltip_text = "拖动调整两栏宽度"
	d.gui_input.connect(_on_split_input.bind(cols, left, right))
	d.mouse_entered.connect(func(): d.color = EconTheme.ACCENT)
	d.mouse_exited.connect(_on_split_exit.bind(d))
	cols.add_child(d)
	_apply_split(left, right)


func _on_split_exit(d: ColorRect) -> void:
	if not _split_dragging:
		d.color = Color(1, 1, 1, 0.1)


func _on_vsplit_exit(d: ColorRect) -> void:
	if not _vs_dragging:
		d.color = Color(1, 1, 1, 0.1)


func _on_split_input(ev: InputEvent, cols: HBoxContainer, left: Control, right: Control) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_split_dragging = ev.pressed
		if not ev.pressed:
			_persist_layout()  # 拖完持久化占比
	elif ev is InputEventMouseMotion and _split_dragging:
		var rect := cols.get_global_rect()
		_split_ratio = clampf((cols.get_global_mouse_position().x - rect.position.x) / maxf(rect.size.x, 1.0), 0.3, 0.8)
		_apply_split(left, right)


func _apply_split(left: Control, right: Control) -> void:
	if left != null and is_instance_valid(left):
		left.size_flags_stretch_ratio = _split_ratio
	if right != null and is_instance_valid(right):
		right.size_flags_stretch_ratio = 1.0 - _split_ratio


## 垂直版: 上下分区之间的可拖横条（调两区各占多高）
var _vs_ratio := 0.5
var _vs_dragging := false


func _make_vsplit(parent: VBoxContainer, top: Control, bottom: Control) -> void:
	var d := ColorRect.new()
	d.color = Color(1, 1, 1, 0.1)   # EVE DividerLine: 白 10%
	d.custom_minimum_size = Vector2(0, 3)
	d.mouse_filter = Control.MOUSE_FILTER_STOP
	d.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	d.tooltip_text = "拖动调整上下分区高度"
	d.gui_input.connect(_on_vsplit_input.bind(parent, top, bottom))
	d.mouse_entered.connect(func(): d.color = EconTheme.ACCENT)
	d.mouse_exited.connect(_on_vsplit_exit.bind(d))
	parent.add_child(d)
	_apply_vsplit(top, bottom)


var _vs_pending := -1.0   # 帧节流: motion 只存值
var _vs_pair := []        # [top, bottom]

func _on_vsplit_input(ev: InputEvent, parent: VBoxContainer, top: Control, bottom: Control) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_vs_dragging = ev.pressed
		if not ev.pressed:
			_vs_pending = -1.0
			_persist_layout()
	elif ev is InputEventMouseMotion and _vs_dragging:
		# 帧节流修卡顿: 鼠标 motion 每秒几百次, 布局应用每帧最多一次（_process 消费）
		var rect := parent.get_global_rect()
		_vs_ratio = clampf((parent.get_global_mouse_position().y - rect.position.y) / maxf(rect.size.y, 1.0), 0.2, 0.8)
		_vs_pair = [top, bottom]
		_vs_pending = _vs_ratio


func _apply_vsplit(top: Control, bottom: Control) -> void:
	if top != null and is_instance_valid(top):
		top.size_flags_vertical = Control.SIZE_EXPAND_FILL
		top.size_flags_stretch_ratio = _vs_ratio
	if bottom != null and is_instance_valid(bottom):
		bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
		bottom.size_flags_stretch_ratio = 1.0 - _vs_ratio


# ================= 窗口栈叠（EVE WindowStack 复刻） =================
# 行为规格（carbonui/window/stack.py + control/window.py FindWindowToStackTo）:
# - 拖动释放时: 被拖窗顶边落在目标窗标题栏区(水平重叠) → 并入目标成标签
# - 宿主标题栏下出现 tab 条, 点击切换; 只有 active 成员内容可见
# - 拖 tab 出宿主矩形 = 分离成独立窗

## 宿主: 吸收一个成员
func dock_member(guest) -> void:
	if guest == self or not (guest is EconPanelBase):
		return
	if guest.stack_host != "" or stack_host != "":
		return
	guest.stack_host = panel_id
	stack_members.append(guest.panel_id)
	if active_member == "":
		active_member = guest.panel_id
	_refresh_tab_bar()
	_apply_stack_visibility()
	post_to_host()
	guest._apply_dock_visual(true)


## 成员视觉: 寄宿时隐藏自己的标题栏/底栏/背板
func _apply_dock_visual(docked: bool) -> void:
	if _header_cont != null:
		_header_cont.visible = not docked
	if _footer != null:
		_footer.visible = not docked
	if _tab_bar != null:
		_tab_bar.visible = not docked and stack_members.size() > 0
	backdrop_scale_hack(docked)


## 寄宿成员的背板透明化（视觉融入宿主）
func backdrop_scale_hack(on: bool) -> void:
	for i in get_child_count():
		var c := get_child(i)
		if c is ColorRect and c.name == "":
			(c as ColorRect).modulate.a = 0.0 if on else 1.0


## 成员每帧跟随宿主位置/尺寸（宿主 tab 条下方起）
func _sync_stack_member() -> void:
	if stack_host == "" or not visible:
		return
	var root := get_parent()
	if not (root is EconUiRoot):
		return
	var host = (root as EconUiRoot)._panels.get(stack_host)
	if host == null or not host.visible:
		return
	var tab_h: float = 26.0 if host._tab_bar != null and host._tab_bar.visible else 0.0
	_panel.position = host._panel.position + Vector2(0, tab_h)
	_panel.size = Vector2(host._panel.size.x, maxf(host._panel.size.y - tab_h, 100.0))
	_panel.scale = host._panel.scale
	_panel.pivot_offset = host._panel.pivot_offset


## 宿主: 刷新标签条
func _refresh_tab_bar() -> void:
	if _tab_bar == null:
		return
	for c in _tab_bar.get_children():
		_tab_bar.remove_child(c)
		c.queue_free()
	if stack_members.is_empty():
		_tab_bar.visible = false
		return
	_tab_bar.visible = true
	# 第一个 tab = 宿主自己
	_tab_bar.add_child(_make_tab(panel_id, _title, true))
	var root := get_parent()
	for mid in stack_members:
		var mp = (root as EconUiRoot)._panels.get(mid) if root is EconUiRoot else null
		if mp != null:
			_tab_bar.add_child(_make_tab(mid, mp._title, false))
	_update_tab_styles()


func _make_tab(id: String, caption: String, is_self: bool) -> Control:
	var b := Button.new()
	b.text = caption
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, 24)
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.set_meta("tab_id", id)
	if is_self:
		b.tooltip_text = "宿主标签"
	else:
		b.tooltip_text = "点击切换 · 按住拖出=分离"
	var host := self
	var tab_id := id
	var start := Vector2.ZERO
	var held := false
	b.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			held = ev.pressed
			start = b.get_global_mouse_position() if ev.pressed else Vector2.ZERO
		elif ev is InputEventMouseButton and not ev.pressed:
			held = false
		)
	b.pressed.connect(func():
		if held and start != Vector2.ZERO and b.get_global_mouse_position().distance_to(start) > 40.0:
			host.undock_member(tab_id)  # 拖出宿主=分离
		else:
			host._select_tab(tab_id))
	return b


func _select_tab(id: String) -> void:
	active_member = "" if id == panel_id else id
	_apply_stack_visibility()
	_update_tab_styles()


## 栈内只有 active 的内容可见
func _apply_stack_visibility() -> void:
	var root := get_parent()
	if not (root is EconUiRoot):
		return
	var ui := root as EconUiRoot
	# 宿主自身 body
	if _scroll != null:
		_scroll.visible = active_member == "" and not _collapsed
	if _own_scroll and body != null:
		body.visible = active_member == "" and not _collapsed
	# 成员
	for mid in stack_members:
		var mp = ui._panels.get(mid)
		if mp != null:
			mp.visible = mid == active_member
			mp._apply_dock_visual(true)


func _update_tab_styles() -> void:
	if _tab_bar == null:
		return
	for i in _tab_bar.get_child_count():
		var b := _tab_bar.get_child(i) as Button
		if b == null:
			continue
		var active_id := panel_id if active_member == "" else active_member
		var is_active: bool = str(b.get_meta("tab_id", "")) == active_id
		b.button_pressed = is_active
		b.add_theme_color_override("font_color", EconTheme.ACCENT if is_active else EconTheme.DIM)
		b.add_theme_stylebox_override("normal", EconTheme.style_box(
			EconTheme.PANEL2.lightened(0.08) if is_active else EconTheme.PANEL2.darkened(0.1),
			EconTheme.ACCENT if is_active else EconTheme.BORDER.darkened(0.2), 3))


## 分离成员（EVE RemoveWnd: 拖出宿主矩形）
func undock_member(member_id: String) -> void:
	stack_members.erase(member_id)
	var root := get_parent()
	if root is EconUiRoot:
		var mp = (root as EconUiRoot)._panels.get(member_id)
		if mp != null:
			mp.stack_host = ""
			mp.visible = false  # 分离后先收起, 由调用方重新 open 到新位置
			mp._apply_dock_visual(false)
			mp._panel.position = _panel.position + Vector2(30, 60)
			mp.open()
	if active_member == member_id:
		active_member = ""
	_refresh_tab_bar()
	_apply_stack_visibility()
	post_to_host()


## 关闭=关整栈（EVE CloseByUser 关栈）
func _close_stack() -> void:
	var root := get_parent()
	if root is EconUiRoot:
		(root as EconUiRoot).close_stack(panel_id)
	post_to_host()


func post_to_host() -> void:
	_persist_layout()


# ================= 活动窗口染色（only_tint_active_window） =================

func _on_panel_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		if _resizing:
			_apply_resize(ev as InputEventMouseMotion)
			accept_event()
		else:
			var side := _edge_side_at(ev.position, _panel.size)
			_panel.mouse_default_cursor_shape = _cursor_for_side(side) if side >= 0 else Control.CURSOR_ARROW
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var side := _edge_side_at(ev.position, _panel.size)
		if side >= 0:
			_resizing = true
			_resize_side = side
			accept_event()
			return
		_set_active()


func _set_active() -> void:
	var root := get_parent()
	if root is EconUiRoot:
		(root as EconUiRoot).set_active_panel(self)


func set_tint(active: bool) -> void:
	if _panel != null:
		_panel.self_modulate = Color(1, 1, 1) if active else Color(0.84, 0.88, 0.96)


# ================= 视觉缩放 =================

func _zoom_in() -> void:
	_zoom_step(1)


func _zoom_out() -> void:
	_zoom_step(-1)


func _zoom_step(dir: int) -> void:
	var root := get_parent()
	if root is EconUiRoot:
		(root as EconUiRoot).zoom_step(dir)


func _apply_zoom() -> void:
	if _panel == null:
		return
	var s: float = EconUiRoot.ui_scale
	_panel.scale = Vector2.ONE * s
	if _zoom_label != null:
		_zoom_label.text = "%d%%" % int(round(s * 100.0))
	call_deferred("_update_pivot")


func _update_pivot() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.pivot_offset = _panel.size * 0.5


# ================= 布局持久化 =================

func _persist_layout() -> void:
	var root := get_parent()
	if root is EconUiRoot:
		(root as EconUiRoot).save_window_layout()
