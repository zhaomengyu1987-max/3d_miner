class_name MiningCorvetteUnit
extends Node3D

## 激光采矿护卫舰（EVE 式矿船，2026-09-30 拍板，模型 mining_corvette.glb）。
## - 只挖 M 档矿：接近后环绕目标，用中黄挖矿激光（牵引光束材质 ramp 橙金行）开采
## - 货舱 500 单位（草案），采矿 5 单位/秒（草案）
## - 满舱（或矿被挖完）飞回站体卸货入库，卸完立即再出击，无冷却

enum State { IDLE, TO_ORE, MINING, TO_STATION, RETURN }

const ShipScene := preload("res://sences/MiningCorvette.tscn")
const CORVETTE_SIZE := 7.2                    # 目标最大边(米) [2026-10-03 拍板: ×3]
const HULL_COLOR := Color(0.55, 0.58, 0.68)   # 无材质低模的舰壳色
const DEBUG_SCALE := 50.0
const RETRY_S := 1.0
const LASER_TINT := Color(1.0, 0.87, 0.45)    # 中黄
const LASER_FORCE := Color(1.0, 0.72, 0.0, 1.0)  # 富金强制束色（2026-09-30 拍板：采矿=高纯金）
const LASER_HALF_WIDTH := 0.135 * 0.5         # 激光半宽（2026-09-30 拍板：基准减半）
const LASER_RAMP_ROW := 3.0                   # rail ramp 图集: 3=橙金(强制通道关闭时的回退)
const GRAVITY_FX := preload("res://scripts/fx/GravityBeamFX.gd")

var belt: BeltFlow
var station: Node3D
var park_pos := Vector3.ZERO
var claims: Array

## 已卸货总量(测试/统计用)
var delivered_total := 0

var _state := State.IDLE
var _retry := 0.0
var _hover_t := 0.0
var _target: BeltOre
var _visual: Node3D
var _laser: GravityBeamFX
var _laser_id := -1
var _cargo := {}              # ore_id -> 已采单位
var _mined_frac := 0.0        # 帧内累积的不足 1 单位部分
var _orbit_a := 0.0


func _ready() -> void:
	_visual = ShipScene.instantiate()
	add_child(_visual)
	var max_dim := _mesh_max_dim_of(_visual)
	if max_dim > 0.001:
		_visual.scale = Vector3.ONE * (CORVETTE_SIZE / max_dim)
	_apply_hull_material(_visual)
	_laser = GRAVITY_FX.new()
	_laser.ramp_row = LASER_RAMP_ROW
	_laser.beam_tint = LASER_TINT
	_laser.force_beam_color = LASER_FORCE
	_laser.beam_half_width = LASER_HALF_WIDTH
	add_child(_laser)


func _speed() -> float:
	var s: float = GameData.ECON["corvette_fly_speed"]
	return s * DEBUG_SCALE if Economy.debug_instant else s


func _process(delta: float) -> void:
	_hover_t += delta
	match _state:
		State.IDLE:
			position = park_pos + Vector3(0.0, sin(_hover_t * 1.6) * 0.15, 0.0)
			_retry -= delta
			if _retry <= 0.0:
				_try_acquire()
		State.TO_ORE:
			if not _target_valid():
				_abort_target()
				return
			var d := _target.global_position - global_position
			if d.length() <= _target.body_radius() + CORVETTE_SIZE * 0.5 + 0.6:
				_start_mining()
			else:
				global_position += d.normalized() * _speed() * delta
				look_at(_target.global_position, Vector3.UP)
		State.MINING:
			_mining_tick(delta)
		State.TO_STATION:
			if station == null or not is_instance_valid(station):
				# 无站体（无 MiningHub 的场景/测试）: 卸不了货, 转为返航待命
				_state = State.RETURN
				return
			var d := station.global_position - global_position
			if d.length() <= 2.0:
				_unload()
			else:
				global_position += d.normalized() * _speed() * delta
				look_at(station.global_position, Vector3.UP)
		State.RETURN:
			var home := park_pos - global_position
			if home.length() <= 0.25:
				_state = State.IDLE
				_retry = RETRY_S
				position = park_pos
			else:
				global_position += home.normalized() * _speed() * delta


func _try_acquire() -> void:
	if belt == null or not is_instance_valid(belt):
		_retry = RETRY_S
		return
	# 舱满优先回站
	if _cargo_total() >= GameData.ECON["corvette_cargo"] - 0.5:
		_state = State.TO_STATION
		return
	var target := belt.get_free_ore_random(claims)  # 无优先随机、避开 S 档(2026-10-03 拍板)
	if target == null:
		if _cargo_total() > 0.0:
			_state = State.TO_STATION  # 池里没 M 矿: 先把货送回去
		elif _state == State.IDLE:
			_retry = RETRY_S
		else:
			_go_home()
		return
	claims.append(target)
	_target = target
	_state = State.TO_ORE


func _start_mining() -> void:
	_state = State.MINING
	_orbit_a = randf() * TAU
	_mined_frac = 0.0
	if _laser_id < 0:
		_laser_id = _laser.spawn(self, _target)


func _mining_tick(delta: float) -> void:
	if not _target_valid():
		_abort_target()
		return
	# 环绕目标(EVE 矿船式盘旋)——角速度见 GameData.ECON["corvette_orbit_speed"]
	_orbit_a += delta * float(GameData.ECON["corvette_orbit_speed"])
	var radius := _target.body_radius() + CORVETTE_SIZE * 0.5 + 0.8
	var desired := _target.global_position \
		+ Vector3(cos(_orbit_a) * radius, 0.4, sin(_orbit_a) * radius)
	global_position = global_position.move_toward(desired, _speed() * delta)
	look_at(_target.global_position, Vector3.UP)
	# 采矿速率: 5 单位/秒(草案), debug 下 ×50
	var rate: float = GameData.ECON["corvette_mine_rate"]
	if Economy.debug_instant:
		rate *= DEBUG_SCALE
	_mined_frac += rate * delta
	var whole := int(_mined_frac)
	if whole <= 0:
		return
	_mined_frac -= whole
	var cap_space := int(GameData.ECON["corvette_cargo"]) - int(_cargo_total())
	var u: int = mini(whole, cap_space)
	u = mini(u, _target.amount)
	if u <= 0:
		return
	var oid := GameData.asset_to_ore(_target.ore_name)
	if oid == "":
		_abort_target()
		return
	_target.mine_units(u)
	_cargo[oid] = int(_cargo.get(oid, 0)) + u
	# 矿被挖完 → 回收进池; 舱满 → 回站卸货
	if _target.amount <= 0:
		_target.set_drifting(false)
		_forget_target()
		_stop_laser()
		_state = State.TO_STATION
	elif _cargo_total() >= GameData.ECON["corvette_cargo"] - 0.5:
		_forget_target()
		_stop_laser()
		_state = State.TO_STATION


## 回站卸货: 走 Economy.deliver_ore 统一入账(燃料/稀有矿提示一致)
func _unload() -> void:
	for oid in _cargo:
		var units: int = _cargo[oid]
		if units > 0:
			delivered_total += units
			Economy.deliver_ore(GameData.ORES[oid]["asset"], units)
	_cargo.clear()
	_try_immediate()


## 卸完/无目标立即再出击(不回泊位)
func _try_immediate() -> void:
	# 全类型皆挖、优先大块(2026-10-02 拍板)
	var target: BeltOre = belt.get_free_ore_random(claims) \
		if belt != null and is_instance_valid(belt) else null
	if target == null:
		if _cargo_total() > 0.0:
			_state = State.TO_STATION
		else:
			_go_home()
		return
	_target = target
	claims.append(target)
	_state = State.TO_ORE


## 目标丢失(漂出走廊被回收等): 保住已采矿量, 激光熄灭
func _abort_target() -> void:
	_forget_target()
	_stop_laser()
	if _cargo_total() >= GameData.ECON["corvette_cargo"] - 0.5:
		_state = State.TO_STATION
	elif _state == State.MINING or _state == State.TO_ORE:
		_try_immediate()


func _stop_laser() -> void:
	if _laser_id >= 0:
		_laser.kill(_laser_id)
		_laser_id = -1


func _go_home() -> void:
	_state = State.RETURN


func _cargo_total() -> float:
	var t := 0
	for oid in _cargo:
		t += int(_cargo[oid])
	return float(t)


func _target_valid() -> bool:
	return _target != null and is_instance_valid(_target) and _target.visible


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
	m.metallic = 0.55
	m.roughness = 0.45
	for mi in meshes:
		mi.material_override = m
