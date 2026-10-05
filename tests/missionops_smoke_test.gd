extends Node

## MissionOps M1 冒烟测试(蓝图 §13.5 + 审查修复验证)。
## 运行: godot --headless --path . res://tests/missionops_smoke_test.tscn
## 全过 → quit(0); 任一失败 → quit(1)。
## 时间旅行: 通过 MissionOps.now_override_sec 注入, 不 sleep。
## 注: 测试开头 reset_state() 保证确定性; user://save.json 跨运行持久。

var _fails: int = 0


func _ready() -> void:
	await get_tree().process_frame
	_run_all()


func _check(label: String, cond: bool) -> void:
	if cond:
		print("  PASS  ", label)
	else:
		_fails += 1
		printerr("  FAIL  ", label)


func _run_all() -> void:
	print("== MissionOps M1 冒烟 ==")
	var mo := MissionOps
	mo.reset_state()                       # 测试确定性: 清掉上次运行残留
	# 模拟已建雇佣兵巢穴 Lv2(2 队容量)——生产路径是建造, 测试直接设等级
	if Economy.modules.has("hive"):
		Economy.modules["hive"]["level"] = 2
		Economy.modules["hive"]["built"] = true
	# 上轮 ⑯ 可能留下坏档+写入挂起 → 本轮先恢复可写并落一个干净基线档
	get_node("/root/GameSave").write_suspended = false
	get_node("/root/GameSave").save_now()
	var now := Time.get_unix_time_from_system()
	mo.now_override_sec = now

	# ① 环境前置: 钱包注资(测试专用, 不走生产路径)
	Economy.money = 100000.0

	# ②-0 巢穴门控: fleet_cap 读到 hive_level
	_check("巢穴门控: fleet_cap = hive_level", mo.fleet_cap() == 2)

	# ② 招募池: 非空且 ≤3
	_check("招募池非空且≤3", not mo.recruit_pool.is_empty() and mo.recruit_pool.size() <= 3)

	# ③ 雇佣: 扣押金, 舰长入册 idle
	var before_money := Economy.money
	var r: Dictionary = mo.hire_captain(mo.recruit_pool[0]["cid"])
	_check("雇佣成功", bool(r.get("ok", false)))
	var cid: String = r.get("cid", "")
	_check("押金已扣", Economy.money < before_money)
	_check("舰长入册且 idle", mo.captains.has(cid) and mo.captains[cid]["status"] == "idle")

	# ④ 建队 + 互斥
	var rt: Dictionary = mo.create_team("一队", cid)
	_check("建队成功", bool(rt.get("ok", false)))
	var tid: String = rt.get("team_id", "")
	var rdup: Dictionary = mo.create_team("二队", cid)
	_check("同舰长不可带两队", not bool(rdup.get("ok", false)))

	# ⑤ 派遣 + 编队互斥(seed 选定必胜, 保证 ⑦ 走成功路径)
	var win_seed := _find_succeeding_seed("mo_survey_ice", cid)
	_check("找到必胜 seed", win_seed >= 0)
	var rd: Dictionary = mo.dispatch(tid, "mo_survey_ice", win_seed)
	_check("派遣成功", bool(rd.get("ok", false)))
	var mid: String = rd.get("mission_id", "")
	_check("任务入途", mo.active.has(mid))
	var rbusy: Dictionary = mo.dispatch(tid, "mo_combat_skirmish")
	_check("在途编队不可再派", not bool(rbusy.get("ok", false)))

	# ⑥ 种子复现: 同 seed 同结果(直接比较概率掷骰)
	var roll_a: bool = _roll_with(mo.active[mid]["seed"])
	var roll_b: bool = _roll_with(mo.active[mid]["seed"])
	_check("种子可复现(同 seed 同结果)", roll_a == roll_b)

	# ⑦ 时间旅行到点 → 结算成功路径
	var ep_before := mo.ep()
	var money_before := Economy.money
	mo.now_override_sec = float(mo.active[mid]["ends_wall"]) + 1.0
	await get_tree().process_frame      # 等 _process 结算
	_check("任务已出途", not mo.active.has(mid))
	_check("成功结算: EP 入账", mo.ep() >= ep_before + 1)
	_check("成功结算: ₡ 入账", Economy.money > money_before)
	_check("舰长回 idle", mo.captains[cid]["status"] == "idle")
	_check("stats.done = 1", int(mo.stats["done"]) == 1)

	# ⑧ 离线幂等: 重复 catch_up 不双发
	var done_before := int(mo.stats["done"])
	mo._catch_up(mo._now() + 99999.0)
	_check("离线补算幂等(不双发)", int(mo.stats["done"]) == done_before)

	# ⑨ 失败路径: 造一个必败任务(seed 穷举找 roll≥P)
	var bad_seed := _find_failing_seed("mo_salvage_field", cid)  # M2: combat 需武器, 改用无门槛任务
	_check("找到必败 seed", bad_seed >= 0)
	if bad_seed >= 0:
		var m2: float = Economy.money            # 基准 = 派遣前余额(成功结算已入账)
		var rf: Dictionary = mo.dispatch(tid, "mo_salvage_field", bad_seed)
		_check("必败任务派遣成功(可派遣)", bool(rf.get("ok", false)))
		mo.now_override_sec = float(mo.active[rf["mission_id"]]["ends_wall"]) + 1.0
		await get_tree().process_frame
		_check("失败结算: 无 ₡ 收益", Economy.money <= m2 + 0.001)
		_check("stats.failed = 1", int(mo.stats["failed"]) == 1)

	# ⑩ 真 round-trip: 落盘 → 污染内存 → 从文件重载 → 逐字段还原
	get_node("/root/GameSave").save_now()
	var ep_snap := mo.ep()
	var caps_snap: int = mo.captains.size()
	var teams_snap: int = mo.teams.size()
	mo.exploration["ep"] = ep_snap + 77                       # 内存污染
	mo.captains["cap_fake"] = {"name": "幽灵", "tier": "normal", "spec": "combat",
		"level": 1, "exp": 0, "status": "idle"}
	get_node("/root/GameSave")._load_or_init()                # 从文件回放
	_check("round-trip: EP 还原", mo.ep() == ep_snap)
	_check("round-trip: 舰长表还原(幽灵被清除)", \
		not mo.captains.has("cap_fake") and mo.captains.size() == caps_snap)
	_check("round-trip: 编队数还原", mo.teams.size() == teams_snap)

	# ⑪ 重启补算: 派遣未来任务 → 模拟进程死亡(清内存) → 文件回放 → catch_up → 幂等
	var done0 := int(mo.stats["done"])
	var rre: Dictionary = mo.dispatch(tid, "mo_survey_ice", 424242)
	_check("重启测试: 派遣成功", bool(rre.get("ok", false)))
	var mid2: String = rre.get("mission_id", "")
	get_node("/root/GameSave").save_now()                     # 模拟重启前的自动存档心跳
	mo.active = {}                                            # 进程死亡(内存丢失)
	get_node("/root/GameSave")._load_or_init()                # 文件回放
	_check("重启回放: 在途任务还原", mo.active.has(mid2))
	# 真复现断言(审查 R3): 用回放恢复的舰长配置重算这一掷, 预测结算成败
	var mis2: Dictionary = mo.active[mid2]
	var cap2: Dictionary = mo.captains[mis2["cid"]]
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = int(mis2["seed"])
	var p2 := MissionDefs.success_probability(MissionDefs.TASKS[mis2["task_id"]], cap2)
	var expect_success := rng2.randf() < p2
	mo.now_override_sec = float(mis2["ends_wall"]) + 1.0
	mo._catch_up(mo._now())
	_check("重启补算: 到点结算", not mo.active.has(mid2) and int(mo.stats["done"]) == done0 + 1)
	_check("真复现: 重算掷骰与实际结算一致",
		mo._last_report.get("success", null) == expect_success)
	mo._catch_up(mo._now())
	_check("重启补算幂等(不双发)", int(mo.stats["done"]) == done0 + 1)

	# ⑫ 派遣到不存在任务被拒
	var rbad: Dictionary = mo.dispatch(tid, "mo_not_exist")
	_check("非法任务被拒", not bool(rbad.get("ok", false)))

	# ⑬ 容量顺序(审查 P2): 两队都在途时一键备战不得先扣押金
	# 前置: 雇第二名舰长建二队, 双队派遣在途
	var r2b: Dictionary = mo.hire_captain(mo.recruit_pool[0]["cid"])
	_check("二队舰长雇佣", bool(r2b.get("ok", false)))
	var cid2: String = r2b.get("cid", "")
	var rt2: Dictionary = mo.create_team("二队", cid2)
	_check("二队建队", bool(rt2.get("ok", false)))
	var win2 := _find_succeeding_seed("mo_survey_ice", cid2)
	var rd2: Dictionary = mo.dispatch(rt2.get("team_id", ""), "mo_survey_ice", win2)
	_check("二队派遣", bool(rd2.get("ok", false)))
	var money_snap2: float = Economy.money
	var caps_before: int = mo.captains.size()
	mo._ui._one_click_prep()
	_check("备战顺序: 满编时不雇佣", Economy.money == money_snap2
		and mo.captains.size() == caps_before)

	# ⑭ 池雇空后计时刷新(审查 P2): 雇光候选, 时间推过刷新点 → 自动补员
	for c in mo.recruit_pool.duplicate():
		if float(c["fee"]) <= Economy.money:
			mo.hire_captain(c["cid"])
	_check("池已雇空", mo.recruit_pool.is_empty())
	mo.now_override_sec = mo._now() + 1900.0            # 推过 30 分钟刷新点
	await get_tree().process_frame
	_check("雇空后计时刷新补员", mo.recruit_pool.size() == 3)

	# ⑮ 解雇联动: 自动解散其编队(一队队长 idle, 二队在途不动)
	var teams_before := mo.teams.size()
	var rdis: Dictionary = mo.dismiss_captain(cid)
	_check("解雇成功", bool(rdis.get("ok", false)))
	_check("解雇自动解散其编队", mo.teams.size() == teams_before - 1 		and not mo.teams.has(tid))
	_check("二队不受牵连", mo.teams.has(rt2.get("team_id", "team_002")))

	# ⑯ 节损坏(放最后——reset 会销毁一切前置) → 挂起写入(自查 P2)
	# 用二队派遣(一队已被⑮解雇销毁)
	var rc: Dictionary = mo.dispatch(rt2.get("team_id", ""), "mo_survey_ice", 777)
	_check("损坏测试前置: 二队派遣", bool(rc.get("ok", false)))
	if bool(rc.get("ok", false)):
		get_node("/root/GameSave").save_now()
		var fc := FileAccess.open("user://save.json", FileAccess.READ)
		var jc: Variant = JSON.parse_string(fc.get_as_text())
		fc.close()
		var midc: String = rc.get("mission_id", "")
		(jc as Dictionary)["sections"]["missionops"]["active"][midc]["dur"] = {}
		var fw2 := FileAccess.open("user://save.json", FileAccess.WRITE)
		fw2.store_string(JSON.stringify(jc))
		fw2.close()
		mo.reset_state()
		get_node("/root/GameSave").write_suspended = false
		get_node("/root/GameSave")._load_or_init()
		_check("损坏节: active.dur 类型损坏被拒", get_node("/root/GameSave").write_suspended)
		get_node("/root/GameSave").write_suspended = false
	mo.exploration = {}
	get_node("/root/GameSave").save_now()
	get_node("/root/GameSave").write_suspended = false
	mo.reset_state()
	get_node("/root/GameSave")._load_or_init()
	_check("损坏节: 回放被拒且写入挂起", get_node("/root/GameSave").write_suspended)
	get_node("/root/GameSave").write_suspended = false
	mo.reset_state()
	get_node("/root/GameSave").save_now()

	# ⑰ 前置: ⑯ 的 reset 清光了 → 重新雇佣+建队供 ⑰⑱⑲ 使用
	if mo.captains.is_empty() and not mo.recruit_pool.is_empty():
		mo.hire_captain(mo.recruit_pool[0]["cid"])
	if mo.teams.is_empty():
		for c in mo.captains:
			if mo.captains[c]["status"] == "idle":
				mo.create_team("测试队", c)
				break

	# ⑰ 保存失败回滚: 雇佣(R4-P1)——前置必须满足, 否则报 FAIL
	var gs := get_node("/root/GameSave")
	_check("⑰前置: 池非空可测试", not mo.recruit_pool.is_empty())
	var money_17: float = Economy.money
	var caps_17: int = mo.captains.size()
	var pool_17_first: String = str(mo.recruit_pool[0]["cid"]) if not mo.recruit_pool.is_empty() else ""
	gs.write_suspended = true
	var r17: Dictionary = mo.hire_captain(mo.recruit_pool[0]["cid"]) if not mo.recruit_pool.is_empty() else {}
	_check("保存失败: 雇佣被拒", not bool(r17.get("ok", false)))
	_check("保存失败: 钱未扣", Economy.money == money_17)
	_check("保存失败: 舰长表未变", mo.captains.size() == caps_17)
	_check("保存失败: 池首位恢复原候选", not mo.recruit_pool.is_empty()
		and str(mo.recruit_pool[0]["cid"]) == pool_17_first)
	gs.write_suspended = false

	# ⑱ 保存失败回滚: 解雇(R4-P1)——前置必须满足
	var caps_18: int = mo.captains.size()
	var money_18: float = Economy.money
	var any_idle := ""
	for c in mo.captains:
		if mo.captains[c]["status"] == "idle":
			any_idle = c
			break
	_check("⑱前置: 有 idle 舰长可测试", any_idle != "")
	gs.write_suspended = true
	if any_idle != "":
		var r18: Dictionary = mo.dismiss_captain(any_idle)
		_check("保存失败: 解雇被拒", not bool(r18.get("ok", false)))
		_check("保存失败: 退款未发", Economy.money == money_18)
		_check("保存失败: 舰长仍在", mo.captains.size() == caps_18)
	gs.write_suspended = false

	# ⑲ 保存失败回滚: 结算(R4-P1)
	var done_19 := int(mo.stats["done"]) + int(mo.stats["failed"])
	var tid19 := ""
	for t in mo.teams:
		if not mo._team_busy(t):
			tid19 = t
			break
	_check("⑲前置: 有空闲编队", tid19 != "")
	if tid19 != "":
		var r19: Dictionary = mo.dispatch(tid19, "mo_survey_ice", 555)
		_check("⑲前置: 派遣成功", bool(r19.get("ok", false)))
		if bool(r19.get("ok", false)):
			var mid19: String = r19.get("mission_id", "")
			gs.write_suspended = true
			mo.now_override_sec = float(mo.active[mid19]["ends_wall"]) + 1.0
			mo._catch_up(mo._now())
			_check("保存失败: 任务放回不结算", mo.active.has(mid19))
			_check("保存失败: 无新结算计数",
				int(mo.stats["done"]) + int(mo.stats["failed"]) == done_19)
			gs.write_suspended = false
			mo._catch_up(mo._now())
			_check("恢复后: 任务正常结算", not mo.active.has(mid19))

	# ⑳ 经济存档失败回滚(自查 P2: R5 修复此前无测试覆盖)
	# 方法: 重定向 Economy.save_path 到无效目录 → save_game 返回 false
	var orig_save_path: String = Economy.save_path
	Economy.save_path = "user://nonexistent_subdir_xyz/fail.json"

	# ⑳-a 雇佣: 经济失败 → 钱未扣+舰长未加+池首位恢复
	var money_20: float = Economy.money
	var caps_20: int = mo.captains.size()
	var pool_20_first: String = str(mo.recruit_pool[0]["cid"]) if not mo.recruit_pool.is_empty() else ""
	_check("⑳前置: 池非空", not mo.recruit_pool.is_empty())
	if not mo.recruit_pool.is_empty():
		var r20: Dictionary = mo.hire_captain(mo.recruit_pool[0]["cid"])
		_check("经济失败: 雇佣被拒", not bool(r20.get("ok", false)))
		_check("经济失败: 钱未扣", Economy.money == money_20)
		_check("经济失败: 舰长未加", mo.captains.size() == caps_20)
		_check("经济失败: 池首位恢复", not mo.recruit_pool.is_empty()
			and str(mo.recruit_pool[0]["cid"]) == pool_20_first)

	# ⑳-b 恢复后正常雇佣
	Economy.save_path = orig_save_path
	var r20b: Dictionary = mo.hire_captain(mo.recruit_pool[0]["cid"]) if not mo.recruit_pool.is_empty() else {}
	_check("⑳恢复: 雇佣成功", bool(r20b.get("ok", false)))

	# ⑳-c 解雇: 经济失败 → 退款未发+舰长仍在
	var caps_20c: int = mo.captains.size()
	var money_20c: float = Economy.money
	var idle_20 := ""
	for c in mo.captains:
		if mo.captains[c]["status"] == "idle":
			idle_20 = c
			break
	_check("⑳-c前置: 有 idle 舰长", idle_20 != "")
	if idle_20 != "":
		Economy.save_path = "user://nonexistent_subdir_xyz/fail.json"
		var r20c: Dictionary = mo.dismiss_captain(idle_20)
		_check("经济失败: 解雇被拒", not bool(r20c.get("ok", false)))
		_check("经济失败: 退款未发", Economy.money == money_20c)
		_check("经济失败: 舰长仍在", mo.captains.size() == caps_20c)
		Economy.save_path = orig_save_path

	# ⑳-d 结算: 经济失败 → 奖励撤回+任务放回+经验恢复
	var tid20 := ""
	for t in mo.teams:
		if not mo._team_busy(t):
			tid20 = t
			break
	_check("⑳-d前置: 有空闲编队", tid20 != "")
	if tid20 != "":
		var r20d: Dictionary = mo.dispatch(tid20, "mo_survey_ice", 888)
		_check("⑳-d前置: 派遣成功", bool(r20d.get("ok", false)))
		if bool(r20d.get("ok", false)):
			var mid20: String = r20d.get("mission_id", "")
			var done_20 := int(mo.stats["done"])
			var exp_20 := int(mo.exploration["ep"])
			var cap_20_cid: String = mo.active[mid20]["cid"]
			var cap_20_snap: Dictionary = mo.captains[cap_20_cid].duplicate()
			# 找必胜 seed 保证走成功路径
			var win_20 := _find_succeeding_seed("mo_survey_ice", cap_20_cid)
			if win_20 >= 0:
				# 撤回当前派遣, 重新用必胜 seed
				mo.active.erase(mid20)
				mo.captains[cap_20_cid]["status"] = "idle"
				var r20w: Dictionary = mo.dispatch(tid20, "mo_survey_ice", win_20)
				if bool(r20w.get("ok", false)):
					mid20 = r20w.get("mission_id", "")
					done_20 = int(mo.stats["done"])
					exp_20 = int(mo.exploration["ep"])
					Economy.save_path = "user://nonexistent_subdir_xyz/fail.json"
					mo.now_override_sec = float(mo.active[mid20]["ends_wall"]) + 1.0
					mo._catch_up(mo._now())
					_check("经济失败: 任务放回", mo.active.has(mid20))
					_check("经济失败: 结算数未变", int(mo.stats["done"]) == done_20)
					_check("经济失败: EP未变", int(mo.exploration["ep"]) == exp_20)
					_check("经济失败: 舰长经验恢复",
						int(mo.captains[cap_20_cid]["exp"]) == int(cap_20_snap["exp"]))
					Economy.save_path = orig_save_path
					# 恢复后正常结算
					mo._catch_up(mo._now())
					_check("⑳恢复: 任务正常结算", not mo.active.has(mid20))
			else:
				_check("⑳-d: 找到必胜seed", false)  # 显式报 FAIL
		Economy.save_path = orig_save_path

	# 收尾清理
	Economy.save_path = orig_save_path
	gs.write_suspended = false

	# ═══════════ M2 功能测试 ═══════════

	# ㉑ 舰船启用/退役(P1-2: ship_uids) — 绝对重置库存(不受之前测试影响)
	Economy.inv["longbow"] = 2
	var rc21: Dictionary = mo.commission_ship("longbow")
	_check("㉑ 启用成功", bool(rc21.get("ok", false)))
	var ship1: String = rc21.get("uid", "")
	_check("㉑ 自动编号 001号", rc21.get("name", "") == "001号")
	_check("㉑ 库存-1", int(Economy.inv.get("longbow", 0)) == 1)
	var rc21b: Dictionary = mo.commission_ship("longbow")
	_check("㉑ 二号舰 002号", rc21b.get("name", "") == "002号")
	var ship2: String = rc21b.get("uid", "")
	_check("㉑ 库存-2", int(Economy.inv.get("longbow", 0)) == 0)
	var rc21c: Dictionary = mo.commission_ship("longbow")
	_check("㉑ 库存空拒绝", not bool(rc21c.get("ok", false)))

	# ㉒ 舰船入编队(P1-2: 装备门槛的前提)
	var rt22: Dictionary = mo.add_ship_to_team(tid, ship1)
	_check("㉒ 船入队成功", bool(rt22.get("ok", false)))
	_check("㉒ 编队有 ship_uids", mo.teams[tid].get("ship_uids", []).has(ship1))
	var rt22b: Dictionary = mo.add_ship_to_team(tid, ship2)
	_check("㉒ 二号船入队", bool(rt22b.get("ok", false)))

	# ㉓ 装备安装/卸下+门槛(P1-2 验证)
	mo.grant_equipment("eq_weapon_mk1", 2)
	var ri23: Dictionary = mo.install_equipment(ship1, "eq_weapon_mk1")
	_check("㉓ 安装武器", bool(ri23.get("ok", false)))
	_check("㉓ 舰船 fitted 有武器", mo.fleet[ship1]["fitted"]["weapon"] == "eq_weapon_mk1")
	_check("㉓ 库存-1", int(mo.inventory.get("eq_weapon_mk1", 0)) == 1)
	# 装备门槛: 战斗任务需要武器
	var gaps23: Array[String] = mo.check_equip_req("mo_combat_skirmish", tid)
	_check("㉓ 战斗门槛通过(有武器)", gaps23.is_empty())
	var gaps23b: Array[String] = mo.check_equip_req("mo_signal_faint", tid)
	_check("㉓ 信号门槛未通过(无电子)", not gaps23b.is_empty())
	# 卸下
	var rr23: Dictionary = mo.remove_equipment(ship1, "weapon")
	_check("㉓ 卸下武器", bool(rr23.get("ok", false)))
	_check("㉓ 卸下后库存+1", int(mo.inventory.get("eq_weapon_mk1", 0)) == 2)

	# ㉔ 舰长技能学习/升级
	mo.captains[cid]["points"] = 3   # 给技能点
	var rl24: Dictionary = mo.learn_skill(cid, "first_strike")
	_check("㉔ 学习技能", bool(rl24.get("ok", false)))
	_check("㉔ 技能已学 lv1", int(mo.captains[cid]["skills"].get("first_strike", 0)) == 1)
	_check("㉔ 点数-1", int(mo.captains[cid]["points"]) == 2)
	var ru24: Dictionary = mo.upgrade_skill(cid, "first_strike")
	_check("㉔ 升级到 lv2", bool(ru24.get("ok", false)))
	_check("㉔ 点数-2", int(mo.captains[cid]["points"]) == 1)
	var rl24b: Dictionary = mo.learn_skill(cid, "first_strike")
	_check("㉔ 重复学习被拒", not bool(rl24b.get("ok", false)))

	# ㉕ T1 升级
	mo.grant_equipment("eq_weapon_mk1", 1)
	mo.grant_material("exp_weapon", 5)
	var ru25: Dictionary = mo.upgrade_equipment("eq_weapon_mk1")
	_check("㉕ T1 升级成功", bool(ru25.get("ok", false)))
	_check("㉕ 升级品入库", int(mo.inventory.get("eq_weapon_mk1_up", 0)) >= 1)
	_check("㉕ 材料消耗", int(mo.inventory.get("exp_weapon", 0)) == 0)

	# ㉖ 碎片兑换
	mo.inventory["frag_generic"] = 5
	var re26: Dictionary = mo.exchange_fragments()
	_check("㉖ 兑换成功", bool(re26.get("ok", false)))
	_check("㉖ 逆向素材+1", int(mo.inventory.get("reverse_material", 0)) >= 1)

	# ㉗ 部分成功(需要 seed 落在 partial 区)
	var partial_seed := _find_partial_seed("mo_survey_ice", cid)
	if partial_seed >= 0:
		mo.install_equipment(ship1, "eq_weapon_mk1")  # 确保有装备
		var rp: Dictionary = mo.dispatch(tid, "mo_survey_ice", partial_seed)
		if bool(rp.get("ok", false)):
			mo.now_override_sec = float(mo.active[rp["mission_id"]]["ends_wall"]) + 1.0
			await get_tree().process_frame
			var rep: Dictionary = mo._last_report
			_check("㉗ 部分成功标记", rep.get("partial", false) == true)
			_check("㉗ 部分成功有奖励", float(rep.get("credits", 0)) > 0)
			_check("㉗ 部分奖励 < 全额", float(rep.get("credits", 0)) < float(MissionDefs.TASKS["mo_survey_ice"]["credits"]))

	# ㉘ 三层板冷却
	var board_tasks: Array[Dictionary] = mo.get_board_tasks()
	_check("㉘ 板含常驻任务", board_tasks.size() >= MissionDefs.RESIDENT_TASKS.size())
	var has_resident := false
	for bt in board_tasks:
		if bt["layer"] == "resident":
			has_resident = true
			break
	_check("㉘ 常驻层存在", has_resident)
	# 派遣一个常驻任务再检查冷却
	var idle28 := mo.first_idle_team()
	if idle28 != "":
		var r28: Dictionary = mo.dispatch(idle28, "mo_salvage_field", 999)
		if bool(r28.get("ok", false)):
			mo.now_override_sec = float(mo.active[r28["mission_id"]]["ends_wall"]) + 1.0
			await get_tree().process_frame
			var board28: Array[Dictionary] = mo.get_board_tasks()
			var found_cd := false
			for bt in board28:
				if bt["id"] == "mo_salvage_field" and bt["cooldown"]:
					found_cd = true
					break
			_check("㉘ 常驻冷却生效", found_cd)

	# ㉙ 远征材料掉落+发现物
	var mat_before: int = int(mo.inventory.get("exp_elec", 0))
	var disc_before: int = mo.discovery_count()
	var idle29 := mo.first_idle_team()
	if idle29 != "":
		var win29 := _find_succeeding_seed("mo_survey_ice", mo.teams[idle29]["captain_id"])
		var r29: Dictionary = mo.dispatch(idle29, "mo_survey_ice", win29)
		if bool(r29.get("ok", false)):
			mo.now_override_sec = float(mo.active[r29["mission_id"]]["ends_wall"]) + 1.0
			await get_tree().process_frame
			_check("㉙ 远征材料掉落", int(mo.inventory.get("exp_elec", 0)) > mat_before)
			_check("㉙ 勘测任务出发现物", mo.discovery_count() > disc_before)

	# ㉚ 舰船退役
	var fleet_before: int = mo.ship_count()
	var rd30: Dictionary = mo.decommission_ship(ship2)
	_check("㉚ 退役成功", bool(rd30.get("ok", false)))
	_check("㉚ 名册-1", mo.ship_count() == fleet_before - 1)
	_check("㉚ 库存+1", int(Economy.inv.get("longbow", 0)) >= 1)

	print("== 结果: %s (fails=%d) ==" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _roll_with(seed_v: int) -> bool:
	# 与 MissionOps._resolve 相同的掷骰: 重放 seed 的第一个 randf 与任务成功率比较
	var def: Dictionary = MissionDefs.TASKS["mo_survey_ice"]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var roll := rng.randf()
	return roll < MissionDefs.success_probability(def, {})


func _find_succeeding_seed(task_id: String, cid: String) -> int:
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var p := MissionDefs.success_probability(def, MissionOps.captains.get(cid, {}))
	for seed_v in range(1, 500):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		if rng.randf() < p:
			return seed_v
	return -1


func _find_partial_seed(task_id: String, cid: String) -> int:
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var p := MissionDefs.success_probability(def, MissionOps.captains.get(cid, {}))
	var partial_line: float = p + (1.0 - p) * 0.5
	for seed_v in range(1, 500):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		var roll := rng.randf()
		if roll >= p and roll < partial_line:
			return seed_v
	return -1


func _find_failing_seed(task_id: String, cid: String) -> int:
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var p := MissionDefs.success_probability(def, MissionOps.captains.get(cid, {}))
	# M2: 需要超过部分成功区(roll >= p + (1-p)*0.5)才算真失败
	var partial_line: float = p + (1.0 - p) * 0.5
	for seed_v in range(1, 500):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		if rng.randf() >= partial_line:
			return seed_v
	return -1
