extends Node

signal changed
## Combat integration: attacker faction, target visitor (null for fleet vs fleet), mutual patrol encounter.
signal hostile_encounter(attacker: String, target: Freighter, patrol_vs_patrol: bool)

const FACTIONS := ["southern", "empire"]
const BLUEPRINTS := {"empire": ["empireReactiveArmor", "empireSiegeControl", "empireLancer"],
	"southern": ["allianceShieldMatrix", "allianceRepairSwarm", "allianceKite"]}
const STAGE_POINTS := 100.0
const BRIBE_PRICE := 1500.0
const PATROL_DURATION := 180.0
const PATROL_COOLDOWN := 480.0
const TRADE_THRESHOLD := 5000.0
const TRADE_SUSPICION := 20.0
const CONTRACT_SUSPICION := 35.0

var eco: Node
var suspicion := {"southern": 0.0, "empire": 0.0}
var inspectors := {"southern": false, "empire": false}
var patrols := {}
var trade_progress := {"southern": 0.0, "empire": 0.0}
var contracts: Array = []
var board_cycle := -1
var convoy_left := 45.0
var next_convoy := "southern"
var _events := {}
var _dirty := false
var _clock := 0.0
var _encounter_clock := 0.0
var _presence: Node3D


func _ready() -> void:
	call_deferred("_connect_missions")


func _connect_missions() -> void:
	var missions := get_node_or_null("/root/MissionOps")
	if missions and not missions.mission_completed.is_connected(_mission_completed):
		missions.mission_completed.connect(_mission_completed)


func faction_name(fid: String) -> String:
	return "联盟" if fid == "southern" else "帝国"


func opposite(fid: String) -> String:
	return "empire" if fid == "southern" else "southern"


func stage(fid: String) -> int:
	return clampi(floori(float(suspicion.get(fid, 0.0)) / STAGE_POINTS), 0, 3)


func stage_name(fid: String) -> String:
	return ["暂无审查", "Ⅰ 审查官来访", "Ⅱ 审查舰队", "Ⅲ 高度怀疑（后续开放）"][stage(fid)]


func reset() -> void:
	suspicion = {"southern": 0.0, "empire": 0.0}
	inspectors = {"southern": false, "empire": false}
	trade_progress = {"southern": 0.0, "empire": 0.0}
	patrols = {"southern": {"left": 0.0, "cooldown": 0.0, "serial": 0}, "empire": {"left": 0.0, "cooldown": 0.0, "serial": 0}}
	contracts.clear()
	_events.clear()
	board_cycle = -1
	convoy_left = 45.0
	next_convoy = "southern"
	_dirty = false
	_clock = 0.0
	changed.emit()


func get_state() -> Dictionary:
	return {"suspicion": suspicion.duplicate(true), "inspectors": inspectors.duplicate(true),
		"patrols": patrols.duplicate(true), "trade_progress": trade_progress.duplicate(true),
		"contracts": contracts.duplicate(true), "board_cycle": board_cycle, "convoy_left": convoy_left,
		"next_convoy": next_convoy, "events": _events.duplicate(true)}


func apply_state(data: Dictionary) -> void:
	reset()
	for fid in FACTIONS:
		suspicion[fid] = clampf(float(data.get("suspicion", {}).get(fid, 0.0)), 0.0, 300.0)
		inspectors[fid] = bool(data.get("inspectors", {}).get(fid, false))
		trade_progress[fid] = maxf(0.0, float(data.get("trade_progress", {}).get(fid, 0.0)))
		var saved: Dictionary = data.get("patrols", {}).get(fid, {})
		patrols[fid] = {"left": clampf(float(saved.get("left", 0.0)), 0.0, PATROL_DURATION),
			"cooldown": maxf(0.0, float(saved.get("cooldown", 0.0))), "serial": int(saved.get("serial", 0))}
	contracts = data.get("contracts", []).duplicate(true)
	board_cycle = int(data.get("board_cycle", -1))
	convoy_left = maxf(0.0, float(data.get("convoy_left", 45.0)))
	next_convoy = String(data.get("next_convoy", "southern"))
	if not FACTIONS.has(next_convoy): next_convoy = "southern"
	_events = data.get("events", {}).duplicate(true)
	changed.emit()


func ensure_board() -> void:
	var cycle := floori(float(eco.day - 1) / 3.0)
	if cycle == board_cycle:
		return
	board_cycle = cycle
	# Accepted orders never expire. Retain recent receipts, replace only unaccepted offers.
	contracts = contracts.filter(func(c): return c.status == "accepted" or (c.status == "completed" and int(c.cycle) >= cycle - 3))
	var needs := [{"kineticAmmo": 200}, {"thermalMissile": 100}, {"truss": 4, "cabin": 2}]
	for fid in FACTIONS:
		for index in 3:
			var cost: Dictionary = needs[(cycle + index) % needs.size()].duplicate()
			var value := 0.0
			for gid in cost: value += int(cost[gid]) * GameData.good_unit_price(gid)
			var reward: String = BLUEPRINTS[fid][index]
			contracts.append({"id": "%s:%d:%d" % [fid, cycle, index], "faction": fid, "cycle": cycle,
				"title": "%s · %s生产委托" % [faction_name(fid), GameData.good_name(String(cost.keys()[0]))],
				"cost": cost, "money": roundf(value * 1.35), "blueprint": reward, "status": "available"})
	_touch()


func contract(id: String) -> Dictionary:
	for item in contracts:
		if item.id == id: return item
	return {}


func accept(id: String) -> String:
	var item := contract(id)
	if item.is_empty() or item.status != "available": return "该委托不可接受"
	var accepted := contracts.filter(func(c): return c.status == "accepted").size()
	if accepted >= 6: return "最多同时接受 6 份委托"
	item.status = "accepted"
	if not eco.save_game():
		item.status = "available"
		return "存档失败，委托尚未接受"
	changed.emit()
	return ""


func deliver(id: String) -> String:
	var item := contract(id)
	if item.is_empty() or item.status != "accepted": return "请先接受该委托"
	if not eco.can_pay(item.cost): return "库存不足，无法交付"
	var before := get_state()
	var inventory: Dictionary = eco.inv.duplicate(true)
	var money: float = eco.money
	var blueprints: Dictionary = eco.blueprints.duplicate(true)
	var inbox_before: Dictionary = eco.inbox.get_state()
	var old_stage := stage(opposite(item.faction))
	eco.pay(item.cost)
	eco.add_money(float(item.money))
	eco.blueprints[item.blueprint] = true
	item.status = "completed"
	_raise(opposite(item.faction), CONTRACT_SUSPICION)
	_letter(item.faction, "生产委托交付确认", "已收到贵站交付的物资。报酬 %s 已到账，并授予【%s】永久制造蓝图。\n\n本次援助使%s的怀疑增加 %.0f 点。" % [
		EconTheme.money(item.money), GameData.good_name(item.blueprint), faction_name(opposite(item.faction)), CONTRACT_SUSPICION], "contract:" + id)
	_announce_transition(opposite(item.faction), old_stage)
	if not eco.save_game():
		eco.inv = inventory
		eco.money = money
		eco.blueprints = blueprints
		apply_state(before)
		eco.inbox.apply_state(inbox_before)
		_dirty = true
		eco.inventory_changed.emit()
		eco.money_changed.emit()
		return "存档失败，交付与奖励已撤回"
	eco.research_changed.emit()
	_touch()
	return ""


func bribe(fid: String) -> String:
	if not FACTIONS.has(fid) or not inspectors[fid] or stage(fid) != 1: return "目前没有可接洽的审查官"
	if eco.money < BRIBE_PRICE: return "资金不足"
	var before := get_state()
	var money: float = eco.money
	var inbox_before: Dictionary = eco.inbox.get_state()
	eco.try_spend(BRIBE_PRICE)
	suspicion[fid] = maxf(0.0, float(suspicion[fid]) - STAGE_POINTS)
	inspectors[fid] = false
	_letter(fid, "审查结案通知", "本次审查已结案。该势力怀疑值减少 100 点，审查官已离站。")
	if not eco.save_game():
		eco.money = money
		apply_state(before)
		eco.inbox.apply_state(inbox_before)
		_dirty = true
		eco.money_changed.emit()
		return "存档失败，贿赂已撤回"
	_touch()
	return ""


func _raise(fid: String, amount: float) -> void:
	var old := stage(fid)
	suspicion[fid] = clampf(float(suspicion[fid]) + amount, 0.0, 300.0)
	if old < 1 and stage(fid) == 1: inspectors[fid] = true
	if old < 2 and stage(fid) >= 2:
		inspectors[fid] = false
		_launch_patrol(fid)


func _launch_patrol(fid: String) -> void:
	patrols[fid].left = PATROL_DURATION
	patrols[fid].cooldown = PATROL_COOLDOWN
	patrols[fid].serial = int(patrols[fid].serial) + 1


func add_suspicion(fid: String, amount: float, event_id := "") -> bool:
	if not FACTIONS.has(fid) or amount <= 0.0 or (event_id != "" and _events.has(event_id)): return false
	var old := stage(fid)
	_raise(fid, amount)
	if event_id != "": _remember(event_id)
	_announce_transition(fid, old)
	_touch()
	return true


func _announce_transition(fid: String, old: int) -> void:
	if old < 2 and stage(fid) >= 2:
		_letter(fid, "审查舰队进驻通知", "由于贵站持续向对方提供物资，我方审查舰队将在空间站附近驻留 180 秒。对方访客在此期间可能遭到拦截。")
	elif old < 1 and stage(fid) == 1:
		_letter(fid, "审查官来访", "贵站与对方的往来已引起怀疑。审查官已经抵达，可在【生产委托】中接洽。")


func record_trade(fid: String, value: float) -> void:
	if not FACTIONS.has(fid) or value <= 0.0: return
	trade_progress[fid] = float(trade_progress[fid]) + value
	var batches := floori(float(trade_progress[fid]) / TRADE_THRESHOLD)
	if batches > 0:
		trade_progress[fid] = fmod(float(trade_progress[fid]), TRADE_THRESHOLD)
		add_suspicion(opposite(fid), batches * TRADE_SUSPICION)
	_touch()


func _mission_completed(report: Dictionary) -> void:
	apply_mission_result(report)


## MissionOps persists an outbox before calling this. Acknowledgement requires a durable economy save.
func apply_mission_result(report: Dictionary) -> bool:
	if not report.get("success", false) and not report.get("partial", false): return true
	var fid: String = MissionDefs.TASKS.get(report.get("task_id", ""), {}).get("faction_id", "")
	if not FACTIONS.has(fid): return true
	var key := "mission:%s:%d:%.6f" % [report.get("mission_id", ""), int(report.get("seed", 0)), float(report.get("timestamp", 0.0))]
	if _events.has(key): return true
	var before := get_state()
	var blueprint_before: Dictionary = eco.blueprints.duplicate(true)
	var inbox_before: Dictionary = eco.inbox.get_state()
	var old_stage := stage(opposite(fid))
	_raise(opposite(fid), 25.0 if report.get("success", false) else 15.0)
	_remember(key)
	if report.get("success", false):
		var reward: String = MissionDefs.TASKS.get(report.get("task_id", ""), {}).get("blueprint_reward", "")
		if reward != "":
			eco.blueprints[reward] = true
			_letter(fid, "行动回报与蓝图授权", "感谢贵站协助我方行动。现授予【%s】永久制造蓝图。" % GameData.good_name(reward), "faction-reward:" + key)
	_announce_transition(opposite(fid), old_stage)
	if not eco.save_game():
		eco.blueprints = blueprint_before
		apply_state(before)
		eco.inbox.apply_state(inbox_before)
		_dirty = true
		return false
	eco.research_changed.emit()
	_touch()
	return true


## Called by the future damage system only after a real civilian loss. Patrol battles never blame the station.
func report_convoy_loss(victim: String, attacker: String, event_id: String, patrol_vs_patrol := false) -> bool:
	if patrol_vs_patrol or not FACTIONS.has(victim) or not FACTIONS.has(attacker) or victim == attacker or event_id == "": return false
	var key := "loss:" + event_id
	if _events.has(key): return false
	var before := get_state()
	var inbox_before: Dictionary = eco.inbox.get_state()
	add_suspicion(victim, 45.0, key)
	_letter(victim, "问责信函：涉嫌通敌", "致空间站管理者：\n\n我方工业舰在贵站附近遭到%s审查舰队袭击并蒙受损失。我方怀疑贵站为敌方提供便利，要求贵站解释与其往来。\n\n我方怀疑值增加 45 点。\n\n附：现场态势图。" % faction_name(attacker), key, "incident_" + victim)
	if not eco.save_game():
		apply_state(before)
		eco.inbox.apply_state(inbox_before)
		_dirty = true
		return false
	_touch()
	return true


func _remember(key: String) -> void:
	_events[key] = true
	while _events.size() > 512: _events.erase(_events.keys()[0])


func _letter(fid: String, title: String, body: String, source_id := "", illustration := "") -> void:
	eco.inbox.receive(title, body, "faction", faction_name(fid) + "联络处", "warn", fid, source_id, illustration)


func _touch() -> void:
	_dirty = true
	changed.emit()


func bind_world(world: Node3D) -> void:
	_presence = preload("res://scripts/economy/FactionPresence.gd").new()
	_presence.relations = self
	_presence.world = world
	world.add_child(_presence)


func try_convoy(fid: String) -> bool:
	if not FACTIONS.has(fid) or eco.module_level("hangar") <= 0 or eco.berths_available() <= 0 or eco.fuel < 5.0: return false
	var tier := "small" if eco.module_level("hangar") == 1 else ("standard" if eco.module_level("hangar") == 2 else "heavy")
	var visitor := Freighter.make(tier, false, eco.rng, eco.price_mod, eco.demand_mod(), "industrial")
	visitor.faction_id = fid
	visitor.visit_role = "convoy"
	visitor.name = faction_name(fid) + "采购商队 · 工业舰"
	var goods: Array = GameData.WARSHIP_PRIORITY.duplicate() + BLUEPRINTS[fid]
	visitor.buy_offers = visitor.buy_offers.filter(func(o): return not goods.has(o.goods))
	for gid in goods:
		var batch: int = GameData.PRODUCTS.get(gid, {}).get("batch", 1)
		visitor.buy_offers.append(visitor._offer(gid, maxf(2.0, batch * 2.0), eco.rng, 1.0, eco.price_mod))
	if not eco.dock_special_freighter(visitor): return false
	eco.fuel -= 5.0
	eco.fuel_changed.emit()
	eco.post_event(visitor.name + "到港，正在采购物资", "good", {"category": "faction", "sender": faction_name(fid) + "商贸处", "faction_id": fid})
	return true


func tick(delta: float) -> void:
	ensure_board()
	convoy_left -= delta
	if convoy_left <= 0.0:
		if try_convoy(next_convoy):
			next_convoy = opposite(next_convoy)
			convoy_left = 120.0
		else: convoy_left = 10.0
	for fid in FACTIONS:
		var active: bool = float(patrols[fid].left) > 0.0
		patrols[fid].left = maxf(0.0, float(patrols[fid].left) - delta)
		patrols[fid].cooldown = maxf(0.0, float(patrols[fid].cooldown) - delta)
		if active:
			_dirty = true
			if float(patrols[fid].left) == 0.0: changed.emit()
		if stage(fid) >= 2 and float(patrols[fid].cooldown) <= 0.0:
			_launch_patrol(fid)
			_touch()
	_encounter_clock += delta
	if _encounter_clock >= 1.0:
		_encounter_clock = 0.0
		_check_encounters()
	_clock += delta
	if _clock >= 3.0:
		_clock = 0.0
		if _dirty and eco.save_game(): _dirty = false


func _check_encounters() -> void:
	if float(patrols.empire.left) > 0.0 and float(patrols.southern.left) > 0.0:
		var mutual := "patrol:%d:%d" % [patrols.empire.serial, patrols.southern.serial]
		if not _events.has(mutual):
			_remember(mutual)
			hostile_encounter.emit("empire", null, true)
			eco.post_event("联盟与帝国审查舰队发生敌对接触，此事件不增加对空间站的怀疑", "warn")
			_dirty = true
	for fid in FACTIONS:
		if float(patrols[fid].left) <= 0.0: continue
		for visitor in eco.berths:
			if visitor.faction_id != opposite(fid): continue
			var key := "encounter:%s:%d:%d" % [fid, patrols[fid].serial, visitor.get_instance_id()]
			if _events.has(key): continue
			_remember(key)
			hostile_encounter.emit(fid, visitor, false)
			eco.post_event("%s审查舰队正在拦截%s访客" % [faction_name(fid), faction_name(visitor.faction_id)], "warn")
			_dirty = true
