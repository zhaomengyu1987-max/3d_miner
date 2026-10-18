extends Node3D
## Hulls retain aitest's metre scale. Local +X is the bow for hull, motion, fittings and exhaust.
const HARBOUR_SCALE := preload("res://scripts/WorldUnits.gd").HARBOUR_EXPANSION
const Motion := preload("res://scripts/ships/ShipMotion.gd")
@export var hull_name := "护卫舰"
@export var hull_length := 86.7873
@export var hull_height := 14.7226
@export var cruise_speed := 72.0
@export var acceleration := 30.0
@export var turn_rate := 60.0
@export var hull_color := Color(0.3, 0.3, 0.3)
var motion := Motion.new()
var exhausts: Array[Node] = []

func _ready() -> void:
	# Match source hull material values without its battle-only global fog uniforms.
	var material := StandardMaterial3D.new()
	material.albedo_color = hull_color
	material.metallic = 0.05
	material.roughness = 0.85
	for mesh in $VisualBasis/Hull.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material
	motion.max_speed = cruise_speed * HARBOUR_SCALE
	motion.acceleration = acceleration * HARBOUR_SCALE
	motion.turn_rate = turn_rate
	for node in find_children("*", "Node3D", true, false):
		if node.has_method("set_drive_state"):
			exhausts.append(node)

func update_exhaust() -> void:
	var forward_speed := maxf(0.0, motion.velocity.dot(global_basis.x)) / motion.max_speed
	for exhaust in exhausts:
		exhaust.set_drive_state(motion.drive, forward_speed, false, motion.velocity.length() / motion.max_speed)
