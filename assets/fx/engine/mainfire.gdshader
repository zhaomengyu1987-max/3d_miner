shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D flow_noise : repeat_enable, filter_linear_mipmap;
uniform float flow_speed : hint_range(0.0, 20.0) = 5.0;
uniform float swirl_speed : hint_range(0.0, 4.0) = 0.35;
uniform float edge_threshold : hint_range(0.0, 0.9) = 0.48;
uniform float edge_softness : hint_range(0.01, 0.5) = 0.16;
uniform float brightness : hint_range(0.0, 12.0) = 4.5;
uniform float drive : hint_range(0.0, 1.0) = 0.0;
uniform float layer_override : hint_range(-1.0, 1.0) = -1.0;
uniform bool ring_surface = false;
uniform float opacity_multiplier : hint_range(0.0, 1.0) = 1.0;
uniform int visual_lod = 0;
uniform bool pooled = false;
uniform bool grouped = false;
varying float power;
varying float layer;

void vertex() {
	if (grouped && ring_surface) { VERTEX -= CUSTOM0.xyz * (1.0 - INSTANCE_CUSTOM.g); }
	power = pooled ? INSTANCE_CUSTOM.r : drive;
	layer = layer_override >= 0.0 ? layer_override : COLOR.r;
}

void fragment() {
	// glTF export flips Blender's UV V: restore nozzle=0, tip=1 here.
	float axial = 1.0 - UV.y;
	float animation_time = visual_lod == 0 ? TIME : 0.0;
	float t = animation_time * flow_speed * mix(0.65, 1.0, power);
	// UV V increases from nozzle to tip. Subtract time to move downstream.
	vec2 p = vec2(UV.x * 3.0 + animation_time * swirl_speed * mix(0.5, 1.0, layer),
		axial * 2.5 - t * mix(0.8, 1.3, layer));
	// MID: one static noise sample. FAR: static analytic flame, no texture sampling.
	float n = 0.65;
	float fine = 0.65;
	if (visual_lod < 2) {
		n = texture(flow_noise, p).r;
		fine = n;
	}
	if (visual_lod == 0) {
		fine = texture(flow_noise, p * vec2(2.0, 1.7) + vec2(0.27, -t * 0.35)).r;
	}
	float breakup = smoothstep(edge_threshold, edge_threshold + edge_softness, n * 0.7 + fine * 0.3);
	float turbulent = mix(0.78 + n * 0.22, breakup, layer * layer);
	float fade = pow(max(1.0 - axial, 0.0), 1.6) * smoothstep(0.0, 0.045, axial);
	// A closed ring has no nozzle or tail; keep its circumference continuous.
	if (ring_surface) { fade = 1.0; }
	vec3 core = vec3(0.60, 0.88, 1.0);
	vec3 cyan = vec3(0.035, 0.42, 1.0);
	vec3 blue = vec3(0.012, 0.13, 0.65);
	vec3 color = layer < 0.5 ? mix(core, cyan, layer * 2.0) : mix(cyan, blue, (layer - 0.5) * 2.0);
	ALBEDO = color * brightness * mix(0.30, 1.0, power);
	ALPHA = fade * turbulent * mix(0.8, 0.32, layer) * opacity_multiplier;
}
