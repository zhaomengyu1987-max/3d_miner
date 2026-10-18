extends Node3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 采矿无人机端到端测试（headless）：
## godot --headless --path . res://tests/drone_mining_test.tscn
## 最小 3D 环境(MiningHub+BeltFlow) → 建无人机(普矿A) → 强制完工 →
## 无人机自动抓 S 档矿拖回站体 → 入库 → DRONE_TEST_PASS / DRONE_TEST_FAIL。
## 存档重定向到 user://drone_test_save.json，不触碰真实存档。

var _fails: Array[String] = []


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)
		print("  [FAIL] ", what)


func _ready() -> void:
	# Beam billboards need a finite camera position even in headless tests.
	var camera := Camera3D.new()
	camera.position = Vector3(40, 30, 40) * U
	camera.near = 0.05 * U
	camera.far = 4000.0 * U
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	await get_tree().process_frame  # Economy 的 deferred 世界/UI 挂载
	Economy.debug_instant = true
	Economy.save_path = "user://drone_test_save.json"
	Economy.debug_reset()  # 真实存档里可能有模块/作业, 测试须从全新开局开始

	# ---- 最小 3D 环境 ----
	var hub := Node3D.new()
	hub.name = "MiningHub"
	add_child(hub)
	var belt := (load("res://sences/BeltFlow.tscn") as PackedScene).instantiate()
	belt.target_count = 40
	belt.spawn_center = Vector3(-25, 0, 0) * U
	belt.spawn_size = Vector3(4, 6, 8) * U
	belt.despawn_center = Vector3(25, 0, 0) * U
	belt.despawn_size = Vector3(4, 6, 8) * U
	belt.station_clear_radius = 2.0 * U
	add_child(belt)

	# ---- 建造（建造界面直接解锁，只卡材料）----
	Economy.inv.clear()
	Economy.inv["commonA"] = 2000
	Economy.inv["commonB"] = 500
	_check(Economy.module_build_block("drone") == "", "无人机可建造(普矿A 200)")
	_check(Economy.build_module("drone") == "", "建造提交")
	# 计时推进检查: debug_instant 下 90s 作业压到 0.9s, 2.5s 真实时间内应自然完工
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2500 and Economy.module_jobs.has("drone"):
		await get_tree().process_frame
	_check(not Economy.module_jobs.has("drone"), "建造计时自动推进(未强制完工)")
	_check(Economy.module_count("drone") == 1, "无人机建成免激活")
	_check(Economy._world != null and Economy._world._drones.size() == 1, "无人机实体生成")

	_check(Economy.module_build_block("corvette") == "", "护卫舰可建造(普矿A500+普矿B100)")
	_check(Economy.build_module("corvette") == "", "护卫舰建造提交")
	Economy.module_jobs["corvette"]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.module_count("corvette") == 1, "护卫舰建成免激活")
	_check(Economy._world != null and Economy._world._corvettes.size() == 1, "护卫舰实体生成")
	Economy.inv.clear()  # 清空库存, 只等自动矿机挖到的矿入账

	# ---- 等自动挖矿入库（真实时间上限 45s；debug_instant 下单周期应 < 3s）----
	# 无人机: 拖 1 颗 S 矿(100 单位)入库; 护卫舰: 采满 1 颗 M 矿(500 单位)回站卸货
	var deadline := Time.get_ticks_msec() + 45000
	var total := 0
	var corv_delivered := 0
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		total = 0
		for id in Economy.inv:
			total += int(Economy.inv[id])
		if Economy._world != null and Economy._world._corvettes.size() > 0:
			corv_delivered = Economy._world._corvettes[0].delivered_total
		if total > 0 and corv_delivered >= 500:
			break
	_check(total > 0, "无人机挖到矿入库 (库存=%d)" % total)
	_check(corv_delivered >= 500, "护卫舰激光采矿卸货 ≥500 (实际 %d)" % corv_delivered)

	if FileAccess.file_exists(Economy.save_path):
		DirAccess.remove_absolute(Economy.save_path)
	if _fails.is_empty():
		print("DRONE_TEST_PASS")
		get_tree().quit(0)
	else:
		print("DRONE_TEST_FAIL (%d)" % _fails.size())
		get_tree().quit(1)
