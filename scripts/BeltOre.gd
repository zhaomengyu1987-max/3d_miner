class_name BeltOre
extends RigidBody3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 单颗可玩矿石: RigidBody 物理体(重力归零, 仅与同类矿石碰撞)
## 漂移 = 恒定 linear_velocity(逐帧重申, 碰撞只做位置分离不改航线)
## 捕获 = 速度指向空间站; 回收 = 冻结 + 碰撞层归零(不占池不挡路)

var generation := 0
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
var fracturing := false
var heat_level := 0.0
var _heat_cooling := false
var _heat_material: ShaderMaterial
var _heat_faces := PackedVector3Array()
var _heat_marks := PackedVector3Array()
## 无人机拖曳标记: true 时玩家松开鼠标不会释放它(_release_all 豁免), 回收时复位
var auto_towed := false
var pull_target: Node3D
var pull_speed := 14.0 * U
var _spin_saved := 0.0
var _spin_captured := 0.0
var _spin_recover_time := 0.0
var _spin_recover_total := 1.0
var _sphere: SphereShape3D
## 下游偏置推力(m/s²): 碰撞/避让后帮矿恢复正向漂移, 防徘徊
@export var drift_bias := 3.0 * U

const OUTLINE_SHADER := preload("res://shaders/outline_hull.gdshader")

var _hover := false
var _orig_mats := {}
var _outline_mat: ShaderMaterial


func _ready() -> void:
	input_ray_pickable = true
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	_outline_mat = ShaderMaterial.new()
	_outline_mat.shader = OUTLINE_SHADER


## 悬停: 1px 级描边高亮 + 鼠标旁矿种提示(经 econ_ui 组转发给 EconUiRoot)
func _on_hover(on: bool) -> void:
	_hover = on
	_apply_outline(on)
	var ui := get_tree().get_first_node_in_group("econ_ui")
	if ui != null:
		if on:
			ui.show_ore_tip(self)
		else:
			ui.hide_ore_tip(self)


func _apply_outline(on: bool) -> void:
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	if on:
		for s in mesh_instance.mesh.get_surface_count():
			if _orig_mats.has(s):
				continue
			var orig: Material = mesh_instance.get_surface_override_material(s)
			if orig == null:
				orig = mesh_instance.mesh.surface_get_material(s)
			if orig == null:
				continue
			var m: Material = orig.duplicate()
			if m is BaseMaterial3D:
				(m as BaseMaterial3D).next_pass = _outline_mat
			else:
				continue
			_orig_mats[s] = orig
			mesh_instance.set_surface_override_material(s, m)
	else:
		for s in _orig_mats:
			mesh_instance.set_surface_override_material(s, _orig_mats[s])
		_orig_mats.clear()


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
	_sphere.radius = 0.4 * U
	col.shape = _sphere
	add_child(col)


func setup(p_name: String, mesh: Mesh, p_tier: String, p_amount: int,
		p_velocity: Vector3, scale_f: float, radius: float,
		spin_min: float, spin_max: float) -> void:
	generation += 1
	_clear_heat()
	fracturing = false
	ore_name = p_name
	tier = p_tier
	amount = p_amount
	velocity = p_velocity
	# age 是"本次寿命"不是"槽位一生累计": 重生必须复位。
	# 否则槽位累计超过 BeltFlow.max_ore_age_s 后, 每次重生都会在下一帧被
	# 保险丝立刻回收 → 该槽位永久报废 → 池子耗尽、走廊断流。
	age = 0.0
	auto_towed = false
	rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	spin_axis = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	if spin_axis.length_squared() < 0.001:
		spin_axis = Vector3.UP
	spin_axis = spin_axis.normalized()
	spin_speed = randf_range(spin_min, spin_max)
	_spin_saved = spin_speed
	_sphere.radius = maxf(radius, 0.05 * U)
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		add_child(mesh_instance)
	# Hover restoration leaves per-surface overrides on the old mesh. Pool reuse
	# must discard those before switching minerals (e.g. gold -> fuel ice).
	if _hover:
		_on_hover(false)
	if mesh_instance.mesh != null:
		for surface in mesh_instance.mesh.get_surface_count():
			mesh_instance.set_surface_override_material(surface, null)
	_orig_mats.clear()
	mesh_instance.material_override = null
	mesh_instance.mesh = mesh
	mesh_instance.scale = Vector3.ONE * scale_f
	name = "Ore_%s_%s" % [p_name, tier]


## 护卫舰激光挖掘: 扣减储量(到 0 由调用方回收进池)
func mine_units(u: int) -> void:
	amount = maxi(amount - u, 0)


## Atomic gameplay extraction: captured/recycled ore cannot be mined or overdrawn.
func extract_units(requested: int) -> int:
	if captured or not visible or amount <= 0:
		return 0
	var taken := mini(maxi(requested, 0), amount)
	amount -= taken
	return taken


## 碰撞球半径(米) = 归一化后的视觉尺寸一半; 供接近/环绕距离计算
func body_radius() -> float:
	return _sphere.radius


func start_capture(target: Node3D, p_speed: float, spin: float) -> void:
	captured = true
	pull_target = target
	pull_speed = p_speed
	_spin_captured = spin
	spin_speed = spin
	angular_velocity = spin_axis * spin
	_spin_recover_time = 0.0

	# 捕获/拖潜中关闭碰撞: 速度逐帧被牵引覆盖, 与矿群接触冲量互相打架 = 拖潝卡顿根源
	collision_layer = 0
	collision_mask = 0

## recover_time > 0 时自转在此时长内从捕获速度线性回落到漂移速度; 0 = 立即恢复
func stop_capture(recover_time := 0.0) -> void:
	captured = false
	fracturing = false
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
	if not on:
		_clear_heat()
		if _hover:
			_on_hover(false)  # 回收时若正被悬停, 清描边与提示
		auto_towed = false
		stop_capture()
	collision_layer = 1 if on else 0  # 回收矿不挡活矿(在清捕获态之后设置, 防被覆盖回 1)
	collision_mask = collision_layer
	if on:
		linear_velocity = velocity
		angular_velocity = spin_axis * spin_speed


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
		if fracturing:
			return # Keep drift and spin; fracture is not translational towing.
		if is_instance_valid(pull_target):
			var d := pull_target.global_position - global_position
			if d.length_squared() > 0.0001 * U * U:
				linear_velocity = d.normalized() * pull_speed
		return
	# 下游偏置: 碰撞/避让后微弱正向(X+)推力, 防徘徊(只对本应正向漂移的矿有效)
	if drift_bias > 0.0 and velocity.x > 0.0 and linear_velocity.x < velocity.x:
		linear_velocity.x = move_toward(linear_velocity.x, velocity.x, drift_bias * delta)


func heat_surface(world_hit: Vector3, progress: float) -> void:
	if mesh_instance == null:
		return
	if _heat_material == null:
		_heat_material = ShaderMaterial.new()
		_heat_material.shader = preload("res://shaders/ore_heat.gdshader")
		var bounds := mesh_instance.mesh.get_aabb()
		_heat_material.set_shader_parameter("mesh_radius", bounds.size.length() * 0.5)
		mesh_instance.material_overlay = _heat_material
		_heat_faces = mesh_instance.mesh.get_faces()
	var bounds := mesh_instance.mesh.get_aabb()
	var radius := maxf(bounds.size.length() * 0.5, 0.0001)
	var local_hit := mesh_instance.to_local(world_hit)
	var center := mesh_instance.to_local(global_position)
	var direction := (local_hit - center).normalized()
	var ray_start := center + direction * radius * 4.0
	var nearest := local_hit
	var best_distance := INF
	# Exact front surface on the beam's centre ray, not an approximate bounding sphere.
	for i in range(0, _heat_faces.size(), 3):
		var hit: Variant = Geometry3D.segment_intersects_triangle(ray_start, center - direction * radius * 4.0,
			_heat_faces[i], _heat_faces[i + 1], _heat_faces[i + 2])
		if hit != null:
			var distance: float = ray_start.distance_squared_to(hit)
			if distance < best_distance:
				best_distance = distance
				nearest = hit
	local_hit = nearest
	_heat_material.set_shader_parameter("hotspot_origin", local_hit)
	if _heat_marks.is_empty():
		_heat_material.set_shader_parameter("heat_origin", local_hit)
		var extent := 0.0
		for i in 8:
			extent = maxf(extent, local_hit.distance_to(bounds.get_endpoint(i)) / radius)
		_heat_material.set_shader_parameter("heat_extent", extent)
	var fresh := true
	for mark in _heat_marks:
		if mark.distance_to(local_hit) < radius * 0.12:
			fresh = false
			break
	if fresh and _heat_marks.size() < 32:
		_heat_marks.append(local_hit)
		var upload := PackedVector3Array(_heat_marks)
		upload.resize(32)
		_heat_material.set_shader_parameter("paint_marks", upload)
		_heat_material.set_shader_parameter("paint_count", _heat_marks.size())
	_heat_cooling = false
	heat_level = 1.0
	_heat_material.set_shader_parameter("hotspot", 1.0)
	_heat_material.set_shader_parameter("spread", clampf(progress, 0.0, 1.0))
	_heat_material.set_shader_parameter("heat", heat_level)


func start_cooling(full_body := false) -> void:
	if full_body:
		heat_surface(global_position, 1.0)
	_heat_cooling = _heat_material != null
	if _heat_material != null:
		_heat_material.set_shader_parameter("hotspot", 0.0)


func _process(delta: float) -> void:
	if _heat_cooling:
		heat_level = maxf(0.0, heat_level - delta / 3.0)
		_heat_material.set_shader_parameter("heat", heat_level)
		if heat_level <= 0.0:
			_clear_heat()


func _clear_heat() -> void:
	if mesh_instance != null:
		mesh_instance.material_overlay = null
	_heat_material = null
	_heat_faces.clear()
	_heat_marks.clear()
	heat_level = 0.0
	_heat_cooling = false


func heat_contact_world() -> Vector3:
	if _heat_material != null:
		return mesh_instance.to_global(_heat_material.get_shader_parameter("hotspot_origin"))
	return global_position
