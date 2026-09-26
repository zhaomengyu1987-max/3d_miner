@tool
class_name IceBelt
extends Node3D

## 矩形碎冰带生成器（编辑器内实时重建）
## 资源: res://assets/models/ice/ice_chunks.glb 内 6 个 IceChunk_S0x 节点

const CHUNKS_SCENE := "res://assets/models/ice/ice_chunks.glb"
const MAX_INSTANCES := 50000
## scale 手柄的参考尺寸: scale=(1,1,1) 对应 30×12 的带区
const REF_LENGTH := 30.0
const REF_WIDTH := 12.0

@export var belt_length := 30.0:
	set(v):
		belt_length = maxf(v, 0.5)
		_rebuild()
@export var belt_width := 12.0:
	set(v):
		belt_width = maxf(v, 0.5)
		_rebuild()
## 每平方米碎冰数量(网格步长 = 1/√density; 改动会重铺网格, 长宽调整则只动边缘)
@export var density := 2.0:
	set(v):
		density = maxf(v, 0.0)
		_rebuild()
## 重新撒布时保持不变的随机种子
@export var seed_value := 20260926:
	set(v):
		seed_value = v
		_rebuild()
## 碎冰基础缩放（原始块仅 2~6cm）
@export var chunk_scale := 4.0:
	set(v):
		chunk_scale = maxf(v, 0.05)
		_rebuild()
@export var scale_min := 0.7:
	set(v):
		scale_min = maxf(v, 0.05)
		_rebuild()
@export var scale_max := 1.6:
	set(v):
		scale_max = maxf(v, 0.05)
		_rebuild()
@export var height_jitter := 0.08
## true = 全方位随机翻滚朝向; false = 平躺(随机偏航 + tilt_max 内倾斜)
@export var tumble := true:
	set(v):
		tumble = v
		_rebuild()
@export var tilt_max := 0.25
@export var cast_shadows := false:
	set(v):
		cast_shadows = v
		_apply_shadow_mode()
@export_tool_button("重新生成") var rebuild_btn: Callable = rebuild
## 构建标记(仅用于验证编辑器加载的脚本版本)
@export var gen_version := 2

var _meshes: Array[Mesh] = []


## 拦截节点 scale: 拖缩放手柄改变冰带区域(长×宽), 冰块个体不拉伸
## 绝对映射: scale.x = belt_length / REF_LENGTH, scale.z = belt_width / REF_WIDTH
func _get(property: StringName) -> Variant:
	if property == &"scale":
		return Vector3(belt_length / REF_LENGTH, 1.0, belt_width / REF_WIDTH)
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"scale":
		var v := Vector3.ZERO
		if value is Vector3:
			v = value
		elif value is Vector3i:
			v = Vector3(value)
		elif value is Array and (value as Array).size() >= 3:
			var a: Array = value
			v = Vector3(float(a[0]), float(a[1]), float(a[2]))
		else:
			return false
		belt_length = clampf(REF_LENGTH * v.x, 0.5, 5000.0)
		belt_width = clampf(REF_WIDTH * maxf(v.z, 0.001), 0.5, 5000.0)
		return true
	return false


func _ready() -> void:
	_rebuild()


func rebuild() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_node_ready():
		return
	if _meshes.is_empty():
		if not _load_meshes():
			return
	for c in get_children():
		if c is MultiMeshInstance3D:
			c.free()
	# 确定性网格散布: 每格内容由 hash(格坐标, seed) 决定, 与带区尺寸无关。
	# 改 belt_length/width 只改变"哪些格子在带区内" —— 边缘增减冰块, 存量不动。
	var step := 1.0 / sqrt(maxf(density, 0.01))
	var nx := int(ceil(belt_length / step))
	var nz := int(ceil(belt_width / step))
	if nx * nz > MAX_INSTANCES:
		push_warning("IceBelt: 网格数 %d 超上限 %d, 请降低 density 或缩小带区" % [nx * nz, MAX_INSTANCES])
		return
	var hx := belt_length * 0.5
	var hz := belt_width * 0.5
	var per_variant: Array = []
	for i in _meshes.size():
		per_variant.append([])
	for ix in nx:
		for iz in nz:
			var px := (float(ix) + 0.5) * step
			var pz := (float(iz) + 0.5) * step
			if absf(px) > hx or absf(pz) > hz:
				continue
			var rng := RandomNumberGenerator.new()
			rng.seed = _cell_hash(ix, iz)
			px += rng.randf_range(-0.45, 0.45) * step
			pz += rng.randf_range(-0.45, 0.45) * step
			var idx := rng.randi_range(0, _meshes.size() - 1)
			var basis: Basis
			if tumble:
				var axis := Vector3(
					rng.randf_range(-1.0, 1.0),
					rng.randf_range(-1.0, 1.0),
					rng.randf_range(-1.0, 1.0))
				if axis.length_squared() < 0.001:
					axis = Vector3.UP
				basis = Basis(axis.normalized(), rng.randf_range(0.0, TAU))
			else:
				basis = Basis.from_euler(Vector3(
					rng.randf_range(-tilt_max, tilt_max),
					rng.randf_range(0.0, TAU),
					rng.randf_range(-tilt_max, tilt_max)))
			var s := chunk_scale * rng.randf_range(scale_min, scale_max)
			basis = basis.scaled(Vector3.ONE * s)
			var pos := Vector3(px, rng.randf_range(-height_jitter, height_jitter), pz)
			per_variant[idx].append(Transform3D(basis, pos))
	for i in _meshes.size():
		var list: Array = per_variant[i]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _meshes[i]
		mm.instance_count = list.size()
		for j in list.size():
			mm.set_instance_transform(j, list[j])
		var mmis := MultiMeshInstance3D.new()
		mmis.name = "Variant_%02d" % i
		mmis.multimesh = mm
		mmis.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			if not cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mmis)


func _cell_hash(ix: int, iz: int) -> int:
	var h := int(seed_value)
	h = (h ^ (ix * 0x9E3779B9)) * 0x85EBCA6B
	h = (h ^ (iz * 0xC2B2AE3D)) * 0x27D4EB2F
	h ^= h >> 15
	return h


func _apply_shadow_mode() -> void:
	if not is_node_ready():
		return
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
		if not cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for c in get_children():
		if c is MultiMeshInstance3D:
			c.cast_shadow = mode


func _load_meshes() -> bool:
	if not ResourceLoader.exists(CHUNKS_SCENE):
		push_warning("IceBelt: 找不到 %s" % CHUNKS_SCENE)
		return false
	var packed: PackedScene = load(CHUNKS_SCENE)
	if packed == null:
		return false
	var inst := packed.instantiate()
	var found: Array[Mesh] = []
	_collect_meshes(inst, found)
	inst.free()
	found.sort_custom(func(a, b): return a.resource_name < b.resource_name)
	_meshes = found
	if _meshes.is_empty():
		push_warning("IceBelt: GLB 内没有 MeshInstance3D")
		return false
	return true


func _collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		out.append(node.mesh)
	for c in node.get_children():
		_collect_meshes(c, out)
