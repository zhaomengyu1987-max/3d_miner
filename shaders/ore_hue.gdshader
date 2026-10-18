shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_texture : source_color;
uniform sampler2D orm_texture;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float hue_shift = -0.09;
uniform float metallic_factor = 0.8882176;
uniform float roughness_factor = 1.0;

vec3 rgb_to_hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 0.000001)), d / (q.x + 0.000001), q.x);
}

vec3 hsv_to_rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 color = texture(albedo_texture, UV).rgb * base_color.rgb;
	vec3 hsv = rgb_to_hsv(color);
	hsv.x = fract(hsv.x + hue_shift);
	ALBEDO = hsv_to_rgb(hsv);
	// Original glTF metallic/roughness map: green roughness, blue metallic.
	vec4 orm = texture(orm_texture, UV);
	METALLIC = orm.b * metallic_factor;
	ROUGHNESS = orm.g * roughness_factor;
}
