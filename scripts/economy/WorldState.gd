extends Node

## 世界系统 M1 —— 局部冲突状态机（帝国 vs 南方联盟）。
## 范围见 docs/世界系统路线图.md：单站点、单条主线；冻结多站扩张/自动化；
## 10 小国与 20 托拉斯只留数据骨架（GameData.WORLD_FACTIONS 以后扩表），不接入模拟。
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

var _current_faction := "empire"
var _save_path := "user://world_state_save.json"


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
			_current_faction = "empire" if cycle_index % 2 == 0 else "southern"
			stockpile = 0.0
			Economy.post_event("边境传来军情：%s 开始大规模军备调度，物流需求预计持续走高" % \
				String(GameData.WORLD_FACTIONS[_current_faction]["name"]), "warn")
		Phase.WAR:
			war_initial_stockpile = maxf(stockpile, 1.0)
			Economy.post_event("局部冲突爆发：%s 当面开战——军需订单短期内暴涨" % \
				String(GameData.WORLD_FACTIONS[_current_faction]["name"]), "warn")
	phase_changed.emit(_phase_name(new_phase))


func _phase_name(p: int) -> String:
	match p:
		Phase.BUILDUP:
			return "筹备期"
		Phase.WAR:
			return "开战期"
	return "和平期"


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


## 当前相位已经走了多久（0~1）——用来拉"筹备期临近开战、调度越来越密集"的曲线
func _phase_progress(day: int) -> float:
	var pos := (day - 1) % maxi(_cycle_len(), 1)
	var peace_d := int(GameData.WORLD["peace_days"])
	var buildup_d := int(GameData.WORLD["buildup_days"])
	var war_d := int(GameData.WORLD["war_days"])
	if pos < peace_d:
		return float(pos) / maxf(float(peace_d), 1.0)
	elif pos < peace_d + buildup_d:
		return float(pos - peace_d) / maxf(float(buildup_d), 1.0)
	return float(pos - peace_d - buildup_d) / maxf(float(war_d), 1.0)


## 当前相位还剩几天结束——dealer 的 dwell_override 用它换算成秒
func _days_left_in_phase(day: int) -> int:
	var pos := (day - 1) % maxi(_cycle_len(), 1)
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
			var p := _phase_progress(Economy.day)
			return lerpf(float(GameData.WORLD["freighter_mult_buildup_lo"]),
				float(GameData.WORLD["freighter_mult_buildup_hi"]), p)
		Phase.WAR:
			return float(GameData.WORLD["freighter_mult_war"])
	return float(GameData.WORLD["freighter_mult_peace"])


# ================= 补给效率占位（星图落地前用三档顶替，调用方接口不变） =================

func supply_efficiency(_faction_id: String) -> float:
	return float(GameData.STATION_EFFICIENCY.get(GameData.STATION_REGION, 0.5))


# ================= 玩家反哺：Economy 广播的军需品实际成交 =================

func _on_military_sale(_goods_id: String, qty: int, price: float) -> void:
	if phase != Phase.BUILDUP:
		return  # 开战期是消耗阶段不是反哺阶段（M1 拍板：战争节奏先走固定时长，见路线图）
	var eff := supply_efficiency(_current_faction)
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
	f.name = "军需采购团·%s" % String(GameData.WORLD_FACTIONS[_current_faction]["name"])
	f.cap = 1000000000.0   # 概念上是"off-screen 的大批采购船团"，不受单船舱位限制
	f.funds = float(GameData.WORLD["dealer_funds"])
	f.dwell_override = maxf(float(_days_left_in_phase(Economy.day)), 0.2) * Economy.day_length()
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
	dealer.dwell_override = maxf(float(_days_left_in_phase(day)), 0.2) * Economy.day_length()
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
	if phase == Phase.BUILDUP:
		return lerpf(0.3, 1.0, _phase_progress(Economy.day))
	if phase == Phase.WAR:
		var intensity: float = war_initial_stockpile / float(GameData.WORLD["stockpile_target"])
		var remaining_frac: float = stockpile / maxf(war_initial_stockpile, 1.0)
		return maxf(intensity, 0.1) * lerpf(0.4, 1.0, remaining_frac)
	return 0.0


# ================= 轻量独立存档（不碰 Economy 的存档结构，降低改动风险） =================

func _save() -> void:
	var data := {
		"stockpile": stockpile,
		"war_initial_stockpile": war_initial_stockpile,
		"current_faction": _current_faction,
	}
	var file := FileAccess.open(_save_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load() -> void:
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
	_current_faction = String(parsed.get("current_faction", "empire"))


## 测试/调试钩子：清空世界系统状态（配合 Economy.debug_reset 在测试里一起调）
func debug_reset() -> void:
	phase = Phase.PEACE
	stockpile = 0.0
	war_initial_stockpile = 0.0
	_current_faction = "empire"
	_despawn_dealer("")
	if FileAccess.file_exists(_save_path):
		DirAccess.remove_absolute(_save_path)
