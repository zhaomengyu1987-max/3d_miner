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
	_test_minor_defection()
	_test_sector_graph()
	_test_minor_friction()
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


func _test_minor_defection() -> void:
	print("[minor defection (M2)]")
	WorldState.debug_reset()
	_check(WorldState.ally_count("empire") == 5, "初始5:5分配(empire=%d)" % WorldState.ally_count("empire"))
	_check(WorldState.ally_count("southern") == 5, "初始5:5分配(southern=%d)" % WorldState.ally_count("southern"))
	_check(absf(WorldState._ally_mult("empire") - 1.0) < 0.0001, "5:5基线下盟友系数=1.0")
	# 多轮"进入筹备期"制造足够的独立判定次数，统计意义上几乎必然至少倒戈一次
	# （10国 × 0.12概率 × 20轮 ≈ 期望24次判定命中，近乎确定性）。
	var changed := false
	for cycle in 20:
		var cycle_len := WorldState._cycle_len()
		Economy.day = cycle * cycle_len + 1  # 先落回和平期
		Economy.day_changed.emit(Economy.day)
		Economy.day = cycle * cycle_len + 1 + int(GameData.WORLD["peace_days"])  # 再跳进筹备期第一天
		Economy.day_changed.emit(Economy.day)
		if WorldState.ally_count("empire") != 5:
			changed = true
	_check(changed, "20轮筹备期后至少发生过一次倒戈（概率性校验）")
	_check(WorldState.ally_count("empire") + WorldState.ally_count("southern") == 10,
		"阵营总数守恒=10(empire=%d, southern=%d)" % [WorldState.ally_count("empire"), WorldState.ally_count("southern")])
	# 盟友系数：人为把全部10国压到一边，验证供需两处都会跟着放大/收缩
	for fid in GameData.MINOR_FACTIONS:
		WorldState._minor_bloc[fid] = "empire"
	_check(WorldState.ally_count("empire") == 10, "人为全压empire后ally_count=10")
	var mult_all_in: float = WorldState._ally_mult("empire")
	_check(mult_all_in > 1.0, "盟友全倒向empire时系数>1.0(%.3f)" % mult_all_in)
	var eff_all_in := WorldState.supply_efficiency("empire")
	for fid in GameData.MINOR_FACTIONS:
		WorldState._minor_bloc[fid] = "southern"
	var eff_isolated := WorldState.supply_efficiency("empire")
	_check(eff_all_in > eff_isolated, "盟友多时补给效率(%.4f) > 盟友全失时(%.4f)" % [eff_all_in, eff_isolated])
	WorldState.debug_reset()


func _test_sector_graph() -> void:
	print("[sector graph (M3)]")
	_check(WorldState.sector_hops("buffer_center", "buffer_center") == 0, "同sector跳数=0")
	_check(WorldState.sector_hops("buffer_center", "empire_core") == 3,
		"玩家→帝国核心=3跳(实际%d)" % WorldState.sector_hops("buffer_center", "empire_core"))
	_check(WorldState.sector_hops("buffer_center", "southern_core") == 3,
		"玩家→南联核心=3跳(实际%d)" % WorldState.sector_hops("buffer_center", "southern_core"))
	_check(WorldState.sector_hops("buffer_center", "pirate_zone") == 1, "玩家→海盗开拓地=1跳(环绕站点)")
	_check(WorldState.sector_hops("empire_core", "southern_core") == 6,
		"帝国核心→南联核心=6跳(满链长度, 实际%d)" % WorldState.sector_hops("empire_core", "southern_core"))
	# 对称性：玩家正好卡在两大国正中间，5:5基线下两边补给效率应该相等
	WorldState.debug_reset()
	var eff_empire := WorldState.supply_efficiency("empire")
	var eff_southern := WorldState.supply_efficiency("southern")
	_check(absf(eff_empire - eff_southern) < 0.0001,
		"5:5基线+对称跳数下，两大国补给效率相等(%.4f vs %.4f)" % [eff_empire, eff_southern])
	var expected: float = 1.0 / (1.0 + 3.0 * float(GameData.WORLD["supply_decay_per_hop"]))
	_check(absf(eff_empire - expected) < 0.0001,
		"3跳衰减公式数值核对(期望%.4f, 实际%.4f)" % [expected, eff_empire])


func _test_minor_friction() -> void:
	print("[minor friction (M3)]")
	WorldState.debug_reset()
	# buffer_center 下默认挂靠 国4(empire)/国9(southern)——天然就是一对可摩擦的混居小国
	var fids_in_center: Array = []
	for fid in GameData.MINOR_FACTIONS:
		if String(GameData.MINOR_FACTIONS[fid]["home_sector"]) == "buffer_center":
			fids_in_center.append(fid)
	_check(fids_in_center.size() == 2, "buffer_center 默认挂靠2个小国(国4/国9)")
	var blocs: Array = []
	for fid in fids_in_center:
		blocs.append(String(WorldState._minor_bloc.get(fid, "")))
	_check(blocs.size() == 2 and blocs[0] != blocs[1], "buffer_center 的2个小国初始归属不同，天然可摩擦")
	# 多轮调用确保函数本身不报错（纯叙事，不断言具体事件文本，只验证不崩）
	for i in 30:
		WorldState._roll_minor_friction()
	_check(true, "连续调用30次_roll_minor_friction()无崩溃")
	WorldState.debug_reset()


func _cleanup() -> void:
	if FileAccess.file_exists(Economy.save_path):
		DirAccess.remove_absolute(Economy.save_path)
	WorldState.debug_reset()
