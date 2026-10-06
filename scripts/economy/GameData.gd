class_name GameData
extends RefCounted

## 制造系统数据表 v0.1 —— manufacturing.md 草案数值的唯一集中地（M0 统一调平只改这里）。
##
## 矿石命名约定（2026-09-30 拍板）：
## - 显示名用占位符 普矿A-E / 稀有矿A-E，后续想好名字只改 "name" 字段；
## - "asset"/"path" 是现有 GLB 模型映射，换模型只改这两处；
## - asset 为空 = 模型还没做：矿流不生成、涉及它的制造单显示"待模型"；
## - "role" 保留文档原名，方便对照 manufacturing.md 的 BOM 与产地设定。
## - superbigGold 不在表内：维持原设计预留碎裂演示，不进矿池。

# ---------- 矿石（10 种 BOM 矿 + 燃料冰矿） ----------
# weight: 采矿场景出现权重（§2.3：很高100 / 高55 / 中30 / 低12 / 很低5，草案）
# price : 基准单价 ₡/单位（= 文档相对单价指数 × 生铁 3₡ 基准，草案）
const ORES := {
	"commonA": {"name": "普矿A", "asset": "IronOre", "path": "res://assets/rareOre/IronOre.glb",
		"weight": 100.0, "price": 2.0, "role": "生铁陨矿·结构金属", "s_only": true},
	"commonB": {"name": "普矿B", "asset": "RockOre", "path": "res://assets/NormalOre/RockOre.glb",
		"weight": 55.0, "price": 4.0, "role": "铜脉砾矿·导体/线圈"},
	"commonC": {"name": "普矿C", "asset": "iceBlack", "path": "res://assets/rareOre/iceBlack.glb",
		"weight": 15.0, "price": 4.0, "role": "冰晶簇·挥发物/低温剂（暂用黑冰模型·低频，新模型可换）"},
	"commonD": {"name": "普矿D", "asset": "NormalOre", "path": "res://assets/NormalOre/NormalOre.glb",
		"weight": 30.0, "price": 6.0, "role": "硅壳岩·电子基材"},
	"commonE": {"name": "普矿E", "asset": "Mesh0", "path": "res://assets/NormalOre/Mesh0.glb",
		"weight": 28.0, "price": 4.0, "role": "碳泥团块·有机/聚合物", "s_only": true},
	"rareA": {"name": "稀有矿A", "asset": "BlueGem", "path": "res://assets/rareOre/BlueGem.glb",
		"weight": 12.0, "price": 24.0, "role": "辉钼晶·精密火控"},
	"rareB": {"name": "稀有矿B", "asset": "metalOre", "path": "res://assets/NormalOre/metalOre.glb",
		"weight": 12.0, "price": 24.0, "role": "磁极稀土矿·电磁系统"},
	"rareC": {"name": "稀有矿C", "asset": "goldenAsteroid", "path": "res://assets/rareOre/goldenAsteroid.glb",
		"weight": 10.0, "price": 20.0, "role": "铱芯重矿·超重装甲"},
	"rareD": {"name": "稀有矿D", "asset": "", "path": "",
		"weight": 6.0, "price": 30.0, "role": "电浆凝矿·电浆储能（模型待做）"},
	"rareE": {"name": "稀有矿E", "asset": "goldSmall", "path": "res://assets/rareOre/goldSmall.glb",
		"weight": 5.0, "price": 40.0, "role": "活性纳米矿·纳米机械"},
	"fuel": {"name": "燃料冰矿", "asset": "IceOre", "path": "res://assets/NormalOre/IceOre.glb",
		"weight": 55.0, "price": 3.0, "role": "冰矿·燃料（高频冰·不进产品BOM，入库即燃料）"},
}
const FUEL_ID := "fuel"
const RARE_IDS := ["rareA", "rareB", "rareC", "rareD", "rareE"]

# ---------- 空间站组件（§5.1，既是商品又是建造原料） ----------
# bom 只用矿石 id；time 秒；price 为单件基准售价
const COMPONENTS := {
	"truss": {"name": "结构桁架", "bom": {"commonA": 60, "commonB": 20}, "time": 60.0, "price": 380.0},
	"cabin": {"name": "密封舱体", "bom": {"commonA": 40, "commonE": 30}, "time": 60.0, "price": 380.0},
	"ecu": {"name": "电子控制舱", "bom": {"commonD": 50, "commonB": 30, "rareA": 5}, "time": 120.0, "price": 1000.0},
	"fueltank": {"name": "低温燃料舱", "bom": {"commonC": 40, "fuel": 30}, "time": 90.0, "price": 460.0},
}

# ---------- 小型产品（§3.1，按批量生产） ----------
# price = 一批的总售价。定价规则（2026-10-02 重平衡）: 期望收购价 =
# price × DEMAND(1.0) × 0.90 ≈ 材料成本 × 2.0 —— 制造要明显比直接卖矿划算。
const PRODUCTS := {
	"smallArms": {"name": "小型武器", "batch": 100,
		"bom": {"commonA": 30, "commonB": 25, "commonE": 10}, "time": 120.0, "price": 470.0},
	"heavyArms": {"name": "重型陆地武器", "batch": 10,
		"bom": {"commonA": 120, "commonB": 60, "commonC": 40}, "time": 240.0, "price": 1500.0},
	"nanoRepair": {"name": "纳米修复剂", "batch": 50,
		"bom": {"rareE": 15, "commonE": 40, "commonC": 20}, "time": 300.0, "price": 1900.0},
	"plasmaAmmo": {"name": "模块化电浆弹药", "batch": 200,
		"bom": {"commonC": 60, "rareD": 35, "commonB": 25}, "time": 360.0, "price": 3100.0},
	# ---------- MissionOps 子系统装备(MVP: 建造厂可制造) ----------
	"eq_power_mk1": {"name": "标准反应堆", "batch": 1,
		"bom": {"rareD": 40, "fueltank": 1}, "time": 240.0, "price": 900.0, "is_equip": true},
	"eq_elec_mk1": {"name": "基础传感阵列", "batch": 1,
		"bom": {"rareB": 40, "ecu": 1}, "time": 240.0, "price": 1000.0, "is_equip": true},
	"eq_weapon_mk1": {"name": "制式火控组", "batch": 1,
		"bom": {"rareA": 40, "truss": 2}, "time": 240.0, "price": 1100.0, "is_equip": true},
	"eq_defense_mk1": {"name": "复合装甲挂包", "batch": 1,
		"bom": {"rareC": 40, "cabin": 1}, "time": 240.0, "price": 950.0, "is_equip": true},
}

# ---------- 舰船（§3.2，单艘生产，纯商品——玩家不操舰） ----------
# 定价规则（2026-10-02 拍板）: 货舰期望收购价 = 材料价值 × 1.05（不亏损线），
# 即 price = 材料价值 × 1.05 ÷ 0.90 = 材料价值 × 7/6（DEMAND=1.0 时）。
# 矿石消耗 2026-10-02 上调 50%（配合矿石单价 ×2/3，材料 ₡ 价值不变、挖矿量 +50%）。
const SHIPS := {
	"longbow": {"name": "长弓级会战护卫舰",
		"bom": {"commonA": 1350, "commonB": 675, "commonC": 525, "commonD": 225, "rareA": 90},
		"time": 600.0, "price": 12845.0},     # 材料 11,010 → 出价 11,560.5（105.0%）
	"raven": {"name": "渡鸦级电子护卫舰",
		"bom": {"commonA": 1050, "commonD": 600, "rareB": 420, "rareA": 195, "commonE": 225},
		"time": 700.0, "price": 24920.0},     # 材料 21,360 → 出价 22,428（105.0%）
	"ram": {"name": "攻城锤 MK2 战列舰",
		"bom": {"commonA": 7800, "rareC": 3900, "commonC": 2100, "commonD": 1350, "commonB": 600},
		"time": 1800.0, "price": 131250.0},   # 材料 112,500 → 出价 118,125（105.0%）
	"logistics": {"name": "帝国标准 1 型装甲后勤舰",
		"bom": {"commonA": 5100, "rareC": 3150, "commonD": 1050, "commonE": 900, "rareE": 270},
		"time": 1500.0, "price": 109550.0},   # 材料 93,900 → 出价 98,595（105.0%）
}

# ---------- 许可证（§4.1，次数制） ----------
const LICENSE_USES_PRODUCT := 30
const LICENSE_USES_SHIP := 3
const LICENSE_FEE_RATE := 0.2  # 约产品基准成本的 15-25%，取 20%

# ---------- 逆向 / 原图 / ME / TE（§4.2-4.4，T2 仅占位） ----------
const RESEARCH := {
	"reverse_max_product": 10,   # 小型产品满 10 批
	"reverse_max_ship": 5,       # 舰船满 5 艘
	"blueprint_time": 300.0,     # 逆向攒满后研究站产出原图耗时
	"me_time": 240.0, "me_max": 10, "me_pct": 0.02,   # 每级材料 -2%，上限 -20%
	"te_time": 240.0, "te_max": 10, "te_pct": 0.04,   # 每级工期 -4%，上限 -40%
}

# ---------- 空间站模块（§5.2/§5.4） ----------
# levels[0] = 首建；等级制(hangar/research) levels 数组，叠加制(factory/container) max_count
const MODULES := {
	"hangar": {"name": "物流机库", "desc": "货舰泊位与来访交易",
		"levels": [
			{"cost": {"commonA": 200, "truss": 2, "cabin": 1}, "time": 300.0, "berths": 1, "ships": ["small"]},
			{"cost": {"commonA": 600, "truss": 4, "cabin": 2, "ecu": 1}, "time": 600.0, "berths": 2, "ships": ["small", "standard"]},
			{"cost": {"commonA": 1500, "truss": 8, "cabin": 4, "ecu": 2, "fueltank": 1}, "time": 900.0, "berths": 4, "ships": ["small", "standard", "heavy", "giant"]},
		]},
	"factory": {"name": "建造厂", "desc": "每座 +2 产线 / -4% 工期 / -1% 材料", "max_count": 5,
		"cost": {"commonA": 300, "truss": 2, "ecu": 1}, "time": 600.0},
	"research": {"name": "研究站", "desc": "逆向/蓝图研究：+25%速度·并行槽/级",
		"levels": [
			{"cost": {"commonD": 200, "truss": 1, "ecu": 2}, "time": 480.0, "slots": 1, "speed": 1.25},
			{"cost": {"commonD": 500, "truss": 3, "ecu": 3}, "time": 600.0, "slots": 2, "speed": 1.5},
			{"cost": {"commonD": 1000, "truss": 6, "ecu": 6, "fueltank": 1}, "time": 900.0, "slots": 3, "speed": 1.75},
		]},
	"container": {"name": "模块化货柜", "desc": "每组 +25% 货舰自动成交速率（装货速度）", "max_count": 4,
		"cost": {"truss": 1, "cabin": 1}, "time": 240.0, "unit": "组"},
	# 采矿无人机（2026-09-30 新增，文档外扩展）：建造界面直接解锁，建成免激活自动挖矿
	"drone": {"name": "采矿无人机", "desc": "自动捕获 S 档矿石拖回站体入库", "max_count": 6,
		"cost": {"commonA": 200}, "time": 90.0, "unit": "架"},
	# 激光采矿护卫舰（2026-09-30 新增）：环绕 M 档矿用中黄激光开采，货舱满回站卸货
	"corvette": {"name": "激光采矿护卫舰", "desc": "激光挖掘 M 档矿：5 单位/秒 · 货舱 500", "max_count": 3,
		"cost": {"commonA": 500, "commonB": 100}, "time": 180.0, "unit": "艘"},
	# 雇佣兵巢穴（蓝图 §5.9, 2026-10-04）：等级制, 每级 +1 行动舰队容量
	"hive": {"name": "雇佣兵巢穴", "desc": "行动舰队容量 +1/级——解锁探索派遣(F6)",
		"levels": [
			{"cost": {"commonA": 300, "cabin": 2}, "time": 300.0},
			{"cost": {"commonA": 800, "truss": 4, "cabin": 3}, "time": 600.0},
			{"cost": {"commonD": 1500, "truss": 8, "ecu": 3}, "time": 900.0},
			{"cost": {"commonD": 3000, "ecu": 6, "fueltank": 2}, "time": 1200.0},
		]},
}

# ---------- 来访货舰（§5.3，草案） ----------
# cap 舱位(1舱位=1矿石单位) / lvl 机库等级门槛 / funds 收购额度
const FREIGHTERS := {
	"small": {"name": "小型工业运输舰", "cap": 400.0, "lvl": 1, "funds": 3000.0},
	"standard": {"name": "标准工业运输舰", "cap": 1200.0, "lvl": 2, "funds": 9000.0},
	"heavy": {"name": "重型工业运输舰", "cap": 4000.0, "lvl": 3, "funds": 30000.0},
	"giant": {"name": "托拉斯巨型货运舰", "cap": 12000.0, "lvl": 3, "funds": 90000.0},
}
# 按机库等级的来船档次权重
const SPAWN_TABLE := {
	1: {"small": 100.0},
	2: {"small": 40.0, "standard": 60.0},
	3: {"small": 20.0, "standard": 40.0, "heavy": 33.0, "giant": 7.0},
}
# 各档货舰出售的许可证目录（§4.1 来源：来访货舰购买）
const LICENSE_CATALOG := {
	"small": ["smallArms", "nanoRepair"],
	"standard": ["heavyArms", "plasmaAmmo"],
	"heavy": ["longbow", "raven", "logistics"],
	"giant": ["ram", "logistics", "raven"],
}

# ---------- 燃料系统（§2.4，2026-09-30 拍板草案） ----------
const FUEL := {
	"visit_cost": 5.0,        # 每艘公共货舰到港+离港消耗本地燃料
	"smuggler_fuel": 100.0,   # 走私召唤燃料 = 20 × 公共单次消耗
	"smuggler_fee": 500.0,    # 走私召唤货币费用
	"smuggler_price": 1.3,    # 走私收货溢价
	"smuggler_license": 0.8,  # 走私许可证折扣
}

# ---------- 经济节律（草案，M0 调平） ----------
const ECON := {
	"day_length": 240.0,          # 1 游戏日 = 240 现实秒
	"visits_per_berth": 1.5,      # 每泊位每日来船期望（1-2 艘）
	"factory_time_pct": 0.04,     # 每座建造厂 -4% 工期
	"factory_mat_pct": 0.01,      # 每座建造厂 -1% 材料
	"base_lines": 1,              # 无建造厂时的手工产线（组件可手搓——首建机库的解锁路径）
	"lines_per_factory": 2,
	"freighter_dwell_s": 60.0,    # 货舰每次到港固定停留秒数（2026-09-30 拍板：1 分钟）
	"freighter_buy_discount": 0.10,  # 挂单价格因子: 外来货舰收购价 = 当前基准价 ×(1-10%)（2026-10-02 拍板）
	"order_duration_days": 3.0,      # 挂单有效天数（到期自动撤回/退货, 2026-10-02 拍板）
	"trade_rate": 40.0,           # 货舰自动成交速率基准 单位/秒（×货柜加成）
	"container_rate_mult": 0.25,  # 每组货柜 +25% 自动成交速率（装货速度语义, 2026-09-30 拍板）
	"start_money": 800.0,
	"build_speed_mult": 10.0,     # 全体建造/生产/研究速度倍率（当前测试期 ×10，M0 调平改回 1.0）
	"max_order_queue": 20,        # 制造排队上限（单数）
	"drone_fly_speed": 1.8,       # 无人机飞行速度 m/s（2026-09-30 拍板：原 6.0 降至 30%）
	"corvette_fly_speed": 2.4,    # 护卫舰飞行速度 m/s（2026-09-30 拍板：原 6.0 降至 40%）
	"drone_tow_player_ratio": 5.0,    # 无人机拖拽速度 = 玩家拖拽速度 ÷ 5（2026-09-30 拍板）
	"corvette_mine_rate": 5.0,        # 护卫舰采矿速度 单位/秒（草案）
	"corvette_cargo": 500.0,          # 护卫舰货舱容量 单位（草案）
	"corvette_orbit_speed": 0.27,     # 护卫舰环绕矿体角速度 rad/s（2026-09-30 拍板：原 0.9 降至 30%）
	# ---------- 战时需求（2026-10-02 拍板：战争期货舰愿意出更高价） ----------
	# 周期制（按游戏日确定性轮转, 无需额外状态）: 8 天和平 + 4 天战争, 循环往复
	"war_cycle_peace_days": 8,
	"war_cycle_war_days": 4,
	"war_demand_general": 1.15,   # 战时通用货物需求倍率（矿石/燃料/组件: 物流紧张）
	"war_demand_military": 1.6,   # 战时军用货物需求倍率（武器/弹药/舰船: 直接拉升出价 60%）
}

## 军用货物（战时吃 war_demand_military）: 武器/弹药/修复剂 + 全部舰船
const MILITARY := ["smallArms", "heavyArms", "nanoRepair", "plasmaAmmo",
	"longbow", "raven", "ram", "logistics"]

# ---------- 货舱占用（舱位=1矿石单位，其余草案） ----------
const VOLUME := {"ore": 1.0, "fuel": 1.0, "component": 2.0, "product": 1.0, "ship": 100.0}

# ---------- 需求锚点（§6） ----------
# 2026-10-02 重平衡: 和平期基线**一律 1.0**（原来舰船 0.1~0.5 会让"造出来卖"巨亏,
# 因为出价 = 基准价 × DEMAND × 0.90）。需求差异改由"战时需求倍率"表达
# （war_demand_military 1.6 / war_demand_general 1.15, 见 ECON）。
# 表结构保留: 单个事件仍可只抬升某种货的需求。
const DEMAND := {
	"ore": 1.0, "fuel": 1.0, "component": 1.0,
	"smallArms": 1.0, "heavyArms": 1.0, "nanoRepair": 1.0, "plasmaAmmo": 1.0,
	"longbow": 1.0, "raven": 1.0, "ram": 1.0, "logistics": 1.0,
}


# ================= 世界系统 M1+M2：局部冲突状态机 + 10 小国倒戈（草案） =================
# 设计与路线图见 docs/世界系统路线图.md。只有 empire/southern 这一条主线真正在跑状态机；
# 10 小国（M2 解冻）静态挂靠在其中一方 bloc 下、会倒戈，但不会自己单独开战线；
# 20 托拉斯仍只留数据骨架位置，冻结到 M5；多站扩张/自动化冻结到 M4。

## 阵营数据骨架（先按两方落地；以后解冻小国/托拉斯时在这里扩表，调用方接口不用改）。
const WORLD_FACTIONS := {
	"empire": {"name": "帝国", "bloc": "empire"},
	"southern": {"name": "南方联盟", "bloc": "southern"},
}

## M2：10 小国解冻——占位名(国1~国10)，正式名称待定后原地替换，key/调用方接口不变。
## 这里的 "bloc" 只是【初始值】：运行时实际归属存在 WorldState._minor_bloc，
## 会被倒戈事件改写并持久化（见 world_state_save.json 的 minor_bloc 字段）。
## 初始 5:5 对半分配（2026-10-02 拍板），20 托拉斯本轮不动（M5 范围，仍保持中立/不接入）。
## "home_sector"（M3 新增）：小国挂靠在哪个 sector 下——这是【静态】位置，不随倒戈变化
## （倒戈只改 bloc 归属，不搬家，呼应"小国不会因为站队换边就挪地方"的常识）。
const MINOR_FACTIONS := {
	"minor1": {"name": "国1", "bloc": "empire", "home_sector": "buffer_west"},
	"minor2": {"name": "国2", "bloc": "empire", "home_sector": "buffer_west"},
	"minor3": {"name": "国3", "bloc": "empire", "home_sector": "empire_front"},
	"minor4": {"name": "国4", "bloc": "empire", "home_sector": "buffer_center"},
	"minor5": {"name": "国5", "bloc": "empire", "home_sector": "empire_front"},
	"minor6": {"name": "国6", "bloc": "southern", "home_sector": "buffer_east"},
	"minor7": {"name": "国7", "bloc": "southern", "home_sector": "buffer_east"},
	"minor8": {"name": "国8", "bloc": "southern", "home_sector": "southern_front"},
	"minor9": {"name": "国9", "bloc": "southern", "home_sector": "buffer_center"},
	"minor10": {"name": "国10", "bloc": "southern", "home_sector": "southern_front"},
}

## 补给效率占位（M3 前用三档顶替真实跳数图）——M3 已落地精简星图，这两个常量不再被
## supply_efficiency() 读取，留着仅供参考/回滚，不要删（怕有遗漏的调用点）。
const STATION_REGION := "border"   # core(核心) / border(边境) / frontier(开拓地)
const STATION_EFFICIENCY := {"core": 1.0, "border": 0.6, "frontier": 0.3}

# ================= 世界系统 M3：精简版星图（跳数图，非真实坐标/渲染） =================
# 概念稿见 tools/art_preview/worldmap_concept_v2.html（帝国/南联钳形夹击，中间挤出
# 小国/托拉斯混居缓冲带，玩家被海盗环包围在正中心）。M3 只落数据层：8 个"代表性 sector"
# 的跳数图，供 WorldState.supply_efficiency() 的距离衰减公式使用；不做真实坐标/UI 渲染
# （那是以后排期的事，这里只论"跳了几步"）。

## 玩家站点固定挂在这个 sector（多站点扩张是 M4 范围，这里先是单一常量）。
const SECTOR_PLAYER := "buffer_center"

## 8 个代表性 sector；name 仅供展示/日志用。
const SECTORS := {
	"empire_core":    {"name": "帝国核心"},
	"empire_front":   {"name": "帝国前线"},
	"buffer_west":    {"name": "缓冲带·西"},
	"buffer_center":  {"name": "缓冲带·中心（玩家站点）"},
	"buffer_east":    {"name": "缓冲带·东"},
	"southern_front": {"name": "南联前线"},
	"southern_core":  {"name": "南联核心"},
	"pirate_zone":    {"name": "海盗开拓地"},
}

## 邻接表（无向图，边权恒为 1，只论跳数不算真实距离）——一条链：
## 帝国核心 - 帝国前线 - 缓冲西 - 缓冲中心(玩家) - 缓冲东 - 南联前线 - 南联核心
## 海盗开拓地单独挂在缓冲中心外（"环绕玩家站点"）。
const SECTOR_EDGES := {
	"empire_core":    ["empire_front"],
	"empire_front":   ["empire_core", "buffer_west"],
	"buffer_west":    ["empire_front", "buffer_center"],
	"buffer_center":  ["buffer_west", "buffer_east", "pirate_zone"],
	"buffer_east":    ["buffer_center", "southern_front"],
	"southern_front": ["buffer_east", "southern_core"],
	"southern_core":  ["southern_front"],
	"pirate_zone":    ["buffer_center"],
}

## 两大国"核心"所在 sector（供跳数衰减公式用：从玩家站点跳几步能到对面核心）。
const FACTION_CORE_SECTOR := {
	"empire": "empire_core",
	"southern": "southern_core",
}

## 局部冲突节奏（2026-10-02 拍板：1 个月筹备 + 10 天开战 + 2 个月和平，循环往复）。
## 天数单位 = Economy.day（1 day = ECON.day_length 秒）；debug_instant 不改这里的天数，
## 只影响"天"本身的真实秒数（跟 Economy.dwell_total() 的加速口径一致）。
const WORLD := {
	"peace_days": 60,
	"buildup_days": 30,
	"war_days": 10,
	"stockpile_target": 100.0,          # 概念上的"满值"；不设硬上限，允许冲破（更夸张的战争）
	"background_fill_ratio": 0.7,       # 玩家什么都不做时，背景经济独自能填到的比例
	"player_contrib_scale": 0.00006,    # 玩家反哺折算系数：按"货值 × 效率 × 这个系数"累加
	"dealer_tiers": 3,                  # 采购代理同一货物挂几档买单（制造"订单墙"视觉密度）
	"dealer_price_jitter": 0.06,        # 每档价格相对当前参考价的小幅抖动（±6%，低成本先实现）
	"dealer_qty_base": 6000.0,          # 普通军需品(弹药/武器/修复剂)阶梯总量基数，远超单站日产能
	"dealer_ship_qty_base": 2.0,        # 舰船类军需单档数量基数（整数级，不能照搬上面的量级）
	"dealer_funds": 5000000.0,
	"freighter_mult_peace": 1.0,
	"freighter_mult_buildup_lo": 1.1,   # 筹备期刚开始
	"freighter_mult_buildup_hi": 1.6,   # 筹备期快结束（临近 D-day，调度密度拉满）
	"freighter_mult_war": 2.0,
	# ---- M2：10 小国倒戈（2026-10-02 拍板）----
	"minor_defect_chance": 0.12,        # 每次进入筹备期，10 小国各自独立判定是否倒戈
	"minor_ally_mult_per_nation": 0.03, # 每多/少一个盟友（相对 5:5 基线）对补给效率/发牌员需求规模的影响
	"minor_ally_mult_min": 0.7,         # 上面系数的安全夹限（当前 ±5 国 × 0.03 = ±15%，正常碰不到这个边界）
	"minor_ally_mult_max": 1.3,
	# ---- M3：精简星图跳数衰减 + 小国局部摩擦（多战线雏形，2026-10-06 拍板）----
	"supply_decay_per_hop": 0.15,       # 补给效率 = 1/(1+跳数×这个系数)；3跳(玩家→任一核心)≈0.69，
	                                     # 跟 M2 前 STATION_EFFICIENCY["border"]=0.6 的量级接近，平滑过渡
	"minor_friction_chance": 0.15,      # [占位] 每次进入筹备期，同 sector 混居的小国有概率擦出局部
	                                     # 摩擦（纯叙事，暂不影响数值，多战线先从"能看见"做起）
}


# ================= 查询辅助 =================

static func ore_ids() -> Array:
	return ORES.keys()


static func is_ore(id: String) -> bool:
	return ORES.has(id)


static func is_component(id: String) -> bool:
	return COMPONENTS.has(id)


static func is_product(id: String) -> bool:
	return PRODUCTS.has(id)


static func is_ship(id: String) -> bool:
	return SHIPS.has(id)


## 军用货物（战时吃 war_demand_military 倍率，见 MILITARY）
static func is_military(id: String) -> bool:
	return MILITARY.has(id)


## 全部可交易货物类别："ore"/"fuel"/"component"/"product"/"ship"
static func cat_of(id: String) -> String:
	if id == FUEL_ID:
		return "fuel"
	if ORES.has(id):
		return "ore"
	if COMPONENTS.has(id):
		return "component"
	if PRODUCTS.has(id):
		return "product"
	if SHIPS.has(id):
		return "ship"
	return ""


static func good_name(id: String) -> String:
	match cat_of(id):
		"ore", "fuel":
			return ORES[id]["name"]
		"component":
			return COMPONENTS[id]["name"]
		"product":
			return PRODUCTS[id]["name"]
		"ship":
			return SHIPS[id]["name"]
	return id


## 单位基准售价（产品按每单位 = 批售价/批量）
static func good_unit_price(id: String) -> float:
	match cat_of(id):
		"ore", "fuel":
			return ORES[id]["price"]
		"component":
			return COMPONENTS[id]["price"]
		"product":
			return PRODUCTS[id]["price"] / float(PRODUCTS[id]["batch"])
		"ship":
			return SHIPS[id]["price"]
	return 0.0


static func good_volume(id: String) -> float:
	return VOLUME.get(cat_of(id), 1.0)


static func asset_to_ore(asset: String) -> String:
	for id in ORES:
		if ORES[id]["asset"] == asset:
			return id
	return ""


## 该资产(矿种)是否锁死 S 档——模型细节撑不起大体积的矿在表里标 "s_only": true
static func ore_s_only(asset: String) -> bool:
	var id := asset_to_ore(asset)
	return id != "" and bool(ORES[id].get("s_only", false))


## 按权重抽一种矿（返回资产名；未做模型的矿自动跳过）
static func pick_ore_asset(rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for id in ORES:
		if ORES[id]["path"] != "":
			total += ORES[id]["weight"]
	if total <= 0.0:
		return "NormalOre"
	var r := rng.randf() * total
	for id in ORES:
		if ORES[id]["path"] == "":
			continue
		r -= ORES[id]["weight"]
		if r <= 0.0:
			return ORES[id]["asset"]
	return "NormalOre"


## 设备（可持许可证/逆向的东西）= 小型产品 + 舰船
static func equip_ids() -> Array:
	var out := []
	out.append_array(PRODUCTS.keys())
	out.append_array(SHIPS.keys())
	return out


static func equip_name(id: String) -> String:
	if PRODUCTS.has(id):
		return PRODUCTS[id]["name"]
	if SHIPS.has(id):
		return SHIPS[id]["name"]
	return id


static func is_ship_equip(id: String) -> bool:
	return SHIPS.has(id)


static func reverse_max(equip: String) -> int:
	return RESEARCH["reverse_max_ship"] if is_ship_equip(equip) else RESEARCH["reverse_max_product"]


static func license_uses(equip: String) -> int:
	return LICENSE_USES_SHIP if is_ship_equip(equip) else LICENSE_USES_PRODUCT


## 设备基准 BOM 成本（₡，按矿石基准价）
static func material_cost(bom: Dictionary) -> float:
	var total := 0.0
	for id in bom:
		total += ORES[id]["price"] * float(bom[id])
	return total


static func license_fee(equip: String) -> float:
	var bom: Dictionary = PRODUCTS[equip]["bom"] if PRODUCTS.has(equip) else SHIPS[equip]["bom"]
	return roundf(material_cost(bom) * LICENSE_FEE_RATE)
