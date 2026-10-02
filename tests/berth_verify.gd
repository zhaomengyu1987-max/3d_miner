extends Node3D

## 泊位距离几何验证探针：加载真实 main.tscn（含 MiningHub 真实缩放链 0.2×0.1），
## 按泊位公式摆船, 实测船头到站壳 AABB 表面的距离（不靠眼睛）。

func _ready() -> void:
	var main: Node3D = (load("res://sences/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().process_frame
	var hub: Node3D = main.find_child("MiningHub", true, false)
	print("hub pos=", hub.global_position, " scale=", hub.scale)

	# 站体世界 AABB（沿缩放链）
	var aabb := AABB(Vector3.ONE * 99999.0, Vector3.ZERO)
	var stack: Array[Node] = [hub]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var ws := Vector3.ONE
			var walker: Node = mi
			while walker != null and walker != hub:
				if walker is Node3D:
					ws *= (walker as Node3D).scale
				walker = walker.get_parent()
			ws *= hub.scale
			var sz := mi.mesh.get_aabb().size * ws
			var ctr := hub.global_position + mi.mesh.get_aabb().position * ws + sz * 0.5
			if sz.length() > aabb.size.length():
				aabb = AABB(ctr - sz * 0.5, sz)
		for c in n.get_children():
			stack.append(c)
	print("站体世界AABB=", aabb)
	var half_w := maxf(aabb.size.x, aabb.size.z) * 0.5
	print("水平半宽=", half_w)

	# 按泊位公式（standard 船 3.0m 长半=1.5; gap=0）摆船
	var ship_len := 3.0
	var a := deg_to_rad(72.0 * 0.0 + 30.0)
	var berth := hub.global_position + Vector3(cos(a), 0.0, sin(a)) * (half_w + ship_len * 0.5)
	print("泊位点=", berth, " 距站心=", berth.distance_to(hub.global_position))
	# 船头=朝站心方向 half ship_len
	var nose := berth - Vector3(cos(a), 0, sin(a)) * ship_len * 0.5
	# AABB 表面最近距离
	var clamped := aabb.grow(0.0).expand(nose).get_support(-Vector3.ONE).abs()  # 占位
	var surface_pt := Vector3(
		clampf(nose.x, aabb.position.x, aabb.end.x),
		clampf(nose.y, aabb.position.y, aabb.end.y),
		clampf(nose.z, aabb.position.z, aabb.end.z))
	print("船头点=", nose)
	print("船头到站壳表面距离=", nose.distance_to(surface_pt), " m")
	# 两种算法对照（F9 8角映射 AABB vs 顶点实测）
	var corner_box := AABB(Vector3.ONE * 99999.0, Vector3.ZERO)
	var first2 := true
	var st2: Array[Node] = [hub]
	var max_r := 0.0
	var radius_samples: Array = []
	while not st2.is_empty():
		var n: Node = st2.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi2 := n as MeshInstance3D
			var ab: AABB = mi2.mesh.get_aabb()
			for co in [Vector3(0,0,0), Vector3(1,0,0), Vector3(0,1,0), Vector3(1,1,0),
					Vector3(0,0,1), Vector3(1,0,1), Vector3(0,1,1), Vector3(1,1,1)]:
				var wp2: Vector3 = mi2.global_transform * (ab.position + ab.size * co)
				if first2:
					corner_box = AABB(wp2, Vector3.ZERO)
					first2 = false
				else:
					corner_box = corner_box.expand(wp2)
			for su in mi2.mesh.get_surface_count():
				var ar: Array = mi2.mesh.surface_get_arrays(su)
				if ar.is_empty() or ar[Mesh.ARRAY_VERTEX] == null:
					continue
				var vs: PackedVector3Array = ar[Mesh.ARRAY_VERTEX]
				var step := maxi(1, vs.size() / 3000)
				for i2 in range(0, vs.size(), step):
					var wv2: Vector3 = mi2.global_transform * vs[i2]
					var rr := sqrt(wv2.x * wv2.x + wv2.z * wv2.z)
					max_r = maxf(max_r, rr)
					radius_samples.append(rr)
		for ch in n.get_children():
			st2.append(ch)
	print("F9角映射AABB=", corner_box.size, " 半宽=", maxf(corner_box.size.x, corner_box.size.z) * 0.5)
	print("全模型顶点最大水平半径=", max_r)
	# 半径分布直方图: 6.0~6.6 的顶点有多少(判断大半径是主体环还是零星天线)
	for lo in range(0, 7):
		var cnt := 0
		for r_i in range(radius_samples.size()):
			if float(radius_samples[r_i]) >= float(lo) and float(radius_samples[r_i]) < float(lo) + 1.0:
				cnt += 1
		print("  半径 %d~%dm 顶点数 %d" % [lo, lo + 1, cnt])
	# 运行时验证: 强制货舰到港, 等状态机跑完靠泊, 打印实际停靠距离
	get_tree().quit(0)
