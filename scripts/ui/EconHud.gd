class_name EconHud
extends Control

## 常驻 HUD：左下通讯收件箱与短暂事件提示。
## 资源（钱/燃料/日期/泊位）改为空间站上方 3D 字牌（StationModules._info_label）；
## 通讯入口常驻，其余模块功能从空间站悬浮窗进入。

var _ticker: VBoxContainer
var _mail_button: Button
var _faction_status: Control
var _contracts_button: Button


func _ready() -> void:
	# CanvasLayer does not provide a parent Control rectangle for anchors.
	_sync_viewport()
	get_viewport().size_changed.connect(_sync_viewport)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_faction_status = preload("res://scripts/ui/FactionStatus.gd").new()
	add_child(_faction_status)
	_contracts_button = EconTheme.button("生产委托", func(): get_parent().open_panel_add("contracts"), Vector2(160, 34))
	_contracts_button.name = "ProductionContractsButton"
	add_child(_contracts_button)
	_sync_viewport()

	_mail_button = preload("res://scripts/ui/InboxButton.gd").new()
	_mail_button.name = "InboxButton"
	_mail_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_mail_button.offset_left = 12.0
	_mail_button.offset_right = 64.0
	_mail_button.offset_top = -64.0
	_mail_button.offset_bottom = -16.0
	add_child(_mail_button)
	_mail_button.pressed.connect(_open_inbox)
	_mail_button.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_open_inbox()
			_mail_button.accept_event())

	# ---- 左下事件滚动 ----
	_ticker = EconTheme.vbox(2)
	_ticker.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_ticker.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ticker.offset_top = -16.0
	_ticker.offset_bottom = -16.0
	_ticker.offset_left = 82.0
	_ticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ticker)

	Economy.event_posted.connect(_on_event)


func _sync_viewport() -> void:
	size = get_viewport_rect().size
	if is_instance_valid(_faction_status):
		_faction_status.size = Vector2(minf(500, size.x - 200), 62)
		_faction_status.position = Vector2(maxf(12, (size.x - _faction_status.size.x) * 0.5 - 90), 34)
	if is_instance_valid(_contracts_button):
		_contracts_button.position = Vector2(size.x - 176, 40)


func _open_inbox() -> void:
	var ui := get_parent()
	ui.hide_station_popup()
	ui.open_panel_add("inbox")


func _on_event(text: String, kind: String) -> void:
	var col := EconTheme.TEXT
	match kind:
		"good": col = EconTheme.GOOD
		"rare": col = EconTheme.RARE
		"warn": col = EconTheme.WARN
		"info": col = EconTheme.DIM
	var l := EconTheme.label(text, col, 13)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ticker.add_child(l)
	if _ticker.get_child_count() > 6:
		_ticker.get_child(0).queue_free()
	var tw := l.create_tween()
	tw.tween_interval(8.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.5)
	tw.tween_callback(l.queue_free)
