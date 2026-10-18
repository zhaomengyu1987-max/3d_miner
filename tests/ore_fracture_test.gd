extends Node3D
var failures := 0

func check(ok: bool, description: String) -> void:
	if not ok:
		failures += 1
		push_error(description)

func _ready() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0, 600, 1400)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	var hub := Node3D.new()
	hub.name = "MiningHub"
	hub.position = Vector3(-1500, 0, 0)
	add_child(hub)
	var belt := BeltFlow.new()
	belt.name = "BeltFlow"
	belt.target_count = 1
	belt.capture_duration_min = 1.0
	belt.capture_duration_max = 1.0
	add_child(belt)
	belt.set_process(false)
	await get_tree().process_frame
	Economy.save_path = "user://ore_fracture_test.json"
	var ore: BeltOre = belt._pool[0]
	prepare(belt, ore, "RockOre", "L")
	check(not belt.drone_can_capture(ore), "Drone rejects L")
	var position_before := ore.global_position
	belt._capture(ore)
	check(not ore.freeze and ore.captured and ore.fracturing, "Fracture keeps drift enabled")
	check(belt._fractures.size() == 1, "Impact started")
	var painted_origin: Vector3 = ore._heat_material.get_shader_parameter("heat_origin")
	var painted_world := ore.mesh_instance.to_global(painted_origin)
	ore.rotate_y(0.7)
	ore.heat_surface(painted_world, 0.2)
	check(ore._heat_material.get_shader_parameter("heat_origin") == painted_origin, "Paint stays fixed in mesh coordinates during rotation")
	check(ore.mesh_instance.to_global(painted_origin).distance_to(painted_world) > 0.01, "Paint rotates with rock instead of remaining in world space")
	var current_origin: Vector3 = ore._heat_material.get_shader_parameter("hotspot_origin")
	check(current_origin.distance_to(painted_origin) > 0.001, "Current yellow contact updates independently of old red paint")
	var hit_direction := (painted_world - ore.global_position).normalized()
	check((ore.heat_contact_world() - ore.global_position).cross(hit_direction).length() < 0.1, "Current contact lies on beam ray")
	check(ore._heat_marks[0] == painted_origin, "Old painted mark is retained")


	for i in 5:
		await get_tree().physics_frame
	check(ore.global_position.distance_to(position_before) > 0.01, "Fracturing rock continues drifting")
	check(ore.linear_velocity.x > 0.0, "Fracture does not pull toward station")
	ore._physics_process(1.0)
	check(ore.extract_units(50) == 0, "Mining cannot race fracture")
	belt._release_all()
	check(not ore.freeze and not ore.captured and belt._fractures.is_empty(), "Cancel ends heating and capture")
	check(ore.collision_layer == 1 and ore.amount == 2500, "Cancel keeps resources and collisions")
	belt._capture(ore)
	belt._process(0.5)
	check(belt._fractures.size() == 1, "Not complete early")
	belt._process(1.6)
	check(belt._fractures.size() == 1, "Full heat requires hold before fracture")
	check(ore.heat_level == 1.0 and float(ore._heat_material.get_shader_parameter("spread")) == 1.0, "Full-body emission reached")
	belt._process(1.5)
	var s_count := 0
	var m_count := 0
	var total := 0
	var medium: BeltOre
	for child in belt._pool:
		if not child.visible:
			continue
		total += child.amount
		check(child.heat_level == 1.0, "Fragments start red-hot")
		child._process(1.5)
		check(is_equal_approx(child.heat_level, 0.5), "Fragments gradually cool")
		child._process(1.6)
		check(child.mesh_instance.material_overlay == null, "Cooled fragment restores original material")
		if child.tier == "S":
			s_count += 1
		if child.tier == "M":
			m_count += 1
			medium = child
			check(child.ore_name == "RockOre", "M preserves mineral")
	check(s_count == 3 and m_count == 1 and total == 800, "L -> 1M + 3S / 800 units with full initial pool")
	check(belt._fractures.is_empty() and belt._beam_ids.is_empty(), "Completed beam cleanup")
	if medium != null:
		belt._capture(medium)
		belt._process(3.6)
	s_count = 0
	total = 0
	for child in belt._pool:
		if child.visible:
			check(child.tier == "S", "Chained split leaves only S")
			s_count += 1
			total += child.amount
	check(s_count == 6 and total == 600, "M -> 3S / chained total six S")
	# Independent conversion trials, rare choice limited to usable rare assets.
	belt._rng.seed = 1091
	var rare_count := 0
	for i in 10000:
		var asset := belt._fragment_asset("RockOre")
		if asset != "RockOre":
			rare_count += 1
			check(GameData.asset_to_ore(asset) in GameData.RARE_IDS, "Only rare mutation")
	check(rare_count > 850 and rare_count < 1150, "Ten percent independent S conversion")
	for child in belt._pool:
		child.set_drifting(false)
	prepare(belt, ore, "goldSmallRed", "S")
	check(not belt.drone_can_capture(ore), "Drone rejects rare S")
	check(belt.get_free_ore("S", [], true) == null, "Drone selector excludes rare S")
	prepare(belt, ore, "RockOre", "S")
	check(belt.get_free_ore("S", [], true) == ore, "Drone selects ordinary S")
	# Hover a gold node, then recycle the same node as fuel ice.
	prepare(belt, ore, "goldSmall", "S")
	ore._on_hover(true)
	ore.set_drifting(false)
	prepare(belt, ore, "IceOre", "S")
	check(ore.mesh_instance.mesh == belt._meshes["IceOre"], "Reused gold node uses actual ice geometry")
	check(ore.mesh_instance.get_surface_override_material(0) == null, "Gold hover material does not leak onto ice")
	check(ore.mesh_instance.get_active_material(0) == belt._meshes["IceOre"].surface_get_material(0), "Ice keeps its own material")

	check(belt.drone_can_capture(ore), "Drone accepts fuel S")
	prepare(belt, ore, "IceOre", "M")
	check(not belt.drone_can_capture(ore), "Drone rejects fuel M")
	prepare(belt, ore, "goldSmallRed", "S")
	belt._capture(ore)
	check(ore.captured and not ore.freeze and belt._fractures.is_empty(), "Player can still tow rare S")
	belt._release_all()
	prepare(belt, ore, "RockOre", "XL")
	belt._capture(ore)
	check(not ore.captured, "XL remains unavailable")
	for child in belt._pool:
		child.set_drifting(false)
	belt._process(0.01)
	check(belt._pool.size() == belt.target_count, "Temporary pool capacity reclaimed")
	print("ORE_FRACTURE_TEST_PASS" if failures == 0 else "ORE_FRACTURE_TEST_FAIL: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func prepare(belt: BeltFlow, ore: BeltOre, asset: String, tier: String) -> void:
	ore.set_drifting(false)
	ore.global_position = Vector3.ZERO
	var size := belt._tier_size(tier)
	ore.setup(asset, belt._meshes[asset], tier, belt.TIER_AMOUNT[tier], Vector3(20, 0, 0),
		size / float(belt._mesh_max_dim[asset]), size * 0.5, 0.2, 0.3)
	ore.set_drifting(true)
