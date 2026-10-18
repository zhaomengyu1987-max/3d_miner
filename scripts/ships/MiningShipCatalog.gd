extends RefCounted
## Visual placeholders from docs/数值表_3D实现版.md §4.
## Presentation only; gameplay profiles live in MiningShipStats.
## Higher tiers share the current 86.4m hull until dedicated models are supplied.
const ORDER := ["drone", "skiff", "prospector", "barge", "orca", "hulk"]
const TYPES := {
	"drone": {"name": "采矿无人机", "role": "无人机", "color": Color(0.5, 0.62, 0.66)},
	"skiff": {"name": "冲锋者级", "role": "采矿护卫舰", "color": Color(0.18, 0.46, 0.82)},
	"prospector": {"name": "掘金者级", "role": "采矿突击舰", "color": Color(0.95, 0.49, 0.08)},
	"barge": {"name": "回旋", "role": "采矿船", "color": Color(0.16, 0.66, 0.36)},
	"orca": {"name": "海豚级", "role": "采矿指挥舰", "color": Color(0.61, 0.30, 0.84)},
	"hulk": {"name": "霍克级", "role": "高级采矿船", "color": Color(0.83, 0.18, 0.23)},
}

static func label(id: String) -> String:
	var row: Dictionary = TYPES.get(id, TYPES["skiff"])
	return row.name + " · " + row.role

static func material(id: String) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = TYPES.get(id, TYPES["skiff"])["color"]
	result.metallic = 0.2
	result.roughness = 0.65
	return result

static func apply_material(root: Node, id: String) -> void:
	var mat := material(id)
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			node.material_override = mat
		for child in node.get_children():
			stack.append(child)
