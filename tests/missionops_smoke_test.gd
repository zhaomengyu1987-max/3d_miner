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
	# 上轮 ⑯ 可能留下坏档+写入挂起 → 本轮先恢复可写并落一个干净基线档
	get_node("/root/GameSave").write_suspended = false
	get_node("/root/GameSave").save_now()
	var now := Time.get_unix_time_from_system()
	mo.now_override_sec = now

	# ① 环境前置: 钱包注资(测试专用, 不走生产路径)
	Economy.money = 100000.0

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
	var bad_seed := _find_failing_seed("mo_combat_skirmish", cid)
	_check("找到必败 seed", bad_seed >= 0)
	if bad_seed >= 0:
		var m2: float = Economy.money            # 基准 = 派遣前余额(成功结算已入账)
		var rf: Dictionary = mo.dispatch(tid, "mo_combat_skirmish", bad_seed)
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
	var money_snap: float = Economy.money
	mo.exploration["ep"] = ep_snap + 77                       # 内存污染
	mo.captains["cap_fake"] = {"name": "幽灵", "tier": "normal", "spec": "combat",
		"level": 1, "exp": 0, "status": "idle"}
	get_node("/root/GameSave")._load_or_init()                # 从文件回放
	_check("round-trip: EP 还原", mo.ep() == ep_snap)
	_check("round-trip: 舰长表还原(幽灵被清除)", \
		not mo.captains.has("cap_fake") and mo.captains.size() == caps_snap)
	_check("round-trip: 编队数还原", mo.teams.size() == teams_snap)
	_check("round-trip: 钱包还原", absf(Economy.money - money_snap) < 0.001)

	# ⑪ 重启补算: 派遣未来任务 → 模拟进程死亡(清内存) → 文件回放 → catch_up → 幂等
	var done0 := int(mo.stats["done"])
	var rre: Dictionary = mo.dispatch(tid, "mo_survey_ice", 424242)
	_check("重启测试: 派遣成功", bool(rre.get("ok", false)))
	var mid2: String = rre.get("mission_id", "")
	get_node("/root/GameSave").save_now()                     # 模拟重启前的自动存档心跳
	mo.active = {}                                            # 进程死亡(内存丢失)
	get_node("/root/GameSave")._load_or_init()                # 文件回放
	_check("重启回放: 在途任务还原", mo.active.has(mid2))
	mo.now_override_sec = float(mo.active[mid2]["ends_wall"]) + 1.0
	mo._catch_up(mo._now())
	_check("重启补算: 到点结算", not mo.active.has(mid2) and int(mo.stats["done"]) == done0 + 1)
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

	# ⑯ 节损坏 → 挂起写入(审查 P1): exploration={} 必须被拒
	mo.exploration = {}
	get_node("/root/GameSave").save_now()               # 把坏节写进档(模拟损坏)
	get_node("/root/GameSave").write_suspended = false
	mo.reset_state()                                    # 清内存, 模拟重启
	get_node("/root/GameSave")._load_or_init()          # 读到坏节
	_check("损坏节: 回放被拒且写入挂起", get_node("/root/GameSave").write_suspended)
	get_node("/root/GameSave").write_suspended = false  # 恢复
	mo.reset_state()
	get_node("/root/GameSave").save_now()               # 收尾自清理: 落干净基线档

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


func _find_failing_seed(task_id: String, cid: String) -> int:
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var p := MissionDefs.success_probability(def, MissionOps.captains.get(cid, {}))
	for seed_v in range(1, 200):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		if rng.randf() >= p:
			return seed_v
	return -1
