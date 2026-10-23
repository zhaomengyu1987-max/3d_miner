extends "res://scripts/economy/MiningCorvetteUnit.gd"
## A neutral miner shares extraction/navigation with player miners, but owns its cargo and fuel.
enum SupplyState { WORKING, TO_REFUEL, WAITING }

var fleet_manager: Node3D
var fleet_id := ""
var ship_index := 0
var fuel_left := 0.0
var supply_state := SupplyState.TO_REFUEL
var refuel_position := Vector3.ZERO
var faction_color := Color.WHITE
var _supply_retry := 0.0
var _status_label: Label3D


func _ready() -> void:
	super._ready()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = faction_color
	mat.metallic = 0.25
	for mesh in _visual.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = mat
	_status_label = Label3D.new()
	_status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status_label.pixel_size = 0.28
	_status_label.font_size = 24
	_status_label.modulate = faction_color
	_status_label.position.y = CORVETTE_SIZE * 0.65
	add_child(_status_label)
	_update_status()


func _process(delta: float) -> void:
	configure_motion()
	if supply_state != SupplyState.WORKING:
		if motion.travel(self, refuel_position, delta):
			supply_state = SupplyState.WAITING
			_supply_retry -= delta
			if _supply_retry <= 0.0:
				_supply_retry = 3.0
				var bought: float = fleet_manager.refuel_ship(fleet_id, fuel_left)
				fuel_left += bought
				if bought > 0.0:
					supply_state = SupplyState.WORKING
					if _cargo_total() > 0.0:
						_state = State.TO_STATION
					else:
						_state = State.IDLE
		_update_status()
		return
	if _state != State.IDLE:
		fuel_left = maxf(0.0, fuel_left - delta * float(GameData.NEUTRAL_MINING["fuel_per_second"]))
	if fuel_left <= 0.0:
		_forget_target()
		_stop_laser()
		supply_state = SupplyState.TO_REFUEL
		_update_status()
		return
	super._process(delta)
	_update_status()


func _unload() -> void:
	var quantity := int(_cargo_total())
	fleet_manager.deliver_cargo(fleet_id, _cargo)
	delivered_total += quantity
	_cargo.clear()
	_try_immediate()


func _update_status() -> void:
	if _status_label == null:
		return
	var status := "采矿中"
	if supply_state == SupplyState.TO_REFUEL:
		status = "返回空间站补给"
	elif supply_state == SupplyState.WAITING:
		status = "等待燃料 / 补给资金"
	elif _state == State.TO_STATION:
		status = "返航卸矿"
	elif _state == State.IDLE or _state == State.RETURN:
		status = "寻找矿体"
	_status_label.text = "%s · %d号\n%s" % [fleet_manager.fleet_name(fleet_id), ship_index + 1, status]


func get_state() -> Dictionary:
	return {"cargo": _cargo.duplicate(), "fuel": fuel_left}


func restore_state(data: Dictionary) -> void:
	_cargo = data.get("cargo", {}).duplicate()
	fuel_left = maxf(0.0, float(data.get("fuel", 0.0)))
	if fuel_left > 0.0:
		supply_state = SupplyState.WORKING
		_state = State.TO_STATION if _cargo_total() > 0.0 else State.IDLE
