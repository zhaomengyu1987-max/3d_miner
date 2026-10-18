@tool
extends Camera3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS
## 挖矿场景相机：拖拽平移 + 滚轮缩放，位置硬钳制在盒形范围内。
## 滚轮缩放固定在运行时起始高度的 ±zoom_range_pct 缩放带内（缩放带优先于 y 盒上限）。
## 运行时始终钳制；编辑器内是否钳制由 clamp_in_editor 控制。

@export var limit_x := 13.0 * U # |x| <= limit_x
@export var limit_y_min := 0.5 * U # y 下限
@export var limit_y_max := 13.0 * U # y 上限（拖拽平移不改 y，y 只由滚轮缩放决定）
@export var limit_z := 10.0 * U # |z| <= limit_z
@export var zoom_range_pct := 0.1      # 滚轮缩放带：起始高度的 ±10%
@export var harbour_zoom_out := 6.0 # 外港原尺寸访客：允许拉远，保留原始近景下限。
@export var clamp_in_editor := false   # 编辑器里移动相机节点时是否也钳制
@export_range(0.0, 0.1, 0.0005, "or_greater", "hide_slider")
var pan_speed := 0.005                 # 平移系数（× 当前高度，米/像素），步长 0.0005
@export_range(0.0, 3.0, 0.005, "or_greater", "hide_slider")
var zoom_speed := 0.15 * U # 每格滚轮沿视线方向移动的距离（米），步长 0.005
@export var wheel_version := 2         # 输入方案版本标记（重载探测用）

var _dragging := false
var _zoom_ref_y := NAN                 # 运行时起始高度（缩放基准）


func _ready() -> void:
	_apply_clamp()
	_zoom_ref_y = global_position.y


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() and not clamp_in_editor:
		return
	_apply_clamp()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_dolly(zoom_speed)   # 向前滚 = 缩近
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_dolly(-zoom_speed)  # 向后滚 = 拉远
	elif event is InputEventMouseMotion and _dragging:
		_pan(event.relative)


func _pan(rel: Vector2) -> void:
	var b := global_transform.basis
	var fwd := -b.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)  # 俯视正下方时退化保护
	var speed := pan_speed * maxf(global_position.y, 0.5 * U)
	# 抓取式平移：画面跟着鼠标走
	global_position += (-b.x * rel.x + fwd.normalized() * rel.y) * speed


func _dolly(amount: float) -> void:
	var zoom_factor := maxf(1.0, global_position.y / maxf(_zoom_ref_y, 1.0))
	global_position += -global_transform.basis.z * amount * 5.0 * zoom_factor


func _apply_clamp() -> void:
	var p := global_position
	var pan_factor := maxf(1.0, p.y / maxf(_zoom_ref_y, 1.0)) if not is_nan(_zoom_ref_y) else 1.0
	p.x = clampf(p.x, -limit_x * pan_factor, limit_x * pan_factor)
	p.z = clampf(p.z, -limit_z * pan_factor, limit_z * pan_factor)
	if is_nan(_zoom_ref_y):
		# 尚未取得缩放基准（编辑器内初次加载）：退化为普通盒钳制
		p.y = clampf(p.y, limit_y_min, limit_y_max)
	else:
		# 缩放带：起始高度 ±zoom_range_pct，优先于 y 盒上限
		var band_lo: float = maxf(_zoom_ref_y * (1.0 - zoom_range_pct), limit_y_min)
		var band_hi: float = maxf(limit_y_max, _zoom_ref_y * maxf(harbour_zoom_out, 1.0 + zoom_range_pct))
		p.y = clampf(p.y, band_lo, band_hi)
	global_position = p
