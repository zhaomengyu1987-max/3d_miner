extends Node3D

var failures := 0
var assertions := 0
var broadcasts := 0


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("INBOX: " + message)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.inbox.set_process(false)
	Economy._world.set_process(false)
	WorldState.set_process(false)
	MissionOps.set_process(false)
	Economy.save_path = "user://inbox_test_save.json"
	WorldState._save_path = "user://inbox_test_world.json"
	Economy.event_posted.connect(func(_text: String, _kind: String): broadcasts += 1)
	_test_receive()
	_test_state()
	_test_sources()
	await _test_ui()
	print("INBOX_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func _test_receive() -> void:
	Economy.debug_reset()
	check(Economy.inbox.unread_count() == 0, "New game has empty inbox")
	Economy.post_event("生产完成：动能实弹 ×1", "good")
	check(broadcasts == 1 and Economy.inbox.messages.size() == 1, "Existing event recorded exactly once and still broadcast")
	var item: Dictionary = Economy.inbox.filtered_messages()[0]
	check(item.category == "event" and item.kind == "good" and item.body.contains("动能实弹"), "Events retain category, severity and full body")
	check(item.day == 1 and item.timestamp > 0 and not item.read, "New message records date and unread status")
	Economy.inbox.mark_read(int(item.id))
	check(Economy.inbox.unread_count() == 0, "Individual read state")
	Economy.post_event("生产完成：动能实弹 ×1", "good")
	check(Economy.inbox.messages.size() == 1 and Economy.inbox.messages[0].count == 2, "Consecutive repeated events coalesce")
	check(Economy.inbox.unread_count() == 1, "New repetition becomes unread")
	Economy.post_event("联络函已到达", "warn", {"category": "faction", "sender": "帝国联络处", "faction_id": "empire",
		"title": "帝国采购意向", "body": "请贵站准备装甲附加板。"})
	item = Economy.inbox.filtered_messages("faction")[0]
	check(item.title == "帝国采购意向" and item.faction_id == "empire" and item.body.contains("装甲"), "Structured faction correspondence")
	var id: int = Economy.post_message("私人联络", "货运排班已经更新。", "港务代理")
	check(id > 0 and broadcasts == 3, "Direct message avoids duplicate transient event broadcast")
	check(Economy.inbox.filtered_messages("other", "货运排班").size() == 1, "Category and body search")
	check(Economy.inbox.filtered_messages("faction", "帝国联络处").size() == 1, "Sender search")
	check(Economy.inbox.filtered_messages("event", "帝国").is_empty(), "Category search excludes unrelated messages")
	Economy.inbox.mark_read(id)
	check(Economy.inbox.unread_count() == 2, "Reading one message leaves other messages unread")
	Economy.inbox.mark_all_read()
	check(Economy.inbox.unread_count() == 0 and Economy.inbox.messages.size() == 3, "Mark all read preserves history")
	check(Economy.post_message("", "") == 0, "Blank messages ignored")
	Economy.post_message("未知类型", "保留消息", "系统", "future")
	check(Economy.inbox.filtered_messages("other").size() == 2, "Unknown future category remains accessible")


func _test_state() -> void:
	var expected: Dictionary = Economy.inbox.get_state()
	check(Economy.save_game(), "Mailbox saved with economy")
	Economy.debug_reset()
	Economy.load_game()
	check(Economy.inbox.get_state() == expected, "History, senders, date, repetitions and read flags round-trip")
	var next: int = Economy.post_message("存档后新消息", "ID不会覆盖旧消息")
	check(next >= int(expected.next_id), "Restored message IDs remain unique")
	Economy.inbox._process(3.1)
	var file := FileAccess.open(Economy.save_path, FileAccess.READ)
	var stored: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	check(stored.inbox.messages.size() == Economy.inbox.messages.size(), "Debounced autosave persists new messages")
	var valid_path: String = Economy.save_path
	Economy.save_path = "user://missing_inbox_folder/fail.json"
	Economy.post_message("重试保存", "存档暂时不可写时消息仍保留")
	Economy.inbox._process(3.1)
	Economy.save_path = valid_path
	Economy.inbox._process(3.1)
	file = FileAccess.open(Economy.save_path, FileAccess.READ)
	stored = JSON.parse_string(file.get_as_text())
	file.close()
	check(stored.inbox.messages.back().title == "重试保存", "Failed inbox autosave retries without losing messages")
	stored.erase("inbox")
	file = FileAccess.open(Economy.save_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(stored))
	file.close()
	Economy.load_game()
	check(Economy.inbox.messages.is_empty(), "Old save without inbox loads normally")
	for index in Economy.inbox.MAX_MESSAGES + 5:
		Economy.post_message("消息 %d" % index, "保留最近消息")
	check(Economy.inbox.messages.size() == Economy.inbox.MAX_MESSAGES, "Bounded history")
	check(Economy.inbox.messages[0].title == "消息 5", "Only oldest messages trimmed")
	var snapshot: Dictionary = Economy.inbox.get_state()
	Economy.inbox.apply_state(snapshot)
	check(Economy.inbox.get_state() == snapshot, "Full history survives load")
	Economy.inbox.apply_state({"messages": [null, "invalid", {}, {"id": 9, "title": "兼容消息", "body": "正文"}]})
	check(Economy.inbox.messages.size() == 1 and Economy.inbox.unread_count() == 1, "Incomplete history safely restores available message fields")


func _test_sources() -> void:
	Economy.debug_reset()
	WorldState.debug_reset()
	WorldState._enter_phase(WorldState.Phase.BUILDUP)
	var letters: Array = Economy.inbox.filtered_messages("faction", "军备采购通告")
	check(letters.size() == 1 and letters[0].sender.ends_with("联络处"), "Actual preparation phase sends faction letter")
	check(letters[0].body.contains("致空间站管理者") and letters[0].faction_id == WorldState.current_faction, "Faction letter has sender identity and content")
	WorldState._enter_phase(WorldState.Phase.WAR)
	check(Economy.inbox.filtered_messages("faction", "战时补给联络函").size() == 1, "War declaration received")
	WorldState._enter_phase(WorldState.Phase.PEACE)
	check(Economy.inbox.filtered_messages("faction", "停火与通商恢复通知").size() == 1, "Peace letter received")
	Economy.modules.hangar.built = true
	Economy.modules.hangar.level = 3
	Economy.fuel = 1000.0
	WorldState._ensure_dealer()
	check(Economy.inbox.filtered_messages("faction", "军需采购团到港函").size() == 1, "Procurement visitor arrival letter received")
	var count: int = Economy.inbox.messages.size()
	WorldState._sync_phase(Economy.day, true)
	check(Economy.inbox.messages.size() == count, "Initial phase synchronization does not resend correspondence")
	var report := {"mission_id": "mail_test_1", "task": "航道巡逻", "success": true, "ep": 12, "credits": 70.0,
		"timestamp": 123.456, "seed": 25}
	MissionOps.mission_completed.emit(report)
	var reports: Array = Economy.inbox.filtered_messages("event", "任务成功")
	check(reports.size() == 1 and reports[0].sender == "行动指挥部" and reports[0].body.contains("70"), "Mission completion signal creates result notification")
	MissionOps.mission_completed.emit(report)
	check(Economy.inbox.filtered_messages("event", "任务成功").size() == 1, "Retried mission report does not duplicate message")
	WorldState._despawn_dealer("")


func _test_ui() -> void:
	Economy.debug_reset()
	var ui = get_tree().get_first_node_in_group("econ_ui")
	var icon: Button = ui.find_child("InboxButton", true, false)
	check(icon != null and icon.is_visible_in_tree(), "Mailbox icon always visible")
	check(icon.mouse_filter == Control.MOUSE_FILTER_STOP, "Mailbox click does not fall through to game")
	var rect := icon.get_global_rect()
	var viewport := get_viewport().get_visible_rect()
	check(rect.position.x < 80.0 and viewport.end.y - rect.end.y < 80.0 and viewport.encloses(rect), "Icon anchored to bottom left inside viewport")
	Economy.post_event("燃料不足：来访暂停", "warn")
	Economy.post_message("测试来信", "[b]这是一封完整来信[/b]\n\n空间站管理者，请查收。", "帝国联络处", "faction", "empire")
	check(icon._badge.visible and icon._count.text == "2", "Unread badge updates immediately")
	ui.open_panel("inventory")
	for frame in 2:
		await get_tree().process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = rect.get_center()
	motion.global_position = rect.get_center()
	get_viewport().push_input(motion, true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = rect.get_center()
	click.global_position = rect.get_center()
	click.pressed = true
	get_viewport().push_input(click, true)
	var release := click.duplicate() as InputEventMouseButton
	release.pressed = false
	get_viewport().push_input(release, true)
	for frame in 4:
		await get_tree().process_frame
	var panel = ui._panels.inbox
	check(panel.visible and ui._panels.inventory.visible, "Icon opens mailbox while preserving other window")
	check(panel._messages.item_count == 2 and Economy.inbox.unread_count() == 2, "Opening inbox does not mark unseen messages read")
	panel._on_selected(0)
	check(Economy.inbox.unread_count() == 1 and icon._count.text == "1", "Selecting message marks only it read and updates badge")
	var body_found := false
	for label in panel._detail.get_children():
		body_found = body_found or (label is Label and label.text.contains("[b]这是一封完整来信[/b]"))
	check(body_found, "Full body shown as safe plain text")
	panel._category = "faction"
	panel._fill_list()
	check(panel._messages.item_count == 1, "Faction folder filters list")
	panel._search = "不存在的正文"
	panel._fill_list()
	check(panel._messages.is_item_disabled(0), "Empty search has harmless placeholder")
	panel._search = ""
	panel._category = ""
	panel._fill_list()
	panel._all_read.pressed.emit()
	check(not icon._badge.visible and Economy.inbox.messages.size() == 2, "Mark all read clears badge and retains messages")
	var selected: int = panel._selected_id
	Economy.post_event("新事件到达", "info")
	check(panel._messages.item_count == 3 and panel._selected_id == selected, "Live inbox update preserves selection")
	for index in 101:
		Economy.post_message("角标 %d" % index, "消息")
	check(icon._count.text == "99+", "Large unread counts have compact badge")
	panel.close()
	check(not panel.visible and ui._panels.inventory.visible, "Inbox closes independently of other windows")
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	right_click.position = icon.get_global_rect().get_center()
	get_viewport().push_input(right_click, true)
	check(panel.visible, "Right mouse button can also open mailbox")
	get_window().size = Vector2i(960, 640)
	for frame in 3:
		await get_tree().process_frame
	viewport = get_viewport().get_visible_rect()
	rect = icon.get_global_rect()
	check(viewport.encloses(rect) and viewport.end.y - rect.end.y < 80.0, "Mailbox remains at bottom left after resizing")
