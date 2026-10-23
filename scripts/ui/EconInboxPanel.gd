class_name EconInboxPanel
extends EconPanelBase

const FILTERS := ["", "event", "faction", "other"]
const CATEGORY_NAMES := {"event": "事件通知", "faction": "势力来信", "other": "其他消息"}

var _category := ""
var _search := ""
var _selected_id := 0
var _messages: ItemList
var _detail_scroll: ScrollContainer
var _detail: VBoxContainer
var _summary: Label
var _all_read: Button
var _shown_message: Dictionary = {}


func _init() -> void:
	super("通讯 · 收件箱")
	_own_scroll = true
	default_size = Vector2(880, 520)


func _panel_min() -> Vector2:
	return Vector2(660, 340)


func _connect_signals() -> void:
	Economy.inbox.changed.connect(_on_messages_changed)


func _collect_itemlists() -> Array:
	return [_messages] if is_instance_valid(_messages) else []


func _collect_scrolls() -> Array:
	return [_detail_scroll] if is_instance_valid(_detail_scroll) else []


func _rebuild() -> void:
	var toolbar := EconTheme.hbox(8)
	body.add_child(toolbar)
	var category := OptionButton.new()
	for name in ["全部消息", "事件通知", "势力来信", "其他消息"]:
		category.add_item(name)
	category.selected = FILTERS.find(_category)
	category.item_selected.connect(func(index: int):
		_category = FILTERS[index]
		_fill_list())
	toolbar.add_child(category)
	var search := LineEdit.new()
	search.placeholder_text = "搜索标题、发件人或正文"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text = _search
	search.text_changed.connect(func(value: String):
		_search = value
		_fill_list())
	toolbar.add_child(search)
	_all_read = EconTheme.button("全部已读", func(): Economy.inbox.mark_all_read(), Vector2(94, 30))
	toolbar.add_child(_all_read)
	_summary = EconTheme.label("", EconTheme.DIM, 12)
	body.add_child(_summary)

	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.custom_minimum_size.y = 250
	columns.split_offset = 300
	body.add_child(columns)
	_messages = ItemList.new()
	_messages.name = "MessageList"
	_messages.allow_reselect = true
	_messages.max_text_lines = 2
	_messages.add_theme_constant_override("v_separation", 10)
	_messages.custom_minimum_size.x = 230
	_messages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_font_size_override("font_size", 13)
	_messages.item_selected.connect(_on_selected)
	columns.add_child(_messages)
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.custom_minimum_size.x = 300
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(_detail_scroll)
	_detail = EconTheme.vbox(10)
	_shown_message = {}
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.add_child(_detail)
	_fill_list()
	body.add_child(EconTheme.label("保留最近 %d 条消息 · 选择消息后标为已读" % Economy.inbox.MAX_MESSAGES, EconTheme.DIM, 11))


func _on_messages_changed() -> void:
	# Update existing controls so new messages cannot reset typing or scroll position.
	if visible and is_instance_valid(_messages):
		_fill_list()


func _fill_list() -> void:
	if not is_instance_valid(_messages):
		return
	var scroll := _messages.get_v_scroll_bar().value
	_messages.clear()
	var rows: Array = Economy.inbox.filtered_messages(_category, _search)
	var selected_visible := false
	for item in rows:
		var repetition := " ×%d" % int(item.count) if int(item.count) > 1 else ""
		var text := "%s %s%s" % ["●" if not item.read else "·", item.title, repetition]
		var index := _messages.add_item(text)
		_messages.set_item_metadata(index, int(item.id))
		_messages.set_item_tooltip(index, "%s\n%s · 第%d天" % [item.title, item.sender, int(item.day)])
		_messages.set_item_custom_fg_color(index, EconTheme.TEXT if not item.read else EconTheme.DIM)
		if int(item.id) == _selected_id:
			_messages.select(index)
			selected_visible = true
	if not selected_visible:
		_selected_id = 0
	_messages.get_v_scroll_bar().value = scroll
	var unread: int = Economy.inbox.unread_count()
	_summary.text = "%d 条未读 · 当前分类 %d 条" % [unread, rows.size()]
	_all_read.disabled = unread == 0
	if rows.is_empty():
		_messages.add_item("没有匹配的消息" if _search != "" else "暂无消息")
		_messages.set_item_disabled(0, true)
		_messages.set_item_selectable(0, false)
	_show_detail()


func _on_selected(index: int) -> void:
	var value: Variant = _messages.get_item_metadata(index)
	if value == null:
		return
	_selected_id = int(value)
	Economy.inbox.mark_read(_selected_id)
	_show_detail()
	_detail_scroll.scroll_vertical = 0


func _show_detail() -> void:
	var item: Dictionary = Economy.inbox.message(_selected_id)
	if item == _shown_message and _detail.get_child_count() > 0:
		return
	_shown_message = item
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	if item.is_empty():
		_detail.add_child(_wrapped("选择一条消息查看内容。", EconTheme.DIM, 14))
		return
	var color := EconTheme.ACCENT
	if item.kind == "warn":
		color = EconTheme.WARN
	elif item.kind == "good":
		color = EconTheme.GOOD
	_detail.add_child(_wrapped(String(item.title), color, 18))
	_detail.add_child(_wrapped("%s · %s · 第%d天" % [item.sender, CATEGORY_NAMES[item.category], int(item.day)], EconTheme.DIM, 12))
	if String(item.get("illustration", "")).begins_with("incident_"):
		var picture := TextureRect.new()
		picture.texture = preload("res://scripts/ui/FactionArt.gd").incident(String(item.get("faction_id", "empire")))
		picture.custom_minimum_size = Vector2(0, 105)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_detail.add_child(picture)
		_detail.add_child(_wrapped("现场态势示意图", EconTheme.DIM, 11))
	_detail.add_child(_wrapped(String(item.body), EconTheme.TEXT, 14))
	if int(item.count) > 1:
		_detail.add_child(_wrapped("同类通知连续出现 %d 次。" % int(item.count), EconTheme.DIM, 12))


func _wrapped(text: String, color: Color, font_size: int) -> Label:
	var label := EconTheme.label(text, color, font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
