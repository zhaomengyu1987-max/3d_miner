extends Node3D

## 运输舰头向/尺寸视觉测量探针（窗口模式运行, 配合 PrintWindow 截图判定头向）：
## 船居中, X+ 红箭头 / Z- 蓝箭头（Godot look_at 的"前方"=-Z）, 俯视相机。
## 同时打印精确 AABB。

func _ready() -> void:
	# 参考地面
	var floor_m := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(12, 12)
	floor_m.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.15, 0.17, 0.2)
	floor_m.material_override = fmat
	add_child(floor_m)

	var ship: Node3D = (load("res://sences/FreighterShip.tscn") as PackedScene).instantiate()
	add_child(ship)

	# 方向指示: +X 红 / -Z 蓝(Godot 前向) / +Y 绿
	axis_marker(Vector3(3, 0.1, 0), Color(1, 0.2, 0.2), 2.2)
	axis_marker(Vector3(0, 0.1, -3), Color(0.2, 0.5, 1), 2.2)
	axis_marker(Vector3(0, 2, 0), Color(0.2, 1, 0.4), 1.6)

	# 相机: 斜上方俯视
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 9, 6)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# 打印精确 AABB（含缩放链）
	var best := AABB()
	var stack: Array[Node] = [ship]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var aabb: AABB = (n as MeshInstance3D).mesh.get_aabb()
			if aabb.size.length() > best.size.length():
				best = aabb
		for c in n.get_children():
			stack.append(c)
	print("SHIP aabb size = ", best.size, " center=", best.position + best.size * 0.5)
	print("SHIP 长轴 = ", ["X", "Y", "Z"][[best.size.x, best.size.y, best.size.z].find(maxf(best.size.x, maxf(best.size.y, best.size.z)))])
	if DisplayServer.get_name() == "headless":
		get_tree().quit(0)  # headless 只打印测量值


func axis_marker(at: Vector3, col: Color, len: float) -> void:
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.04
	cm.bottom_radius = 0.12
	cm.height = len
	m.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	m.material_override = mat
	add_child(m)
	m.position = at
	# 圆柱默认沿 Y, 转到指向原点方向
	m.look_at(Vector3(at.x, 0, at.z), Vector3.UP)
	m.rotate_object_local(Vector3.RIGHT, PI / 2)
