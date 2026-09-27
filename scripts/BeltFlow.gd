@tool
class_name BeltFlow
extends Node3D

## 可玩矿石层: 生成区出生 → 沿流向漂移 → 进入消失区回收(对象池循环)
## 编辑器内: 显示橙/红调试框; 运行时: 池化生成 BeltOre
## 矿石 mesh 来自 assets/NormalOre/(普通5种) 与 assets/rareOre/(稀有6种)

const ORE_NORMAL := {
	"NormalOre": "res://assets/NormalOre/NormalOre.glb",
	"metalOre": "res://assets/NormalOre/metalOre.glb",
	"Mesh0": "res://assets/NormalOre/Mesh0.glb",
	"RockOre": "res://assets/NormalOre/RockOre.glb",
}
## 冰矿组: 后续新冰块形态往这里添行(GLB 文件位置不限, 按名索引)
const ORE_ICE := {
	"IceOre": "res://assets/NormalOre/IceOre.glb",
}
const ORE_RARE := {
	"goldSmall": "res://assets/rareOre/goldSmall.glb",
	"IronOre": "res://assets/rareOre/IronOre.glb",
	"BlueGem": "res://assets/rareOre/BlueGem.glb",
	"goldenAsteroid": "res://assets/rareOre/goldenAsteroid.glb",
	"iceBlack": "res://assets/rareOre/iceBlack.glb",
}
# superbigGold 不进流动矿池: 超大金矿, 预留给碎裂效果演示
const TIER_AMOUNT := {"S": 100, "M": 500, "L": 2500, "XL": 5000}
## 这些矿种永远渲染为小尺寸(档位/储量照常掷骰)
const ALWAYS_SMALL := ["goldSmall", "BlueGem"]
## 这些矿种永远只出 S 档(档位/储量锁死; 尺寸随档位自动走 S 区间)
const S_TIER_ONLY := ["Mesh0"]
## 牵引特写小窗(PiP)脚本; 运行时 _start_flow 创建, 捕获时绑定目标
const CloseupCam := preload("res://scripts/TowCloseupCam.gd")

@export_group("生成区")
@export var spawn_center := Vector3(-100, 0, 0):
	set(v):
		spawn_center = v
		_update_debug()
@export var spawn_size := Vector3(10, 12, 60):
	set(v):
		spawn_size = Vector3(maxf(v.x, 0.5), maxf(v.y, 0.5), maxf(v.z, 0.5))
		_update_debug()

@export_group("消失区")
@export var despawn_center := Vector3(60, 0, 0):
	set(v):
		despawn_center = v
		_update_debug()
@export var despawn_size := Vector3(10, 12, 60):
	set(v):
		despawn_size = Vector3(maxf(v.x, 0.5), maxf(v.y, 0.5), maxf(v.z, 0.5))
		_update_debug()

@export_group("流动")
@export var flow_direction := Vector3(1, 0, 0):
	set(v):
		flow_direction = v.normalized() if v.length_squared() > 0.001 else Vector3(1, 0, 0)
@export var flow_speed := 4.0
## 每颗速度 = flow_speed ± speed_variance (绝对值 m/s), 下限 0.05 防反向
@export var speed_variance := 0.25
@export var target_count := 40
## 单颗矿最长存活(秒): 保险丝, 防任何意外滞留的矿占死池子
@export var max_ore_age_s := 600.0
@export var prefill_corridor := true

@export_group("矿石尺寸(按档位)")
## 各档位目标世界尺寸(米, 取矿石最大边); 模型原始大小差异已自动归一化
@export var tier_size_s := 0.8:
	set(v):
		tier_size_s = maxf(v, 0.05)
@export var tier_size_m := 1.6:
	set(v):
		tier_size_m = maxf(v, 0.05)
@export var tier_size_l := 3.0:
	set(v):
		tier_size_l = maxf(v, 0.05)
@export var tier_size_xl := 5.5:
	set(v):
		tier_size_xl = maxf(v, 0.05)
## 同档位个体大小差异(±比例)
@export var size_jitter := 0.15:
	set(v):
		size_jitter = clampf(v, 0.0, 0.9)
## 自转速度范围(rad/s), 每颗矿在 [min, max] 内随机
@export var spin_speed_min := 0.15:
	set(v):
		spin_speed_min = maxf(v, 0.0)
@export var spin_speed_max := 0.9:
	set(v):
		spin_speed_max = maxf(v, 0.0)

@export_group("矿池权重")
## 普通4种 / 冰矿 / 稀有5种 三组出现权重(组内等概率)
@export var normal_ore_weight := 70.0:
	set(v):
		normal_ore_weight = maxf(v, 0.0)
@export var rare_ore_weight := 20.0:
	set(v):
		rare_ore_weight = maxf(v, 0.0)
## 冰矿组权重(冰带主题, 后续扩充形态)
@export var ice_ore_weight := 15.0:
	set(v):
		ice_ore_weight = maxf(v, 0.0)

@export_group("档位权重(资源池掷骰)")
@export var tier_s_weight := 50.0
@export var tier_m_weight := 30.0
@export var tier_l_weight := 15.0
@export var tier_xl_weight := 2.0

@export_group("引力捕获(初级)")
## 弹开后偏出走廊的矿: 超出上/下边带高度即回收
@export var despawn_band_up := 25.0
@export var despawn_band_down := 25.0
## 全域兜底: 离带中心超过该半径(米)的任何方向失踪矿直接回收
@export var despawn_stray_radius := 250.0

@export_group("引力捕获(初级)")
@export var capture_enabled := true
## 空间站节点; 留空则自动找场景里名为 MiningHub 的节点
@export var station_path: NodePath
@export var beam_muzzle_offset := Vector3(0, 0, 0)
## 捕获飞行时长区间(秒): 按捕获瞬间距离自动折算速度, 与设计文档"吸附7~8秒"口径一致
@export var capture_duration_min := 5.0:
	set(v):
		capture_duration_min = maxf(v, 0.5)
@export var capture_duration_max := 10.0:
	set(v):
		capture_duration_max = maxf(v, 0.5)
## 捕获态专用自转速度(rad/s), 与 free 漂移自转独立
@export var capture_spin_speed := 8.0
## 松开光束后自转从捕获速度回落到漂移速度的时长区间(秒, 每颗随机)
@export var spin_recover_min := 3.0:
	set(v):
		spin_recover_min = maxf(v, 0.1)
@export var spin_recover_max := 5.0:
	set(v):
		spin_recover_max = maxf(v, 0.1)
@export var beam_color := Color(0.55, 0.75, 1.0)
## 矿到空间站该距离内算送达(回收)
@export var capture_reach := 3.0

@export_group("空间站避让")
## 站体清空半径: 0=自动(运行时从站体网格AABB推算), >0=手动覆盖(米)
@export var station_clear_radius := 0.0:
	set(v):
		station_clear_radius = maxf(v, 0.0)
## 自动半径的贴边系数: 站体半径×(1+系数); 0.2 = 矿可贴到站壳 20% 距离处
@export var station_clear_margin := 0.2
## 避让推力强度(越大绕得越急)
@export var station_push := 2.5:
	set(v):
		station_push = maxf(v, 0.1)

@export_group("调试")
@export var show_debug_zones := true:
	set(v):
		show_debug_zones = v
		_update_debug()
## 每 3s 的"贴站矿 / 池占用"诊断打印(排查断流时打开)。
## 默认关: 10× 加速下每 3s 模拟时间打一条, 实测 48 分钟游戏时间刷了 966 条。
@export var debug_monitor := false

var _pool: Array[BeltOre] = []
## 生成起点游标: _spawn_one 从它开始找空槽位, 用完前移一位
var _spawn_cursor := 0
var _meshes: Dictionary = {}
var _mesh_max_dim: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _dbg_spawn: MeshInstance3D
var _dbg_despawn: MeshInstance3D
var _started := false
var _station: Node3D
var _beam_fx: GravityBeamFX
var _beam_ids := {}
var _clear_radius := 8.0  # 实际生效的避让半径(自动测量或手动覆盖)
var _dbg_accum2 := 0.0
var _closeup  # TowCloseupCam (CanvasLayer), 运行时创建


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_debug()
	else:
		_start_flow()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _started:
		return
	var muzzle: Variant = _muzzle_pos()
	var station_pos: Vector3 = _station.global_position if _station and is_instance_valid(_station) else Vector3.ZERO
	# 消失区远端在流向轴上的坐标(每帧算一次, 避让/参数变化都实时正确)
	var fd := flow_direction
	var despawn_edge: float = despawn_center.dot(fd) 		+ 0.5 * (absf(fd.x) * despawn_size.x + absf(fd.y) * despawn_size.y + absf(fd.z) * despawn_size.z)
	var active := 0
	for ore in _pool:
		if not ore.visible:
			continue
		active += 1
		if ore.captured:
			# 送达判定
			if muzzle != null and ore.global_position.distance_to(muzzle) <= capture_reach:
				print("BeltFlow: 送达 %s %s 储量%d" % [ore.ore_name, ore.tier, ore.amount])
				_kill_beam(ore)
				ore.set_drifting(false)
			elif muzzle == null:
				ore.set_drifting(false)
				_kill_beam(ore)
		else:
			var lp := to_local(ore.global_position)
			# 回收判定 v2: 沿流向越过消失区远端即回收——
			# 旧"盒内命中"判定会被避让推挤的 Y/Z 偏移漏掉(矿飘出走廊永不回收→池子耗尽)
			if lp.dot(fd) > despawn_edge or ore.age > max_ore_age_s 					or lp.y > despawn_band_up or lp.y < -despawn_band_down 					or lp.length() > despawn_stray_radius:
				ore.set_drifting(false)
			elif _station != null and is_instance_valid(_station):
				# 软避让 v2: 注入径向逃逸速度(旧版直接改坐标与求解器打架, 矿黏站)
				var off := ore.global_position - station_pos
				var d := off.length()
				if d < _clear_radius and d > 0.01:
					var strength := (_clear_radius - d) / _clear_radius
					ore.linear_velocity += off.normalized() * strength * station_push * 10.0 * delta
	if active < target_count:
		_spawn_one()
	# 诊断 v2: 贴站矿专项(每3s: 最近站距/最远X进度) —— 仅 debug_monitor 打开时统计并打印
	if debug_monitor:
		_dbg_accum2 += delta
		if _dbg_accum2 >= 3.0:
			_dbg_accum2 = 0.0
			var nearest := INF
			var near_ore: BeltOre = null
			for ore2 in _pool:
				if not ore2.visible:
					continue
				var d2 := ore2.global_position.distance_to(station_pos)
				if d2 < nearest:
					nearest = d2
					near_ore = ore2
			var lp2 := to_local(near_ore.global_position) if near_ore else Vector3.ZERO
			print("[监控] 最近站距=%.1f (%s %s档 y=%.1f z=%.1f vel=%.2f) 边缘=%.0f 池=%d" % [
				nearest, near_ore.ore_name if near_ore else "-",
				near_ore.tier if near_ore else "-", lp2.y, lp2.z,
				near_ore.linear_velocity.x if near_ore else 0.0,
				despawn_edge, active])


func _muzzle_pos() -> Variant:
	if _station == null or not is_instance_valid(_station):
		return null
	return (_station.global_transform * beam_muzzle_offset) as Vector3


# ---------- 引力捕获 ----------
func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not _started or not capture_enabled:
		return
	# 点住持续牵引, 松开脱离(设计文档 4.4)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_capture()
		else:
			_release_all()


func _release_all() -> void:
	for ore in _pool:
		if ore.captured:
			_kill_beam(ore)
			ore.stop_capture(_rng.randf_range(spin_recover_min, spin_recover_max))


func _try_capture() -> void:
	if _station == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var best: BeltOre = null
	var best_t := INF
	var radius := tier_size_s * 0.5 + 0.6
	for ore in _pool:
		if not ore.visible or ore.captured or ore.tier != "S":
			continue
		var to_ore := ore.global_position - origin
		var t := to_ore.dot(dir)
		if t <= 0.0:
			continue
		var closest := origin + dir * t
		if closest.distance_squared_to(ore.global_position) <= radius * radius and t < best_t:
			best = ore
			best_t = t
	if best:
		_capture(best)


func _capture(ore: BeltOre) -> void:
	var muzzle: Variant = _muzzle_pos()
	if muzzle == null:
		return
	var dist: float = (ore.global_position - muzzle).length()
	var duration := _rng.randf_range(capture_duration_min, capture_duration_max)
	ore.start_capture(_station, dist / maxf(duration, 0.1), capture_spin_speed)
	if _beam_fx:
		_beam_ids[ore] = _beam_fx.spawn(_station, ore)
	if _closeup:
		_closeup.set_target(ore, _tier_size(ore.tier) * 0.5)


func _kill_beam(ore: BeltOre) -> void:
	if _beam_fx and _beam_ids.has(ore):
		_beam_fx.kill(_beam_ids[ore])
	_beam_ids.erase(ore)
	if _closeup:
		_closeup.clear_target(ore)


## 从站体 mesh AABB 实测清空半径(最大半宽 × (1+贴边系数)); 手动覆盖优先
func _measure_station_radius() -> void:
	if station_clear_radius > 0.0:
		_clear_radius = station_clear_radius
		print("BeltFlow: 站体避让半径(手动) = %.1f m" % _clear_radius)
		return
	_clear_radius = 8.0
	var hub := _station
	if hub == null or not is_instance_valid(hub):
		return
	# 找站体下最大的网格 AABB, 沿父链乘全所有缩放(世界真实尺度)
	var best := 0.0
	var stack: Array[Node] = [hub]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			# 世界缩放 = 本节点与 hub 之间所有祖先 scale 的乘积
			var ws := Vector3.ONE
			var walker: Node = mi
			while walker != null and walker != hub:
				ws *= (walker as Node3D).scale if walker is Node3D else Vector3.ONE
				walker = walker.get_parent()
			ws *= hub.global_transform.basis.get_scale()
			var sz := mi.mesh.get_aabb().size * ws
			best = maxf(best, 0.5 * maxf(sz.x, maxf(sz.y, sz.z)))
		for c in n.get_children():
			stack.append(c)
	if best > 0.5:
		_clear_radius = best * (1.0 + station_clear_margin)
	print("BeltFlow: 站体避让半径(自动) = %.1f m (站体半宽 %.1f)" % [_clear_radius, best])


func _start_flow() -> void:
	_rng.seed = hash(name) + int(global_position.x)
	for c in get_children():
		if c.name.begins_with("DEBUG_"):
			c.free()
	_load_meshes()
	_station = get_node_or_null(station_path)
	if _station == null:
		var scene := get_tree().current_scene if get_tree() else null
		if scene:
			_station = scene.find_child("MiningHub", true, false)
	if _station == null:
		push_warning("BeltFlow: 找不到空间站(MiningHub), 引力捕获不可用")
	_measure_station_radius()
	if capture_enabled:
		_beam_fx = GravityBeamFX.new()
		add_child(_beam_fx)
	_closeup = CloseupCam.new()
	add_child(_closeup)
	_pool.clear()
	_spawn_cursor = 0
	for i in target_count:
		var ore := BeltOre.new()
		add_child(ore)
		ore.set_drifting(false)
		_pool.append(ore)
	for i in target_count:
		_spawn_one(prefill_corridor)
	_started = true


func _spawn_one(prefill := false) -> void:
	# 轮转起点取空槽位(而不是固定从 _pool[0] 找第一个不可见的):
	# 旧实现下, 一个"取到就报废"的坏槽位会每帧被取中, 其余空槽位永远轮不到,
	# 单点故障即可让整条矿流停摆。游标每用掉一个槽位前移一位, 天然轮转。
	var n := _pool.size()
	for k in n:
		var idx := (_spawn_cursor + k) % n
		var ore: BeltOre = _pool[idx]
		if ore.visible:
			continue
		var pos := Vector3(
			spawn_center.x + _rng.randf_range(-spawn_size.x, spawn_size.x) * 0.5,
			spawn_center.y + _rng.randf_range(-spawn_size.y, spawn_size.y) * 0.5,
			spawn_center.z + _rng.randf_range(-spawn_size.z, spawn_size.z) * 0.5)
		if prefill:
			pos.x = lerpf(spawn_center.x, despawn_center.x, _rng.randf())
		var ore_name := _pick_ore()
		var tier := _pick_tier()
		if ore_name in S_TIER_ONLY:
			tier = "S"
		var speed := maxf(flow_speed + _rng.randf_range(-speed_variance, speed_variance), 0.05)
		# 流向转到世界空间: 节点被挪动/旋转后矿流跟随节点朝向
		var dir_world := global_transform.basis * flow_direction
		dir_world = dir_world.normalized() if dir_world.length_squared() > 0.001 else Vector3(1, 0, 0)
		# 尺寸 = 档位目标 × 个体抖动 ÷ 模型原始最大边(归一化)
		var tier_size := _tier_size(tier)
		if ore_name in ALWAYS_SMALL:
			tier_size = tier_size_s
		var raw: float = _mesh_max_dim.get(ore_name, 1.0)
		var jitter := _rng.randf_range(1.0 - size_jitter, 1.0 + size_jitter)
		var scale_f := tier_size * jitter / raw
		var radius := tier_size * jitter * 0.5  # 碰撞球半径 = 世界最大边/2
		ore.position = pos
		ore.setup(ore_name, _meshes[ore_name], tier, TIER_AMOUNT[tier],
			dir_world * speed, scale_f, radius,
			spin_speed_min, spin_speed_max)
		ore.set_drifting(true)
		_spawn_cursor = (idx + 1) % n
		return


func _tier_size(tier: String) -> float:
	match tier:
		"M":
			return tier_size_m
		"L":
			return tier_size_l
		"XL":
			return tier_size_xl
	return tier_size_s


func _pick_ore() -> String:
	var total := normal_ore_weight + ice_ore_weight + rare_ore_weight
	if total <= 0.0:
		return ORE_NORMAL.keys()[0]
	var r := _rng.randf() * total
	var names: Array
	if r < normal_ore_weight:
		names = ORE_NORMAL.keys()
	elif r < normal_ore_weight + ice_ore_weight:
		names = ORE_ICE.keys()
	else:
		names = ORE_RARE.keys()
	return names[_rng.randi_range(0, names.size() - 1)]


func _pick_tier() -> String:
	var total := tier_s_weight + tier_m_weight + tier_l_weight + tier_xl_weight
	if total <= 0.0:
		return "S"
	var r := _rng.randf() * total
	if r < tier_s_weight:
		return "S"
	if r < tier_s_weight + tier_m_weight:
		return "M"
	if r < tier_s_weight + tier_m_weight + tier_l_weight:
		return "L"
	return "XL"


func _in_box(p: Vector3, c: Vector3, s: Vector3) -> bool:
	return absf(p.x - c.x) <= s.x * 0.5 and absf(p.y - c.y) <= s.y * 0.5 \
		and absf(p.z - c.z) <= s.z * 0.5


func _load_meshes() -> void:
	_meshes.clear()
	for table in [ORE_NORMAL, ORE_ICE, ORE_RARE]:
		for ore_name in table:
			var path: String = table[ore_name]
			if not ResourceLoader.exists(path):
				push_warning("BeltFlow: 缺少 %s" % path)
				continue
			var packed: PackedScene = load(path)
			if packed == null:
				continue
			var inst := packed.instantiate()
			var mesh := _first_mesh(inst)
			inst.free()
			if mesh != null:
				_meshes[ore_name] = mesh
				var aabb := mesh.get_aabb()
				var md := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
				_mesh_max_dim[ore_name] = maxf(md, 0.001)
	if _meshes.is_empty():
		push_warning("BeltFlow: 没有可用矿石 mesh")


func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and n.mesh != null:
		return n.mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null


# ---------- 编辑器调试框 ----------
func _update_debug() -> void:
	if not Engine.is_editor_hint():
		return
	_dbg_spawn = _ensure_box(_dbg_spawn, "DEBUG_Spawn",
		Color(1.0, 0.55, 0.1), spawn_center, spawn_size)
	_dbg_despawn = _ensure_box(_dbg_despawn, "DEBUG_Despawn",
		Color(0.95, 0.15, 0.12), despawn_center, despawn_size)
	var vis := show_debug_zones
	if _dbg_spawn:
		_dbg_spawn.visible = vis
	if _dbg_despawn:
		_dbg_despawn.visible = vis


func _ensure_box(existing: MeshInstance3D, dbg_name: String, col: Color,
		center: Vector3, size: Vector3) -> MeshInstance3D:
	var mi := existing
	if mi == null:
		mi = get_node_or_null(NodePath(dbg_name))
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = dbg_name
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mi.material_override = mat
		add_child(mi)
	var box := mi.mesh as BoxMesh
	if box == null:
		box = BoxMesh.new()
		mi.mesh = box
	box.size = size
	mi.position = center
	mi.visible = show_debug_zones
	return mi
