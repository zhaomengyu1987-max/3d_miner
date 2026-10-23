extends Node3D

const Frigate := preload("res://sences/ships/FrigateVisitor.tscn")
const Battleship := preload("res://sences/ships/BattleshipVisitor.tscn")
var relations: Node
var world: Node3D
var groups := {}
var age := 0.0


func _process(delta: float) -> void:
	age += delta
	for fid in relations.FACTIONS:
		var active: bool = float(relations.patrols[fid].left) > 0.0
		if active and not groups.has(fid):
			var group := Node3D.new()
			group.name = "Inspection_" + fid
			add_child(group)
			for packed in [Battleship, Frigate]:
				var ship: Node3D = packed.instantiate()
				group.add_child(ship)
				var label := Label3D.new()
				label.text = relations.faction_name(fid) + "审查舰队"
				label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				label.no_depth_test = true
				label.pixel_size = 0.65
				label.font_size = 32
				label.position.y = 100.0
				label.modulate = Color("edac73") if fid == "empire" else Color("75cbe6")
				ship.add_child(label)
			groups[fid] = group
		elif not active and groups.has(fid):
			groups[fid].queue_free()
			groups.erase(fid)
		if not groups.has(fid): continue
		var center: Vector3 = world._hub.global_position if is_instance_valid(world._hub) else world.global_position
		var radius: float = maxf(world._station_half_r * 2.5, 1300.0)
		var group: Node3D = groups[fid]
		for index in group.get_child_count():
			var angle := age * 0.015 + index * 0.16 + (PI if fid == "empire" else 0.0)
			var ship: Node3D = group.get_child(index)
			ship.global_position = center + Vector3(cos(angle) * radius, 160.0 + index * 40.0, sin(angle) * radius)
			ship.rotation.y = -angle - PI * 0.5
