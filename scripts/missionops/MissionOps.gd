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
var _ui: Node = null
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
		"fleet": fleet, "ship_name_counter": ship_name_counter,
		"inventory": inventory, "board": board,
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
	# M2 字段
	fleet = data.get("fleet", {})
	ship_name_counter = int(data.get("ship_name_counter", 0))
	inventory = data.get("inventory", {})
	var board_d: Variant = data.get("board", null)
	if typeof(board_d) == TYPE_DICTIONARY:
		board = board_d
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
		"level": 1, "exp": 0, "status": "idle"}
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
	teams[tid] = {"name": team_name, "captain_id": cid}
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
	var def: Dictionary = MissionDefs.TASKS[task_id]
	# 同步落盘+回滚(自查 P2: 崩溃丢派遣而非幽灵在途)
	var snap_seq := _mis_seq
	_mis_seq += 1
	var mid := "mis_%03d" % _mis_seq
	var seed_v := seed_override if seed_override >= 0 else int(_now() * 1000.0) ^ (_mis_seq * 7919)
	var now := _now()
	var dur := float(def["dur_sec"])
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
	active.erase(mid)
	if captains.has(cid):
		captains[cid]["status"] = "idle"
		captain_state_changed.emit(cid, "idle")
	var gs := get_node_or_null("/root/GameSave")
	if gs and not gs.save_now():
		active[mid] = mis
		if captains.has(cid):
			captains[cid]["status"] = snap_status
		push_warning("MissionOps: 结算落盘失败, 任务放回重试(mid=%s)" % mid)
		return
	# 第二步: 发奖励; 经济存档失败 → 全量回滚, 任务放回重试(R5-P1)
	if success:
		var ep := int(def["ep"])
		var credits := float(def["credits"])
		exploration["ep"] += ep
		report["ep"] = ep
		report["credits"] = credits
		stats["done"] += 1
		_give_captain_exp(cid, 30)
		Economy.add_money(credits)
		if not _persist_economy():
			Economy.add_money(-credits)
			exploration["ep"] = snap_ep
			stats["done"] = snap_done
			stats["failed"] = snap_failed
			active[mid] = mis
			if captains.has(cid):
				captains[cid] = snap_cap            # 恢复完整舰长(含exp/level, 自查P2)
				captains[cid]["status"] = snap_status
			if gs:
				gs.save_now()
			_last_report = {}                       # 清残留报告(P3)
			push_warning("MissionOps: 经济存档失败, 结算已回滚(mid=%s)" % mid)
			return
	else:
		report["ep"] = 0
		report["credits"] = 0
		stats["failed"] += 1
		_give_captain_exp(cid, 5)
	_last_report = report
	_set_cooldown(mis["task_id"])   # M2: 常驻任务冷却(§5.8)
	if gs:
		gs.touch()
	mission_completed.emit(report)


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
	fleet = {}
	ship_name_counter = 0
	inventory = {}
	board = {"resident_cd": {}, "rotation": [], "rotation_at": 0.0, "rotation_seed": 0}
	_refresh_pool()
	_refresh_rotation()


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
	var ship: Dictionary = fleet[uid]
	# 自动卸装
	for slot in ship["fitted"]:
		var eq_id: String = ship["fitted"][slot]
		if eq_id != "":
			inventory[eq_id] = int(inventory.get(eq_id, 0)) + 1
	# 从编队移除
	for tid in teams:
		if teams[tid].get("ship_uids", []).has(uid):
			teams[tid]["ship_uids"].erase(uid)
	var def_id: String = ship["def_id"]
	fleet.erase(uid)
	Economy.inv[def_id] = int(Economy.inv.get(def_id, 0)) + 1
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	_persist_economy()
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
	if not MissionDefs.EQUIPMENT.has(eq_id):
		return {"ok": false, "why": "装备不存在"}
	if is_ship_on_mission(ship_uid):
		return {"ok": false, "why": "在途舰船不可换装"}
	if int(inventory.get(eq_id, 0)) < 1:
		return {"ok": false, "why": "库存无此装备"}
	var eq: Dictionary = MissionDefs.EQUIPMENT[eq_id]
	var slot: String = eq["slot"]
	var ship: Dictionary = fleet[ship_uid]
	# 卸下旧装备回仓
	var old: String = ship["fitted"][slot]
	if old != "":
		inventory[old] = int(inventory.get(old, 0)) + 1
	# 安装新的
	inventory[eq_id] = int(inventory.get(eq_id, 0)) - 1
	ship["fitted"][slot] = eq_id
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
	return {"ok": true, "replaced": old}


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
	inventory[eq_id] = int(inventory.get(eq_id, 0)) + 1
	ship["fitted"][slot] = ""
	var gs := get_node_or_null("/root/GameSave")
	if gs:
		gs.save_now()
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
	# 受害者(按任务类型)
	report["victim"] = {"name": _victim_name(def), "ship": _victim_ship(def),
		"corporation": _victim_corp(def)}
	# 掉落清单
	if success:
		report["loot"] = _roll_loot(mid, mis, def)
	else:
		report["loot"] = {"destroyed": [], "dropped": []}
	return report


func _victim_name(def: Dictionary) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_now()) ^ hash(def["name"])
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


func _roll_loot(mid: String, mis: Dictionary, def: Dictionary) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(mis["seed"]) + 1   # 不同掷骰位置
	var destroyed: Array[Dictionary] = []
	var dropped: Array[Dictionary] = []
	# 远征材料(§15.3: 类型由任务类型决定, 数量由难度)
	var mat_id: String = MissionDefs.drop_material(def["kind"])
	var mat_label: String = MissionDefs.EXP_MATERIALS.get(mat_id, {}).get("label", mat_id)
	var diff: String = def["diff"]
	var mat_qty: int = {"D1": 1, "D2": 2, "D3": 3, "D4": 4}.get(diff, 1)
	if mat_qty > 0:
		dropped.append({"id": mat_id, "label": mat_label, "qty": mat_qty, "slot": "货舱"})
		inventory[mat_id] = int(inventory.get(mat_id, 0)) + mat_qty
	# 蓝图碎片(30-60% 概率, §5.5)
	var frag_p: float = {"D1": 0.30, "D2": 0.40, "D3": 0.50, "D4": 0.60}.get(diff, 0.30)
	if rng.randf() < frag_p:
		dropped.append({"id": "frag_generic", "label": "蓝图碎片", "qty": 1, "slot": "货舱"})
		inventory["frag_generic"] = int(inventory.get("frag_generic", 0)) + 1
	# 焚毁物(战斗类)
	if def["kind"] == "combat":
		destroyed.append({"id": "pirate_mod", "label": "海盗改装火控", "qty": 1, "slot": "高槽"})
	return {"destroyed": destroyed, "dropped": dropped}


# ── 对外只读 ──

func last_report() -> Dictionary:
	return _last_report


func ep() -> int:
	return int(exploration["ep"])
