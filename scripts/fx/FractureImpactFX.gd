extends Node3D
## Local surface impact: pulsing shock rings, hot core and outward sparks.
var target: Node3D
var source: Node3D
var radius := 1.0
var elapsed := 0.0
var ending := -1.0
var material := StandardMaterial3D.new()
var rings: Array[MeshInstance3D] = []
var sparks: Array[MeshInstance3D] = []

func configure(ore: Node3D, station: Node3D, color: Color, size: float) -> void:
	target = ore
	source = station
	radius = size
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = color
	material.no_depth_test = false
	for i in 3:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.92
		torus.outer_radius = 1.0
		torus.rings = 32
		torus.ring_segments = 8
		ring.mesh = torus
		ring.rotation.x = PI / 2.0
		ring.material_override = material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
		rings.append(ring)
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 8
	sphere.rings = 4
	for i in 13:
		var spark := MeshInstance3D.new()
		spark.mesh = sphere
		spark.material_override = material
		spark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(spark)
		sparks.append(spark)
	_process(0.0)

func finish() -> void:
	ending = 0.0
	target = null

func _process(delta: float) -> void:
	elapsed += delta
	if ending >= 0.0:
		ending += delta
		material.albedo_color.a = maxf(0.0, 1.0 - ending / 0.5)
		if ending >= 0.5:
			queue_free()
	elif is_instance_valid(target) and is_instance_valid(source):
		var outward := (source.global_position - target.global_position).normalized()
		global_position = target.heat_contact_world() if target.has_method("heat_contact_world") else target.global_position + outward * radius * 0.85
		if outward.length_squared() > 0.01:
			look_at(global_position + outward, Vector3.RIGHT if absf(outward.y) > 0.95 else Vector3.UP)
	else:
		queue_free()
		return
	for i in rings.size():
		var phase := fmod(elapsed * 2.5 + float(i) / 3.0, 1.0)
		rings[i].scale = Vector3.ONE * radius * (0.12 + phase * 0.8) * 0.3
		rings[i].position.z = -radius * 0.08 * phase
	for i in sparks.size():
		var phase := fmod(elapsed * 3.0 + float(i) / 13.0, 1.0)
		var angle := float(i) * TAU / 12.0
		sparks[i].position = Vector3(cos(angle), sin(angle), -0.35) * phase * radius
		sparks[i].scale = Vector3.ONE * radius * (0.045 + 0.04 * (1.0 - phase))
	sparks[0].position = Vector3.ZERO
	sparks[0].scale = Vector3.ONE * radius * (0.18 + 0.06 * sin(elapsed * 35.0))
