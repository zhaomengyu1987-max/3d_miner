extends Node

## 极简存档节注册器（蓝图 §6.3 前置公共件, 2026-10-04 M1）。
##
## 各系统通过 register_section() 注册自己的"取状态/回放状态"回调;
## apply_cb(data) 必须返回 bool: false = 节数据损坏 → GameSave 挂起写入保护旧档(§6.3 P1 修复)。
## 本件统一负责: JSON 落盘(user://save.json) / 启动读档 / 60s 心跳自动存 /
## touch() 关键操作后追加存 / 读档失败保护(不覆盖旧档)。
##
## 存档顶层结构:
##   { "version": 1, "saved_at_wall": float(Unix 秒), "sections": { <name>: <data> } }
##
## 纪律(蓝图 §6.3): 写盘前版本校验; 读档失败挂起写入不覆盖旧档; 日志不落档。
## 各节 data 必须是 JSON 可序列化类型(dict/array/num/str/bool)。

const SAVE_PATH := "user://save.json"
const FORMAT_VERSION := 1
const AUTOSAVE_SEC := 60.0

## saved_at_wall: 最近一次落盘的现实 Unix 秒(离线结算锚点, 各节共用)
var saved_at_wall: float = 0.0
## 读档失败时置 true: 挂起一切写入, 防止坏档被新档覆盖(竞品丁案)
var write_suspended: bool = false

var _sections: Dictionary = {}          # name -> { get: Callable, apply: Callable }
var _accum: float = 0.0
var _dirty: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_or_init()
	_load_or_create_autosave_timer()


func _load_or_create_autosave_timer() -> void:
	var t := Timer.new()
	t.wait_time = AUTOSAVE_SEC
	t.timeout.connect(_on_autosave)
	add_child(t)
	t.start()


## 注册一个存档节。get_cb() 返回 JSON 可序列化数据; apply_cb(data) 在读档后回放。
func register_section(section_name: String, get_cb: Callable, apply_cb: Callable) -> void:
	_sections[section_name] = {"get": get_cb, "apply": apply_cb}
	# 注册晚于读档(典型: autoload 顺序在读档之后) → 把已读到的数据立即回放给它
	if _pending.has(section_name):
		var data: Variant = _pending[section_name]
		if apply_cb.is_valid() and not apply_cb.call(data):
			write_suspended = true
			push_warning("GameSave: 节 %s 回放失败, 写入挂起(保护旧档)" % section_name)
			return
		_pending.erase(section_name)


## 读档时如果节尚未注册, 数据先挂在这里等注册时回放
var _pending: Dictionary = {}


## 关键操作后调用: 标脏, 下一帧落盘(合并同帧多次调用)
func touch() -> void:
	_dirty = true


func _process(delta: float) -> void:
	if _dirty and not write_suspended:
		_dirty = false
		save_now()


func _on_autosave() -> void:
	if not write_suspended:
		save_now()


## 立即落盘。返回是否成功。
func save_now() -> bool:
	if write_suspended:
		return false
	var sections: Dictionary = {}
	for sec_name in _sections:
		var cb: Callable = _sections[sec_name]["get"]
		if cb.is_valid():
			sections[sec_name] = cb.call()
	saved_at_wall = Time.get_unix_time_from_system()
	var payload := {
		"version": FORMAT_VERSION,
		"saved_at_wall": saved_at_wall,
		"sections": sections,
	}
	# 原子写: 先写临时文件再改名(同卷 rename 近似原子), 避免写一半崩坏档
	var tmp_path := SAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_warning("GameSave: 无法打开 %s (err %d)" % [tmp_path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(payload))
	f.close()
	var err := DirAccess.rename_absolute(tmp_path, SAVE_PATH)
	if err != OK:
		push_warning("GameSave: 改名失败(err %d), 保留旧档" % err)
		DirAccess.remove_absolute(tmp_path)
		return false
	return true


## 启动读档: 无档 → 通知各节用默认值(apply({})); 坏档 → 挂起写入保护旧档。
func _load_or_init() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		saved_at_wall = Time.get_unix_time_from_system()
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		write_suspended = true
		push_warning("GameSave: 存档存在但无法读取, 写入挂起(保护旧档)")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		write_suspended = true
		push_warning("GameSave: 存档解析失败, 写入挂起(保护旧档)")
		return
	var data: Dictionary = parsed
	if int(data.get("version", -1)) != FORMAT_VERSION:
		write_suspended = true
		push_warning("GameSave: 版本不匹配(%s), 写入挂起(保护旧档)" % str(data.get("version")))
		return
	saved_at_wall = float(data.get("saved_at_wall", 0.0))
	var sections: Dictionary = data.get("sections", {})
	if typeof(sections) != TYPE_DICTIONARY:
		sections = {}
	for sec_name in sections:
		_pending[sec_name] = sections[sec_name]
	# 已注册的节立即回放; 未注册的挂 _pending 等注册
	for sec_name in _sections.keys():
		if _pending.has(sec_name):
			var apply_cb: Callable = _sections[sec_name]["apply"]
			var payload: Variant = _pending[sec_name]
			if apply_cb.is_valid() and not apply_cb.call(payload):
				write_suspended = true
				push_warning("GameSave: 节 %s 回放失败, 写入挂起(保护旧档)" % sec_name)
				return
			_pending.erase(sec_name)
