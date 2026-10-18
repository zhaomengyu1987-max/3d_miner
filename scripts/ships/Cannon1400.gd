extends Node3D
## Passive fitting. No process, target acquisition, damage, or automatic fire.
## Original barrel/muzzle hierarchy is retained for a future pirate encounter controller.
const Effects := preload("res://scripts/fx/Cannon1400Effects.gd")

func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.32, 0.35)
	material.metallic = 0.2
	material.roughness = 0.8
	for mesh in find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material

func muzzle_markers() -> Array[Node]:
	return find_children("*muzzle*", "Node3D", true, false)
