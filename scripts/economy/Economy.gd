extends Node

## Economy autoload —— 门面（facade）。
## 库存/货币/燃料/游戏时钟/空间站模块/许可证/逆向与原图研究/来访货舰/存档。
## 全部数值在 GameData.gd；UI 在 scripts/ui/；3D 模块实体在 StationModules.gd。
##
## 【2026-10-14 拆分重构】实现分入五个子模块（挂为本节点子节点，树管理生命周期）：
##   EcoWallet      钱包/燃料/库存
##   EcoMarket      本地市场（限价挂单+撮合）+ 价格查询 + 成交历史
##   EcoProduction  制造产线 + 研究站 + 许可证/逆向
##   EcoFreighters  来访货舰调度 + 泊位 + 停留
##   EcoModules     空间站模块状态与建造
## 【门面承诺】对外 API 一字不改：函数名/字段名/信号名/save_path/debug_instant/debug_reset
## 与拆分前完全一致——UI/WorldState/MissionOps/测试代码零改动。字段是转发属性（读写下标
## 透传、整体赋值走 setter），函数是一行转发。子模块互相之间只经门面单向访问（无引用环）。
## _process 编排与存档键结构保持原样：时序敏感（日切换→到期→来船→战争→存盘），勿改动顺序。

signal inventory_changed
signal money_changed
signal fuel_changed
signal modules_changed
signal licenses_changed
signal research_changed
signal jobs_changed
signal market_changed            # 本地市场挂单/成交变化
signal freighters_changed
signal event_posted(text: String, kind: String)  # kind: info / good / rare / warn
signal day_changed(day: int)
signal military_goods_sold(goods_id: String, qty: int, price: float)  # 世界系统钩子：军需品实际成交广播（仅玩家卖出方向）

var save_path := "user://economy_save.json"  # 测试可重定向，避免污染真存档
const StationModulesScript := preload("res://scripts/economy/StationModules.gd")
const UiRootScript := preload("res://scripts/ui/EconUiRoot.gd")
const EcoWalletScript := preload("res://scripts/economy/EcoWallet.gd")
const EcoMarketScript := preload("res://scripts/economy/EcoMarket.gd")
const EcoProductionScript := preload("res://scripts/economy/EcoProduction.gd")
const EcoFreightersScript := preload("res://scripts/economy/EcoFreighters.gd")
const EcoModulesScript := preload("res://scripts/economy/EcoModules.gd")

## 子模块（对外只暴露本门面；兄弟模块互相访问一律经 eco.* 转发，不互相持引用）
var wallet: Node
var market: Node
var production: Node
var freight: Node
var mods: Node

# ---- 时钟（留在门面） ----
var day := 1
var day_time := 0.0
var rng := RandomNumberGenerator.new()

## 测试钩子：true 时所有耗时缩到 1/100（冒烟测试用）
var debug_instant := false

var _day_length := 0.0
var _trade_accum := 0.0           # 自动成交节拍（每秒一拍）
var _world: Node3D
var _ui: CanvasLayer


# ================= 转发属性（字段搬家后对外名不变） =================
# 标量：读写双向转发（测试布景 / MissionOps 回滚快照会整体赋值）。
# 容器：getter 返回子模块容器引用——元素读写天然透传；整体赋值走 setter 跟随转移。

var money: float:
	get: return wallet.money
	set(v): wallet.money = v
var fuel: float:
	get: return wallet.fuel
	set(v): wallet.fuel = v
var inv: Dictionary:
	get: return wallet.inv
	set(v): wallet.inv = v
var licenses: Dictionary:
	get: return production.licenses
	set(v): production.licenses = v
var reverse: Dictionary:
	get: return production.reverse
	set(v): production.reverse = v
var blueprints: Dictionary:
	get: return production.blueprints
	set(v): production.blueprints = v
var me_levels: Dictionary:
	get: return production.me_levels
	set(v): production.me_levels = v
var te_levels: Dictionary:
	get: return production.te_levels
	set(v): production.te_levels = v
var prod_jobs: Array:
	get: return production.prod_jobs
	set(v): production.prod_jobs = v
var order_queue: Array:
	get: return production.order_queue
	set(v): production.order_queue = v
var research_jobs: Array:
	get: return production.research_jobs
	set(v): production.research_jobs = v
var sell_orders: Array:
	get: return market.sell_orders
	set(v): market.sell_orders = v
var buy_orders: Array:
	get: return market.buy_orders
	set(v): market.buy_orders = v
var trade_log: Array:
	get: return market.trade_log
	set(v): market.trade_log = v
var price_mod: Dictionary:
	get: return market.price_mod
	set(v): market.price_mod = v
var modules: Dictionary:
	get: return mods.modules
	set(v): mods.modules = v
var module_jobs: Dictionary:
	get: return mods.module_jobs
	set(v): mods.module_jobs = v
var berths: Array:
	get: return freight.berths
	set(v): freight.berths = v
var _visit_schedule: Array:
	get: return freight._visit_schedule
	set(v): freight._visit_schedule = v


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	rng.randomize()
	_day_length = GameData.ECON["day_length"]
	_spawn_submodules()
	_init_state()
	load_game()
	_roll_visit_schedule()
	# 世界实体与 UI 延后一帧挂到场景树（autoload 先于主场景就绪）
	call_deferred("_spawn_world_and_ui")


func _spawn_submodules() -> void:
	wallet = EcoWalletScript.new()
	wallet.name = "Wallet"
	wallet.eco = self
	add_child(wallet)
	market = EcoMarketScript.new()
	market.name = "Market"
	market.eco = self
	add_child(market)
	production = EcoProductionScript.new()
	production.name = "Production"
	production.eco = self
	add_child(production)
	freight = EcoFreightersScript.new()
	freight.name = "Freighters"
	freight.eco = self
	add_child(freight)
	mods = EcoModulesScript.new()
	mods.name = "Mods"
	mods.eco = self
	add_child(mods)


func _spawn_world_and_ui() -> void:
	var scene := get_tree().current_scene
	if scene != null:
		_world = StationModulesScript.new()
		_world.name = "StationModules"
		scene.add_child(_world)
	_ui = UiRootScript.new()
	_ui.name = "EconUiRoot"
	get_tree().root.add_child(_ui)
	if not modules["hangar"]["built"]:
		post_event("提示：点击空间站打开模块菜单，先建物流机库（燃料冰矿要顺手囤）", "info")


## 测试钩子：恢复到全新开局状态（只改内存状态, 不动存档文件）
func debug_reset() -> void:
	_init_state()
	inv.clear()
	money = float(GameData.ECON["start_money"])
	fuel = 0.0
	day = 1
	day_time = 0.0
	licenses.clear()
	reverse.clear()
	blueprints.clear()
	me_levels.clear()
	te_levels.clear()
	prod_jobs.clear()
	research_jobs.clear()
	module_jobs.clear()
	order_queue.clear()
	sell_orders.clear()
	buy_orders.clear()
	trade_log.clear()
	price_mod.clear()
	berths.clear()
	_visit_schedule.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()


# ================= 时钟与来船（编排留在门面，顺序勿动） =================

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	day_time += delta
	# 到点来船
	while not _visit_schedule.is_empty() and _visit_schedule[0]["t"] <= day_time:
		var v: Dictionary = _visit_schedule.pop_front()
		_try_arrive(v["def"], false)
	# 日切换
	if day_time >= _day_length:
		day_time -= _day_length
		var war_before := war_active()
		day += 1
		freight._warned_fuel_today = false
		expire_orders()   # 挂单到期结算（卖单退货 / 买单撤销）
		_roll_visit_schedule()
		if war_active() != war_before:
			if war_active():
				post_event("战争爆发：军用需求 ×%.1f、通用 ×%.1f —— 货舰愿意出更高价" % [
					float(GameData.ECON["war_demand_military"]),
					float(GameData.ECON["war_demand_general"])], "warn")
			else:
				post_event("战事平息：需求回落至和平基线", "info")
		day_changed.emit(day)
		save_game()
	# 货舰固定停留（2026-09-30 拍板：每次 1 分钟；提前条件=舱满/资金尽/货单完成）
	freight.tick_dwell(delta)
	_advance_jobs(delta)
	# 自动成交节拍：货舰与本地市场挂单每秒撮合一次
	_trade_accum += delta
	if _trade_accum >= 1.0:
		_auto_trade(_trade_accum)
		_trade_accum = 0.0


## 一个游戏日对应的真实秒数（世界系统按"天"换算特殊货舰停留秒数要用这个，不直接碰 _day_length）
func day_length() -> float:
	return _day_length


## 战时状态：确定性周期（每 peace+war 天一循环，后段为战时）。无需额外存档字段。
func war_active() -> bool:
	var peace := int(GameData.ECON["war_cycle_peace_days"])
	var war := int(GameData.ECON["war_cycle_war_days"])
	if war <= 0:
		return false
	return (day - 1) % maxi(peace + war, 1) >= peace


## 某货物当前的需求倍率（和平 1.0；战时军用 1.6 / 其余 1.15）
func demand_mult(goods_id: String) -> float:
	if not war_active():
		return 1.0
	var gid := goods_id.trim_prefix("lic:")
	return float(GameData.ECON["war_demand_military"]) if GameData.is_military(gid) \
		else float(GameData.ECON["war_demand_general"])


## 传给 Freighter.make 的战时需求表（和平期返回空表 = 全部 1.0）
func demand_mod() -> Dictionary:
	if not war_active():
		return {}
	return {
		"general": float(GameData.ECON["war_demand_general"]),
		"military": float(GameData.ECON["war_demand_military"]),
	}


# ================= 转发：本地市场（EcoMarket） =================

## 某货物的当前价格因子（全局 "*" × 该货物条目，夹 0.05 下限）
func price_factor(goods_id: String) -> float:
	return market.price_factor(goods_id)


## 事件接口: 设定价格因子（相对当前基准价的倍数）
func set_price_mod(goods_id: String, mult: float) -> void:
	market.set_price_mod(goods_id, mult)


## 事件接口: 按增量扰动价格因子（事件用百分比描述冲击时更顺手）
func nudge_price_mod(goods_id: String, delta: float) -> void:
	market.nudge_price_mod(goods_id, delta)


func unit_price_of(goods_id: String) -> float:
	return market.unit_price_of(goods_id)


func expected_freighter_price(goods_id: String, is_buy: bool) -> float:
	return market.expected_freighter_price(goods_id, is_buy)


func fillable_range(goods_id: String, is_buy: bool) -> Vector2:
	return market.fillable_range(goods_id, is_buy)


func suggest_price(goods_id: String, is_buy: bool) -> float:
	return market.suggest_price(goods_id, is_buy)


func freighter_sells(goods_id: String) -> bool:
	return market.freighter_sells(goods_id)


func order_remaining_days(o: Dictionary) -> float:
	return market.order_remaining_days(o)


func expire_orders() -> int:
	return market.expire_orders()


func post_sell(goods_id: String, qty: int, price := -1.0) -> String:
	return market.post_sell(goods_id, qty, price)


func post_buy(goods_id: String, qty: int, price := -1.0) -> String:
	return market.post_buy(goods_id, qty, price)


func cancel_sell_by_uid(uid: int) -> bool:
	return market.cancel_sell_by_uid(uid)


func cancel_buy_by_uid(uid: int) -> bool:
	return market.cancel_buy_by_uid(uid)


func cancel_sell(index: int) -> void:
	market.cancel_sell(index)


func cancel_buy(index: int) -> void:
	market.cancel_buy(index)


func _auto_trade(dt: float) -> void:
	market._auto_trade(dt)


func _freighter_buys(f: Freighter, budget: float) -> int:
	return market._freighter_buys(f, budget)


func _freighter_sells(f: Freighter, budget: float) -> int:
	return market._freighter_sells(f, budget)


# ================= 转发：钱包/库存（EcoWallet） =================

func deliver_ore(asset: String, amount: int) -> void:
	wallet.deliver_ore(asset, amount)


func stock(id: String) -> int:
	return wallet.stock(id)


func can_pay(cost: Dictionary) -> bool:
	return wallet.can_pay(cost)


func pay(cost: Dictionary) -> bool:
	return wallet.pay(cost)


func try_spend(v: float) -> bool:
	return wallet.try_spend(v)


func add_money(v: float) -> void:
	wallet.add_money(v)


func _refund(cost: Dictionary) -> void:
	wallet._refund(cost)


# ================= 转发：制造/研究/许可证（EcoProduction） =================

func buy_license(equip: String, count := 1) -> String:
	return production.buy_license(equip, count)


func factory_count() -> int:
	return production.factory_count()


func max_lines() -> int:
	return production.max_lines()


func effective_materials(equip: String) -> Dictionary:
	return production.effective_materials(equip)


func effective_time(equip: String) -> float:
	return production.effective_time(equip)


func production_block_reason(equip: String, batches: int) -> String:
	return production.production_block_reason(equip, batches)


func start_production(equip: String, batches: int) -> String:
	return production.start_production(equip, batches)


func _pump_orders() -> void:
	production._pump_orders()


func cancel_order(index: int) -> void:
	production.cancel_order(index)


func research_slots() -> int:
	return production.research_slots()


func research_speed() -> float:
	return production.research_speed()


func research_block_reason(kind: String, equip: String) -> String:
	return production.research_block_reason(kind, equip)


func start_research(kind: String, equip: String) -> String:
	return production.start_research(kind, equip)


# ================= 转发：来访货舰（EcoFreighters） =================

func dwell_total() -> float:
	return freight.dwell_total()


func dwell_left(f: Freighter) -> float:
	return freight.dwell_left(f)


func _roll_visit_schedule() -> void:
	freight.roll_visit_schedule()


func _try_arrive(def_id: String, smuggler: bool) -> bool:
	return freight.try_arrive(def_id, smuggler)


func _depart(f: Freighter, reason: String) -> void:
	freight.depart(f, reason)


func dock_special_freighter(f: Freighter) -> bool:
	return freight.dock_special_freighter(f)


func summon_smuggler() -> String:
	return freight.summon_smuggler()


func berths_available() -> int:
	return freight.berths_available()


func _berths_total() -> int:
	return freight._berths_total()


# ================= 转发：空间站模块（EcoModules） =================

func module_level(id: String) -> int:
	return mods.module_level(id)


## 雇佣兵巢穴等级(蓝图 §5.9): MissionOps 行动舰队容量的唯一来源
func hive_level() -> int:
	return mods.module_level("hive")


func module_count(id: String) -> int:
	return mods.module_count(id)


func module_state(id: String) -> Dictionary:
	return mods.module_state(id)


func module_next_cost(id: String) -> Dictionary:
	return mods.module_next_cost(id)


func module_build_block(id: String) -> String:
	return mods.module_build_block(id)


func build_module(id: String) -> String:
	return mods.build_module(id)


func set_smuggler_ok(on: bool) -> void:
	mods.set_smuggler_ok(on)


# ================= 事件与存档（聚合留在门面，JSON 键结构不变） =================

func post_event(text: String, kind := "info") -> void:
	event_posted.emit(text, kind)


func _init_state() -> void:
	mods.init_state()
	wallet.inv.clear()


## 制造/研究/模块三类作业统一推进（原 _advance_jobs：任一完工只发一次 jobs_changed）
func _advance_jobs(delta: float) -> void:
	var d1: bool = production.advance(delta)
	var d2: bool = mods.advance(delta)
	if d1 or d2:
		jobs_changed.emit()


func save_game() -> bool:
	var data := {
		"v": 1,
		"money": money, "day": day, "fuel": fuel, "inv": inv,
		"modules": modules,
		"licenses": licenses, "reverse": reverse, "blueprints": blueprints,
		"me": me_levels, "te": te_levels,
		"prod_jobs": prod_jobs, "order_queue": order_queue, "research_jobs": research_jobs,
		"sell_orders": sell_orders, "buy_orders": buy_orders, "trade_log": trade_log,
		"price_mod": price_mod,
		"module_jobs": module_jobs,
	}
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_warning("Economy: 存档写入失败(%s)" % save_path)
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	return true


func load_game() -> void:
	if not FileAccess.file_exists(save_path):
		money = GameData.ECON["start_money"]
		return
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		money = GameData.ECON["start_money"]
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		money = GameData.ECON["start_money"]
		return
	money = float(parsed.get("money", GameData.ECON["start_money"]))
	day = int(parsed.get("day", 1))
	fuel = float(parsed.get("fuel", 0.0))
	inv = parsed.get("inv", {})
	var m: Dictionary = parsed.get("modules", {})
	for id in modules:
		if m.has(id):
			for k in modules[id]:
				if m[id].has(k):
					modules[id][k] = m[id][k]
	licenses = parsed.get("licenses", {})
	reverse = parsed.get("reverse", {})
	blueprints = parsed.get("blueprints", {})
	me_levels = parsed.get("me", {})
	te_levels = parsed.get("te", {})
	prod_jobs = parsed.get("prod_jobs", [])
	order_queue = parsed.get("order_queue", [])
	research_jobs = parsed.get("research_jobs", [])
	sell_orders = parsed.get("sell_orders", [])
	buy_orders = parsed.get("buy_orders", [])
	trade_log = parsed.get("trade_log", [])
	for o in sell_orders + buy_orders:
		if not o.has("uid"):
			o["uid"] = market._order_uid
			market._order_uid += 1
	price_mod = parsed.get("price_mod", {})
	module_jobs = parsed.get("module_jobs", {})
	# 货舰不持久化：读档后泊位清空，来船计划重排
	berths.clear()
	var migrated := _migrate_orders()   # 旧挂单补限价/创建日（必须在 trade_log 之后, 建议价要用它）
	if migrated > 0:
		print("Economy: 旧挂单迁移 %d 条（补限价 + 创建日 + orig）" % migrated)
		call_deferred("post_event", "旧挂单已迁移：%d 条补上限价与到期日（3 天）" % migrated, "info")
	expire_orders()   # 存档里可能躺着已过期的挂单


## 旧存档兼容（2026-10-02 挂单加限价后）:
## 早期挂单结构是 {goods, qty}, 没有 price/day/orig。不迁移的话它们会显示"@—"、
## 且永远不过期（僵尸单）。规则: price 取当前建议价, day 取当天（给足一个完整期限）,
## orig 缺失补 qty。只补缺, 不动已有值。
func _migrate_orders() -> int:
	var n := 0
	for o in sell_orders:
		if float(o.get("price", 0.0)) <= 0.0:
			o["price"] = suggest_price(String(o["goods"]), false)
			n += 1
		if not o.has("day"):
			o["day"] = day
		if not o.has("orig"):
			o["orig"] = int(o["qty"])
	for b in buy_orders:
		if float(b.get("price", 0.0)) <= 0.0:
			b["price"] = suggest_price(String(b["goods"]), true)
			n += 1
		if not b.has("day"):
			b["day"] = day
		if not b.has("orig"):
			b["orig"] = int(b["qty"])
	return n
