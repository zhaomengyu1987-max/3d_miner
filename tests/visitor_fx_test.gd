extends Node3D
## Run with an isolated user directory. Explicit FX test, never called by visitor AI.
const Effects := preload("res://scripts/fx/Cannon1400Effects.gd")

func _ready() -> void:
	Economy.set_process(false)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0, 30, 100)
	camera.look_at(Vector3.ZERO)
	var muzzle := Effects.new()
	add_child(muzzle)
	muzzle.position.x = -15
	muzzle.configure_muzzle(0.32)
	var impact := Effects.new()
	add_child(impact)
	impact.position.x = 15
	impact.configure_impact(0.32)
	var shell := preload("res://sences/ships/Shell1400Visual.tscn").instantiate()
	add_child(shell)
	var ship := preload("res://sences/ships/FrigateVisitor.tscn").instantiate()
	add_child(ship)
	ship.position = Vector3(0, -20, 0)
	ship.motion.velocity = Vector3(ship.motion.max_speed, 0, 0)
	ship.motion.drive = 1.0
	ship.update_exhaust()
	await get_tree().create_timer(2.5).timeout
	var ok := not is_instance_valid(muzzle) and not is_instance_valid(impact)
	print("VISITOR_FX_TEST_PASS" if ok else "VISITOR_FX_TEST_FAIL")
	get_tree().quit(0 if ok else 1)
