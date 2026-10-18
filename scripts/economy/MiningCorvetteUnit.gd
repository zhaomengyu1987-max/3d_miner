class_name MiningCorvetteUnit
extends Node3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 激光采矿护卫舰（EVE 式矿船，2026-09-30 拍板，模型 mining_corvette.glb）。
## - 接近矿石后保持作业位置，用中黄挖矿激光开采；舰首朝向航行方向。
## - 各型参数由 MiningShipStats 提供；周期结算，货舱与矿体储量共同限制。
## - 满舱（或矿被挖完）飞回站体卸货入库，卸完立即再出击，无冷却

enum State { IDLE, TO_ORE, MINING, TO_STATION, RETURN }

const ShipScene := preload("res://sences/MiningCorvette.tscn")
const ShipCatalog := preload("res://scripts/ships/MiningShipCatalog.gd")
const Stats := preload("res://scripts/ships/MiningShipStats.gd")
## Shared movement/mining state machine, distinct gameplay profiles.
@export_enum("skiff", "prospector", "barge", "orca", "hulk") var ship_type := "skiff"
const CORVETTE_SIZE := 0.72 * U # 舰长86.4m，与战斗护卫舰86.787m相差约0.45%。
const HULL_COLOR := Color(0.55, 0.58, 0.68)   # 无材质低模的舰壳色
const DEBUG_SCALE := 50.0
const RETRY_S := 1.0
const LASER_TINT := Color(1.0, 0.87, 0.45)    # 中黄
const LASER_FORCE := Color(1.0, 0.72, 0.0, 1.0)  # 富金强制束色（2026-09-30 拍板：采矿=高纯金）
const LASER_HALF_WIDTH := 0.135 * 0.5 * U # 激光半宽（2026-09-30 拍板：基准减半）
const LASER_RAMP_ROW := 3.0                   # rail ramp 图集: 3=橙金(强制通道关闭时的回退)
const GRAVITY_FX := preload("res://scripts/fx/GravityBeamFX.gd")

var belt: BeltFlow
var station: Node3D
var park_pos := Vector3.ZERO
var claims: Array

## 已卸货总量(测试/统计用)
var delivered_total := 0

const Motion := preload("res://scripts/ships/ShipMotion.gd")
var motion := Motion.new()

var _state := State.IDLE
var _retry := 0.0
var _target_generation := -1
var _target: BeltOre
var _visual: Node3D
var _laser: GravityBeamFX
var _laser_id := -1
var _cargo := {}              # ore_id -> 已采单位
var travel_seconds := 0.0
var mining_seconds := 0.0
var full_cargo_count := 0
var mined_total := 0
var mining_attempts := 0
var _mined_frac := 0.0        # 帧内累积的不足 1 单位部分
var _orbit_a := 0.0


func _ready() -> void:
	_visual = get_node_or_null("Visual") as Node3D
	if _visual == null:
		_visual = ShipScene.instantiate()
		add_child(_visual)
	var max_dim := _mesh_max_dim_of(_visual)
	if max_dim > 0.001:
		_visual.scale = Vector3.ONE * (CORVETTE_SIZE / max_dim)
	_visual.rotation.y = PI / 2.0 # Authored +Z bow -> common +X.
	_apply_hull_material(_visual)
	_laser = GRAVITY_FX.new()
	_laser.ramp_row = LASER_RAMP_ROW
	_laser.beam_tint = LASER_TINT
	_laser.force_beam_color = LASER_FORCE
	_laser.beam_half_width = LASER_HALF_WIDTH
	add_child(_laser)


func _speed() -> float:
	var s: float = Stats.speed(ship_type)
	return s * DEBUG_SCALE if Economy.debug_instant else s


func configure_motion() -> void:
	motion.max_speed = _speed()
	motion.acceleration = _speed() * (50.0 if Economy.debug_instant else 1.5)
	motion.turn_rate = 7200.0 if Economy.debug_instant else 60.0


func _process(delta: float) -> void:
	configure_motion()
	if _state == State.MINING:
		mining_seconds += delta
	elif _state in [State.TO_ORE, State.TO_STATION, State.RETURN]:
		travel_seconds += delta
	match _state:
		State.IDLE:
			motion.travel(self, park_pos, delta)
			_retry -= delta
			if _retry <= 0.0:
				_try_acquire()
		State.TO_ORE:
			if not _target_valid():
				_abort_target()
				return
			var d := _target.global_position - global_position
			if d.length() <= _target.body_radius() + CORVETTE_SIZE * 0.5 + 0.6 * U:
				_start_mining()
			else:
				motion.travel(self, _target.global_position, delta)
		State.MINING:
			_mining_tick(delta)
		State.TO_STATION:
			if station == null or not is_instance_valid(station):
				# 无站体（无 MiningHub 的场景/测试）: 卸不了货, 转为返航待命
				_state = State.RETURN
				return
			# Unload at the assigned outer berth; a frigate-sized hull cannot fly into the station centre.
			if motion.travel(self, park_pos, delta):
				_unload()
		State.RETURN:
			if motion.travel(self, park_pos, delta):
				_state = State.IDLE
				_retry = RETRY_S



func _try_acquire() -> void:
	if belt == null or not is_instance_valid(belt):
		_retry = RETRY_S
		return
	# 舱满优先回站
	if _cargo_total() >= Stats.profile(ship_type)["cargo"] - 0.5:
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
	_target_generation = target.generation
	_state = State.TO_ORE


func _start_mining() -> void:
	_state = State.MINING
	var approach := global_position - _target.global_position
	_orbit_a = atan2(approach.z, approach.x)
	_mined_frac = 0.0
	if _laser_id < 0:
		_laser_id = _laser.spawn(self, _target)


func _mining_tick(delta: float) -> void:
	if not _target_valid():
		_abort_target()
		return
	# Hold the approach-side mining station; no random orbit or broadside chase.
	var radius := _target.body_radius() + CORVETTE_SIZE * 0.5 + 0.8 * U
	var desired := _target.global_position \
		+ Vector3(cos(_orbit_a) * radius, 0.4 * U, sin(_orbit_a) * radius)
	motion.travel(self, desired, delta)
	var oid := GameData.asset_to_ore(_target.ore_name)
	if oid == "":
		_abort_target()
		return
	var profile := Stats.profile(ship_type)
	_mined_frac += delta * (DEBUG_SCALE if Economy.debug_instant else 1.0)
	var interval := float(profile.interval)
	while _mined_frac >= interval:
		_mined_frac -= interval
		mining_attempts += 1
		var chance := Stats.chance(ship_type, oid)
		var rolls := int(floor(chance)) + (1 if randf() < fmod(chance, 1.0) else 0)
		var available := int(profile.cargo) - int(_cargo_total())
		var u := mini(rolls * int(profile["yield"]), available)
		u = _target.extract_units(u)
		if u > 0:
			_cargo[oid] = int(_cargo.get(oid, 0)) + u
			mined_total += u
		if _target.amount <= 0 or _cargo_total() >= float(profile.cargo):
			break
	if _cargo_total() >= float(profile.cargo):
		full_cargo_count += 1
	# 矿被挖完 → 回收进池; 舱满 → 回站卸货
	if _target.amount <= 0:
		_target.set_drifting(false)
		_forget_target()
		_stop_laser()
		_state = State.TO_STATION
	elif _cargo_total() >= Stats.profile(ship_type)["cargo"] - 0.5:
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
	_target_generation = target.generation
	claims.append(target)
	_state = State.TO_ORE


## 目标丢失(漂出走廊被回收等): 保住已采矿量, 激光熄灭
func _abort_target() -> void:
	_forget_target()
	_stop_laser()
	if _cargo_total() >= Stats.profile(ship_type)["cargo"] - 0.5:
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
	return _target != null and is_instance_valid(_target) and _target.visible and not _target.captured and _target.amount > 0 and _target.generation == _target_generation


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
	ShipCatalog.apply_material(root, ship_type)


func debug_stats() -> Dictionary:
	return {"ship_type": ship_type, "speed_mps": _speed(), "cargo": _cargo_total(),
		"capacity": Stats.profile(ship_type).cargo, "mined": mined_total,
		"delivered": delivered_total, "travel_seconds": travel_seconds,
		"mining_seconds": mining_seconds, "full_cargo_count": full_cargo_count,
		"attempts": mining_attempts}


func _exit_tree() -> void:
	if claims != null:
		claims.erase(_target)
