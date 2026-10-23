class_name Freighter
extends RefCounted

## 来访船只（数据实体）。运输档次 def_id 与实际船型 hull_id 独立。
## 由 StationModules 在到港/离站时生成/飞离（泊位沿机库向外排布，§5.3）。
## 交易规则（manufacturing.md §5.3）：船舱物理化——玩家卖出占用舱位，
## 舱满或资金用尽即离站；玩家可买许可证/组件，卖矿石/组件/产品/舰船。

var def_id := ""
var hull_id := "industrial"
var faction_id := ""
var visit_role := ""
var is_smuggler := false
var name := ""
var cap := 0.0            # 舱位总量
var cargo_units := 0.0    # 已占舱位
var funds := 0.0          # 本次收购额度（用完即走）
var dock_age := 0.0       # 已停靠秒数（超时离站保险丝）
var departing := false
var is_dealer := false     # 世界系统"军需采购代理"标记：停留由 WorldState 的阶段结束日决定，
                            # 不吃 after_trade() 的"货单吃满就走"规则（见 Economy._auto_trade）
var dwell_override := -1.0 # >0 时覆盖 Economy.dwell_total()（秒）；is_dealer 等特殊货舰专用
var supplies_requested: Dictionary = {}
var supplies_received: Dictionary = {}
var supplies_income := 0.0
var supply_retry := 0.0
var shortage_reported := false

## 收购清单：[{goods, price, qty_left}]（price = ₡/单位）
var buy_offers: Array = []
## 出售清单：[{goods, price, qty, uses}]（许可证条目带 uses，qty<=0 表示不限）
var sell_offers: Array = []
## 需求倍率表 {"general": x, "military": y}（战时时 >1；空表 = 全部 1.0）。由 Economy 传入，
## 保证货舰可独立构造与测试。见 Economy.demand_mod()。
var demand_mod: Dictionary = {}


## 该货物的当前需求倍率（战时军用吃 military，其余吃 general）
func demand_mult(goods_id: String) -> float:
	if demand_mod.is_empty():
		return 1.0
	return float(demand_mod.get("military" if GameData.is_military(goods_id) else "general", 1.0))


## p_price_mod: 市场价格因子表（事件接口, Economy.price_mod）——键=货物 id 或 "*"（全局水平）。
## 由 Economy 传入而不是自己去取单例, 保证货舰可独立构造与测试。
static func make(p_def_id: String, p_smuggler: bool, rng: RandomNumberGenerator,
		p_price_mod: Dictionary = {}, p_demand_mod: Dictionary = {}, p_hull_id := "") -> Freighter:
	var f := Freighter.new()
	f.def_id = p_def_id
	f.is_smuggler = p_smuggler
	f.demand_mod = p_demand_mod
	var def: Dictionary = GameData.FREIGHTERS[p_def_id]
	f.cap = def["cap"]
	f.funds = def["funds"] * rng.randf_range(0.8, 1.2) * (1.2 if p_smuggler else 1.0)
	f._gen_offers(rng, p_price_mod)
	f.hull_id = p_hull_id if GameData.VISITOR_HULL_NAMES.has(p_hull_id) else _roll_hull(p_def_id, rng)
	if f.is_warship():
		f._add_warship_orders(rng, p_price_mod)
	var hull_name: String = def["name"] if f.hull_id == "industrial" else GameData.VISITOR_HULL_NAMES[f.hull_id]
	f.name = ("走私·" if p_smuggler else "") + hull_name
	return f


static func _roll_hull(tier: String, rng: RandomNumberGenerator) -> String:
	var weights: Dictionary = GameData.VISITOR_HULL_WEIGHTS.get(tier, {"industrial": 1.0})
	var total := 0.0
	for weight in weights.values():
		total += float(weight)
	var roll := rng.randf() * total
	for id in weights:
		roll -= float(weights[id])
		if roll <= 0.0:
			return String(id)
	return "industrial"


## 价格因子解析: 全局 "*" × 该货物条目, 缺省 1.0; 夹到 0.05 防负价/零价。
## 事件系统只需改 Economy.price_mod, 之后到港的货舰报价自然跟着变。
static func resolve_price_mod(mods: Dictionary, goods_id: String) -> float:
	var m := 1.0
	if mods.has("*"):
		m *= float(mods["*"])
	if mods.has(goods_id):
		m *= float(mods[goods_id])
	return maxf(m, 0.05)


## 舱位剩余
func space_left() -> float:
	return maxf(cap - cargo_units, 0.0)


func is_warship() -> bool:
	return GameData.WARSHIP_ORDER_BATCHES.has(hull_id)


func prioritized_buy_offers() -> Array:
	if not is_warship() and visit_role != "convoy":
		return buy_offers
	var priority := []
	var other := []
	for offer in buy_offers:
		if GameData.WARSHIP_PRIORITY.has(String(offer["goods"])) or (visit_role == "convoy" and GameData.recipe_faction(String(offer["goods"])) == faction_id):
			priority.append(offer)
		else:
			other.append(offer)
	priority.append_array(other)
	return priority


func _add_warship_orders(rng: RandomNumberGenerator, p_price_mod: Dictionary) -> void:
	# Replace any random entries, so each military good has exactly one stable quota.
	buy_offers = buy_offers.filter(func(offer): return not GameData.WARSHIP_PRIORITY.has(offer["goods"]))
	var bonus: float = GameData.FUEL["smuggler_price"] if is_smuggler else 1.0
	for id in GameData.WARSHIP_PRIORITY:
		var qty := maxf(1.0, roundf(float(GameData.PRODUCTS[id]["batch"]) * float(GameData.WARSHIP_ORDER_BATCHES[hull_id])))
		buy_offers.append(_offer(id, qty, rng, bonus, p_price_mod))
	buy_offers = prioritized_buy_offers()


func buy_offer_for(goods_id: String) -> Dictionary:
	for o in buy_offers:
		if o["goods"] == goods_id:
			return o
	return {}


func sell_offer_for(goods_id: String) -> Dictionary:
	for o in sell_offers:
		if o["goods"] == goods_id:
			return o
	return {}


## 成交后由 Economy 调用；返回 true 表示该离站了（舱满/资金尽/货单全部完成）
func after_trade() -> bool:
	if cargo_units >= cap - 0.01:
		return true
	# 资金买不动任何一单了
	for o in buy_offers:
		if float(o["qty_left"]) > 0.0 and float(o["price"]) <= funds:
			return false
	# 收购清单全部吃满
	var buys_left := false
	for o in buy_offers:
		if float(o["qty_left"]) > 0.0:
			buys_left = true
			break
	if not buys_left:
		return true
	return false


# ---------- 清单生成 ----------

func _gen_offers(rng: RandomNumberGenerator, p_price_mod: Dictionary) -> void:
	buy_offers.clear()
	sell_offers.clear()
	var bonus := GameData.FUEL["smuggler_price"] if is_smuggler else 1.0

	# ---- 收购清单：矿石 3-5 种 + 燃料 + 组件 1-2 种 + 产品 1-3 种（巨舰可能收船） ----
	# 注意: const 表派生的 keys()/引用数组是只读的, 必须 duplicate 后才能 shuffle
	var ore_pool: Array = []
	for id in GameData.ORES:
		if id != GameData.FUEL_ID and GameData.ORES[id]["path"] != "":
			ore_pool.append(id)
	ore_pool.shuffle()
	var n_ore := rng.randi_range(3, 5)
	for i in mini(n_ore, ore_pool.size()):
		var id: String = ore_pool[i]
		var qty := rng.randf_range(80.0, 300.0) / maxf(GameData.ORES[id]["price"] / 3.0, 1.0)
		buy_offers.append(_offer(id, qty, rng, bonus, p_price_mod))
	# 燃料永远收（§6：公共物流持续买入）
	buy_offers.append(_offer(GameData.FUEL_ID, rng.randf_range(120.0, 380.0), rng, bonus, p_price_mod))
	# 组件
	var comp_pool: Array = GameData.COMPONENTS.keys().duplicate()
	comp_pool.shuffle()
	for i in rng.randi_range(1, 2):
		if i < comp_pool.size():
			buy_offers.append(_offer(comp_pool[i], rng.randf_range(3.0, 12.0), rng, bonus, p_price_mod))
	# 产品
	var prod_pool: Array = GameData.tradable_product_ids()
	prod_pool.shuffle()
	for i in rng.randi_range(1, 3):
		if i < prod_pool.size():
			var pid: String = prod_pool[i]
			var batch: int = GameData.PRODUCTS[pid]["batch"]
			buy_offers.append(_offer(pid, rng.randf_range(0.4, 1.6) * batch, rng, bonus, p_price_mod))
	# 舰船：重型/巨型低概率收（§6 和平期需求低；战争/会战 TODO）
	if def_id in ["heavy", "giant"] and rng.randf() < 0.3:
		var ship_pool: Array = GameData.SHIPS.keys().duplicate()
		var sid: String = ship_pool[rng.randi_range(0, ship_pool.size() - 1)]
		buy_offers.append(_offer(sid, float(rng.randi_range(1, 2)), rng, bonus, p_price_mod))

	# ---- 出售清单：许可证 + 组件（价格同样吃价格因子；折扣/溢价各走各的表） ----
	var lic_pool: Array = (GameData.LICENSE_CATALOG[def_id] as Array).duplicate()
	lic_pool = lic_pool.filter(func(id): return GameData.requires_license(id))
	var n_lic := 0 if lic_pool.is_empty() else rng.randi_range(1, mini(3, lic_pool.size()))
	var lic_discount := GameData.FUEL["smuggler_license"] if is_smuggler else 1.0
	lic_pool.shuffle()
	for i in n_lic:
		var equip: String = lic_pool[i]
		sell_offers.append({
			"goods": "lic:" + equip,
			"price": GameData.license_fee(equip) * lic_discount * rng.randf_range(1.0, 1.1) \
				* resolve_price_mod(p_price_mod, "lic:" + equip),
			"qty": float(rng.randi_range(1, 3)),
			"uses": GameData.license_uses(equip),
		})
	if is_smuggler:
		# 走私船多带几种许可证
		for equip in ["longbow", "ram"]:
			if rng.randf() < 0.4 and sell_offer_for("lic:" + equip).is_empty():
				sell_offers.append({
					"goods": "lic:" + equip,
					"price": GameData.license_fee(equip) * lic_discount * rng.randf_range(1.0, 1.1) \
						* resolve_price_mod(p_price_mod, "lic:" + equip),
					"qty": 1.0,
					"uses": GameData.license_uses(equip),
				})
	var comp_discount := 0.8 if is_smuggler else 1.0
	comp_pool.shuffle()
	for i in rng.randi_range(1, 3):
		if i < comp_pool.size():
			var cid: String = comp_pool[i]
			sell_offers.append({
				"goods": cid,
				"price": GameData.COMPONENTS[cid]["price"] * comp_discount * rng.randf_range(1.1, 1.3) \
					* resolve_price_mod(p_price_mod, cid),
				"qty": float(rng.randi_range(2, 8)),
				"uses": 0,
			})


## 收购报价 = 当前基准价 × 需求锚点 × 战时需求倍率 × 走私溢价 × (1-收购折扣) × 价格因子 × 随机浮动(0.9~1.1)
func _offer(goods_id: String, qty: float, rng: RandomNumberGenerator, bonus: float,
		p_price_mod: Dictionary) -> Dictionary:
	var demand: float = GameData.DEMAND.get(goods_id, GameData.DEMAND["ore"]) * demand_mult(goods_id)
	var disc: float = 1.0 - float(GameData.ECON["freighter_buy_discount"])
	return {
		"goods": goods_id,
		"price": GameData.good_unit_price(goods_id) * demand * bonus * disc \
			* resolve_price_mod(p_price_mod, goods_id) * rng.randf_range(0.9, 1.1),
		"qty_left": qty,
	}
