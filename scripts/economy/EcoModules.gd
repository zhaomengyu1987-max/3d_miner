extends Node
## EcoModules —— 空间站模块状态与建造（Economy 门面拆分子模块, 2026-10-14）。
## 建成钩子（重排来船计划 / 泵排队单）经门面转发，保持原有触发顺序。

var eco: Node  # Economy 门面

var modules := {}        # id -> {"built":bool,"level":int,"count":int,"smuggler_ok":bool}
var module_jobs := {}    # module_id -> {"total":float,"left":float}


func init_state() -> void:
	for id in GameData.MODULES:
		modules[id] = {"built": false, "level": 0, "count": 0, "smuggler_ok": false}


func module_level(id: String) -> int:
	return int(modules[id]["level"]) if modules.has(id) else 0


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
		if eco.stock(gid) < int(cost[gid]):
			return "材料不足：%s" % GameData.good_name(gid)
	return ""


func build_module(id: String) -> String:
	var reason := module_build_block(id)
	if reason != "":
		return reason
	eco.pay(module_next_cost(id))
	var t: float = GameData.MODULES[id]["time"] if not GameData.MODULES[id].has("levels") \
		else GameData.MODULES[id]["levels"][module_level(id)]["time"]
	if eco.debug_instant:
		t /= 100.0
	t /= float(GameData.ECON["build_speed_mult"])
	module_jobs[id] = {"total": t, "left": t}
	eco.jobs_changed.emit()
	eco.modules_changed.emit()
	return ""


func _finish_module_build(id: String) -> void:
	var def: Dictionary = GameData.MODULES[id]
	var m: Dictionary = modules[id]
	if def.has("levels"):
		m["level"] = int(m["level"]) + 1
		m["built"] = true
		eco.post_event("%s 建成（Lv.%d）——点击空间站打开 %s 界面" % [def["name"], m["level"], def["name"]], "good")
	else:
		m["count"] = int(m["count"]) + 1
		m["built"] = true
		eco.post_event("%s 加装完成（第 %d %s）" % [def["name"], m["count"], def.get("unit", "组")], "good")
	eco._roll_visit_schedule()
	eco._pump_orders()  # 建造厂扩产线 → 排队单可能立即开工
	eco.modules_changed.emit()


## 模块建造工期推进（原 Economy._advance_jobs 的模块段）。返回本拍是否有完工。
func advance(delta: float) -> bool:
	var dirty := false
	for id in module_jobs.keys().duplicate():
		var mj: Dictionary = module_jobs[id]
		mj["left"] -= delta
		if mj["left"] <= 0.0:
			module_jobs.erase(id)
			_finish_module_build(id)
			dirty = true
	return dirty


func set_smuggler_ok(on: bool) -> void:
	modules["hangar"]["smuggler_ok"] = on
	eco.modules_changed.emit()
	eco.post_event("走私货舰停靠已%s——暗市渠道%s" % ["开启" if on else "关闭", "接入" if on else "断开"], "warn")
