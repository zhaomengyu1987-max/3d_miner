extends Node

## Station communications, independent of the UI. Saved with the economy state.
signal changed

const MAX_MESSAGES := 300
const CATEGORIES := ["event", "faction", "other"]
const SAVE_DELAY := 3.0

var eco: Node
var messages: Array = []
var _next_id := 1
var _dirty := false
var _save_clock := 0.0


func _ready() -> void:
	call_deferred("_connect_sources")


func _connect_sources() -> void:
	var missions := get_node_or_null("/root/MissionOps")
	if missions != null and not missions.mission_completed.is_connected(_on_mission_completed):
		missions.mission_completed.connect(_on_mission_completed)


func _process(delta: float) -> void:
	if not _dirty:
		return
	_save_clock += delta
	if _save_clock >= SAVE_DELAY:
		_save_clock = 0.0
		if eco.save_game():
			_dirty = false


func _notify() -> void:
	_dirty = true
	changed.emit()


func reset() -> void:
	messages.clear()
	_next_id = 1
	_dirty = false
	_save_clock = 0.0
	changed.emit()


func receive_event(text: String, kind: String, details: Dictionary = {}) -> int:
	var title := String(details.get("title", text.get_slice("：", 0)))
	if title.length() > 36:
		title = title.substr(0, 35) + "…"
	return receive(title, String(details.get("body", text)), String(details.get("category", "event")),
		String(details.get("sender", "空间站系统")), kind, String(details.get("faction_id", "")),
		String(details.get("source_id", "")), String(details.get("illustration", "")))


## Generic entry point for future diplomacy, missions, and story messages.
func receive(title: String, body: String, category := "other", sender := "空间站通讯",
		kind := "info", faction_id := "", source_id := "", illustration := "") -> int:
	if title.strip_edges().is_empty() and body.strip_edges().is_empty():
		return 0
	if not CATEGORIES.has(category):
		category = "other"
	if source_id != "":
		for item in messages:
			if String(item.get("source_id", "")) == source_id:
				return int(item.id)
	var now := int(Time.get_unix_time_from_system())
	# Collapse adjacent repeated system events; a new occurrence becomes unread again.
	if category == "event" and source_id == "" and not messages.is_empty():
		var last: Dictionary = messages.back()
		if last.category == category and last.title == title and last.body == body and last.sender == sender and last.kind == kind \
				and last.faction_id == faction_id and now - int(last.timestamp) >= 0 \
				and now - int(last.timestamp) <= 15 and int(last.day) == int(eco.day):
			last.count = int(last.count) + 1
			last.timestamp = now
			last.read = false
			_notify()
			return int(last.id)
	var id := _next_id
	_next_id += 1
	messages.append({"id": id, "title": title, "body": body, "category": category,
		"sender": sender, "faction_id": faction_id, "kind": kind, "read": false,
		"day": int(eco.day), "timestamp": now, "count": 1, "source_id": source_id, "illustration": illustration})
	while messages.size() > MAX_MESSAGES:
		messages.pop_front()
	_notify()
	return id


func unread_count() -> int:
	var count := 0
	for item in messages:
		if not bool(item.read):
			count += 1
	return count


func message(id: int) -> Dictionary:
	for item in messages:
		if int(item.id) == id:
			return item.duplicate(true)
	return {}


func filtered_messages(category := "", search := "") -> Array:
	var out := []
	var query := search.strip_edges().to_lower()
	for index in range(messages.size() - 1, -1, -1):
		var item: Dictionary = messages[index]
		if category != "" and item.category != category:
			continue
		if query != "" and not query in (String(item.title) + " " + String(item.sender) + " " + String(item.body)).to_lower():
			continue
		out.append(item.duplicate(true))
	return out


func mark_read(id: int) -> void:
	for item in messages:
		if int(item.id) == id and not bool(item.read):
			item.read = true
			_notify()
			return


func mark_all_read() -> void:
	var dirty := false
	for item in messages:
		if not bool(item.read):
			item.read = true
			dirty = true
	if dirty:
		_notify()


func get_state() -> Dictionary:
	return {"messages": messages.duplicate(true), "next_id": _next_id}


func apply_state(state: Dictionary) -> void:
	messages.clear()
	_next_id = maxi(1, int(state.get("next_id", 1)))
	var saved: Variant = state.get("messages", [])
	if saved is Array:
		for item in saved:
			if not item is Dictionary or not item.has_all(["id", "title", "body"]):
				continue
			var id := int(item.id)
			if id <= 0 or not message(id).is_empty():
				continue
			var category := String(item.get("category", "other"))
			messages.append({"id": id, "title": String(item.title), "body": String(item.body),
				"category": category if CATEGORIES.has(category) else "other",
				"sender": String(item.get("sender", "空间站通讯")), "kind": String(item.get("kind", "info")),
				"faction_id": String(item.get("faction_id", "")), "read": bool(item.get("read", false)),
				"day": maxi(1, int(item.get("day", 1))), "timestamp": int(item.get("timestamp", 0)),
				"count": maxi(1, int(item.get("count", 1))), "source_id": String(item.get("source_id", "")),
				"illustration": String(item.get("illustration", ""))})
			_next_id = maxi(_next_id, id + 1)
	while messages.size() > MAX_MESSAGES:
		messages.pop_front()
	_dirty = false
	_save_clock = 0.0
	changed.emit()


func _on_mission_completed(report: Dictionary) -> void:
	var result := "任务成功" if report.get("success", false) else ("部分成功" if report.get("partial", false) else "任务失败")
	var task := String(report.get("task", "探索任务"))
	var body := "%s：%s\n\n探索点 +%d\n报酬 %s\n\n详细战报可在行动中心查看。" % [
		task, result, int(report.get("ep", 0)), EconTheme.money(float(report.get("credits", 0.0)))]
	var source := "mission:%s:%d:%.6f" % [report.get("mission_id", ""), int(report.get("seed", 0)), float(report.get("timestamp", 0.0))]
	receive(result + " · " + task, body, "event", "行动指挥部",
		"good" if report.get("success", false) else "warn", "", source)
