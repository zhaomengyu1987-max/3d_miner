class_name MiningDroneUnit
extends Node3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 采矿无人机单位（StationModules 按 module_count 生成，模型 drone.glb）。
## 状态机：IDLE 泊位悬停 → TO_ORE 飞向未被认领的普矿/燃料冰矿 S 档矿 → 到达即拖曳
## （ore.start_capture 自动飞站，BeltFlow 送达钩子统一入账）→ 护送至入库。
## 2026-09-30 拍板：拖拽速度 = 玩家拖拽速度的 1/5（按 m/s 移动）；
## 矿拖回空间站后无冷却立即出发下一趟；无目标才回泊位。

enum State { IDLE, TO_ORE, ESCORT, RETURN }

const DroneScene := preload("res://sences/MiningDrone.tscn")
const DRONE_SIZE := 0.45 * U # 目标最大边54m，随原有世界整体放大。
const HULL_COLOR := Color(0.5, 0.62, 0.66)    # 无材质低模的机壳色
const DEBUG_SCALE := 50.0                     # debug_instant 时速度×50（headless 测试）
const RETRY_S := 1.0                          # 池内暂无目标时的重试间隔

var belt: BeltFlow
var station: Node3D
var park_pos := Vector3.ZERO                  # 世界坐标停泊位
var claims: Array                             # 与其他无人机共享的认领目标列表

const Motion := preload("res://scripts/ships/ShipMotion.gd")
var motion := Motion.new()

var _state := State.IDLE
var _retry := 0.0
var _target_generation := -1
var _target: BeltOre
var _visual: Node3D


func _ready() -> void:
	_visual = DroneScene.instantiate()
	add_child(_visual)
	var max_dim := _mesh_max_dim_of(_visual)
	if max_dim > 0.001:
		_visual.scale = Vector3.ONE * (DRONE_SIZE / max_dim)
	_visual.rotation.y = PI / 2.0 # Authored +Z bow -> common +X.
	_apply_hull_material(_visual)
	position = park_pos


func _speed() -> float:
	var s: float = GameData.ECON["drone_fly_speed"]
	return s * DEBUG_SCALE if Economy.debug_instant else s


func configure_motion() -> void:
	motion.max_speed = _speed()
	motion.acceleration = _speed() * (50.0 if Economy.debug_instant else 1.5)
	motion.turn_rate = 7200.0 if Economy.debug_instant else 100.0


func _process(delta: float) -> void:
	configure_motion()
	match _state:
		State.IDLE:
			motion.travel(self, park_pos, delta)
			_retry -= delta
			if _retry <= 0.0:
				_try_acquire()
		State.TO_ORE:
			if not _target_valid():
				_forget_target()
				_go_home()
				return
			var d := _target.global_position - global_position
			if d.length() <= 0.6 * U:
				_tow()
			else:
				motion.travel(self, _target.global_position, delta)
		State.ESCORT:
			# 贴着被拖矿飞, 直到 BeltFlow 送达回收(矿消失) → 无冷却立即下一趟
			if _target == null or not is_instance_valid(_target) or not _target.visible or _target.generation != _target_generation:
				_forget_target()
				_try_immediate()
			elif is_instance_valid(_target) and station != null and is_instance_valid(station):
				# 平滑护航: 锚点=拖拽线侧后方, 距离随矿+舰尺寸自适应(防扎进被拖矿)
				var tow_dir := (station.global_position - _target.global_position).normalized()
				var anchor := _target.global_position - tow_dir * (_target.body_radius() + DRONE_SIZE * 0.5 + 0.3 * U) + Vector3(0.0, 0.6, 0.0) * U
				motion.max_speed = _speed() * 3.0
				motion.travel(self, anchor, delta)
		State.RETURN:
			if motion.travel(self, park_pos, delta):
				_state = State.IDLE
				_retry = RETRY_S



func _try_acquire() -> void:
	if belt == null or not is_instance_valid(belt):
		_retry = RETRY_S
		return
	var target := belt.get_free_ore("S", claims, true)
	if target == null:
		if _state == State.IDLE:
			_retry = RETRY_S
		else:
			_go_home()
		return
	claims.append(target)
	_target = target
	_target_generation = target.generation
	_state = State.TO_ORE


## 送达后无冷却直接出发（不回泊位）
func _try_immediate() -> void:
	var target: BeltOre = belt.get_free_ore("S", claims, true) \
		if belt != null and is_instance_valid(belt) else null
	if target == null:
		_go_home()
		return
	_target = target
	_target_generation = target.generation
	claims.append(target)
	_state = State.TO_ORE


func _go_home() -> void:
	_state = State.RETURN


## 拖曳: 速度 = 玩家拖拽速度(距离/捕获时长档) 的 1/5, 按 m/s 移动
func _tow() -> void:
	if station == null or not is_instance_valid(station):
		# 无站体（无 MiningHub 的场景/测试）: 拖不了, 直接放回
		_forget_target()
		_go_home()
		return
	if not _target_valid():
		_forget_target()
		_go_home()
		return
	var dist: float = station.global_position.distance_to(_target.global_position)
	var dur := 7.5
	if belt != null and is_instance_valid(belt):
		dur = belt.capture_duration_mid()
	var player_speed := dist / maxf(dur, 0.5)
	var tow_speed := player_speed / GameData.ECON["drone_tow_player_ratio"]
	if Economy.debug_instant:
		tow_speed *= DEBUG_SCALE
	_target.auto_towed = true
	# 自旋 0：矿平稳直线回站（2026-09-30 拍板，取消拖拽旋转）
	_target.start_capture(station, tow_speed, 0.0)
	_state = State.ESCORT


## 目标仍可拖: 存活、可见、没被玩家先手捕获
func _target_valid() -> bool:
	return _target != null and is_instance_valid(_target) \
		and _target.visible and not _target.captured and _target.generation == _target_generation \
		and belt != null and belt.drone_can_capture(_target)


func _forget_target() -> void:
	claims.erase(_target)
	_target = null


func _mesh_max_dim_of(root: Node) -> float:
	var best := 0.0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var sz := (n as MeshInstance3D).mesh.get_aabb().size
			best = maxf(best, maxf(sz.x, maxf(sz.y, sz.z)))
		for c in n.get_children():
			stack.append(c)
	return best


func _apply_hull_material(root: Node) -> void:
	var needs_mat := false
	var meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			meshes.append(mi)
			for i in mi.mesh.get_surface_count():
				if mi.mesh.surface_get_material(i) == null:
					needs_mat = true
		for c in n.get_children():
			stack.append(c)
	if not needs_mat:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = HULL_COLOR
	m.metallic = 0.4
	m.roughness = 0.5
	for mi in meshes:
		mi.material_override = m
