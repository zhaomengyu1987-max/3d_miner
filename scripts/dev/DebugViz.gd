extends Node3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 空间诊断可视化（dev 工具，F9 开关）：
## 把所有停靠/避让判定的几何直接画出来——站体世界AABB线框、泊位环、
## 到港船包围盒+头向箭头、矿流边界。治"无法感知场景模型位置/边界"的根。
## 用法: 游戏内按 F9 切换; 截图后线框 vs 模型是否对齐一目了然。

var _enabled := false
var _top_cam: Camera3D
var _saved_cam: Camera3D
var _top_view := false
var _mesh: MeshInstance3D
var _im: ImmediateMesh
var _labels: Array[Label3D] = []
var _hub: Node3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_im = ImmediateMesh.new()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _im
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	_mesh.material_override = mat
	add_child(_mesh)
	_mesh.visible = false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		# 顶视图开关（验收用: 正上方俯视, 量环/盒/泊位圈的贴合）
		_top_view = not _top_view
		if _top_view:
			_saved_cam = get_viewport().get_camera_3d()
			if _top_cam == null:
				_top_cam = Camera3D.new()
				add_child(_top_cam)
				_top_cam.fov = 40.0
				_top_cam.near = 0.05 * U
				_top_cam.far = 4000.0 * U
			var t := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
			_top_cam.global_position = t + Vector3(0, 34, 0.001) * U
			_top_cam.look_at(t, Vector3.UP)
			_top_cam.make_current()
		elif _saved_cam != null:
			_saved_cam.make_current()
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		_enabled = not _enabled
		_mesh.visible = _enabled
		for l in _labels:
			l.visible = _enabled
		if _enabled:
			_rebuild_labels()


func _process(_delta: float) -> void:
	if not _enabled:
		return
	if _hub == null or not is_instance_valid(_hub):
		var scene := get_tree().current_scene
		if scene:
			_hub = scene.find_child("MiningHub", true, false)
	_draw_all()


func _draw_all() -> void:
	_im.clear_surfaces()
	if _hub == null or not is_instance_valid(_hub):
		return
	# 1) 站体世界 AABB（橙）
	var box := _world_aabb(_hub)
	_draw_box(box, Color(1, 0.6, 0.2))
	# 2) 泊位 locator 十字: 直接画在手摆 DockRing 圈上（半径/圆心/高度=StationRig.tscn 用户摆放值）
	#    青色圆线本身=rig 的 DockRing torus（F9 已联动显示, 与 tscn 所见一致）
	var sm := get_tree().root.find_child("StationModules", true, false)
	if sm != null:
		var ring_c := Vector3(
			_hub.global_position.x + sm._dock_center.x,
			sm._dock_plane_y,
			_hub.global_position.z + sm._dock_center.y)
		for s in 4:
			var a := deg_to_rad(72.0 * float(s) + 30.0)
			var p: Vector3 = ring_c + Vector3(cos(a), 0, sin(a)) * sm._station_half_r
			_draw_cross(p, Color(0.3, 0.9, 1))
	# 3) 到港船: 包围盒(绿) + 头向箭头(黄)
	var ships_root := get_tree().root.find_child("DockedShips", true, false)
	if ships_root != null:
		for c in ships_root.get_children():
			if c is Node3D:
				var sbox := _world_aabb(c)
				_draw_box(sbox, Color(0.3, 1, 0.4))
				var fwd: Vector3 = c.global_basis.x
				_line(c.global_position, c.global_position + fwd * (1.6 * U), Color(1, 0.9, 0.2))
	_update_labels(box, 0.0)


func _im_line(p: Vector3) -> Vector3:
	return to_local(p)


func _line(a: Vector3, b: Vector3, col: Color) -> void:
	_im.surface_begin(Mesh.PRIMITIVE_LINES, null)
	_im.surface_set_color(col)
	_im.surface_add_vertex(to_local(a))
	_im.surface_set_color(col)
	_im.surface_add_vertex(to_local(b))
	_im.surface_end()


func _draw_box(box: AABB, col: Color) -> void:
	var c := box.position
	var e := box.end
	var pts := [
		[Vector3(c.x, c.y, c.z), Vector3(e.x, c.y, c.z)], [Vector3(c.x, e.y, c.z), Vector3(e.x, e.y, c.z)],
		[Vector3(c.x, c.y, e.z), Vector3(e.x, c.y, e.z)], [Vector3(c.x, e.y, e.z), Vector3(e.x, e.y, e.z)],
		[Vector3(c.x, c.y, c.z), Vector3(c.x, e.y, c.z)], [Vector3(e.x, c.y, c.z), Vector3(e.x, e.y, c.z)],
		[Vector3(c.x, c.y, e.z), Vector3(c.x, e.y, e.z)], [Vector3(e.x, c.y, e.z), Vector3(e.x, e.y, e.z)],
		[Vector3(c.x, c.y, c.z), Vector3(c.x, c.y, e.z)], [Vector3(e.x, c.y, c.z), Vector3(e.x, c.y, e.z)],
		[Vector3(c.x, e.y, c.z), Vector3(c.x, e.y, e.z)], [Vector3(e.x, e.y, c.z), Vector3(e.x, e.y, e.z)],
	]
	for seg in pts:
		_line(seg[0], seg[1], col)


func _draw_cross(p: Vector3, col: Color) -> void:
	_line(p - Vector3(0.5, 0, 0) * U, p + Vector3(0.5, 0, 0) * U, col)
	_line(p - Vector3(0, 0, 0.5) * U, p + Vector3(0, 0, 0.5) * U, col)


## 世界 AABB（沿缩放链, 与 StationModules._measure_station 同算法）
func _world_aabb(root: Node3D) -> AABB:
	var best := AABB()
	var stack: Array[Node] = [root]
	var first := true
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var aabb: AABB = mi.mesh.get_aabb()
			# 粗确: 用节点全局变换映射 8 角
			for co in [Vector3(0,0,0), Vector3(1,0,0), Vector3(0,1,0), Vector3(1,1,0),
					Vector3(0,0,1), Vector3(1,0,1), Vector3(0,1,1), Vector3(1,1,1)]:
				var wp: Vector3 = mi.global_transform * (aabb.position + aabb.size * co)
				if first:
					best = AABB(wp, Vector3.ZERO)
					first = false
				else:
					best = best.expand(wp)
		for ch in n.get_children():
			stack.append(ch)
	if first:
		best = AABB(root.global_position, Vector3(0.4, 0.4, 0.4) * U)
	return best


func _rebuild_labels() -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	var l1 := _mk_label("站体 AABB（橙）· 泊位环+泊位点（青）· 船盒+头向（绿/黄）")
	l1.position = Vector3(0, 6, 0) * U
	var l2 := _mk_label("")
	l2.position = Vector3(0, 5.4, 0) * U
	_labels = [l1, l2]


func _mk_label(t: String) -> Label3D:
	var l := Label3D.new()
	l.text = t
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.pixel_size = 0.004 * U
	l.font_size = 40
	l.outline_size = 8
	l.modulate = Color(0.6, 1, 0.8)
	l.outline_modulate = Color(0, 0, 0, 0.9)
	add_child(l)
	l.visible = _enabled
	return l


func _update_labels(box: AABB, _half_w: float) -> void:
	if _labels.size() >= 2:
		var sm2 := get_tree().root.find_child("StationModules", true, false)
		var rr: float = sm2._station_half_r if sm2 != null else 0.0
		_labels[1].text = "DockRing(手摆): R=%.2f 圆心偏(%.2f,%.2f) y=%.2f" % [
			rr, sm2._dock_center.x if sm2 != null else 0.0,
			sm2._dock_center.y if sm2 != null else 0.0,
			sm2._dock_plane_y if sm2 != null else 0.0]
		_labels[1].global_position = _hub.global_position + Vector3(0, 5.4, 0) * U
		_labels[0].global_position = _hub.global_position + Vector3(0, 6.0, 0) * U
