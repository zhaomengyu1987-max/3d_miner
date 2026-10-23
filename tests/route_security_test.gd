extends Node3D

var failures := 0
var assertions := 0
var world_path := "user://route_security_world.json"


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("ROUTE_SECURITY: " + message)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	MissionOps.set_process(false)
	Economy.save_path = "user://route_security_economy.json"
	WorldState._save_path = world_path
	Economy.debug_reset()
	WorldState.debug_reset()
	check(WorldState.route_safety == 10.0, "New game starts at maximum safety")
	check(WorldState.pirate_pressure == 0.0, "Unbuilt starting station has no pirate pressure")
	Economy.add_money(1000000.0)
	var pressure: float = WorldState.pirate_pressure
	check(pressure > 0.0 and WorldState.route_safety == 10.0, "Wealth attracts pirates without inventing a harassment event")
	Economy.add_money(1000000.0)
	check(WorldState.pirate_pressure > pressure, "More wealth increases pirate pressure")
	pressure = WorldState.pirate_pressure
	Economy.modules.factory.count = 2
	Economy.modules.factory.built = true
	Economy.modules_changed.emit()
	check(WorldState.station_development == 2 and WorldState.pirate_pressure > pressure, "Construction contributes to pirate attraction")
	Economy.debug_reset()
	Economy.inv.commonA = 1000
	Economy.inventory_changed.emit()
	var wealth: float = WorldState.station_wealth
	Economy.post_sell("commonA", 1000)
	check(is_equal_approx(WorldState.station_wealth, wealth), "Player escrow still counts as station wealth")
	Economy.neutral_fleets.deliver_cargo("neutral_aurora", {"rareA": 10000})
	check(is_equal_approx(WorldState.station_wealth, wealth), "Neutral ore listings do not count as player wealth")
	Economy.order_queue = [{"paid": {"commonA": 20}}]
	WorldState._refresh_security_metrics()
	check(is_equal_approx(WorldState.station_wealth, wealth + 40.0), "Paid queue materials remain station wealth")
	Economy.prod_jobs = [{"equip": "truss", "batches": 1}]
	WorldState._refresh_security_metrics()
	check(WorldState.station_wealth > wealth + 40.0, "Active manufacturing remains station wealth")
	Economy.add_money(1000000000.0)
	check(WorldState.pirate_pressure == 100.0, "Pirate pressure is bounded")
	var safe_risk: float = WorldState.pirate_risk()
	var result: Dictionary = WorldState.record_pirate_harassment("test-raid", 2.0)
	check(result.ok and WorldState.route_safety == 8.0, "Harassment interface lowers route safety")
	check(WorldState.last_harassment_wall > 0.0, "Harassment time is recorded")
	check(WorldState.pirate_risk() > safe_risk, "Lower safety increases future harassment risk")
	WorldState.record_pirate_harassment("test-raid", 2.0)
	check(WorldState.route_safety == 8.0, "Duplicate harassment event is idempotent")
	check(not WorldState.record_pirate_harassment("invalid", -1.0).ok, "Invalid harassment cannot improve safety")
	WorldState.record_pirate_harassment("severe-raid", 100.0)
	check(WorldState.route_safety == 0.0, "Safety cannot fall below zero")
	var task_ids := ["mo_combat_skirmish", "mo_escort_convoy", "mo_patrol_lane", "mo_combat_nest"]
	for i in task_ids.size():
		var task_id: String = task_ids[i]
		var definition: Dictionary = MissionDefs.TASKS[task_id]
		var report := {"mission_id": "unit_%d" % i, "task_id": task_id, "success": true,
			"seed": 100 + i, "timestamp": 1000 + i}
		var before: float = WorldState.route_safety
		result = WorldState.apply_route_mission_result(report)
		check(result.ok and is_equal_approx(WorldState.route_safety - before, float(definition.route_safety_gain)),
			"Security task improves route safety: " + task_id)
		WorldState.apply_route_mission_result(report)
		check(is_equal_approx(WorldState.route_safety - before, float(definition.route_safety_gain)), "Mission reward cannot be replayed")
	var failed := {"mission_id": "failed", "task_id": "mo_patrol_lane", "success": false, "seed": 0, "timestamp": 0}
	var before: float = WorldState.route_safety
	WorldState.apply_route_mission_result(failed)
	check(WorldState.route_safety == before, "Failed task does not improve safety")
	failed.mission_id = "partial"
	failed.partial = true
	WorldState.apply_route_mission_result(failed)
	check(is_equal_approx(WorldState.route_safety - before, 0.3 * 0.6), "Partial success receives reduced safety reward")
	WorldState.adjust_route_safety(100.0, "upper-bound")
	check(WorldState.route_safety == 10.0, "Safety cannot exceed ten")
	WorldState.record_pirate_harassment("persisted-raid", 1.0)
	WorldState.route_safety = 0.0
	WorldState._load()
	check(WorldState.route_safety == 9.0, "Safety survives save/load")
	WorldState.record_pirate_harassment("persisted-raid", 1.0)
	check(WorldState.route_safety == 9.0, "Event IDs survive save/load")
	WorldState._save_path = "user://route_missing_folder/world.json"
	result = WorldState.record_pirate_harassment("failed-save", 1.0)
	check(not result.ok and WorldState.route_safety == 9.0, "Failed world save rolls back safety")
	WorldState._save_path = world_path
	result = WorldState.record_pirate_harassment("failed-save", 1.0)
	check(result.ok and WorldState.route_safety == 8.0, "Failed write does not consume the event ID")
	var file := FileAccess.open(world_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"stockpile": 0.0, "current_faction": "empire"}))
	file.close()
	WorldState._load()
	check(WorldState.route_safety == 10.0, "Legacy save receives default safety ten")
	_test_mission_integration()
	print("ROUTE_SECURITY_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func _resolve_task(task_id: String, team: String, captain: String) -> Dictionary:
	var probability := MissionDefs.success_probability(MissionDefs.TASKS[task_id], MissionOps.captains[captain])
	var rng := RandomNumberGenerator.new()
	var seed_value := 0
	for value in 1000:
		rng.seed = value
		if rng.randf() < probability:
			seed_value = value
			break
	var dispatch: Dictionary = MissionOps.dispatch(team, task_id, seed_value)
	check(bool(dispatch.get("ok", false)), "Security mission dispatches through real MissionOps")
	if not bool(dispatch.get("ok", false)):
		return {}
	MissionOps.now_override_sec = float(dispatch.ends_wall) + 1.0
	MissionOps._catch_up(MissionOps._now())
	return MissionOps.last_report()


func _test_mission_integration() -> void:
	Economy.debug_reset()
	WorldState.debug_reset()
	MissionOps.now_override_sec = 81000.0
	MissionOps.reset_state()
	GameSave.write_suspended = false
	Economy.money = 100000.0
	Economy.modules.hive.level = 1
	Economy.modules.hive.built = true
	Economy.inv.longbow = 1
	var hire: Dictionary = MissionOps.hire_captain(MissionOps.recruit_pool[0].cid)
	check(bool(hire.get("ok", false)), "Integration captain is hired")
	if not bool(hire.get("ok", false)):
		return
	var captain: String = hire.cid
	var team: Dictionary = MissionOps.create_team("航道测试队", captain)
	var commissioned: Dictionary = MissionOps.commission_ship("longbow")
	check(bool(team.get("ok", false)) and bool(commissioned.get("ok", false)), "Integration fleet is commissioned")
	if not bool(team.get("ok", false)) or not bool(commissioned.get("ok", false)):
		return
	MissionOps.grant_equipment("eq_weapon_mk1")
	MissionOps.install_equipment(commissioned.uid, "eq_weapon_mk1")
	MissionOps.add_ship_to_team(team.team_id, commissioned.uid)
	WorldState.adjust_route_safety(-5.0, "integration-start")
	var report := _resolve_task("mo_patrol_lane", team.team_id, captain)
	check(is_equal_approx(WorldState.route_safety, 5.3), "Real task settlement applies safety reward")
	check(is_equal_approx(float(report.get("route_safety_gain", 0.0)), 0.3), "Mission report shows actual safety gain")
	check(MissionOps.pending_route_results.is_empty(), "Successful delivery clears the pending result")
	WorldState._save_path = "user://route_missing_folder/world.json"
	report = _resolve_task("mo_combat_skirmish", team.team_id, captain)
	check(MissionOps.pending_route_results.size() == 1 and WorldState.route_safety == 5.3, "Failed world write retains a pending reward")
	check(bool(report.get("route_safety_pending", false)), "Report identifies pending safety settlement")
	var pending_snapshot: Dictionary = JSON.parse_string(JSON.stringify(MissionOps._get_state()))
	WorldState._save_path = world_path
	MissionOps._flush_route_results()
	check(is_equal_approx(WorldState.route_safety, 5.8) and MissionOps.pending_route_results.is_empty(), "Pending reward retries after storage recovers")
	check(MissionOps._apply_state(pending_snapshot), "Pending outbox survives MissionOps state reload")
	MissionOps._flush_route_results()
	check(is_equal_approx(WorldState.route_safety, 5.8) and MissionOps.pending_route_results.is_empty(), "Crash-window replay cannot double the safety reward")
