class_name NewsTicker
extends Control

## 顶部新闻播报条（2026-10-02）
##
## 【数据源】与现有事件日志**同一条管道**: `Economy.event_posted(text, kind)` —— 世界叙事的
## 相位切换/军需采购团到港撤离/小国倒戈都在里面, 不需要额外接 WorldState 的文本流。
## 但这条管道也混着成交、入库、操作报错等非叙事文本, 所以按**关键词白名单**挑选
## （NEWS_KEYS, 与 WorldState/Economy 的文案用词保持一致）, kind 只决定颜色。
##
## 【常驻角标】走世界系统的**结构化公开接口**:
##   WorldState.phase_name() / days_left_in_phase() / phase / faction_display_name() /
##   current_faction / stockpile / ally_count() / dealer
## （2026-10-02 已把 phase_name/days_left_in_phase/phase_progress/current_faction 去掉下划线转正,
##   避免 UI 伸手摸私有字段。）
##
## 本节点全屏宽、高 28px、mouse_filter=IGNORE —— 不挡游戏点击, 也不与面板抢输入。

const BAR_H := 28.0
const SCROLL_SPEED := 70.0        # 滚动速度 px/秒
const BADGE_W := 340.0            # 右侧角标预留宽度
const GAP := 12.0
const QUEUE_MAX := 12             # 待播队列上限（防爆刷）
const BADGE_REFRESH := 0.5        # 角标刷新间隔（秒）

## 世界叙事关键词（命中即播报）
const NEWS_KEYS := ["边境", "军情", "局部冲突", "战事", "倒戈", "采购团", "军需", "阵营", "战争"]

const IDLE_TEXT := "—— 边境暂无新消息 ——"

var _line: Label
var _badge: Label
var _queue: Array = []            # [{text, kind}]
var _cur: Dictionary = {}
var _x := 0.0
var _badge_t := 99.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = BAR_H
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_line = EconTheme.label(IDLE_TEXT, EconTheme.DIM, 13)
	_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_line)
	_badge = EconTheme.label("", EconTheme.ACCENT, 13)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_badge.clip_text = true
	add_child(_badge)
	resized.connect(queue_redraw)
	Economy.event_posted.connect(_on_event)
	_refresh_badge()


func _draw() -> void:
	# 半透明底 + 底部一条 Photon 细线（与窗口风格统一, 但更淡以免挡视线）
	draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, BAR_H)), Color(0.02, 0.03, 0.035, 0.72))
	draw_line(Vector2(0.0, BAR_H - 1.0), Vector2(size.x, BAR_H - 1.0),
		Color(EconTheme.ACCENT.r, EconTheme.ACCENT.g, EconTheme.ACCENT.b, 0.45), 1.0)


func _on_event(text: String, kind: String) -> void:
	if not _is_news(text):
		return
	_queue.append({"text": text, "kind": kind})
	if _queue.size() > QUEUE_MAX:
		_queue.pop_front()
	if _cur.is_empty():
		_next()


## 世界叙事关键词白名单（非叙事文本: 成交/入库/操作报错 一律不进新闻条）
func _is_news(text: String) -> bool:
	for k in NEWS_KEYS:
		if text.find(String(k)) >= 0:
			return true
	return false


func _next() -> void:
	if _queue.is_empty():
		_cur = {}
		_line.text = IDLE_TEXT
		_line.add_theme_color_override("font_color", EconTheme.DIM)
		return
	_cur = _queue.pop_front()
	_line.text = String(_cur["text"])
	_line.add_theme_color_override("font_color", _kind_color(String(_cur["kind"])))
	_x = maxf(_scroll_w(), 60.0)


func _kind_color(kind: String) -> Color:
	match kind:
		"good":
			return EconTheme.GOOD
		"rare":
			return EconTheme.RARE
		"warn":
			return EconTheme.WARN
	return EconTheme.TEXT


func _scroll_w() -> float:
	return maxf(size.x - BADGE_W - GAP * 2.0, 60.0)


func _process(delta: float) -> void:
	_badge_t += delta
	if _badge_t >= BADGE_REFRESH:
		_badge_t = 0.0
		_refresh_badge()
	# 角标: 右侧固定宽度, 右对齐
	_badge.position = Vector2(maxf(size.x - BADGE_W - 8.0, 0.0), (BAR_H - 18.0) * 0.5)
	_badge.size = Vector2(minf(BADGE_W, maxf(size.x - 16.0, 40.0)), BAR_H)
	if _cur.is_empty():
		_line.position = Vector2(GAP, (BAR_H - 18.0) * 0.5)
		_line.size = Vector2(_scroll_w(), BAR_H)
		return
	# 滚动: 文字整体左移, 完全滑出后再取下一条（队列空则回到 IDLE 常驻提示）
	_x -= SCROLL_SPEED * delta
	if _x < -_line.get_minimum_size().x - GAP:
		_next()
		return
	_line.position = Vector2(_x, (BAR_H - 18.0) * 0.5)
	_line.size = Vector2(maxf(_line.get_minimum_size().x, 1.0), BAR_H)


## 角标 = 相位 · 阵营 · 相位倒计时 · 物资 · 盟友 · 采购团在港
func _refresh_badge() -> void:
	var phase_i: int = int(WorldState.phase)
	var col := EconTheme.DIM
	if phase_i == 1:
		col = EconTheme.WARN
	elif phase_i == 2:
		col = EconTheme.BAD
	_badge.add_theme_color_override("font_color", col)
	var left: int = WorldState.days_left_in_phase()
	var sp: float = WorldState.stockpile
	var tgt: float = float(GameData.WORLD["stockpile_target"])
	var allies: int = WorldState.ally_count(WorldState.current_faction)
	var total: int = GameData.MINOR_FACTIONS.size()
	if size.x < 1020.0:
		_badge.text = "【%s·%s】剩 %d 天 · %.0f/%.0f" % [
			WorldState.phase_name(), WorldState.faction_display_name(), left, sp, tgt]
	else:
		_badge.text = "【%s · %s】剩 %d 天 · 物资 %.0f/%.0f · 盟友 %d/%d%s" % [
			WorldState.phase_name(), WorldState.faction_display_name(), left, sp, tgt,
			allies, total, " · 采购团在港" if WorldState.dealer != null else ""]
