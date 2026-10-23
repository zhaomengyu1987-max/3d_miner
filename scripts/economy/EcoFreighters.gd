extends Node
## EcoFreighters —— 来访货舰调度：来船计划 / 泊位 / 停留时长 / 走私召唤
## （Economy 门面拆分子模块, 2026-10-14）。
## 世界系统（WorldState）经门面调用 dock_special_freighter / _depart / _roll_visit_schedule；
## 3D 表现（StationModules）直接遍历门面的 berths 转发属性。

var eco: Node  # Economy 门面

var berths: Array = []           # 当前停靠的 Freighter
var _visit_schedule: Array = []  # [{t:float, def:String}] 当日来船计划
var _warned_fuel_today := false


## 货舰停留上限（debug_instant 加速模式压缩 50×）。
## 【单一来源】显示与超时判定必须用同一个值，否则加速模式下倒计时会骗人。
func dwell_total() -> float:
	return float(GameData.ECON["freighter_dwell_s"]) / (50.0 if eco.debug_instant else 1.0)


## 货舰剩余停留秒数（订单簿"剩余"列 / 机库倒计时用）
func dwell_left(f: Freighter) -> float:
	if f == null or not is_instance_valid(f):
		return 0.0
	return maxf(0.0, dwell_total() - f.dock_age)


func roll_visit_schedule() -> void:
	_visit_schedule.clear()
	var hangar_lv: int = eco.module_level("hangar")
	if hangar_lv <= 0:
		return
	var free_berths := berths_available()
	if free_berths <= 0:
		return
	var mult := WorldState.freighter_frequency_mult()
	var visits := free_berths * GameData.ECON["visits_per_berth"] * mult
	var n: int = int(floor(visits)) + (1 if eco.rng.randf() < visits - floor(visits) else 0)
	var table: Dictionary = GameData.SPAWN_TABLE[clampi(hangar_lv, 1, 3)]
	for i in n:
		_visit_schedule.append({
			"t": eco.rng.randf_range(2.0, eco.day_length() * 0.95),
			"def": _weighted_def(table),
		})
	_visit_schedule.sort_custom(func(a, b): return a["t"] < b["t"])


func _weighted_def(table: Dictionary) -> String:
	var total := 0.0
	for k in table:
		total += table[k]
	var r: float = eco.rng.randf() * total
	for k in table:
		r -= table[k]
		if r <= 0.0:
			return k
	return table.keys()[0]


func try_arrive(def_id: String, smuggler: bool) -> bool:
	if berths_available() <= 0:
		return false
	var cost: float = GameData.FUEL["visit_cost"] if not smuggler else 0.0
	if eco.fuel < cost:
		if not _warned_fuel_today and not smuggler:
			_warned_fuel_today = true
			eco.post_event("本地燃料不足，货舰绕行——物流停摆中（冰矿=燃料）", "warn")
		return false
	if cost > 0.0:
		eco.fuel -= cost
		eco.fuel_changed.emit()
	var f := Freighter.make(def_id, smuggler, eco.rng, eco.price_mod, eco.demand_mod())
	berths.append(f)
	_resupply_warship(f)
	eco.freighters_changed.emit()
	eco.post_event("%s 到港，停留 %d 秒（剩余泊位 %d）——货舰自动与市场挂单成交" % [
		f.name, int(GameData.ECON["freighter_dwell_s"]), berths_available()],
		"good" if not smuggler else "rare")
	return true


func depart(f: Freighter, reason: String) -> void:
	if not berths.has(f):
		return
	berths.erase(f)
	eco.freighters_changed.emit()
	eco.post_event("%s 离站（%s）" % [f.name, reason], "info")


## 世界系统等外部调用方对接一艘"特殊货舰"（如采购代理）：占用正常泊位；
## 泊位已满时返回 false，由调用方自行在下一天重试（不强行挤占）。
func dock_special_freighter(f: Freighter) -> bool:
	if berths_available() <= 0:
		return false
	berths.append(f)
	_resupply_warship(f)
	eco.freighters_changed.emit()
	return true


## Fuel/ammunition are consumed onboard; these purchases do not occupy transport cargo.
## Shortages are retried while docked. Only the remaining requirement can be purchased.
func _resupply_warship(f: Freighter) -> void:
	var profile: Dictionary = GameData.VISITOR_SUPPLIES.get(f.hull_id, {})
	if profile.is_empty():
		return
	if f.supplies_requested.is_empty():
		f.supplies_requested = profile.duplicate()
	var purchased := false
	var incomplete := false
	for gid in f.supplies_requested:
		var need := maxi(0, int(f.supplies_requested[gid]) - int(f.supplies_received.get(gid, 0)))
		if need <= 0:
			continue
		var price: float = eco.expected_freighter_price(gid, false) * eco.price_factor(gid)
		if f.is_smuggler:
			price *= float(GameData.FUEL["smuggler_price"])
		price = maxf(0.01, price)
		var quantity := mini(need, mini(eco.stock(gid), int(f.funds / price)))
		if quantity > 0 and eco.pay({gid: quantity}):
			var total := float(quantity) * price
			f.funds -= total
			f.supplies_income += total
			f.supplies_received[gid] = int(f.supplies_received.get(gid, 0)) + quantity
			eco.add_money(total)
			if f.faction_id != "":
				eco.diplomacy.record_trade(f.faction_id, total)
			eco.market._log_trade(gid, price, quantity)
			if GameData.is_military(gid):
				eco.military_goods_sold.emit(gid, quantity, price)
			purchased = true
		incomplete = incomplete or int(f.supplies_received.get(gid, 0)) < int(f.supplies_requested[gid])
	if purchased:
		eco.post_event("%s 战舰补给：燃料 %d/%d · 电浆弹药 %d/%d · 累计收入 %s" % [
			f.name, int(f.supplies_received.get("fuel", 0)), int(f.supplies_requested.get("fuel", 0)),
			int(f.supplies_received.get("plasmaAmmo", 0)), int(f.supplies_requested.get("plasmaAmmo", 0)),
			EconTheme.money(f.supplies_income)], "good")
	if incomplete and not f.shortage_reported:
		f.shortage_reported = true
		eco.post_event("%s 补给不足：燃料、弹药或采购资金不足，将在停靠期间继续补给" % f.name, "warn")
	if purchased:
		eco.market_changed.emit()
		eco.freighters_changed.emit()


func summon_smuggler() -> String:
	if not eco.modules["hangar"].get("smuggler_ok", false):
		return "需在物流机库开启走私停靠"
	if berths_available() <= 0:
		return "泊位已满"
	if eco.fuel < GameData.FUEL["smuggler_fuel"]:
		return "燃料不足（需 %d）" % int(GameData.FUEL["smuggler_fuel"])
	if eco.money < GameData.FUEL["smuggler_fee"]:
		return "资金不足（需 %s）" % EconTheme.money(GameData.FUEL["smuggler_fee"])
	eco.fuel -= GameData.FUEL["smuggler_fuel"]
	eco.money -= GameData.FUEL["smuggler_fee"]
	eco.fuel_changed.emit()
	eco.money_changed.emit()
	try_arrive("small" if eco.module_level("hangar") < 3 else "standard", true)
	return ""


## 停留倒计时推进（原 Economy._process 的货舰段）。到点离站。
func tick_dwell(delta: float) -> void:
	var dwell := dwell_total()
	for f in berths.duplicate():
		f.dock_age += delta
		f.supply_retry -= delta
		if f.supply_retry <= 0.0:
			f.supply_retry = 1.0
			_resupply_warship(f)
		# dwell_override：世界系统的采购代理(is_dealer)等特殊货舰用它覆盖固定停留时长
		var eff_dwell: float = f.dwell_override if f.dwell_override > 0.0 else dwell
		if f.dock_age >= eff_dwell:
			depart(f, "停留结束")


func berths_available() -> int:
	return _berths_total() - berths.size()


func _berths_total() -> int:
	var lv: int = eco.module_level("hangar")
	if lv <= 0:
		return 0
	return int(GameData.MODULES["hangar"]["levels"][lv - 1]["berths"])
