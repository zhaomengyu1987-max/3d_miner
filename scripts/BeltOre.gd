class_name BeltOre
extends RigidBody3D

## 单颗可玩矿石: RigidBody 物理体(重力归零, 仅与同类矿石碰撞)
## 漂移 = 恒定 linear_velocity(逐帧重申, 碰撞只做位置分离不改航线)
## 捕获 = 速度指向空间站; 回收 = 冻结 + 碰撞层归零(不占池不挡路)

var ore_name := ""
var tier := "S"
var amount := 100
var velocity := Vector3.ZERO      # 漂移速度(世界系, 每物理帧重申)
var spin_axis := Vector3.UP
var spin_speed := 0.0             # rad/s
var mesh_instance: MeshInstance3D
var age := 0.0                    # 存活计时(秒): BeltFlow 最长存活保险丝用
# 捕获态: 被空间站引力光束拉拽
var captured := false
var pull_target: Node3D
var pull_speed := 14.0
var _spin_saved := 0.0
var _spin_captured := 0.0
var _spin_recover_time := 0.0
var _spin_recover_total := 1.0
var _sphere: SphereShape3D
## 下游偏置推力(m/s²): 碰撞/避让后帮矿恢复正向漂移, 防徘徊
@export var drift_bias := 3.0


func _init() -> void:
	mass = 1.0
	gravity_scale = 0.0
	can_sleep = false  # 慢速漂移矿不许休眠(休眠=停止漂移=占池)
	continuous_cd = false
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.5  # 碰撞即弹开, 接触不粘滞(治堵车停摆)
	physics_material_override = pm
	var col := CollisionShape3D.new()
	_sphere = SphereShape3D.new()
	_sphere.radius = 0.4
	col.shape = _sphere
	add_child(col)


func setup(p_name: String, mesh: Mesh, p_tier: String, p_amount: int,
		p_velocity: Vector3, scale_f: float, radius: float,
		spin_min: float, spin_max: float) -> void:
	ore_name = p_name
	tier = p_tier
	amount = p_amount
	velocity = p_velocity
	# age 是"本次寿命"不是"槽位一生累计": 重生必须复位。
	# 否则槽位累计超过 BeltFlow.max_ore_age_s 后, 每次重生都会在下一帧被
	# 保险丝立刻回收 → 该槽位永久报废 → 池子耗尽、走廊断流。
	age = 0.0
	rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	spin_axis = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	if spin_axis.length_squared() < 0.001:
		spin_axis = Vector3.UP
	spin_axis = spin_axis.normalized()
	spin_speed = randf_range(spin_min, spin_max)
	_spin_saved = spin_speed
	_sphere.radius = maxf(radius, 0.05)
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
	angular_velocity = spin_axis * spin
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
		angular_velocity = spin_axis * spin_speed


func set_drifting(on: bool) -> void:
	visible = on
	freeze = not on  # 池中矿冻结: 零模拟开销
	collision_layer = 1 if on else 0  # 回收矿不挡活矿
	collision_mask = collision_layer
	if on:
		linear_velocity = velocity
		angular_velocity = spin_axis * spin_speed
	else:
		stop_capture()


func _physics_process(delta: float) -> void:
	if freeze:
		return
	age += delta
	if _spin_recover_time > 0.0:
		_spin_recover_time = maxf(_spin_recover_time - delta, 0.0)
		var t := 1.0 - _spin_recover_time / _spin_recover_total
		spin_speed = lerpf(_spin_captured, _spin_saved, t)
		angular_velocity = spin_axis * spin_speed
	if captured:
		if is_instance_valid(pull_target):
			var d := pull_target.global_position - global_position
			if d.length_squared() > 0.0001:
				linear_velocity = d.normalized() * pull_speed
		return
	# 下游偏置: 碰撞/避让后微弱正向(X+)推力, 防徘徊(只对本应正向漂移的矿有效)
	if drift_bias > 0.0 and velocity.x > 0.0 and linear_velocity.x < velocity.x:
		linear_velocity.x = move_toward(linear_velocity.x, velocity.x, drift_bias * delta)
