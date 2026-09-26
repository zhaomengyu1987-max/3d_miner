@tool
extends Control

## 常驻相机预览: SubViewport 共享编辑器 World3D, 镜像相机每帧跟随场景 Camera3D

const FIND_INTERVAL := 0.5

var _sv: SubViewport
var _mirror: Camera3D
var _cam: Camera3D
var _label: Label
var _find_timer := 0.0
var _world: World3D


func _ready() -> void:
	custom_minimum_size = Vector2(0, 280)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.anchor_right = 1.0
	v.anchor_bottom = 1.0
	add_child(v)
	_label = Label.new()
	_label.text = "PreviewCam: 启动中"
	v.add_child(_label)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(svc)
	_sv = SubViewport.new()
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svc.add_child(_sv)
	_mirror = Camera3D.new()
	_mirror.current = true
	_sv.add_child(_mirror)


func _process(delta: float) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_label.text = "PreviewCam: 无打开场景"
		return
	_find_timer -= delta
	if _find_timer <= 0.0 or not is_instance_valid(_cam) or not _cam.is_inside_tree():
		_find_timer = FIND_INTERVAL
		_cam = _find_camera(root)
	if _cam == null:
		_label.text = "PreviewCam: 场景中无 Camera3D"
		return
	var evp := EditorInterface.get_editor_viewport_3d(0)
	if evp:
		var w := evp.find_world_3d()
		if _world != w:
			_world = w
			_sv.world_3d = w
	_label.text = "PreviewCam: %s" % _cam.name
	_mirror.global_transform = _cam.global_transform
	_mirror.fov = _cam.fov
	_mirror.current = true


func _find_camera(root: Node) -> Camera3D:
	if is_instance_valid(_cam) and _cam.is_inside_tree():
		return _cam
	var found := root.find_children("*", "Camera3D", true, false)
	return found[0] if found.size() > 0 else null
