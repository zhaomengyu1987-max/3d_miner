extends Node3D

var failures := 0
var assertions := 0
var diplomacy: Node
var encounters: Array = []
const SAVE := "user://faction_relations_test.json"
const FAILED_SAVE := "user://no_faction_test_directory/save.json"


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("FACTION_RELATIONS: " + message)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.inbox.set_process(false)
	Economy._world.set_process(false)
	WorldState.set_process(false)
	MissionOps.set_process(false)
	Economy.save_path = SAVE
	WorldState._save_path = "user://faction_relations_world.json"
	diplomacy = Economy.diplomacy
	diplomacy.hostile_encounter.connect(func(attacker: String, visitor: Freighter, mutual: bool):
		encounters.append({"attacker": attacker, "visitor": visitor, "mutual": mutual}))
	_test_initial_and_board()
	_test_delivery()
	_test_transactions_fail_closed()
	_test_bribe()
	_test_stages_and_encounters()
	_test_faction_trade()
	_test_missions()
	_test_mission_outbox()
	_test_actual_mission_settlement()
	_test_loss_and_persistence()
	_test_convoys()
	await _test_letter_picture()
	print("FACTION_RELATIONS_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func reset_fixture() -> void:
	Economy.save_path = SAVE
	Economy.debug_reset()
	Economy.rng.seed = 631502
	WorldState.phase = WorldState.Phase.PEACE
	diplomacy.ensure_board()
	diplomacy.convoy_left = 10000.0
	encounters.clear()


func first_contract(fid: String) -> Dictionary:
	for item in diplomacy.contracts:
		if item.faction == fid and item.status == "available":
			return item
	return {}


func load_saved() -> Dictionary:
	var file := FileAccess.open(SAVE, FileAccess.READ)
	if file == null:
		return {}
	var result: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	return result


func _test_initial_and_board() -> void:
	reset_fixture()
	check(diplomacy.suspicion.southern == 0.0 and diplomacy.suspicion.empire == 0.0, "Both factions start at zero independently")
	check(diplomacy.stage("southern") == 0 and diplomacy.stage("empire") == 0, "Zero starts below inspection stage")
	check(not diplomacy.inspectors.southern and not diplomacy.inspectors.empire, "No inspectors before suspicion")
	check(diplomacy.patrols.southern.left == 0.0 and diplomacy.patrols.empire.left == 0.0, "No inspection fleets at start")
	check(diplomacy.contracts.size() == 6, "Board offers three orders for each faction")
	var ids := {}
	var reward_ids := {}
	for item in diplomacy.contracts:
		ids[item.id] = true
		reward_ids[item.blueprint] = true
		check(GameData.recipe_faction(item.blueprint) == item.faction, "Reward is an actual exclusive recipe for issuing faction")
		check(float(item.money) > 0.0 and not item.cost.is_empty() and item.status == "available", "Contract includes payable goods and money reward")
	check(ids.size() == 6 and reward_ids.size() == 6, "All board IDs and six blueprint rewards are distinct")
	var before: Array = diplomacy.contracts.duplicate(true)
	diplomacy.ensure_board()
	check(diplomacy.contracts == before, "Opening the board again does not reroll rewards")
	var accepted: Dictionary = first_contract("southern")
	check(diplomacy.accept(accepted.id) == "", "Order can be accepted")
	var id: String = accepted.id
	Economy.day = 10
	diplomacy.ensure_board()
	check(diplomacy.contract(id).status == "accepted", "Accepted order survives board refresh without expiring")
	check(diplomacy.contracts.size() == 7, "Refresh replaces only unaccepted offers")
	check(not diplomacy.accept("missing:id").is_empty(), "Unknown contract cannot be accepted")
	reset_fixture()
	for item in diplomacy.contracts:
		check(diplomacy.accept(item.id) == "", "Accept up to six concurrent contracts")
	Economy.day = 4
	diplomacy.ensure_board()
	check(not diplomacy.accept(first_contract("empire").id).is_empty(), "Seventh active contract is rejected")


func _test_delivery() -> void:
	reset_fixture()
	var item: Dictionary = first_contract("southern")
	var id: String = item.id
	var reward: String = item.blueprint
	var money_before: float = Economy.money
	check(not diplomacy.deliver(id).is_empty(), "Cannot deliver unaccepted order")
	check(diplomacy.accept(id) == "", "Accept before delivery")
	var empty: Dictionary = Economy.inv.duplicate(true)
	check(not diplomacy.deliver(id).is_empty(), "Insufficient stock prevents delivery")
	check(Economy.inv == empty and Economy.money == money_before and not Economy.blueprints.has(reward), "Insufficient delivery has no side effects")
	for gid in item.cost:
		Economy.inv[gid] = int(item.cost[gid]) + 7
	Economy.inv.commonA = 987
	var stock_before: Dictionary = Economy.inv.duplicate(true)
	check(diplomacy.deliver(id) == "", "Stocked order can be delivered")
	for gid in stock_before:
		check(Economy.stock(gid) == int(stock_before[gid]) - int(item.cost.get(gid, 0)), "Delivery removes only exact requested quantities: " + gid)
	check(Economy.money == money_before + float(item.money), "Full contracted reward is credited once")
	check(Economy.blueprints.get(reward, false) and not Economy.licenses.has(reward), "Reward grants permanent blueprint rather than consumable license")
	check(diplomacy.contract(id).status == "completed", "Completed contract becomes a receipt")
	check(diplomacy.suspicion.empire == diplomacy.CONTRACT_SUSPICION and diplomacy.suspicion.southern == 0.0, "Aid raises only opposing faction suspicion")
	check(Economy.inbox.filtered_messages("faction", "生产委托交付确认").size() == 1, "Delivery creates one faction receipt letter")
	check(load_saved().inbox.messages.size() == Economy.inbox.messages.size(), "Delivery receipt and rewards reach the same durable save")
	var after: Dictionary = Economy.inv.duplicate(true)
	var money_after: float = Economy.money
	check(not diplomacy.deliver(id).is_empty(), "Repeated delivery is refused")
	check(Economy.inv == after and Economy.money == money_after and diplomacy.suspicion.empire == diplomacy.CONTRACT_SUSPICION, "Repeated delivery duplicates neither payment, cargo nor suspicion")
	Economy.modules.factory.count = 1
	for gid in Economy.production.effective_materials(reward):
		Economy.inv[gid] = 100000
	check(Economy.production_block_reason(reward, 1) == "", "Permanent faction blueprint unlocks real manufacturing")
	check(Economy.start_production(reward, 1) == "" and not Economy.prod_jobs[0].uses_license, "Faction recipe manufacture consumes no license")
	Economy._advance_jobs(100000.0)
	check(Economy.stock(reward) == 1 and Economy.blueprints.get(reward, false), "Crafted exclusive equipment reaches goods inventory and blueprint remains")
	for fid in diplomacy.FACTIONS:
		for blueprint in diplomacy.BLUEPRINTS[fid]:
			check(GameData.recipe_faction(blueprint) == fid and not GameData.is_open_recipe(blueprint), "All faction-exclusive recipes are gated")
	check(Economy.save_game(), "Contract progress and rewards save")
	Economy.debug_reset()
	Economy.load_game()
	check(Economy.blueprints.get(reward, false) and diplomacy.contract(id).status == "completed", "Permanent blueprint and completion survive load")
	check(not diplomacy.deliver(id).is_empty(), "Loaded receipt cannot be delivered twice")


func _test_transactions_fail_closed() -> void:
	reset_fixture()
	var item: Dictionary = first_contract("empire")
	var id: String = item.id
	Economy.save_path = FAILED_SAVE
	check(not diplomacy.accept(id).is_empty() and diplomacy.contract(id).status == "available", "Failed acceptance save restores available status")
	Economy.save_path = SAVE
	diplomacy.accept(id)
	diplomacy.add_suspicion("southern", 80.0, "pre_delivery")
	for gid in item.cost:
		Economy.inv[gid] = item.cost[gid]
	var before: Dictionary = diplomacy.get_state()
	var inventory: Dictionary = Economy.inv.duplicate(true)
	var money: float = Economy.money
	var blueprints: Dictionary = Economy.blueprints.duplicate(true)
	var letters: Dictionary = Economy.inbox.get_state()
	Economy.save_path = FAILED_SAVE
	check(not diplomacy.deliver(id).is_empty(), "Delivery reports failed save")
	check(Economy.inv == inventory and Economy.money == money and Economy.blueprints == blueprints, "Failed delivery restores goods, money and blueprint ownership")
	check(diplomacy.get_state() == before, "Failed delivery restores contract and cross-stage inspector changes")
	check(Economy.inbox.get_state() == letters, "Failed delivery sends no false success or inspection correspondence")
	Economy.save_path = SAVE
	check(diplomacy.deliver(id) == "" and diplomacy.inspectors.southern, "Retry commits once and correctly creates inspector")


func _test_bribe() -> void:
	reset_fixture()
	check(not diplomacy.bribe("empire").is_empty(), "Bribe is unavailable before inspector arrives")
	diplomacy.add_suspicion("empire", 175.0, "bribe-stage")
	check(diplomacy.stage("empire") == 1 and diplomacy.inspectors.empire, "First stage sends inspector")
	Economy.money = diplomacy.BRIBE_PRICE - 1.0
	check(not diplomacy.bribe("empire").is_empty() and diplomacy.suspicion.empire == 175.0, "Insufficient bribe funds preserves suspicion")
	Economy.money = 5000.0
	var before: Dictionary = diplomacy.get_state()
	var letters: Dictionary = Economy.inbox.get_state()
	Economy.save_path = FAILED_SAVE
	check(not diplomacy.bribe("empire").is_empty(), "Bribe reports failed persistence")
	check(Economy.money == 5000.0 and diplomacy.get_state() == before, "Failed bribe rolls back exact money, inspector and suspicion")
	check(Economy.inbox.get_state() == letters, "Failed bribe does not send settlement letter")
	Economy.save_path = SAVE
	check(diplomacy.bribe("empire") == "", "Inspector accepts paid bribe")
	check(Economy.money == 5000.0 - diplomacy.BRIBE_PRICE and diplomacy.suspicion.empire == 75.0, "Bribe costs configured sum and removes precisely one complete 100-point stage")
	check(not diplomacy.inspectors.empire and diplomacy.stage("empire") == 0, "Bribed inspector leaves")
	check(not diplomacy.bribe("empire").is_empty(), "Cannot repeatedly bribe departed inspector")
	check(load_saved().diplomacy.suspicion.empire == 75.0, "Bribe result persists atomically")
	diplomacy.add_suspicion("empire", 150.0, "second-stage")
	check(not diplomacy.bribe("empire").is_empty(), "Second-stage fleet cannot use first-stage bribe")


func _test_stages_and_encounters() -> void:
	reset_fixture()
	diplomacy.add_suspicion("empire", 99.0, "below")
	check(diplomacy.stage("empire") == 0, "99 points remains below first stage")
	diplomacy.add_suspicion("empire", 1.0, "boundary")
	check(diplomacy.stage("empire") == 1 and diplomacy.inspectors.empire, "100 points is exact first-stage boundary")
	check(not diplomacy.add_suspicion("empire", 1.0, "boundary") and diplomacy.suspicion.empire == 100.0, "Duplicate suspicion event is ignored")
	check(not diplomacy.add_suspicion("unknown", 100.0) and not diplomacy.add_suspicion("empire", -2.0), "Invalid faction and negative additions rejected")
	diplomacy.add_suspicion("empire", 100.0, "fleet")
	check(diplomacy.stage("empire") == 2 and not diplomacy.inspectors.empire, "200 points replaces inspector with fleet")
	check(diplomacy.patrols.empire.left == 180.0 and diplomacy.patrols.empire.serial == 1, "Inspection fleet starts with 180-second residency")
	diplomacy.tick(179.0)
	check(diplomacy.patrols.empire.left == 1.0, "Inspection duration counts down")
	diplomacy.tick(1.0)
	check(diplomacy.patrols.empire.left == 0.0, "Fleet departs at residency boundary")
	diplomacy.tick(299.0)
	check(diplomacy.patrols.empire.left == 0.0, "Cooldown prevents constant replacement fleets")
	diplomacy.tick(1.0)
	check(diplomacy.patrols.empire.left == 180.0 and diplomacy.patrols.empire.serial == 2, "Persisting high suspicion permits next fleet after cooldown")
	diplomacy.add_suspicion("empire", 10000.0, "third-stage")
	check(diplomacy.suspicion.empire == 300.0 and diplomacy.stage("empire") == 3, "Suspicion clamps at reserved third stage")
	check(diplomacy.patrols.empire.serial == 2 and encounters.is_empty(), "Third stage introduces no new fleet type or major event")
	diplomacy.add_suspicion("southern", 200.0, "other-fleet")
	var suspicion: Dictionary = diplomacy.suspicion.duplicate(true)
	diplomacy._check_encounters()
	check(encounters.size() == 1 and encounters[0].mutual and encounters[0].visitor == null, "Opposing inspection fleets expose mutual hostile encounter")
	check(diplomacy.suspicion == suspicion, "Fleet-versus-fleet encounter does not accuse the player")
	diplomacy._check_encounters()
	check(encounters.size() == 1, "Repeated scan does not duplicate same fleet encounter")
	var visitor := Freighter.make("small", false, Economy.rng, {}, {}, "industrial")
	visitor.faction_id = "southern"
	Economy.berths.append(visitor)
	diplomacy._check_encounters()
	check(encounters.size() == 2 and not encounters[1].mutual and encounters[1].visitor == visitor and encounters[1].attacker == "empire", "Empire patrol targets actual opposing industrial visitor")
	check(Economy.berths.has(visitor) and diplomacy.suspicion == suspicion, "Without combat integration hostile contact does not invent destroyed ships or losses")
	diplomacy._check_encounters()
	check(encounters.size() == 2, "Visitor hostile contact is emitted once per patrol")


func market_ship(fid: String, price: float, quantity: int) -> Freighter:
	var ship := Freighter.make("small", false, Economy.rng, {}, {}, "industrial")
	ship.faction_id = fid
	ship.cap = 100000.0
	ship.funds = 100000.0
	ship.buy_offers = [{"goods": "commonA", "qty_left": float(quantity), "price": price}]
	return ship


func player_listing(quantity: int, price := 1.0) -> void:
	Economy.sell_orders.append({"goods": "commonA", "qty": quantity, "orig": quantity, "price": price, "day": 1, "uid": 100})


func _test_faction_trade() -> void:
	reset_fixture()
	player_listing(49)
	check(Economy.market._freighter_buys(market_ship("empire", 100.0, 50), 49.0) == 49, "Actual faction buyer purchases player goods")
	check(diplomacy.trade_progress.empire == 4900.0 and diplomacy.suspicion.southern == 0.0, "Partial value accumulates below large-purchase threshold")
	player_listing(1)
	Economy.market._freighter_buys(market_ship("empire", 100.0, 1), 1.0)
	check(diplomacy.suspicion.southern == 20.0 and diplomacy.trade_progress.empire == 0.0, "Exactly 5000 credits of real purchases raises opposing suspicion once")
	player_listing(125)
	Economy.market._freighter_buys(market_ship("empire", 100.0, 125), 125.0)
	check(diplomacy.suspicion.southern == 60.0 and diplomacy.trade_progress.empire == 2500.0, "Multiple thresholds and remainder account for the whole trade")
	var money: float = Economy.money
	var npc_before: float = Economy.neutral_fleets.fleets.neutral_aurora.money
	Economy.sell_orders.append({"goods": "commonA", "qty": 100, "orig": 100, "price": 1.0, "day": 1, "uid": 101,
		"owner": "neutral_aurora", "owner_name": "极光采掘联合"})
	Economy.market._freighter_buys(market_ship("empire", 100.0, 100), 100.0)
	check(Economy.money == money and Economy.neutral_fleets.fleets.neutral_aurora.money == npc_before + 10000.0, "Neutral ore seller retains its own actual revenue")
	check(diplomacy.suspicion.southern == 60.0 and diplomacy.trade_progress.empire == 2500.0, "NPC-owned market orders do not make player appear allied")
	player_listing(100, 200.0)
	check(Economy.market._freighter_buys(market_ship("empire", 100.0, 100), 100.0) == 0, "Refused prices do not become purchases")
	Economy.sell_orders.clear()
	player_listing(100)
	Economy.market._freighter_buys(market_ship("", 100.0, 100), 100.0)
	check(diplomacy.suspicion.southern == 60.0 and diplomacy.trade_progress.empire == 2500.0, "Unaffiliated ordinary visitors create no faction suspicion")
	diplomacy.record_trade("southern", 5000.0)
	check(diplomacy.suspicion.empire == 20.0 and diplomacy.suspicion.southern == 60.0, "Alliance purchases independently raise empire suspicion")


func _test_missions() -> void:
	reset_fixture()
	var report := {"mission_id": "faction_mission", "task_id": "mo_empire_patrol", "task": "帝国委派·边境巡查",
		"success": true, "partial": false, "seed": 217, "timestamp": 100.25, "credits": 750, "ep": 6}
	MissionOps.mission_completed.emit(report)
	check(diplomacy.suspicion.southern == 25.0 and diplomacy.suspicion.empire == 0.0, "Successful faction mission raises only opposing suspicion")
	check(Economy.blueprints.get("empireReactiveArmor", false), "Successful mission awards its defined permanent faction blueprint")
	check(Economy.inbox.filtered_messages("faction", "行动回报与蓝图授权").size() == 1, "Real mission signal delivers faction blueprint authorization letter as well as normal result")
	var letters: int = Economy.inbox.messages.size()
	MissionOps.mission_completed.emit(report)
	check(diplomacy.suspicion.southern == 25.0 and Economy.inbox.messages.size() == letters, "Duplicate mission signal cannot award extra suspicion or letters")
	check(Economy.save_game(), "Mission reward and deduplication state save")
	Economy.debug_reset()
	Economy.load_game()
	MissionOps.mission_completed.emit(JSON.parse_string(JSON.stringify(report)))
	check(diplomacy.suspicion.southern == 25.0 and Economy.inbox.messages.size() == letters, "Mission event deduplication survives JSON numeric conversion and load")
	report = {"mission_id": "partial_faction_mission", "task_id": "mo_alliance_patrol", "success": false, "partial": true, "seed": 9, "timestamp": 101.0}
	MissionOps.mission_completed.emit(report)
	check(diplomacy.suspicion.empire == 15.0 and not Economy.blueprints.has("allianceShieldMatrix"), "Partial faction mission gives lesser suspicion and no full-success blueprint")
	report = {"mission_id": "failed_faction_mission", "task_id": "mo_alliance_patrol", "success": false, "partial": false, "seed": 9, "timestamp": 102.0}
	MissionOps.mission_completed.emit(report)
	check(diplomacy.suspicion.empire == 15.0, "Failed faction mission does not raise suspicion")
	report = {"mission_id": "neutral_mission", "task_id": "mo_survey_ice", "success": true, "seed": 8, "timestamp": 103.0}
	MissionOps.mission_completed.emit(report)
	check(diplomacy.suspicion.empire == 15.0 and diplomacy.suspicion.southern == 25.0, "Unaffiliated mission creates no faction suspicion")


func _test_mission_outbox() -> void:
	reset_fixture()
	MissionOps.now_override_sec = 260000.0
	MissionOps.reset_state()
	var report := {"mission_id": "persisted_faction_mission", "task_id": "mo_alliance_patrol", "task": "联盟委派·航线守望",
		"success": true, "partial": false, "seed": 921, "timestamp": 260001.0, "credits": 750, "ep": 6}
	var key: String = MissionOps._route_result_id(report)
	MissionOps.pending_faction_results[key] = report.duplicate(true)
	GameSave.write_suspended = true
	MissionOps._flush_faction_results()
	check(MissionOps.pending_faction_results.has(key) and diplomacy.suspicion.empire == 0.0, "Outbox is not applied before its own durable save succeeds")
	GameSave.write_suspended = false
	Economy.save_path = FAILED_SAVE
	var inbox_before: Dictionary = Economy.inbox.get_state()
	MissionOps._flush_faction_results()
	check(MissionOps.pending_faction_results.has(key), "Economic save failure retains queued faction result")
	check(diplomacy.suspicion.empire == 0.0 and not Economy.blueprints.has("allianceShieldMatrix"), "Failed faction settlement restores suspicion and blueprint ownership")
	check(Economy.inbox.get_state() == inbox_before, "Failed faction settlement retracts undurable authorization letter")
	var file := FileAccess.open(GameSave.SAVE_PATH, FileAccess.READ)
	var persisted: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	check(persisted.sections.missionops.pending_faction_results.has(key), "Pending faction result is already present in actual durable mission save")
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(MissionOps._get_state()))
	Economy.save_path = SAVE
	MissionOps._route_retry_at = MissionOps._now() + 5.0
	MissionOps._process(0.1)
	check(MissionOps.pending_faction_results.has(key) and diplomacy.suspicion.empire == 0.0, "Retry cooldown prevents eager repeated settlement")
	MissionOps.now_override_sec += 5.0
	MissionOps._process(0.1)
	check(MissionOps.pending_faction_results.is_empty() and diplomacy.suspicion.empire == 25.0, "Five-second retry clears queued result after storage recovers")
	check(Economy.blueprints.get("allianceShieldMatrix", false) and Economy.inbox.filtered_messages("faction", "行动回报与蓝图授权").size() == 1,
		"Retried settlement awards permanent blueprint and exactly one authorization letter")
	var messages: int = Economy.inbox.messages.size()
	check(MissionOps._apply_state(snapshot), "Pending faction outbox survives real MissionOps JSON state restore")
	MissionOps._flush_faction_results()
	check(diplomacy.suspicion.empire == 25.0 and MissionOps.pending_faction_results.is_empty() and Economy.inbox.messages.size() == messages,
		"Crash-window replay acknowledges existing faction receipt without duplicating reward or suspicion")
	var legacy: Dictionary = JSON.parse_string(JSON.stringify(MissionOps._get_state()))
	legacy.erase("pending_faction_results")
	check(MissionOps._apply_state(legacy) and MissionOps.pending_faction_results.is_empty(), "Legacy mission save without faction outbox remains compatible")
	MissionOps.reset_state()
	check(MissionOps.pending_faction_results.is_empty(), "Fresh mission reset clears pending faction rewards")


func _test_actual_mission_settlement() -> void:
	reset_fixture()
	MissionOps.now_override_sec = 360000.0
	MissionOps.reset_state()
	GameSave.write_suspended = false
	Economy.money = 100000.0
	Economy.modules.hive.built = true
	Economy.modules.hive.level = 1
	Economy.inv.longbow = 2
	var hire: Dictionary = MissionOps.hire_captain(MissionOps.recruit_pool[0].cid)
	check(hire.get("ok", false), "Actual faction mission hires a captain")
	if not hire.get("ok", false): return
	var team: Dictionary = MissionOps.create_team("势力任务测试", hire.cid)
	check(team.get("ok", false), "Actual faction mission forms a team")
	if not team.get("ok", false): return
	for index in 2:
		var commissioned: Dictionary = MissionOps.commission_ship("longbow")
		check(commissioned.get("ok", false), "Actual faction mission commissions ship %d" % index)
		if not commissioned.get("ok", false): return
		MissionOps.grant_equipment("eq_weapon_mk1")
		var fitted: Dictionary = MissionOps.install_equipment(commissioned.uid, "eq_weapon_mk1")
		check(fitted.get("ok", false), "Actual faction mission equips ship %d" % index)
		check(MissionOps.add_ship_to_team(team.team_id, commissioned.uid).get("ok", false), "Actual faction mission assigns ship %d" % index)
	var probability: float = MissionDefs.success_probability(MissionDefs.TASKS.mo_empire_patrol, MissionOps.captains[hire.cid])
	var rng := RandomNumberGenerator.new()
	var success_seed := -1
	for candidate in 1000:
		rng.seed = candidate
		if rng.randf() < probability:
			success_seed = candidate
			break
	var dispatch: Dictionary = MissionOps.dispatch(team.team_id, "mo_empire_patrol", success_seed)
	check(dispatch.get("ok", false), "Actual faction mission dispatches through player API")
	if not dispatch.get("ok", false): return
	MissionOps.now_override_sec = float(dispatch.ends_wall) + 1.0
	GameSave.write_suspended = true
	MissionOps._catch_up(MissionOps._now())
	check(MissionOps.active.has(dispatch.mission_id) and MissionOps.pending_faction_results.is_empty(), "Initial mission-save failure restores active task and removes uncommitted faction outbox")
	check(diplomacy.suspicion.southern == 0.0 and not Economy.blueprints.has("empireReactiveArmor"), "Initial mission-save failure issues no faction benefits")
	GameSave.write_suspended = false
	Economy.save_path = FAILED_SAVE
	var money: float = Economy.money
	MissionOps._catch_up(MissionOps._now())
	check(MissionOps.active.has(dispatch.mission_id) and MissionOps.pending_faction_results.is_empty(), "Failed economic reward returns real mission and removes pending faction result")
	check(Economy.money == money and diplomacy.suspicion.southern == 0.0 and MissionOps.ep() == 0, "Failed real settlement restores money, exploration reward and suspicion")
	Economy.save_path = SAVE
	var commits: Array = []
	GameSave.register_section("faction_test_audit", func() -> Dictionary:
		commits.append({"active": MissionOps.active.has(dispatch.mission_id), "pending": not MissionOps.pending_faction_results.is_empty()})
		return {}, func(_data) -> bool: return true)
	MissionOps._catch_up(MissionOps._now())
	GameSave._sections.erase("faction_test_audit")
	check(not commits.is_empty() and not commits[0].active and commits[0].pending,
		"First durable removal of completed mission already includes faction outbox")
	var report: Dictionary = MissionOps.last_report()
	check(report.get("success", false) and not MissionOps.active.has(dispatch.mission_id), "Real faction patrol settles successfully")
	check(Economy.money == money + 750.0 and MissionOps.ep() == 6, "Real faction patrol grants its configured money and exploration rewards once")
	check(diplomacy.suspicion.southern == 25.0 and Economy.blueprints.get("empireReactiveArmor", false), "Real mission awards permanent faction blueprint and opposing suspicion")
	check(MissionOps.pending_faction_results.is_empty(), "Real mission acknowledges durable faction result")
	check(Economy.inbox.filtered_messages("event", "任务成功").size() == 1 and Economy.inbox.filtered_messages("faction", "行动回报与蓝图授权").size() == 1,
		"Real settlement sends independent result notification and faction authorization")
	MissionOps._catch_up(MissionOps._now())
	check(Economy.money == money + 750.0 and diplomacy.suspicion.southern == 25.0, "Repeated catch-up does not re-award completed faction mission")


func _test_loss_and_persistence() -> void:
	reset_fixture()
	check(not diplomacy.report_convoy_loss("empire", "empire", "same-side"), "Same-faction incident is not blamed as opposing attack")
	check(not diplomacy.report_convoy_loss("empire", "southern", ""), "Unidentified loss cannot be replayed indefinitely")
	check(not diplomacy.report_convoy_loss("southern", "empire", "mutual", true), "Actual fleet-versus-fleet loss explicitly creates no accusation")
	var before: Dictionary = diplomacy.get_state()
	Economy.save_path = FAILED_SAVE
	check(not diplomacy.report_convoy_loss("southern", "empire", "real-civilian-loss"), "Loss report refuses acknowledgement when save fails")
	check(diplomacy.get_state() == before and Economy.inbox.messages.is_empty(), "Failed loss report restores suspicion, event receipt and accusation letter")
	Economy.save_path = SAVE
	check(diplomacy.report_convoy_loss("southern", "empire", "real-civilian-loss"), "Actual opposing convoy loss creates accountability")
	check(diplomacy.suspicion.southern == 45.0 and diplomacy.suspicion.empire == 0.0, "Victim faction synchronously increases its suspicion")
	var letters: Array = Economy.inbox.filtered_messages("faction", "问责信函")
	check(letters.size() == 1 and letters[0].title.contains("通敌") and letters[0].body.contains("帝国"), "Accusation letter contains victim perspective and attacker identity")
	check(letters.size() == 1 and letters[0].illustration == "incident_southern", "Accountability message stores corresponding incident illustration")
	check(not diplomacy.report_convoy_loss("southern", "empire", "real-civilian-loss") and diplomacy.suspicion.southern == 45.0, "Repeated combat loss callback does not duplicate blame")
	diplomacy.add_suspicion("empire", 210.0, "saved-fleet")
	diplomacy.record_trade("southern", 123.0)
	diplomacy.accept(first_contract("southern").id)
	diplomacy.tick(12.0)
	Economy.inbox.mark_read(int(letters[0].id))
	var state: Dictionary = diplomacy.get_state()
	var mailbox: Dictionary = Economy.inbox.get_state()
	check(Economy.save_game(), "Faction simulation and correspondence persist together")
	Economy.debug_reset()
	Economy.load_game()
	check(JSON.parse_string(JSON.stringify(diplomacy.get_state())) == JSON.parse_string(JSON.stringify(state)),
		"Suspicion, patrol timers/serials, trade progress, contracts and event receipts survive actual JSON reload")
	check(Economy.inbox.get_state() == mailbox, "Accusation body, illustration and read status persist with faction state")
	check(not diplomacy.report_convoy_loss("southern", "empire", "real-civilian-loss"), "Combat receipt survives load and suppresses duplicate accusations")
	var saved: Dictionary = load_saved()
	saved.erase("diplomacy")
	var file := FileAccess.open(SAVE, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	Economy.load_game()
	check(diplomacy.suspicion.southern == 0.0 and diplomacy.suspicion.empire == 0.0, "Old economy saves migrate to independent zero suspicion")
	diplomacy.ensure_board()
	check(diplomacy.contracts.size() == 6 and diplomacy.patrols.empire.left == 0.0, "Old save gains board and no phantom inspection fleet")
	diplomacy.apply_state({"suspicion": {"southern": -20.0, "empire": 999.0}, "next_convoy": "invalid",
		"patrols": {"empire": {"left": 999.0}}})
	check(diplomacy.suspicion.southern == 0.0 and diplomacy.suspicion.empire == 300.0 and diplomacy.patrols.empire.left == 180.0,
		"Loaded numeric state clamps to supported suspicion and residency bounds")
	check(diplomacy.next_convoy == "southern", "Unknown saved convoy faction falls back safely")


func _test_convoys() -> void:
	reset_fixture()
	check(not diplomacy.try_convoy("empire"), "Faction convoy cannot dock without hangar")
	Economy.modules.hangar.built = true
	Economy.modules.hangar.level = 1
	check(not diplomacy.try_convoy("empire"), "Faction arrival still requires harbour fuel")
	Economy.fuel = 100.0
	check(not diplomacy.try_convoy("unknown"), "Unknown faction cannot spawn convoy")
	for fid in diplomacy.FACTIONS:
		Economy.berths.clear()
		var fuel: float = Economy.fuel
		check(diplomacy.try_convoy(fid), "Known faction convoy docks: " + fid)
		var visitor: Freighter = Economy.berths.back()
		check(visitor.faction_id == fid and visitor.visit_role == "convoy", "Convoy has explicit faction and economic role")
		check(visitor.hull_id == "industrial" and not visitor.is_warship() and visitor.name.contains("工业舰"), "Procurement caravan is a real industrial hull with matching label")
		check(Economy.fuel == fuel - 5.0, "Faction convoy pays standard arrival fuel cost only once")
		for gid in diplomacy.BLUEPRINTS[fid]:
			check(not visitor.buy_offer_for(gid).is_empty(), "Convoy buys its actual faction-exclusive goods: " + gid)
		check(visitor.supplies_requested.is_empty(), "Industrial convoy does not silently consume warship ammunition")
		check(Economy.inbox.filtered_messages("faction", "正在采购物资").size() >= 1, "Convoy arrival appears in faction communications")
	Economy.berths.clear()
	diplomacy.next_convoy = "southern"
	diplomacy.convoy_left = 0.0
	diplomacy.tick(0.01)
	check(Economy.berths.size() == 1 and Economy.berths[0].faction_id == "southern" and diplomacy.next_convoy == "empire", "Timed convoy arrival alternates factions")
	check(diplomacy.convoy_left == 120.0, "Successful caravan schedules next arrival")


func _test_letter_picture() -> void:
	reset_fixture()
	diplomacy.report_convoy_loss("empire", "southern", "ui-incident")
	Economy.save_game()
	Economy.debug_reset()
	Economy.load_game()
	var ui := get_tree().get_first_node_in_group("econ_ui")
	ui.open_panel("market")
	await get_tree().process_frame
	var market: Control = ui._panels.market
	var market_ids: Array = market._market_ids()
	for fid in diplomacy.FACTIONS:
		for gid in diplomacy.BLUEPRINTS[fid]:
			check(market_ids.has(gid) and not market_ids.has("lic:" + gid), "Exclusive faction goods trade normally without fictitious license listings: " + gid)
			check(not GameData.licensed_equip_ids().has(gid), "Faction blueprint cannot be bypassed through ordinary license shop: " + gid)
	ui.open_panel("inbox")
	await get_tree().process_frame
	var panel: Control = ui._panels.inbox
	panel._on_selected(0)
	await get_tree().process_frame
	var picture: TextureRect
	var body_visible := false
	for child in panel._detail.get_children():
		if child is TextureRect:
			picture = child
		if child is Label and child.text.contains("涉嫌通敌"):
			body_visible = true
	check(body_visible, "Opening saved accountability letter shows full title and text")
	check(picture != null and picture.texture != null and picture.texture.get_width() > 0, "Opening saved accountability letter displays its actual illustration")
