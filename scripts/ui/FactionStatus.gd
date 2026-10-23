extends Control

var _left: Label
var _right: Label
var _timer := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(320, 62)
	_left = EconTheme.label("", Color("75cbe6"), 11)
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left.clip_text = true
	add_child(_left)
	_right = EconTheme.label("", Color("edac73"), 11)
	_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right.clip_text = true
	add_child(_right)
	Economy.diplomacy.changed.connect(refresh)
	refresh()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= 0.5:
		_timer = 0.0
		refresh()


func refresh() -> void:
	var r: Node = Economy.diplomacy
	_left.text = "联盟 %.0f / 300\n%s" % [r.suspicion.southern, r.stage_name("southern")]
	_right.text = "帝国 %.0f / 300\n%s" % [r.suspicion.empire, r.stage_name("empire")]
	_left.position = Vector2(0, 0)
	_right.position = Vector2(size.x * 0.5 + 12, 0)
	_left.size = Vector2(size.x * 0.5 - 12, 34)
	_right.size = Vector2(size.x * 0.5 - 12, 34)
	tooltip_text = "争议星系：联盟与帝国均宣称拥有主权，海盗长期活动。\n双方怀疑分别从 0 累计：100 审查官、200 审查舰队、300 第三阶段预留。\n交付委托：另一方 +35；势力任务成功 +25；每累计采购 ₡5,000：另一方 +20。\n审查官贿赂 ₡1,500，减少完整一阶段（100 点）。"
	queue_redraw()


func _draw() -> void:
	var half := (size.x - 12.0) * 0.5
	var y := 40.0
	draw_rect(Rect2(0, y, size.x, 12), Color(0.035, 0.055, 0.07, 0.95))
	var left: float = half * float(Economy.diplomacy.suspicion.southern) / 300.0
	var right: float = half * float(Economy.diplomacy.suspicion.empire) / 300.0
	draw_rect(Rect2(half - left, y + 2, left, 8), Color("75cbe6"))
	draw_rect(Rect2(half + 12, y + 2, right, 8), Color("edac73"))
	for index in range(1, 4):
		draw_line(Vector2(half - half * index / 3.0, y), Vector2(half - half * index / 3.0, y + 12), EconTheme.DIM, 1)
		draw_line(Vector2(half + 12 + half * index / 3.0, y), Vector2(half + 12 + half * index / 3.0, y + 12), EconTheme.DIM, 1)
	draw_line(Vector2(half + 6, y - 5), Vector2(half + 6, y + 17), EconTheme.TEXT, 2)
