extends RefCounted
## World contract: one Godot unit is one metre, matching aitest's ship assets.
## Migration anchor: legacy mining corvette 7.2 -> 86.4 m; aitest frigate mesh 86.787 m.
## Mining units were reduced 10x, then the entire legacy world enlarged 10x.
## Final mining corvette: 86.4m; imported visitor hulls retain native metre scale.
## This converts legacy tuning only. New metre-authored assets/values must NOT multiply again.
## Scene coordinates were baked at this factor; changing this constant alone is not a rescale.
const LEGACY_TO_METERS := 120.0
## Second world migration relative to the visitor navigation tuning, not imported mesh size.
const HARBOUR_EXPANSION := 10.0
