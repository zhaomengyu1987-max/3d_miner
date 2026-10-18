shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform float brightness : hint_range(0.0, 2.0) = 0.55;
uniform float drive : hint_range(0.0, 1.0) = 0.0;
uniform bool grouped = false;
void vertex() {
	if (grouped) { VERTEX -= CUSTOM0.xyz * (1.0 - INSTANCE_CUSTOM.r); }
}
void fragment() {
	float cross_fade = pow(max(1.0 - pow(abs(UV.y * 2.0 - 1.0), 2.0), 0.0), 2.8);
	float along = pow(max(1.0 - UV.x, 0.0), 2.2);
	float root = mix(0.15, 1.0, smoothstep(0.0, 0.08, UV.x));
	ALBEDO = vec3(0.025, 0.26, 0.8) * brightness;
	ALPHA = 0.3 * cross_fade * along * root * drive;
}
