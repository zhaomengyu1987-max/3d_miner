extends Node3D
## Run in an isolated project/user-data directory; this exercises the real main scene.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS
var failures := 0

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func _ready() -> void:
	print("TEST_USER_DATA=", OS.get_user_data_dir())
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.debug_reset()
	var main := preload("res://sences/main.tscn").instantiate()
	main.get_node("TimeWarp").free()
	add_child(main)
	await get_tree().physics_frame
	var hub := main.get_node("MiningHub") as Node3D
	var belt := main.get_node("BeltFlow") as BeltFlow
	var camera := main.get_node("Camera3D") as Camera3D
	check(main.scale.is_equal_approx(Vector3.ONE) and belt.scale.is_equal_approx(Vector3.ONE), "world/physics parents retain unit scale")
	check(hub.position.is_equal_approx(Vector3(0.55544, 9.58215, 3.934128) * U), "station placement converted")
	check(is_equal_approx(camera.near, 0.036 * U) and is_equal_approx(camera.far, 4000.0 * U), "camera clipping converted")
	check(belt._pool.size() == 400, "ore count unchanged")
	check(is_equal_approx(belt.flow_speed, 0.77 * U), "ore travel speed converted")
	var old_camera := Camera3D.new()
	add_child(old_camera)
	old_camera.global_transform = camera.global_transform
	old_camera.global_position /= U
	old_camera.fov = camera.fov
	for point in [hub.global_position, belt.global_position, Vector3(8, 6, -12) * U]:
		check(camera.unproject_position(point).distance_to(old_camera.unproject_position(point / U)) < 0.02, "screen composition invariant")
	old_camera.queue_free()
	for ore in belt._pool:
		check(ore.scale.is_equal_approx(Vector3.ONE), "ore rigid body unit scale")
		break
	var ore := belt.get_free_ore("S", [])
	check(ore != null, "S ore available")
	if ore != null:
		check(ore.body_radius() >= 0.8 * U * 0.85 * 0.5, "ore collision radius converted")
		var distance := ore.global_position.distance_to(hub.global_position)
		belt._capture(ore)
		var duration := distance / ore.pull_speed
		check(duration >= 4.99 and duration <= 10.01, "capture duration remains 5-10 seconds")
		belt._release_all()
	var sm := Economy._world as StationModules
	sm._ensure_world_refs()
	sm._measure_station()
	check(sm._station_half_r > 3.2 * U and sm._station_half_r < 3.4 * U, "dock ring world radius converted")
	check(is_equal_approx(sm._station_body.get_child(0).shape.radius, 3.5 * U), "station picking radius converted")
	var station_size := sm._corner_mapped_aabb(hub.get_node("AthanorGroup")).size
	check(maxf(station_size.x, maxf(station_size.y, station_size.z)) > 1000.0, "station enlarged beyond flagship")
	var miner := MiningCorvetteUnit.new()
	miner.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(miner)
	var miner_size := sm._corner_mapped_aabb(miner._visual).size
	var miner_length := maxf(miner_size.x, maxf(miner_size.y, miner_size.z))
	check(absf(miner_length / 86.787292 - 1.0) < 0.10, "mining and combat frigate lengths differ by less than 10 percent")
	check(is_equal_approx(miner_length, 86.4), "mining frigate not double scaled")
	check(is_equal_approx(miner_size.x, miner_length), "mining frigate longitudinal axis is X")
	miner.free()
	var drone := MiningDroneUnit.new()
	drone.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(drone)
	var drone_size := sm._corner_mapped_aabb(drone._visual).size
	check(is_equal_approx(maxf(drone_size.x, maxf(drone_size.y, drone_size.z)), 54.0), "drone enlarged to 54 metres")
	check(is_equal_approx(drone_size.x, 54.0), "drone longitudinal axis is X")
	drone.free()
	Economy.modules["hangar"]["built"] = true
	Economy.modules["hangar"]["level"] = 1
	var freighter := Freighter.new()
	freighter.def_id = "small"
	freighter.name = "Scale test"
	Economy.berths.append(freighter)
	sm._spawn_ship(freighter)
	var ship: Node3D = sm._ships[freighter]
	for i in 600:
		sm._process_ships(1.0 / 60.0)
		if ship.get_meta("state") == "docked":
			break
	check(ship.get_meta("state") == "docked", "freighter arrives at scaled berth")
	var cargo_nose: Vector3 = ship.get_meta("nose_local")
	var cargo_dock: Vector3 = ship.get_meta("dock_point")
	check((ship.global_transform * cargo_nose).distance_to(cargo_dock) < 0.1, "cargo bow rather than ship centre meets DockRing")
	Economy.berths.erase(freighter)
	sm._depart_ship(freighter)
	for i in 1800:
		sm._process_ships(1.0 / 60.0)
		if ship.is_queued_for_deletion():
			break
	check(ship.is_queued_for_deletion(), "freighter backs out, turns and departs")
	var ice := main.get_node("IceFlow")
	var count := 0
	for particles in ice._systems:
		count += particles.amount
	check(count == 996, "ice particle count remains 6 x floor(1000/6)")
	print("WORLD_SCALE_TEST_PASS" if failures == 0 else "WORLD_SCALE_TEST_FAIL")
	get_tree().quit(0 if failures == 0 else 1)
