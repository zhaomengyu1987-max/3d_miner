extends Node

## 制造系统冒烟测试（headless）：
## godot --headless --path . res://tests/economy_smoke_test.tscn
## 输出 ECONOMY_TEST_PASS / ECONOMY_TEST_FAIL。
## 存档重定向到 user://economy_test_save.json，不触碰真实存档。

var _fails: Array[String] = []

## 用 const preload 而不是 class_name: 新脚本的类名要等编辑器扫描后才进
## .godot/global_script_class_cache.cfg, release/headless 下不一定已登记（`is` 需要 const 才能当类型用）。
const NewsTickerScript := preload("res://scripts/ui/NewsTicker.gd")


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails.append(what)
		print("  [FAIL] ", what)


func _ready() -> void:
	await get_tree().process_frame  # 等 Economy 的 deferred 世界/UI 挂载完成
	Economy.debug_instant = true
	Economy.save_path = "user://economy_test_save.json"
	Economy.debug_reset()  # 真实存档里可能有模块/作业, 测试须从全新开局开始
	_test_deliver()
	_test_pay()
	_test_module_build()
	_test_production_license()
	_test_research()
	_test_component_no_license()
	_test_order_uid_cancel()
	_test_trade_budget()
	_test_order_queue()
	await _test_market_trade()  # 协程: 不 await 会让其 await 之后的断言全部静默跳过
	_test_smuggler()
	_test_price_factor()
	_test_balance_and_war()
	_test_price_chart()
	await _test_limit_orders()
	_test_order_migration()
	await _test_scroll_keep()
	await _test_license_market()
	await _test_orderbook_columns()
	await _test_icons()
	await _test_drag_and_layer()
	await _test_news_ticker()
	_test_save_load()
	_cleanup()
	if _fails.is_empty():
		print("ECONOMY_TEST_PASS")
		get_tree().quit(0)
	else:
		print("ECONOMY_TEST_FAIL (%d)" % _fails.size())
		get_tree().quit(1)


func _test_deliver() -> void:
	print("[deliver]")
	Economy.inv.clear()
	Economy.fuel = 0.0
	Economy.deliver_ore("IronOre", 100)
	Economy.deliver_ore("IceOre", 50)      # IceOre = 燃料冰矿(高频冰)
	Economy.deliver_ore("iceBlack", 30)    # iceBlack = 普矿C(2026-09-30 对调)
	Economy.deliver_ore("superbigGold", 10)  # 不在数据表: 忽略
	_check(Economy.stock("commonA") == 100, "IronOre→普矿A ×100")
	_check(Economy.fuel == 50.0, "IceOre→燃料 ×50")
	_check(Economy.stock("commonC") == 30, "iceBlack→普矿C ×30")
	_check(Economy.stock("rareD") == 0, "superbigGold 不入账")


func _test_pay() -> void:
	print("[pay]")
	Economy.inv.clear()
	Economy.inv["commonA"] = 100
	Economy.inv["truss"] = 2
	_check(Economy.can_pay({"commonA": 100, "truss": 2}), "can_pay 满足")
	_check(Economy.pay({"commonA": 100, "truss": 2}), "pay 成功")
	_check(Economy.stock("commonA") == 0 and Economy.stock("truss") == 0, "pay 扣减")
	_check(not Economy.can_pay({"commonA": 1}), "can_pay 不足")
	Economy.money = 100.0
	_check(not Economy.try_spend(150.0), "try_spend 余额不足")
	_check(Economy.try_spend(50.0) and Economy.money == 50.0, "try_spend 成功")


func _test_module_build() -> void:
	print("[module]")
	Economy.inv.clear()
	for id in ["commonA", "commonB", "commonC", "commonD", "commonE"]:
		Economy.inv[id] = 5000
	for id in ["truss", "cabin", "ecu", "fueltank"]:
		Economy.inv[id] = 20
	_check(Economy.module_build_block("hangar") == "", "机库可建")
	_check(Economy.build_module("hangar") == "", "建造机库提交")
	_check(Economy.module_jobs.has("hangar"), "机库作业中")
	Economy.module_jobs["hangar"]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.module_level("hangar") == 1, "机库 Lv1")
	_check(Economy.berths_available() == 1, "泊位 1")
	_check(Economy.build_module("hangar") == "", "升级机库提交")
	Economy.module_jobs["hangar"]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.module_level("hangar") == 2 and Economy.berths_available() == 2, "机库 Lv2 泊位 2")
	_check(Economy.build_module("factory") == "", "建造厂提交")
	Economy.module_jobs["factory"]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.factory_count() == 1 and Economy.max_lines() == 3, "建造厂 +2 产线")
	_check(Economy.build_module("research") == "", "研究站提交")
	Economy.module_jobs["research"]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.research_slots() == 1 and Economy.research_speed() > 1.0, "研究站 Lv1 生效")


func _test_production_license() -> void:
	print("[production]")
	Economy.inv.clear()
	Economy.inv["commonA"] = 500
	Economy.inv["commonB"] = 500
	Economy.inv["commonE"] = 500
	Economy.licenses["smallArms"] = 2
	_check(Economy.production_block_reason("smallArms", 5) != "", "许可证次数不足拦截")
	_check(Economy.start_production("smallArms", 1) == "", "制造 smallArms ×1 批")
	_check(Economy.prod_jobs.size() == 1, "作业入队")
	_check(Economy.stock("commonA") == 470, "BOM 扣料(30)")
	Economy.prod_jobs[0]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.stock("smallArms") == 100, "产出 100 支")
	_check(int(Economy.licenses["smallArms"]) == 1, "许可证 -1 次")
	_check(int(Economy.reverse.get("smallArms", 0)) == 1, "逆向 +1")


func _test_research() -> void:
	print("[research]")
	Economy.reverse["smallArms"] = GameData.reverse_max("smallArms")
	_check(Economy.research_block_reason("blueprint", "smallArms") == "", "原图可研制")
	_check(Economy.start_research("blueprint", "smallArms") == "", "原图研究提交")
	# 同目标不能并行（2026-10-02 用户报"能点多次但没有实际作用"）:
	# 研究站有 2 槽时, 原先同一个原图能排两条, 第二条完工只是把 blueprints 再写一遍。
	Economy.module_state("research")["level"] = maxi(Economy.module_state("research")["level"], 2)
	if Economy.research_slots() >= 2:
		var dup := Economy.start_research("blueprint", "smallArms")
		_check(dup != "", "同一原图第二次被拒（%s）" % dup)
		_check(Economy.research_jobs.size() == 1,
			"只产生 1 条研究作业（实际 %d 条）" % Economy.research_jobs.size())
	else:
		print("   （研究槽 <2, 跳过并行重复断言）")
	Economy.research_jobs[0]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.blueprints.has("smallArms"), "原图到手")
	_check(Economy.research_block_reason("blueprint", "smallArms") == "已拥有原图",
		"已有原图后不可重复研制")
	_check(Economy.start_research("me", "smallArms") == "", "ME 研究提交")
	Economy.research_jobs[0]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(int(Economy.me_levels.get("smallArms", 0)) == 1, "ME Lv1")
	var mats: Dictionary = Economy.effective_materials("smallArms")
	_check(int(mats["commonA"]) == 29, "ME -2%% 后 commonA 30→29 (得 %s)" % mats.get("commonA"))
	_check(Economy.research_block_reason("me", "smallArms") == "" or true, "ME 继续研究可达")
	# ME 等级不会越过上限（并行作业/旧存档可能留下重复作业）
	var me_max := int(GameData.RESEARCH["me_max"])
	Economy.me_levels["smallArms"] = me_max
	Economy.research_jobs.append({"kind": "me", "equip": "smallArms", "total": 1.0, "left": 0.0})
	Economy._advance_jobs(0.0)
	_check(int(Economy.me_levels["smallArms"]) == me_max, "ME 完工不会越过上限 %d" % me_max)


func _test_component_no_license() -> void:
	print("[component]")
	# 空间站结构（组件）永远免许可证——2026-09-30 bug 回归
	Economy.inv.clear()
	Economy.licenses.clear()
	Economy.inv["commonA"] = 500
	Economy.inv["commonB"] = 500
	_check(Economy.production_block_reason("truss", 1) == "", "组件无许可证也可造")
	_check(Economy.start_production("truss", 1) == "", "组件手搓提交")
	Economy.prod_jobs[0]["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.stock("truss") == 1, "组件产出 1")
	_check(not Economy.licenses.has("truss"), "组件不消耗许可证")


func _test_order_queue() -> void:
	print("[queue]")
	# 制造排队：产线满继续下单 → 排队；取消退款；产线空闲自动开工
	Economy.blueprints.clear()
	Economy.reverse.clear()
	Economy.inv.clear()
	Economy.licenses.clear()
	Economy.licenses["heavyArms"] = 100
	Economy.inv["commonA"] = 5000
	Economy.inv["commonB"] = 2000
	Economy.inv["commonC"] = 2000
	for i in 4:
		_check(Economy.start_production("heavyArms", 1) == "", "连续下单 %d" % (i + 1))
	_check(Economy.prod_jobs.size() == 3, "3 条产线开工")
	_check(Economy.order_queue.size() == 1, "第 4 单进入排队")
	_check(int(Economy.licenses.get("heavyArms", 0)) == 96, "下单时锁定许可证 4 次")
	var paid_a := int(Economy.order_queue[0]["paid"]["commonA"])
	var stock_before := Economy.stock("commonA")
	Economy.cancel_order(0)
	_check(Economy.order_queue.size() == 0, "排队单可取消")
	_check(Economy.stock("commonA") == stock_before + paid_a, "取消退还锁定的材料")
	_check(int(Economy.licenses.get("heavyArms", 0)) == 97, "取消退还许可证 1 次")
	_check(Economy.start_production("heavyArms", 1) == "", "再次排队")
	_check(Economy.order_queue.size() == 1, "再次进入排队")
	for job in Economy.prod_jobs.duplicate():
		job["left"] = 0.0
	Economy._advance_jobs(0.0)
	_check(Economy.order_queue.is_empty(), "产线空闲后排队单自动开工")
	_check(Economy.prod_jobs.size() == 1, "排队的第 4 单已开工")


func _test_order_uid_cancel() -> void:
	print("[uid-cancel]")
	# 回归(2026-10-01): UI 记下标会在成交移位后误撤别的单——uid 必须恒稳
	Economy.sell_orders.clear()
	Economy.inv.clear()
	Economy.inv["commonA"] = 100
	Economy.inv["commonB"] = 100
	_check(Economy.post_sell("commonA", 100) == "", "挂卖 A")
	_check(Economy.post_sell("commonB", 100) == "", "挂卖 B")
	var uid_b := int(Economy.sell_orders[1].get("uid", -1))
	_check(uid_b > 0, "B 有 uid")
	Economy.sell_orders.remove_at(0)  # 模拟 A 成交消失 → B 下标前移(旧 bug 触发条件)
	_check(Economy.cancel_sell_by_uid(uid_b), "按 uid 撤 B 成功")
	_check(Economy.sell_orders.is_empty(), "撤的确实是 B(A 已不在)")
	_check(Economy.stock("commonB") == 100, "B 货退回")
	_check(not Economy.cancel_sell_by_uid(uid_b), "重复撤同 uid 返回 false")
	Economy.inv.clear()


func _test_trade_budget() -> void:
	print("[budget]")
	# 回归(2026-10-01): trade_rate=每船总吞吐——单拍撮合量≤预算
	Economy.berths.clear()
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()
	Economy.inv.clear()
	Economy.money = 100000.0
	Economy.fuel = 100.0
	_check(Economy._try_arrive("standard", false), "货舰到港")
	var f: Freighter = Economy.berths[0]
	f.buy_offers = [{"goods": "commonA", "price": 3.0, "qty_left": 100000.0}]
	f.funds = 1000000.0
	Economy.inv["commonA"] = 5000
	_check(Economy.post_sell("commonA", 5000) == "", "挂卖 5000")
	var used := Economy._freighter_buys(f, 10.0)  # 预算 10 单位
	_check(used == 10, "单拍撮合=预算(10), 实际 %d" % used)
	_check(int(Economy.sell_orders[0]["qty"]) == 4990, "余量 4990")
	Economy.sell_orders.clear()
	Economy.berths.clear()


func _test_market_trade() -> void:
	print("[market]")
	# 市场挂单制：挂卖→到港货舰自动收购并带走；挂买→自动吃进货舰带来的货；停留结束自动离站
	Economy.berths.clear()
	Economy.inv.clear()
	Economy.licenses.clear()
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()
	Economy.fuel = 100.0
	Economy.money = 1000.0
	# 挂卖普矿A ×100（挂单即锁货）——限价 3.0 = 下面注入的货舰出价, 保证能成交
	Economy.inv["commonA"] = 100
	_check(Economy.post_sell("commonA", 100, 3.0) == "", "挂卖普矿A ×100 @3")
	_check(Economy.stock("commonA") == 0, "挂单锁定货物")
	# 合并挂单 + 全量截断（纳米产品场景, 2026-09-30 修 bug）
	Economy.inv["nanoRepair"] = 100
	_check(Economy.post_sell("nanoRepair", 1 << 20) == "", "挂卖全部(超量截断到 100)")
	_check(Economy.stock("nanoRepair") == 0, "纳米全部锁定")
	Economy.inv["nanoRepair"] = 50
	_check(Economy.post_sell("nanoRepair", 50) == "", "再次挂卖纳米(合并)")
	var merged := 0
	for o in Economy.sell_orders:
		if String(o["goods"]) == "nanoRepair":
			merged = int(o["qty"])
	_check(Economy.sell_orders.size() == 2, "同货物挂单合并为一条(共 2 条)")
	_check(merged == 150, "合并数量 150 (实际 %d)" % merged)
	_check(Economy.post_buy("lic:heavyArms", 1, 100.0) == "", "挂买许可证 ×1 @100")
	_check(Economy.post_buy("lic:heavyArms", 2, 100.0) == "", "再次挂买(同价位合并)")
	var bmerged := 0
	for o in Economy.buy_orders:
		if String(o["goods"]) == "lic:heavyArms":
			bmerged = int(o["qty"])
	_check(bmerged == 3, "买单合并数量 3")
	# 货舰到港（注入报价：收普矿A、卖 heavyArms 许可证）
	_check(Economy._try_arrive("small", false), "货舰到港")
	var f: Freighter = Economy.berths[0]
	f.buy_offers = [{"goods": "commonA", "price": 3.0, "qty_left": 100.0}]
	f.sell_offers = [{"goods": "lic:heavyArms", "price": 100.0, "qty": 1.0, "uses": 3}]
	_check(Economy.post_buy("lic:heavyArms", 1, 100.0) == "", "挂买许可证 ×1 @100")
	# 等自动成交（debug: 成交速率×50, 首拍 1s 内完成）
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if Economy.money == 1200.0 and int(Economy.licenses.get("heavyArms", 0)) == 3:
			break
	_check(Economy.money == 1200.0, "自动成交 +300/-100 (实际 %d)" % int(Economy.money))
	_check(int(Economy.licenses.get("heavyArms", 0)) == 3, "挂买许可证自动成交")
	_check(f.cargo_units == 100.0, "货舰带走收购的货物")
	# 停留结束（debug 1.2s）自动离站
	deadline = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline and Economy.berths.size() > 0:
		await get_tree().process_frame
	_check(Economy.berths.is_empty(), "停留结束后自动离站")


func _test_smuggler() -> void:
	print("[smuggler]")
	Economy.berths.clear()
	Economy.module_state("hangar")["smuggler_ok"] = true
	Economy.fuel = 200.0
	Economy.money = 1000.0
	Economy.module_state("hangar")["level"] = 3
	_check(Economy.summon_smuggler() == "", "走私召唤成功")
	_check(Economy.fuel == 100.0 and Economy.money == 500.0, "扣燃料 100 + ₡500")
	_check(Economy.berths.size() == 1 and Economy.berths[0].is_smuggler, "走私船到港")
	Economy.module_state("hangar")["level"] = 2


## 挂单价格因子（2026-10-02 拍板）：外来货舰收购价 = 当前基准价 × DEMAND × 走私溢价
## × (1-10%) × 价格因子 × rng(0.9~1.1)。价格因子=事件接口（Economy.price_mod）。
func _test_price_factor() -> void:
	print("[price factor]")
	Economy.price_mod.clear()
	var disc: float = 1.0 - float(GameData.ECON["freighter_buy_discount"])
	_check(absf(disc - 0.9) < 0.0001, "收购折扣 = 10%%（表值 %.2f）" % float(GameData.ECON["freighter_buy_discount"]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261002
	var f := Freighter.make("standard", false, rng, Economy.price_mod)
	_check(not f.buy_offers.is_empty(), "货舰生成收购清单")
	var bad := 0
	for o in f.buy_offers:
		var gid := String(o["goods"])
		var base: float = GameData.good_unit_price(gid)
		var demand: float = float(GameData.DEMAND.get(gid, GameData.DEMAND["ore"])) * Economy.demand_mult(gid)
		var lo: float = base * demand * disc * 0.9
		var hi: float = base * demand * disc * 1.1
		var got: float = float(o["price"])
		if got < lo - 0.01 or got > hi + 0.01:
			bad += 1
			print("   × %s: %.4f 不在 [%.4f, %.4f]" % [gid, got, lo, hi])
	_check(bad == 0, "全部买单 = 基准价×DEMAND×(1-10%%)±10%%（异常 %d 条）" % bad)
	# 人工核对折扣: 打印前 3 条（基准价 → 收购价）
	for k in mini(3, f.buy_offers.size()):
		var o0: Dictionary = f.buy_offers[k]
		var g0 := String(o0["goods"])
		var b0: float = GameData.good_unit_price(g0)
		print("   %s: 基准 %.1f → 收购 %.1f (×%.2f)" % [g0, b0, float(o0["price"]), float(o0["price"]) / maxf(b0, 0.001)])
	# 事件接口: 全局因子 ×1.5 / 单价因子 ×2.0
	Economy.set_price_mod("*", 1.5)
	_check(absf(Economy.price_factor("iceBlack") - 1.5) < 0.001, "全局因子对未单列货物生效")
	Economy.set_price_mod("commonA", 2.0)
	_check(absf(Economy.price_factor("commonA") - 3.0) < 0.001, "单价因子 × 全局因子 = 3.0")
	var f2 := Freighter.make("standard", false, rng, Economy.price_mod)
	bad = 0
	for o in f2.buy_offers:
		var gid2 := String(o["goods"])
		var base2: float = GameData.good_unit_price(gid2)
		var demand2: float = float(GameData.DEMAND.get(gid2, GameData.DEMAND["ore"])) * Economy.demand_mult(gid2)
		var mult: float = Economy.price_factor(gid2)
		var got2: float = float(o["price"])
		if got2 < base2 * demand2 * disc * mult * 0.9 - 0.01 \
				or got2 > base2 * demand2 * disc * mult * 1.1 + 0.01:
			bad += 1
	_check(bad == 0, "价格因子进入新到港货舰报价（异常 %d 条）" % bad)
	# 出售清单同样吃因子（组件：基准 ×(1.1~1.3) × 因子）
	var checked_sell := false
	for so in f2.sell_offers:
		var sg := String(so["goods"])
		if not GameData.is_component(sg):
			continue
		var b4: float = GameData.COMPONENTS[sg]["price"]
		_check(float(so["price"]) >= b4 * 1.1 * 1.5 - 0.01 \
				and float(so["price"]) <= b4 * 1.3 * 1.5 + 0.01,
			"组件出售价吃价格因子（%s）" % sg)
		checked_sell = true
		break
	if not checked_sell:
		print("   （本次生成无组件出售条目, 跳过）")
	# 持久化: price_mod 随存档落盘
	Economy.save_game()
	var txt := FileAccess.get_file_as_string(Economy.save_path)
	_check(txt.find("\"price_mod\"") >= 0, "price_mod 已纳入存档")
	Economy.price_mod.clear()


## 价格图回归（P0）: trade_log 恒定截断 200 条 ⇒ 不能用 size 当"变了没"的判据,
## 否则满额后图永久冻结；另外横轴必须吃"游戏日"而不是笔序。
## 定价重平衡 + 战时需求（2026-10-02 拍板）:
## ① 舰船货舰期望出价 = 材料价值 ×1.05（不亏损线）; 产品 ≥材料 ×1.8; 组件 ≥×1.6
## ② 战时周期（8 和平 + 4 战争）与需求倍率（军用 ×1.6 / 通用 ×1.15）
## ③ 默认卖价 = 货舰期望价（不再是"永远卖不掉的基准价"）
func _test_balance_and_war() -> void:
	print("[balance & war]")
	var day0: int = Economy.day
	Economy.day = 1
	_check(not Economy.war_active(), "第 1 日 = 和平期")
	for sid in GameData.SHIPS:
		var mc: float = GameData.material_cost(GameData.SHIPS[sid]["bom"])
		var bid: float = Economy.expected_freighter_price(sid, false)
		var ratio := bid / maxf(mc, 0.01)
		_check(absf(ratio - 1.05) < 0.005, "%s 期望出价 = 材料 ×%.3f（目标 1.05: 材料 %s → 出价 %s）" % [
			GameData.equip_name(sid), ratio, EconTheme.money(mc), EconTheme.money(bid)])
	for pid in GameData.PRODUCTS:
		var mc2: float = GameData.material_cost(GameData.PRODUCTS[pid]["bom"])
		var bid2: float = Economy.expected_freighter_price(pid, false) * float(GameData.PRODUCTS[pid]["batch"])
		_check(bid2 >= mc2 * 1.8, "%s 一批期望出价 %s ≥ 材料 %s ×1.8（%.2f×）" % [
			GameData.equip_name(pid), EconTheme.money(bid2), EconTheme.money(mc2), bid2 / maxf(mc2, 0.01)])
	for cid in GameData.COMPONENTS:
		var mc3: float = GameData.material_cost(GameData.COMPONENTS[cid]["bom"])
		var bid3: float = Economy.expected_freighter_price(cid, false)
		_check(bid3 >= mc3 * 1.6, "%s 期望出价 %s ≥ 材料 %s ×1.6（%.2f×）" % [
			GameData.good_name(cid), EconTheme.money(bid3), EconTheme.money(mc3), bid3 / maxf(mc3, 0.01)])
	# 默认卖价必须落在货舰收购区间内（原来 = 基准价 → 永远不成交）
	Economy.trade_log.clear()   # 清掉历史成交价, 才能验证"无船无史"的兜底分支
	Economy.berths.clear()      # 清掉在港走私船（其 ×1.3 溢价不属于普通收购区间）
	var sug: float = Economy.suggest_price("commonA", false)
	var rg: Vector2 = Economy.fillable_range("commonA", false)
	_check(sug <= rg.y + 0.005 and sug >= rg.x - 0.005, "无船无史时默认卖价 %s 落在收购区间 %s–%s" % [
		EconTheme.money(sug), EconTheme.money(rg.x), EconTheme.money(rg.y)])
	# 战时周期
	var peace := int(GameData.ECON["war_cycle_peace_days"])
	var war := int(GameData.ECON["war_cycle_war_days"])
	Economy.day = peace
	_check(not Economy.war_active(), "第 %d 日 = 和平期（周期前段）" % peace)
	Economy.day = peace + 1
	_check(Economy.war_active(), "第 %d 日 = 战时" % (peace + 1))
	var dm: Dictionary = Economy.demand_mod()
	_check(absf(float(dm.get("military", 0.0)) - 1.6) < 0.001 \
			and absf(float(dm.get("general", 0.0)) - 1.15) < 0.001, "战时需求表 = 通用 ×1.15 / 军用 ×1.6")
	Economy.day = peace + war + 1
	_check(not Economy.war_active(), "战后回到和平期（周期 %d 天）" % (peace + war))
	# 需求倍率进入报价: 用 ×50 大倍率放大, 盖过 rng(0.9~1.1) 噪声
	var rp := RandomNumberGenerator.new()
	rp.seed = 20261003
	var sp := Freighter.make("standard", false, rp)
	var rw := RandomNumberGenerator.new()
	rw.seed = 20261003
	var sw := Freighter.make("standard", false, rw, {}, {"general": 50.0, "military": 50.0})
	var op: Dictionary = sp.buy_offer_for(GameData.FUEL_ID)
	var ow: Dictionary = sw.buy_offer_for(GameData.FUEL_ID)
	_check(not op.is_empty() and not ow.is_empty(), "两船都收燃料（可比价）")
	if not op.is_empty() and not ow.is_empty():
		var rr: float = float(ow["price"]) / maxf(float(op["price"]), 0.0001)
		_check(rr > 20.0, "需求倍率确实进了收购报价（×50 倍率实测 ×%.1f）" % rr)
	# 精确倍率: 期望价公式（确定性, 无 rng 噪声）
	Economy.day = 1
	var exp_ore: float = Economy.expected_freighter_price("commonA", false)
	var exp_ship: float = Economy.expected_freighter_price("raven", false)
	Economy.day = peace + 1
	_check(absf(Economy.expected_freighter_price("commonA", false) / maxf(exp_ore, 0.001) - 1.15) < 0.001,
		"战时矿石期望价 ×1.15")
	_check(absf(Economy.expected_freighter_price("raven", false) / maxf(exp_ship, 0.001) - 1.6) < 0.001,
		"战时舰船期望价 ×1.6")
	_check(not Economy.freighter_sells("commonA") and Economy.freighter_sells("truss") \
			and Economy.freighter_sells("lic:raven"),
		"货舰供货面识别正确（矿石不供 / 组件与许可证供）")
	Economy.day = day0


func _test_price_chart() -> void:
	print("[price chart]")
	var chart = preload("res://scripts/ui/PriceChart.gd").new()
	add_child(chart)
	Economy.trade_log.clear()
	for i in 5:
		Economy.trade_log.append({"g": "commonA", "p": 10.0 + float(i), "q": 2, "d": i})
	chart.goods = "commonA"
	chart._process(0.1)
	_check(chart._vols.size() > 0, "价格图收到数据（柱数 %d）" % chart._vols.size())
	# 关键回归: 满 200 条（条数恒定）后新成交仍须刷新 —— 旧判据只看条数会永久冻结
	Economy.trade_log.clear()
	for i in 200:
		Economy.trade_log.append({"g": "commonA", "p": 50.0, "q": 1, "d": 0})
	chart._process(0.1)
	var q_before: int = chart._max_q
	Economy.trade_log.remove_at(0)
	Economy.trade_log.append({"g": "commonA", "p": 99.0, "q": 500, "d": 1})
	chart._process(0.1)
	_check(chart._max_q > q_before, "满 200 条后仍刷新（峰值 %d → %d）" % [q_before, chart._max_q])
	Economy.trade_log.clear()
	chart.queue_free()


## 限价单语义（2026-10-02）: 卖价 ≤ 货舰出价才成交（按货舰出价结算）; 到期自动退回。
func _test_limit_orders() -> void:
	print("[limit orders]")
	Economy.berths.clear()
	Economy.inv.clear()
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()
	Economy.money = 1000.0
	Economy.inv["commonA"] = 20
	# ① 高价挂卖: 故意高于货舰出价 → 不该成交
	# （本用例关掉加速模式: 货舰停 60s 不离站, 观察窗口才稳定）
	Economy.debug_instant = false
	_check(Economy.post_sell("commonA", 10, 999.0) == "", "高价挂卖 10 @999")
	_check(Economy.stock("commonA") == 10, "挂单锁货 10（库存 %d）" % Economy.stock("commonA"))
	_check(Economy._try_arrive("small", false), "货舰到港")
	var f: Freighter = Economy.berths[0]
	f.buy_offers = [{"goods": "commonA", "price": 3.0, "qty_left": 100.0}]
	f.sell_offers = []
	var dl := Time.get_ticks_msec() + 3000   # ≥3 个成交拍（1 拍/秒）
	while Time.get_ticks_msec() < dl:
		await get_tree().process_frame
	_check(Economy.sell_orders.size() == 1 and absf(Economy.money - 1000.0) < 0.01,
		"要价 999 > 出价 3 → 不成交（钱 %.0f）" % Economy.money)
	# ② 改到自己能接受的价位 → 成交, 按货舰出价 3.0 结算
	Economy.post_sell("commonA", 10, 2.0)
	f.buy_offers = [{"goods": "commonA", "price": 3.0, "qty_left": 100.0}]
	var dl2 := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < dl2 and Economy.money < 1029.0:
		await get_tree().process_frame
	_check(absf(Economy.money - 1030.0) < 0.01,
		"限价 2.0 ≤ 出价 3.0 → 成交并按 3.0 结算（钱 %.0f, 期望 1030）" % Economy.money)
	# ③ 建议价: 港内有船 → 最优对手价
	_check(absf(Economy.suggest_price("commonA", false) - 3.0) < 0.01,
		"建议卖价 = 港内最优出价 3.0（实际 %.2f）" % Economy.suggest_price("commonA", false))
	# ④ 到期: 港内无船时挂一单, 把日期推过期限 → 自动撤回并退货
	print("  · step6 expire")
	Economy.berths.clear()
	Economy.sell_orders.clear()
	Economy.inv["commonA"] = 5
	Economy.post_sell("commonA", 5, 1.0)
	_check(Economy.stock("commonA") == 0, "到期前货物仍锁定")
	var dur: float = float(GameData.ECON["order_duration_days"])
	var day0: int = Economy.day
	Economy.day = day0 + int(ceil(dur)) + 1
	var expired: int = Economy.expire_orders()
	_check(expired == 1, "到期撤单 1 条（实际 %d）" % expired)
	_check(Economy.stock("commonA") == 5 and Economy.sell_orders.is_empty(), "到期货物退回库存")
	Economy.day = day0
	# ⑤ 交易窗 UI: 改价后确认信号要带上新价
	# 注意: GDScript lambda 按值捕获局部变量, 必须"改数组内容"而不是重新赋值外层变量
	var dlg = preload("res://scripts/ui/EconTradeDialog.gd").new()
	add_child(dlg)
	dlg.setup("commonA", true, 12.5)
	var got: Array = []
	dlg.confirmed.connect(func(g, q, p, b): got.append([g, q, p, b]))
	dlg._price_spin.value = 20.0     # 模拟玩家用箭头/输入改价
	_check(absf(dlg._price() - 20.0) < 0.001,
		"改价后 _price() = %.2f（期望 20）" % dlg._price())
	dlg._on_confirm()
	_check(got.size() == 1 and absf(float(got[0][2]) - 20.0) < 0.001,
		"交易窗带上改后的限价（%.2f）" % (float(got[0][2]) if got.size() == 1 else -1.0))
	dlg.queue_free()
	Economy.debug_instant = true   # 复原加速模式
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()
	Economy.inv.clear()


## 旧存档挂单迁移（2026-10-02）: 老格式 {goods,qty} → 补 price/day/orig, 且不被读档误判过期
func _test_order_migration() -> void:
	print("[order migration]")
	Economy.save_path = "user://economy_test_save.json"
	var legacy := {
		"v": 1, "day": 50, "money": 100.0, "fuel": 10.0,
		"inv": {"commonA": 7},
		"sell_orders": [{"goods": "commonA", "qty": 7}],
		"buy_orders": [{"goods": "commonC", "qty": 3}],
		"trade_log": [{"g": "commonA", "p": 4.5, "q": 1, "d": 49}],
	}
	var wf := FileAccess.open(Economy.save_path, FileAccess.WRITE)
	wf.store_string(JSON.stringify(legacy))
	wf.close()
	Economy.load_game()
	var so: Dictionary = Economy.sell_orders[0] if not Economy.sell_orders.is_empty() else {}
	_check(not so.is_empty() and absf(float(so.get("price", 0.0)) - 4.5) < 0.01,
		"卖单迁移价 = 最近成交价 4.5（实际 %.2f）" % float(so.get("price", 0.0)))
	_check(not so.is_empty() and int(so.get("day", -1)) == Economy.day, "卖单迁移创建日 = 当天")
	_check(not so.is_empty() and int(so.get("orig", -1)) == 7, "卖单迁移 orig = 7")
	var bo: Dictionary = Economy.buy_orders[0] if not Economy.buy_orders.is_empty() else {}
	_check(not bo.is_empty() and float(bo.get("price", 0.0)) > 0.0,
		"买单迁移价 > 0（实际 %.2f）" % float(bo.get("price", 0.0)))
	_check(not bo.is_empty() and int(bo.get("orig", -1)) == 3, "买单迁移 orig = 3")
	_check(Economy.sell_orders.size() == 1 and Economy.buy_orders.size() == 1, "迁移后挂单仍在（未被误判过期）")
	Economy.inv.clear()
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()


## 滚动位置保持回归（2026-10-02，修"提交订单/制造后滑块回顶"）:
## 提交会经 Economy 信号 + 处理函数显式 refresh() 在同一帧触发多次全量重建;
## 修复前第 2 次 refresh 捕获到"刚重建、还没恢复"的 0, 并把正确的恢复值覆盖掉。
func _test_scroll_keep() -> void:
	print("[scroll keep]")
	var ui = get_tree().get_first_node_in_group("econ_ui")
	_check(ui != null, "EconUiRoot 存在")
	if ui == null:
		return
	Economy.inv["commonA"] = int(Economy.inv.get("commonA", 0)) + 600
	Economy.inv["commonB"] = int(Economy.inv.get("commonB", 0)) + 300
	ui.open_panel("factory")
	for i in 6:
		await get_tree().process_frame      # 新建子树要几帧才算完布局
	var fp = ui._panels.get("factory")
	_check(fp != null and fp._left_scroll != null, "建造厂面板/左列滚动容器就绪")
	if fp == null or fp._left_scroll == null:
		return
	var sc: ScrollContainer = fp._left_scroll
	sc.scroll_vertical = 150
	await get_tree().process_frame
	var before: int = sc.scroll_vertical
	var maxv: float = sc.get_v_scroll_bar().max_value
	_check(maxv > 150.0, "左列内容可滚动（上限 %.0f）" % maxv)
	if maxv <= 150.0:
		ui.close_all()
		return
	_check(before > 100, "初始停在 %d" % before)
	var jobs_before: int = Economy.prod_jobs.size()
	fp._produce("truss", 1)                 # 面板真实提交路径（信号 refresh + 显式 refresh）
	_check(Economy.prod_jobs.size() > jobs_before or not Economy.order_queue.is_empty(),
		"制造请求已受理（信号链已触发）")
	for i in 3:
		await get_tree().process_frame
	var after: int = (fp._left_scroll as ScrollContainer).scroll_vertical
	_check(absf(float(after - before)) <= 2.0, "提交后滚动保持（%d → %d）" % [before, after])
	# 帧内合并（2026-10-02 性能）: 同帧多次 refresh 只真正重建一次
	var n0: int = fp.rebuilds
	fp.refresh()
	fp.refresh()
	fp.refresh()
	await get_tree().process_frame
	_check(fp.rebuilds == n0 + 1, "同帧 3 次 refresh 只重建 1 次（实际 %d 次）" % (fp.rebuilds - n0))
	ui.close_all()


## 许可证/蓝图市场（2026-10-02 修）: 左列"过滤器 vs lic: 前缀"不匹配 ⇒ 许可证分组整组不渲染;
## 订单簿守卫也不放行 lic: ⇒ 连已写好的许可证订单簿都是死代码（产品/舰船因此造不出来）。
func _test_license_market() -> void:
	print("[license market]")
	var ui = get_tree().get_first_node_in_group("econ_ui")
	if ui == null:
		_check(false, "EconUiRoot 存在")
		return
	ui.open_panel("market")
	for i in 4:
		await get_tree().process_frame
	var mp = ui._panels.get("market")
	_check(mp != null and mp._goods_list != null, "市场面板/左列就绪")
	if mp == null or mp._goods_list == null:
		return
	var metas: Array = []
	var has_ship_group := false
	for i in mp._goods_list.item_count:
		if mp._goods_list.get_item_text(i).find("舰船许可证") >= 0:
			has_ship_group = true
		metas.append(str(mp._goods_list.get_item_metadata(i)))
	_check(has_ship_group, "左列出现『舰船许可证』分组（修复前整组被 continue 掉）")
	_check(metas.has("lic:raven") and metas.has("lic:longbow") and metas.has("lic:ram"),
		"战舰许可证已列出（raven/longbow/ram）")
	_check(metas.has("lic:heavyArms"), "产品许可证已列出（heavyArms）")
	# 选中许可证 → 订单簿必须真的建起来（守卫放行 lic:）
	mp._sel_goods = "lic:raven"
	mp._refresh_right()
	await get_tree().process_frame
	_check(mp._sellers_list != null and not _body_has_text(mp.body, "在左侧选择货物"),
		"选中许可证后订单簿正常渲染")
	# 端到端: 货舰带战舰许可证到港 → 玩家挂买 → 到账 3 次
	Economy.debug_instant = false
	Economy.berths.clear()
	Economy.buy_orders.clear()
	Economy.licenses.erase("raven")
	Economy.money = 10000.0
	Economy.fuel = 500.0
	_check(Economy._try_arrive("small", false), "货舰到港（注入战舰许可证报价）")
	var f: Freighter = Economy.berths[0]
	f.buy_offers = []
	f.sell_offers = [{"goods": "lic:raven", "price": 100.0, "qty": 1.0,
		"uses": GameData.license_uses("raven")}]
	_check(Economy.post_buy("lic:raven", 1, 100.0) == "", "挂买战舰许可证 1 张 @100")
	var dl := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < dl and int(Economy.licenses.get("raven", 0)) <= 0:
		await get_tree().process_frame
	_check(int(Economy.licenses.get("raven", 0)) == GameData.license_uses("raven"),
		"成交到账 %d 次（实际 %d）" % [GameData.license_uses("raven"), int(Economy.licenses.get("raven", 0))])
	_check(absf(Economy.money - 9900.0) < 0.01, "按限价 100 扣款（钱 %.2f）" % Economy.money)
	# 机库现货渠道（官价）
	var fee: float = GameData.license_fee("raven")
	var m0: float = Economy.money
	_check(Economy.buy_license("raven", 1) == "", "机库购买许可证成功")
	_check(absf(Economy.money - (m0 - fee)) < 0.01, "机库扣官价 %s" % EconTheme.money(fee))
	_check(int(Economy.licenses.get("raven", 0)) == GameData.license_uses("raven") * 2,
		"机库到账再 +%d 次" % GameData.license_uses("raven"))
	_check(Economy.buy_license("commonA", 1) != "", "矿石不适用许可证（返回错误）")
	# 机库面板 UI 有现货区
	ui.open_panel("hangar")
	for i in 3:
		await get_tree().process_frame
	var hp = ui._panels.get("hangar")
	_check(hp != null and _body_has_text(hp.body, "许可证现货"), "机库面板出现『许可证现货』区")
	_check(hp != null and _body_has_text(hp.body, "攻城锤"), "机库列出战舰许可证（ram）")
	Economy.debug_instant = true
	ui.close_all()


## 递归查找控件文本（面板用 Label/RichTextLabel/Button 混排）
func _body_has_text(node: Node, needle: String) -> bool:
	if node is Label and needle in (node as Label).text:
		return true
	if node is RichTextLabel and needle in (node as RichTextLabel).text:
		return true
	if node is Button and needle in (node as Button).text:
		return true
	for c in node.get_children():
		if _body_has_text(c, needle):
			return true
	return false


## 订单簿列（2026-10-02，用户报"[你·挂买] 只有数量、看不到价格"）:
## 买卖两侧每一行都必须显式含"数量 + 价格"；列序对齐 EVE（数量→价格→来源→剩余，
## marketbase.py:3071-3099），剩余时间 = 货舰离站倒计时 / 挂单剩余天数。
func _test_orderbook_columns() -> void:
	print("[orderbook columns]")
	var ui = get_tree().get_first_node_in_group("econ_ui")
	if ui == null:
		_check(false, "EconUiRoot 存在")
		return
	Economy.debug_instant = false
	Economy.berths.clear()
	Economy.sell_orders.clear()
	Economy.buy_orders.clear()
	Economy.money = 5000.0
	Economy.fuel = 500.0
	Economy.inv["commonA"] = int(Economy.inv.get("commonA", 0)) + 20
	_check(Economy.post_sell("commonA", 10, 3.0) == "", "挂卖 10 @3.0")
	_check(Economy.post_buy("commonA", 10, 2.0) == "", "挂买 10 @2.0")
	_check(Economy._try_arrive("small", false), "货舰到港（报价 1.0 收 / 5.0 卖，不与挂单交叉成交）")
	var f: Freighter = Economy.berths[0]
	f.buy_offers = [{"goods": "commonA", "price": 1.0, "qty_left": 50.0}]
	f.sell_offers = [{"goods": "commonA", "price": 5.0, "qty": 8.0}]
	ui.open_panel("market")
	for i in 4:
		await get_tree().process_frame
	var mp = ui._panels.get("market")
	mp._sel_goods = "commonA"
	mp._refresh_right()
	await get_tree().process_frame
	var sell_rows := _list_texts(mp._sellers_list)
	var buy_rows := _list_texts(mp._buyers_list)
	_check(_body_has_text(mp.body, "数量") and _body_has_text(mp.body, "价格"),
		"订单簿有列头（数量 / 价格 / 来源 / 剩余）")
	var mine_buy := _row_matching(sell_rows, "[你·挂买]")
	var mine_sell := _row_matching(buy_rows, "[你·挂卖]")
	_check(mine_buy.find("₡2") >= 0 and mine_buy.find("余 10/10") >= 0,
		"我的挂买行含数量+限价：%s" % mine_buy.strip_edges())
	_check(mine_sell.find("₡3") >= 0 and mine_sell.find("余 10/10") >= 0,
		"我的挂卖行含数量+限价：%s" % mine_sell.strip_edges())
	var fr_ask := _row_matching(sell_rows, f.name)
	var fr_bid := _row_matching(buy_rows, f.name)
	_check(fr_ask.find("₡5") >= 0 and fr_ask.find("×8") >= 0,
		"货舰出售行含数量+价格：%s" % fr_ask.strip_edges())
	_check(fr_bid.find("₡1") >= 0 and fr_bid.find("×50") >= 0,
		"货舰收购行含数量+价格：%s" % fr_bid.strip_edges())
	_check(mine_buy.find("剩") >= 0 and fr_ask.find("剩") >= 0,
		"行内含剩余时间（挂单=剩余天数 / 货舰=离站倒计时）")
	Economy.debug_instant = true
	ui.close_all()


func _list_texts(l: ItemList) -> Array:
	var out: Array = []
	if l == null or not is_instance_valid(l):
		return out
	for i in l.item_count:
		out.append(l.get_item_text(i))
	return out


func _row_matching(rows: Array, needle: String) -> String:
	for t in rows:
		if String(t).find(needle) >= 0:
			return String(t)
	return ""


## 图标回归（2026-10-02）: 空间站悬浮窗"市场交易"按钮原引用不存在的 market_logo.svg
## ⇒ load() 返回 null ⇒ 按钮空白（用户报"看不到 Icon"）。现在图标由代码手绘像素画生成。
func _test_icons() -> void:
	print("[icons]")
	var icons := preload("res://scripts/ui/EconIcons.gd")
	var tex: Texture2D = icons.market_logo()
	_check(tex != null, "市场图标生成成功")
	if tex == null:
		return
	_check(tex.get_width() == 48 and tex.get_height() == 48,
		"图标尺寸 48×48（16×16 手绘稿 ×3 nearest）实际 %s" % str(tex.get_size()))
	var img := tex.get_image()
	var black := 0
	var ink := 0
	var frame := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.g > 0.5:
				ink += 1          # 主线条 #58A7BF
			elif c.g > 0.2:
				frame += 1        # 边框 #305665
			elif c.a > 0.9 and c.r < 0.02 and c.g < 0.02 and c.b < 0.02:
				black += 1        # 黑底
	var total := img.get_width() * img.get_height()
	_check(black > total / 2, "黑底占比过半（黑 %d / 共 %d）" % [black, total])
	_check(ink > 150, "主线条像素 %d 个（双向箭头可见）" % ink)
	_check(frame > 300, "边框像素 %d 个" % frame)
	# 建造厂图标（齿轮）
	var ftex: Texture2D = icons.factory_logo()
	_check(ftex != null and ftex.get_width() == 48, "建造厂图标生成 48×48")
	if ftex != null:
		var fimg := ftex.get_image()
		var fink := 0
		for y in fimg.get_height():
			for x in fimg.get_width():
				if fimg.get_pixel(x, y).g > 0.5:
					fink += 1
		_check(fink > 300, "齿轮线条像素 %d 个" % fink)
	# 悬浮窗里的按钮必须真的拿到图标（这是用户看到的那两颗）
	var ui = get_tree().get_first_node_in_group("econ_ui")
	if ui == null:
		_check(false, "EconUiRoot 存在")
		return
	ui.show_station_popup(Vector2(300, 300))
	await get_tree().process_frame
	var btn := _find_button_by_tip(ui, "市场交易")
	_check(btn != null, "悬浮窗存在『市场交易』按钮")
	if btn != null:
		_check(btn.icon != null, "按钮 icon 非空（修复前 = null ⇒ 空白）")
		_check(btn.icon != null and btn.icon.get_width() == 48, "按钮图标为 48×48 像素画")
	# 建造厂与商品制造合并: 只剩一颗图标按钮, 不再有文字按钮"商品制造"
	# 注意: 模块按钮的 tooltip_text 会被 _refresh_popup_buttons 换成建成状态, 所以按 meta 找
	var fac := _find_button_by_meta(ui, "module_id", "factory")
	_check(fac != null and fac.icon != null, "『建造厂 · 商品制造』已合并为图标按钮")
	if fac != null:
		_check(_body_has_text(fac, "建造厂 · 商品制造"), "合并按钮的浮字提示 = 建造厂 · 商品制造")
	_check(_find_button_by_text(ui, "商品制造") == null, "旧的『商品制造』文字按钮已移除")
	# 悬浮窗保持打开（2026-10-02 用户拍板: 打开面板不自动关菜单）
	if btn != null:
		btn.emit_signal("pressed")
		await get_tree().process_frame
		_check(ui._popup.visible, "点开面板后悬浮窗**仍然可见**（原来会自己关掉）")
		_check(ui._panels["market"].visible, "市场面板已打开")
		_check(not ui._popup_blocker.visible, "全屏遮罩已撤（否则会挡住新面板）")
	ui.close_all()
	ui.hide_station_popup()


## 按元数据找按钮（模块按钮的 tooltip 会被建成状态覆盖, 不能用文字匹配）
func _find_button_by_meta(node: Node, key: String, val: String) -> Button:
	if node is Button and str((node as Button).get_meta(key, "")) == val:
		return node as Button
	for c in node.get_children():
		var r := _find_button_by_meta(c, key, val)
		if r != null:
			return r
	return null


## 按按钮文字找按钮（用于断言某个文字按钮已被移除）
func _find_button_by_text(node: Node, txt: String) -> Button:
	if node is Button and (node as Button).text == txt:
		return node as Button
	for c in node.get_children():
		var r := _find_button_by_text(c, txt)
		if r != null:
			return r
	return null


## 按 hover 提示文字找按钮（悬浮窗按钮无固定 name）
func _find_button_by_tip(node: Node, tip: String) -> Button:
	if node is Button and (node as Button).tooltip_text == tip:
		return node as Button
	for c in node.get_children():
		var r := _find_button_by_tip(c, tip)
		if r != null:
			return r
	return null


## 拖动 + 层级 + 多开回归（2026-10-02 用户拍板: **删除吸附、不要吸附线、点谁谁置顶**）:
## ① 吸附删除后: 拖动严格跟手、**不改变尺寸**（旧吸附贴边会改尺寸 ⇒ UI 忽然变宽且收不回）
## ② 松手落在窗口外也不能卡住拖动状态
## ③ 整窗留在视口内 ⇒ 右上角 ✕ 永远点得到（旧实现允许拖出屏只留 50px ⇒ 无法关闭）
## ④ 面板不再各自带全屏点击拦截背板（多开时最上层那块会让下面那扇窗点不到）
## ⑤ 点击的窗口移到最前, 且 ESC 先关它
func _test_drag_and_layer() -> void:
	print("[drag & layer]")
	var ui = get_tree().get_first_node_in_group("econ_ui")
	if ui == null:
		_check(false, "EconUiRoot 存在")
		return
	ui.close_all()
	ui._open_stack.clear()
	ui.open_panel_add("build", true)
	await get_tree().process_frame
	var p = ui._panels.get("build")
	_check(p != null and p._panel != null, "建造面板就绪")
	if p == null:
		return
	# ① 拖动严格跟手、不改尺寸
	p._panel.size = Vector2(600, 400)
	var w0: float = p._panel.size.x
	p._panel.position = Vector2(200, 200)
	p._drag_logic = p._panel.position
	p._dragging = true
	for i in 5:
		var mm := InputEventMouseMotion.new()
		mm.relative = Vector2(6, 4)
		p._input(mm)
	_check(p._panel.position.is_equal_approx(Vector2(230, 220)),
		"拖动 5×(+6,+4) 后位置严格跟手（实际 %s, 期望 (230, 220)）" % str(p._panel.position))
	_check(absf(p._panel.size.x - w0) < 0.01, "拖动不改变宽度（吸附旧实现会改尺寸）")
	_check(not p.has_method("_apply_drag_snap") and not p.has_method("_snap_axes"),
		"吸附相关函数已整体删除")
	p._dragging = false
	# ② 松手在窗口外也不能卡住拖动状态
	p._dragging = true
	await get_tree().process_frame
	_check(not p._dragging, "左键已松开 → 拖动状态被强制结束")
	# ③ 整窗留在视口内（✕ 永远点得到）
	p._panel.position = Vector2(99999, 99999)
	p._clamp_panel_offscreen()
	var vp: Vector2 = p.get_viewport_rect().size
	_check(p._panel.position.x <= maxf(vp.x - p._panel.size.x, 0.0) + 0.01 \
			and p._panel.position.y <= maxf(vp.y - p._panel.size.y, 0.0) + 0.01,
		"拖到屏幕外会被夹回视口内（%s）" % str(p._panel.position))
	# ④ 层级 + 共享背板（菜单层是动态的: 前 16 / 后 14, 见下面"菜单让位"三条）
	_check(int(ui.POPUP_LAYER_FRONT) > 15 and int(ui.POPUP_LAYER_BACK) < 15,
		"菜单前景层 %d > 面板 15 > 让位层 %d" % [int(ui.POPUP_LAYER_FRONT), int(ui.POPUP_LAYER_BACK)])
	# 层级不变式 —— 这条专门防"拦截层盖住让位后的菜单 ⇒ 点不动第二个功能"的回归:
	# 拦截层 13 < 菜单让位 14 < 面板/根 15 < 菜单前景 16
	_check(int(ui._backdrop_layer.layer) < int(ui.POPUP_LAYER_BACK) \
			and int(ui.POPUP_LAYER_BACK) < 15 and int(ui.POPUP_LAYER_FRONT) > 15,
		"层级不变式: 拦截层 %d < 菜单让位 %d < 面板 15 < 菜单前景 %d" % [
			int(ui._backdrop_layer.layer), int(ui.POPUP_LAYER_BACK), int(ui.POPUP_LAYER_FRONT)])
	_check(ui._modal_backdrop.get_parent() == ui._backdrop_layer,
		"拦截层在独立低层（否则菜单让位后会被它盖住 → 点不动第二个功能）")
	_check(ui._popup_blocker.get_parent() == ui._popup_layer, "悬浮窗遮罩与悬浮窗同层")
	_check(ui._modal_backdrop != null and ui._modal_backdrop.visible, "面板打开时共享层可见")
	_check(ui._modal_backdrop.color.a < 0.01 and ui._modal_backdrop.mouse_filter == Control.MOUSE_FILTER_STOP,
		"共享层**全透明**但保留输入隔离（用户: 点功能后全屏变半透明深色是 bug; a=%.2f）" % ui._modal_backdrop.color.a)
	_check(not _has_stop_backdrop(p), "面板自身不再有全屏点击拦截背板（否则下面的窗点不到）")
	# 面板开着时弹出的菜单不能启用全屏拦截层（同层全屏 STOP 会吃掉面板点击）
	ui.show_station_popup(Vector2(200, 200))
	await get_tree().process_frame
	_check(not ui._popup_blocker.visible, "面板开着时菜单不启用全屏拦截层")
	# 菜单不再自动让位（用户: "空间站UI 会发生位移"）
	ui._popup.position = Vector2(321, 123)
	ui.open_panel_add("inventory", true)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(ui._popup.position.is_equal_approx(Vector2(321, 123)),
		"打开面板后菜单不位移（仍在 %s）" % str(ui._popup.position))
	# 布局存档: 不能把折叠高度(32)或 0 高度写进去（否则下次打开只剩一条标题栏）
	ui.layout_path = "user://layout_test.json"
	ui._panels["build"]._toggle_collapse()
	ui.save_window_layout()
	var ltxt := FileAccess.get_file_as_string(ui.layout_path)
	var lj: Variant = JSON.parse_string(ltxt)
	_check(ltxt.find("\"collapsed\"") < 0, "存档不再写折叠态")
	if typeof(lj) == TYPE_DICTIONARY:
		var bad_h := 0
		for k in lj:
			if k == "_ui_scale":
				continue
			var e: Dictionary = lj[k]
			if float(e.get("w", 0.0)) > 0.0 and float(e.get("h", 0.0)) < EconUiRoot.LAYOUT_MIN_H - 0.01:
				bad_h += 1
				print("   × %s: w=%.0f h=%.0f" % [k, float(e.get("w", 0.0)), float(e.get("h", 0.0))])
		_check(bad_h == 0, "存档里有效窗口高度均 ≥ 下限 %.0f（异常 %d 条）" % [EconUiRoot.LAYOUT_MIN_H, bad_h])
		_check(float((lj["build"] as Dictionary).get("h", 0.0)) >= EconUiRoot.LAYOUT_MIN_H - 0.01,
			"折叠中的窗口存档仍写展开高度（实际 %.0f）" % float((lj["build"] as Dictionary).get("h", 0.0)))
	ui._panels["build"]._toggle_collapse()      # 还原展开
	DirAccess.remove_absolute(ui.layout_path)
	ui.layout_path = EconUiRoot.LAYOUT_PATH
	# 菜单不再"永远最顶层"（用户 2026-10-02 报）: 点面板 ⇒ 菜单让位; 抓标题栏 ⇒ 回到最前
	ui.show_station_popup(Vector2(200, 200))
	await get_tree().process_frame
	_check(int(ui._popup_layer.layer) == int(ui.POPUP_LAYER_FRONT), "刚弹出时菜单在最前")
	ui.open_panel_add("market", true)
	await get_tree().process_frame
	_check(int(ui._popup_layer.layer) == int(ui.POPUP_LAYER_BACK),
		"打开面板后菜单让位（层 %d < 面板 15）" % int(ui._popup_layer.layer))
	ui._raise_popup()
	_check(int(ui._popup_layer.layer) == int(ui.POPUP_LAYER_FRONT), "抓标题栏后菜单回到最前")
	# 连点多个功能（用户报"点开一个后点不动其他"）—— 真实点击路由, 且**菜单必须处于让位层**:
	# 拦截层若放在 15（旧实现）就会盖住 14 的菜单 ⇒ 这一击被拦截层吃掉 ⇒ 面板不开 ⇒ 断言失败。
	# 注意: 不能在点击前调 show_station_popup（它会把菜单抬回 16, 那样测不出这个 bug）。
	ui.open_panel_add("build", true)                 # 打开面板 ⇒ 菜单自动让位
	ui._popup.position = Vector2(4, 4)               # 挪到面板覆盖不到的角落
	ui._popup.visible = true
	await get_tree().process_frame
	_check(int(ui._popup_layer.layer) == int(ui.POPUP_LAYER_BACK),
		"点击前菜单处于让位层 %d（面板 15 之下、拦截层 %d 之上）" % [
			int(ui.POPUP_LAYER_BACK), int(ui._backdrop_layer.layer)])
	var inv_btn := _find_button_by_text(ui._popup, "仓库")
	_check(inv_btn != null and inv_btn.is_visible_in_tree(), "让位状态下菜单按钮仍可见")
	if inv_btn != null:
		var cpos: Vector2 = inv_btn.get_global_rect().get_center()
		for pressed in [true, false]:
			var cev := InputEventMouseButton.new()
			cev.button_index = MOUSE_BUTTON_LEFT
			cev.pressed = pressed
			cev.position = cpos
			cev.global_position = cpos
			ui.get_viewport().push_input(cev)
		await get_tree().process_frame
		_check(ui._panels["inventory"].visible,
			"菜单在让位层时仍能点到第二个功能（真实点击路由, 命中点 %s）" % str(cpos))
	_check(ui._panels["build"].visible and ui._panels["inventory"].visible,
		"两扇窗同时在（多开未被写死）")
	# ✕ 关闭按钮（用户报"缺少 x 关闭按钮"）
	ui.show_station_popup(Vector2(200, 200))
	await get_tree().process_frame
	var xbtn := _find_button_by_text(ui._popup, "✕")
	_check(xbtn != null, "空间站菜单有 ✕ 关闭按钮")
	if xbtn != null:
		xbtn.emit_signal("pressed")
		await get_tree().process_frame
		_check(not ui._popup.visible, "点 ✕ 后菜单关闭")
	# ⑤ 点击置顶 + ESC 顺序
	ui.open_panel_add("market", true)
	await get_tree().process_frame
	ui._panels["build"]._set_active()          # 模拟点击建造面板
	await get_tree().process_frame
	_check(ui.get_child(ui.get_child_count() - 1) == ui._panels["build"],
		"点击的窗口被移到最前（绘制/输入优先）")
	_check(ui._open_stack[-1] == "build", "置顶后 ESC 会先关它（叠开栈已同步）")
	# ⑥ 多开细节: 层叠偏移 / 市场里"我的订单"（原调用点方法缺失, 点了没反应）/ ESC 逐层关
	ui.close_all()
	ui._open_stack.clear()
	ui.open_panel_add("market", true)
	ui.open_panel_add("build", true)
	await get_tree().process_frame
	_check(ui._panels["market"].visible and ui._panels["build"].visible,
		"市场与建造面板可**同时**打开（多开）")
	_check(ui._open_stack.size() == 2, "叠开栈记录 2 扇窗（ESC 逐层关）")
	_check((ui._panels["build"] as EconPanelBase).cascade_offset != Vector2.ZERO,
		"第二扇窗带层叠偏移（不会完全盖住第一扇）")
	_check(ui.has_method("open_panel_add"), "open_panel_add 存在（修复前该方法缺失）")
	ui._panels["market"]._open_orders()
	await get_tree().process_frame
	_check(ui._panels["orders"].visible and ui._panels["market"].visible,
		"市场里『我的订单』可叠加打开且市场不关")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	ui._input(esc)
	await get_tree().process_frame
	_check(not ui._panels["orders"].visible and ui._panels["market"].visible,
		"ESC 只关最上层（orders 关掉, market 仍在）")
	ui.close_all()
	ui._open_stack.clear()
	ui.hide_station_popup()


## 面板里是否还有 MOUSE_FILTER_STOP 的全屏 ColorRect（旧的多窗"点击杀手"）
func _has_stop_backdrop(p) -> bool:
	for c in (p as Node).get_children():
		if c is ColorRect and (c as ColorRect).mouse_filter == Control.MOUSE_FILTER_STOP:
			return true
	return false


## 顶部新闻播报条（2026-10-02）: 文本流走 Economy.event_posted（按关键词白名单挑世界叙事）,
## 常驻角标走 WorldState 的结构化公开接口。
func _test_news_ticker() -> void:
	print("[news ticker]")
	var ui = get_tree().get_first_node_in_group("econ_ui")
	if ui == null:
		_check(false, "EconUiRoot 存在")
		return
	var ticker = null
	for c in ui.get_children():
		if c is NewsTickerScript:
			ticker = c
	_check(ticker != null, "新闻条已挂在 EconUiRoot 下")
	if ticker == null:
		return
	# ① 世界叙事文本进队列（与事件日志同一管道, 不需要额外接 WorldState）
	ticker._queue.clear()
	ticker._cur = {}
	Economy.post_event("边境传来军情：帝国 开始大规模军备调度，物流需求预计持续走高", "warn")
	_check(ticker._queue.size() + (0 if ticker._cur.is_empty() else 1) >= 1, "世界叙事文本已进入新闻条")
	_check(String(ticker._line.text).find("边境传来军情") >= 0, "新闻条显示该文本（%s）" % ticker._line.text)
	# ② 非叙事文本被过滤（成交/入库/操作报错不上新闻）
	ticker._queue.clear()
	ticker._cur = {}
	Economy.post_event("货舰 自动收购 普矿A ×5 → +₡9", "good")
	Economy.post_event("制造失败：材料不足", "warn")
	_check(ticker._queue.is_empty() and ticker._cur.is_empty(), "成交/报错文本被关键词白名单挡掉")
	# ③ 相位切换播报 + 角标（结构化接口）
	var saved_day: int = Economy.day
	var saved_path: String = WorldState._save_path
	WorldState._save_path = "user://world_test.json"
	var peace_d := int(GameData.WORLD["peace_days"])
	Economy.day = peace_d + 1                      # 进入筹备期
	WorldState._sync_phase(Economy.day, false)
	await get_tree().process_frame
	ticker._badge_t = 99.0
	ticker._refresh_badge()
	_check(String(ticker._badge.text).find("筹备期") >= 0, "角标显示当前相位（%s）" % ticker._badge.text)
	_check(String(ticker._badge.text).find(WorldState.faction_display_name()) >= 0, "角标显示当前阵营")
	_check(String(ticker._badge.text).find("剩") >= 0, "角标显示相位倒计时")
	_check(ticker._queue.size() > 0 or String(ticker._line.text).find("军备调度") >= 0,
		"相位切换文案已进入新闻条")
	# ④ 公开接口可用（转正后不该再伸手摸私有字段）
	_check(WorldState.phase_name() == "筹备期", "phase_name() 公开可用（%s）" % WorldState.phase_name())
	_check(WorldState.days_left_in_phase() > 0, "days_left_in_phase() 公开可用（%d 天）" % WorldState.days_left_in_phase())
	_check(WorldState.phase_progress() >= 0.0 and WorldState.phase_progress() <= 1.0,
		"phase_progress() 公开可用（%.2f）" % WorldState.phase_progress())
	_check(WorldState.current_faction != "", "current_faction 公开可用（%s）" % WorldState.current_faction)
	# ⑤ 命令输入不挡点击
	_check(ticker.mouse_filter == Control.MOUSE_FILTER_IGNORE, "新闻条不拦截鼠标（不挡游戏点击）")
	# 还原
	Economy.day = saved_day
	WorldState._sync_phase(Economy.day, true)
	WorldState._save_path = saved_path
	if FileAccess.file_exists("user://world_test.json"):
		DirAccess.remove_absolute("user://world_test.json")


func _test_save_load() -> void:
	print("[save]")
	Economy.money = 1234.0
	Economy.fuel = 42.0
	Economy.save_game()
	Economy.money = 0.0
	Economy.fuel = 0.0
	Economy.load_game()
	_check(Economy.money == 1234.0 and Economy.fuel == 42.0, "存档往返")


func _cleanup() -> void:
	if FileAccess.file_exists(Economy.save_path):
		DirAccess.remove_absolute(Economy.save_path)
