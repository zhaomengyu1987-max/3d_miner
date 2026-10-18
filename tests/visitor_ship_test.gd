extends Node3D
const Motion := preload("res://scripts/ships/ShipMotion.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.debug_reset()
	var sm: StationModules = Economy._world
	sm.set_process(false)
	# A displaced ring must remain the docking reference, rather than world/station origin.
	sm._dock_center = Vector2(13.0, -24.0)
	sm._dock_plane_y = 80.0
	Economy.modules["hangar"]["built"] = true
	Economy.modules["hangar"]["level"] = 3
	for id in ["standard", "heavy", "giant"]:
		var f := Freighter.new()
		f.def_id = id
		f.name = id
		Economy.berths.append(f)
		sm._spawn_ship(f)
		var ship: Node3D = sm._ships[f]
		check(ship.get_node("VisualBasis/Hull").scale.is_equal_approx(Vector3.ONE), id + " original hull scale")
		check(ship.get_node("VisualBasis").basis.is_equal_approx(Basis.IDENTITY), id + " model bow remains +X")
		check(ship.find_children("Cannon*", "Node3D", true, false).size() > 0, id + " passive 1400 fitted")
		check(ship.find_children("*Rail*", "", true, false).is_empty(), id + " no rail weapons")
		check(ship.get_node("VisualBasis/Cannon1").muzzle_markers().size() >= 2, id + " original muzzle markers")
	for i in 2400:
		sm._process_ships(1.0 / 60.0)
	for f in Economy.berths.duplicate():
		var ship: Node3D = sm._ships[f]
		check(ship.get_meta("state") == "docked", f.def_id + " arrives and brakes")
		check(ship.motion.velocity.length() < 0.01, f.def_id + " docked at rest")
		var nose: Vector3 = ship.get_meta("nose_local")
		var dock_point: Vector3 = ship.get_meta("dock_point")
		check((ship.global_transform * nose).distance_to(dock_point) < 0.1, f.def_id + " bow meets ring berth")
		check(absf(Vector2(dock_point.x, dock_point.z).distance_to(sm._dock_center) - sm._station_half_r) < 0.1, f.def_id + " berth lies on DockRing")
		Economy.berths.erase(f)
		sm._depart_ship(f)
	for i in 6000:
		sm._process_ships(1.0 / 60.0)
	for ship in sm._ship_root.get_children():
		check(ship.is_queued_for_deletion(), ship.name + " reverses, turns and leaves")
	for fps in [30, 60, 120]:
		var body := Node3D.new()
		add_child(body)
		body.rotation.y = PI / 2.0
		var motion := Motion.new()
		var dt := 1.0 / float(fps)
		var arrived := false
		var bounded := true
		for i in fps * 20:
			var old_velocity: Vector3 = motion.velocity
			var old_rotation := body.quaternion
			arrived = motion.travel(body, Vector3(100, 0, 0), dt)
			bounded = bounded and motion.velocity.distance_to(old_velocity) <= motion.acceleration * dt + 0.06
			bounded = bounded and rad_to_deg(old_rotation.angle_to(body.quaternion)) <= motion.turn_rate * dt + 0.05
			if arrived:
				break
		check(arrived and body.position.distance_to(Vector3(100, 0, 0)) < 0.05, "arrival at %d fps" % fps)
		check(bounded, "acceleration and turn limits at %d fps" % fps)
		body.free()
	var vertical_body := Node3D.new()
	add_child(vertical_body)
	var vertical_motion := Motion.new()
	var vertical_arrived := false
	for i in 1200:
		vertical_arrived = vertical_motion.travel(vertical_body, Vector3(0, 50, 0), 1.0 / 60.0)
		if vertical_arrived:
			break
	check(vertical_arrived, "vertical movement does not stall on yaw alignment")
	vertical_body.free()
	var turning_body := Node3D.new()
	add_child(turning_body)
	var turning_motion := Motion.new()
	turning_motion.velocity = Vector3(30, 0, 0)
	var first_position := turning_body.position
	turning_motion.travel(turning_body, Vector3(0, 0, 100), 0.1)
	check(turning_motion.velocity.x < 30.0 and absf(turning_motion.velocity.z) < 0.001, "course change brakes before lateral acceleration")
	check(turning_body.global_basis.x.dot(Vector3.RIGHT) > 0.999, "hull does not turn sideways while braking")
	check(turning_body.position.x > first_position.x, "braking preserves forward inertia")
	turning_body.free()
	for reversing in [false, true]:
		var body := Node3D.new()
		add_child(body)
		var motion := Motion.new()
		var target := Vector3(-10000 if reversing else 10000, 0, 0)
		motion.travel(body, target, 1.0 / 60.0, reversing)
		var ratio := 0.5 if reversing else 1.0
		check(is_equal_approx(motion.velocity.length(), motion.acceleration * ratio / 60.0), "reverse/forward starting acceleration ratio %s" % ratio)
		for i in 300:
			motion.travel(body, target, 1.0 / 60.0, reversing)
		check(is_equal_approx(motion.velocity.length(), motion.max_speed * ratio), "reverse/forward cruise speed ratio %s" % ratio)
		check(body.global_basis.x.dot(Vector3.RIGHT) > 0.999, "reverse keeps bow orientation")
		body.free()
	print("VISITOR_TEST_PASS" if failures == 0 else "VISITOR_TEST_FAIL")
	get_tree().quit(0 if failures == 0 else 1)
