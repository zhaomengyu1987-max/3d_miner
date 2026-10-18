extends CanvasLayer

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS
## 牵引特写小窗 (PiP): 左键牵引矿石时, 右下角出现长焦观察画面。
## 机位 = 目标沿主相机视线方向后方 TELE_DIST 米处, 朝向与主相机一致,
## FOV 按目标尺寸动态收窄 —— 效果等同主相机拉长焦, 而非贴脸微距。
## 由 BeltFlow 在运行时创建: set_target(ore, radius) 绑定显示,
## clear_target(ore) 或目标失效(送达/松开/回收)自动隐藏。
## SubViewport 共享主 World3D(own_world_3d=false); 控件全部 IGNORE 不挡拾取。

const VIEW_SIZE := Vector2i(360, 270)
const MARGIN := 16
const BORDER := 2
const TELE_DIST := 20.0 * U # 长焦机位与目标的距离(米): 越大长焦压缩感越强
const FRAME_FILL := 2.4      # 目标在画面中的占比(目标半径的倍数)
const FOLLOW_SPEED := 8.0    # 机位平滑(越大越跟手)
const DOF_AMOUNT := 0.15     # 焦外虚化强度(0~1), 400mm 浅景深

var _container: SubViewportContainer
var _cam: Camera3D
var _attrs: CameraAttributesPractical
var _target: Node3D
var _target_radius := 0.5 * U
var _cam_pos := Vector3.ZERO
var _snapped := false
var _free_dist := TELE_DIST  # 遮挡钳制后的机位距离(_physics_process 更新)


func _ready() -> void:
	layer = 10
	visible = false
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# 深色半透明描边底框
	var frame := ColorRect.new()
	frame.color = Color(0.05, 0.1, 0.16, 0.85)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	frame.offset_left = -VIEW_SIZE.x - MARGIN
	frame.offset_top = -VIEW_SIZE.y - MARGIN
	frame.offset_right = -MARGIN + BORDER
	frame.offset_bottom = -MARGIN + BORDER
	root.add_child(frame)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_container.offset_left = -VIEW_SIZE.x - MARGIN + BORDER
	_container.offset_top = -VIEW_SIZE.y - MARGIN + BORDER
	_container.offset_right = -MARGIN
	_container.offset_bottom = -MARGIN
	root.add_child(_container)

	var vp := SubViewport.new()
	vp.own_world_3d = false            # 共享主世界
	vp.handle_input_locally = false
	_container.add_child(vp)

	_cam = Camera3D.new()
	_cam.near = 0.05 * U
	_cam.far = 4000.0 * U
	# 长焦浅景深: 焦平面锁在矿石上, 每帧按机位距离更新前后景虚化范围
	_attrs = CameraAttributesPractical.new()
	_attrs.dof_blur_far_enabled = true
	_attrs.dof_blur_near_enabled = true
	_attrs.dof_blur_amount = DOF_AMOUNT
	_cam.attributes = _attrs
	vp.add_child(_cam)
	_cam.make_current()


func _main_view_dir() -> Vector3:
	var main_cam := get_viewport().get_camera_3d()
	if main_cam != null:
		var vd := -main_cam.global_transform.basis.z
		if vd.length_squared() > 0.0001:
			return vd.normalized()
	return Vector3(0.3, -0.5, -1.0).normalized()


func _physics_process(_delta: float) -> void:
	# 机位遮挡钳制: 目标与理想机位之间被空间站等刚体挡住时拉近机位
	_free_dist = TELE_DIST
	if _target == null or not is_instance_valid(_target):
		return
	var space := get_viewport().get_world_3d().direct_space_state
	if space == null:
		return
	var desired := _target.global_position - _main_view_dir() * TELE_DIST
	var q := PhysicsRayQueryParameters3D.create(_target.global_position, desired)
	var hit := space.intersect_ray(q)
	if not hit.is_empty() and hit.has("position"):
		var d_hit: float = (hit.position as Vector3).distance_to(_target.global_position)
		_free_dist = maxf(d_hit * 0.85, _target_radius * 1.5)


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target) or not _target.visible:
		visible = false
		_target = null
		return
	visible = true
	var view_dir := _main_view_dir()
	var dist := _free_dist
	var desired := _target.global_position - view_dir * dist
	if not _snapped:
		_cam_pos = desired
		_snapped = true
	else:
		_cam_pos = _cam_pos.lerp(desired, 1.0 - exp(-FOLLOW_SPEED * delta))
	_cam.global_position = _cam_pos
	# 长焦取景: FOV = 目标按 FRAME_FILL 倍半径充满画面
	var d := maxf(_cam_pos.distance_to(_target.global_position), 0.5 * U)
	_cam.fov = rad_to_deg(2.0 * atan(_target_radius * FRAME_FILL / d))
	# 焦平面跟焦: 矿石清晰, 前后景(冰尘/星空/远处站体)迅速进入焦外
	_attrs.dof_blur_far_distance = d + _target_radius * 1.5
	_attrs.dof_blur_far_transition = maxf(d * 0.10, 0.5 * U)
	_attrs.dof_blur_near_distance = maxf(d - _target_radius * 2.5, 0.1 * U)
	_attrs.dof_blur_near_transition = maxf(d * 0.08, 0.3 * U)
	var up := Vector3.UP
	if absf(view_dir.dot(up)) > 0.95:
		up = Vector3(0, 0, 1)          # 视线近乎竖直时换参考轴
	_cam.look_at(_target.global_position, up)


func set_target(ore: Node3D, radius := 0.5 * U) -> void:
	if ore == null:
		clear_target()
		return
	if ore != _target:
		_snapped = false               # 换目标时机位立刻贴合
	_target = ore
	_target_radius = maxf(radius, 0.05 * U)


func clear_target(ore: Node3D = null) -> void:
	if ore == null or ore == _target:
		_target = null
		visible = false
