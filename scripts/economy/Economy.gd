extends Node

## Economy autoload —— 制造系统状态核心（manufacturing.md v0.1）。
## 库存/货币/燃料/游戏时钟/空间站模块/许可证/逆向与原图研究/来访货舰/存档。
## 全部数值在 GameData.gd；UI 在 scripts/ui/；3D 模块实体在 StationModules.gd。

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

var money := 0.0
var day := 1
var inv := {}            # 货物id(矿/组件/产品/舰船) -> 数量
var fuel := 0.0          # 燃料单位（1 燃料冰矿 = 1 燃料）
var modules := {}        # id -> {"built":bool,"level":int,"count":int,"smuggler_ok":bool}
var licenses := {}       # equip -> 剩余次数
var reverse := {}        # equip -> 逆向等级
var blueprints := {}     # equip -> true（已获原图）
var me_levels := {}      # equip -> ME 等级
var te_levels := {}      # equip -> TE 等级
var prod_jobs: Array = []        # 制造作业 {kind,equip,batches,total,left,uses_license}
var order_queue: Array = []      # 制造排队订单 {equip,batches,uses_license,paid}（产线满时排队, 可取消退款）
var research_jobs: Array = []    # 研究作业 {kind,equip,total,left}
var _order_uid := 1               # 挂单稳定唯一 id（修 UI 陈旧下标误撤, 2026-10-01）
var sell_orders: Array = []      # 本地市场挂卖 {goods,qty,orig}（挂单即锁货, 可取消退回）
var buy_orders: Array = []       # 本地市场挂买 {goods,qty,orig}（成交时扣款）
var trade_log: Array = []        # 成交历史 [{g,p,q,d}] 截断 200 条（价格历史图数据源）
## 市场价格因子（事件接口）: {货物id 或 "*": 倍数}, 缺省 1.0。
## 只影响之后到港的货舰报价（Freighter.make 生成清单时读取），已停靠的船不追溯。
## 例: price_mod["*"] = 1.15 → 全局涨价 15%；price_mod["commonA"] = 0.8 → 普矿A 单独压价 20%。
var price_mod: Dictionary = {}


## 某货物的当前价格因子（全局 "*" × 该货物条目，夹 0.05 下限）
func price_factor(goods_id: String) -> float:
	return Freighter.resolve_price_mod(price_mod, goods_id)


## 事件接口: 设定价格因子（相对当前基准价的倍数）
func set_price_mod(goods_id: String, mult: float) -> void:
	price_mod[goods_id] = maxf(mult, 0.05)
	market_changed.emit()


## 事件接口: 按增量扰动价格因子（事件用百分比描述冲击时更顺手）
func nudge_price_mod(goods_id: String, delta: float) -> void:
	set_price_mod(goods_id, price_factor(goods_id) + delta)
var module_jobs := {}    # module_id -> {"total":float,"left":float}
var berths: Array = []   # 当前停靠的 Freighter
var day_time := 0.0
var rng := RandomNumberGenerator.new()

## 测试钩子：true 时所有耗时缩到 1/100（冒烟测试用）
var debug_instant := false

var _day_length := 0.0
var _visit_schedule: Array = []   # [{t:float, def:String}] 当日来船计划
var _warned_fuel_today := false
var _trade_accum := 0.0           # 自动成交节拍（每秒一拍）
var _world: Node3D
var _ui: CanvasLayer


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	rng.randomize()
	_day_length = GameData.ECON["day_length"]
	_init_state()
	load_game()
	_roll_visit_schedule()
	# 世界实体与 UI 延后一帧挂到场景树（autoload 先于主场景就绪）
	call_deferred("_spawn_world_and_ui")



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


# ================= 时钟与来船 =================

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
		_warned_fuel_today = false
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
	var dwell := dwell_total()
	for f in berths.duplicate():
		f.dock_age += delta
		# dwell_override：世界系统的采购代理(is_dealer)等特殊货舰用它覆盖固定停留时长
		var eff_dwell: float = f.dwell_override if f.dwell_override > 0.0 else dwell
		if f.dock_age >= eff_dwell:
			_depart(f, "停留结束")
	_advance_jobs(delta)
	# 自动成交节拍：货舰与本地市场挂单每秒撮合一次
	_trade_accum += delta
	if _trade_accum >= 1.0:
		_auto_trade(_trade_accum)
		_trade_accum = 0.0


## 货舰停留上限（debug_instant 加速模式压缩 50×）。
## 【单一来源】显示与超时判定必须用同一个值，否则加速模式下倒计时会骗人。
func dwell_total() -> float:
	return float(GameData.ECON["freighter_dwell_s"]) / (50.0 if debug_instant else 1.0)


## 一个游戏日对应的真实秒数（世界系统按"天"换算特殊货舰停留秒数要用这个，不直接碰 _day_length）
func day_length() -> float:
	return _day_length


## 货舰剩余停留秒数（订单簿"剩余"列 / 机库倒计时用）
func dwell_left(f: Freighter) -> float:
	if f == null or not is_instance_valid(f):
		return 0.0
	return maxf(0.0, dwell_total() - f.dock_age)


func _roll_visit_schedule() -> void:
	_visit_schedule.clear()
	var hangar_lv := module_level("hangar")
	if hangar_lv <= 0:
		return
	var free_berths := berths_available()
	if free_berths <= 0:
		return
	var mult := WorldState.freighter_frequency_mult()
	var visits := free_berths * GameData.ECON["visits_per_berth"] * mult
	var n := int(floor(visits)) + (1 if rng.randf() < visits - floor(visits) else 0)
	var table: Dictionary = GameData.SPAWN_TABLE[clampi(hangar_lv, 1, 3)]
	for i in n:
		_visit_schedule.append({
			"t": rng.randf_range(2.0, _day_length * 0.95),
			"def": _weighted_def(table),
		})
	_visit_schedule.sort_custom(func(a, b): return a["t"] < b["t"])


func _weighted_def(table: Dictionary) -> String:
	var total := 0.0
	for k in table:
		total += table[k]
	var r := rng.randf() * total
	for k in table:
		r -= table[k]
		if r <= 0.0:
			return k
	return table.keys()[0]


func _try_arrive(def_id: String, smuggler: bool) -> bool:
	if berths_available() <= 0:
		return false
	var cost: float = GameData.FUEL["visit_cost"] if not smuggler else 0.0
	if fuel < cost:
		if not _warned_fuel_today and not smuggler:
			_warned_fuel_today = true
			post_event("本地燃料不足，货舰绕行——物流停摆中（冰矿=燃料）", "warn")
		return false
	if cost > 0.0:
		fuel -= cost
		fuel_changed.emit()
	var f := Freighter.make(def_id, smuggler, rng, price_mod, demand_mod())
	berths.append(f)
	freighters_changed.emit()
	post_event("%s 到港，停留 %d 秒（剩余泊位 %d）——货舰自动与市场挂单成交" % [
		f.name, int(GameData.ECON["freighter_dwell_s"]), berths_available()],
		"good" if not smuggler else "rare")
	return true


func _depart(f: Freighter, reason: String) -> void:
	if not berths.has(f):
		return
	berths.erase(f)
	freighters_changed.emit()
	post_event("%s 离站（%s）" % [f.name, reason], "info")


## 世界系统等外部调用方对接一艘"特殊货舰"（如采购代理）：占用正常泊位；
## 泊位已满时返回 false，由调用方自行在下一天重试（不强行挤占）。
func dock_special_freighter(f: Freighter) -> bool:
	if berths_available() <= 0:
		return false
	berths.append(f)
	freighters_changed.emit()
	return true


func summon_smuggler() -> String:
	if not modules["hangar"].get("smuggler_ok", false):
		return "需在物流机库开启走私停靠"
	if berths_available() <= 0:
		return "泊位已满"
	if fuel < GameData.FUEL["smuggler_fuel"]:
		return "燃料不足（需 %d）" % int(GameData.FUEL["smuggler_fuel"])
	if money < GameData.FUEL["smuggler_fee"]:
		return "资金不足（需 %s）" % EconTheme.money(GameData.FUEL["smuggler_fee"])
	fuel -= GameData.FUEL["smuggler_fuel"]
	money -= GameData.FUEL["smuggler_fee"]
	fuel_changed.emit()
	money_changed.emit()
	_try_arrive("small" if module_level("hangar") < 3 else "standard", true)
	return ""


# ================= 挖矿入库 =================

## BeltFlow 送达钩子：asset = 矿石 GLB 资产名
func deliver_ore(asset: String, amount: int) -> void:
	var id := GameData.asset_to_ore(asset)
	if id == "":
		return
	var value := EconTheme.money(GameData.ORES[id]["price"] * amount)
	if id == GameData.FUEL_ID:
		fuel += amount
		fuel_changed.emit()
		post_event("燃料冰矿 +%d · 估值 %s（燃料库存 %d）" % [amount, value, int(fuel)], "good")
		return
	inv[id] = int(inv.get(id, 0)) + amount
	inventory_changed.emit()
	if id in GameData.RARE_IDS:
		post_event("稀有矿入库：%s ×%d · 估值 %s" % [GameData.good_name(id), amount, value], "rare")
	else:
		post_event("%s ×%d 入库 · 估值 %s" % [GameData.good_name(id), amount, value], "good")


# ================= 库存与支付 =================

func stock(id: String) -> int:
	if id == GameData.FUEL_ID:
		return int(fuel)
	return int(inv.get(id, 0))


## cost 表可含矿石 id（fuel 走燃料库存）与组件 id
func can_pay(cost: Dictionary) -> bool:
	for id in cost:
		if stock(id) < int(cost[id]):
			return false
	return true


func pay(cost: Dictionary) -> bool:
	if not can_pay(cost):
		return false
	for id in cost:
		if id == GameData.FUEL_ID:
			fuel -= cost[id]
		else:
			inv[id] = int(inv.get(id, 0)) - int(cost[id])
	fuel_changed.emit()
	inventory_changed.emit()
	return true


func try_spend(v: float) -> bool:
	if money < v:
		return false
	money -= v
	money_changed.emit()
	return true


func add_money(v: float) -> void:
	money += v
	money_changed.emit()


# ================= 本地市场（限价挂单制, 2026-10-02 升级） =================
## 玩家不直接点货舰交易：挂限价卖单/买单挂在市场上, 到港货舰在停留期内自动撮合。
## 成交条件 = 价格可接受: 卖单要价 ≤ 货舰出价 / 买单出价 ≥ 货舰要价；
## 成交价 = 货舰报价（面板上显示的就是它, 玩家不会拿到比要价更低/付出比出价更高）。
## 挂卖即锁货（撤单/到期退回）; 挂买成交时才扣款（不收托管）;
## 挂单在 order_duration_days 后自动到期（卖单退货、买单撤销）。

## 界面/文案用的货物名（许可证带前缀）
func _goods_label(gid: String) -> String:
	if gid.begins_with("lic:"):
		return "许可证·" + GameData.equip_name(gid.substr(4))
	return GameData.good_name(gid)


## 单位基准价（许可证走 license_fee，其余走 GameData.good_unit_price）
func unit_price_of(goods_id: String) -> float:
	if goods_id.begins_with("lic:"):
		return GameData.license_fee(goods_id.substr(4))
	return GameData.good_unit_price(goods_id)


## 货舰在该货物上的**期望成交价**（默认挂单价与可成交区间都用它，含战时需求倍率）。
## 卖方向（玩家卖）= 基准价 × DEMAND × 需求倍率 × (1−收购折扣)，即"货舰的收购基准线"。
## 买方向（玩家买）= 货舰供货价期望：许可证 rng(1.0~1.1) → ×1.05；组件 rng(1.1~1.3) → ×1.20；
## 其余货物货舰不供货（sell_offers 里没有）→ 回落基准价。
## 出处: 报价生成 Freighter.gd:129-165（出售清单）/ :168-178（收购报价）。
func expected_freighter_price(goods_id: String, is_buy: bool) -> float:
	var base := unit_price_of(goods_id)
	if is_buy:
		if goods_id.begins_with("lic:"):
			return maxf(base * 1.05, 0.01)
		if GameData.is_component(goods_id):
			return maxf(base * 1.20, 0.01)
		return maxf(base, 0.01)
	var demand: float = GameData.DEMAND.get(goods_id.trim_prefix("lic:"), 1.0)
	var disc := 1.0 - float(GameData.ECON["freighter_buy_discount"])
	return maxf(base * demand * demand_mult(goods_id) * disc, 0.01)


## 货舰可成交区间 [下限, 上限]（含 rng 波动）——UI 用来说明"挂多高还能卖 / 出多低还能买"
func fillable_range(goods_id: String, is_buy: bool) -> Vector2:
	var base := unit_price_of(goods_id)
	if is_buy:
		if goods_id.begins_with("lic:"):
			return Vector2(base * 1.00, base * 1.10)
		if GameData.is_component(goods_id):
			return Vector2(base * 1.10, base * 1.30)
		return Vector2(base, base)
	var e := expected_freighter_price(goods_id, false)
	return Vector2(e * 0.9, e * 1.1)


## 默认挂单价建议: ①港内有对应报价→最优对手价（挂上就能成交）
## ②否则最近一笔成交价（价格发现） ③再否则**货舰期望价**（含战时倍率）。
## 【2026-10-02 修】原来第③档用"基准价"——而货舰出价上限 = 基准价 × DEMAND × 0.99，
## 基准价永远高于上限 ⇒ 默认价是个永远不会成交的价格。
func suggest_price(goods_id: String, is_buy: bool) -> float:
	var best := 0.0
	for f in berths:
		var o: Dictionary = f.sell_offer_for(goods_id) if is_buy else f.buy_offer_for(goods_id)
		if o.is_empty():
			continue
		var p: float = float(o["price"])
		if best <= 0.0:
			best = p
		elif is_buy and p < best:
			best = p
		elif not is_buy and p > best:
			best = p
	if best > 0.0:
		return best
	for i in range(trade_log.size() - 1, -1, -1):
		if String(trade_log[i]["g"]) == goods_id:
			return maxf(float(trade_log[i]["p"]), 0.01)
	return expected_freighter_price(goods_id, is_buy)


## 货舰是否会出售该货物 —— 只有许可证与组件进 sell_offers（Freighter.gd:129-165），
## 矿石/燃料/产品/舰船都不会：对这些货物挂买单永远不会成交（UI 要给出提示）。
func freighter_sells(goods_id: String) -> bool:
	return goods_id.begins_with("lic:") or GameData.is_component(goods_id)


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


## 该挂单还剩几天到期（供 UI 显示）
func order_remaining_days(o: Dictionary) -> float:
	return maxf(float(GameData.ECON["order_duration_days"]) - float(day - int(o.get("day", day))), 0.0)


## 到期结算: 卖单把余货退回库存, 买单直接撤销。返回撤单条数。
## 由日切换自动调用, 测试也可直接调（用 day 推进控制时机）。
func expire_orders() -> int:
	var dur: float = float(GameData.ECON["order_duration_days"])
	if dur <= 0.0:
		return 0
	var n := 0
	for i in range(sell_orders.size() - 1, -1, -1):
		var o: Dictionary = sell_orders[i]
		if float(day - int(o.get("day", day))) < dur:
			continue
		sell_orders.remove_at(i)
		_refund({String(o["goods"]): int(o["qty"])})
		post_event("挂卖到期：%s ×%d 已退回库存" % [_goods_label(String(o["goods"])), int(o["qty"])], "warn")
		n += 1
	for i in range(buy_orders.size() - 1, -1, -1):
		var b: Dictionary = buy_orders[i]
		if float(day - int(b.get("day", day))) < dur:
			continue
		buy_orders.remove_at(i)
		post_event("挂买到期：%s ×%d 已撤销" % [_goods_label(String(b["goods"])), int(b["qty"])], "warn")
		n += 1
	if n > 0:
		market_changed.emit()
	return n


## 挂卖出（限价）: 货物立即从库存锁定进挂单；price<=0 时用 suggest_price 兜底。
## 同货物 + 同价位自动合并；不同价位各成一条（价格档位语义）。qty 超库存时截断（"挂卖全部"用）。
func post_sell(goods_id: String, qty: int, price := -1.0) -> String:
	if qty <= 0:
		return "数量无效"
	qty = mini(qty, stock(goods_id))
	if qty <= 0:
		return "库存不足：%s" % _goods_label(goods_id)
	var px: float = float(price) if float(price) > 0.0 else suggest_price(goods_id, false)
	px = maxf(px, 0.01)
	if goods_id == GameData.FUEL_ID:
		fuel -= qty
		fuel_changed.emit()
	else:
		inv[goods_id] = int(inv.get(goods_id, 0)) - qty
		inventory_changed.emit()
	for o in sell_orders:
		if String(o["goods"]) == goods_id and absf(float(o.get("price", 0.0)) - px) < 0.005:
			o["qty"] = int(o["qty"]) + qty
			o["orig"] = int(o["orig"]) + qty  # 合并同货物同价位挂单
			o["day"] = day
			market_changed.emit()
			return ""
	sell_orders.append({"goods": goods_id, "qty": qty, "orig": qty, "price": px, "day": day, "uid": _order_uid})
	_order_uid += 1
	market_changed.emit()
	return ""


## 挂买入（限价）: 成交时按货舰要价扣款（≤ 你的限价）。
## 同货物 + 同价位合并；先尝试合并再判 20 单上限（旧版在合并前就拒单）。
func post_buy(goods_id: String, qty: int, price := -1.0) -> String:
	if qty <= 0:
		return "数量无效"
	var px: float = float(price) if float(price) > 0.0 else suggest_price(goods_id, true)
	px = maxf(px, 0.01)
	for o in buy_orders:
		if String(o["goods"]) == goods_id and absf(float(o.get("price", 0.0)) - px) < 0.005:
			o["qty"] = int(o["qty"]) + qty
			o["orig"] = int(o["orig"]) + qty
			o["day"] = day
			market_changed.emit()
			return ""
	if buy_orders.size() >= 20:
		return "挂买已满（20 单）"
	buy_orders.append({"goods": goods_id, "qty": qty, "orig": qty, "price": px, "day": day,"uid": _order_uid})
	_order_uid += 1
	market_changed.emit()
	return ""


## 机库现货购买许可证（官价 = 该装备 BOM 材料成本 × 20%，见 GameData.license_fee）。
## 与货舰渠道并存：货舰浮动价（普通 1.0~1.1×、走私 0.8×），机库是稳定官价。
## 一张许可证 = license_uses() 次（舰船 3 次 / 产品 30 次）。
func buy_license(equip: String, count := 1) -> String:
	if count <= 0:
		return "数量无效"
	if not (GameData.PRODUCTS.has(equip) or GameData.SHIPS.has(equip)):
		return "该装备不需要许可证"
	var total: float = GameData.license_fee(equip) * float(count)
	if money < total:
		return "资金不足（需 %s）" % EconTheme.money(total)
	try_spend(total)
	var uses := GameData.license_uses(equip) * count
	licenses[equip] = int(licenses.get(equip, 0)) + uses
	licenses_changed.emit()
	market_changed.emit()
	post_event("机库购入 %s 许可证 ×%d（+%d 次）" % [GameData.equip_name(equip), count, uses], "good")
	return ""


## 按 uid 撤单（UI 选中用——数组下标会被成交/到期移位, uid 稳定）
func cancel_sell_by_uid(uid: int) -> bool:
	for i in sell_orders.size():
		if int(sell_orders[i].get("uid", -1)) == uid:
			cancel_sell(i)
			return true
	return false


func cancel_buy_by_uid(uid: int) -> bool:
	for i in buy_orders.size():
		if int(buy_orders[i].get("uid", -1)) == uid:
			cancel_buy(i)
			return true
	return false


func cancel_sell(index: int) -> void:
	if index < 0 or index >= sell_orders.size():
		return
	var o: Dictionary = sell_orders[index]
	sell_orders.remove_at(index)
	_refund({String(o["goods"]): int(o["qty"])})
	market_changed.emit()


func cancel_buy(index: int) -> void:
	if index < 0 or index >= buy_orders.size():
		return
	buy_orders.remove_at(index)
	market_changed.emit()


## 每秒一拍：到港货舰 ↔ 市场挂单 自动撮合
func _auto_trade(dt: float) -> void:
	if berths.is_empty() or (sell_orders.is_empty() and buy_orders.is_empty()):
		return
	var rate: float = GameData.ECON["trade_rate"] \
		* (1.0 + GameData.ECON["container_rate_mult"] * module_count("container")) * dt
	if debug_instant:
		rate *= 50.0
	var traded := false
	for f in berths.duplicate():
		# trade_rate = 每艘船【总】吞吐/秒——买卖共享同一预算(2026-10-01 修双向翻倍)。
		# 双向都要跑: `or` 短路会让"收货成功"的货舰当拍不卖货; 若它当拍就舱满离站,
		# 玩家挂在买方的单永远吃不到（economy 冒烟测试的买方断言曾因此静默漏检）。
		var used_buy := _freighter_buys(f, rate)
		var used_sell := _freighter_sells(f, rate - float(used_buy))
		if used_buy > 0 or used_sell > 0:
			traded = true
		# 世界系统的采购代理(is_dealer)靠 WorldState 的阶段结束日离港，不吃"货单吃满就走"的规则
		if not f.is_dealer and f.after_trade():
			_depart(f, "货单完成")
	if traded:
		market_changed.emit()
		freighters_changed.emit()


## 货舰按收购清单吃进市场挂卖
func _freighter_buys(f: Freighter, budget: float) -> int:
	var used := 0
	for offer in f.buy_offers:
		if budget - float(used) < 1.0 or f.funds < float(offer["price"]):
			continue
		for listing in sell_orders:
			if String(listing["goods"]) != String(offer["goods"]) or int(listing["qty"]) <= 0:
				continue
			var price: float = float(offer["price"])
			# 限价: 玩家要价高于货舰出价 → 本拍不成交（等更好的价, 否则到期退回）
			if float(listing.get("price", price)) > price + 0.0001:
				continue
			var space := f.space_left() / GameData.good_volume(String(offer["goods"]))
			var n: int = mini(int(listing["qty"]), int(float(offer["qty_left"])))
			n = mini(n, int(space))
			n = mini(n, int(budget) - used)
			n = mini(n, int(f.funds / maxf(price, 0.01)))
			if n <= 0:
				continue
			_log_trade(String(offer["goods"]), price, n)
			if GameData.is_military(String(offer["goods"])):
				military_goods_sold.emit(String(offer["goods"]), n, price)
			listing["qty"] = int(listing["qty"]) - n
			offer["qty_left"] = float(offer["qty_left"]) - n
			f.cargo_units += n * GameData.good_volume(String(offer["goods"]))
			f.funds -= price * n
			add_money(price * n)
			used += n
			if int(listing["qty"]) <= 0:
				sell_orders.erase(listing)
	return used


## 货舰按出售清单供应市场挂买
func _freighter_sells(f: Freighter, budget: float) -> int:
	var used := 0
	for offer in f.sell_offers:
		if float(offer["qty"]) < 1.0 or budget - float(used) < 1.0:
			continue
		for listing in buy_orders:
			if String(listing["goods"]) != String(offer["goods"]) or int(listing["qty"]) <= 0:
				continue
			var price: float = float(offer["price"])
			# 限价: 货舰要价高于玩家出价 → 不成交
			if price > float(listing.get("price", price)) + 0.0001:
				continue
			var n: int = mini(int(listing["qty"]), int(float(offer["qty"])))
			n = mini(n, int(budget) - used)
			n = mini(n, int(money / maxf(price, 0.01)))
			if n <= 0:
				continue
			var gid := String(offer["goods"])
			listing["qty"] = int(listing["qty"]) - n
			offer["qty"] = float(offer["qty"]) - n
			try_spend(price * n)
			f.funds += price * n
			budget -= n
			used += n
			_log_trade(gid, price, n)
			if gid.begins_with("lic:"):
				var equip := gid.substr(4)
				licenses[equip] = int(licenses.get(equip, 0)) + int(offer["uses"]) * n
				licenses_changed.emit()
				post_event("市场成交：购得 %s 许可证 ×%d" % [GameData.equip_name(equip), n], "good")
			else:
				inv[gid] = int(inv.get(gid, 0)) + n
				inventory_changed.emit()
				post_event("市场成交：购入 %s ×%d ← %s" % [GameData.good_name(gid), n, f.name], "good")
			if int(listing["qty"]) <= 0:
				buy_orders.erase(listing)
			break
	return used


func berths_available() -> int:
	return _berths_total() - berths.size()


func _berths_total() -> int:
	var lv := module_level("hangar")
	if lv <= 0:
		return 0
	return int(GameData.MODULES["hangar"]["levels"][lv - 1]["berths"])


# ================= 制造（组件/产品/舰船） =================

func factory_count() -> int:
	return module_count("factory")


func max_lines() -> int:
	return int(GameData.ECON["base_lines"]) + int(GameData.ECON["lines_per_factory"]) * factory_count()


## 有效材料表（建造厂 -1%/座；原图 ME -2%/级 仅对已获原图的设备生效）
func effective_materials(equip: String) -> Dictionary:
	var bom: Dictionary = _equip_bom(equip)
	var f := factory_count()
	var me: int = me_levels.get(equip, 0) if blueprints.has(equip) else 0
	var out := {}
	for id in bom:
		var v: float = float(bom[id]) * (1.0 - GameData.ECON["factory_mat_pct"] * f) \
			* (1.0 - GameData.RESEARCH["me_pct"] * me)
		out[id] = maxi(1, roundi(v)) if int(bom[id]) > 0 else 0
	return out


## 有效工期秒（建造厂 -4%/座；原图 TE -4%/级；测试期全局 ×10 速度）
func effective_time(equip: String) -> float:
	var t: float = _equip_time(equip)
	var f := factory_count()
	var te: int = te_levels.get(equip, 0) if blueprints.has(equip) else 0
	t *= (1.0 - GameData.ECON["factory_time_pct"] * f) * (1.0 - GameData.RESEARCH["te_pct"] * te)
	t /= float(GameData.ECON["build_speed_mult"])
	return t / 100.0 if debug_instant else t


func _equip_bom(equip: String) -> Dictionary:
	if GameData.PRODUCTS.has(equip):
		return GameData.PRODUCTS[equip]["bom"]
	if GameData.SHIPS.has(equip):
		return GameData.SHIPS[equip]["bom"]
	return GameData.COMPONENTS[equip]["bom"]


func _equip_time(equip: String) -> float:
	if GameData.PRODUCTS.has(equip):
		return GameData.PRODUCTS[equip]["time"]
	if GameData.SHIPS.has(equip):
		return GameData.SHIPS[equip]["time"]
	return GameData.COMPONENTS[equip]["time"]


func production_block_reason(equip: String, batches: int) -> String:
	if not GameData.is_component(equip) and factory_count() <= 0:
		return "需要建造厂"  # 组件可手搓（首建机库路径）；产品/舰船要建造厂
	var need := effective_materials(equip)
	for id in need:
		var per := int(need[id]) * batches
		if stock(id) < per:
			return "材料不足：%s" % GameData.good_name(id)
	# 许可证只管产品/舰船——组件（空间站结构）永远免许可证（2026-09-30 修 bug）
	# MVP: MissionOps 装备(is_equip)免许可证(蓝图 §15.3 许可制造 M3 接)
	# 产线满不再拦截：继续下单会进入排队（2026-09-30 拍板）
	var is_mission_equip: bool = GameData.PRODUCTS.has(equip) and GameData.PRODUCTS[equip].get("is_equip", false)
	if not is_mission_equip and not GameData.is_component(equip) and not blueprints.has(equip):
		var uses := int(licenses.get(equip, 0))
		if uses < batches:
			return "许可证次数不足（去机库向货舰购买）"
	return ""


func start_production(equip: String, batches: int) -> String:
	var reason := production_block_reason(equip, batches)
	if reason != "":
		return reason
	if order_queue.size() >= int(GameData.ECON["max_order_queue"]):
		return "排队已满（上限 %d 单）" % int(GameData.ECON["max_order_queue"])
	var need := effective_materials(equip)
	var cost := {}
	for id in need:
		cost[id] = int(need[id]) * batches
	pay(cost)
	# 许可证只管产品/舰船：组件不消耗许可证、也不涨逆向（2026-09-30 修 bug）
	# MVP: MissionOps 装备(is_equip)免许可证——基础装备直接造(船长令 2026-10-05)
	# 排队制下许可证在下单时锁定扣除、取消时退还（完工只涨逆向）
	var is_mission_equip2: bool = GameData.PRODUCTS.has(equip) and GameData.PRODUCTS[equip].get("is_equip", false)
	var uses_license := not is_mission_equip2 and not blueprints.has(equip) and not GameData.is_component(equip)
	if uses_license:
		licenses[equip] = int(licenses.get(equip, 0)) - batches
		if int(licenses[equip]) <= 0:
			licenses.erase(equip)
		licenses_changed.emit()
	order_queue.append({"equip": equip, "batches": batches, "uses_license": uses_license, "paid": cost})
	_pump_orders()
	jobs_changed.emit()
	return ""


## 产线有空位时按排队顺序开工（下单时已锁料）
func _pump_orders() -> void:
	while order_queue.size() > 0 and prod_jobs.size() < max_lines():
		var order: Dictionary = order_queue.pop_front()
		var t: float = effective_time(order["equip"]) * float(order["batches"])
		prod_jobs.append({
			"kind": "equip",
			"equip": order["equip"],
			"batches": int(order["batches"]),
			"total": t,
			"left": t,
			"uses_license": order["uses_license"],
		})


## 取消排队订单：全额退还下单时锁定的材料与许可证次数
func cancel_order(index: int) -> void:
	if index < 0 or index >= order_queue.size():
		return
	var order: Dictionary = order_queue[index]
	order_queue.remove_at(index)
	_refund(order["paid"])
	if order["uses_license"]:
		var equip: String = order["equip"]
		licenses[equip] = int(licenses.get(equip, 0)) + int(order["batches"])
		licenses_changed.emit()
	jobs_changed.emit()


func _refund(cost: Dictionary) -> void:
	for id in cost:
		if id == GameData.FUEL_ID:
			fuel += float(cost[id])
		else:
			inv[id] = int(inv.get(id, 0)) + int(cost[id])
	fuel_changed.emit()
	inventory_changed.emit()


func _advance_jobs(delta: float) -> void:
	var dirty := false
	for job in prod_jobs.duplicate():
		job["left"] -= delta
		if job["left"] <= 0.0:
			prod_jobs.erase(job)
			_finish_production(job)
			dirty = true
	for job in research_jobs.duplicate():
		job["left"] -= delta
		if job["left"] <= 0.0:
			research_jobs.erase(job)
			_finish_research(job)
			dirty = true
	for id in module_jobs.keys().duplicate():
		var mj: Dictionary = module_jobs[id]
		mj["left"] -= delta
		if mj["left"] <= 0.0:
			module_jobs.erase(id)
			_finish_module_build(id)
			dirty = true
	if dirty:
		jobs_changed.emit()


func _finish_production(job: Dictionary) -> void:
	var equip: String = job["equip"]
	var batches: int = job["batches"]
	# MVP: MissionOps 装备完工 → 入 MissionOps 库存(非 Economy.inv)
	if GameData.PRODUCTS.has(equip) and GameData.PRODUCTS[equip].get("is_equip", false):
		var mo := get_node_or_null("/root/MissionOps")
		if mo:
			mo.grant_equipment(equip, batches)
			post_event("%s 制造完成 ×%d → 已入探索装备库" % [GameData.good_name(equip), batches], "good")
			jobs_changed.emit()
			return
	if GameData.is_component(equip):
		inv[equip] = int(inv.get(equip, 0)) + batches
	elif GameData.is_product(equip):
		inv[equip] = int(inv.get(equip, 0)) + GameData.PRODUCTS[equip]["batch"] * batches
	else:
		inv[equip] = int(inv.get(equip, 0)) + batches
	inventory_changed.emit()
	if job["uses_license"] and not GameData.is_component(equip):
		# 许可证已在下单时扣除；完工只涨逆向等级
		var lv := int(reverse.get(equip, 0)) + batches
		var mx := GameData.reverse_max(equip)
		if lv > mx:
			lv = mx
		if lv != int(reverse.get(equip, 0)):
			reverse[equip] = lv
			research_changed.emit()
			if lv >= mx:
				post_event("%s 逆向研究已满级，可在研究站研制原图！" % GameData.equip_name(equip), "good")
	post_event("生产完成：%s ×%d" % [GameData.good_name(equip), batches], "good")
	_pump_orders()  # 产线空出 → 立即开工下一张排队单


# ================= 研究站 =================

func research_slots() -> int:
	var lv := module_level("research")
	if lv <= 0:
		return 0
	return int(GameData.MODULES["research"]["levels"][lv - 1]["slots"])


func research_speed() -> float:
	var lv := module_level("research")
	if lv <= 0:
		return 0.0
	return float(GameData.MODULES["research"]["levels"][lv - 1]["speed"])


func research_block_reason(kind: String, equip: String) -> String:
	if module_level("research") <= 0:
		return "需要研究站"
	if research_jobs.size() >= research_slots():
		return "研究槽已满"
	# 同一目标不能并行研究（2026-10-02 用户报"能点多次但没有实际作用"）:
	# 原先只查"槽位是否满", 研究站有 2 槽时同一个原图能排两条 —— 第二条完工只是把
	# blueprints[equip] 再写一遍, 纯浪费槽位与时间（截图里正是两条重复的原图作业）。
	# ME/TE 更糟: 并行完工会把等级推过上限。
	for j in research_jobs:
		if String(j["kind"]) == kind and String(j["equip"]) == equip:
			return "该目标已在研究中"
	match kind:
		"blueprint":
			if blueprints.has(equip):
				return "已拥有原图"
			if int(reverse.get(equip, 0)) < GameData.reverse_max(equip):
				return "逆向等级未满（%d/%d）" % [int(reverse.get(equip, 0)), GameData.reverse_max(equip)]
		"me":
			if not blueprints.has(equip):
				return "需先获得原图"
			if int(me_levels.get(equip, 0)) >= int(GameData.RESEARCH["me_max"]):
				return "已满级"
		"te":
			if not blueprints.has(equip):
				return "需先获得原图"
			if int(te_levels.get(equip, 0)) >= int(GameData.RESEARCH["te_max"]):
				return "已满级"
	return ""


func start_research(kind: String, equip: String) -> String:
	var reason := research_block_reason(kind, equip)
	if reason != "":
		return reason
	var t: float = GameData.RESEARCH["blueprint_time"] if kind == "blueprint" \
		else GameData.RESEARCH["me_time"] if kind == "me" else GameData.RESEARCH["te_time"]
	t /= research_speed()
	if debug_instant:
		t /= 100.0
	t /= float(GameData.ECON["build_speed_mult"])
	research_jobs.append({"kind": kind, "equip": equip, "total": t, "left": t})
	jobs_changed.emit()
	return ""


func _finish_research(job: Dictionary) -> void:
	var equip: String = job["equip"]
	match job["kind"]:
		"blueprint":
			blueprints[equip] = true
			post_event("逆向完成！获得原图蓝图：%s（免许可费生产）" % GameData.equip_name(equip), "good")
		"me":
			var me_max := int(GameData.RESEARCH["me_max"])
			var me_new: int = mini(int(me_levels.get(equip, 0)) + 1, me_max)   # 并行作业可能已推到上限
			if me_new != int(me_levels.get(equip, 0)):
				me_levels[equip] = me_new
				post_event("材料研究 ME +%d → %s（材料 -%d%%）" % [
					me_levels[equip], GameData.equip_name(equip),
					me_levels[equip] * int(GameData.RESEARCH["me_pct"] * 100)], "good")
		"te":
			var te_max := int(GameData.RESEARCH["te_max"])
			var te_new: int = mini(int(te_levels.get(equip, 0)) + 1, te_max)
			if te_new != int(te_levels.get(equip, 0)):
				te_levels[equip] = te_new
				post_event("建造研究 TE +%d → %s（工期 -%d%%）" % [
					te_levels[equip], GameData.equip_name(equip),
					te_levels[equip] * int(GameData.RESEARCH["te_pct"] * 100)], "good")
	research_changed.emit()


# ================= 空间站模块 =================

func _init_state() -> void:
	for id in GameData.MODULES:
		modules[id] = {"built": false, "level": 0, "count": 0, "smuggler_ok": false}
	inv.clear()


func module_level(id: String) -> int:
	return int(modules[id]["level"]) if modules.has(id) else 0


## 雇佣兵巢穴等级(蓝图 §5.9): MissionOps 行动舰队容量的唯一来源
func hive_level() -> int:
	return module_level("hive")


func module_count(id: String) -> int:
	return int(modules[id]["count"]) if modules.has(id) else 0


func module_state(id: String) -> Dictionary:
	return modules[id]


## 目标等级（levels 制）或目标数量+1（叠加制）的花费与工期
func module_next_cost(id: String) -> Dictionary:
	var def: Dictionary = GameData.MODULES[id]
	if def.has("levels"):
		var lv := module_level(id)
		if lv >= def["levels"].size():
			return {}
		return def["levels"][lv]["cost"]
	if module_count(id) >= int(def["max_count"]):
		return {}
	return def["cost"]


func module_build_block(id: String) -> String:
	var def: Dictionary = GameData.MODULES[id]
	if def.has("levels"):
		var lv := module_level(id)
		if module_jobs.has(id):
			return "建造中"
		if lv >= def["levels"].size():
			return "已满级"
	else:
		if module_jobs.has(id):
			return "建造中"
		if module_count(id) >= int(def["max_count"]):
			return "已达上限"
	var cost := module_next_cost(id)
	for gid in cost:
		if stock(gid) < int(cost[gid]):
			return "材料不足：%s" % GameData.good_name(gid)
	return ""


func build_module(id: String) -> String:
	var reason := module_build_block(id)
	if reason != "":
		return reason
	pay(module_next_cost(id))
	var t: float = GameData.MODULES[id]["time"] if not GameData.MODULES[id].has("levels") \
		else GameData.MODULES[id]["levels"][module_level(id)]["time"]
	if debug_instant:
		t /= 100.0
	t /= float(GameData.ECON["build_speed_mult"])
	module_jobs[id] = {"total": t, "left": t}
	jobs_changed.emit()
	modules_changed.emit()
	return ""


func _finish_module_build(id: String) -> void:
	var def: Dictionary = GameData.MODULES[id]
	var m: Dictionary = modules[id]
	if def.has("levels"):
		m["level"] = int(m["level"]) + 1
		m["built"] = true
		post_event("%s 建成（Lv.%d）——点击空间站打开 %s 界面" % [def["name"], m["level"], def["name"]], "good")
	else:
		m["count"] = int(m["count"]) + 1
		m["built"] = true
		post_event("%s 加装完成（第 %d %s）" % [def["name"], m["count"], def.get("unit", "组")], "good")
	_roll_visit_schedule()
	_pump_orders()  # 建造厂扩产线 → 排队单可能立即开工
	modules_changed.emit()


func set_smuggler_ok(on: bool) -> void:
	modules["hangar"]["smuggler_ok"] = on
	modules_changed.emit()
	post_event("走私货舰停靠已%s——暗市渠道%s" % ["开启" if on else "关闭", "接入" if on else "断开"], "warn")


# ================= 事件与存档 =================

func post_event(text: String, kind := "info") -> void:
	event_posted.emit(text, kind)


## 成交历史（价格图数据源）: {g货物, p单价, q数量, d游戏日}
func _log_trade(gid: String, price: float, qty: int) -> void:
	trade_log.append({"g": gid, "p": price, "q": qty, "d": day})
	if trade_log.size() > 200:
		trade_log = trade_log.slice(trade_log.size() - 200)


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
			o["uid"] = _order_uid
			_order_uid += 1
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
