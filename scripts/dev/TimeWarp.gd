class_name TimeWarp
extends Node
## 开发用时间加速系统（默认 10×，运行期 F10 开关）
##
## 用途：把整局模拟按 multiplier 倍速推进，让"只在大时间尺度才暴露"的问题
## （例：BeltOre.age 累计不复位 → 池槽位逐批报废 → 矿石断流）在秒级复现。
##
## 实现口径（依据本机引擎源码 main/main.cpp::iteration()）：
##   physics delta = physics_step * time_scale     (physics_step = 1/physics_ticks_per_second)
##   process  delta = process_step * time_scale
## 即：物理**步数不变**、单步 delta 变粗 —— 模拟时间按 multiplier 倍速前进，
## CPU 开销基本不变（不新增物理步）。因此不需要动 max_physics_steps_per_frame，
## 那个上限只管"慢帧追帧"（默认 8 步）。
## 副作用与对策：单步变小/变粗后，碰撞解算精度随之下降；若要保精度，
## 把 Engine.physics_ticks_per_second 同倍率提高即可（tps=600 + 10× → 单步仍是 1/60 s）。
##
## 用法：
##   1) 场景里挂一个 TimeWarp 节点（main.tscn 已挂，enabled=false），
##      运行时按 F10 在 1× / multiplier 之间切换；
##   2) 无头/自动化：warp.activate(10.0) / warp.deactivate()。

signal warp_changed(active: bool, multiplier: float)

## 盖在 SettingsPanel(layer 20) 之上，全屏时也能看到当前倍率
const OVERLAY_LAYER := 21

@export var enabled := false        ## 默认关：不动发布版行为，需要时勾选或按热键
@export_range(0.1, 100.0, 0.1, "or_greater") var multiplier := 10.0
@export var toggle_key := KEY_F10   ## 运行期开关热键
@export var show_overlay := true    ## 右上角倍率提示

var _active := false
var _label: Label


func _ready() -> void:
	if show_overlay:
		_build_overlay()
	if enabled:
		activate()
	else:
		_apply()


func _exit_tree() -> void:
	# 别把全局时间倍率留在被改过的状态（换场景 / 退出时复位）
	if _active:
		Engine.time_scale = 1.0


func activate(mult: float = -1.0) -> void:
	if mult > 0.0:
		multiplier = mult
	_active = true
	_apply()
	warp_changed.emit(_active, multiplier)


func deactivate() -> void:
	_active = false
	_apply()
	warp_changed.emit(_active, multiplier)


func toggle() -> void:
	if _active:
		deactivate()
	else:
		activate()


func is_active() -> bool:
	return _active


## 真实秒 → 当前倍率下的模拟秒（调试心算用）
func realtime_to_sim(seconds: float) -> float:
	return seconds * multiplier if _active else seconds


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == toggle_key:
		toggle()
		get_viewport().set_input_as_handled()


func _apply() -> void:
	Engine.time_scale = multiplier if _active else 1.0
	if _label != null:
		_label.visible = _active
		# 用字符串拼接而非 % 格式化: Godot 的 % 不支持 %g 之类的格式符, 写错会运行时报错
		_label.text = "TIME ×" + str(multiplier) + ("  (F10 关)" if _active else "  (F10 开)")


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "WarpOverlay"
	layer.layer = OVERLAY_LAYER
	add_child(layer)
	_label = Label.new()
	_label.visible = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_label.offset_left = -260.0
	_label.offset_top = 12.0
	_label.offset_right = -16.0
	_label.offset_bottom = 44.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	layer.add_child(_label)
