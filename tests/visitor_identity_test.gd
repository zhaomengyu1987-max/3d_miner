extends Node3D

var failures := 0
var assertions := 0


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("VISITOR_IDENTITY: " + message)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.debug_reset()
	Economy._world.set_process(false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 82921
	for tier in GameData.FREIGHTERS:
		var definition: Dictionary = GameData.FREIGHTERS[tier]
		for hull in GameData.VISITOR_HULL_WEIGHTS[tier]:
			var f := Freighter.make(tier, false, rng, {}, {}, hull)
			check(f.def_id == tier and f.hull_id == hull, "Capacity tier and hull are independent: " + tier + "/" + hull)
			check(f.cap == definition.cap and f.funds > 0.0, "Hull selection preserves trade capacity and budget")
			if hull == "industrial":
				check(f.name == definition.name, "Industrial hull retains industrial name")
			else:
				check(f.name == GameData.VISITOR_HULL_NAMES[hull] and not "工业" in f.name and not "货运" in f.name,
					"Military hull is labelled with its actual ship class")
		var counts: Dictionary = {}
		var valid_names := true
		for sample in 400:
			var visitor := Freighter.make(tier, false, rng)
			counts[visitor.hull_id] = int(counts.get(visitor.hull_id, 0)) + 1
			var expected: String = definition.name if visitor.hull_id == "industrial" else GameData.VISITOR_HULL_NAMES[visitor.hull_id]
			valid_names = valid_names and visitor.name == expected
		check(valid_names, "Random arrivals always match model and name: " + tier)
		if tier == "small":
			check(int(counts.get("industrial", 0)) == 400, "Level-one traffic remains industrial")
		else:
			check(int(counts.get("industrial", 0)) > 220 and int(counts.get("industrial", 0)) < 340,
				"Industrial ships remain the majority while military ships still visit: " + tier)
			check(counts.size() == 2, "Both ship classes appear in random traffic: " + tier)
	var smuggler := Freighter.make("standard", true, rng, {}, {}, "frigate")
	check(smuggler.name == "走私·护卫舰", "Smuggler role does not replace the actual hull class")
	Economy.modules.hangar.built = true
	Economy.modules.hangar.level = 3
	WorldState.dealer = null
	WorldState._ensure_dealer()
	check(WorldState.dealer != null and WorldState.dealer.hull_id == "flagship", "Military procurement explicitly uses flagship hull")
	check(WorldState.dealer.name.contains("旗舰") and not WorldState.dealer.name.contains("工业"), "Procurement flagship has a truthful name")
	var node: Node3D = Economy._world._ships[WorldState.dealer]
	var labels := node.find_children("*", "Label3D", false, false)
	check(node.get_meta("hull_id") == "flagship", "World uses explicit hull identity")
	check(labels.size() == 1 and labels[0].text == WorldState.dealer.name, "World label matches the name used by hangar and market")
	print("VISITOR_IDENTITY_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)
