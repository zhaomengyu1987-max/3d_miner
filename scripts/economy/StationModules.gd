class_name StationModules
extends Node3D

# Legacy distances converted to metres; timing and angles are unchanged.
const U := preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS

## 站体世界绑定（Economy autoload 创建）：
## - 空间站本体可点击 → 通知 UI 弹出模块悬浮窗（模块占位模型已移除, 2026-09-30 拍板）
## - 小型货舰沿用工业船；标准/重型/巨型访客使用护卫舰/战列舰/旗舰。
## - 采矿无人机编队（drone.glb）与激光采矿护卫舰编队（mining_corvette.glb）

## 来访货舰 3D（经 sences/FreighterShip.tscn 包装）
const Motion := preload("res://scripts/ships/ShipMotion.gd")
const VISITOR_SCENES := {
	"standard": preload("res://sences/ships/FrigateVisitor.tscn"),
	"heavy": preload("res://sences/ships/BattleshipVisitor.tscn"),
	"giant": preload("res://sences/ships/FlagshipVisitor.tscn"),
}
var _traffic_retry := 0.0
const ShipScene := preload("res://sences/FreighterShip.tscn")
var _station_half_r := 4.7 * U # 站体实测水平半宽（_measure_station）
var _dock_plane_y := 0.0        # 停靠平面高度
var _dock_center := Vector2.ZERO  # 泊位圆心相对站心偏移（手摆 DockRing 的位置）
const BERTH_GAP := 0.0          # 船头距站壳缓冲（用户拍板 2026-10-01: 直接吻壳停靠）
const BERTH_SLOT_ANGLE := 72.0 # 最多4条独立径向进出港航道。
const SHIP_DEPART_BACK := 6.0 * U # 离港先径向后退距离(再转身走)
const SHIP_LEN := {"small": 0.875 * U, "standard": 1.0 * U, "heavy": 1.125 * U, "giant": 1.25 * U}  # 各型号目标长度(米) [2026-10-05 再拍板: 全舰÷4]
const HULL_COLOR := Color(0.58, 0.64, 0.74)  # 无材质低模的中性船壳色
## 站体点击判定半径(米): 覆盖 athanor 站体, 与避让半径同量级
const STATION_CLICK_RADIUS := 3.5 * U
## 空点兜底: 鼠标点击位置与站心屏幕投影距离小于该值也算点站(像素)
# R8: STATION_CLICK_PIXELS 已删除(空点兜底导致点太空触发菜单)

var _hub: Node3D
var _belt: BeltFlow  # 无人机/护卫舰取目标用
var _station_body: StaticBody3D
var _ship_root: Node3D
var _ships := {}     # Freighter -> Node3D（停靠中的船，含泊位 slot meta）
var _drone_root: Node3D
var _drones: Array = []          # MiningDroneUnit 列表，与 module_count("drone") 同步
var _drone_claims: Array = []    # 全体无人机共享的认领目标（防止两架抢同一颗矿）
var _corvette_root: Node3D
var _corvettes: Array = []       # 五种激光矿船列表，按各模块数量同步
var _corvette_claims: Array = [] # 五种矿船共享的非 S 矿体认领
var _info_label: Label3D         # 空间站头顶信息字牌（钱/燃料/日期/泊位）


func _ready() -> void:
	var scene := get_tree().current_scene
	if scene:
		_hub = scene.find_child("MiningHub", true, false)
		_belt = scene.find_child("BeltFlow", true, false) as BeltFlow
	if _hub == null:
		push_warning("StationModules: 找不到 MiningHub，站体点击不可用")
	else:
		_build_station_click_body()
	_ship_root = Node3D.new()
	_ship_root.name = "DockedShips"
	add_child(_ship_root)
	_drone_root = Node3D.new()
	_drone_root.name = "MiningDrones"
	add_child(_drone_root)
	_corvette_root = Node3D.new()
	_corvette_root.name = "MiningCorvettes"
	add_child(_corvette_root)
	# rig 几何: 编辑器里常显(供手摆), 运行时隐藏——F9 唤回（与 DebugViz 联动）
	for rig_name in ["DockBox", "RingEdge", "DockRing"]:
		var rn := find_node_rig(rig_name)
		if rn is VisualInstance3D:
			(rn as VisualInstance3D).visible = false
	_measure_station()
	Economy.modules_changed.connect(_on_modules_changed)
	Economy.freighters_changed.connect(_reconcile_ships)
	Economy.money_changed.connect(_update_info_label)
	Economy.fuel_changed.connect(_update_info_label)
	Economy.day_changed.connect(func(_d): _update_info_label())
	_on_modules_changed()
	_reconcile_ships()
	_update_info_label()


## 空间站上方信息字牌：钱 · 燃料 · 第 N 日 · 泊位（HUD 屏幕按键已全部移除, 2026-09-30 拍板）
func _update_info_label() -> void:
	if _hub == null or not is_instance_valid(_hub):
		return
	if _info_label == null:
		_info_label = Label3D.new()
		_info_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_info_label.no_depth_test = true
		_info_label.pixel_size = 0.004 * U
		_info_label.font_size = 44
		_info_label.outline_size = 10
		_info_label.modulate = Color(0.92, 0.96, 1.0)
		_info_label.outline_modulate = Color(0.02, 0.04, 0.08, 0.92)
		add_child(_info_label)
	var total := Economy._berths_total()
	var line2 := "第 %d 日" % Economy.day
	if total > 0:
		line2 += " · 泊位 %d/%d" % [Economy.berths.size(), total]
	_info_label.text = "₡%s · 燃料 %d\n%s" % [
		EconTheme.money(Economy.money), int(Economy.fuel), line2]
	_info_label.position = _hub.global_position + Vector3(0, 3.6, 0) * U


## 实测站体世界对角半径 → 泊位环 = 半径 + 2m 船身余量（探针验证: 站体 6.0×4.0×6.0m）
func find_node_rig(n: String) -> Node:
	if _hub == null or not is_instance_valid(_hub):
		return null
	return _hub.find_child(n, false, false)


func _measure_station() -> void:
	_ensure_world_refs()
	if _hub == null or not is_instance_valid(_hub):
		return
	var best_box := AABB(Vector3.ONE * 99999, Vector3.ZERO)
	var stack: Array[Node] = [_hub]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var ws := Vector3.ONE
			var walker: Node = mi
			while walker != null and walker != _hub:
				if walker is Node3D:
					ws *= (walker as Node3D).scale
				walker = walker.get_parent()
			var sz := mi.mesh.get_aabb().size * ws * _hub.scale
			if sz.length() > best_box.size.length():
				best_box.size = sz
		for c in n.get_children():
			stack.append(c)
	# 2026-10-01 用户方案: 几何由 StationRig.tscn 手工摆放（编辑器拖 30 秒校准）。
	# DockRing(TorusMesh)=泊位圈半径优先; 摆了就用, 没摆回退顶点实测。
	var dock_ring := _hub.find_child("DockRing", false, false) as MeshInstance3D
	if dock_ring != null and dock_ring.mesh is TorusMesh:
		# 尊重编辑器手摆的一切: mesh 半径 × 节点全局缩放(XZ) + 节点位置(圆心/高度)
		var tm := dock_ring.mesh as TorusMesh
		var gs: Vector3 = dock_ring.global_transform.basis.get_scale()
		var sxz := (absf(gs.x) + absf(gs.z)) * 0.5
		_station_half_r = (tm.inner_radius + tm.outer_radius) * 0.5 * sxz
		_dock_plane_y = dock_ring.global_position.y
		_dock_center = Vector2(
			dock_ring.global_position.x - _hub.global_position.x,
			dock_ring.global_position.z - _hub.global_position.z)
		print("StationModules: 手摆 DockRing 半径 %.2fm 圆心偏移(%.2f,%.2f) 平面y %.2f" % [
			_station_half_r, _dock_center.x, _dock_center.y, _dock_plane_y])
	else:
		_dock_plane_y = _widest_section_y(_hub)
		_station_half_r = _ring_radius_at(_dock_plane_y)
		print("StationModules: 未摆 DockRing, 顶点实测泊位半径 %.2fm" % _station_half_r)


## 角映射世界 AABB（mesh 局部 AABB 8 角 × global_transform → expand; 与 F9 显示同一真值）
func _corner_mapped_aabb(root: Node3D) -> AABB:
	var box := AABB(Vector3.ONE * 99999.0, Vector3.ZERO)
	var first := true
	var st: Array[Node] = [root]
	while not st.is_empty():
		var n: Node = st.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var ab: AABB = mi.mesh.get_aabb()
			for co in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0),
					Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)]:
				var wp: Vector3 = mi.global_transform * (ab.position + ab.size * co)
				if first:
					box = AABB(wp, Vector3.ZERO)
					first = false
				else:
					box = box.expand(wp)
		for c in n.get_children():
			st.append(c)
	return box


## 扫模型顶点按 y 分桶, 取水平半径最大的桶的中点 y——Athanor 大环层（视觉主体, 非包围盒中心）
func _widest_section_y(root: Node3D) -> float:
	var fallback := root.global_position.y
	var best_node: MeshInstance3D = null
	var best_len := 0.0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var l: float = mi.mesh.get_aabb().size.length()
			if l > best_len:
				best_len = l
				best_node = mi
		for c in n.get_children():
			stack.append(c)
	if best_node == null:
		return fallback
	var verts: PackedVector3Array = best_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return fallback
	var buckets := {}  # y桶(0.25m) -> 最大水平半径
	for v in verts:
		var wv: Vector3 = best_node.global_transform * v
		var key := int(floor((wv.y - _hub.global_position.y) / (0.25 * U)))
		var r2 := sqrt(wv.x * wv.x + wv.z * wv.z)
		if not buckets.has(key) or float(buckets[key]) < r2:
			buckets[key] = r2
	var best_key := 0
	var best_r := -1.0
	for k in buckets:
		if float(buckets[k]) > best_r:
			best_r = float(buckets[k])
			best_key = int(k)
	return _hub.global_position.y + (float(best_key) + 0.5) * (0.25 * U)


## 实测停靠平面(±0.45m 层)上模型的最大水平半径=环外缘（细天线撑大 AABB 的修复）
func _ring_radius_at(plane_y: float) -> float:
	var best := 0.0
	var stack: Array[Node] = [_hub]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			for surf in mi.mesh.get_surface_count():
				var arrays: Array = mi.mesh.surface_get_arrays(surf)
				if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
					continue
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var step := maxi(1, verts.size() / 4000)  # 采样上限防卡
				for i in range(0, verts.size(), step):
					var wv: Vector3 = mi.global_transform * verts[i]
					if absf(wv.y - plane_y) <= 0.45 * U:
						best = maxf(best, sqrt(wv.x * wv.x + wv.z * wv.z))
		for c in n.get_children():
			stack.append(c)
	return best if best > 0.5 * U else 3.0 * U


## 站体点击判定体：只作为射线命中目标（开启拾取反而会被矿石抢走最近命中, 故关闭）
func _build_station_click_body() -> void:
	_station_body = StaticBody3D.new()
	_station_body.name = "StationClickBody"
	_station_body.input_ray_pickable = false
	_station_body.collision_layer = 2
	_station_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = STATION_CLICK_RADIUS
	shape.shape = sphere
	_station_body.add_child(shape)
	_hub.add_child(_station_body)


## 点击空间站判定（_unhandled_input, 自管射线 + 屏幕距离兜底）：
## - 命中站体判定球 → 开菜单
## - 点在矿石上 = 捕获意图, 不开
## - 空点但屏幕距离贴近站心投影 → 开菜单（提高容错）
func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_open_station_menu()


func _try_open_station_menu() -> void:
	if _hub == null or not is_instance_valid(_hub) or _station_body == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * (500.0 * U))
	params.hit_from_inside = true
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit and (hit["collider"] is BeltOre):
		return  # 点在矿石上: 玩家在捕获, 不弹菜单
	# R8 修复: 严格只允许射线命中站体碰撞球才弹菜单
	# 删除"空点兜底"(原 90px 屏幕距离导致点太空也触发)
	if hit and hit["collider"] == _station_body:
		_open_station_menu(mouse)


func _open_station_menu(mouse: Vector2) -> void:
	var ui := get_tree().get_first_node_in_group("econ_ui")
	if ui != null:
		ui.show_station_popup(mouse)


# ---------- 世界引用 ----------

## 世界引用懒查找：主场景里 hub/belt 开局就有, 但测试场景是后加的, 每次同步前补找
func _ensure_world_refs() -> void:
	var scene := get_tree().current_scene
	if _hub == null and scene != null:
		_hub = scene.find_child("MiningHub", true, false)
		if _hub != null:
			_build_station_click_body()
	if _belt == null and scene != null:
		_belt = scene.find_child("BeltFlow", true, false) as BeltFlow


func _on_modules_changed() -> void:
	_sync_drones()
	_sync_corvettes()


# ---------- 来访货舰 3D ----------

## DockRing 上的船头对接点；船体原点按实际舰首位置向外偏移。
func _berth_slot_pos(slot: int, _ship_len: float) -> Vector3:
	var base := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
	var a := deg_to_rad(BERTH_SLOT_ANGLE * float(slot) + 30.0)
	var r := _station_half_r  # 手摆 DockRing 即泊位圈(圆心/半径/高度全部以用户摆放为准)
	return Vector3(base.x + _dock_center.x, _dock_plane_y, base.z + _dock_center.y) + Vector3(cos(a), 0.0, sin(a)) * r


## 站心坐标（测试场景没有 MiningHub → 退回原点, 与 _berth_slot_pos 同口径）。
## 注意: 直接用 _hub.global_position 会在无 MiningHub 的场景里空指针崩溃（headless 测试曾整体挂掉）。
func _hub_pos() -> Vector3:
	return _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO


## 平滑转身: 每帧向"面向站心"插值 w(0~1)
func _face_station_smooth(node: Node3D, w: float) -> void:
	var base := _hub_pos()
	var to_station := base - node.global_position
	to_station.y = 0.0
	if to_station.length_squared() < 0.1 * U * U:
		return
	var cur := Quaternion(node.global_basis)
	var want := Quaternion(Motion.forward_basis(to_station))
	node.global_basis = Basis(cur.slerp(want, clampf(w, 0.0, 1.0)))


## 平滑转向任意方向
func _face_dir_smooth(node: Node3D, dir: Vector3, w: float) -> void:
	var d := dir.normalized()
	d.y = 0.0
	if d.length_squared() < 0.1:
		return
	var cur := Quaternion(node.global_basis)
	var want := Quaternion(Motion.forward_basis(d))
	node.global_basis = Basis(cur.slerp(want, clampf(w, 0.0, 1.0)))


func _reconcile_ships() -> void:
	if _ship_root == null:
		return
	_ensure_world_refs()
	if Economy.module_level("hangar") <= 0:
		return
	for f in Economy.berths:
		if not _ships.has(f):
			_spawn_ship(f)
	for f in _ships.keys().duplicate():
		if not Economy.berths.has(f):
			_depart_ship(f)


func _spawn_ship(f: Freighter) -> void:
	var taken: Array = _ship_root.get_children().map(func(n): return n.get_meta("slot", 0))
	var slot := -1
	for i in range(Economy._berths_total()):
		if i not in taken:
			slot = i
			break
	# Departing hulls reserve their lane until fully outside the harbour.
	if slot < 0:
		return
	var visitor := VISITOR_SCENES.has(f.def_id)
	var packed: PackedScene = VISITOR_SCENES.get(f.def_id, ShipScene)
	var node: Node3D = packed.instantiate()
	_ship_root.add_child(node)
	var ship_len: float = SHIP_LEN.get(f.def_id, SHIP_LEN["standard"])
	if visitor:
		ship_len = node.hull_length
	var dock_point := _berth_slot_pos(slot, ship_len)
	var radial := Vector3(cos(deg_to_rad(BERTH_SLOT_ANGLE * slot + 30.0)), 0, sin(deg_to_rad(BERTH_SLOT_ANGLE * slot + 30.0)))
	var motion = node.motion if visitor else Motion.new()
	if not visitor:
		motion.max_speed = 6.0 * U
		motion.acceleration = 3.0 * U
	node.set_meta("motion", motion)
	node.set_meta("ship_length", ship_len)
	# 归一化: 型号目标长度 ÷ 模型最大边; 模型头向校正(假定长轴=+Y→转到 -Z 前)
	var ship: Node3D = node.get_child(0) as Node3D if node.get_child_count() > 0 else null
	if ship != null and not visitor:
		var max_dim := _mesh_max_dim_of(ship)
		if max_dim > 0.001:
			ship.scale = Vector3.ONE * (ship_len / max_dim)
		ship.rotation.y = PI / 2.0 # Authored +Z bow becomes the shared +X bow.
		_apply_hull_material(ship)
	# Local +X is the bow after model normalization. Align that tip, not the root,
	# with DockRing. Exclude exhaust trails, labels and weapon effects from hull bounds.
	var hull: Node3D = node.get_node("VisualBasis/Hull") if visitor else ship
	var bounds := _hull_bounds_local(node, hull)
	var nose := Vector3(bounds.end.x, bounds.get_center().y, bounds.get_center().z)
	var facing := Motion.forward_basis(-radial)
	var berth := dock_point - facing * nose
	node.global_basis = facing
	node.global_position = berth + radial * maxf(12.0 * U, ship_len * 0.8)
	node.set_meta("slot", slot)
	node.set_meta("state", "arriving")
	node.set_meta("berth", berth)
	node.set_meta("dock_point", dock_point)
	node.set_meta("nose_local", nose)
	node.set_meta("away", radial)
	var label := Label3D.new()
	label.text = f.name + (" · " + node.hull_name if visitor else "")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.004 * U
	label.font_size = 52
	label.outline_size = 8
	label.modulate = EconTheme.RARE if f.is_smuggler else Color(0.85, 0.92, 1.0)
	label.outline_modulate = Color(0.02, 0.04, 0.08, 0.9)
	label.position.y = node.hull_height * 0.65 + 8.0 * U / 12.0 if visitor else 1.1 * U
	node.add_child(label)
	_ships[f] = node


func _depart_ship(f: Freighter) -> void:
	var node: Node3D = _ships[f]
	_ships.erase(f)
	node.set_meta("state", "backing")  # 阶段1: 保持船头对站, 径向倒退
	node.set_meta("depart_from", node.global_position)


## 每帧推进靠港/离港状态机（替代 tween——转向/速度分段控制）
func _process(delta: float) -> void:
	_process_ships(delta)
	_traffic_retry -= delta
	if _traffic_retry <= 0.0:
		_traffic_retry = 1.0
		_reconcile_ships()


func _process_ships(delta: float) -> void:
	if _ship_root == null:
		return
	for node: Node3D in _ship_root.get_children():
		var motion = node.get_meta("motion", null)
		if motion == null or node.is_queued_for_deletion():
			continue
		var berth: Vector3 = node.get_meta("berth", node.global_position)
		var length: float = node.get_meta("ship_length", 12.0)
		var away: Vector3 = node.get_meta("away", Vector3.RIGHT)
		match str(node.get_meta("state", "")):
			"arriving":
				if motion.travel(node, berth, delta):
					node.set_meta("state", "docked")
			"docked":
				motion.stop()
				node.global_position = berth
			"backing":
				var origin: Vector3 = node.get_meta("depart_from", node.global_position)
				if motion.travel(node, origin + away * maxf(SHIP_DEPART_BACK, length * 0.75), delta, true):
					node.set_meta("state", "turning")
			"turning":
				motion.stop()
				motion.face(node, away, delta)
				if node.global_basis.x.dot(away) > 0.999:
					node.set_meta("state", "leaving")
			"leaving":
				motion.travel(node, node.global_position + away * (10000.0 * U / 12.0), delta)
				if node.global_position.distance_to(berth) > maxf(40.0 * U, length * 2.0):
					node.queue_free()
		if node.has_method("update_exhaust"):
			node.update_exhaust()


func _hull_bounds_local(root: Node3D, hull: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	var stack: Array[Node] = [hull]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and current.mesh != null:
			var transform: Transform3D = root.global_transform.affine_inverse() * current.global_transform
			var box: AABB = transform * current.mesh.get_aabb()
			bounds = box if first else bounds.merge(box)
			first = false
		for child in current.get_children():
			stack.append(child)
	return bounds


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


## GLB 无材质时套中性船壳色（有材质则不动）
func _apply_hull_material(root: Node) -> void:
	var needs_mat := false
	var meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			meshes.append(mi)
			for i in mi.mesh.get_surface_count():
				if mi.mesh.surface_get_material(i) == null:
					needs_mat = true
		for c in n.get_children():
			stack.append(c)
	if not needs_mat:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = HULL_COLOR
	m.metallic = 0.55
	m.roughness = 0.45
	for mi in meshes:
		mi.material_override = m


# ---------- 采矿无人机编队 ----------

func _sync_drones() -> void:
	if _drone_root == null:
		return
	_ensure_world_refs()
	var want := Economy.module_count("drone")
	while _drones.size() > want:
		var d = _drones.pop_back()
		d.queue_free()
	while _drones.size() < want:
		var i := _drones.size()
		var unit := MiningDroneUnit.new()
		unit.belt = _belt
		unit.station = _hub
		unit.claims = _drone_claims
		unit.park_pos = _drone_park_pos(i)
		_drone_root.add_child(unit)
		_drones.append(unit)
	# 清理失效认领(矿被回收/捕获/释放)
	for o in _drone_claims.duplicate():
		if not (is_instance_valid(o) and o.visible and not o.captured):
			_drone_claims.erase(o)


## 停泊位：绕站体一圈的悬停点（最多 6 架）
func _drone_park_pos(i: int) -> Vector3:
	var base := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
	var angle := deg_to_rad(i * 60.0 + 30.0)
	return base + Vector3(cos(angle) * 4.2, 0.8, sin(angle) * 4.2) * U


# ---------- 激光采矿护卫舰编队 ----------

func _sync_corvettes() -> void:
	if _corvette_root == null:
		return
	_ensure_world_refs()
	for module_id in MiningCorvetteUnit.Stats.MODULE_TYPES:
		var type_id: String = MiningCorvetteUnit.Stats.MODULE_TYPES[module_id]
		var matching: Array = _corvettes.filter(func(c): return c.ship_type == type_id)
		var want := Economy.module_count(module_id)
		while matching.size() > want:
			var c = matching.pop_back()
			_corvettes.erase(c)
			c.queue_free()
		while matching.size() < want:
			var unit := MiningCorvetteUnit.new()
			unit.ship_type = type_id
			unit.belt = _belt
			unit.station = _hub
			unit.claims = _corvette_claims
			unit.park_pos = _corvette_park_pos(_corvettes.size())
			_corvette_root.add_child(unit)
			unit.global_position = unit.park_pos
			_corvettes.append(unit)
			matching.append(unit)
	for i in _corvettes.size():
		_corvettes[i].park_pos = _corvette_park_pos(i)

	for o in _corvette_claims.duplicate():
		if not (is_instance_valid(o) and o.visible and not o.captured):
			_corvette_claims.erase(o)


## 激光矿船待命位：每圈15艘，超出时另起外圈。
func _corvette_park_pos(i: int) -> Vector3:
	var base := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
	var angle := deg_to_rad((i % 15) * 24.0 + 90.0)
	var radius := maxf(5.6 * U, _station_half_r + MiningCorvetteUnit.CORVETTE_SIZE * 0.5 + 2.0 * U)
	radius += floori(float(i) / 15.0) * 2.0 * U
	return base + Vector3(cos(angle) * radius, 0.5 * U, sin(angle) * radius)
