extends Node

## MissionOps 探索派遣系统 · 状态机 autoload(M1 骨架, 蓝图 §13)。
##
## 结构 = 蓝图 §3 存档节(M1 子集): exploration / captains / recruit_pool / teams / active / stats。
## 时钟 = 墙钟(§6.1 方案A): 派遣记 started_wall/ends_wall, 到点按 mission seed 掷骰结算;
## 离线补算 = 读档后 catch_up(now), 与在线同函数同结果。
## 随机 = 每任务独立 seed(存档), 同 seed 重放同结果(§11.8)。
## 航道安全通过可选 WorldState 适配接口结算；待处理结果随本节保存并可重试。

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
var captains: Dictionary = {}        # cid -> {name, tier, spec, level, exp, status, skills, points}
var recruit_pool: Array = []         # [{cid, name, tier, spec, fee}]
var pool_refresh_at: float = 0.0
var pool_seed: int = 0
var teams: Dictionary = {}           # team_id -> {name, captain_id, ship_uids: []}
var active: Dictionary = {}          # mission_id -> {task_id, team_id, cid, seed, started_wall, ends_wall, dur}
var stats: Dictionary = {"done": 0, "failed": 0}
var _cap_seq: int = 0
var _team_seq: int = 0
var _mis_seq: int = 0
var _last_report: Dictionary = {}
var pending_route_results: Dictionary = {}
var pending_faction_results: Dictionary = {}
var _route_retry_at := 0.0
var _ui: Node = null
# ── MVP 试玩档 ──
var trial_mode: bool = false           # 加速模式(时长÷SPEED_DIV)
var trial_initialized: bool = false     # 初始资源只发一次
const TRIAL_SPEED_DIV := 10.0           # 试玩: 任务时长÷10
const T1UP_DUR_MOD := 0.85              # T1+升级: 任务时长×0.85(-15%)
# ── M2 新增 ──
var fleet: Dictionary = {}           # ship_uid -> {def_id, name, fitted: {power/elec/weapon/defense}}
var ship_name_counter: int = 0       # 自动编号 001号/002号…
var inventory: Dictionary = {}       # {eq_id: count, exp_material: count, frag_id: count}
var board: Dictionary = {            # 三层任务板(§5.8)
	"resident_cd": {},               # task_id -> cooldown_until_wall
	"rotation": [],                  # 当前轮换任务 id 列表
	"rotation_at": 0.0,              # 下次轮换刷新墙钟
	"rotation_seed": 0,
}


func _ready() -> void:
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.register_section(SAVE_SECTION, Callable(self, "_get_state"), Callable(self, "_apply_state"))
	# 启动补算延迟到本帧末: 确保所有节注册/回放完成后再结算,
	# 且 _refresh_pool 的 seed 取到最终墙钟值(避免注册顺序竞争)。
	call_deferred("_startup_catch_up")
	# MVP: 行动中心(F6/巢穴点击同一入口)
	_ui = load("res://scripts/ui/ActionCenterUi.gd").new()
	_ui.name = "ActionCenterUi"
	add_child(_ui)
	# M2: 战报弹窗(F7 查看 / 结算自动弹出)
	var kr: Node = load("res://scripts/ui/KillReportUi.gd").new()
	add_child(kr)


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
		"fleet": fleet, "ship_name_counter": ship_name_counter,
		"inventory": inventory, "board": board,
		"discoveries": discoveries,
		"trial_initialized": trial_initialized, "trial_mode": trial_mode,
		"pending_route_results": pending_route_results,
		"pending_faction_results": pending_faction_results,
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
	var route_d: Variant = data.get("pending_route_results", {})
	var faction_d: Variant = data.get("pending_faction_results", {})
	if not faction_d is Dictionary: return false
	for report in faction_d.values():
		if not report is Dictionary or not report.has_all(["mission_id", "task_id", "seed", "timestamp"]): return false
		if not MissionDefs.TASKS.has(report.task_id): return false
	if not route_d is Dictionary:
		return false
	for report in route_d.values():
		if not report is Dictionary or not report.has_all(["mission_id", "task_id", "seed", "timestamp"]):
			return false
		if not MissionDefs.TASKS.has(report.task_id):
			return false
		if typeof(report.mission_id) != TYPE_STRING or typeof(report.seed) not in [TYPE_INT, TYPE_FLOAT] \
			or typeof(report.timestamp) not in [TYPE_INT, TYPE_FLOAT]:
			return false
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
	pending_route_results = route_d
	pending_faction_results = faction_d
	pool_refresh_at = float(data.get("pool_refresh_at", 0.0))
	pool_seed = int(data.get("pool_seed", 0))
	_cap_seq = int(data.get("cap_seq", 0))
	_team_seq = int(data.get("team_seq", 0))
	_mis_seq = int(data.get("mis_seq", 0))
	# M2 字段
	fleet = data.get("fleet", {})
	ship_name_counter = int(data.get("ship_name_counter", 0))
	inventory = data.get("inventory", {})
	var board_d: Variant = data.get("board", null)
	if typeof(board_d) == TYPE_DICTIONARY:
		board = board_d
	var disc_d: Variant = data.get("discoveries", null)
	if typeof(disc_d) == TYPE_ARRAY:
		discoveries = disc_d
	# R6-P1: M1 旧档编队没有 ship_uids → 补默认空数组(前向兼容)
	for tid in teams:
		if not (teams[tid] as Dictionary).has("ship_uids"):
			teams[tid]["ship_uids"] = []
	trial_initialized = bool(data.get("trial_initialized", false))
	trial_mode = bool(data.get("trial_mode", false))
	return true


## 启动补算(deferred): 所有节注册/回放完成后执行一次; 幂等。
func _startup_catch_up() -> void:
	_catch_up(_now())
	_flush_route_results()
	_flush_faction_results()
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
	if (not pending_route_results.is_empty() or not pending_faction_results.is_empty()) and now >= _route_retry_at:
		_route_retry_at = now + 5.0
		_flush_route_results()
		_flush_faction_results()
	if now >= pool_refresh_at:
		_refresh_pool()
	if now >= float(board.get("rotation_at", 0.0)):
		_refresh_rotation()
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

## 动钱后立即同步经济自档; 返回 false = 经济存档写入失败(R5-P1)
func _persist_economy() -> bool:
	if Economy.has_method("save_game"):
		return bool(Economy.save_game())
	return true


func hire_captain(candidate_cid: String) -> Dictionary:
	var target_idx := -1
	var target: Dictionary = {}
	for i in range(recruit_pool.size()):
		if recruit_pool[i]["cid"] == candidate_cid:
			target = recruit_pool[i]
			target_idx = i
			break
	if target.is_empty():
		return {"ok": false, "why": "候选不存在"}
	var fee := float(target["fee"])
	if Economy.money < fee:
		return {"ok": false, "why": "资金不足(押金 %d)" % int(fee)}
	# 三阶段(R5): 改内存→存missionops→存经济; 任一失败全量回滚
	var snap_seq := _cap_seq
	_cap_seq += 1
	var cid := "cap_%03d" % _cap_seq
	captains[cid] = {"name": target["name"], "tier": target["tier"], "spec": target["spec"],
		"level": 1, "exp": 0, "status": "idle", "skills": {}, "points": 0}
	recruit_pool.remove_at(target_idx)
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		captains.erase(cid)
		_cap_seq = snap_seq
		recruit_pool.insert(target_idx, target)
		return {"ok": false, "why": "任务档写入失败, 雇佣已取消"}
	Economy.add_money(-fee)
	if not _persist_economy():
		Economy.add_money(fee)
		captains.erase(cid)
		_cap_seq = snap_seq
		recruit_pool.insert(target_idx, target)
		if gs:
			gs.save_now()
		push_warning("MissionOps: 经济存档失败, 雇佣已回滚")
		return {"ok": false, "why": "经济档写入失败, 雇佣已取消(保护钱包)"}
	captain_state_changed.emit(cid, "hired")
	return {"ok": true, "cid": cid}


func dismiss_captain(cid: String) -> Dictionary:
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	if captains[cid]["status"] != "idle":
		return {"ok": false, "why": "在途舰长不可解雇"}
	# 完整快照(R5-P2: 恢复原状态而非重建)
	var cap_snapshot: Dictionary = captains[cid].duplicate()
	var teams_snapshot: Dictionary = {}
	var disbanded: Array[String] = []
	for tid in teams.keys():
		if teams[tid]["captain_id"] == cid:
			disbanded.append(tid)
			teams_snapshot[tid] = (teams[tid] as Dictionary).duplicate()
	for tid in disbanded:
		teams.erase(tid)
	var fee: float = MissionDefs.TIERS[cap_snapshot["tier"]]["hire_fee"] * 0.5
	captains.erase(cid)
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		captains[cid] = cap_snapshot
		for tid in teams_snapshot:
			teams[tid] = teams_snapshot[tid]
		return {"ok": false, "why": "任务档写入失败, 解雇已取消"}
	Economy.add_money(fee)
	if not _persist_economy():
		Economy.add_money(-fee)
		captains[cid] = cap_snapshot
		for tid in teams_snapshot:
			teams[tid] = teams_snapshot[tid]
		if gs:
			gs.save_now()
		push_warning("MissionOps: 经济存档失败, 解雇已回滚")
		return {"ok": false, "why": "经济档写入失败, 解雇已取消(保护退款)"}
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
	# 同步落盘+回滚(自查 P2: 与 hire/dismiss/resolve 同模式)
	var snap_seq := _team_seq
	_team_seq += 1
	var tid := "team_%03d" % _team_seq
	teams[tid] = {"name": team_name, "captain_id": cid, "ship_uids": []}
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		teams.erase(tid)
		_team_seq = snap_seq
		return {"ok": false, "why": "存档写入失败, 建队已取消"}
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


## M2: 舰船加入编队(装备门槛的前提——门槛统计基于编队内舰船)
func add_ship_to_team(tid: String, ship_uid: String) -> Dictionary:
	if not teams.has(tid):
		return {"ok": false, "why": "编队不存在"}
	if not fleet.has(ship_uid):
		return {"ok": false, "why": "舰船不存在"}
	if is_ship_on_mission(ship_uid):
		return {"ok": false, "why": "在途舰船不可编队"}
	# 检查是否已在其他编队
	for other_tid in teams:
		if teams[other_tid].get("ship_uids", []).has(ship_uid):
			return {"ok": false, "why": "该舰船已在编队 %s" % teams[other_tid]["name"]}
	var max_slots: int = MissionDefs.MAX_SLOTS
	if teams[tid]["ship_uids"].size() >= max_slots:
		return {"ok": false, "why": "船位已满(%d/%d)" % [teams[tid]["ship_uids"].size(), max_slots]}
	teams[tid]["ship_uids"].append(ship_uid)
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	return {"ok": true}


## M2: 舰船移出编队
func remove_ship_from_team(tid: String, ship_uid: String) -> Dictionary:
	if not teams.has(tid):
		return {"ok": false, "why": "编队不存在"}
	var uids: Array = teams[tid].get("ship_uids", [])
	if not uids.has(ship_uid):
		return {"ok": false, "why": "该舰船不在此编队"}
	if _team_busy(tid):
		return {"ok": false, "why": "编队在途不可调整"}
	uids.erase(ship_uid)
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	return {"ok": true}


## MVP: 编队T1+装备时长修正(任一船装有_up装备→×0.85)
func _team_t1up_dur_mod(team_id: String) -> float:
	if not teams.has(team_id):
		return 1.0
	for uid in teams[team_id].get("ship_uids", []):
		if fleet.has(uid):
			for slot in fleet[uid].get("fitted", {}):
				var eq_id: String = fleet[uid]["fitted"][slot]
				if eq_id != "" and eq_id.ends_with("_up"):
					return T1UP_DUR_MOD
	return 1.0


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
	# 装备门槛检查(§15.4)
	var gaps: Array[String] = check_equip_req(task_id, team_id)
	if not gaps.is_empty():
		return {"ok": false, "why": "装备不足: " + " · ".join(gaps)}
	# R6-P2: 任务板限制(状态机层, 不依赖 UI 灰显)
	var now_wall := _now()
	if task_id in MissionDefs.RESIDENT_TASKS:
		var cd_until: float = float(board["resident_cd"].get(task_id, 0.0))
		if now_wall < cd_until:
			var remain: int = int(cd_until - now_wall)
			return {"ok": false, "why": "冷却中(剩余 %d:%02d)" % [remain / 60, remain % 60]}
	elif not (task_id in board.get("rotation", [])):
		return {"ok": false, "why": "此任务不在当前任务板上"}
	var def: Dictionary = MissionDefs.TASKS[task_id]
	# 同步落盘+回滚(自查 P2: 崩溃丢派遣而非幽灵在途)
	var snap_seq := _mis_seq
	_mis_seq += 1
	var mid := "mis_%03d" % _mis_seq
	var seed_v := seed_override if seed_override >= 0 else int(_now() * 1000.0) ^ (_mis_seq * 7919)
	var now := _now()
	var dur := float(def["dur_sec"])
	# MVP: 试玩加速
	if trial_mode:
		dur /= TRIAL_SPEED_DIV
	# MVP: T1+ 升级效果(时长×0.85, 每件生效不叠加取最优)
	dur *= _team_t1up_dur_mod(team_id)
	active[mid] = {"task_id": task_id, "team_id": team_id, "cid": cid,
		"seed": seed_v, "started_wall": now, "ends_wall": now + dur, "dur": dur}
	captains[cid]["status"] = "on_mission"
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		active.erase(mid)
		_mis_seq = snap_seq
		captains[cid]["status"] = "idle"
		return {"ok": false, "why": "存档写入失败, 派遣已取消"}
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
	# M2: 富化战报(KILLREPORT 数据)
	var report := _build_killreport(mid, mis, def, success, cid)
	# 第一步: 任务出册 + 舰长状态 + 同步落盘(检查结果, 失败放回+中止)
	var snap_done := int(stats["done"])
	var snap_failed := int(stats["failed"])
	var snap_ep := int(exploration["ep"])
	var snap_status: String = captains[cid]["status"] if captains.has(cid) else ""
	var snap_cap: Dictionary = captains[cid].duplicate() if captains.has(cid) else {}
	var snap_inv: Dictionary = inventory.duplicate()  # P1-1: inventory 快照(战利品回滚)
	# The result must share the first durable removal of the mission; otherwise a crash
	# after removal could permanently lose the faction reward before it enters the outbox.
	var faction_result_id := _route_result_id(report)
	var faction_before: Dictionary = pending_faction_results.duplicate(true)
	var faction_partial := not success and _is_partial(success, roll, p)
	if String(def.get("faction_id", "")) != "" and (success or faction_partial):
		var faction_report := report.duplicate(true)
		faction_report["partial"] = faction_partial
		pending_faction_results[faction_result_id] = faction_report
	active.erase(mid)
	if captains.has(cid):
		captains[cid]["status"] = "idle"
		captain_state_changed.emit(cid, "idle")
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		pending_faction_results = faction_before
		active[mid] = mis
		if captains.has(cid):
			captains[cid]["status"] = snap_status
		push_warning("MissionOps: 结算落盘失败, 任务放回重试(mid=%s)" % mid)
		return
	# M2: 部分成功(§5.2: 失败但接近线 → ×0.6 奖励 + 舰长轻伤)
	var partial := false
	if not success:
		partial = _is_partial(success, roll, p)
		report["partial"] = partial
	# 第二步: 发奖励+战利品入仓; 经济存档失败 → 全量回滚(含 inventory, P1-1)
	if success or partial:
		var mul := 1.0 if success else 0.6
		var ep := int(float(def["ep"]) * mul)
		var credits := float(def["credits"]) * mul
		exploration["ep"] += ep
		report["ep"] = ep
		report["credits"] = credits
		stats["done"] += 1
		_give_captain_exp(cid, 30)
		Economy.add_money(credits)
		_apply_loot(report.get("loot", {}))   # P1-1: 战利品在事务内应用(非 _build 时)
		if not _persist_economy():
			Economy.add_money(-credits)
			exploration["ep"] = snap_ep
			stats["done"] = snap_done
			stats["failed"] = snap_failed
			inventory = snap_inv                    # P1-1: inventory 回滚
			active[mid] = mis
			pending_faction_results = faction_before
			if captains.has(cid):
				captains[cid] = snap_cap
				captains[cid]["status"] = snap_status
			if gs:
				gs.save_now()
			_last_report = {}
			push_warning("MissionOps: 经济存档失败, 结算已回滚(mid=%s)" % mid)
			return
	else:
		report["ep"] = 0
		report["credits"] = 0
		stats["failed"] += 1
		_give_captain_exp(cid, 5)
	_last_report = report
	if float(def.get("route_safety_gain", 0.0)) > 0.0 and (success or partial):
		report["route_safety_pending"] = true
		pending_route_results[_route_result_id(report)] = report.duplicate(true)
		_flush_route_results()
	_set_cooldown(mis["task_id"])   # M2: 常驻任务冷却(§5.8)
	if pending_faction_results.has(faction_result_id):
		_flush_faction_results()
	_maybe_discovery(def, int(mis["seed"]))   # M2: 发现物(§5.7)
	if gs:
		gs.touch()
	mission_completed.emit(report)


func _route_result_id(report: Dictionary) -> String:
	return "%s:%d:%.6f" % [report.get("mission_id", ""), int(report.get("seed", 0)), float(report.get("timestamp", 0))]


func _flush_faction_results() -> void:
	if pending_faction_results.is_empty(): return
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now(): return
	for id in pending_faction_results.keys().duplicate():
		if Economy.diplomacy.apply_mission_result(pending_faction_results[id]):
			pending_faction_results.erase(id)
	if gs: gs.touch()


func _flush_route_results() -> void:
	if pending_route_results.is_empty():
		return
	var world := get_node_or_null("/root/WorldState")
	if world == null or not world.has_method("apply_route_mission_result"):
		return
	var gs := get_node_or_null("/root/GameSave")
	# Persist the outbox first. WorldState records the same result ID before acknowledging it.
	if gs and not gs.save_now():
		return
	for id in pending_route_results.keys().duplicate():
		var result: Dictionary = world.apply_route_mission_result(pending_route_results[id])
		if not bool(result.get("ok", false)):
			continue
		if _route_result_id(_last_report) == id:
			_last_report["route_safety_gain"] = float(result.get("gain", 0.0))
			_last_report["route_safety_pending"] = false
		pending_route_results.erase(id)
	if gs:
		gs.touch()


func _give_captain_exp(cid: String, amount: int) -> void:
	if not captains.has(cid):
		return
	var cap: Dictionary = captains[cid]
	# 老练技能加成
	var exp_mul: float = 1.0
	var skills: Dictionary = cap.get("skills", {})
	if skills.has("veteran"):
		var lv: int = int(skills["veteran"])
		exp_mul = MissionDefs.SKILLS["veteran"]["lv%d" % lv].get("exp_mul", 1.0)
	cap["exp"] = int(cap["exp"]) + int(amount * exp_mul)
	var max_lv: int = MissionDefs.TIERS[cap["tier"]]["max_level"]
	while cap["level"] < max_lv:
		var need := int(100.0 * pow(float(cap["level"]), 1.5))
		if int(cap["exp"]) < need:
			break
		cap["exp"] = int(cap["exp"]) - need
		cap["level"] = int(cap["level"]) + 1
		cap["points"] = int(cap.get("points", 0)) + 1   # 升级+1技能点


## 学习技能(花 1 点; 条件: 有余点 + 槽位未满)
## ⚠ 技能效果当前为 placeholder(2026-10-05 船长拍板): 仅入表+扣点, dur_mul/credits_mul 等不接入计算
func learn_skill(cid: String, skill_id: String) -> Dictionary:
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	if not MissionDefs.SKILLS.has(skill_id):
		return {"ok": false, "why": "技能不存在"}
	var cap: Dictionary = captains[cid]
	if int(cap.get("points", 0)) < 1:
		return {"ok": false, "why": "技能点不足"}
	var skills: Dictionary = cap.get("skills", {})
	if skills.has(skill_id):
		return {"ok": false, "why": "已学过此技能"}
	var max_slots: int = MissionDefs.TIERS[cap["tier"]]["skill_slots"]
	if skills.size() >= max_slots:
		return {"ok": false, "why": "技能槽已满(%d/%d)" % [skills.size(), max_slots]}
	skills[skill_id] = 1
	cap["skills"] = skills
	cap["points"] = int(cap["points"]) - 1
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	return {"ok": true}


## 升级技能到 2 级(花 1 点; 条件: 已学 lv1 + 精英槽未满)
func upgrade_skill(cid: String, skill_id: String) -> Dictionary:
	if not captains.has(cid):
		return {"ok": false, "why": "舰长不存在"}
	var cap: Dictionary = captains[cid]
	var skills: Dictionary = cap.get("skills", {})
	if not skills.has(skill_id) or int(skills[skill_id]) != 1:
		return {"ok": false, "why": "此技能未学或已 2 级"}
	if int(cap.get("points", 0)) < 1:
		return {"ok": false, "why": "技能点不足"}
	# 检查精英上限(2 级技能数 ≤ max_elite)
	var elite_count := 0
	for sid in skills:
		if int(skills[sid]) == 2:
			elite_count += 1
	var max_elite: int = MissionDefs.TIERS[cap["tier"]]["max_elite"]
	if elite_count >= max_elite:
		return {"ok": false, "why": "精英技能已满(%d/%d)" % [elite_count, max_elite]}
	skills[skill_id] = 2
	cap["skills"] = skills
	cap["points"] = int(cap["points"]) - 1
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	return {"ok": true}


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
	pending_route_results.clear()
	pending_faction_results.clear()
	_route_retry_at = 0.0
	fleet = {}
	ship_name_counter = 0
	inventory = {}
	board = {"resident_cd": {}, "rotation": [], "rotation_at": 0.0, "rotation_seed": 0}
	discoveries = []
	_refresh_pool()
	_refresh_rotation()


## MVP: 试玩档初始化(只发一次初始资源)
func trial_setup() -> void:
	if trial_initialized:
		return
	trial_initialized = true
	trial_mode = true
	# 初始资金
	Economy.money = 50000.0
	# 初始舰船×2
	Economy.inv["longbow"] = int(Economy.inv.get("longbow", 0)) + 2
	# 初始装备×4(每种1件)
	for eq_id in MissionDefs.EQUIPMENT:
		inventory[eq_id] = int(inventory.get(eq_id, 0)) + 2
	# 初始材料(供T1+升级测试)
	inventory["exp_weapon"] = 5
	inventory["exp_elec"] = 5
	inventory["exp_power"] = 5
	inventory["exp_defense"] = 5
	# 模拟巢穴Lv2
	if Economy.modules.has("hive"):
		Economy.modules["hive"]["level"] = 2
		Economy.modules["hive"]["built"] = true
	print("[MissionOps] 试玩档初始化完成: ₡50000 + 舰船×2 + 装备×8 + 材料×20")


# ═══════════════════════════════════════════════════
# M2: 舰船名册(§14 启用/命名/退役)
# ═══════════════════════════════════════════════════

## 启用舰船: Economy.inv 商品 -1 → 名册 +1, 自动编号(§14)
func commission_ship(def_id: String) -> Dictionary:
	if not GameData.SHIPS.has(def_id):
		return {"ok": false, "why": "船型不存在"}
	# 检查库存(装备了能源才有资格启用? M2 先不卡装备, M3 加)
	var have: int = int(Economy.inv.get(def_id, 0))
	if have < 1:
		return {"ok": false, "why": "库存无此船(需先建造)"}
	Economy.inv[def_id] = have - 1
	ship_name_counter += 1
	var uid := "ship_%03d" % ship_name_counter
	var ship_name := "%03d号" % ship_name_counter
	fleet[uid] = {"def_id": def_id, "name": ship_name,
		"fitted": {"power": "", "elec": "", "weapon": "", "defense": ""}}
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		# 回滚
		Economy.inv[def_id] = have
		ship_name_counter -= 1
		fleet.erase(uid)
		return {"ok": false, "why": "存档写入失败, 启用已取消"}
	if not _persist_economy():
		Economy.inv[def_id] = have
		ship_name_counter -= 1
		fleet.erase(uid)
		if gs:
			gs.save_now()
		return {"ok": false, "why": "经济档写入失败, 启用已取消"}
	return {"ok": true, "uid": uid, "name": ship_name}


## 退役: 自动卸装回仓库, 转回库存商品(§14)
func decommission_ship(uid: String) -> Dictionary:
	if not fleet.has(uid):
		return {"ok": false, "why": "舰船不存在"}
	if is_ship_on_mission(uid):
		return {"ok": false, "why": "在途舰船不可退役"}
	# 完整快照(R6-P1: 保存失败全量回滚, 不复制舰船)
	var ship_snapshot: Dictionary = (fleet[uid] as Dictionary).duplicate(true)
	var teams_snapshot: Dictionary = {}
	var snap_inv := inventory.duplicate(true)
	var snap_econ_inv := Economy.inv.duplicate(true)
	var ship: Dictionary = fleet[uid]
	# 自动卸装
	for slot in ship["fitted"]:
		var eq_id: String = ship["fitted"][slot]
		if eq_id != "":
			inventory[eq_id] = int(inventory.get(eq_id, 0)) + 1
	# 从编队移除
	for tid in teams:
		if teams[tid].get("ship_uids", []).has(uid):
			teams_snapshot[tid] = (teams[tid] as Dictionary).duplicate(true)
			teams[tid]["ship_uids"].erase(uid)
	var def_id: String = ship["def_id"]
	fleet.erase(uid)
	Economy.inv[def_id] = int(Economy.inv.get(def_id, 0)) + 1
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		# missionops 落盘失败 → 回滚(不复制)
		fleet[uid] = ship_snapshot
		inventory = snap_inv
		Economy.inv = snap_econ_inv
		for tid in teams_snapshot:
			teams[tid] = teams_snapshot[tid]
		return {"ok": false, "why": "任务档写入失败, 退役已取消"}
	if not _persist_economy():
		fleet[uid] = ship_snapshot
		inventory = snap_inv
		Economy.inv = snap_econ_inv
		for tid in teams_snapshot:
			teams[tid] = teams_snapshot[tid]
		if gs:
			gs.save_now()
		return {"ok": false, "why": "经济档写入失败, 退役已取消(防复制)"}
	return {"ok": true}


func ship_count() -> int:
	return fleet.size()


func is_ship_on_mission(ship_uid: String) -> bool:
	for mid in active:
		var tid: String = active[mid]["team_id"]
		if teams.has(tid):
			for uid in teams[tid].get("ship_uids", []):
				if uid == ship_uid:
					return true
	return false


# ═══════════════════════════════════════════════════
# M2: 装备系统(§15 安装/卸下/门槛)
# ═══════════════════════════════════════════════════

## 安装装备到舰船
func install_equipment(ship_uid: String, eq_id: String) -> Dictionary:
	if not fleet.has(ship_uid):
		return {"ok": false, "why": "舰船不存在"}
	if not MissionDefs.EQUIPMENT.has(eq_id) and not MissionDefs.EQUIPMENT.has(eq_id.replace("_up", "")):
		return {"ok": false, "why": "装备不存在"}
	if is_ship_on_mission(ship_uid):
		return {"ok": false, "why": "在途舰船不可换装"}
	if int(inventory.get(eq_id, 0)) < 1:
		return {"ok": false, "why": "库存无此装备"}
	var base_id := eq_id.replace("_up", "")   # R6-P2: T1+ 用基础定义
	var eq: Dictionary = MissionDefs.EQUIPMENT[base_id]
	var slot: String = eq["slot"]
	var ship: Dictionary = fleet[ship_uid]
	# 快照(回滚用)
	var snap_old: String = ship["fitted"][slot]
	var snap_inv := inventory.duplicate()
	# 卸下旧装备回仓
	if snap_old != "":
		inventory[snap_old] = int(inventory.get(snap_old, 0)) + 1
	# 安装新的
	inventory[eq_id] = int(inventory.get(eq_id, 0)) - 1
	ship["fitted"][slot] = eq_id
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		ship["fitted"][slot] = snap_old
		inventory = snap_inv
		return {"ok": false, "why": "存档写入失败, 装备已还原"}
	return {"ok": true, "replaced": snap_old}


## 卸下装备
func remove_equipment(ship_uid: String, slot: String) -> Dictionary:
	if not fleet.has(ship_uid):
		return {"ok": false, "why": "舰船不存在"}
	if is_ship_on_mission(ship_uid):
		return {"ok": false, "why": "在途舰船不可换装"}
	var ship: Dictionary = fleet[ship_uid]
	var eq_id: String = ship["fitted"].get(slot, "")
	if eq_id == "":
		return {"ok": false, "why": "该槽位为空"}
	var snap_inv := inventory.duplicate()
	inventory[eq_id] = int(inventory.get(eq_id, 0)) + 1
	ship["fitted"][slot] = ""
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		ship["fitted"][slot] = eq_id
		inventory = snap_inv
		return {"ok": false, "why": "存档写入失败, 卸下已还原"}
	return {"ok": true, "eq_id": eq_id}


## 统计编队装备(slot → count)
func get_team_equipment(team_id: String) -> Dictionary:
	var result := {"power": 0, "elec": 0, "weapon": 0, "defense": 0}
	if not teams.has(team_id):
		return result
	for uid in teams[team_id].get("ship_uids", []):
		if fleet.has(uid):
			for slot in fleet[uid]["fitted"]:
				if fleet[uid]["fitted"][slot] != "":
					result[slot] = int(result.get(slot, 0)) + 1
	return result


## 装备门槛检查(§15.4): 返回缺口描述(空=通过)
func check_equip_req(task_id: String, team_id: String) -> Array[String]:
	if not MissionDefs.TASKS.has(task_id):
		return []
	var def: Dictionary = MissionDefs.TASKS[task_id]
	var equipped: Dictionary = get_team_equipment(team_id)
	return MissionDefs.equip_gap(def, equipped)


## 给测试/作弊口: 直接入库装备
func grant_equipment(eq_id: String, count: int = 1) -> void:
	inventory[eq_id] = int(inventory.get(eq_id, 0)) + count


## 给测试/作弊口: 直接入库远征材料
func grant_material(mat_id: String, count: int = 1) -> void:
	inventory[mat_id] = int(inventory.get(mat_id, 0)) + count


# ═══════════════════════════════════════════════════
# M2: 三层任务板(§5.8 常驻/轮换/发现)
# ═══════════════════════════════════════════════════

func _refresh_rotation() -> void:
	board["rotation_seed"] = int(_now() * 1000.0) ^ (ship_name_counter * 31337)
	board["rotation_at"] = _now() + MissionDefs.ROTATION_REFRESH_SEC
	var rng := RandomNumberGenerator.new()
	rng.seed = int(board["rotation_seed"])
	var pool: Array = MissionDefs.ROTATION_POOL.duplicate()
	board["rotation"] = []
	for i in mini(MissionDefs.ROTATION_SLOTS, pool.size()):
		var idx := rng.randi_range(0, pool.size() - 1)
		board["rotation"].append(pool[idx])
		pool.remove_at(idx)


## 当前可见任务列表(常驻+轮换, 排除冷却中)
func get_board_tasks() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var now := _now()
	# 常驻层
	for tid in MissionDefs.RESIDENT_TASKS:
		if MissionDefs.TASKS.has(tid):
			var def: Dictionary = MissionDefs.TASKS[tid]
			var cd_until: float = float(board["resident_cd"].get(tid, 0.0))
			var on_cd := now < cd_until
			result.append({"id": tid, "layer": "resident", "def": def,
				"cooldown": on_cd, "cd_remain": maxf(0.0, cd_until - now)})
	# 轮换层
	for tid in board["rotation"]:
		if MissionDefs.TASKS.has(tid):
			var def: Dictionary = MissionDefs.TASKS[tid]
			result.append({"id": tid, "layer": "rotation", "def": def,
				"cooldown": false, "cd_remain": 0.0})
	return result


## 结算后设置常驻冷却(§5.8: 时长 × 1.5)
func _set_cooldown(task_id: String) -> void:
	if task_id in MissionDefs.RESIDENT_TASKS:
		var def: Dictionary = MissionDefs.TASKS[task_id]
		board["resident_cd"][task_id] = _now() + float(def["dur_sec"]) * MissionDefs.COOLDOWN_MULT


# ═══════════════════════════════════════════════════
# M2: 战报富化(KILLREPORT 数据准备)
# ═══════════════════════════════════════════════════

func _build_killreport(mid: String, mis: Dictionary, def: Dictionary,
		success: bool, cid: String) -> Dictionary:
	var report := {
		"mission_id": mid, "task_id": mis["task_id"],
		"task": def["name"], "success": success,
		"seed": int(mis["seed"]), "duration": float(mis["dur"]),
		"timestamp": _now(),
	}
	# 参战方
	var members: Array[Dictionary] = []
	var cap: Dictionary = captains.get(cid, {})
	members.append({"name": cap.get("name", "?"), "role": "队长",
		"ship": "旗舰", "damage": 0, "final_blow": true})
	var ship_count: int = teams.get(mis["team_id"], {}).get("ship_uids", []).size()
	for i in range(ship_count - 1):
		members.append({"name": "僚机 %d" % (i + 1), "role": "队员",
			"ship": "护卫", "damage": 0, "final_blow": false})
	report["members"] = members
	# 受害者(按任务类型; P1-3: 用 mission seed 派生, 可复现)
	report["victim"] = {"name": _victim_name(def, int(mis["seed"])),
		"ship": _victim_ship(def), "corporation": _victim_corp(def)}
	# 掉落清单
	if success:
		report["loot"] = _roll_loot(mid, mis, def)
	else:
		report["loot"] = {"destroyed": [], "dropped": []}
	return report


func _victim_name(def: Dictionary, seed_v: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v ^ hash(def["name"])   # P1-3: mission seed 派生(可复现)
	return MissionDefs.NICKS[rng.randi_range(0, MissionDefs.NICKS.size() - 1)]


func _victim_ship(def: Dictionary) -> String:
	match def["kind"]:
		"combat": return "劫掠者级快船"
		"survey", "signal": return "深空探测器"
		"salvage": return "废弃船体"
		"escort": return "科考船"
		_: return "未知目标"


func _victim_corp(def: Dictionary) -> String:
	match def["kind"]:
		"combat": return "开拓地私掠团"
		"salvage": return "深空打捞协会"
		_: return "深空探索协会"


# ═══════════════════════════════════════════════════
# M2: T1 升级(§15.3 就地升级) + 碎片兑换(§5.7)
# ═══════════════════════════════════════════════════

## T1 就地升级: T1 件 + 远征材料 ×N + ₡ → T1+(§15.3, ≈1.25×)
func upgrade_equipment(eq_id: String) -> Dictionary:
	if not MissionDefs.EQUIPMENT.has(eq_id):
		return {"ok": false, "why": "装备不存在"}
	if int(inventory.get(eq_id, 0)) < 1:
		return {"ok": false, "why": "库存无此装备"}
	var eq: Dictionary = MissionDefs.EQUIPMENT[eq_id]
	var mat_id: String = ""
	for mid in MissionDefs.EXP_MATERIALS:
		if MissionDefs.EXP_MATERIALS[mid]["slot"] == eq["slot"]:
			mat_id = mid
			break
	var mat_need := 5   # [占位] T1+ 需要 5 个对应材料
	if int(inventory.get(mat_id, 0)) < mat_need:
		return {"ok": false, "why": "材料不足: %s %d/%d" % [
			MissionDefs.EXP_MATERIALS[mat_id]["label"],
			int(inventory.get(mat_id, 0)), mat_need]}
	var cost: float = eq["price"] * 0.5   # 升级费 = 半价
	if Economy.money < cost:
		return {"ok": false, "why": "资金不足(₡%d)" % int(cost)}
	# 执行(带快照回滚)
	var snap_inv := inventory.duplicate()
	var snap_money: float = Economy.money
	inventory[eq_id] = int(inventory[eq_id]) - 1
	inventory[mat_id] = int(inventory[mat_id]) - mat_need
	var up_id := eq_id + "_up"
	inventory[up_id] = int(inventory.get(up_id, 0)) + 1
	Economy.add_money(-cost)
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		inventory = snap_inv
		Economy.money = snap_money
		return {"ok": false, "why": "任务档写入失败, 升级已取消"}
	if not _persist_economy():
		inventory = snap_inv
		Economy.money = snap_money
		if gs:
			gs.save_now()
		return {"ok": false, "why": "经济档写入失败, 升级已取消"}
	return {"ok": true, "upgraded_to": up_id}


## 碎片 → 逆向素材(§5.7: 凑满 N 片兑换)
func exchange_fragments() -> Dictionary:
	var frag_count := int(inventory.get("frag_generic", 0))
	var need := 5   # [占位] 5 片换 1 份
	if frag_count < need:
		return {"ok": false, "why": "碎片不足(%d/%d)" % [frag_count, need]}
	var snap_inv := inventory.duplicate()
	inventory["frag_generic"] = frag_count - need
	inventory["reverse_material"] = int(inventory.get("reverse_material", 0)) + 1
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		inventory = snap_inv
		return {"ok": false, "why": "存档写入失败, 兑换已取消"}
	return {"ok": true}


## M2: 部分成功(§5.2 结算区间第三档)
func _is_partial(success: bool, roll: float, p: float) -> bool:
	if success:
		return false
	return roll < p + (1.0 - p) * 0.5   # 失败但接近成功线 → 部分成功


# ═══════════════════════════════════════════════════
# M2: 发现物图鉴(§5.7 简版)
# ═══════════════════════════════════════════════════

var discoveries: Array = []   # JSON 回放不保留 Array[Dictionary] 类型, 用普通 Array

func _maybe_discovery(def: Dictionary, seed_v: int) -> void:
	# 勘测/信号类必得发现物; 其余 15% 概率
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v + 2
	var p: float = 1.0 if def["kind"] in ["survey", "signal"] else 0.15
	if rng.randf() < p:
		var disc := {
			"kind": def["kind"],
			"title": _gen_discovery_title(def, rng),
			"found_at": _now(),
			"task": def["name"],
		}
		discoveries.append(disc)


func _gen_discovery_title(def: Dictionary, rng: RandomNumberGenerator) -> String:
	var prefixes := ["远古", "废弃", "未知", "加密", "损坏的"]
	var nouns := ["信标", "残骸", "数据核心", "星图", "通讯记录"]
	return prefixes[rng.randi_range(0, prefixes.size()-1)] + nouns[rng.randi_range(0, nouns.size()-1)]


func discovery_count() -> int:
	return discoveries.size()


# ═══════════════════════════════════════════════════
# M2: 装备掉落概率(战斗类 30-60%)
# ═══════════════════════════════════════════════════

## M2: 战利品掷骰(纯函数,不修改 inventory——副作用在 _resolve 事务内应用)
func _roll_loot(mid: String, mis: Dictionary, def: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(mis["seed"]) + 1
	var destroyed: Array[Dictionary] = []
	var dropped: Array[Dictionary] = []
	var mat_id: String = MissionDefs.drop_material(def["kind"])
	var mat_label: String = MissionDefs.EXP_MATERIALS.get(mat_id, {}).get("label", mat_id)
	var diff: String = def["diff"]
	var mat_qty: int = {"D1": 1, "D2": 2, "D3": 3, "D4": 4}.get(diff, 1)
	if mat_qty > 0:
		dropped.append({"id": mat_id, "label": mat_label, "qty": mat_qty, "slot": "货舱"})
	var frag_p: float = {"D1": 0.30, "D2": 0.40, "D3": 0.50, "D4": 0.60}.get(diff, 0.30)
	if rng.randf() < frag_p:
		dropped.append({"id": "frag_generic", "label": "蓝图碎片", "qty": 1, "slot": "货舱"})
	if def["kind"] == "combat":
		destroyed.append({"id": "pirate_mod", "label": "海盗改装火控", "qty": 1, "slot": "高槽"})
	return {"destroyed": destroyed, "dropped": dropped}


## M2: 将战利品入仓(只在事务成功后调用)
func _apply_loot(loot: Dictionary) -> void:
	for item in loot.get("dropped", []):
		var iid: String = item["id"]
		inventory[iid] = int(inventory.get(iid, 0)) + int(item["qty"])


# ── 对外只读 ──

func last_report() -> Dictionary:
	return _last_report


func ep() -> int:
	return int(exploration["ep"])
