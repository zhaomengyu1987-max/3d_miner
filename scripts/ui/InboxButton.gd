extends Button

var _badge: PanelContainer
var _count: Label


func _ready() -> void:
	custom_minimum_size = Vector2(52, 48)
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	add_theme_stylebox_override("normal", EconTheme.style_box(EconTheme.PANEL, EconTheme.ACCENT.darkened(0.45), 8))
	add_theme_stylebox_override("hover", EconTheme.style_box(EconTheme.PANEL2.lightened(0.08), EconTheme.ACCENT, 8))
	add_theme_stylebox_override("pressed", EconTheme.style_box(EconTheme.PANEL2, EconTheme.ACCENT, 8))
	_badge = PanelContainer.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := EconTheme.style_box(EconTheme.WARN, EconTheme.PANEL, 10)
	style.content_margin_left = 5.0
	style.content_margin_right = 5.0
	style.content_margin_top = 1.0
	style.content_margin_bottom = 1.0
	_badge.add_theme_stylebox_override("panel", style)
	_badge.position = Vector2(32, -6)
	_badge.custom_minimum_size = Vector2(20, 18)
	add_child(_badge)
	_count = EconTheme.label("", Color(0.08, 0.1, 0.11), 11)
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.add_child(_count)
	Economy.inbox.changed.connect(_refresh)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	_refresh()


func _refresh() -> void:
	var unread: int = Economy.inbox.unread_count()
	_badge.visible = unread > 0
	_count.text = "99+" if unread > 99 else str(unread)
	tooltip_text = "通讯收件箱 · %d 条未读\n事件通知 / 势力来信 / 其他消息" % unread
	queue_redraw()


func _draw() -> void:
	var color := EconTheme.ACCENT if is_hovered() else EconTheme.TEXT
	var corner := (size - Vector2(28, 20)) * 0.5
	draw_rect(Rect2(corner, Vector2(28, 20)), color, false, 1.5)
	draw_polyline(PackedVector2Array([corner + Vector2(1, 2), corner + Vector2(14, 11), corner + Vector2(27, 2)]), color, 1.5, true)
	draw_line(corner + Vector2(1, 19), corner + Vector2(10, 10), color, 1.0, true)
	draw_line(corner + Vector2(27, 19), corner + Vector2(18, 10), color, 1.0, true)
