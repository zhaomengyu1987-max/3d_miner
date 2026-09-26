@tool
class_name IceFlow
extends Node3D

## 纯表演层冰流 v2 —— GPUParticles3D 引擎原生粒子流
## 设计原则: 零 @tool / 零编辑器预览 / 零 MultiMesh 手工管理
## 编辑器内本节点不可见(设计使然); F5 运行时生成, 脚本永远从磁盘新载
##
## 原理: 每种冰块一个 GPUParticles3D, 发射盒 = 整个冰带体积,
## 粒子沿流向匀速移动, 寿命 = 长度/速度, 走完自动重生 → 无限流动
## 6 个系统各配不同速度 → 天然差速视差

const CHUNKS_SCENE := "res://assets/models/ice/ice_chunks.glb"
const SYSTEM_COUNT := 6  # 每种冰块一个粒子系统

@export_group("冰带体积(发射区)")
## 流动方向上的长度(米)
@export var field_length := 150.0:
	set(v):
		field_length = maxf(v, 10.0)
		_update_debug()
## 宽度(米)
@export var field_width := 100.0:
	set(v):
		field_width = maxf(v, 5.0)
		_update_debug()
## 垂直厚度(米) —— 体积的关键参数
@export var field_thickness := 15.0:
	set(v):
		field_thickness = maxf(v, 1.0)
		_update_debug()

@export_group("流动")
@export var flow_direction := Vector3(1, 0, 0):
	set(v):
		flow_direction = v.normalized() if v.length_squared() > 0.001 else Vector3(1, 0, 0)
		_update_debug()
## 基础流速(m/s), 6 个系统在其 ±speed_variance/2 内均布 → 差速
@export var flow_speed := 5.0
@export var speed_variance := 3.0

@export_group("冰块")
@export var total_count := 6000
## 缩放是乘在原始网格(~0.06m)上的倍率: 8~30 → 0.5~1.8m 冰块
@export var scale_min := 8.0
@export var scale_max := 30.0
## 自转速度范围(rad/s)
@export var spin_min := 0.5
@export var spin_max := 3.0

@export_group("调试")
@export var show_debug_zones := true:
	set(v):
		show_debug_zones = v
		_update_debug()

var _systems: Array[GPUParticles3D] = []
var _dbg_volume: MeshInstance3D
var _dbg_slab: MeshInstance3D


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_debug()
	else:
		_free_debug()
		_build()


func _build() -> void:
	_free_debug()
	for s in _systems:
		if is_instance_valid(s):
			s.free()
	_systems.clear()
	var meshes := _load_meshes()
	if meshes.is_empty():
		push_warning("IceFlow: 没有可用冰块 mesh, 检查 %s" % CHUNKS_SCENE)
		return
	var dir := flow_direction.normalized() if flow_direction.length_squared() > 0.001 \
		else Vector3(1, 0, 0)
	var per_system := total_count / SYSTEM_COUNT
	if per_system > 5000:
		push_warning("IceFlow: 每系统 %d 粒子过多, preprocess 会卡; 建议 total_count ≤ 30000" % per_system)
	var last_lifetime := 0.0
	for i in SYSTEM_COUNT:
		var mesh: Mesh = meshes[i % meshes.size()]
		# 差速: 系统速度在 [speed-var/2, speed+var/2] 均布
		var speed: float = flow_speed - speed_variance * 0.5 \
			+ speed_variance * float(i) / float(SYSTEM_COUNT - 1)
		var lifetime: float = field_length / maxf(speed, 0.1)
		last_lifetime = lifetime
		var p := GPUParticles3D.new()
		p.name = "Ice_%d" % i
		p.amount = per_system
		p.lifetime = lifetime
		p.preprocess = lifetime  # 开局预填满整条带, 无空白期
		p.draw_pass_1 = mesh
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var pm := ParticleProcessMaterial.new()
		# 发射区 = 上游边缘的一片薄板: 粒子从边缘出生(视野外), 飘完全程在下游消失
		# — 而不是全体积随机出生(那就是"凭空出现")
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.5, field_thickness * 0.5, field_width * 0.5)
		pm.direction = dir
		pm.spread = 0.0
		pm.initial_velocity_min = speed
		pm.initial_velocity_max = speed
		pm.gravity = Vector3.ZERO
		# 3D 网格粒子的旋转必须走 rotation_3d 通道:
		# angle/angular_velocity 仅在 disable_z / rotate_y / BILLBOARD 时生效(官方文档)
		pm.use_rotation_3d = true
		pm.rotation_3d_min = Vector3.ZERO
		pm.rotation_3d_max = Vector3(360.0, 360.0, 360.0)  # 随机初始姿态(度)
		pm.use_rotation_velocity_3d = true
		var spin_d := rad_to_deg(spin_max)  # 导出口径 rad/s → 引擎 度/s
		pm.rotation_velocity_3d_min = Vector3(-spin_d, -spin_d, -spin_d)
		pm.rotation_velocity_3d_max = Vector3(spin_d, spin_d, spin_d)
		pm.scale_min = scale_min
		pm.scale_max = scale_max
		p.process_material = pm
		p.position = -dir * field_length * 0.5  # 系统节点放在上游边缘
		# 可见性 AABB 必须罩住"出生板+整段飞行路径", 否则相机稍偏整个系统被剔除(经典坑)
		var aabb_size := Vector3(field_length + 2.0, field_thickness + 2.0, field_width + 2.0) \
			+ dir.abs() * 2.0
		p.visibility_aabb = AABB(dir * field_length * 0.5 - aabb_size * 0.5, aabb_size)
		add_child(p)
		_systems.append(p)
	print("IceFlow: built %d systems, %d particles total, lifetime=%.1fs" %
		[_systems.size(), total_count, last_lifetime])


func _load_meshes() -> Array[Mesh]:
	var out: Array[Mesh] = []
	if not ResourceLoader.exists(CHUNKS_SCENE):
		push_warning("IceFlow: 找不到 %s" % CHUNKS_SCENE)
		return out
	var packed: PackedScene = load(CHUNKS_SCENE)
	if packed == null:
		return out
	var inst := packed.instantiate()
	_collect_meshes(inst, out)
	inst.free()
	return out


func _collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		out.append(node.mesh)
	for c in node.get_children():
		_collect_meshes(c, out)


## ---------- 编辑器调试框(仅编辑器可见, 运行时清除) ----------
func _free_debug() -> void:
	for c in get_children():
		if c.name.begins_with("DEBUG_"):
			c.free()
	_dbg_volume = null
	_dbg_slab = null


func _update_debug() -> void:
	if not Engine.is_editor_hint() or not is_node_ready():
		return
	var dir := flow_direction.normalized() if flow_direction.length_squared() > 0.001 else Vector3(1, 0, 0)
	_dbg_volume = _ensure_box(_dbg_volume, "DEBUG_Volume", Color(0.3, 0.8, 1.0, 0.25),
		Vector3.ZERO, Vector3(field_length, field_thickness, field_width), dir)
	_dbg_slab = _ensure_box(_dbg_slab, "DEBUG_SpawnEdge", Color(0.2, 1.0, 0.4),
		-dir * field_length * 0.5, Vector3(1.0, field_thickness, field_width), dir)
	if _dbg_volume:
		_dbg_volume.visible = show_debug_zones
	if _dbg_slab:
		_dbg_slab.visible = show_debug_zones


func _ensure_box(existing: MeshInstance3D, dbg_name: String, col: Color,
		center: Vector3, size: Vector3, dir: Vector3) -> MeshInstance3D:
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
	# 盒子 X 轴对齐流向
	var zax := dir.cross(Vector3.UP).normalized() if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.RIGHT
	var yax := zax.cross(dir)
	mi.transform = Transform3D(Basis(dir, yax, zax), center)
	mi.visible = show_debug_zones
	return mi
