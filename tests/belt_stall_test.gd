extends Node
## BeltFlow 长跑"矿石断流"回归测试（无头）
##
## 现象：矿石流跑一段时间后不再出现新矿。
## 待验证根因：BeltOre.age 只在 _physics_process 里累加，回收重生时从不复位，
##   于是它是"池槽位一生累计"而不是"本次寿命"。每个槽位累计超过
##   BeltFlow.max_ore_age_s 之后，每次重生都会在下一帧立刻被 age 保险丝回收
##   （BeltFlow._process 的 age 条件），该槽位从此永久报废 → 走廊最终空掉。
##   注意：消失区判定（沿流向越过 despawn_edge）本身没问题，本测试同时证明这点 ——
##   只改保险丝数值就会改变塌陷时刻，而"越界回收"始终正常工作。
##
## 时间压缩（只缩数值尺度，不改结构；让分钟级现象在秒级复现）：
##   max_ore_age_s = 20s（游戏里 600s）      flow_speed = 8 m/s（游戏里 0.77）
##   单趟 x(-100 → 65) = 165m ≈ 20.6s ≈ 1 个保险丝周期
## 时间加速：TimeWarp 10×（与结构无关，只决定跑完 100s 模拟要几秒真实时间）
##
## 判定（预热结束后进入稳态采样）：
##   1) 稳态可见矿数 >= target_count 的一半
##   2) 稳态可见矿的 age <= 保险丝 + 1 帧（重生必须复位寿命）
##   3) 池内"报废槽位"（age 已超保险丝的槽位，含冻结在池里的）== 0
##
## 运行（本机 release 模板不支持 --path/场景参数，需把 exe 放工程根目录，
## 并把 project.godot 的 run/main_scene 临时指向本场景）：
##   .\_dsh_godot_test.exe --headless --quit-after 6000
## 输出：BELT_STALL_TEST_PASS / BELT_STALL_TEST_FAIL，退出码 0/1

const BeltFlowScript := preload("res://scripts/BeltFlow.gd")
const TimeWarpScript := preload("res://scripts/dev/TimeWarp.gd")

const WARP := 10.0              ## 加速系统倍率（10×）
const COUNT := 60               ## 池容量（游戏 400；数量不影响结构复现）
const FUSE_S := 20.0            ## max_ore_age_s（游戏 600s）
const FLOW_SPEED := 8.0         ## 游戏 0.77 m/s
const SPEED_VARIANCE := 0.5
const WARMUP_S := 60.0          ## 预热：等所有槽位都跑满 1 趟以上（报废发生在第 1~2 趟末）
const RUN_SIM_S := 100.0
const SAMPLE_S := 5.0
const MIN_ALIVE_RATIO := 0.5
const AGE_SLACK := 1.0          ## 允许超出保险丝的量（10× 下单物理步 0.167s）

var _flow                       # BeltFlow（用 preload 实例化，避开 class_name 缓存依赖）
var _warp                       # TimeWarp
var _fails := 0
var _min_visible := 1 << 30
var _max_age_seen := 0.0
var _real_elapsed := 0.0
var _sim_elapsed := 0.0


func _ready() -> void:
	await _run()


func _run() -> void:
	print("=== BeltFlow 长跑断流测试 ===")
	print("参数: target_count=%d  max_ore_age_s=%.0fs  flow_speed=%.2f  加速=%.0f×  (单趟≈%.1fs)"
		% [COUNT, FUSE_S, FLOW_SPEED, WARP, 165.0 / FLOW_SPEED])

	_warp = TimeWarpScript.new()
	_warp.name = "TimeWarp"
	_warp.show_overlay = false
	add_child(_warp)
	_warp.activate(WARP)
	_check(is_equal_approx(Engine.time_scale, WARP), "加速系统生效 Engine.time_scale=%.1f" % Engine.time_scale)
	_check_overlay_path()

	_build_flow()
	var st0: Dictionary = _stats()
	print("池容量=%d  初始可见=%d" % [_flow._pool.size(), st0["visible"]])

	await _simulate()

	print("--- 汇总 ---")
	print("模拟时长=%.1fs  真实耗时=%.1fs  (实际加速≈%.1f×)"
		% [_sim_elapsed, _real_elapsed, _sim_elapsed / maxf(_real_elapsed, 0.001)])
	print("稳态内可见矿最低=%d (目标≥%d)  可见矿 age 上限=%.2fs (目标≤%.2fs)  报废槽位=%d"
		% [_min_visible, int(COUNT * MIN_ALIVE_RATIO), _max_age_seen, FUSE_S + AGE_SLACK, _dead_slots()])

	var st: Dictionary = _stats()
	_check(_min_visible >= int(COUNT * MIN_ALIVE_RATIO),
		"稳态可见矿数保持 >= %d（实测最低 %d）" % [int(COUNT * MIN_ALIVE_RATIO), _min_visible])
	_check(_max_age_seen <= FUSE_S + AGE_SLACK,
		"可见矿 age 不超过保险丝（实测上限 %.2fs）" % _max_age_seen)
	_check(_dead_slots() == 0,
		"没有报废槽位（age 超保险丝 %d 个）" % _dead_slots())
	_check(st["progressed"] > 0, "稳态仍有矿在推进（实测 %d 个已推进 30m+）" % st["progressed"])
	_check_rotation()
	_finish()


func _simulate() -> void:
	var sim_t := 0.0
	var next_sample := SAMPLE_S
	var first_delta := -1.0
	var t0 := Time.get_ticks_msec()
	while sim_t < RUN_SIM_S:
		await get_tree().physics_frame
		var d := get_physics_process_delta_time()
		if first_delta < 0.0:
			first_delta = d
			print("物理步 delta=%.4fs (=1/%d × %.0f×)  每真实秒推进≈%.1f 模拟秒"
				% [d, Engine.physics_ticks_per_second, Engine.time_scale, 1.0 / maxf(d, 0.0001) * Engine.physics_ticks_per_second / 60.0])
		sim_t += d
		if sim_t >= next_sample:
			var st: Dictionary = _stats()
			var steady := sim_t > WARMUP_S
			if steady:
				_min_visible = mini(_min_visible, st["visible"])
				_max_age_seen = maxf(_max_age_seen, st["age_max"])
			print("  t=%6.1fs 可见=%3d 推进=%3d age[%.1f~%.1f] 报废槽位=%3d%s"
				% [sim_t, st["visible"], st["progressed"], st["age_min"], st["age_max"],
					_dead_slots(), "  <- 稳态采样" if steady else ""])
			next_sample += SAMPLE_S
	_sim_elapsed = sim_t
	_real_elapsed = (Time.get_ticks_msec() - t0) / 1000.0


func _build_flow() -> void:
	_flow = BeltFlowScript.new()
	_flow.name = "BeltFlow"
	_flow.target_count = COUNT
	_flow.max_ore_age_s = FUSE_S
	_flow.flow_speed = FLOW_SPEED
	_flow.speed_variance = SPEED_VARIANCE
	_flow.capture_enabled = false   # 只测"漂移→回收→重生"循环，隔离捕获态
	_flow.show_debug_zones = false
	add_child(_flow)                # _ready → _start_flow()


## 覆盖 TimeWarp 的叠加提示路径（开 overlay 的开关走一遍）。
## 这本身没有可断言量，价值在于：格式化/构建写错时日志里会出现 "ERROR:"，
## 回归时只要检查本测试输出无 ERROR 行即可（历史上 %g 就是这条路径漏出来的）。
func _check_overlay_path() -> void:
	var ui = TimeWarpScript.new()
	ui.name = "TimeWarpOverlayProbe"
	ui.show_overlay = true
	add_child(ui)
	ui.activate(WARP)
	ui.deactivate()
	ui.queue_free()
	_warp.activate(WARP)            # 恢复本测试的加速倍率


## 可见矿统计（测试只读池内数据，不改游戏代码）
func _stats() -> Dictionary:
	var visible_n := 0
	var progressed := 0
	var age_min := INF
	var age_max := -INF
	var x_start: float = _flow.spawn_center.x + 30.0
	for ore in _flow._pool:
		if not ore.visible:
			continue
		visible_n += 1
		age_min = minf(age_min, ore.age)
		age_max = maxf(age_max, ore.age)
		if _flow.to_local(ore.global_position).x > x_start:
			progressed += 1
	if visible_n == 0:
		age_min = 0.0
		age_max = 0.0
	return {"visible": visible_n, "progressed": progressed, "age_min": age_min, "age_max": age_max}


## 池内 age 已超保险丝的槽位（含冻结在池里的）：这是"重生没复位寿命"的直接指纹
func _dead_slots() -> int:
	var n := 0
	for ore in _flow._pool:
		if ore.age > FUSE_S + AGE_SLACK:
			n += 1
	return n


## 生成起点轮转回归：模拟一个"取到就报废"的坏槽位（生成后立刻回收），
## 连续 8 次生成应落在 8 个不同槽位上。旧实现固定从 _pool[0] 找第一个空槽位，
## 这种坏槽位会每帧被取中 → 只落 1 个槽位 → 其余空槽位永远轮不到 → 全局断流。
func _check_rotation() -> void:
	for ore in _flow._pool:
		ore.set_drifting(false)          # 全场清空，保证每次只有一个槽位被取用
	var used := {}
	for i in 8:
		_flow._spawn_one()
		var vis := _visible_indices()
		if vis.size() != 1:
			break
		var idx: int = vis[0]
		used[idx] = true
		_flow._pool[idx].set_drifting(false)   # 立刻回收 = 坏槽位签名
	_check(used.size() == 8, "坏槽位不霸占生成路径（连续 8 次生成落在 %d 个不同槽位）" % used.size())


func _visible_indices() -> Array:
	var out := []
	for i in _flow._pool.size():
		if _flow._pool[i].visible:
			out.append(i)
	return out


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  PASS: ", what)
	else:
		_fails += 1
		print("  FAIL: ", what)


func _finish() -> void:
	if _fails == 0:
		print("BELT_STALL_TEST_PASS")
		get_tree().quit(0)
	else:
		print("BELT_STALL_TEST_FAIL (%d)" % _fails)
		get_tree().quit(1)
