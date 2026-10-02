class_name EconHud
extends Control

## 常驻 HUD：仅左下事件滚动条。
## 资源（钱/燃料/日期/泊位）改为空间站上方 3D 字牌（StationModules._info_label）；
## 全部功能按键只通过点击空间站的悬浮窗进入（2026-09-30 拍板）。

var _ticker: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ---- 左下事件滚动 ----
	_ticker = EconTheme.vbox(2)
	_ticker.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_ticker.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ticker.offset_top = -10.0
	_ticker.offset_left = 12.0
	_ticker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ticker)

	Economy.event_posted.connect(_on_event)


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
