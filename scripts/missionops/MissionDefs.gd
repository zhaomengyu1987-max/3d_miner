class_name MissionDefs
extends RefCounted

## MissionOps 静态定义表(蓝图 §8 任务表 M1 子集 / §9 舰长档 / 名池)。
## 数值多为 [占位], 上线前按 §5.5/§9 校准。

# ── 难度档基础成功率(§5.2) ──
const DIFF_BASE := {"D1": 0.85, "D2": 0.75, "D3": 0.65, "D4": 0.50}

# ── M1 任务表(4 条,蓝图 §8 子集;时长/奖励 [占位]) ──
# 货币奖励 = 时长(秒) × 20₡/秒 × 15% 封顶口径的约 60~70%(添头,§5.5)
const TASKS := {
	"mo_survey_ice": {
		"name": "冰带深处勘测", "kind": "survey", "diff": "D1", "dur_sec": 300.0,
		"ships": 2, "spec": "survey", "risk": 0.0,
		"ep": 5, "credits": 300, "desc": "勘测碎冰带深处,绘制矿脉草图。",
	},
	"mo_combat_skirmish": {
		"name": "航道清剿·散匪", "kind": "combat", "diff": "D1", "dur_sec": 480.0,
		"ships": 2, "spec": "combat", "risk": 0.0,
		"ep": 6, "credits": 700, "desc": "清剿航道散匪,保障委托方航线。",
	},
	"mo_salvage_field": {
		"name": "残骸场打捞", "kind": "salvage", "diff": "D1", "dur_sec": 600.0,
		"ships": 2, "spec": "salvage", "risk": 0.0,
		"ep": 8, "credits": 500, "desc": "打捞旧战残骸,回收可用部件。",
	},
	"mo_escort_probe": {
		"name": "无人探测器护送", "kind": "escort", "diff": "D2", "dur_sec": 720.0,
		"ships": 2, "spec": "escort", "risk": 0.05,
		"ep": 12, "credits": 900, "desc": "护送协会探测器穿越低安域。",
	},
}

# ── 舰长档位(v4g 两档;M1 先做普通,稀有进招募池) ──
const TIERS := {
	"normal": {"label": "普通", "max_level": 5, "skill_slots": 3, "hire_fee": 2000.0, "bonus": 0.0},
	"rare":   {"label": "稀有", "max_level": 7, "skill_slots": 5, "hire_fee": 12000.0, "bonus": 0.05},
}
const TIER_WEIGHTS := {"normal": 0.85, "rare": 0.15}   # 招募池掷骰 [占位]

# ── 特长(与任务 kind 匹配 +10%,§5.2) ──
const SPECS := ["combat", "survey", "salvage", "escort", "logistics"]
const SPEC_LABEL := {
	"combat": "战斗", "survey": "勘测", "salvage": "打捞",
	"escort": "护航", "logistics": "后勤",
}

# ── 名池(v4v: seed 驱动组合,名 + 诨号) ──
const FIRST_NAMES := ["薇拉", "老萨", "柯特", "玛尔塔", "贝恩", "柳芭", "霍克", "尤里", "婷卡", "奥斯丁"]
const NICKS := ["「钩鼻」", "「老盐」", "「独眼」", "「铁颚」", "「雾里刀」", "「半吊子」",
	"「北风」", "「哑炮」", "「三指」", "「星尘」"]

# ── M1 编队上限(巢穴建筑 M2 落地前占位) ──
const MAX_TEAMS := 2
const MAX_SLOTS := 3


## 成功率(§5.2 简化版): base(D) + 舰长档 bonus + 特长匹配 10% − 风险, 夹 5%~99%
static func success_probability(def: Dictionary, captain: Dictionary) -> float:
	var p: float = DIFF_BASE.get(def["diff"], 0.75)
	var tier: String = captain.get("tier", "normal")
	p += TIERS[tier]["bonus"]
	if captain.get("spec", "") == def.get("spec", ""):
		p += 0.10
	p -= float(def.get("risk", 0.0))
	return clampf(p, 0.05, 0.99)
