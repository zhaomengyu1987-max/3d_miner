shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

uniform vec3 heat_origin = vec3(0.0);
uniform vec3 hotspot_origin = vec3(0.0);
uniform vec3 paint_marks[32];
uniform int paint_count = 0;
uniform float mesh_radius = 1.0;
uniform float spread : hint_range(0.0, 1.0) = 0.0;
uniform float heat : hint_range(0.0, 1.0) = 1.0;
uniform float heat_extent = 2.0;
uniform float hotspot = 1.0;
varying vec3 surface_position;

void vertex() {
	surface_position = VERTEX;
	VERTEX += NORMAL * mesh_radius * 0.002;
}

void fragment() {
	float distance_from_hit = length(surface_position - heat_origin) / max(mesh_radius, 0.0001);
	// Slower initial spread, calibrated to this mesh instead of a large fixed radius.
	float reach = mix(0.12, heat_extent + 0.15, pow(spread, 1.6));
	float mask = 1.0 - smoothstep(max(0.0, reach - 0.15), reach, distance_from_hit);
	mask = mix(mask, 1.0, smoothstep(0.97, 1.0, spread));
	for (int i = 0; i < paint_count; i++) {
		float d = length(surface_position - paint_marks[i]) / max(mesh_radius, 0.0001);
		mask = max(mask, 1.0 - smoothstep(0.12, 0.24, d));
	}
	float current_distance = length(surface_position - hotspot_origin) / max(mesh_radius, 0.0001);
	mask = max(mask, (1.0 - smoothstep(0.12, 0.24, current_distance)) * hotspot);
	float intensity = mask * heat;
	// Fixed-size yellow core: never grows with spread; disabled during cooling.
	float core = (1.0 - smoothstep(0.05, 0.175, current_distance)) * hotspot;
	intensity = max(intensity, core * heat);
	ALBEDO = mix(vec3(0.65, 0.018, 0.003), vec3(1.0, 0.65, 0.015), core);
	EMISSION = mix(vec3(1.0, 0.025, 0.002), vec3(1.0, 0.65, 0.015), core) * intensity * 2.8;
	ROUGHNESS = 0.65;
	ALPHA = intensity * 0.85;
}
