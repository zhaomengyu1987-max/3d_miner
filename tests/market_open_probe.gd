extends Node

## 市场面板打开探针（headless）：复现"点不开"，打印每步状态与报错。

func _ready() -> void:
	await get_tree().process_frame
	var ui = get_tree().get_first_node_in_group("econ_ui")
	print("ui=", ui)
	if ui == null:
		print("PROBE_FAIL: no ui")
		get_tree().quit(1)
		return
	print("panels=", ui._panels.keys())
	print("has market=", ui._panels.has("market"))
	ui.open_panel("market")
	await get_tree().process_frame
	var mp = ui._panels.get("market")
	if mp == null:
		print("PROBE_FAIL: market panel missing")
		get_tree().quit(1)
		return
	print("market visible=", mp.visible)
	print("body children=", mp.body.get_child_count())
	print("modal_open=", EconUiRoot.modal_open)
	await get_tree().process_frame
	await get_tree().process_frame
	print("vp=", mp.get_viewport_rect().size)
	print("panel pos=", mp._panel.position, " size=", mp._panel.size, " min=", mp._panel.custom_minimum_size)
	print("user_moved=", mp._user_moved, " collapsed=", mp._collapsed)
	# 防复发断言(2026-10-02): 切遍全部品类, 面板 min 宽必须恒定
	var widths := []
	var samples := ["commonA", "truss", "smallArms", "longbow", "lic:smallArms"]
	var mkt = ui._panels.get("market")
	mkt.open()
	await get_tree().process_frame
	for gid in samples:
		mkt._sel_goods = gid
		mkt._refresh_right()
		await get_tree().process_frame
		await get_tree().process_frame
		widths.append(int(mkt._panel.get_combined_minimum_size().x))
	print("WIDTHS=", widths, " 恒定=", widths.all(func(w): return w == widths[0]))
	if not widths.all(func(w): return w == widths[0]):
		print("WIDTH_MISMATCH_FAIL")
		get_tree().quit(1)
		return
	print("PROBE_DONE")
	get_tree().quit(0)
