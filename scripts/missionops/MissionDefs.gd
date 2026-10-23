class_name MissionDefs
extends RefCounted

## MissionOps 静态定义表 M2 版(蓝图 §8 全 12 任务 / §9 舰长技能 / §15 装备)。
## 数值多为 [占位], 上线前按 §5.5/§9 校准。

# ── 难度档基础成功率(§5.2) ──
const DIFF_BASE := {"D1": 0.85, "D2": 0.75, "D3": 0.65, "D4": 0.50}

# ── 任务表(§8: 12 条;时长/奖励 [占位]) ──
const TASKS := {
	"mo_empire_patrol": {"name": "帝国委派·边境巡查", "kind": "combat", "diff": "D1", "dur_sec": 480.0,
		"ships": 2, "spec": "combat", "risk": 0.0, "ep": 6, "credits": 750,
		"desc": "协助帝国巡查争议星系。成功增加联盟怀疑 25 点，授予帝国反应装甲蓝图。",
		"equip_req": {"weapon": 1}, "faction_id": "empire", "blueprint_reward": "empireReactiveArmor"},
	"mo_alliance_patrol": {"name": "联盟委派·航线守望", "kind": "escort", "diff": "D1", "dur_sec": 480.0,
		"ships": 2, "spec": "escort", "risk": 0.0, "ep": 6, "credits": 750,
		"desc": "协助联盟巡查争议星系。成功增加帝国怀疑 25 点，授予联盟偏转矩阵蓝图。",
		"equip_req": {"defense": 1}, "faction_id": "southern", "blueprint_reward": "allianceShieldMatrix"},
	"mo_survey_ice": {
		"name": "冰带深处勘测", "kind": "survey", "diff": "D1", "dur_sec": 300.0,
		"ships": 2, "spec": "survey", "risk": 0.0,
		"ep": 5, "credits": 300, "desc": "勘测碎冰带深处,绘制矿脉草图。",
		"equip_req": {},
	},
	"mo_survey_rock": {
		"name": "砾矿带测绘", "kind": "survey", "diff": "D1", "dur_sec": 360.0,
		"ships": 2, "spec": "survey", "risk": 0.0,
		"ep": 5, "credits": 350, "desc": "测绘砾矿带地形,标记富矿点。",
		"equip_req": {},
	},
	"mo_combat_skirmish": {
		"name": "航道清剿·散匪", "kind": "combat", "diff": "D1", "dur_sec": 480.0,
		"ships": 2, "spec": "combat", "risk": 0.0,
		"ep": 6, "credits": 700, "desc": "清剿航道散匪,保障委托方航线。",
		"equip_req": {"weapon": 1},
		"route_safety_gain": 0.5,
	},
	"mo_salvage_field": {
		"name": "残骸场打捞", "kind": "salvage", "diff": "D1", "dur_sec": 600.0,
		"ships": 2, "spec": "salvage", "risk": 0.0,
		"ep": 8, "credits": 500, "desc": "打捞旧战残骸,回收可用部件。",
		"equip_req": {},
	},
	"mo_escort_probe": {
		"name": "无人探测器护送", "kind": "escort", "diff": "D2", "dur_sec": 720.0,
		"ships": 2, "spec": "escort", "risk": 0.05,
		"ep": 12, "credits": 900, "desc": "护送协会探测器穿越低安域。",
		"equip_req": {},
	},
	"mo_salvage_hulk": {
		"name": "废弃船体拆解", "kind": "salvage", "diff": "D2", "dur_sec": 900.0,
		"ships": 3, "spec": "salvage", "risk": 0.05,
		"ep": 12, "credits": 800, "desc": "拆解废弃船体,回收结构材料。",
		"equip_req": {},
	},
	"mo_signal_faint": {
		"name": "微弱深空信号", "kind": "signal", "diff": "D2", "dur_sec": 720.0,
		"ships": 2, "spec": "survey", "risk": 0.05,
		"ep": 12, "credits": 600, "desc": "追踪深空微弱信号,定位信号源。",
		"equip_req": {"elec": 1},
	},
	"mo_combat_nest": {
		"name": "匪帮窝点清除", "kind": "combat", "diff": "D3", "dur_sec": 1200.0,
		"ships": 3, "spec": "combat", "risk": 0.10,
		"ep": 25, "credits": 1800, "desc": "摧毁海盗窝点,清剿有生力量。",
		"equip_req": {"weapon": 1},
		"route_safety_gain": 1.5,
	},
	"mo_survey_deep": {
		"name": "深空星域测绘", "kind": "survey", "diff": "D3", "dur_sec": 1500.0,
		"ships": 3, "spec": "survey", "risk": 0.10,
		"ep": 25, "credits": 1200, "desc": "未测绘星域的全面勘察。",
		"equip_req": {},
	},
	"mo_escort_science": {
		"name": "科学考察护航", "kind": "escort", "diff": "D3", "dur_sec": 1800.0,
		"ships": 3, "spec": "escort", "risk": 0.08,
		"ep": 25, "credits": 2000, "desc": "科考船深空护航,保障科研进度。",
		"equip_req": {"defense": 1},
	},
	"mo_salvage_wreck": {
		"name": "战舰残骸拆解", "kind": "salvage", "diff": "D3", "dur_sec": 1320.0,
		"ships": 3, "spec": "salvage", "risk": 0.10,
		"ep": 25, "credits": 1500, "desc": "拆解大型战舰残骸。",
		"equip_req": {},
	},
	"mo_signal_grid": {
		"name": "异常信标阵列", "kind": "signal", "diff": "D4", "dur_sec": 2700.0,
		"ships": 3, "spec": "survey", "risk": 0.15,
		"ep": 50, "credits": 2500, "desc": "解密异常信标阵列,获取深空数据。",
		"equip_req": {"elec": 2},
	},
	"mo_patrol_lane": {
		"name": "航道巡逻", "kind": "combat", "diff": "D1", "dur_sec": 420.0,
		"ships": 2, "spec": "combat", "risk": 0.0,
		"ep": 5, "credits": 400, "desc": "巡查空间站附近航道,驱离可疑舰船。",
		"equip_req": {"weapon": 1}, "route_safety_gain": 0.3,
	},
	"mo_escort_convoy": {
		"name": "商队护航", "kind": "escort", "diff": "D2", "dur_sec": 900.0,
		"ships": 2, "spec": "escort", "risk": 0.05,
		"ep": 12, "credits": 1000, "desc": "护送来往商队穿越航道,保障空间站补给线。",
		"equip_req": {"defense": 1}, "route_safety_gain": 0.7,
	},
}

# ── 三层任务板(§5.8) ──
const RESIDENT_TASKS := ["mo_survey_ice", "mo_combat_skirmish", "mo_salvage_field",
	"mo_empire_patrol", "mo_alliance_patrol",
	"mo_escort_probe", "mo_signal_faint", "mo_patrol_lane", "mo_escort_convoy"]
const ROTATION_POOL := ["mo_survey_rock", "mo_salvage_hulk", "mo_combat_nest",
	"mo_survey_deep", "mo_escort_science", "mo_salvage_wreck", "mo_signal_grid"]
const ROTATION_SLOTS := 3
const ROTATION_REFRESH_SEC := 1800.0
const COOLDOWN_MULT := 1.5

# ── 舰长档位(§9 v4g 两档) ──
const TIERS := {
	"normal": {"label": "普通", "max_level": 5, "skill_slots": 3,
		"max_elite": 1, "hire_fee": 2000.0, "bonus": 0.0},
	"rare":   {"label": "稀有", "max_level": 7, "skill_slots": 5,
		"max_elite": 2, "hire_fee": 12000.0, "bonus": 0.05},
}
const TIER_WEIGHTS := {"normal": 0.85, "rare": 0.15}

# ── 舰长技能表(§9.2, 11 项) ──
const SKILLS := {
	"first_strike":    {"label": "先手压制", "cat": "combat",
		"lv1": {"combat_p": 0.04}, "lv2": {"combat_p": 0.08, "combat_risk_half": true}},
	"vital_strike":    {"label": "要害打击", "cat": "combat",
		"lv1": {"credits_mul": 0.10}, "lv2": {"credits_mul": 0.20}},
	"suppress_fire":   {"label": "压制齐射", "cat": "combat",
		"lv1": {"combat_dmg_red": 0.15}, "lv2": {"combat_dmg_red": 0.30}},
	"deep_survey":     {"label": "深空测绘", "cat": "survey",
		"lv1": {"ep_mul": 0.15}, "lv2": {"ep_mul": 0.30}},
	"signal_parse":    {"label": "信号解析", "cat": "survey",
		"lv1": {"survey_p": 0.04}, "lv2": {"survey_p": 0.08}},
	"wreck_eye":       {"label": "残骸鉴赏", "cat": "salvage",
		"lv1": {"loot_mul": 0.15}, "lv2": {"loot_mul": 0.30}},
	"survivor_beacon": {"label": "幸存者信标", "cat": "salvage",
		"lv1": {"rescue_p": 0.10}, "lv2": {"rescue_p": 0.20}},
	"guard_formation": {"label": "护卫阵型", "cat": "escort",
		"lv1": {"escort_dmg_red": 0.15}, "lv2": {"escort_dmg_red": 0.30}},
	"quick_response":  {"label": "快速反应", "cat": "generic",
		"lv1": {"dur_mul": 0.94}, "lv2": {"dur_mul": 0.88}},
	"anomaly_nose":    {"label": "异常嗅觉", "cat": "generic",
		"lv1": {"rare_find_p": 0.10}, "lv2": {"rare_find_p": 0.20}},
	"veteran":         {"label": "老练", "cat": "generic",
		"lv1": {"exp_mul": 1.20}, "lv2": {"exp_mul": 1.40}},
}

const SPECS := ["combat", "survey", "salvage", "escort", "logistics"]
const SPEC_LABEL := {
	"combat": "战斗", "survey": "勘测", "salvage": "打捞",
	"escort": "护航", "logistics": "后勤",
}

# ── 子系统装备(§15, M2: MK1 四件 + 资格门槛) ──
const EQUIPMENT := {
	"eq_power_mk1":   {"label": "标准反应堆", "slot": "power", "tier": "T1",
		"bom": {"commonC": 50, "fueltank": 1}, "time": 240.0, "price": 900.0,
		"desc": "资格件: 舰船启用必需(无能源=死船)"},
	"eq_elec_mk1":    {"label": "基础传感阵列", "slot": "elec", "tier": "T1",
		"bom": {"rareB": 40, "ecu": 1}, "time": 240.0, "price": 1000.0,
		"desc": "资格件: 信号/勘测类任务必备"},
	"eq_weapon_mk1":  {"label": "制式火控组", "slot": "weapon", "tier": "T1",
		"bom": {"rareA": 40, "truss": 2}, "time": 240.0, "price": 1100.0,
		"desc": "资格件: 战斗类任务必备"},
	"eq_defense_mk1": {"label": "复合装甲挂包", "slot": "defense", "tier": "T1",
		"bom": {"rareC": 40, "cabin": 1}, "time": 240.0, "price": 950.0,
		"desc": "资格件: D3+ 任务全员必备"},
}
const SLOT_ORDER := ["power", "elec", "weapon", "defense"]
const SLOT_LABEL := {"power": "能源", "elec": "电子", "weapon": "武器", "defense": "防御"}

# ── 远征材料(§15.3) ──
const EXP_MATERIALS := {
	"exp_power":   {"label": "超导环流圈", "slot": "power"},
	"exp_elec":    {"label": "相位谐振器", "slot": "elec"},
	"exp_weapon":  {"label": "火控枢纽", "slot": "weapon"},
	"exp_defense": {"label": "装甲晶格", "slot": "defense"},
}

# ── 名池 ──
const FIRST_NAMES := ["薇拉", "老萨", "柯特", "玛尔塔", "贝恩", "柳芭", "霍克", "尤里", "婷卡", "奥斯丁"]
const NICKS := ["「钩鼻」", "「老盐」", "「独眼」", "「铁颚」", "「雾里刀」", "「半吊子」",
	"「北风」", "「哑炮」", "「三指」", "「星尘」"]

const MAX_TEAMS := 2
const MAX_SLOTS := 3


## 成功率(§5.2): base + 舰长 bonus + 特长匹配 + 技能 − 风险
static func success_probability(def: Dictionary, captain: Dictionary) -> float:
	var p: float = DIFF_BASE.get(def["diff"], 0.75)
	var tier: String = captain.get("tier", "normal")
	if TIERS.has(tier):
		p += TIERS[tier]["bonus"]
	if captain.get("spec", "") == def.get("spec", ""):
		p += 0.10
	var skills: Dictionary = captain.get("skills", {})
	for sid in skills:
		if SKILLS.has(sid):
			var eff: Dictionary = SKILLS[sid].get("lv%d" % int(skills[sid]), {})
			var kind: String = def.get("kind", "")
			if kind == "combat" and eff.has("combat_p"):
				p += eff["combat_p"]
			if kind in ["survey", "signal"] and eff.has("survey_p"):
				p += eff["survey_p"]
	p -= float(def.get("risk", 0.0))
	return clampf(p, 0.05, 0.99)


## 装备门槛(§15.4): 返回缺口列表; fleet_equipped = {slot: count}
static func equip_gap(def: Dictionary, fleet_equipped: Dictionary) -> Array[String]:
	var gaps: Array[String] = []
	for slot in def.get("equip_req", {}):
		var need: int = int(def["equip_req"][slot])
		var have: int = int(fleet_equipped.get(slot, 0))
		if need > 0 and have < need:
			gaps.append("%s %d/%d" % [SLOT_LABEL.get(slot, slot), have, need])
	return gaps


## 任务类型 → 远征材料(§15.3)
static func drop_material(kind: String) -> String:
	match kind:
		"combat": return "exp_weapon"
		"survey", "signal": return "exp_elec"
		"escort": return "exp_defense"
		_: return "exp_power"
