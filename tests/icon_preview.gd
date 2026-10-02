extends Node3D

## 图标样张预览：把 assets/icons 的 SVG 以 16/32/64 三档显示, 配窗口截图验货。

func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 10)
	cam.make_current()

	var canvas := CanvasLayer.new()
	add_child(canvas)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var names := ["ore", "ice", "ship", "license", "market", "truss"]
	var grid := GridContainer.new()
	grid.columns = 6
	grid.position = Vector2(30, 60)
	root.add_child(grid)
	for n in names:
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(90, 0)
		grid.add_child(col)
		for sz: int in [16, 32, 64]:
			var tr := TextureRect.new()
			tr.texture = load("res://assets/icons/%s.svg" % n)
			tr.custom_minimum_size = Vector2(sz, sz)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			col.add_child(tr)
	var title := Label.new()
	title.text = "SVG 图标样张 · 上=16 中=32 下=64 · Photon 线条风"
	title.position = Vector2(30, 20)
	title.add_theme_color_override("font_color", Color(0.6, 0.9, 1))
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)
