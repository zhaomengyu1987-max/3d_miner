@tool
extends Node3D
## Reusable nozzle effect. Local -X points downstream; imported geometry retains Blender edits.
## A fleet/ship controller calls set_drive_state; no per-nozzle process callback or ship scans.

@export_group("Editor Preview")
## Only affects the editor viewport; runtime always uses the actual drive state below.
@export_enum("Actual State", "Idle", "Cruise", "Accelerating", "Full Boost") var editor_preview_mode := 4:
	set(value):
		editor_preview_mode = value
		_apply_state()
## Hide the kilometre-long trail while placing the nozzle, without changing runtime visibility.
@export var editor_show_trail := true:
	set(value):
		editor_show_trail = value
		_apply_state()
@export_group("Drive State")
@export_range(0.0, 1.0) var thrust := 0.0:
	set(value):
		thrust = clampf(value, 0.0, 1.0)
		_apply_state()
@export_range(0.0, 1.0) var speed_ratio := 0.0:
	set(value):
		speed_ratio = clampf(value, 0.0, 1.0)
		_apply_state()
@export var boost_active := false:
	set(value):
		boost_active = value
		_apply_state()
@export_group("Flame")
@export_range(0.0, 20.0) var flow_speed := 5.0:
	set(value):
		flow_speed = value
		_material_settings_dirty = true
		_apply_state()
@export_range(0.0, 4.0) var swirl_speed := 0.35:
	set(value):
		swirl_speed = value
		_material_settings_dirty = true
		_apply_state()
@export_range(0.0, 0.9) var outer_threshold := 0.48:
	set(value):
		outer_threshold = value
		_material_settings_dirty = true
		_apply_state()
@export_range(0.01, 0.5) var outer_softness := 0.16:
	set(value):
		outer_softness = value
		_material_settings_dirty = true
		_apply_state()
@export_range(0.0, 12.0) var flame_brightness := 4.5:
	set(value):
		flame_brightness = value
		_material_settings_dirty = true
		_apply_state()
@export_group("Trail")
@export_range(0.0, 2.0) var trail_brightness := 0.55:
	set(value):
		trail_brightness = value
		_material_settings_dirty = true
		_apply_state()
@export_range(0.01, 2.0) var trail_length_scale := 1.0:
	set(value):
		trail_length_scale = value
		_apply_state()

const SPHERE_CENTER := Vector3(0.9047034, -0.0146217, -0.1004295)
var _flame: ShaderMaterial
var _ring_material: ShaderMaterial
var _trail: ShaderMaterial
var _ring_pivots: Array[Node3D] = []
var _visual_lod := 0
var _batching_state := false
var _material_settings_dirty := true

static func runtime_trail_enabled() -> bool:
	return bool(ProjectSettings.get_setting("effects/thruster_trails_enabled", true))

static func runtime_enabled() -> bool:
	return bool(ProjectSettings.get_setting("effects/thrusters_enabled", true))

func _ready() -> void:
	if not Engine.is_editor_hint() and not runtime_enabled():
		hide()
		return
	_flame = ShaderMaterial.new()
	_flame.shader = preload("res://assets/fx/engine/mainfire.gdshader")
	_flame.set_shader_parameter("flow_noise", preload("res://assets/fx/engine/flow_noise.tres"))
	_trail = ShaderMaterial.new()
	_trail.shader = preload("res://assets/fx/engine/trail.gdshader")
	_assign_material($MainFire, _flame)
	_assign_material($Trail, _trail)
	var sphere_material := _glow_material(Color(0.25, 0.65, 1.0), 2.5)
	_assign_material($Sphere, sphere_material)
	# Persisted binding is visible even before @tool _ready (and after editor reload).
	_ring_material = $InnerRingPivot/Model.material_override as ShaderMaterial
	_ring_pivots.clear()
	for pivot: Node3D in [$InnerRingPivot, $OuterRingPivot]:
		pivot.position = SPHERE_CENTER
		(pivot.get_child(0) as Node3D).position = -SPHERE_CENTER
		_ring_pivots.append(pivot)
	_apply_state()

func _glow_material(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat

func _assign_material(root: Node, material: Material) -> void:
	for mesh: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

var _ring_speed_ratio := -1.0

func set_drive_state(power: float, normalized_speed: float, boosting: bool, motion_speed: float = -1.0) -> void:
	power = clampf(power, 0.0, 1.0)
	normalized_speed = clampf(normalized_speed, 0.0, 1.0)
	if is_equal_approx(thrust, power) and is_equal_approx(speed_ratio, normalized_speed) and boost_active == boosting and is_equal_approx(_ring_speed_ratio, motion_speed):
		return
	_batching_state = true
	_ring_speed_ratio = motion_speed
	thrust = power
	speed_ratio = normalized_speed
	boost_active = boosting
	_batching_state = false
	_apply_state()

## Driven by Ship's existing 0.5s LOD check, not a per-exhaust process callback.
func set_visual_lod(lod: int) -> void:
	lod = clampi(lod, 0, 2)
	if _visual_lod == lod:
		return
	_visual_lod = lod
	_material_settings_dirty = true
	_apply_state()

func _apply_state() -> void:
	if not Engine.is_editor_hint() and not runtime_enabled():
		hide()
		return
	if _batching_state or _flame == null or _trail == null:
		return
	var power := thrust
	var speed := speed_ratio
	var boosting := boost_active
	if Engine.is_editor_hint():
		match editor_preview_mode:
			1:
				power = 0.0
				speed = 0.0
				boosting = false
			2:
				power = 0.45
				speed = 0.5
				boosting = false
			3:
				power = 1.0
				speed = 0.6
				boosting = true
			4:
				power = 1.0
				speed = 1.0
				boosting = true
	for material: ShaderMaterial in [_flame, _ring_material]:
		material.set_shader_parameter("drive", power)
		if _material_settings_dirty:
			material.set_shader_parameter("flow_speed", flow_speed)
			material.set_shader_parameter("swirl_speed", swirl_speed)
			material.set_shader_parameter("edge_threshold", outer_threshold)
			material.set_shader_parameter("edge_softness", outer_softness)
			material.set_shader_parameter("brightness", flame_brightness)
			material.set_shader_parameter("visual_lod", _visual_lod)
	if _material_settings_dirty:
		_trail.set_shader_parameter("brightness", trail_brightness)
		_material_settings_dirty = false
	# Speed controls length, not a second opacity fade that hides short moving trails.
	var moving := speed > 0.0001
	_trail.set_shader_parameter("drive", 1.0 if moving else 0.0)
	$MainFire.visible = _visual_lod < 2
	$Trail.visible = _visual_lod < 2 and moving and (editor_show_trail if Engine.is_editor_hint() else runtime_trail_enabled())
	$Trail.scale.x = maxf(0.0001, trail_length_scale * speed)
	# 0.001 + hidden avoids a singular transform while collapsing inside the constant sphere.
	var ring_speed := speed if Engine.is_editor_hint() or _ring_speed_ratio < 0.0 else clampf(_ring_speed_ratio, 0.0, 1.0)
	var rings_on := _visual_lod == 0 and ring_speed > 0.0
	for pivot in _ring_pivots:
		pivot.visible = rings_on
		pivot.scale = Vector3.ONE * ring_speed if rings_on else Vector3.ONE * 0.001
