extends Node3D

## 空间站实际尺寸测量探针（headless）：
## 实例化 MiningHub.tscn → 沿父链乘缩放 → 世界 AABB → 半径/包围盒

func _ready() -> void:
	var hub := (load("res://sences/MiningHub.tscn") as PackedScene).instantiate()
	hub.scale = Vector3(0.2, 0.2, 0.2)  # main.tscn 中 MiningHub 的缩放
	add_child(hub)
	await get_tree().process_frame
	var best := 0.0
	var box := AABB()
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
			if sz.length() > best:
				best = sz.length()
				box = AABB(mi.global_position - sz * 0.5, sz)
		for c in n.get_children():
			stack.append(c)
	print("STATION world size = ", box.size, " (X×Y×Z m)")
	print("STATION half-extent max = ", maxf(box.size.x, maxf(box.size.y, box.size.z)) / 2.0, " m")
	print("STATION diagonal radius = ", best / 2.0, " m")
	print("=> 建议泊位环半径 = 对角半径 + 船身余量2m ≈ ", best / 2.0 + 2.0, " m")
	get_tree().quit(0)
