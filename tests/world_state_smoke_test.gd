extends Node

## 世界系统 M1 冒烟测试（headless）：
## godot --headless --path . res://tests/world_state_smoke_test.tscn
## 输出 WORLDSTATE_TEST_PASS / WORLDSTATE_TEST_FAIL。
## 存档重定向到 user://economy_test_save.json，不触碰真实存档；
## WorldState 自己的 user://world_state_save.json 由 debug_reset() 清理。

var _fails: Array[String] = []


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)
		print("  [FAIL] ", what)


func _ready() -> void:
	await get_tree().process_frame  # 等 Economy 的 deferred 世界/UI 挂载完成
	Economy.debug_instant = true
	Economy.save_path = "user://economy_test_save.json"
	Economy.debug_reset()
	WorldState.debug_reset()
	_test_phase_math()
	_test_background_accrual()
	_test_player_contribution()
	_test_dealer_lifecycle()
	_test_frequency_mult()
	_test_war_transition_and_burn()
	_cleanup()
	if _fails.is_empty():
		print("WORLDSTATE_TEST_PASS")
		get_tree().quit(0)
	else:
		print("WORLDSTATE_TEST_FAIL (%d)" % _fails.size())
		get_tree().quit(1)


func _test_phase_math() -> void:
	print("[phase math]")
	var peace_d: int = int(GameData.WORLD["peace_days"])
	var buildup_d: int = int(GameData.WORLD["buildup_days"])
	var war_d: int = int(GameData.WORLD["war_days"])
	_check(WorldState._phase_for_day(1) == WorldState.Phase.PEACE, "day1 = 和平期")
	_check(WorldState._phase_for_day(peace_d) == WorldState.Phase.PEACE, "day%d(和平最后一天) 仍是和平期" % peace_d)
	_check(WorldState._phase_for_day(peace_d + 1) == WorldState.Phase.BUILDUP, "day%d = 筹备期第一天" % (peace_d + 1))
	_check(WorldState._phase_for_day(peace_d + buildup_d) == WorldState.Phase.BUILDUP, "筹备期最后一天仍是筹备期")
	_check(WorldState._phase_for_day(peace_d + buildup_d + 1) == WorldState.Phase.WAR, "开战期第一天")
	_check(WorldState._phase_for_day(peace_d + buildup_d + war_d) == WorldState.Phase.WAR, "开战期最后一天")
	_check(WorldState._phase_for_day(peace_d + buildup_d + war_d + 1) == WorldState.Phase.PEACE, "下一轮循环回到和平期")


func _test_background_accrual() -> void:
	print("[background accrual]")
	Economy.day = int(GameData.WORLD["peace_days"]) + 1  # 筹备期第一天
	WorldState.stockpile = 0.0
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.phase == WorldState.Phase.BUILDUP, "进入筹备期")
	_check(WorldState.stockpile > 0.0, "筹备期第一天已有背景积累(%.4f)" % WorldState.stockpile)
	var after_one_day := WorldState.stockpile
	Economy.day += 1
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.stockpile > after_one_day, "第二天继续累积(%.4f → %.4f)" % [after_one_day, WorldState.stockpile])


func _test_player_contribution() -> void:
	print("[player contribution]")
	_check(WorldState.phase == WorldState.Phase.BUILDUP, "仍在筹备期（沿用上一测试的时钟）")
	var before := WorldState.stockpile
	Economy.military_goods_sold.emit("heavyArms", 10, 1500.0)
	_check(WorldState.stockpile > before, "军需品成交反哺物资积累(%.4f → %.4f)" % [before, WorldState.stockpile])
	# 开战期不应再被玩家交易影响（M1 拍板：战争节奏先走固定时长，反哺只在筹备期生效）
	Economy.day = int(GameData.WORLD["peace_days"]) + int(GameData.WORLD["buildup_days"]) + 1
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.phase == WorldState.Phase.WAR, "进入开战期")
	var war_stock := WorldState.stockpile
	Economy.military_goods_sold.emit("heavyArms", 999, 999999.0)
	_check(absf(WorldState.stockpile - war_stock) < 0.0001, "开战期玩家交易不改变物资积累")


func _test_dealer_lifecycle() -> void:
	print("[dealer lifecycle]")
	Economy.berths.clear()
	Economy.modules["hangar"]["level"] = 2
	Economy.modules["hangar"]["built"] = true
	Economy.day = int(GameData.WORLD["peace_days"]) + 1  # 回到筹备期第一天，单独测 dealer
	WorldState.stockpile = 0.0
	WorldState.war_initial_stockpile = 0.0
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.dealer != null, "筹备期生成采购代理")
	if WorldState.dealer == null:
		return
	_check(Economy.berths.has(WorldState.dealer), "采购代理占用一个正常泊位（2026-10-02 拍板：占位）")
	var expected_entries: int = GameData.MILITARY.size() * int(GameData.WORLD["dealer_tiers"])
	_check(WorldState.dealer.buy_offers.size() == expected_entries,
		"阶梯买单条数 = 军需品种类 × 档位数（期望 %d, 实际 %d）" % [expected_entries, WorldState.dealer.buy_offers.size()])
	var smallarms_tiers := 0
	for o in WorldState.dealer.buy_offers:
		if String(o["goods"]) == "smallArms":
			smallarms_tiers += 1
	_check(smallarms_tiers == int(GameData.WORLD["dealer_tiers"]), "smallArms 恰好挂了 %d 档买单" % int(GameData.WORLD["dealer_tiers"]))


func _test_frequency_mult() -> void:
	print("[frequency mult]")
	Economy.day = 1
	Economy.day_changed.emit(1)
	_check(absf(WorldState.freighter_frequency_mult() - float(GameData.WORLD["freighter_mult_peace"])) < 0.001,
		"和平期频率乘数 = 基线")
	Economy.day = int(GameData.WORLD["peace_days"]) + 1
	Economy.day_changed.emit(Economy.day)
	var lo := WorldState.freighter_frequency_mult()
	_check(absf(lo - float(GameData.WORLD["freighter_mult_buildup_lo"])) < 0.05, "筹备期第一天频率乘数≈低值(%.3f)" % lo)
	Economy.day = int(GameData.WORLD["peace_days"]) + int(GameData.WORLD["buildup_days"])
	Economy.day_changed.emit(Economy.day)
	var hi := WorldState.freighter_frequency_mult()
	_check(hi > lo, "筹备期末尾频率乘数高于开头(%.2f > %.2f)" % [hi, lo])
	Economy.day = int(GameData.WORLD["peace_days"]) + int(GameData.WORLD["buildup_days"]) + 1
	Economy.day_changed.emit(Economy.day)
	_check(absf(WorldState.freighter_frequency_mult() - float(GameData.WORLD["freighter_mult_war"])) < 0.001,
		"开战期频率乘数 = 战时值")


func _test_war_transition_and_burn() -> void:
	print("[war transition & burn]")
	Economy.berths.clear()
	WorldState._despawn_dealer("")
	Economy.day = int(GameData.WORLD["peace_days"]) + 1
	WorldState.stockpile = 0.0
	WorldState.war_initial_stockpile = 0.0
	Economy.day_changed.emit(Economy.day)
	for i in 5:
		Economy.day += 1
		Economy.day_changed.emit(Economy.day)
	var pre_war_stock := WorldState.stockpile
	_check(pre_war_stock > 0.0, "筹备若干天后已有积累(%.3f)" % pre_war_stock)
	Economy.day = int(GameData.WORLD["peace_days"]) + int(GameData.WORLD["buildup_days"]) + 1
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.phase == WorldState.Phase.WAR, "进入开战期")
	_check(absf(WorldState.war_initial_stockpile - pre_war_stock) < 0.001,
		"开战瞬间快照 = 筹备期当时积累(%.3f vs %.3f)" % [WorldState.war_initial_stockpile, pre_war_stock])
	var day1_war_stock := WorldState.stockpile
	_check(day1_war_stock < WorldState.war_initial_stockpile, "开战第一天已经开始消耗")
	for i in int(GameData.WORLD["war_days"]) - 1:
		Economy.day += 1
		Economy.day_changed.emit(Economy.day)
	_check(WorldState.stockpile <= 0.0001, "开战期打满应该接近耗尽(%.4f)" % WorldState.stockpile)
	Economy.day += 1
	Economy.day_changed.emit(Economy.day)
	_check(WorldState.phase == WorldState.Phase.PEACE, "战争结束回到和平期")
	_check(WorldState.dealer == null, "和平期采购代理已撤离")


func _cleanup() -> void:
	if FileAccess.file_exists(Economy.save_path):
		DirAccess.remove_absolute(Economy.save_path)
	WorldState.debug_reset()
