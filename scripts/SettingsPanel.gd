extends CanvasLayer
## 设置面板（autoload 单例，独立文件，不进任何主场景）：
## - ESC 呼出/关闭；第一页: Setting / Exit Game
## - 第二页: 抗锯齿(下拉: 关闭/MSAA 3D/FXAA)、全屏显示、返回上一页
## - 抗锯齿选择持久化到 user://settings.cfg，下次启动自动应用
## 编辑器内不构建不响应，只在运行的游戏里生效。

const CFG_PATH := "user://settings.cfg"

var _root: Control
var _page1: VBoxContainer
var _page2: VBoxContainer
var _aa_option: OptionButton
var _fullscreen_btn: CheckButton
var _aa_mode := 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_build_ui()
	_load_and_apply()


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		toggle_panel()
		get_viewport().set_input_as_handled()


# ---------- UI 构建 ----------

func _build_ui() -> void:
	layer = 20
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP   # 面板开着时挡住游戏点击
	_root.visible = false
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	# ---- 第一页 ----
	_page1 = VBoxContainer.new()
	_page1.add_theme_constant_override("separation", 12)
	vbox.add_child(_page1)
	_page1.add_child(_make_button("Setting", _show_page2))
	_page1.add_child(_make_button("Exit Game", _exit_game))

	# ---- 第二页 ----
	_page2 = VBoxContainer.new()
	_page2.add_theme_constant_override("separation", 12)
	_page2.visible = false
	vbox.add_child(_page2)

	var title := Label.new()
	title.text = "Setting"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page2.add_child(title)

	var aa_row := HBoxContainer.new()
	aa_row.add_theme_constant_override("separation", 12)
	_page2.add_child(aa_row)
	var aa_label := Label.new()
	aa_label.text = "抗锯齿"
	aa_row.add_child(aa_label)
	_aa_option = OptionButton.new()
	_aa_option.add_item("关闭")        # 0
	_aa_option.add_item("MSAA 3D")    # 1
	_aa_option.add_item("FXAA")       # 2
	_aa_option.item_selected.connect(set_aa_mode)
	aa_row.add_child(_aa_option)

	_fullscreen_btn = CheckButton.new()
	_fullscreen_btn.text = "全屏显示"
	_fullscreen_btn.toggled.connect(_on_fullscreen_toggled)
	_page2.add_child(_fullscreen_btn)

	_page2.add_child(_make_button("返回上一页", _show_page1))


func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(240, 44)
	b.pressed.connect(handler)
	return b


# ---------- 对外接口 ----------

func is_panel_visible() -> bool:
	return _root != null and _root.visible


func is_page2_active() -> bool:
	return _page2 != null and _page2.visible


func toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_show_page1()


func show_page1() -> void:
	_page1.visible = true
	_page2.visible = false


func show_page2() -> void:
	_page1.visible = false
	_page2.visible = true


func set_fullscreen(on: bool) -> void:
	if _fullscreen_btn != null:
		_fullscreen_btn.set_pressed_no_signal(on)
	_on_fullscreen_toggled(on)


func set_aa_mode(mode: int) -> void:
	_aa_mode = clampi(mode, 0, 2)
	var vp := get_viewport()
	match _aa_mode:
		1:
			vp.msaa_3d = Viewport.MSAA_4X
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		2:
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		_:
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	if _aa_option != null:
		_aa_option.select(_aa_mode)
	# 持久化
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("video", "anti_aliasing", _aa_mode)
	cfg.save(CFG_PATH)


# ---------- 内部 ----------

func _show_page1() -> void:
	show_page1()


func _show_page2() -> void:
	show_page2()


func _exit_game() -> void:
	get_tree().quit()


func _on_fullscreen_toggled(on: bool) -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


func _load_and_apply() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		set_aa_mode(int(cfg.get_value("video", "anti_aliasing", 0)))
	else:
		set_aa_mode(0)
