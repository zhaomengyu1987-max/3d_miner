extends Node3D
## Adapted 1400 effect layers; ordinary nodes allocated only when explicitly requested.
## Visitors never create this effect. No combat or damage dependencies.
const BASE := "res://assets/fx/cannon1400/"
const SHADERS := "res://shaders/visitors/"
var layers: Array[Dictionary] = []
var age := 0.0

func add_layer(texture_path: String, shader_name: String, size_m: float, duration: float, growth: float, params: Dictionary = {}) -> void:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size_m
	mesh.mesh = quad
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = load(SHADERS + shader_name + ".gdshader")
	material.set_shader_parameter("atlas" if shader_name == "thermal_blast_billboard" else "tex", load(texture_path))
	for key in params:
		material.set_shader_parameter(key, params[key])
	mesh.material_override = material
	add_child(mesh)
	layers.append({"node": mesh, "material": material, "duration": duration, "growth": growth})

func configure_muzzle(size_scale := 1.0) -> void:
	add_layer(BASE + "muzzle_main.png", "muzzle_billboard", 5.35 * size_scale, 0.35, 1.4,
		{"ramp": load(BASE + "ramp_orange.png"), "brightness": 1.6})
	add_layer(BASE + "cross_flare.png", "expl_billboard", 10.0 * size_scale, 0.22, 1.2)
	add_layer(BASE + "core_cone.png", "shockwave_billboard", 7.0 * size_scale, 0.30, 1.2,
		{"ramp": load(BASE + "ramp_fire.png"), "use_ramp": 1.0, "use_alpha_mask": 1.0, "brightness": 2.0})

func configure_impact(size_scale := 1.0) -> void:
	add_layer(BASE + "radial_core.png", "shockwave_billboard", 40.0 * size_scale, 0.4, 1.6,
		{"ramp": load(BASE + "ramp_fire.png"), "use_ramp": 1.0, "use_alpha_mask": 1.0, "brightness": 1.6})
	add_layer(BASE + "ring_main.png", "shockwave_billboard", 96.0 * size_scale, 2.0, 2.8,
		{"ramp": load("res://assets/fx/shockwave/heat_ramp.png"), "use_ramp": 1.0, "brightness": 1.0})
	add_layer("res://assets/fx/motion/fireball_atlas.png", "thermal_blast_billboard", 64.0 * size_scale, 1.2, 1.7,
		{"flow_map": load("res://assets/fx/motion/fireball_flow.png"), "ramp": load("res://assets/fx/motion/fire_ramp.png"), "brightness": 4.5})
	add_layer(BASE + "cross_flare.png", "expl_billboard", 76.0 * size_scale, 0.25, 1.3)

func _process(delta: float) -> void:
	age += delta
	var alive := false
	for layer in layers:
		var k := clampf(age / float(layer.duration), 0.0, 1.0)
		layer.node.visible = k < 1.0
		if k >= 1.0:
			continue
		alive = true
		layer.node.scale = Vector3.ONE * lerpf(1.0, float(layer.growth), k)
		layer.material.set_shader_parameter("effect_progress", k)
		layer.material.set_shader_parameter("effect_color", Color(1.0, 1.0, 1.0, 1.0 - k))
	if not alive:
		queue_free()
