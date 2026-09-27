class_name BeltOre
extends Node3D

## 单颗可玩矿石: 数据(矿种/档位/储量) + 自漂移 + 自转。由 BeltFlow 池化与调度。

var ore_name := ""
var tier := "S"
var amount := 100
var velocity := Vector3.ZERO
var spin_axis := Vector3.UP
var spin_speed := 0.0
var mesh_instance: MeshInstance3D
var age := 0.0  # 存活计时(秒): BeltFlow 的最长存活保险丝用
# 捕获态: 被空间站引力光束拉拽
var captured := false
var pull_target: Node3D
var pull_speed := 14.0
var _spin_saved := 0.0
var _spin_captured := 0.0
var _spin_recover_time := 0.0
var _spin_recover_total := 1.0


func setup(p_name: String, mesh: Mesh, p_tier: String, p_amount: int,
		p_velocity: Vector3, scale_f: float, spin_min: float, spin_max: float) -> void:
	ore_name = p_name
	tier = p_tier
	amount = p_amount
	velocity = p_velocity
	rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	spin_axis = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	if spin_axis.length_squared() < 0.001:
		spin_axis = Vector3.UP
	spin_axis = spin_axis.normalized()
	spin_speed = randf_range(spin_min, spin_max)
	_spin_saved = spin_speed
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		add_child(mesh_instance)
	mesh_instance.mesh = mesh
	mesh_instance.scale = Vector3.ONE * scale_f
	name = "Ore_%s_%s" % [p_name, tier]


func start_capture(target: Node3D, p_speed: float, spin: float) -> void:
	captured = true
	pull_target = target
	pull_speed = p_speed
	_spin_captured = spin
	spin_speed = spin
	_spin_recover_time = 0.0


## recover_time > 0 时自转在此时长内从捕获速度线性回落到漂移速度; 0 = 立即恢复
func stop_capture(recover_time := 0.0) -> void:
	captured = false
	pull_target = null
	if recover_time > 0.0 and spin_speed > _spin_saved:
		_spin_captured = spin_speed
		_spin_recover_total = recover_time
		_spin_recover_time = recover_time
	else:
		spin_speed = _spin_saved
		_spin_recover_time = 0.0


func set_drifting(on: bool) -> void:
	visible = on
	set_process(on)
	if not on:
		stop_capture()


func _process(delta: float) -> void:
	age += delta
	if _spin_recover_time > 0.0:
		_spin_recover_time = maxf(_spin_recover_time - delta, 0.0)
		var t := 1.0 - _spin_recover_time / _spin_recover_total
		spin_speed = lerpf(_spin_captured, _spin_saved, t)
	if captured:
		if is_instance_valid(pull_target):
			var d := pull_target.global_position - global_position
			if d.length_squared() > 0.0001:
				global_position += d.normalized() * pull_speed * delta
			rotate(spin_axis, spin_speed * delta)
		return
	if velocity != Vector3.ZERO:
		global_position += velocity * delta
		rotate(spin_axis, spin_speed * delta)
