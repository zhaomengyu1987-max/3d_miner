extends Node3D

var failures := 0
var assertions := 0


func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failures += 1
		push_error("VISITOR_SUPPLY: " + message)


func ship(hull: String) -> Freighter:
	var rng := RandomNumberGenerator.new()
	rng.seed = 17921
	return Freighter.make("giant", false, rng, {}, {}, hull)


func _ready() -> void:
	await get_tree().process_frame
	Economy.set_process(false)
	MissionOps.set_process(false)
	Economy.save_path = "user://visitor_supply_test.json"
	WorldState._save_path = "user://visitor_supply_world.json"
	Economy.debug_reset()
	WorldState.debug_reset()
	var freight: Node = Economy.freight
	var last_fuel := 0
	var last_ammo := 0
	for hull in ["frigate", "battleship", "flagship"]:
		var visitor := ship(hull)
		Economy.fuel = 1000.0
		Economy.inv.plasmaAmmo = 2000
		var before_money: float = Economy.money
		var before_funds: float = visitor.funds
		var fuel_price: float = Economy.expected_freighter_price("fuel", false)
		var ammo_price: float = Economy.expected_freighter_price("plasmaAmmo", false)
		freight._resupply_warship(visitor)
		var requested: Dictionary = GameData.VISITOR_SUPPLIES[hull]
		var fuel: int = requested.fuel
		var ammo: int = requested.plasmaAmmo
		var total := fuel * fuel_price + ammo * ammo_price
		check(fuel > last_fuel and ammo > last_ammo, "Larger warship consumes more: " + hull)
		check(Economy.fuel == 1000.0 - fuel and Economy.stock("plasmaAmmo") == 2000 - ammo, "Supplies consume station stock")
		check(int(visitor.supplies_received.fuel) == fuel and int(visitor.supplies_received.plasmaAmmo) == ammo, "Ship receives its exact requirement")
		check(is_equal_approx(Economy.money - before_money, total), "Player receives fuel and ammunition revenue")
		check(is_equal_approx(before_funds - visitor.funds, total), "Ship pays from its actual trade budget")
		check(visitor.cargo_units == 0.0, "Consumed supplies do not become transport cargo")
		freight._resupply_warship(visitor)
		check(is_equal_approx(Economy.money - before_money, total), "Repeat supply does not double charge")
		last_fuel = fuel
		last_ammo = ammo
	var industrial := ship("industrial")
	var before_fuel: float = Economy.fuel
	var before_ammo: int = Economy.stock("plasmaAmmo")
	freight._resupply_warship(industrial)
	check(industrial.supplies_requested.is_empty() and Economy.fuel == before_fuel and Economy.stock("plasmaAmmo") == before_ammo,
		"Industrial hull does not consume warship supplies")
	var partial := ship("frigate")
	Economy.fuel = 2.0
	Economy.inv.plasmaAmmo = 3
	freight._resupply_warship(partial)
	check(Economy.fuel == 0.0 and Economy.stock("plasmaAmmo") == 0, "Partial supply never overdraws stock")
	check(int(partial.supplies_received.fuel) == 2 and int(partial.supplies_received.plasmaAmmo) == 3, "Shortage gives only available stock")
	Economy.fuel = 1000.0
	Economy.inv.plasmaAmmo = 1000
	freight._resupply_warship(partial)
	check(int(partial.supplies_received.fuel) == 20 and int(partial.supplies_received.plasmaAmmo) == 40, "Restocking purchases only the remaining requirement")
	var poor := ship("frigate")
	poor.funds = 0.5
	before_fuel = Economy.fuel
	before_ammo = Economy.stock("plasmaAmmo")
	freight._resupply_warship(poor)
	check(poor.funds == 0.5 and Economy.fuel == before_fuel and Economy.stock("plasmaAmmo") == before_ammo, "No free supplies when ship cannot afford a unit")
	Economy.modules.hangar.built = true
	Economy.modules.hangar.level = 3
	var empty := ship("flagship")
	Economy.fuel = 0.0
	Economy.inv.plasmaAmmo = 0
	check(Economy.dock_special_freighter(empty), "Special military visitor uses the same resupply path")
	check(empty.shortage_reported and empty.supplies_received.is_empty(), "Missing supplies are reported")
	freight.tick_dwell(61.0)
	check(not Economy.berths.has(empty), "Unfilled supplies do not block timed departure")
	Economy.fuel = 1000.0
	Economy.inv.plasmaAmmo = 1000
	WorldState.phase = WorldState.Phase.BUILDUP
	WorldState.stockpile = 0.0
	freight._resupply_warship(ship("frigate"))
	check(WorldState.stockpile > 0.0, "Actual ammunition sales feed military supply accumulation")
	WorldState.phase = WorldState.Phase.PEACE
	Economy.berths.clear()
	Economy.fuel = 10.0
	var money: float = Economy.money
	check(Economy._try_arrive("small", false), "Ordinary industrial visitor still arrives")
	check(Economy.fuel == 5.0 and Economy.money == money, "Existing harbour cost stays separate from paid warship supplies")
	print("VISITOR_SUPPLY_TEST_%s (%d assertions)" % ["PASS" if failures == 0 else "FAIL", assertions])
	get_tree().quit(0 if failures == 0 else 1)
