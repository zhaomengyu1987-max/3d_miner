extends Node3D
## Neutral factions own their money, ship cargo and ore. Only fuel purchases pay the station.
const MinerScript := preload("res://scripts/economy/NeutralMiningShip.gd")
const FLAGSHIP := preload("res://sences/ships/FlagshipVisitor.tscn")
const FACTIONS := [
	{"id": "neutral_aurora", "name": "极光采掘联合", "color": Color(0.35, 0.85, 0.82), "mothership": false},
	{"id": "neutral_copper", "name": "赤铜矿业", "color": Color(0.95, 0.62, 0.28), "mothership": false},
	{"id": "neutral_deep", "name": "深域勘采团", "color": Color(0.65, 0.58, 0.95), "mothership": true},
]

var eco: Node
var fleets: Dictionary = {}
var miners: Array = []
var motherships: Dictionary = {}
var _labels: Dictionary = {}
var _belt: BeltFlow
var _station: Node3D
var _world: Node3D
var _market_tick := 0.0


func reset_state() -> void:
	_clear_visuals()
	fleets.clear()
	for faction in FACTIONS:
		var ships: Array = []
		for i in eco.rng.randi_range(1, 3):
			ships.append({"cargo": {}, "fuel": 0.0})
		fleets[faction.id] = {"money": float(GameData.NEUTRAL_MINING["starting_money"]),
			"stock": {}, "mother_stock": {}, "ships": ships}
	if is_instance_valid(_belt) and is_instance_valid(_station):
		_spawn_visuals()


func bind_world(world: Node3D) -> void:
	_world = world
	var scene := get_tree().current_scene
	if scene == null:
		return
	_belt = scene.find_child("BeltFlow", true, false) as BeltFlow
	_station = scene.find_child("MiningHub", true, false) as Node3D
	if _belt != null and _station != null:
		_spawn_visuals()


func _clear_visuals() -> void:
	for miner in miners:
		miner.set_process(false)
		miner._forget_target()
		miner._stop_laser()
		miner.queue_free()
	miners.clear()
	for mother in motherships.values():
		mother.queue_free()
	motherships.clear()
	_labels.clear()


func _spawn_visuals() -> void:
	_clear_visuals()
	var index := 0
	for faction in FACTIONS:
		var fid: String = faction.id
		var state: Dictionary = fleets[fid]
		var home: Node3D = _station
		if bool(faction.mothership):
			home = _make_mothership(faction)
			motherships[fid] = home
		for i in state.ships.size():
			var miner := MinerScript.new()
			miner.fleet_manager = self
			miner.fleet_id = fid
			miner.ship_index = i
			miner.faction_color = faction.color
			miner.belt = _belt
			miner.station = home
			# Player and neutral laser miners use one reservation list.
			miner.claims = _world._corvette_claims
			var angle := deg_to_rad(195.0 + float(index) * 18.0)
			miner.refuel_position = _station.global_position + Vector3(cos(angle) * 1100.0, -80.0, sin(angle) * 1100.0)
			miner.park_pos = home.global_position + Vector3(float(i - 1) * 120.0, 50.0, 180.0) \
				if bool(faction.mothership) else miner.refuel_position
			add_child(miner)
			miner.global_position = miner.refuel_position
			miner.restore_state(state.ships[i])
			miners.append(miner)
			index += 1
	_update_mother_labels()


func _make_mothership(faction: Dictionary) -> Node3D:
	var mother := Node3D.new()
	mother.name = "Mothership_" + String(faction.id)
	add_child(mother)
	var corridor_center := (_belt.spawn_center + _belt.despawn_center) * 0.5
	mother.global_position = _belt.to_global(corridor_center) + Vector3(-500.0, 0.0, 500.0)
	var flagship_length := float(FLAGSHIP.get_state().get_node_property_value(0,
		_find_property(FLAGSHIP.get_state(), "hull_length")))
	# Half the existing flagship's authored length. The box is replaced by a hull later.
	var length := flagship_length * 0.5
	var visual := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(length, length * 0.23, length * 0.36)
	visual.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = faction.color.darkened(0.3)
	mat.metallic = 0.45
	mat.roughness = 0.65
	visual.material_override = mat
	mother.add_child(visual)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.4
	label.font_size = 28
	label.modulate = faction.color
	label.position.y = length * 0.25
	mother.add_child(label)
	_labels[faction.id] = label
	return mother


func _find_property(scene: SceneState, property_name: String) -> int:
	for i in scene.get_node_property_count(0):
		if scene.get_node_property_name(0, i) == property_name:
			return i
	return -1


func fleet_name(fid: String) -> String:
	for faction in FACTIONS:
		if faction.id == fid:
			return faction.name
	return fid


func has_mothership(fid: String) -> bool:
	for faction in FACTIONS:
		if faction.id == fid:
			return bool(faction.mothership)
	return false


func refuel_ship(fid: String, current_fuel: float) -> float:
	if not fleets.has(fid):
		return 0.0
	var price: float = eco.expected_freighter_price(GameData.FUEL_ID, false) * eco.price_factor(GameData.FUEL_ID)
	price = maxf(price, 0.01)
	var state: Dictionary = fleets[fid]
	var need := maxi(0, floori(float(GameData.NEUTRAL_MINING["tank_capacity"]) - current_fuel))
	var quantity := mini(need, mini(int(eco.fuel), int(float(state.money) / price)))
	if quantity <= 0:
		return 0.0
	var cost := float(quantity) * price
	state.money = float(state.money) - cost
	eco.fuel -= quantity
	eco.add_money(cost)
	eco.fuel_changed.emit()
	eco.market._log_trade(GameData.FUEL_ID, price, quantity)
	eco.post_event("%s 补给：燃料 ×%d · 收入 %s" % [fleet_name(fid), quantity, EconTheme.money(cost)], "good")
	return float(quantity)


func deliver_cargo(fid: String, cargo: Dictionary) -> void:
	if not fleets.has(fid):
		return
	var destination: Dictionary = fleets[fid]["mother_stock" if has_mothership(fid) else "stock"]
	for gid in cargo:
		var amount := maxi(0, int(cargo[gid]))
		destination[gid] = int(destination.get(gid, 0)) + amount
	if not has_mothership(fid):
		publish_order(fid)
	_update_mother_labels()


func publish_order(fid: String) -> void:
	if has_mothership(fid) or not fleets.has(fid):
		return
	var stock: Dictionary = fleets[fid].stock
	var goods := ""
	for listing in eco.sell_orders:
		if String(listing.get("owner", "")) == fid:
			goods = String(listing.goods)
			break
	if goods == "":
		for gid in stock:
			if int(stock[gid]) > 0:
				goods = String(gid)
				break
	var quantity := int(stock.get(goods, 0))
	if quantity <= 0:
		return
	if eco.market.post_neutral_sell(fid, fleet_name(fid), goods, quantity):
		stock[goods] = int(stock.get(goods, 0)) - quantity


func credit_sale(fid: String, amount: float) -> void:
	if fleets.has(fid):
		fleets[fid].money = float(fleets[fid].money) + amount


func return_unsold(fid: String, goods: String, quantity: int) -> void:
	if fleets.has(fid):
		var stock: Dictionary = fleets[fid].stock
		stock[goods] = int(stock.get(goods, 0)) + quantity


func _process(delta: float) -> void:
	if not is_instance_valid(_belt) or not is_instance_valid(_station):
		return
	_market_tick += delta
	if _market_tick < 1.0:
		return
	_market_tick = 0.0
	for fid in fleets:
		publish_order(fid)
	_update_mother_labels()


func _update_mother_labels() -> void:
	for fid in _labels:
		var total := 0
		for amount in fleets[fid].mother_stock.values():
			total += int(amount)
		_labels[fid].text = "%s · 采矿母舰\n已接收矿物 %d" % [fleet_name(fid), total]


func get_state() -> Dictionary:
	for miner in miners:
		fleets[miner.fleet_id].ships[miner.ship_index] = miner.get_state()
	return fleets.duplicate(true)


func apply_state(data: Dictionary) -> void:
	# Missing factions retain defaults, so existing saves gain the new fleet population.
	for fid in fleets:
		if not data.has(fid) or not data[fid] is Dictionary:
			continue
		var saved: Dictionary = data[fid]
		fleets[fid].money = maxf(0.0, float(saved.get("money", GameData.NEUTRAL_MINING["starting_money"])))
		fleets[fid].stock = saved.get("stock", {}).duplicate()
		fleets[fid].mother_stock = saved.get("mother_stock", {}).duplicate()
		var ships: Array = saved.get("ships", [])
		if not ships.is_empty():
			fleets[fid].ships = ships.slice(0, 3).duplicate(true)
	if is_instance_valid(_belt) and is_instance_valid(_station):
		_spawn_visuals()
