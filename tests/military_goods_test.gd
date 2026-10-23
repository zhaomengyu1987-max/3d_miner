extends Node3D

var failures := 0
var assertions := 0


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("MILITARY_GOODS: " + message)


func materials(id: String, batches := 1) -> void:
	for ore in Economy.effective_materials(id):
		Economy.inv[ore] = int(Economy.effective_materials(id)[ore]) * batches


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	MissionOps.set_process(false)
	WorldState.set_process(false)
	Economy._world.set_process(false)
	Economy.save_path = "user://military_goods_test.json"
	WorldState._save_path = "user://military_goods_world.json"
	WorldState.debug_reset()
	_test_recipes()
	_test_manufacture()
	_test_warship_orders()
	_test_matching()
	_test_save_load()
	await _test_ui()
	print("MILITARY_GOODS_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func _test_recipes() -> void:
	check(GameData.product_ids("ammo").size() == 4, "Four ammunition types")
	check(GameData.product_ids("ship_equipment").filter(func(id): return GameData.is_open_recipe(id)).size() == 3, "Three initial commercial ship equipment types")
	for id in GameData.WARSHIP_PRIORITY:
		var product: Dictionary = GameData.PRODUCTS[id]
		check(GameData.is_open_recipe(id) and not GameData.requires_license(id), "Open recipe: " + id)
		check(GameData.is_military(id) and not product.get("is_equip", false), "Military commercial inventory: " + id)
		check(not GameData.licensed_equip_ids().has(id), "No license or blueprint catalogue entry: " + id)
		var revenue := GameData.good_unit_price(id) * float(product.batch) * 0.9
		check(revenue >= GameData.material_cost(product.bom) * 1.8, "Manufacturing adds value: " + id)
	for id in ["kineticAmmo", "thermalMissile", "heavyTorpedo", "armorPlate"]:
		var low_only := true
		for ore in GameData.PRODUCTS[id].bom:
			low_only = low_only and String(ore).begins_with("common")
		check(low_only, "Low mineral recipe: " + id)
	check(GameData.PRODUCTS.thermalMissile.bom.size() > GameData.PRODUCTS.kineticAmmo.bom.size(), "Missiles require more mineral varieties")
	check(_ore_quantity("heavyTorpedo") >= 1000 and _ore_quantity("armorPlate") >= 1000, "Torpedoes and plates consume bulk minerals")
	var membrane_high_only := true
	for ore in GameData.PRODUCTS.resistanceMembrane.bom:
		membrane_high_only = membrane_high_only and String(ore).begins_with("rare")
	check(membrane_high_only and _ore_quantity("resistanceMembrane") <= 20, "Membrane uses small amounts of high minerals")
	check(GameData.PRODUCTS.nanoArmorRepairer.bom.has("commonA") and GameData.PRODUCTS.nanoArmorRepairer.bom.has("rareE"), "Repairer uses mixed minerals")
	check(GameData.good_name("plasmaAmmo").contains("高级") and GameData.PRODUCTS.plasmaAmmo.bom.has("rareD"), "Plasma is advanced ammunition")


func _ore_quantity(id: String) -> int:
	var quantity := 0
	for count in GameData.PRODUCTS[id].bom.values():
		quantity += int(count)
	return quantity


func _test_manufacture() -> void:
	for id in GameData.WARSHIP_PRIORITY:
		Economy.debug_reset()
		materials(id)
		var mo_before: int = MissionOps.inventory.get(id, 0)
		check(Economy.factory_count() == 0 and Economy.max_lines() == 1, "Initial handcraft line available")
		check(Economy.production_block_reason(id, 1) == "", "Manufacturable at start: " + id)
		var money_before: float = Economy.money
		check(Economy.buy_license(id) != "" and Economy.money == money_before, "No license fee for open recipe")
		check(Economy.start_research("blueprint", id) != "", "No blueprint required or offered")
		check(Economy.start_production(id, 1) == "", "Handcraft starts: " + id)
		check(Economy.prod_jobs.size() == 1 and not Economy.prod_jobs[0].uses_license, "Job does not reserve a license")
		var all_consumed := true
		for ore in GameData.PRODUCTS[id].bom:
			all_consumed = all_consumed and Economy.stock(ore) == 0
		check(all_consumed, "Exact minerals consumed")
		Economy.production.advance(10000.0)
		check(Economy.stock(id) == int(GameData.PRODUCTS[id].batch), "Correct batch in commercial inventory: " + id)
		check(int(MissionOps.inventory.get(id, 0)) == mo_before, "Does not enter expedition inventory")
		check(Economy.licenses.is_empty() and Economy.reverse.is_empty(), "No license or reverse progress generated")
	Economy.debug_reset()
	check(Economy.production_block_reason("kineticAmmo", 1).contains("材料不足"), "Open recipes still require minerals")
	check(Economy.production_block_reason("smallArms", 1) == "需要建造厂", "Existing licensed products retain factory gate")
	check(Economy.production_block_reason("longbow", 1) == "需要建造厂", "Ships retain factory gate")
	Economy.modules.factory.count = 1
	materials("smallArms")
	check(Economy.production_block_reason("smallArms", 1).contains("许可证"), "Existing products retain licensing")
	Economy.debug_reset()
	materials("kineticAmmo", 3)
	check(Economy.start_production("kineticAmmo", 1) == "" and Economy.start_production("kineticAmmo", 2) == "", "Open goods use existing production queue")
	check(Economy.order_queue.size() == 1 and not Economy.order_queue[0].uses_license, "Queued open recipe reserves no license")
	Economy.cancel_order(0)
	check(Economy.stock("commonA") == 160 and Economy.stock("commonB") == 80 and Economy.licenses.is_empty(), "Queue cancellation refunds exact ore and no licenses")


func _test_warship_orders() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 78402
	for hull in ["frigate", "battleship", "flagship"]:
		var visitor := Freighter.make("giant", false, rng, {}, {"military": 1.6}, hull)
		for id in GameData.WARSHIP_PRIORITY:
			var offer := visitor.buy_offer_for(id)
			check(not offer.is_empty() and float(offer.qty_left) >= 1.0, "Warship always wants " + id + ": " + hull)
			var expected: float = GameData.good_unit_price(id) * 0.9 * 1.6
			check(float(offer.price) >= expected * 0.9 - 0.001 and float(offer.price) <= expected * 1.1 + 0.001, "Military demand affects new offers")
		var seen := []
		for offer in visitor.buy_offers:
			check(not seen.has(offer.goods), "No duplicate military/random offers")
			seen.append(offer.goods)
	var licenses_valid := true
	for tier in GameData.FREIGHTERS:
		for smuggler in [false, true]:
			for sample in 20:
				var visitor := Freighter.make(tier, smuggler, rng)
				for offer in visitor.sell_offers:
					if String(offer.goods).begins_with("lic:"):
						licenses_valid = licenses_valid and GameData.requires_license(String(offer.goods).substr(4))
	check(licenses_valid, "Public and smuggler visitors never sell open recipe licenses")


func _test_matching() -> void:
	Economy.debug_reset()
	var visitor := Freighter.new()
	visitor.hull_id = "battleship"
	visitor.funds = 100.0
	visitor.cap = 10.0
	visitor.buy_offers = [{"goods": "commonA", "price": 2.0, "qty_left": 10.0},
		{"goods": "thermalMissile", "price": 10.0, "qty_left": 10.0}]
	Economy.inv.commonA = 10
	Economy.inv.thermalMissile = 10
	check(Economy.post_sell("commonA", 10, 1.0) == "" and Economy.post_sell("thermalMissile", 10, 5.0) == "", "New goods can be listed")
	var money: float = Economy.money
	check(Economy.market._freighter_buys(visitor, 4.0) == 4, "Shared trade rate enforced")
	check(visitor.buy_offer_for("thermalMissile").qty_left == 6.0 and visitor.buy_offer_for("commonA").qty_left == 10.0, "Warship prioritizes goods even when ore offer comes first")
	check(Economy.money == money + 40.0 and visitor.funds == 60.0, "Actual sales credit player and debit ship")
	check(Economy.market._freighter_buys(visitor, 100.0) == 6 and visitor.funds == 0.0 and visitor.cargo_units == 10.0, "Priority cannot exceed funds or capacity")
	var industrial := Freighter.new()
	industrial.hull_id = "industrial"
	industrial.buy_offers = visitor.buy_offers.duplicate(true)
	check(industrial.prioritized_buy_offers()[0].goods == "commonA", "Industrial ship retains its ordinary order")
	Economy.sell_orders.clear()
	Economy.inv.armorPlate = 2
	Economy.post_sell("armorPlate", 2, 100.0)
	visitor.funds = 1000.0
	visitor.cap = 100.0
	visitor.cargo_units = 0.0
	visitor.buy_offers = [{"goods": "armorPlate", "price": 50.0, "qty_left": 2.0}]
	check(Economy.market._freighter_buys(visitor, 100.0) == 0, "Priority respects player ask price")
	visitor.buy_offers[0].price = 100.0
	visitor.cap = 1.0
	check(Economy.market._freighter_buys(visitor, 100.0) == 1 and Economy.sell_orders[0].qty == 1, "Equipment occupies cargo and only available space fills")
	WorldState.dealer = visitor
	WorldState._refresh_dealer_offers()
	for id in GameData.WARSHIP_PRIORITY:
		check(not visitor.buy_offer_for(id).is_empty(), "Military procurement includes new goods: " + id)
	WorldState.dealer = null


func _test_save_load() -> void:
	Economy.debug_reset()
	for id in GameData.WARSHIP_PRIORITY:
		Economy.inv[id] = 7
	materials("heavyTorpedo", 2)
	Economy.start_production("heavyTorpedo", 1)
	Economy.start_production("heavyTorpedo", 1)
	Economy.post_sell("resistanceMembrane", 2, 100.0)
	check(Economy.save_game(), "Save new inventory, jobs and listings")
	Economy.debug_reset()
	Economy.load_game()
	check(Economy.stock("resistanceMembrane") == 5 and Economy.sell_orders.size() == 1, "New inventory and market listing survive save/load")
	check(Economy.prod_jobs.size() == 1 and Economy.order_queue.size() == 1, "Active and queued open jobs survive save/load")
	Economy.production.advance(10000.0)
	Economy.production.advance(10000.0)
	check(Economy.stock("heavyTorpedo") == 27 and Economy.licenses.is_empty(), "Restored jobs complete with correct batch output")


func _test_ui() -> void:
	Economy.debug_reset()
	var ui = get_tree().get_first_node_in_group("econ_ui")
	check(ui != null, "Game UI available")
	if ui == null:
		return
	ui._open_module_panel("factory")
	for frame in 4:
		await get_tree().process_frame
	check(ui._panels.factory.visible, "Factory menu opens initial handcraft catalogue without a built factory")
	var factory_labels := ""
	for label in ui._panels.factory.find_children("*", "Label", true, false):
		factory_labels += label.text + "\n"
	check(factory_labels.contains("弹药（初始可造") and factory_labels.contains("舰用装备（常规配方初始可造"), "Manufacturing shows ammunition and equipment sections")
	for id in GameData.WARSHIP_PRIORITY:
		check(factory_labels.contains(GameData.good_name(id)), "Manufacturing displays " + id)
	ui.open_panel("market")
	for frame in 4:
		await get_tree().process_frame
	var market = ui._panels.market
	var displayed := []
	for index in market._goods_list.item_count:
		displayed.append(str(market._goods_list.get_item_metadata(index)))
	for id in GameData.WARSHIP_PRIORITY:
		check(displayed.has(id) and not displayed.has("lic:" + id), "Market lists new good without license: " + id)
	check(displayed.has("lic:heavyArms") and displayed.has("lic:longbow"), "Existing product and ship license market preserved")
