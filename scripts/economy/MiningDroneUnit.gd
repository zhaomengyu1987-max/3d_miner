class_name MiningDroneUnit
extends Node3D

## 采矿无人机单位（StationModules 按 module_count 生成，模型 drone.glb）。
## 状态机：IDLE 泊位悬停 → TO_ORE 飞向未被认领的 S 档矿 → 到达即拖曳
## （ore.start_capture 自动飞站，BeltFlow 送达钩子统一入账）→ 护送至入库。
## 2026-09-30 拍板：拖拽速度 = 玩家拖拽速度的 1/5（按 m/s 移动）；
## 矿拖回空间站后无冷却立即出发下一趟；无目标才回泊位。

enum State { IDLE, TO_ORE, ESCORT, RETURN }

const DroneScene := preload("res://sences/MiningDrone.tscn")
const DRONE_SIZE := 4.5                       # 目标最大边(米) [2026-10-03 拍板: ×5]
const HULL_COLOR := Color(0.5, 0.62, 0.66)    # 无材质低模的机壳色
const DEBUG_SCALE := 50.0                     # debug_instant 时速度×50（headless 测试）
const RETRY_S := 1.0                          # 池内暂无目标时的重试间隔

var belt: BeltFlow
var station: Node3D
var park_pos := Vector3.ZERO                  # 世界坐标停泊位
var claims: Array                             # 与其他无人机共享的认领目标列表

var _state := State.IDLE
var _retry := 0.0
var _hover_t := 0.0
var _target: BeltOre
var _visual: Node3D


func _ready() -> void:
	_visual = DroneScene.instantiate()
	add_child(_visual)
	var max_dim := _mesh_max_dim_of(_visual)
	if max_dim > 0.001:
		_visual.scale = Vector3.ONE * (DRONE_SIZE / max_dim)
	_apply_hull_material(_visual)
	position = park_pos


func _speed() -> float:
	var s: float = GameData.ECON["drone_fly_speed"]
	return s * DEBUG_SCALE if Economy.debug_instant else s


func _process(delta: float) -> void:
	_hover_t += delta
	if _visual != null:
		_visual.rotation.y += delta * 0.6
	match _state:
		State.IDLE:
			position = park_pos + Vector3(0.0, sin(_hover_t * 2.0) * 0.12, 0.0)
			_retry -= delta
			if _retry <= 0.0:
				_try_acquire()
		State.TO_ORE:
			if not _target_valid():
				_forget_target()
				_go_home()
				return
			var d := _target.global_position - global_position
			if d.length() <= 0.6:
				_tow()
			else:
				global_position += d.normalized() * _speed() * delta
				look_at(_target.global_position, Vector3.UP)
		State.ESCORT:
			# 贴着被拖矿飞, 直到 BeltFlow 送达回收(矿消失) → 无冷却立即下一趟
			if _target == null or not is_instance_valid(_target) or not _target.visible:
				_forget_target()
				_try_immediate()
			elif is_instance_valid(_target) and station != null and is_instance_valid(station):
				# 平滑护航: 锚点=拖拽线侧后方, 距离随矿+舰尺寸自适应(防扎进被拖矿)
				var tow_dir := (station.global_position - _target.global_position).normalized()
				var anchor := _target.global_position - tow_dir * (_target.body_radius() + DRONE_SIZE * 0.5 + 0.3) + Vector3(0.0, 0.6, 0.0)
				global_position = global_position.move_toward(anchor, _speed() * 3.0 * delta)
				look_at(_target.global_position, Vector3.UP)
		State.RETURN:
			var home := park_pos - global_position
			if home.length() <= 0.2:
				_state = State.IDLE
				_retry = RETRY_S
				position = park_pos
			else:
				global_position += home.normalized() * _speed() * delta


func _try_acquire() -> void:
	if belt == null or not is_instance_valid(belt):
		_retry = RETRY_S
		return
	var target := belt.get_free_ore("S", claims)
	if target == null:
		if _state == State.IDLE:
			_retry = RETRY_S
		else:
			_go_home()
		return
	claims.append(target)
	_target = target
	_state = State.TO_ORE


## 送达后无冷却直接出发（不回泊位）
func _try_immediate() -> void:
	var target: BeltOre = belt.get_free_ore("S", claims) \
		if belt != null and is_instance_valid(belt) else null
	if target == null:
		_go_home()
		return
	_target = target
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
		and _target.visible and not _target.captured


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
