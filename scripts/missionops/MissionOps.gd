extends Node

## MissionOps 探索派遣系统 · 状态机 autoload(M1 骨架, 蓝图 §13)。
##
## 结构 = 蓝图 §3 存档节(M1 子集): exploration / captains / recruit_pool / teams / active / stats。
## 时钟 = 墙钟(§6.1 方案A): 派遣记 started_wall/ends_wall, 到点按 mission seed 掷骰结算;
## 离线补算 = 读档后 catch_up(now), 与在线同函数同结果。
## 随机 = 每任务独立 seed(存档), 同 seed 重放同结果(§11.8)。
## 边界(§1): 只调 Economy.add_money / Economy.money; 对 WorldState 零依赖。

signal mission_completed(report: Dictionary)
signal captain_state_changed(cid: String, status: String)
signal board_refreshed

## 测试注入: >=0 时替代真实墙钟(冒烟测试的时间旅行)
var now_override_sec: float = -1.0

const SAVE_SECTION := "missionops"
const POOL_SIZE := 3
const POOL_REFRESH_SEC := 1800.0     # 30 现实分钟 [占位]
const CAPTAIN_SHARE := 0.20          # 舰长分成(报告注记, M2 落地逐账)

var exploration: Dictionary = {"ep": 0, "level": 1}
var captains: Dictionary = {}        # cid -> {name, tier, spec, level, exp, status}
var recruit_pool: Array = []         # [{cid, name, tier, spec, fee}]
var pool_refresh_at: float = 0.0
var pool_seed: int = 0
var teams: Dictionary = {}           # team_id -> {name, captain_id}
var active: Dictionary = {}          # mission_id -> {task_id, team_id, cid, seed, started_wall, ends_wall, dur}
var stats: Dictionary = {"done": 0, "failed": 0}
var _cap_seq: int = 0
var _team_seq: int = 0
var _mis_seq: int = 0
var _last_report: Dictionary = {}
var _ui: Node = null


func _ready() -> void:
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.register_section(SAVE_SECTION, Callable(self, "_get_state"), Callable(self, "_apply_state"))
	# 启动补算延迟到本帧末: 确保所有节注册/回放完成后再结算,
	# 且 _refresh_pool 的 seed 取到最终墙钟值(避免注册顺序竞争)。
	call_deferred("_startup_catch_up")
	# M1 临时入口: F6 开关任务板(M2 挂 EconUiRoot 面板链)
	_ui = load("res://scripts/ui/MissionBoardUi.gd").new()
	add_child(_ui)


# ── 时间 ──
func _now() -> float:
	if now_override_sec >= 0.0:
		return now_override_sec
	return Time.get_unix_time_from_system()


# ── 持久化(GameSave 节) ──
func _get_state() -> Dictionary:
	return {
		"exploration": exploration, "captains": captains, "recruit_pool": recruit_pool,
		"pool_refresh_at": pool_refresh_at, "pool_seed": pool_seed,
		"teams": teams, "active": active, "stats": stats,
		"cap_seq": _cap_seq, "team_seq": _team_seq, "mis_seq": _mis_seq,
	}


func _apply_state(data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var exploration_d: Variant = data.get("exploration", null)
	var captains_d: Variant = data.get("captains", null)
	var pool_a: Variant = data.get("recruit_pool", null)
	var teams_d: Variant = data.get("teams", null)
	var active_d: Variant = data.get("active", null)
	var stats_d: Variant = data.get("stats", null)
	# ── 外层容器 ──
	if typeof(exploration_d) != TYPE_DICTIONARY or typeof(captains_d) != TYPE_DICTIONARY 			or typeof(pool_a) != TYPE_ARRAY or typeof(teams_d) != TYPE_DICTIONARY 			or typeof(active_d) != TYPE_DICTIONARY or typeof(stats_d) != TYPE_DICTIONARY:
		push_warning("MissionOps: 存档节外层结构损坏")
		return false
	# ── 消费字段深度校验(只验实际读取的键; JSON 数字回放为 float, INT/FLOAT 同收) ──
	if typeof(exploration_d.get("ep", null)) not in [TYPE_INT, TYPE_FLOAT]:
		push_warning("MissionOps: exploration.ep 损坏")
		return false
	for k in ["done", "failed"]:
		if typeof(stats_d.get(k, null)) not in [TYPE_INT, TYPE_FLOAT]:
			push_warning("MissionOps: stats.%s 损坏" % k)
			return false
	for cid in captains_d:
		var c: Variant = captains_d[cid]
		if typeof(c) != TYPE_DICTIONARY:
			return false
		for k in ["name", "tier", "spec", "level", "exp", "status"]:
			if not (c as Dictionary).has(k):
				push_warning("MissionOps: captains[%s] 缺 %s" % [str(cid), k])
				return false
		if typeof(c["level"]) not in [TYPE_INT, TYPE_FLOAT] 				or typeof(c["exp"]) not in [TYPE_INT, TYPE_FLOAT]:
			return false
		if not MissionDefs.TIERS.has(c["tier"]) or not MissionDefs.SPECS.has(c["spec"]):
			push_warning("MissionOps: captains[%s] tier/spec 非法" % str(cid))
			return false
		if not (c["status"] in ["idle", "on_mission", "resting"]):
			return false
	for e in pool_a:
		if typeof(e) != TYPE_DICTIONARY or not (e as Dictionary).has_all(
				["cid", "name", "tier", "spec", "fee"]):
			push_warning("MissionOps: recruit_pool 条目损坏")
			return false
		if not MissionDefs.TIERS.has(e["tier"]):
			return false
	for tid in teams_d:
		var tm: Variant = teams_d[tid]
		if typeof(tm) != TYPE_DICTIONARY or not (tm as Dictionary).has_all(
				["name", "captain_id"]):
			return false
		if not captains_d.has(tm["captain_id"]):
			push_warning("MissionOps: 编队 %s 引用不存在舰长(悬空)" % str(tid))
			return false
	for mid in active_d:
		var m: Variant = active_d[mid]
		if typeof(m) != TYPE_DICTIONARY:
			return false
		var need := ["task_id", "team_id", "cid", "seed", "started_wall", "ends_wall", "dur"]
		if not (m as Dictionary).has_all(need):
			push_warning("MissionOps: active[%s] 字段不全" % str(mid))
			return false
		if not MissionDefs.TASKS.has(m["task_id"]):
			push_warning("MissionOps: active[%s] 任务不存在" % str(mid))
			return false
		if not captains_d.has(m["cid"]) or not teams_d.has(m["team_id"]):
			push_warning("MissionOps: active[%s] 引用悬空" % str(mid))
			return false
		# 全字段类型(审查 R3-P2: 消费什么验什么——结算读取全部七个)
		for k in ["seed", "started_wall", "ends_wall", "dur"]:
			if typeof(m[k]) not in [TYPE_INT, TYPE_FLOAT]:
				push_warning("MissionOps: active[%s].%s 类型损坏(%s)" % [str(mid), k, str(typeof(m[k]))])
				return false
		for k in ["task_id", "team_id", "cid"]:
			if typeof(m[k]) != TYPE_STRING:
				push_warning("MissionOps: active[%s].%s 类型损坏" % [str(mid), k])
				return false
		if float(m["dur"]) <= 0.0 or float(m["ends_wall"]) < float(m["started_wall"]):
			push_warning("MissionOps: active[%s] 数值非法" % str(mid))
			return false
	# ── 校验通过, 回放 ──
	exploration = exploration_d
	captains = captains_d
	recruit_pool = pool_a
	teams = teams_d
	active = active_d
	stats = stats_d
	pool_refresh_at = float(data.get("pool_refresh_at", 0.0))
	pool_seed = int(data.get("pool_seed", 0))
	_cap_seq = int(data.get("cap_seq", 0))
	_team_seq = int(data.get("team_seq", 0))
	_mis_seq = int(data.get("mis_seq", 0))
	return true


## 启动补算(deferred): 所有节注册/回放完成后执行一次; 幂等。
func _startup_catch_up() -> void:
	_catch_up(_now())
	# 空池补员仅在"从未初始化"时进行(pool_refresh_at<=0 = 新档);
	# 恢复档的空池等计时到期由 _process 自然刷新(审查 R3-P2)
	if recruit_pool.is_empty() and pool_refresh_at <= 0.0:
		_refresh_pool()
	if fleet_cap() == 0:
		print("[MissionOps] 雇佣兵巢穴未建造——建造后解锁探索派遣(F6)")
	board_refreshed.emit()


# ── 主循环: 到点结算 ──
func _process(_delta: float) -> void:
	var now := _now()
	if now >= pool_refresh_at:
		_refresh_pool()
		board_refreshed.emit()
	if active.is_empty():
		return
	var done_ids: Array[String] = []
	for mid in active:
		if now >= float(active[mid]["ends_wall"]):
			done_ids.append(mid)
	for mid in done_ids:
		_resolve(mid)


## 离线补算(读档后/测试用): 到点任务逐个结算, 幂等(active 删除即不重放)
func _catch_up(now: float) -> void:
	var done_ids: Array[String] = []
	for mid in active:
		if now >= float(active[mid]["ends_wall"]):
			done_ids.append(mid)
	for mid in done_ids:
		_resolve(mid)


# ── 招募池(seed 驱动, v4v) ──
func _refresh_pool() -> void:
	pool_seed = int(_now() * 1000.0) ^ (_mis_seq * 2654435761)
	pool_refresh_at = _now() + POOL_REFRESH_SEC
	var rng := RandomNumberGenerator.new()
	rng.seed = pool_seed
	recruit_pool.clear()
	for i in POOL_SIZE:
		var roll := rng.randf()
		var tier := "normal"
		if roll > MissionDefs.TIER_WEIGHTS["normal"]:
			tier = "rare"
		var spec: String = MissionDefs.SPECS[rng.randi_range(0, MissionDefs.SPECS.size() - 1)]
		var fname: String = MissionDefs.FIRST_NAMES[rng.randi_range(0, MissionDefs.FIRST_NAMES.size() - 1)]
		var nick: String = MissionDefs.NICKS[rng.randi_range(0, MissionDefs.NICKS.size() - 1)]
		var name := fname
		if tier == "rare":
			name += nick
		var fee: float = MissionDefs.TIERS[tier]["hire_fee"]
		recruit_pool.append({"cid": "cand_%d" % (i + 1), "name": name,
			"tier": tier, "spec": spec, "fee": fee})


# ── 雇佣 / 解雇 ──

## 动钱后立即同步经济自档(审查 R3-P1: 钱包唯一权威 = economy_save.json,
## MissionOps 不再在 GameSave 存钱包; 每次变更即刻落盘, 关窗/崩溃零窗口)
func _persist_economy() -> void:
	if Economy.has_method("save_game"):
		Economy.save_game()


func hire_captain(candidate_cid: String) -> Dictionary:
	# 先拷贝目标再操作(不在 for-in 中 erase 原数组——脆弱模式)
	var target: Dictionary = {}
	for c in recruit_pool:
		if c["cid"] == candidate_cid:
			target = c
			break
	if target.is_empty():
		return {"ok": false, "why": "候选不存在"}
	var fee := float(target["fee"])
	if Economy.money < fee:
		return {"ok": false, "why": "资金不足(押金 %d)" % int(fee)}
	Economy.add_money(-fee)
	_cap_seq += 1
	var cid := "cap_%03d" % _cap_seq
	captains[cid] = {"name": target["name"], "tier": target["tier"], "spec": target["spec"],
		"level": 1, "exp": 0, "status": "idle"}
	recruit_pool.erase(target)
	get_node("/root/GameSave").touch()
	_persist_economy()
	captain_state_changed.emit(cid, "hired")
	return {"ok": true, "cid": cid}


func dismiss_captain(cid: String) -> Dictionary:
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	if captains[cid]["status"] != "idle":
		return {"ok": false, "why": "在途舰长不可解雇"}
	# 解雇自动解散其编队(审查 P1: 不留悬空占位占容量)
	var disbanded: Array[String] = []
	for tid in teams.keys():
		if teams[tid]["captain_id"] == cid:
			disbanded.append(tid)
	for tid in disbanded:
		teams.erase(tid)
	Economy.add_money(MissionDefs.TIERS[captains[cid]["tier"]]["hire_fee"] * 0.5)
	captains.erase(cid)
	get_node("/root/GameSave").touch()
	_persist_economy()
	captain_state_changed.emit(cid, "dismissed")
	return {"ok": true, "disbanded": disbanded}


# ── 编队(M1: 舰长即编队, 船位 M2 舰船实例落地后启用) ──
## 舰队容量 = 巢穴等级(蓝图 §5.9); 未建巢穴 → 0 队 → 一切派遣锁死
func fleet_cap() -> int:
	if Economy.has_method("hive_level"):
		return Economy.hive_level()
	return MissionDefs.MAX_TEAMS   # Economy 不在(main 未并入)时用占位


func create_team(team_name: String, cid: String) -> Dictionary:
	if teams.size() >= fleet_cap():
		return {"ok": false, "why": "行动舰队已满(%d 队)" % fleet_cap()}
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	if captains[cid]["status"] != "idle":
		return {"ok": false, "why": "舰长不在岗"}
	for tid in teams:
		if teams[tid]["captain_id"] == cid:
			return {"ok": false, "why": "该舰长已带另一队"}
	_team_seq += 1
	var tid := "team_%03d" % _team_seq
	teams[tid] = {"name": team_name, "captain_id": cid}
	get_node("/root/GameSave").touch()
	return {"ok": true, "team_id": tid}


func first_idle_team() -> String:
	for tid in teams:
		var cid: String = teams[tid]["captain_id"]
		if captains.has(cid) and captains[cid]["status"] == "idle" and not _team_busy(tid):
			return tid
	return ""


func _team_busy(tid: String) -> bool:
	for mid in active:
		if active[mid]["team_id"] == tid:
			return true
	return false


# ── 派遣 ──
func dispatch(team_id: String, task_id: String, seed_override: int = -1) -> Dictionary:
	if not MissionDefs.TASKS.has(task_id):
		return {"ok": false, "why": "任务不存在"}
	if not teams.has(team_id):
		return {"ok": false, "why": "编队不存在"}
	if _team_busy(team_id):
		return {"ok": false, "why": "编队在途"}
	var cid: String = teams[team_id]["captain_id"]
	if not captains.has(cid) or captains[cid]["status"] != "idle":
		return {"ok": false, "why": "舰长不在岗"}
	var def: Dictionary = MissionDefs.TASKS[task_id]
	_mis_seq += 1
	var mid := "mis_%03d" % _mis_seq
	var seed_v := seed_override if seed_override >= 0 else int(_now() * 1000.0) ^ (_mis_seq * 7919)
	var now := _now()
	var dur := float(def["dur_sec"])
	active[mid] = {"task_id": task_id, "team_id": team_id, "cid": cid,
		"seed": seed_v, "started_wall": now, "ends_wall": now + dur, "dur": dur}
	captains[cid]["status"] = "on_mission"
	get_node("/root/GameSave").touch()
	captain_state_changed.emit(cid, "on_mission")
	return {"ok": true, "mission_id": mid, "ends_wall": now + dur}


# ── 结算(成功/失败两档, M1) ──
## 崩溃安全顺序(自查 P1): 先从 active 删除并同步落盘 save.json,
## 再给奖励——崩溃时丢奖励(而非双给), 通胀方向安全。
func _resolve(mid: String) -> void:
	var mis: Dictionary = active[mid]
	var def: Dictionary = MissionDefs.TASKS[mis["task_id"]]
	var cid: String = mis["cid"]
	var cap: Dictionary = captains.get(cid, {})
	var rng := RandomNumberGenerator.new()
	rng.seed = int(mis["seed"])
	var roll := rng.randf()
	var p := MissionDefs.success_probability(def, cap)
	var success := roll < p
	var report := {
		"mission_id": mid, "task": def["name"], "success": success,
		"seed": int(mis["seed"]), "captain": cap.get("name", "?"),
		"duration": float(mis["dur"]),
	}
	# ── 第一步: 任务出册 + 舰长状态 + 同步落盘(此点之后崩溃不会重复结算) ──
	active.erase(mid)
	if captains.has(cid):
		captains[cid]["status"] = "idle"
		captain_state_changed.emit(cid, "idle")
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	# ── 第二步: 发奖励(此点之后崩溃丢奖励, 不双给) ──
	if success:
		var ep := int(def["ep"])
		var credits := float(def["credits"])
		exploration["ep"] += ep
		report["ep"] = ep
		report["credits"] = credits
		stats["done"] += 1
		_give_captain_exp(cid, 30)
		Economy.add_money(credits)
		_persist_economy()
	else:
		report["ep"] = 0
		report["credits"] = 0
		stats["failed"] += 1
		_give_captain_exp(cid, 5)
	_last_report = report
	if gs:
		gs.touch()
	mission_completed.emit(report)


func _give_captain_exp(cid: String, amount: int) -> void:
	if not captains.has(cid):
		return
	var cap: Dictionary = captains[cid]
	cap["exp"] = int(cap["exp"]) + amount
	var max_lv: int = MissionDefs.TIERS[cap["tier"]]["max_level"]
	while cap["level"] < max_lv:
		var need := int(100.0 * pow(float(cap["level"]), 1.5))
		if int(cap["exp"]) < need:
			break
		cap["exp"] = int(cap["exp"]) - need
		cap["level"] = int(cap["level"]) + 1


## 测试/调试用: 清空全部运行态(不删存档文件; 存档回放发生在 _ready, 之后重置即测试基线)
func reset_state() -> void:
	exploration = {"ep": 0, "level": 1}
	captains = {}
	recruit_pool = []
	pool_refresh_at = 0.0
	teams = {}
	active = {}
	stats = {"done": 0, "failed": 0}
	_cap_seq = 0
	_team_seq = 0
	_mis_seq = 0
	_last_report = {}
	_refresh_pool()


# ── 对外只读 ──
func is_ship_on_mission(_ship_uid: String) -> bool:
	return false   # M1 无舰船实例; M2 舰船名册落地后接任务锁


func last_report() -> Dictionary:
	return _last_report


func ep() -> int:
	return int(exploration["ep"])
