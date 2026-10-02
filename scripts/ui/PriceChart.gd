class_name PriceChart
extends Control

## 市场日交易量柱状图（自绘 _draw——零子节点）：
## 每天一根柱（Photon 青蓝半透明+顶亮线），柱高=当日成交量；顶注峰值量。

var goods := ""
var _vols: Array = []      # [{d, q}] 按日聚合
var _max_q := 0


func setup(p_goods: String) -> void:
	goods = p_goods
	_rebuild_data()
	queue_redraw()


func _rebuild_data() -> void:
	var by_day := {}
	var first_d := -1
	for e in Economy.trade_log:
		if String(e["g"]) != goods:
			continue
		var d := int(e["d"])
		by_day[d] = int(by_day.get(d, 0)) + int(e["q"])
		if first_d < 0 or d < first_d:
			first_d = d
	_vols.clear()
	_max_q = 0
	if first_d >= 0:
		# 时间轴不偷懒(2026-10-02 拍板): 首交易日→今天 连续每天一柱, 无交易=0 矮柱
		var from_d := maxi(first_d, Economy.day - 60)  # 上限 60 柱防柱宽<1px
		for d in range(from_d, Economy.day + 1):
			var q: int = int(by_day.get(d, 0))
			_vols.append({"d": d, "q": q})
			_max_q = maxi(_max_q, q)


func _process(_delta: float) -> void:
	var n := 0
	for e in Economy.trade_log:
		if String(e["g"]) == goods:
			n += 1
	if n != _vols.size() or (n > 0 and _dirty_check != n):
		_dirty_check = n
		_rebuild_data()
		queue_redraw()


var _dirty_check := -1


func _draw() -> void:
	var sz := size
	if sz.x < 30 or sz.y < 20:
		return
	draw_rect(Rect2(Vector2.ZERO, sz), Color(0.04, 0.05, 0.045, 0.9))
	var grid := Color(1, 1, 1, 0.05)
	for i in 3:
		var y := sz.y * i / 2.0
		draw_line(Vector2(0, y), Vector2(sz.x, y), grid, 1.0)
	if _vols.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(8, sz.y * 0.55),
			"该货物暂无成交", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, EconTheme.DIM)
		return
	var col := Color("58A7BF")
	var fill := Color(0.35, 0.65, 0.75, 0.35)
	var top_h := 12.0            # 顶部标注带
	var chart_h: float = sz.y - top_h - 3.0
	var n := _vols.size()
	var bw: float = maxf(sz.x / float(maxi(n, 1)) - 3.0, 2.0)
	for i in n:
		var v: int = int(_vols[i]["q"])
		var h: float = maxf(chart_h * float(v) / maxf(float(_max_q), 1.0), 2.0)  # 0 量=2px 矮柱
		var x: float = 2.0 + (sz.x - 4.0) * float(i) / float(maxi(n, 1))
		var rect := Rect2(x, top_h + chart_h - h, bw, maxf(h, 1.0))
		draw_rect(rect, fill)
		draw_rect(rect, Color(col, 0.9), false, 1.0)  # 顶/边亮线
	draw_string(ThemeDB.fallback_font, Vector2(4, 10), "峰值 %d/日" % _max_q,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
	draw_string(ThemeDB.fallback_font, Vector2(sz.x - 60, 10), "%d 日" % n,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, EconTheme.DIM)
