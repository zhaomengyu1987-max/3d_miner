@tool
extends Node3D
## Editor-visible tint on an instanced GLB; each hull gets its own material.
const Catalog := preload("res://scripts/ships/MiningShipCatalog.gd")
@export_enum("skiff", "prospector", "barge", "orca", "hulk") var ship_type := "skiff":
	set(value):
		ship_type = value
		if is_inside_tree():
			Catalog.apply_material(self, ship_type)

func _ready() -> void:
	Catalog.apply_material(self, ship_type)
