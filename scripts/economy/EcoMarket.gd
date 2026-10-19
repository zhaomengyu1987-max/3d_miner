extends Node
## EcoMarket —— 本地市场（限价挂单制, 2026-10-02 升级）+ 价格查询 + 成交历史
## （Economy 门面拆分子模块, 2026-10-14）。
## 玩家不直接点货舰交易：挂限价卖单/买单挂在市场上, 到港货舰在停留期内自动撮合。
## 成交条件 = 价格可接受: 卖单要价 ≤ 货舰出价 / 买单出价 ≥ 货舰要价；
## 成交价 = 货舰报价（面板上显示的就是它, 玩家不会拿到比要价更低/付出比出价更高）。
## 挂卖即锁货（撤单/到期退回）; 挂买成交时才扣款（不收托管）;
## 挂单在 order_duration_days 后自动到期（卖单退货、买单撤销）。
## 撮合跨界（动钱包/库存/许可证）一律走 eco.* 门面调用, 不复制逻辑。

var eco: Node  # Economy 门面

var sell_orders: Array = []      # 本地市场挂卖 {goods,qty,orig,price,day,uid}（挂单即锁货, 可取消退回）
var buy_orders: Array = []       # 本地市场挂买 {goods,qty,orig,price,day,uid}（成交时扣款）
var trade_log: Array = []        # 成交历史 [{g,p,q,d}] 截断 200 条（价格历史图数据源）
## 市场价格因子（事件接口）: {货物id 或 "*": 倍数}, 缺省 1.0。
## 只影响之后到港的货舰报价（Freighter.make 生成清单时读取），已停靠的船不追溯。
## 例: price_mod["*"] = 1.15 → 全局涨价 15%；price_mod["commonA"] = 0.8 → 普矿A 单独压价 20%。
var price_mod: Dictionary = {}
var _order_uid := 1               # 挂单稳定唯一 id（修 UI 陈旧下标误撤, 2026-10-01）


## 某货物的当前价格因子（全局 "*" × 该货物条目，夹 0.05 下限）
func price_factor(goods_id: String) -> float:
	return Freighter.resolve_price_mod(price_mod, goods_id)


## 事件接口: 设定价格因子（相对当前基准价的倍数）
func set_price_mod(goods_id: String, mult: float) -> void:
	price_mod[goods_id] = maxf(mult, 0.05)
	eco.market_changed.emit()


## 事件接口: 按增量扰动价格因子（事件用百分比描述冲击时更顺手）
func nudge_price_mod(goods_id: String, delta: float) -> void:
	set_price_mod(goods_id, price_factor(goods_id) + delta)


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
	return maxf(base * demand * eco.demand_mult(goods_id) * disc, 0.01)


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
	for f in eco.berths:
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


## 该挂单还剩几天到期（供 UI 显示）
func order_remaining_days(o: Dictionary) -> float:
	return maxf(float(GameData.ECON["order_duration_days"]) - float(eco.day - int(o.get("day", eco.day))), 0.0)


## 到期结算: 卖单把余货退回库存, 买单直接撤销。返回撤单条数。
## 由日切换自动调用, 测试也可直接调（用 day 推进控制时机）。
func expire_orders() -> int:
	var dur: float = float(GameData.ECON["order_duration_days"])
	if dur <= 0.0:
		return 0
	var n := 0
	for i in range(sell_orders.size() - 1, -1, -1):
		var o: Dictionary = sell_orders[i]
		if float(eco.day - int(o.get("day", eco.day))) < dur:
			continue
		sell_orders.remove_at(i)
		eco._refund({String(o["goods"]): int(o["qty"])})
		eco.post_event("挂卖到期：%s ×%d 已退回库存" % [_goods_label(String(o["goods"])), int(o["qty"])], "warn")
		n += 1
	for i in range(buy_orders.size() - 1, -1, -1):
		var b: Dictionary = buy_orders[i]
		if float(eco.day - int(b.get("day", eco.day))) < dur:
			continue
		buy_orders.remove_at(i)
		eco.post_event("挂买到期：%s ×%d 已撤销" % [_goods_label(String(b["goods"])), int(b["qty"])], "warn")
		n += 1
	if n > 0:
		eco.market_changed.emit()
	return n


## 挂卖出（限价）: 货物立即从库存锁定进挂单；price<=0 时用 suggest_price 兜底。
## 同货物 + 同价位自动合并；不同价位各成一条（价格档位语义）。qty 超库存时截断（"挂卖全部"用）。
func post_sell(goods_id: String, qty: int, price := -1.0) -> String:
	if qty <= 0:
		return "数量无效"
	qty = mini(qty, eco.stock(goods_id))
	if qty <= 0:
		return "库存不足：%s" % _goods_label(goods_id)
	var px: float = float(price) if float(price) > 0.0 else suggest_price(goods_id, false)
	px = maxf(px, 0.01)
	if goods_id == GameData.FUEL_ID:
		eco.fuel -= qty
		eco.fuel_changed.emit()
	else:
		eco.inv[goods_id] = int(eco.inv.get(goods_id, 0)) - qty
		eco.inventory_changed.emit()
	for o in sell_orders:
		if String(o["goods"]) == goods_id and absf(float(o.get("price", 0.0)) - px) < 0.005:
			o["qty"] = int(o["qty"]) + qty
			o["orig"] = int(o["orig"]) + qty  # 合并同货物同价位挂单
			o["day"] = eco.day
			eco.market_changed.emit()
			return ""
	sell_orders.append({"goods": goods_id, "qty": qty, "orig": qty, "price": px, "day": eco.day, "uid": _order_uid})
	_order_uid += 1
	eco.market_changed.emit()
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
			o["day"] = eco.day
			eco.market_changed.emit()
			return ""
	if buy_orders.size() >= 20:
		return "挂买已满（20 单）"
	buy_orders.append({"goods": goods_id, "qty": qty, "orig": qty, "price": px, "day": eco.day, "uid": _order_uid})
	_order_uid += 1
	eco.market_changed.emit()
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
	eco._refund({String(o["goods"]): int(o["qty"])})
	eco.market_changed.emit()


func cancel_buy(index: int) -> void:
	if index < 0 or index >= buy_orders.size():
		return
	buy_orders.remove_at(index)
	eco.market_changed.emit()


## 每秒一拍：到港货舰 ↔ 市场挂单 自动撮合
func _auto_trade(dt: float) -> void:
	if eco.berths.is_empty() or (sell_orders.is_empty() and buy_orders.is_empty()):
		return
	var rate: float = GameData.ECON["trade_rate"] \
		* (1.0 + GameData.ECON["container_rate_mult"] * eco.module_count("container")) * dt
	if eco.debug_instant:
		rate *= 50.0
	var traded := false
	for f in eco.berths.duplicate():
		# trade_rate = 每艘船【总】吞吐/秒——买卖共享同一预算(2026-10-01 修双向翻倍)。
		# 双向都要跑: `or` 短路会让"收货成功"的货舰当拍不卖货; 若它当拍就舱满离站,
		# 玩家挂在买方的单永远吃不到（economy 冒烟测试的买方断言曾因此静默漏检）。
		var used_buy := _freighter_buys(f, rate)
		var used_sell := _freighter_sells(f, rate - float(used_buy))
		if used_buy > 0 or used_sell > 0:
			traded = true
		# 世界系统的采购代理(is_dealer)靠 WorldState 的阶段结束日离港，不吃"货单吃满就走"的规则
		if not f.is_dealer and f.after_trade():
			eco._depart(f, "货单完成")
	if traded:
		eco.market_changed.emit()
		eco.freighters_changed.emit()


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
				eco.military_goods_sold.emit(String(offer["goods"]), n, price)
			listing["qty"] = int(listing["qty"]) - n
			offer["qty_left"] = float(offer["qty_left"]) - n
			f.cargo_units += n * GameData.good_volume(String(offer["goods"]))
			f.funds -= price * n
			eco.add_money(price * n)
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
			n = mini(n, int(eco.money / maxf(price, 0.01)))
			if n <= 0:
				continue
			var gid := String(offer["goods"])
			listing["qty"] = int(listing["qty"]) - n
			offer["qty"] = float(offer["qty"]) - n
			eco.try_spend(price * n)
			f.funds += price * n
			budget -= n
			used += n
			_log_trade(gid, price, n)
			if gid.begins_with("lic:"):
				var equip := gid.substr(4)
				eco.licenses[equip] = int(eco.licenses.get(equip, 0)) + int(offer["uses"]) * n
				eco.licenses_changed.emit()
				eco.post_event("市场成交：购得 %s 许可证 ×%d" % [GameData.equip_name(equip), n], "good")
			else:
				eco.inv[gid] = int(eco.inv.get(gid, 0)) + n
				eco.inventory_changed.emit()
				eco.post_event("市场成交：购入 %s ×%d ← %s" % [GameData.good_name(gid), n, f.name], "good")
			if int(listing["qty"]) <= 0:
				buy_orders.erase(listing)
			break
	return used


## 成交历史（价格图数据源）: {g货物, p单价, q数量, d游戏日}
func _log_trade(gid: String, price: float, qty: int) -> void:
	trade_log.append({"g": gid, "p": price, "q": qty, "d": eco.day})
	if trade_log.size() > 200:
		trade_log = trade_log.slice(trade_log.size() - 200)
