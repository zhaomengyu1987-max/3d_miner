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
	_catch_up(_now())
	if recruit_pool.is_empty():
		_refresh_pool()
	board_refreshed.emit()
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


func _apply_state(data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	exploration = data.get("exploration", exploration)
	captains = data.get("captains", {})
	recruit_pool = data.get("recruit_pool", [])
	pool_refresh_at = float(data.get("pool_refresh_at", 0.0))
	pool_seed = int(data.get("pool_seed", 0))
	teams = data.get("teams", {})
	active = data.get("active", {})
	stats = data.get("stats", stats)
	_cap_seq = int(data.get("cap_seq", 0))
	_team_seq = int(data.get("team_seq", 0))
	_mis_seq = int(data.get("mis_seq", 0))


# ── 主循环: 到点结算 ──
func _process(_delta: float) -> void:
	var now := _now()
	if not recruit_pool.is_empty() and now >= pool_refresh_at:
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
func hire_captain(candidate_cid: String) -> Dictionary:
	for c in recruit_pool:
		if c["cid"] == candidate_cid:
			var fee := float(c["fee"])
			if Economy.money < fee:
				return {"ok": false, "why": "资金不足(押金 %d)" % int(fee)}
			Economy.add_money(-fee)
			_cap_seq += 1
			var cid := "cap_%03d" % _cap_seq
			captains[cid] = {"name": c["name"], "tier": c["tier"], "spec": c["spec"],
				"level": 1, "exp": 0, "status": "idle"}
			recruit_pool.erase(c)
			get_node("/root/GameSave").touch()
			captain_state_changed.emit(cid, "hired")
			return {"ok": true, "cid": cid}
	return {"ok": false, "why": "候选不存在"}


func dismiss_captain(cid: String) -> Dictionary:
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	if captains[cid]["status"] != "idle":
		return {"ok": false, "why": "在途舰长不可解雇"}
	Economy.add_money(MissionDefs.TIERS[captains[cid]["tier"]]["hire_fee"] * 0.5)
	captains.erase(cid)
	get_node("/root/GameSave").touch()
	captain_state_changed.emit(cid, "dismissed")
	return {"ok": true}


# ── 编队(M1: 舰长即编队, 船位 M2 舰船实例落地后启用) ──
func create_team(team_name: String, cid: String) -> Dictionary:
	if teams.size() >= MissionDefs.MAX_TEAMS:
		return {"ok": false, "why": "行动舰队已满(%d 队)" % MissionDefs.MAX_TEAMS}
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
	if success:
		var ep := int(def["ep"])
		var credits := float(def["credits"])
		exploration["ep"] += ep
		Economy.add_money(credits)
		stats["done"] += 1
		report["ep"] = ep
		report["credits"] = credits
		_give_captain_exp(cid, 30)
	else:
		stats["failed"] += 1
		report["ep"] = 0
		report["credits"] = 0
		_give_captain_exp(cid, 5)
	if captains.has(cid):
		captains[cid]["status"] = "idle"
		captain_state_changed.emit(cid, "idle")
	active.erase(mid)
	_last_report = report
	get_node("/root/GameSave").touch()
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
