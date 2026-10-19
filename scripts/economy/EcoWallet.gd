extends Node
## EcoWallet —— 钱包/燃料/库存（Economy 门面拆分子模块, 2026-10-14）。
## 拆分纪律（全子模块通用）：
## - 对外 API 全部留在 Economy.gd 门面，外部（UI/WorldState/MissionOps/测试）不得直接引用本模块
## - 信号全部声明在门面上，这里经 eco.<signal>.emit() 发射
## - 跨域状态一律 eco.<转发属性> 现取现用，禁止在 _ready 缓存兄弟模块的容器引用
##   （load_game 会整体重赋值门面属性，缓存引用会指向旧字典）

var eco: Node  # Economy 门面（故意不标类型，避免 preload 成环）

var money := 0.0
var fuel := 0.0          # 燃料单位（1 燃料冰矿 = 1 燃料）
var inv := {}            # 货物id(矿/组件/产品/舰船) -> 数量


## BeltFlow 送达钩子：asset = 矿石 GLB 资产名
func deliver_ore(asset: String, amount: int) -> void:
	var id := GameData.asset_to_ore(asset)
	if id == "":
		return
	var value := EconTheme.money(GameData.ORES[id]["price"] * amount)
	if id == GameData.FUEL_ID:
		fuel += amount
		eco.fuel_changed.emit()
		eco.post_event("燃料冰矿 +%d · 估值 %s（燃料库存 %d）" % [amount, value, int(fuel)], "good")
		return
	inv[id] = int(inv.get(id, 0)) + amount
	eco.inventory_changed.emit()
	if id in GameData.RARE_IDS:
		eco.post_event("稀有矿入库：%s ×%d · 估值 %s" % [GameData.good_name(id), amount, value], "rare")
	else:
		eco.post_event("%s ×%d 入库 · 估值 %s" % [GameData.good_name(id), amount, value], "good")


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
	eco.fuel_changed.emit()
	eco.inventory_changed.emit()
	return true


func try_spend(v: float) -> bool:
	if money < v:
		return false
	money -= v
	eco.money_changed.emit()
	return true


func add_money(v: float) -> void:
	money += v
	eco.money_changed.emit()


func _refund(cost: Dictionary) -> void:
	for id in cost:
		if id == GameData.FUEL_ID:
			fuel += float(cost[id])
		else:
			inv[id] = int(inv.get(id, 0)) + int(cost[id])
	eco.fuel_changed.emit()
	eco.inventory_changed.emit()
