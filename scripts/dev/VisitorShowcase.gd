extends Node3D
## F6 preview. Economy is paused and saves redirected; no visitor weapons fire.
const MiningCatalog := preload("res://scripts/ships/MiningShipCatalog.gd")
@export var mining_fleet_only := false
var ships: Array[Node3D] = []
var entries: Array[Dictionary] = []
var overview_distance := 1000.0
var camera: Camera3D
var moving := false
var selected := -1
var distance := 800.0
var yaw := 0.0
var pitch := 1.15

func _ready() -> void:
	GameSave.write_suspended = true
	Economy.save_path = "user://visitor_preview.json"
	for singleton in [Economy, WorldState, MissionOps]:
		singleton.process_mode = Node.PROCESS_MODE_DISABLED
	await get_tree().process_frame
	if is_instance_valid(Economy._world):
		Economy._world.hide()
		Economy._world.process_mode = Node.PROCESS_MODE_DISABLED
	for ui in get_tree().get_nodes_in_group("econ_ui"):
		ui.hide()
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.018, 0.028, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.75, 0.9)
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	environment.environment = env
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.light_energy = 1.0
	add_child(light)
	# Use the runtime mining-unit normalization and the main scene's station rig.
	var drone := MiningDroneUnit.new()
	drone.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(drone)
	_add_entry(drone, drone._visual, "采矿无人机")
	drone.configure_motion()
	ships.append(drone)
	if mining_fleet_only:
		for scene_name in ["Skiff", "Prospector", "Barge", "Orca", "Hulk"]:
			var miner: MiningCorvetteUnit = load("res://sences/ships/mining/" + scene_name + ".tscn").instantiate()
			miner.process_mode = Node.PROCESS_MODE_DISABLED
			add_child(miner)
			_add_entry(miner, miner._visual, MiningCatalog.label(miner.ship_type))
			miner.configure_motion()
			ships.append(miner)
	else:
		var miner := MiningCorvetteUnit.new()
		miner.process_mode = Node.PROCESS_MODE_DISABLED
		add_child(miner)
		_add_entry(miner, miner._visual, MiningCatalog.label("skiff"))
		miner.configure_motion()
		ships.append(miner)
		var station: Node3D = preload("res://sences/StationRig.tscn").instantiate()
		add_child(station)
		station.position = Vector3.ZERO
		for guide in ["DockBox", "RingEdge", "DockRing"]:
			station.get_node(guide).hide()
		_add_entry(station, station.get_node("AthanorGroup"), "空间站")
		for kind in ["Frigate", "Battleship", "Flagship"]:
			var ship: Node3D = load("res://sences/ships/" + kind + "Visitor.tscn").instantiate()
			add_child(ship)
			ships.append(ship)
			_add_entry(ship, ship.get_node("VisualBasis/Hull"), ship.hull_name)
		entries.sort_custom(func(a, b): return a.size_m < b.size_m)
	var total_width := 0.0
	for entry in entries:
		total_width += maxf(entry.bounds.size.x, 65.0) + 35.0
	var cursor := -total_width * 0.5
	for i in entries.size():
		var entry := entries[i]
		var width := maxf(entry.bounds.size.x, 65.0)
		entry.node.position = Vector3(cursor + width * 0.5, 0, 0) - entry.center
		var marker := Label3D.new()
		marker.text = str(i + 1)
		marker.font_size = 28
		marker.fixed_size = true
		marker.pixel_size = 0.002
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.position = entry.center + Vector3(0, 0, entry.bounds.size.z * 0.5 + 15.0)
		entry.node.add_child(marker)
		cursor += width + 35.0
		print("SIZE_COMPARE ", i + 1, " ", entry.title, " ", entry.size_m, " m")
	# Same camera and world units for all models; no per-object display magnification.
	overview_distance = maxf(total_width, 850.0)
	distance = overview_distance
	camera = Camera3D.new()
	camera.fov = 50.0
	camera.near = 0.5
	camera.far = 10000.0
	add_child(camera)
	camera.make_current()
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var help := Label.new()
	help.position = Vector2(24, 20)
	help.text = "采矿船占位预览 · 按等级排列 · 高级船型暂用同尺寸模型\n" if mining_fleet_only else "尺寸对比 · 从小到大 · 同一比例（标注为舰体最大边）\n"
	for i in entries.size():
		help.text += "%d %s %.2f米　" % [i + 1, entries[i].title, entries[i].size_m]
		if i % (2 if mining_fleet_only else 3) == (1 if mining_fleet_only else 2):
			help.text += "\n"
	help.text += "\n0 全景 · 1—6 单独查看 · 右键环视 · 滚轮缩放 · 空格启停全部舰船航行"
	canvas.add_child(help)
	if "--capture-visitors" in OS.get_cmdline_user_args():
		for i in 30:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://mining_fleet_overview.png" if mining_fleet_only else "user://visitor_overview.png")
		get_tree().quit()

func _process(delta: float) -> void:
	if camera == null:
		return
	for ship in ships:
		if moving:
			var target := Vector3(ship.position.x, ship.position.y, float(ship.get_meta("destination_z", -250.0)))
			if ship.motion.travel(ship, target, delta):
				ship.set_meta("destination_z", -target.z)
		else:
			ship.motion.stop()
		if ship.has_method("update_exhaust"):
			ship.update_exhaust()
	var center: Vector3 = entries[selected].node.position + entries[selected].center if selected >= 0 else Vector3.ZERO
	camera.position = center + Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	camera.look_at(center)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			moving = not moving
		elif event.keycode >= KEY_0 and event.keycode <= KEY_6:
			selected = event.keycode - KEY_1
			distance = maxf(entries[selected].size_m * 2.0, 12.0) if selected >= 0 else overview_distance
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw -= event.relative.x * 0.005
		pitch = clampf(pitch + event.relative.y * 0.005, 0.08, 1.5)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(8.0, distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(4000.0, distance / 0.9)

func _add_entry(node: Node3D, visual: Node3D, title: String) -> void:
	var bounds := AABB()
	var first := true
	var nodes: Array[Node] = [visual]
	while not nodes.is_empty():
		var current: Node = nodes.pop_back()
		if current is MeshInstance3D and current.mesh != null:
			var box: AABB = node.global_transform.affine_inverse() * current.global_transform * current.mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
		for child in current.get_children():
			nodes.append(child)
	entries.append({"node": node, "title": title, "bounds": bounds,
		"center": bounds.get_center(), "size_m": maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))})
