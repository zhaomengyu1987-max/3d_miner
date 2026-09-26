@tool
extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var base := EditorInterface.get_base_control()
	var found := _search(base)
	var tops := []
	for c in base.get_children():
		tops.append(String(c.name))
	print("PROBE_FOUND=", found)
	print("PROBE_TOPS=", tops)
	print("PROBE_PLUGINS=", ProjectSettings.get_setting("editor_plugins/enabled"))
	queue_free()

func _search(n: Node) -> bool:
	if String(n.name) == "PreviewCam":
		return true
	for c in n.get_children():
		if _search(c):
			return true
	return false
