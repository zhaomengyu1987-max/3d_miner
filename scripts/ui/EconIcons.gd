class_name EconIcons
extends RefCounted

## 手绘像素图标（字符画 → ImageTexture，黑底 + 像素线稿风，2026-10-02）。
##
## 【为什么把图写在代码里】空间站悬浮窗的"市场交易"按钮原来引用
## `res://assets/icons/market_logo.svg`，而该文件**从未存在**（目录里只有
## ore/ice/ship/license/market/truss.svg）⇒ `load()` 返回 null ⇒ `Button.icon = null`
## ⇒ 按钮一片空白（用户报"看不到 Icon"）。字符画方案：
##   ① 不依赖导入管线（未导入的 PNG/SVG 在 release 包里同样是 null）；
##   ② 可以 headless 断言"图标非空、有线条像素"；
##   ③ 天然是"像素画线"风格，无需任何图像生成工具。
##
## 字符画约定（16×16 手工稿）：
##   '.' = 透明（保留黑底）   '#' = 边框线（Photon focus_dark 暗青）
##   '*' = 主线条（Photon focus 青蓝 #58A7BF）
## 放大一律用整倍 nearest（默认 ×3 = 48×48），保证像素不糊。

const _BG := Color(0, 0, 0, 1.0)              # 黑底
const _FRAME := Color(0.188, 0.337, 0.396)    # #305665
const _INK := Color("58A7BF")                 # Photon focus 青蓝

## 市场交易 = 双向箭头（买卖交换）
const _MARKET := [
	"################",
	"#..............#",
	"#..............#",
	"#.........*....#",
	"#..........*...#",
	"#.**********...#",
	"#..........*...#",
	"#.........*....#",
	"#.....*........#",
	"#....*.........#",
	"#...**********.#",
	"#....*.........#",
	"#.....*........#",
	"#..............#",
	"#..............#",
	"################",
]

## 建造厂 · 商品制造 = 齿轮（八边环 + 四向齿, 生产/制造语义）
const _FACTORY := [
	"################",
	"#..............#",
	"#......**......#",
	"#.....****.....#",
	"#....**..**....#",
	"#...**....**...#",
	"#...*......*...#",
	"#.***......***.#",
	"#.***......***.#",
	"#...*......*...#",
	"#...**....**...#",
	"#....**..**....#",
	"#.....****.....#",
	"#......**......#",
	"#..............#",
	"################",
]

static var _cache: Dictionary = {}
static var _png_cache: Dictionary = {}


## M2: 通用模块图标——PNG 优先, 字符画回退(仅 market/factory 有字符画)
static func module_icon(module_id: String) -> Texture2D:
	match module_id:
		"market":
			return market_logo()
		"factory":
			return factory_logo()
	var png := png_icon(module_id)
	if png != null:
		return png
	return null   # 无 PNG 也无字符画的模块返回 null(面板自行处理)


## M2: 从 assets/ui/icons/ 加载 PNG 图标(48×48, EVE 渲染风)
## 找不到文件时回退到字符画版(不返回 null)
static func png_icon(module_id: String) -> Texture2D:
	if _png_cache.has(module_id) and _png_cache[module_id] != null:
		return _png_cache[module_id]
	var path := "res://assets/ui/icons/icon_%s.png" % module_id
	if not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	if tex != null:
		_png_cache[module_id] = tex
	return tex


## 市场交易 logo（黑底 + 双向箭头）。scale = 整数放大倍率（1 = 16×16 原始像素）
static func market_logo(scale := 3) -> Texture2D:
	var png := png_icon("market")
	if png != null:
		return png
	return _make("market", _MARKET, scale)


## 建造厂 · 商品制造 logo（黑底 + 齿轮）
static func factory_logo(scale := 3) -> Texture2D:
	var png := png_icon("factory")
	if png != null:
		return png
	return _make("factory", _FACTORY, scale)


## 字符画 → ImageTexture（同 key+scale 走缓存，避免每次开窗重建贴图）
static func _make(key: String, rows: Array, scale: int) -> Texture2D:
	var ck := "%s@%d" % [key, scale]
	if _cache.has(ck) and _cache[ck] != null:
		return _cache[ck]
	var h := rows.size()
	var w := String(rows[0]).length()
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(_BG)   # 黑底（用户要的黑底像素画线）
	for y in h:
		var line := String(rows[y])
		for x in mini(w, line.length()):
			match line[x]:
				"#":
					img.set_pixel(x, y, _FRAME)
				"*":
					img.set_pixel(x, y, _INK)
	if scale > 1:
		img.resize(w * scale, h * scale, Image.INTERPOLATE_NEAREST)
	var tex := ImageTexture.create_from_image(img)
	_cache[ck] = tex
	return tex
