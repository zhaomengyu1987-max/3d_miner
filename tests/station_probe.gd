extends Node3D

## 站体世界尺寸探针: 实例化 main.tscn, 计算 MiningHub 下所有网格的世界空间 AABB
## 用法: godot --headless --path . res://tests/station_probe.tscn

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node3D = (load("res://sences/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var hub := main.get_node_or_null("MiningHub")
	if hub == null:
		print("PROBE: MiningHub 不存在")
		get_tree().quit()
		return
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var stack: Array[Node] = [hub]
	var count := 0
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			count += 1
			var mi := n as MeshInstance3D
			var ab := mi.mesh.get_aabb()
			for k in 8:
				var corner := Vector3(
					ab.position.x + (ab.size.x if k & 1 else 0.0),
					ab.position.y + (ab.size.y if k & 2 else 0.0),
					ab.position.z + (ab.size.z if k & 4 else 0.0))
				var wp := mi.global_transform * corner
				mn = mn.min(wp)
				mx = mx.max(wp)
		for c in n.get_children():
			stack.append(c)
	var size := mx - mn
	print("PROBE: 网格数=%d" % count)
	print("PROBE: 站体世界尺寸 = %.2f x %.2f x %.2f m" % [size.x, size.y, size.z])
	print("PROBE: 半宽(水平最大) = %.2f m, 中心 = %s" % [
		maxf(size.x, size.z) * 0.5, str((mn + mx) * 0.5)])
	# 矿流参照: BeltFlow 位置
	var bf := main.get_node_or_null("BeltFlow")
	if bf:
		print("PROBE: BeltFlow 世界位置 = ", (bf as Node3D).global_position)
	get_tree().quit()
