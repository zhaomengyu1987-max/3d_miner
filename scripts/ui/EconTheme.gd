class_name EconTheme
extends RefCounted

## 制造系统 UI 主题与控件工厂（代码构建，深色科幻风，与 SettingsPanel 同套路）。

# —— EVE 国服实拍采样色板（2026-10-01, 像素取样自市场窗口）——
const BG := Color(0.04, 0.045, 0.04, 0.55)     # 全屏遮罩（EVE 后台仅微暗, 不全黑）
const PANEL := Color(0.075, 0.078, 0.067, 0.97)   # 窗体底 #131411 暖黑
const PANEL2 := Color(0.078, 0.106, 0.094, 1.0)   # 行/卡片底 #141b18 微绿
const BORDER := Color(0.17, 0.17, 0.16, 1.0)      # 边框 #2b2b28 极淡 1px
# EVE Photon 官方主题（colorThemes.py:77 源码）: focus/accent=#58A7BF focus_dark=#305665 alert=#F39058 tint=#060a0c
const ACCENT := Color("58A7BF")          # Photon focus 青蓝
const TEXT := Color(0.88, 0.93, 1.0)
const DIM := Color(0.52, 0.60, 0.72)
const GOOD := Color(0.45, 0.90, 0.55)
const WARN := Color("F39058")            # Photon alert 橙
const BAD := Color(1.0, 0.42, 0.40)
const RARE := Color(0.80, 0.60, 1.0)
const FUELC := Color(0.55, 0.85, 1.0)


static func style_box(bg: Color, border := BORDER, radius := 4, bw := 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


static func label(text: String, col := TEXT, size := 14) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	return l


static func title(text: String, size := 20) -> Label:
	var l := label(text, ACCENT, size)
	return l


static func button(text: String, cb := Callable(), min_size := Vector2(0, 30)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ACCENT)
	b.add_theme_color_override("font_disabled_color", DIM)
	b.add_theme_stylebox_override("normal", style_box(PANEL2))
	b.add_theme_stylebox_override("hover", style_box(PANEL2.lightened(0.08), ACCENT))
	b.add_theme_stylebox_override("pressed", style_box(PANEL2.darkened(0.1), ACCENT))
	b.add_theme_stylebox_override("disabled", style_box(PANEL2.darkened(0.2), BORDER.darkened(0.3)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func rich(bb: String, size := 13) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.add_theme_color_override("default_color", TEXT)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	return r


static func vbox(sep := 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func hsep(h := 8) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


static func card() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style_box(PANEL2, BORDER, 6))
	return p


static func progress() -> ProgressBar:
	var pb := ProgressBar.new()
	pb.custom_minimum_size = Vector2(0, 14)
	pb.show_percentage = false
	pb.add_theme_stylebox_override("background", style_box(PANEL.darkened(0.2), BORDER.darkened(0.3), 3))
	pb.add_theme_stylebox_override("fill", style_box(ACCENT.darkened(0.4), ACCENT, 3))
	return pb


static func money(v: float) -> String:
	return "₡" + comma(v)


## 订单簿行：列序按 EVE 原版 = 数量 → 价格 → 来源 → 剩余
## （marketbase.py:3071-3084 收购簿 = 数量/价格/过期时间；:3087-3099 出售簿 = 数量/价格/最小成交量/过期时间）
## 仍走 ItemList 单行文本 + 定宽补空格（性能 SOP：禁止"每行一组 Control"）
static func order_line(qty: String, price: String, src: String, left := "") -> String:
	var s := "%s%s%s" % [qty.rpad(12), price.rpad(14), src]
	if left != "":
		s += "   " + left
	return s


## 订单簿列头（EVE 列表是带 headers 的: marketbase.py:3054-3055，行高 18）
static func order_header() -> String:
	return order_line("数量", "价格", "来源", "剩余")


static func comma(v: float) -> String:
	var n := int(round(v))
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## BOM 富文本：有料绿 / 缺料红；batches>1 时按倍数显示
static func bom_rich(bom: Dictionary, mult := 1) -> String:
	var parts: Array[String] = []
	for id in bom:
		var need := int(bom[id]) * mult
		var have := Economy.stock(id)
		var col := "#73e68d" if have >= need else "#ff6b6b"
		var missing := ""
		if GameData.is_ore(id) and GameData.ORES[id]["path"] == "":
			col = "#c06bff"
			missing = "（待模型）"
		parts.append("[color=%s]%s %d%s[/color]" % [col, GameData.good_name(id), need, missing])
	return " · ".join(parts)


static func fmt_time(sec: float) -> String:
	if sec < 60.0:
		return "%d秒" % int(ceilf(sec))
	return "%d分%02d秒" % [int(sec) / 60, int(sec) % 60]
