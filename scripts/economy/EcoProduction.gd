extends Node
## EcoProduction —— 制造产线 + 研究站 + 许可证/逆向研究（Economy 门面拆分子模块, 2026-10-14）。
## 完工入 MissionOps 装备库的直通逻辑（is_equip）原样保留。
## 跨域（钱包扣料/库存查询/信号）一律走 eco.* 门面调用。

var eco: Node  # Economy 门面

var licenses := {}       # equip -> 剩余次数
var reverse := {}        # equip -> 逆向等级
var blueprints := {}     # equip -> true（已获原图）
var me_levels := {}      # equip -> ME 等级
var te_levels := {}      # equip -> TE 等级
var prod_jobs: Array = []        # 制造作业 {kind,equip,batches,total,left,uses_license}
var order_queue: Array = []      # 制造排队订单 {equip,batches,uses_license,paid}（产线满时排队, 可取消退款）
var research_jobs: Array = []    # 研究作业 {kind,equip,total,left}


func buy_license(equip: String, count := 1) -> String:
	if count <= 0:
		return "数量无效"
	if not (GameData.PRODUCTS.has(equip) or GameData.SHIPS.has(equip)):
		return "该装备不需要许可证"
	var total: float = GameData.license_fee(equip) * float(count)
	if eco.money < total:
		return "资金不足（需 %s）" % EconTheme.money(total)
	eco.try_spend(total)
	var uses := GameData.license_uses(equip) * count
	licenses[equip] = int(licenses.get(equip, 0)) + uses
	eco.licenses_changed.emit()
	eco.market_changed.emit()
	eco.post_event("机库购入 %s 许可证 ×%d（+%d 次）" % [GameData.equip_name(equip), count, uses], "good")
	return ""


func factory_count() -> int:
	return eco.module_count("factory")


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
	return t / 100.0 if eco.debug_instant else t


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
		if eco.stock(id) < per:
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
	eco.pay(cost)
	# 许可证只管产品/舰船：组件不消耗许可证、也不涨逆向（2026-09-30 修 bug）
	# MVP: MissionOps 装备(is_equip)免许可证——基础装备直接造(船长令 2026-10-05)
	# 排队制下许可证在下单时锁定扣除、取消时退还（完工只涨逆向）
	var is_mission_equip2: bool = GameData.PRODUCTS.has(equip) and GameData.PRODUCTS[equip].get("is_equip", false)
	var uses_license := not is_mission_equip2 and not blueprints.has(equip) and not GameData.is_component(equip)
	if uses_license:
		licenses[equip] = int(licenses.get(equip, 0)) - batches
		if int(licenses[equip]) <= 0:
			licenses.erase(equip)
		eco.licenses_changed.emit()
	order_queue.append({"equip": equip, "batches": batches, "uses_license": uses_license, "paid": cost})
	_pump_orders()
	eco.jobs_changed.emit()
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
	eco._refund(order["paid"])
	if order["uses_license"]:
		var equip: String = order["equip"]
		licenses[equip] = int(licenses.get(equip, 0)) + int(order["batches"])
		eco.licenses_changed.emit()
	eco.jobs_changed.emit()


## 推进制造+研究作业（原 Economy._advance_jobs 的前两段）。返回本拍是否有完工。
func advance(delta: float) -> bool:
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
	return dirty


func _finish_production(job: Dictionary) -> void:
	var equip: String = job["equip"]
	var batches: int = job["batches"]
	# MVP: MissionOps 装备完工 → 入 MissionOps 库存(非 Economy.inv)
	if GameData.PRODUCTS.has(equip) and GameData.PRODUCTS[equip].get("is_equip", false):
		var mo := eco.get_node_or_null("/root/MissionOps")
		if mo:
			mo.grant_equipment(equip, batches)
			eco.post_event("%s 制造完成 ×%d → 已入探索装备库" % [GameData.good_name(equip), batches], "good")
			eco.jobs_changed.emit()
			return
	if GameData.is_component(equip):
		eco.inv[equip] = int(eco.inv.get(equip, 0)) + batches
	elif GameData.is_product(equip):
		eco.inv[equip] = int(eco.inv.get(equip, 0)) + GameData.PRODUCTS[equip]["batch"] * batches
	else:
		eco.inv[equip] = int(eco.inv.get(equip, 0)) + batches
	eco.inventory_changed.emit()
	if job["uses_license"] and not GameData.is_component(equip):
		# 许可证已在下单时扣除；完工只涨逆向等级
		var lv := int(reverse.get(equip, 0)) + batches
		var mx := GameData.reverse_max(equip)
		if lv > mx:
			lv = mx
		if lv != int(reverse.get(equip, 0)):
			reverse[equip] = lv
			eco.research_changed.emit()
			if lv >= mx:
				eco.post_event("%s 逆向研究已满级，可在研究站研制原图！" % GameData.equip_name(equip), "good")
	eco.post_event("生产完成：%s ×%d" % [GameData.good_name(equip), batches], "good")
	_pump_orders()  # 产线空出 → 立即开工下一张排队单


# ================= 研究站 =================

func research_slots() -> int:
	var lv: int = eco.module_level("research")
	if lv <= 0:
		return 0
	return int(GameData.MODULES["research"]["levels"][lv - 1]["slots"])


func research_speed() -> float:
	var lv: int = eco.module_level("research")
	if lv <= 0:
		return 0.0
	return float(GameData.MODULES["research"]["levels"][lv - 1]["speed"])


func research_block_reason(kind: String, equip: String) -> String:
	if eco.module_level("research") <= 0:
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
	if eco.debug_instant:
		t /= 100.0
	t /= float(GameData.ECON["build_speed_mult"])
	research_jobs.append({"kind": kind, "equip": equip, "total": t, "left": t})
	eco.jobs_changed.emit()
	return ""


func _finish_research(job: Dictionary) -> void:
	var equip: String = job["equip"]
	match job["kind"]:
		"blueprint":
			blueprints[equip] = true
			eco.post_event("逆向完成！获得原图蓝图：%s（免许可费生产）" % GameData.equip_name(equip), "good")
		"me":
			var me_max := int(GameData.RESEARCH["me_max"])
			var me_new: int = mini(int(me_levels.get(equip, 0)) + 1, me_max)   # 并行作业可能已推到上限
			if me_new != int(me_levels.get(equip, 0)):
				me_levels[equip] = me_new
				eco.post_event("材料研究 ME +%d → %s（材料 -%d%%）" % [
					me_levels[equip], GameData.equip_name(equip),
					me_levels[equip] * int(GameData.RESEARCH["me_pct"] * 100)], "good")
		"te":
			var te_max := int(GameData.RESEARCH["te_max"])
			var te_new: int = mini(int(te_levels.get(equip, 0)) + 1, te_max)
			if te_new != int(te_levels.get(equip, 0)):
				te_levels[equip] = te_new
				eco.post_event("建造研究 TE +%d → %s（工期 -%d%%）" % [
					te_levels[equip], GameData.equip_name(equip),
					te_levels[equip] * int(GameData.RESEARCH["te_pct"] * 100)], "good")
	eco.research_changed.emit()
