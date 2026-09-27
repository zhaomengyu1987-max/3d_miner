extends Node
## SettingsPanel 自动化测试（独立场景，不进任何游戏流程）：
##   godot --headless --path . res://tests/settings_test.tscn
## 通过打印 SETTINGS_TEST_PASS / SETTINGS_TEST_FAIL，退出码 0/1。

var _fails := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var panel := get_tree().root.get_node_or_null("SettingsPanel")
	_check(panel != null, "autoload SettingsPanel 存在")
	if panel == null:
		return _finish()
	_check(not panel.is_panel_visible(), "初始隐藏")

	# ESC 唤出
	_press_esc()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(panel.is_panel_visible(), "ESC 打开面板")
	_check(not panel.is_page2_active(), "打开后默认第一页")

	# 返回游戏
	panel.return_to_game()
	await get_tree().process_frame
	_check(not panel.is_panel_visible(), "返回游戏关闭面板")
	_press_esc()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(panel.is_panel_visible(), "重新呼出")

	# 进入第二页
	panel.show_page2()
	await get_tree().process_frame
	_check(panel.is_page2_active(), "Setting 进入第二页")

	# 抗锯齿应用 + 切换
	panel.set_aa_mode(1)
	await get_tree().process_frame
	_check(get_viewport().msaa_3d == Viewport.MSAA_4X, "MSAA 3D -> msaa_3d=4X")
	_check(get_viewport().screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED, "MSAA 模式下 FXAA 关闭")
	panel.set_aa_mode(2)
	await get_tree().process_frame
	_check(get_viewport().screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA, "FXAA -> screen_space_aa=FXAA")
	_check(get_viewport().msaa_3d == Viewport.MSAA_DISABLED, "FXAA 模式下 MSAA 关闭")
	panel.set_aa_mode(0)
	await get_tree().process_frame
	_check(get_viewport().msaa_3d == Viewport.MSAA_DISABLED
		and get_viewport().screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED, "关闭 -> 全部关")

	# 持久化（最后写入的是 0）
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	_check(int(cfg.get_value("video", "anti_aliasing", -1)) == 0, "抗锯齿选择已持久化到 settings.cfg")
	# 换个值再验证落盘
	panel.set_aa_mode(1)
	cfg.load("user://settings.cfg")
	_check(int(cfg.get_value("video", "anti_aliasing", -1)) == 1, "再次选择落盘更新")
	panel.set_aa_mode(0)

	# 全屏路径冒烟（headless 无真实窗口，只验证不崩）
	panel.set_fullscreen(true)
	await get_tree().process_frame
	panel.set_fullscreen(false)
	await get_tree().process_frame
	print("  PASS: 全屏切换路径无异常")

	# 返回上一页
	panel.show_page1()
	_check(not panel.is_page2_active(), "返回上一页")

	# ESC 关闭
	_press_esc()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not panel.is_panel_visible(), "ESC 关闭面板")

	_finish()


func _press_esc() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  PASS: ", what)
	else:
		_fails += 1
		print("  FAIL: ", what)


func _finish() -> void:
	if _fails == 0:
		print("SETTINGS_TEST_PASS")
		get_tree().quit(0)
	else:
		print("SETTINGS_TEST_FAIL (%d)" % _fails)
		get_tree().quit(1)
