@tool
extends MeshInstance3D
## 大气控制 — 启用开关 + 漂移/云团大小/透明度,检查器即调即生效(@tool)
## drift_speed 单位 UV/秒:地面速度 ≈ drift_speed × 64 m/s(512m 平面 + scale 8)

@export var enabled := true: set = _set_enabled
@export var drift_speed := Vector2(0.03, 0.008)  # 0.03 ≈ 地面 2 m/s
@export_range(1.0, 64.0, 0.5) var cloud_scale := 8.0: set = _apply_all
@export_range(0.0, 1.0, 0.01) var opacity := 0.9: set = _apply_all

var _mat: StandardMaterial3D


func _set_enabled(v: bool) -> void:
	enabled = v
	visible = v
	if v:
		_apply_all()


func _ready() -> void:
	_apply_all()


func _process(delta: float) -> void:
	if _mat == null:
		_apply_all()
	if not enabled or _mat == null:
		return
	var off: Vector3 = _mat.uv1_offset + Vector3(drift_speed.x, drift_speed.y, 0.0) * delta
	off.x = fposmod(off.x, 1.0)
	off.y = fposmod(off.y, 1.0)
	_mat.uv1_offset = off


func _apply_all(_v: Variant = null) -> void:
	if _mat == null:
		_mat = material_override as StandardMaterial3D
	if _mat == null:
		return
	_mat.uv1_scale = Vector3(cloud_scale, cloud_scale, 1.0)
	var c: Color = _mat.albedo_color
	c.a = opacity
	_mat.albedo_color = c
