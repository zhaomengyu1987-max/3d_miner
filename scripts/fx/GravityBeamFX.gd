class_name GravityBeamFX
extends MultiMeshInstance3D

## 引力捕获光束渲染器 —— 磁轨炮 EVE blast.fx 复刻移植版（持续型）
## 原型: E:\godot乱弄2\aitest\aitest scripts/fx/beam_renderer.gd (BeamRenderer)
## 差异: 容量 8 / 持续型生命周期（spawn 后常亮, kill 后 FADE_TIME 淡出）
##       / 无 LOD 恒 L0 全效 / 束宽缩小到炮舰级 / 断言端点失效自动熄灭
## 材质: assets/fx/rail/rail_blast.tres（云图+双 LUT+噪声+ramp 图集）
## COLOR=(tint.rgb, 亮度) ｜ INSTANCE_CUSTOM=(相位, ramp行0=磁轨蓝, LOD, 束长m)

const CAPACITY := 8
const FADE_TIME := 0.25
const RACE_TIME := 0.25    # 光束从炮口"伸到"目标的时长
const HOLD_ALPHA := 0.65

@export var beam_half_width := 0.135
## 远档色调(近档颜色由 ramp 行决定, 磁轨行偏蓝)
@export var beam_tint := Color(0.55, 0.75, 1.0)

var _src: Array = []
var _dst: Array = []
var _t := PackedFloat32Array()      # alive=已持续时长 / fading=已淡出时长
var _dur := PackedFloat32Array()    # fading 时的淡出总时长
var _phase := PackedFloat32Array()
var _state := PackedByteArray()     # 0=空闲 1=按住牵引 2=淡出中
var _fix_from := PackedVector3Array()  # kill 时冻结的端点(防跟踪被回收的矿)
var _fix_to := PackedVector3Array()
var _accum := 0.0

const UPDATE_HZ := 30.0


func _init() -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2, 2)
	var mat: ShaderMaterial = load("res://assets/fx/rail/rail_blast.tres")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = CAPACITY
	mm.visible_instance_count = CAPACITY  # 空槽用零缩放藏住
	multimesh = mm
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in CAPACITY:
		_src.append(null)
		_dst.append(null)
	_t.resize(CAPACITY)
	_dur.resize(CAPACITY)
	_phase.resize(CAPACITY)
	_state.resize(CAPACITY)
	_fix_from.resize(CAPACITY)
	_fix_to.resize(CAPACITY)
	for i in CAPACITY:
		_phase[i] = randf() * 10.0
		multimesh.set_instance_transform(i,
			Transform3D(Basis().scaled(Vector3.ONE * 0.001), Vector3.ZERO))
		multimesh.set_instance_color(i, Color(0, 0, 0, 0))
		multimesh.set_instance_custom_data(i, Color(0, 0, 0, 0))


## 返回槽位 id（-1=满）。src/dst 传 Node3D 实时跟踪。
func spawn(src: Node3D, dst: Node3D) -> int:
	for i in CAPACITY:
		if _state[i] == 0:
			_src[i] = src
			_dst[i] = dst
			_t[i] = 0.0
			_state[i] = 1
			return i
	return -1


## 淡出并释放槽位。端点冻结在当前位置——矿会被回收重生,
## 继续跟踪会把淡出中的光束拽成"站→出生区"的幻影(=多打一发)
func kill(id: int) -> void:
	if id < 0 or id >= CAPACITY:
		return
	if _state[id] == 1:
		_state[id] = 2
		_t[id] = 0.0
		_dur[id] = FADE_TIME
		if is_instance_valid(_src[id]):
			_fix_from[id] = to_local((_src[id] as Node3D).global_position)
		if is_instance_valid(_dst[id]):
			_fix_to[id] = to_local((_dst[id] as Node3D).global_position)


func kill_all() -> void:
	for i in CAPACITY:
		kill(i)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < 1.0 / UPDATE_HZ:
		return
	delta = _accum
	_accum = 0.0
	var cam := get_viewport().get_camera_3d()
	var cam_pos: Vector3 = cam.global_position if cam != null else Vector3.INF
	for i in CAPACITY:
		var src = _src[i]
		if src == null:
			continue
		match _state[i]:
			1:
				_t[i] += delta
			2:
				_t[i] += delta
				if _t[i] >= _dur[i]:
					_free_slot(i)
					continue
		_update_instance(i, cam_pos)


func _free_slot(i: int) -> void:
	_src[i] = null
	_dst[i] = null
	_state[i] = 0
	multimesh.set_instance_transform(i,
		Transform3D(Basis().scaled(Vector3.ONE * 0.001), Vector3.ZERO))
	multimesh.set_instance_color(i, Color(0, 0, 0, 0))


func _update_instance(i: int, cam_pos: Vector3) -> void:
	var src = _src[i]
	var dst = _dst[i]
	var from: Vector3
	var to: Vector3
	if _state[i] == 2:
		# 淡出中: 用冻结端点, 不跟踪
		from = _fix_from[i]
		to = _fix_to[i]
	else:
		if not is_instance_valid(src) or not is_instance_valid(dst):
			_free_slot(i)
			return
		from = to_local((src as Node3D).global_position)
		to = to_local((dst as Node3D).global_position)
	var full_len := from.distance_to(to)
	var tint := beam_tint
	if full_len < 0.05:
		multimesh.set_instance_transform(i,
			Transform3D(Basis().scaled(Vector3.ONE * 0.001), from))
		multimesh.set_instance_color(i, Color(tint.r, tint.g, tint.b, 0.0))
		return
	var dir := (to - from) / full_len
	# 头部生长: 光束从炮口"伸到"目标
	var head_frac := 1.0
	if _state[i] == 1:
		head_frac = minf(_t[i] / RACE_TIME, 1.0)
	var len := full_len * head_frac
	var mid := from + dir * (len * 0.5)
	# 面片朝向相机: 侧轴 = 束向 × 视线
	var view := cam_pos - mid
	var side := dir.cross(view)
	if side.length_squared() < 1.0:
		side = dir.cross(Vector3.UP)
		if side.length_squared() < 1.0:
			side = dir.cross(Vector3.FORWARD)
	side = side.normalized()
	var half := len * 0.5
	var b := Basis(dir * half, side * beam_half_width, dir.cross(side))
	multimesh.set_instance_transform(i, Transform3D(b, mid))
	var alpha := HOLD_ALPHA
	if _state[i] == 2:
		alpha = HOLD_ALPHA * (1.0 - clampf(_t[i] / _dur[i], 0.0, 1.0))
	multimesh.set_instance_color(i, Color(tint.r, tint.g, tint.b, alpha))
	multimesh.set_instance_custom_data(i, Color(_phase[i], 0.0, 0.0, len))
