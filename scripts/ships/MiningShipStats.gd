extends RefCounted
## Current metre-scale gameplay tuning; no additional world scaling at call sites.
const BASE_SPEED := 2.4 * preload("res://scripts/WorldUnits.gd").LEGACY_TO_METERS
const MODULE_TYPES := {"corvette": "skiff", "prospector": "prospector", "barge": "barge", "orca": "orca", "hulk": "hulk"}
const TYPES := {
	"skiff": {"speed_ratio": 1.0, "cargo": 500, "interval": 0.2, "yield": 1, "common": 1.0, "rare": 0.65, "fuel": 1.0},
	"prospector": {"speed_ratio": 0.9, "cargo": 750, "interval": 0.2, "yield": 2, "common": 0.6, "rare": 1.0, "fuel": 0.6},
	"barge": {"speed_ratio": 0.5, "cargo": 1500, "interval": 0.2, "yield": 3, "common": 1.0, "rare": 0.75, "fuel": 1.0},
	"orca": {"speed_ratio": 0.65, "cargo": 2000, "interval": 0.3, "yield": 3, "common": 0.9, "rare": 0.8, "fuel": 0.9},
	"hulk": {"speed_ratio": 0.4, "cargo": 3000, "interval": 0.2, "yield": 5, "common": 1.0, "rare": 0.9, "fuel": 1.0},
}

static func profile(id: String) -> Dictionary:
	return TYPES.get(id, TYPES["skiff"])

static func speed(id: String) -> float:
	return BASE_SPEED * float(profile(id).speed_ratio)

static func chance(id: String, ore_id: String) -> float:
	var category := "rare" if ore_id.begins_with("rare") else ("fuel" if ore_id == "fuel" else "common")
	return float(profile(id)[category])
