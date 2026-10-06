class_name StationModules
extends Node3D

## 站体世界绑定（Economy autoload 创建）：
## - 空间站本体可点击 → 通知 UI 弹出模块悬浮窗（模块占位模型已移除, 2026-09-30 拍板）
## - 来访货舰 3D（industrial1.glb）：泊位沿机库向外排布, 到港飞入/离站飞出
## - 采矿无人机编队（drone.glb）与激光采矿护卫舰编队（mining_corvette.glb）

## 来访货舰 3D（经 sences/FreighterShip.tscn 包装）
const ShipScene := preload("res://sences/FreighterShip.tscn")
var _station_half_r := 4.7      # 站体实测水平半宽（_measure_station）
var _dock_plane_y := 0.0        # 停靠平面高度
var _dock_center := Vector2.ZERO  # 泊位圆心相对站心偏移（手摆 DockRing 的位置）
const BERTH_GAP := 0.0          # 船头距站壳缓冲（用户拍板 2026-10-01: 直接吻壳停靠）
const BERTH_SLOT_ANGLE := 72.0 # 泊位间隔角(最多4泊位, 环上弦距≈11m > 巨舰船长)
const SHIP_NOSE_FIX := PI      # 模型头向校正(look_at 后 -Z 对站; 若船头反了改 0.0)
const SHIP_APPROACH_SPD := 6.0  # 进港速度 m/s（缩小世界快节奏）
const SHIP_DEPART_SPD := 6.0    # 离港速度 m/s
const SHIP_DEPART_BACK := 6.0   # 离港先径向后退距离(再转身走)
const SHIP_LEN := {"small": 0.875, "standard": 1.0, "heavy": 1.125, "giant": 1.25}  # 各型号目标长度(米) [2026-10-05 再拍板: 全舰÷4]
const HULL_COLOR := Color(0.58, 0.64, 0.74)  # 无材质低模的中性船壳色
## 站体点击判定半径(米): 覆盖 athanor 站体, 与避让半径同量级
const STATION_CLICK_RADIUS := 6.0
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
var _corvettes: Array = []       # MiningCorvetteUnit 列表，与 module_count("corvette") 同步
var _corvette_claims: Array = [] # 护卫舰认领的 M 档矿
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
		_info_label.pixel_size = 0.004
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
	_info_label.position = _hub.global_position + Vector3(0, 3.6, 0)


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
		var key := int(floor((wv.y - _hub.global_position.y) / 0.25))
		var r2 := sqrt(wv.x * wv.x + wv.z * wv.z)
		if not buckets.has(key) or float(buckets[key]) < r2:
			buckets[key] = r2
	var best_key := 0
	var best_r := -1.0
	for k in buckets:
		if float(buckets[k]) > best_r:
			best_r = float(buckets[k])
			best_key = int(k)
	return _hub.global_position.y + (float(best_key) + 0.5) * 0.25


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
					if absf(wv.y - plane_y) <= 0.45:
						best = maxf(best, sqrt(wv.x * wv.x + wv.z * wv.z))
		for c in n.get_children():
			stack.append(c)
	return best if best > 0.5 else 3.0


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
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * 500.0)
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

## 泊位绕站一圈（角度=slot×72°+30°）, 半径=站半径+该船半长+缓冲——按实测尺寸紧贴停靠
func _berth_slot_pos(slot: int, ship_len: float) -> Vector3:
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
	if to_station.length_squared() < 0.1:
		return
	var cur := Quaternion(node.global_basis)
	var want := Quaternion(Basis.looking_at(to_station.normalized(), Vector3.UP))
	node.global_basis = Basis(cur.slerp(want, clampf(w, 0.0, 1.0)))


## 平滑转向任意方向
func _face_dir_smooth(node: Node3D, dir: Vector3, w: float) -> void:
	var d := dir.normalized()
	d.y = 0.0
	if d.length_squared() < 0.1:
		return
	var cur := Quaternion(node.global_basis)
	var want := Quaternion(Basis.looking_at(d, Vector3.UP))
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
	var taken: Array = _ships.values().map(func(n): return n.get_meta("slot", 0))
	var slot := 0
	for i in range(Economy._berths_total()):
		if i not in taken:
			slot = i
			break
	var node: Node3D = ShipScene.instantiate()
	_ship_root.add_child(node)
	var ship_len: float = SHIP_LEN.get(f.def_id, SHIP_LEN["standard"])
	var berth := _berth_slot_pos(slot, ship_len)
	# 任意角度进场: 来向随机方位, 距站 14~18m, 高度随机落差（不穿模——路径在环外）
	var a := randf() * TAU
	# 水平环距离与高度差分离（曾把高度差乘进距离系数→出生 25m 高空俯冲=停靠过远根因）
	node.position = berth + Vector3(cos(a), 0.0, sin(a)) * randf_range(9.0, 12.0) 		+ Vector3(0.0, randf_range(0.8, 2.0), 0.0)
	node.set_meta("slot", slot)
	node.set_meta("state", "arriving")
	node.set_meta("berth", berth)
	# 归一化: 型号目标长度 ÷ 模型最大边; 模型头向校正(假定长轴=+Y→转到 -Z 前)
	var ship: Node3D = node.get_child(0) as Node3D if node.get_child_count() > 0 else null
	if ship != null:
		var max_dim := _mesh_max_dim_of(ship)
		if max_dim > 0.001:
			ship.scale = Vector3.ONE * (ship_len / max_dim)
		ship.rotation.y = PI  # 实测(2026-10-01 探针): 模型长轴=Z 头在+Z; look_at 前向=-Z → 转 180° 船头对站
		_apply_hull_material(ship)
	var label := Label3D.new()
	label.text = f.name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.004
	label.font_size = 52
	label.outline_size = 8
	label.modulate = EconTheme.RARE if f.is_smuggler else Color(0.85, 0.92, 1.0)
	label.outline_modulate = Color(0.02, 0.04, 0.08, 0.9)
	label.position.y = 1.1  # 贴船（原 1.8 悬空过远）
	node.add_child(label)
	_face_station_smooth(node, 1.0)
	_ships[f] = node


func _depart_ship(f: Freighter) -> void:
	var node: Node3D = _ships[f]
	_ships.erase(f)
	node.set_meta("state", "backing")  # 阶段1: 保持船头对站, 径向倒退
	var away := (node.global_position - _hub_pos())
	away.y = 0.0
	away = away.normalized() if away.length_squared() > 0.01 else Vector3(1, 0, 0)
	node.set_meta("away", away)
	node.set_meta("depart_from", node.global_position)


## 每帧推进靠港/离港状态机（替代 tween——转向/速度分段控制）
func _process(delta: float) -> void:
	_process_ships(delta)  # 靠港/离港状态机驱动（曾漏挂: 船生成后静止在远处=不显示的根因）


func _process_ships(delta: float) -> void:
	if _ship_root == null:
		return
	for f in Economy.berths.duplicate():
		var n: Node3D = _ships.get(f)
		if n == null or not is_instance_valid(n):
			continue
		var st := str(n.get_meta("state", ""))
		var berth: Vector3 = n.get_meta("berth", n.global_position)
		match st:
			"arriving":
				var d := berth - n.global_position
				if d.length() <= 0.15:
					n.set_meta("state", "docked")
					var hb := _hub.global_position if _hub != null else Vector3.ZERO
					print("SHIP DOCKED: 距站心 %.2fm (泊位理论 %.2fm)" % [
						n.global_position.distance_to(hb), berth.distance_to(hb)])
				else:
					n.global_position += d.normalized() * SHIP_APPROACH_SPD * delta
					_face_station_smooth(n, 3.0 * delta)
			"docked":
				n.global_position = berth + Vector3(0, sin(Time.get_ticks_msec() * 0.002 + float(n.get_meta("slot", 0))) * 0.06, 0)
				_face_station_smooth(n, 2.0 * delta)
	# 离港中的船（已不在 berths）
	for node in _ship_root.get_children():
		var st := str(node.get_meta("state", ""))
		if st == "backing":
			var away: Vector3 = node.get_meta("away", Vector3(1, 0, 0))
			var from: Vector3 = node.get_meta("depart_from", node.global_position)
			_face_station_smooth(node, 3.0 * delta)  # 船头保持对站倒退
			node.global_position += away * SHIP_DEPART_SPD * 0.8 * delta
			if node.global_position.distance_to(from) >= SHIP_DEPART_BACK:
				node.set_meta("state", "turning")
		elif st == "turning":
			var away2: Vector3 = node.get_meta("away", Vector3(1, 0, 0))
			_face_dir_smooth(node, away2, 3.0 * delta)  # 转身朝离开方向
			var q := Quaternion(Basis.looking_at(away2, Vector3.UP))
			if absf(Quaternion(node.global_basis).dot(q)) > 0.985:
				node.set_meta("state", "leaving")
		elif st == "leaving":
			var away3: Vector3 = node.get_meta("away", Vector3(1, 0, 0))
			node.global_position += away3 * SHIP_DEPART_SPD * delta
			if node.global_position.distance_to(_hub_pos()) > 40.0:
				node.queue_free()


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
		_drone_root.add_child(unit)
		unit.park_pos = _drone_park_pos(i)  # 先入树再定位(_ready 里要用)
		_drones.append(unit)
	# 清理失效认领(矿被回收/捕获/释放)
	for o in _drone_claims.duplicate():
		if not (is_instance_valid(o) and o.visible and not o.captured):
			_drone_claims.erase(o)


## 停泊位：绕站体一圈的悬停点（最多 6 架）
func _drone_park_pos(i: int) -> Vector3:
	var base := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
	var angle := deg_to_rad(i * 60.0 + 30.0)
	return base + Vector3(cos(angle) * 4.2, 0.8, sin(angle) * 4.2)


# ---------- 激光采矿护卫舰编队 ----------

func _sync_corvettes() -> void:
	if _corvette_root == null:
		return
	_ensure_world_refs()
	var want := Economy.module_count("corvette")
	while _corvettes.size() > want:
		var c = _corvettes.pop_back()
		c.queue_free()
	while _corvettes.size() < want:
		var i := _corvettes.size()
		var unit := MiningCorvetteUnit.new()
		unit.belt = _belt
		unit.station = _hub
		unit.claims = _corvette_claims
		_corvette_root.add_child(unit)
		unit.park_pos = _corvette_park_pos(i)
		_corvettes.append(unit)
	for o in _corvette_claims.duplicate():
		if not (is_instance_valid(o) and o.visible and not o.captured):
			_corvette_claims.erase(o)


## 护卫舰停泊位：另一圈（最多 3 艘），与无人机圈错开
func _corvette_park_pos(i: int) -> Vector3:
	var base := _hub.global_position if _hub != null and is_instance_valid(_hub) else Vector3.ZERO
	var angle := deg_to_rad(i * 120.0 + 90.0)
	return base + Vector3(cos(angle) * 5.6, 0.5, sin(angle) * 5.6)
