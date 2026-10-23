extends Node3D

const MarketPanel := preload("res://scripts/ui/EconMarketPanel.gd")
const MainScene := preload("res://sences/main.tscn")
var failures := 0
var assertions := 0


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("NEUTRAL_TEST: " + message)


func orders_for(fid: String) -> Array:
	return Economy.sell_orders.filter(func(order): return String(order.get("owner", "")) == fid)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	Economy.save_path = "user://neutral_mining_test.json"
	Economy.rng.seed = 2073
	Economy.debug_reset()
	var manager: Node3D = Economy.neutral_fleets
	manager.set_process(false)
	var fid := "neutral_aurora"
	var mother_fid := "neutral_deep"
	check(manager.fleets.size() == 3, "Three neutral factions")
	for state in manager.fleets.values():
		check(state.ships.size() >= 1 and state.ships.size() <= 3, "One to three miners per faction")
	var initial_money: float = Economy.money
	var initial_neutral_money: float = manager.fleets[fid].money
	check(manager.refuel_ship(fid, 0.0) == 0.0, "No station fuel means no departure")
	Economy.fuel = 100.0
	var fuel_price: float = Economy.expected_freighter_price("fuel", false)
	var bought: float = manager.refuel_ship(fid, 0.0)
	check(bought == 12.0 and Economy.fuel == 88.0, "Refuel takes station stock")
	check(is_equal_approx(Economy.money - initial_money, bought * fuel_price), "Fuel purchase pays player")
	check(is_equal_approx(initial_neutral_money - manager.fleets[fid].money, bought * fuel_price), "Fuel purchase charges faction")
	manager.fleets[fid].money = 0.0
	check(manager.refuel_ship(fid, 0.0) == 0.0 and Economy.fuel == 88.0, "Cannot buy fuel without money")
	manager.fleets[fid].money = 5000.0
	Economy.fuel = 2.0
	check(manager.refuel_ship(fid, 0.0) == 2.0 and Economy.fuel == 0.0, "Partial refuel never overdraws station")
	var neutral_before: float = manager.fleets[fid].money
	var player_before: float = Economy.money
	manager.deliver_cargo(fid, {"commonA": 60, "rareA": 20})
	check(orders_for(fid).size() == 1, "Mixed cargo occupies one order")
	check(Economy.stock("commonA") == 0 and Economy.stock("rareA") == 0, "Neutral ore never enters player stock")
	manager.deliver_cargo(fid, {"commonA": 40, "commonB": 25})
	check(orders_for(fid).size() == 1 and int(orders_for(fid)[0].qty) == 100, "Further deliveries update the same order")
	check(int(manager.fleets[fid].stock.commonB) == 25, "Other minerals wait for the next order")
	var order: Dictionary = orders_for(fid)[0]
	check(not Economy.cancel_sell_by_uid(int(order.uid)), "Player cannot cancel faction orders")
	var visitor := Freighter.new()
	visitor.cap = 1000.0
	visitor.funds = 1000.0
	visitor.buy_offers = [{"goods": "commonA", "qty_left": 50.0, "price": 2.0}]
	Economy.berths.append(visitor)
	Economy.market._auto_trade(1.0)
	check(int(order.qty) == 60, "Visiting freighter buys neutral ore at normal throughput")
	check(is_equal_approx(manager.fleets[fid].money - neutral_before, 80.0), "Ore proceeds belong to neutral faction")
	check(Economy.money == player_before, "NPC ore sales do not give player money")
	Economy.berths.clear()
	var order_price: float = order.price
	check(Economy.fillable_range("commonA", true) == Vector2(order_price, order_price),
		"Buy price guidance reflects the actual neutral ask")
	Economy.post_buy("commonA", 10, order_price - 0.1)
	Economy.market._auto_trade(1.0)
	check(Economy.stock("commonA") == 0, "Player limit price is respected")
	Economy.buy_orders.clear()
	Economy.post_buy("commonA", 10, order_price)
	neutral_before = manager.fleets[fid].money
	player_before = Economy.money
	Economy.market._auto_trade(1.0)
	check(Economy.stock("commonA") == 10, "Player can buy neutral ore without visitors")
	check(is_equal_approx(player_before - Economy.money, 10.0 * order_price), "Player pays the faction ask")
	check(is_equal_approx(manager.fleets[fid].money - neutral_before, 10.0 * order_price), "Player trade credits the faction")
	Economy.inv.commonA = 5
	Economy.post_sell("commonA", 5, order_price)
	check(Economy.sell_orders.size() == 2, "Player and faction orders never merge")
	Economy.day = 5
	Economy.expire_orders()
	check(Economy.stock("commonA") == 5, "Only the player's unsold ore is refunded to player")
	check(int(manager.fleets[fid].stock.commonA) == 50, "Expired faction ore returns to faction")
	manager.publish_order(fid)
	check(orders_for(fid).size() == 1, "Faction can republish after expiry")
	manager.deliver_cargo(mother_fid, {"commonB": 123})
	check(orders_for(mother_fid).is_empty(), "Mothership factions never list their ore")
	check(int(manager.fleets[mother_fid].mother_stock.commonB) == 123, "Mothership receives mined cargo")
	var ui := MarketPanel.new()
	check(ui._collect_offers("commonA", false).size() == 1, "Faction sell order appears in market seller list")
	ui.free()
	var old_uid: int = orders_for(fid)[0].uid
	check(Economy.save_game(), "Neutral economy saves")
	manager.fleets[mother_fid].mother_stock.clear()
	manager.fleets[fid].money = 0.0
	Economy.load_game()
	check(int(manager.fleets[mother_fid].mother_stock.commonB) == 123, "Mother stock survives load")
	check(float(manager.fleets[fid].money) > 0.0, "Faction money survives load")
	check(orders_for(fid).size() == 1, "Single faction order survives load")
	Economy.inv.commonB = 10
	Economy.post_sell("commonB", 10)
	check(int(Economy.sell_orders[-1].uid) > old_uid, "New IDs do not collide with loaded orders")
	Economy.sell_orders.clear()
	manager.fleets[fid].stock.clear()
	manager.deliver_cargo(fid, {"commonA": 3, "rareA": 4})
	Economy.inv.commonA = 3
	Economy.post_sell("commonA", 3, 2.0)
	visitor.buy_offers = [{"goods": "commonA", "qty_left": 10.0, "price": 2.0}]
	visitor.cargo_units = 0.0
	check(Economy.market._freighter_buys(visitor, 100.0) == 6,
		"Completing a faction order does not skip the following player order")
	manager.publish_order(fid)
	check(orders_for(fid).size() == 1 and String(orders_for(fid)[0].goods) == "rareA",
		"Next mineral takes the same single faction order slot after a sale")
	await _test_world(manager)
	print("NEUTRAL_MINING_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)


func _test_world(manager: Node3D) -> void:
	var main := MainScene.instantiate()
	add_child(main)
	var belt: BeltFlow = main.get_node("BeltFlow")
	belt.target_count = 15
	await get_tree().process_frame
	# bind_world normally searches the current main scene; this test hosts it as a child.
	manager._belt = belt
	manager._station = main.get_node("MiningHub")
	manager._world = Economy._world
	manager._spawn_visuals()
	var expected := 0
	for state in manager.fleets.values():
		expected += state.ships.size()
	check(manager.miners.size() == expected, "World spawns all neutral miners")
	check(manager.motherships.size() == 1, "World spawns a mothership")
	var mother: Node3D = manager.motherships["neutral_deep"]
	var visual := mother.get_child(0) as MeshInstance3D
	check(is_equal_approx(visual.mesh.size.x, 530.9215 * 0.5), "Placeholder is half flagship length")
	for miner in manager.miners:
		miner.set_process(false)
		check(is_same(miner.claims, Economy._world._corvette_claims), "Player and NPC miners share ore reservations")
	var ship: Node3D = manager.miners[0]
	ship.supply_state = ship.SupplyState.TO_REFUEL
	ship.fuel_left = 0.0
	ship.global_position = ship.refuel_position
	ship.motion.stop()
	Economy.fuel = 0.0
	ship._process(0.1)
	check(ship.supply_state == ship.SupplyState.WAITING, "Fuel shortage keeps miner at station")
	Economy.fuel = 50.0
	ship._supply_retry = 0.0
	ship._process(0.1)
	check(ship.supply_state == ship.SupplyState.WORKING and ship.fuel_left > 0.0, "Miner resumes when fuel is available")
	ship._cargo = {"commonD": 50}
	ship._unload()
	check(ship._cargo.is_empty() and ship.delivered_total >= 50, "Actual neutral ship unload routes cargo to faction")
	var mother_ship: Node3D
	for miner in manager.miners:
		if miner.fleet_id == "neutral_deep":
			mother_ship = miner
			break
	check(mother_ship.station == mother, "Mother faction miners return to mothership")
	mother_ship._cargo = {"rareB": 11}
	mother_ship._unload()
	check(int(manager.fleets.neutral_deep.mother_stock.rareB) == 11, "Ship unload reaches actual mothership inventory")
	check(orders_for("neutral_deep").is_empty(), "Mother unloading does not create a market order")
	# Exercise navigation -> extraction -> full/low-fuel return -> unload without shortcuts.
	for i in belt._pool.size():
		var ore: BeltOre = belt._pool[i]
		ore.tier = "M"
		ore.ore_name = "RockOre"
		ore.amount = 2000
		ore.captured = false
		ore.freeze = true
		ore.set_physics_process(false)
		ore.global_position = manager._station.global_position + Vector3(-1500.0 - i * 30.0, -80.0, -400.0 - i * 60.0)
	Economy.fuel = 2000.0
	for miner in manager.miners:
		miner._forget_target()
		miner._stop_laser()
		miner._state = miner.State.IDLE
		miner._cargo.clear()
		miner.fuel_left = 12.0
		miner.supply_state = miner.SupplyState.WORKING
	for step in 12000:
		for miner in manager.miners:
			miner._process(1.0 / 30.0)
	var mined := 0
	var delivered := 0
	for miner in manager.miners:
		mined += miner.mined_total
		delivered += miner.delivered_total
	check(mined > 0 and delivered > 100, "Autonomous ships fly, mine and return ore")
	check(Economy.fuel < 2000.0, "Working fleets periodically return for station fuel")
	check(int(manager.fleets.neutral_deep.mother_stock.get("commonB", 0)) > 123,
		"Autonomous mother fleet actually delivers mined ore")
	check(orders_for("neutral_aurora").size() == 1 and orders_for("neutral_copper").size() == 1,
		"Autonomous independent fleets each retain one market order")
	ship._cargo = {"commonE": 37}
	ship.fuel_left = 4.0
	Economy.save_game()
	Economy.load_game()
	for miner in manager.miners:
		miner.set_process(false)
	check(manager.miners[0]._cargo.get("commonE", 0) == 37, "In-flight cargo persists")
	check(manager.miners[0].fuel_left == 4.0, "In-flight fuel persists")
