extends Node

## 世界系统 M1+M2 —— 局部冲突状态机（帝国 vs 南方联盟）+ 10 小国静态阵营/倒戈。
## 范围见 docs/世界系统路线图.md：单站点、只有一条主线在跑状态机（10 小国不会自己
## 单独开战线，只会在 empire/southern 之间倒戈）；20 托拉斯仍保持中立，冻结到 M5；
## 多站点扩张/自动化仍冻结到 M4。
##
## 节奏（2026-10-02 拍板）：和平 60 天 → 筹备 30 天 → 开战 10 天 → 循环往复。
## 相位纯按 Economy.day 推导（跟 Economy.war_active() 的周期写法同一个思路，不占存档字段）；
## 只有"物资积累" stockpile 是真正需要持久化的状态——玩家/背景经济的反哺是非确定性的，
## 没法靠天数反推复原，所以单独存一个轻量 json（不碰 Economy 的存档结构，降低改动风险）。
##
## 对外两个输出：
## ① freighter_frequency_mult() —— Economy._roll_visit_schedule() 读取，影响货舰来访频率。
## ② "发牌员"订单墙 —— 筹备/开战期间常驻一艘特殊货舰(dealer)，用阶梯买单模拟"总量庞大、
##    玩家只吃得到其中一小份"的军需采购需求；价格先做"当前参考价附近小幅抖动"（低成本版，
##    2026-10-02 拍板，后续按实测手感再调整抖动曲线/是否改用真实深度曲线）。

signal phase_changed(phase_name: String)
signal stockpile_changed(value: float, target: float)

enum Phase { PEACE, BUILDUP, WAR }

var phase: int = Phase.PEACE
var stockpile := 0.0              # 筹备期累积 / 开战期剩余（起点 0，不设硬上限）
var war_initial_stockpile := 0.0  # 开战瞬间快照的总量，决定这场战争的烈度规模
var dealer: Freighter = null
var rng := RandomNumberGenerator.new()

var current_faction := "empire"
var _save_path := "user://world_state_save.json"

## M2：10 小国当前阵营归属（fid -> "empire"/"southern"）。初始值来自
## GameData.MINOR_FACTIONS，倒戈事件会原地改写，随 _save()/_load() 持久化。
var _minor_bloc: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	rng.randomize()
	_load()
	Economy.day_changed.connect(_on_day_changed)
	Economy.military_goods_sold.connect(_on_military_sale)
	# 读档可能是在某个相位中途进来的：先对齐 phase，不重复播报事件
	_sync_phase(Economy.day, true)


func _on_day_changed(day: int) -> void:
	_sync_phase(day, false)
	match phase:
		Phase.BUILDUP:
			stockpile += _background_daily_gain()
			stockpile_changed.emit(stockpile, float(GameData.WORLD["stockpile_target"]))
		Phase.WAR:
			var burn: float = war_initial_stockpile / maxf(float(GameData.WORLD["war_days"]), 1.0)
			stockpile = maxf(0.0, stockpile - burn)
			stockpile_changed.emit(stockpile, maxf(war_initial_stockpile, 1.0))
		Phase.PEACE:
			pass
	if phase == Phase.BUILDUP or phase == Phase.WAR:
		_ensure_dealer()
		_refresh_dealer(day)
	else:
		_despawn_dealer("和平期，采购团撤离")
	_save()


# ================= 相位切换 =================

## 纯函数推导"现在应该处于哪个相位"；切换时触发一次性事件播报。
## initial=true 用于读档/启动首帧对齐状态，不重复播报。
func _sync_phase(day: int, initial: bool) -> void:
	var new_phase := _phase_for_day(day)
	if new_phase == phase and not initial:
		return
	phase = new_phase
	if initial:
		return
	_enter_phase(new_phase)


func _enter_phase(new_phase: int) -> void:
	match new_phase:
		Phase.PEACE:
			if war_initial_stockpile > 0.0:
				var scale: float = war_initial_stockpile / float(GameData.WORLD["stockpile_target"])
				var flavor := "小规模边境摩擦" if scale < 0.6 else ("局部冲突" if scale < 1.2 else "大规模会战")
				Economy.post_event("边境战事平息（%s）——市场需求回落至日常基线" % flavor, "info")
			stockpile = 0.0
			war_initial_stockpile = 0.0
		Phase.BUILDUP:
			var cycle_index := (Economy.day - 1) / maxi(_cycle_len(), 1)
			current_faction = "empire" if cycle_index % 2 == 0 else "southern"
			stockpile = 0.0
			_roll_minor_defections()
			_roll_minor_friction()
			Economy.post_event("边境传来军情：%s 开始大规模军备调度，物流需求预计持续走高" % \
				String(GameData.WORLD_FACTIONS[current_faction]["name"]), "warn")
		Phase.WAR:
			war_initial_stockpile = maxf(stockpile, 1.0)
			Economy.post_event("局部冲突爆发：%s 当面开战——军需订单短期内暴涨" % \
				String(GameData.WORLD_FACTIONS[current_faction]["name"]), "warn")
	phase_changed.emit(phase_name(new_phase))


## 相位名（公开接口, 2026-10-02 转正给新闻条/角标用）。p < 0 时用当前相位。
func phase_name(p := -1) -> String:
	var v: int = phase if p < 0 else p
	match v:
		Phase.BUILDUP:
			return "筹备期"
		Phase.WAR:
			return "开战期"
	return "和平期"


## 当前阵营显示名（公开接口, 新闻条角标用）
func faction_display_name() -> String:
	return String(GameData.WORLD_FACTIONS.get(current_faction, {}).get("name", current_faction))


# ================= 相位推导（纯函数，不占额外存档字段，和 Economy.war_active() 同一思路） =================

func _cycle_len() -> int:
	return int(GameData.WORLD["peace_days"]) + int(GameData.WORLD["buildup_days"]) + int(GameData.WORLD["war_days"])


func _phase_for_day(day: int) -> int:
	var pos := (day - 1) % maxi(_cycle_len(), 1)
	var peace_d := int(GameData.WORLD["peace_days"])
	var buildup_d := int(GameData.WORLD["buildup_days"])
	if pos < peace_d:
		return Phase.PEACE
	elif pos < peace_d + buildup_d:
		return Phase.BUILDUP
	return Phase.WAR


## 当前相位已走完的比例 0~1（公开接口; day < 0 时用今天）——UI 可画相位进度条
func phase_progress(day := -1) -> float:
	var d: int = Economy.day if day < 0 else day
	var pos := (d - 1) % maxi(_cycle_len(), 1)
	var peace_d := int(GameData.WORLD["peace_days"])
	var buildup_d := int(GameData.WORLD["buildup_days"])
	var war_d := int(GameData.WORLD["war_days"])
	if pos < peace_d:
		return clampf(float(pos) / maxf(float(peace_d), 1.0), 0.0, 1.0)
	elif pos < peace_d + buildup_d:
		return clampf(float(pos - peace_d) / maxf(float(buildup_d), 1.0), 0.0, 1.0)
	return clampf(float(pos - peace_d - buildup_d) / maxf(float(war_d), 1.0), 0.0, 1.0)


## 当前相位还剩几天（公开接口; day < 0 时用今天）——新闻条"还剩 X 天"用它
func days_left_in_phase(day := -1) -> int:
	var d: int = Economy.day if day < 0 else day
	var pos := (d - 1) % maxi(_cycle_len(), 1)
	var peace_d := int(GameData.WORLD["peace_days"])
	var buildup_d := int(GameData.WORLD["buildup_days"])
	var war_d := int(GameData.WORLD["war_days"])
	if pos < peace_d:
		return peace_d - pos
	elif pos < peace_d + buildup_d:
		return peace_d + buildup_d - pos
	return peace_d + buildup_d + war_d - pos


# ================= 输出① 货舰来访频率乘数 =================

func freighter_frequency_mult() -> float:
	match phase:
		Phase.BUILDUP:
			var p := phase_progress(Economy.day)
			return lerpf(float(GameData.WORLD["freighter_mult_buildup_lo"]),
				float(GameData.WORLD["freighter_mult_buildup_hi"]), p)
		Phase.WAR:
			return float(GameData.WORLD["freighter_mult_war"])
	return float(GameData.WORLD["freighter_mult_peace"])


# ================= 补给效率（M3：精简星图跳数衰减 × M2：盟友系数） =================

## M3：补给效率 = 距离衰减基值 × 盟友系数。距离衰减基值按"玩家站点到当面主战方核心
## sector 的跳数"算（1/(1+跳数×supply_decay_per_hop)），替换了 M2 前的 STATION_REGION
## 三档占位常量——接口签名没变，调用方（_on_military_sale/_demand_scale）不用改。
## 盟友系数沿用 M2：由 10 小国当前阵营归属算出（相对 5:5 基线每多/少一个盟友
## ±minor_ally_mult_per_nation），阵营归属一边倒，补给效率跟着一起动。
func supply_efficiency(faction_id: String) -> float:
	var core_sector := String(GameData.FACTION_CORE_SECTOR.get(faction_id, GameData.SECTOR_PLAYER))
	var hops := sector_hops(GameData.SECTOR_PLAYER, core_sector)
	var decay: float = float(GameData.WORLD["supply_decay_per_hop"])
	var base := 1.0 / (1.0 + float(hops) * decay)
	return base * _ally_mult(faction_id)


## 两个 sector 之间的最短跳数（BFS，图很小，每次现算不缓存也无妨）。
## 查不到/不连通时返回 99 兜底（当前图是连通的，正常不会触发）。
func sector_hops(from_id: String, to_id: String) -> int:
	if from_id == to_id:
		return 0
	var visited := {from_id: true}
	var queue: Array = [[from_id, 0]]
	var qi := 0
	while qi < queue.size():
		var cur: Array = queue[qi]
		qi += 1
		var node: String = cur[0]
		var dist: int = cur[1]
		for neighbor in GameData.SECTOR_EDGES.get(node, []):
			var nid := String(neighbor)
			if visited.has(nid):
				continue
			if nid == to_id:
				return dist + 1
			visited[nid] = true
			queue.append([nid, dist + 1])
	return 99


## 10 小国里当前归属 bloc 的数量（0~10）。
func ally_count(bloc: String) -> int:
	var n := 0
	for fid in _minor_bloc:
		if String(_minor_bloc[fid]) == bloc:
			n += 1
	return n


## 盟友系数：相对 5:5 基线，每多/少一个盟友 ±minor_ally_mult_per_nation，夹在
## [minor_ally_mult_min, minor_ally_mult_max] 内（当前参数下正常跑不到夹限）。
func _ally_mult(bloc: String) -> float:
	var per_nation: float = float(GameData.WORLD["minor_ally_mult_per_nation"])
	var raw := 1.0 + float(ally_count(bloc) - 5) * per_nation
	return clampf(raw, float(GameData.WORLD["minor_ally_mult_min"]), float(GameData.WORLD["minor_ally_mult_max"]))


## 初始化/重置 10 小国归属为 GameData.MINOR_FACTIONS 里的默认值。
func _init_minor_factions() -> void:
	_minor_bloc.clear()
	for fid in GameData.MINOR_FACTIONS:
		_minor_bloc[fid] = String(GameData.MINOR_FACTIONS[fid]["bloc"])


## 每次进入筹备期触发一轮：10 小国各自独立判定是否倒戈（翻转 bloc），逐条播报。
func _roll_minor_defections() -> void:
	var chance: float = float(GameData.WORLD["minor_defect_chance"])
	for fid in GameData.MINOR_FACTIONS.keys():
		if rng.randf() >= chance:
			continue
		var cur_bloc := String(_minor_bloc.get(fid, String(GameData.MINOR_FACTIONS[fid]["bloc"])))
		var new_bloc := "southern" if cur_bloc == "empire" else "empire"
		_minor_bloc[fid] = new_bloc
		Economy.post_event("边境风声：%s 倒戈——阵营由【%s】转投【%s】" % [
			String(GameData.MINOR_FACTIONS[fid]["name"]),
			String(GameData.WORLD_FACTIONS[cur_bloc]["name"]),
			String(GameData.WORLD_FACTIONS[new_bloc]["name"])], "warn")


## M3：多战线雏形——10 小国之间的局部摩擦。按 home_sector 分组，如果同一 sector 里
## 混居着归属不同 bloc 的小国，有概率擦出一次摩擦事件。目前【纯叙事】，不改任何数值
## （2026-10-06 拍板：先让玩家"看得见"多战线的影子，手感出来后再决定要不要挂效率）。
func _roll_minor_friction() -> void:
	var chance: float = float(GameData.WORLD["minor_friction_chance"])
	var by_sector: Dictionary = {}
	for fid in GameData.MINOR_FACTIONS:
		var sector := String(GameData.MINOR_FACTIONS[fid]["home_sector"])
		if not by_sector.has(sector):
			by_sector[sector] = []
		by_sector[sector].append(fid)
	for sector in by_sector:
		var fids: Array = (by_sector[sector] as Array).duplicate()
		if fids.size() < 2:
			continue
		if rng.randf() >= chance:
			continue
		fids.shuffle()
		var a := ""
		var b := ""
		for i in fids.size():
			for j in range(i + 1, fids.size()):
				var bloc_a := String(_minor_bloc.get(fids[i], ""))
				var bloc_b := String(_minor_bloc.get(fids[j], ""))
				if bloc_a != "" and bloc_a != bloc_b:
					a = fids[i]
					b = fids[j]
					break
			if a != "":
				break
		if a == "" or b == "":
			continue  # 这个 sector 里凑巧归属一致，没有摩擦对象
		Economy.post_event("局部摩擦：%s 与 %s 在【%s】发生边境冲突——双方互指对方挑衅（暂不影响补给）" % [
			String(GameData.MINOR_FACTIONS[a]["name"]),
			String(GameData.MINOR_FACTIONS[b]["name"]),
			String(GameData.SECTORS[sector]["name"])], "warn")


# ================= 玩家反哺：Economy 广播的军需品实际成交 =================

func _on_military_sale(_goods_id: String, qty: int, price: float) -> void:
	if phase != Phase.BUILDUP:
		return  # 开战期是消耗阶段不是反哺阶段（M1 拍板：战争节奏先走固定时长，见路线图）
	var eff := supply_efficiency(current_faction)
	var value: float = float(qty) * price
	stockpile += value * eff * float(GameData.WORLD["player_contrib_scale"])
	stockpile_changed.emit(stockpile, float(GameData.WORLD["stockpile_target"]))
	_save()


func _background_daily_gain() -> float:
	var target: float = float(GameData.WORLD["stockpile_target"])
	var ratio: float = float(GameData.WORLD["background_fill_ratio"])
	var days: float = maxf(float(GameData.WORLD["buildup_days"]), 1.0)
	return target * ratio / days


# ================= 输出② "发牌员"：以特殊货舰身份挂阶梯买单 =================

func _ensure_dealer() -> void:
	if dealer != null and Economy.berths.has(dealer):
		return
	dealer = null  # 旧引用可能已经因为别的原因离港，清掉陈旧引用再试
	var f := Freighter.new()
	f.is_dealer = true
	f.is_smuggler = false
	# def_id 必须给一个 StationModules.SHIP_LEN 认识的型号，否则 _spawn_ship() 里
	# SHIP_LEN[f.def_id] 查不到会崩（2026-10-02 冒烟测试炸出来的 bug）。
	# 发牌员是"大批采购船团"概念，视觉上给个 giant 船模比较贴切。
	f.def_id = "giant"
	f.name = "军需采购团·%s" % String(GameData.WORLD_FACTIONS[current_faction]["name"])
	f.cap = 1000000000.0   # 概念上是"off-screen 的大批采购船团"，不受单船舱位限制
	f.funds = float(GameData.WORLD["dealer_funds"])
	f.dwell_override = maxf(float(days_left_in_phase(Economy.day)), 0.2) * Economy.day_length()
	if not Economy.dock_special_freighter(f):
		return  # 泊位已满：先不占位，下一天 _ensure_dealer() 会再试
	dealer = f
	Economy.post_event("%s 到港——正在本地市场大举扫货" % f.name, "warn")


func _despawn_dealer(reason: String) -> void:
	if dealer == null:
		return
	if Economy.berths.has(dealer):
		Economy._depart(dealer, reason)
	dealer = null


## 每天刷新一次：续命 dwell_override（跟着"相位剩余天数"走）+ 重新生成阶梯买单。
func _refresh_dealer(day: int) -> void:
	if dealer == null or not is_instance_valid(dealer):
		return
	dealer.dwell_override = maxf(float(days_left_in_phase(day)), 0.2) * Economy.day_length()
	_refresh_dealer_offers()


## 阶梯买单：同一货物挂 dealer_tiers 档，价格围绕当前参考价小幅抖动（低成本版，2026-10-02 拍板）。
## 数量基数随"筹备期进度 / 开战期剩余比例"伸缩，制造"量在变化"的直观感；
## 舰船类军需另走一套小量级基数，不能照搬弹药/武器的大数字（否则"单站点造出 2000 艘战舰"很荒谬）。
func _refresh_dealer_offers() -> void:
	if dealer == null or not is_instance_valid(dealer):
		return
	dealer.buy_offers.clear()
	var tiers := maxi(int(GameData.WORLD["dealer_tiers"]), 1)
	var jitter: float = float(GameData.WORLD["dealer_price_jitter"])
	var scale := _demand_scale()
	for gid in GameData.MILITARY:
		var ref_price: float = Economy.suggest_price(gid, false)
		if ref_price <= 0.0:
			ref_price = GameData.good_unit_price(gid)
		var is_ship_good := GameData.is_ship(gid)
		var qty_total: float = (float(GameData.WORLD["dealer_ship_qty_base"]) if is_ship_good \
			else float(GameData.WORLD["dealer_qty_base"])) * scale
		var per_tier := maxf(qty_total / float(tiers), 1.0)
		for _t in tiers:
			var jit := rng.randf_range(-jitter, jitter)
			dealer.buy_offers.append({
				"goods": gid,
				"price": maxf(ref_price * (1.0 + jit), 0.01),
				"qty_left": per_tier,
			})


## 需求规模：筹备期随进度爬升(0.3→1.0)；开战期随"本场战争烈度 × 剩余比例"伸缩
## （供给枯竭则订单自然萎缩，呼应"后勤跟不上，战事自己偃旗息鼓"）。
func _demand_scale() -> float:
	var base := 0.0
	if phase == Phase.BUILDUP:
		base = lerpf(0.3, 1.0, phase_progress(Economy.day))
	elif phase == Phase.WAR:
		var intensity: float = war_initial_stockpile / float(GameData.WORLD["stockpile_target"])
		var remaining_frac: float = stockpile / maxf(war_initial_stockpile, 1.0)
		base = maxf(intensity, 0.1) * lerpf(0.4, 1.0, remaining_frac)
	else:
		return 0.0
	# M2：当面主战方的盟友越多，采购代理的扫货需求基数跟着放大（反之收缩）。
	return base * _ally_mult(current_faction)


# ================= 轻量独立存档（不碰 Economy 的存档结构，降低改动风险） =================

func _save() -> void:
	var data := {
		"stockpile": stockpile,
		"war_initial_stockpile": war_initial_stockpile,
		"current_faction": current_faction,
		"minor_bloc": _minor_bloc,
	}
	var file := FileAccess.open(_save_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load() -> void:
	_init_minor_factions()  # 先填默认 5:5，读档成功再按存档覆盖；没有存档就停在默认值
	if not FileAccess.file_exists(_save_path):
		return
	var file := FileAccess.open(_save_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	stockpile = float(parsed.get("stockpile", 0.0))
	war_initial_stockpile = float(parsed.get("war_initial_stockpile", 0.0))
	current_faction = String(parsed.get("current_faction", "empire"))
	var saved_bloc: Variant = parsed.get("minor_bloc", null)
	if typeof(saved_bloc) == TYPE_DICTIONARY:
		for fid in saved_bloc:
			if _minor_bloc.has(fid):
				_minor_bloc[fid] = String(saved_bloc[fid])


## 测试/调试钩子：清空世界系统状态（配合 Economy.debug_reset 在测试里一起调）
func debug_reset() -> void:
	phase = Phase.PEACE
	stockpile = 0.0
	war_initial_stockpile = 0.0
	current_faction = "empire"
	_init_minor_factions()
	_despawn_dealer("")
	if FileAccess.file_exists(_save_path):
		DirAccess.remove_absolute(_save_path)
