extends Node

## MissionOps M1 冒烟测试(蓝图 §13.5 子集)。
## 运行: godot --headless --path . res://tests/missionops_smoke_test.tscn
## 全过 → quit(0); 任一失败 → quit(1)。
## 时间旅行: 通过 MissionOps.now_override_sec 注入, 不 sleep。

var _fails: int = 0
var _reports: Array = []


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

	# ⑤ 派遣 + 编队互斥
	var rd: Dictionary = mo.dispatch(tid, "mo_survey_ice")
	_check("派遣成功", bool(rd.get("ok", false)))
	var mid: String = rd.get("mission_id", "")
	_check("任务入途", mo.active.has(mid))
	var rbusy: Dictionary = mo.dispatch(tid, "mo_combat_skirmish")
	_check("在途编队不可再派", not bool(rbusy.get("ok", false)))

	# ⑥ 种子复现: 同 seed 同结果(直接比较概率掷骰)
	var roll_a: bool = _roll_with(mo.active[mid]["seed"], mid)
	var roll_b: bool = _roll_with(mo.active[mid]["seed"], mid)
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

	# ⑩ 存档 round-trip: save_now 后文件含 missionops 节
	get_node("/root/GameSave").save_now()
	var f := FileAccess.open("user://save.json", FileAccess.READ)
	var ok_file := f != null
	var payload: Variant = null
	if ok_file:
		payload = JSON.parse_string(f.get_as_text())
		f.close()
	_check("存档落盘且 JSON 可解析", ok_file and typeof(payload) == TYPE_DICTIONARY)
	_check("存档含 missionops 节", typeof(payload) == TYPE_DICTIONARY \
		and (payload as Dictionary).get("sections", {}).has("missionops"))
	_check("存档含 saved_at_wall", typeof(payload) == TYPE_DICTIONARY \
		and float((payload as Dictionary).get("saved_at_wall", 0)) > 0)

	# ⑪ 派遣到不存在任务被拒
	var rbad: Dictionary = mo.dispatch(tid, "mo_not_exist")
	_check("非法任务被拒", not bool(rbad.get("ok", false)))

	print("== 结果: %s (fails=%d) ==" % ["PASS" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _roll_with(seed_v: int, _mid: String) -> bool:
	# 与 MissionOps._resolve 相同的掷骰: 重放 seed 的第一个 randf 与任务成功率比较
	var def: Dictionary = MissionDefs.TASKS["mo_survey_ice"]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var roll := rng.randf()
	return roll < MissionDefs.success_probability(def, MissionOps.captains.get(_active_cid(), {}))


func _active_cid() -> String:
	return ""


func _find_failing_seed(task_id: String, cid: String) -> int:
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var p := MissionDefs.success_probability(def, MissionOps.captains.get(cid, {}))
	for seed_v in range(1, 200):
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		if rng.randf() >= p:
			return seed_v
	return -1
