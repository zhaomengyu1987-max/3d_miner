extends Node3D

const Stats := preload("res://scripts/ships/MiningShipStats.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _ready() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(100, 100, 100)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	await get_tree().process_frame
	Economy.save_path = "user://mining_profiles_test.json"
	Economy.debug_reset()
	Economy.debug_instant = false
	seed(7721)
	for module_id in Stats.MODULE_TYPES:
		var type_id: String = Stats.MODULE_TYPES[module_id]
		for oid in GameData.MODULES[module_id].cost:
			Economy.inv[oid] = 100000
		check(Economy.build_module(module_id) == "", "Build " + module_id)
		Economy.module_jobs[module_id].left = 0.0
		Economy._advance_jobs(0.0)
		var matches: Array = Economy._world._corvettes.filter(func(c): return c.ship_type == type_id)
		check(matches.size() == 1, "Main-world spawn " + type_id)
		if matches.is_empty():
			continue
		var ship: MiningCorvetteUnit = matches[0]
		ship.set_process(false)
		ship.configure_motion()
		check(is_equal_approx(ship.motion.max_speed, Stats.speed(type_id)), "Metre speed " + type_id)
		check(is_equal_approx(ship.motion.acceleration, Stats.speed(type_id) * 1.5), "Acceleration " + type_id)
		var ore := BeltOre.new()
		ore.ore_name = "metalOre" if type_id == "prospector" else "RockOre"
		ore.amount = 10000
		ore.freeze = true
		add_child(ore)
		ore.set_physics_process(false)
		ship._target = ore
		ship._target_generation = ore.generation
		ship._state = ship.State.MINING
		for i in 300:
			ship._mining_tick(1.0 / 30.0)
		var profile := Stats.profile(type_id)
		var expected := 10.0 / float(profile.interval) * float(profile["yield"]) * Stats.chance(type_id, GameData.asset_to_ore(ore.ore_name))
		check(absf(ship.mined_total - expected) <= maxf(6.0, expected * 0.2), "Expected throughput " + type_id)
		check(10000 - ore.amount == ship.mined_total, "Conserved extraction " + type_id)
		ship._cargo = {"commonB": int(profile.cargo) - 1}
		ship._mined_frac = 0.0
		ship._mining_tick(5.0)
		check(ship._cargo_total() == float(profile.cargo), "Cargo cap " + type_id)
		check(ship.full_cargo_count == 1, "Full-cargo counter " + type_id)
		check(ship._state == ship.State.TO_STATION, "Return when full " + type_id)
		var delivered_before := ship.delivered_total
		ship._unload()
		check(ship.delivered_total - delivered_before == int(profile.cargo), "Unload " + type_id)
		ship._target = ore
		ship._target_generation = ore.generation
		ore.generation += 1
		check(not ship._target_valid(), "Recycled ore invalidates target " + type_id)
		ore.queue_free()
	Economy.save_game()
	Economy.modules["hulk"].count = 0
	Economy.load_game()
	check(Economy.module_count("hulk") == 1, "New ship persists")
	check(Economy.module_count("corvette") == 1, "Legacy corvette identity persists")
	var boundary := BeltOre.new()
	add_child(boundary)
	boundary.amount = 3
	check(boundary.extract_units(20) == 3 and boundary.amount == 0, "No ore overdraft")
	boundary.amount = 3
	boundary.captured = true
	check(boundary.extract_units(2) == 0 and boundary.amount == 3, "No mining captured ore")
	boundary.captured = false
	boundary.hide()
	check(boundary.extract_units(2) == 0, "No mining hidden ore")
	print("MINING_PROFILES_TEST_PASS" if failures == 0 else "MINING_PROFILES_TEST_FAIL: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
