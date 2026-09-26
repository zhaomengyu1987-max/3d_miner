shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// 高空云雾层 —— 程序化 fbm,无贴图依赖;木星风:奶金亮部 / 锈橙暗部
uniform vec3 cloud_bright : source_color = vec3(0.93, 0.83, 0.64);
uniform vec3 cloud_shadow : source_color = vec3(0.52, 0.36, 0.26);
uniform float coverage : hint_range(0.0, 1.0) = 0.42;
uniform float softness : hint_range(0.005, 0.4) = 0.10;
uniform float density_boost : hint_range(0.0, 2.0) = 1.15;
uniform float flow_speed = 0.006;
uniform float noise_scale = 0.004;
uniform vec2 wind_dir = vec2(1.0, 0.22);
uniform float fade_near = 130.0;
uniform float fade_far = 460.0;
uniform float max_alpha : hint_range(0.0, 1.0) = 0.9;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	mat2 rot = mat2(0.86, 0.5, -0.5, 0.86);
	for (int i = 0; i < 5; i++) {
		v += amp * vnoise(p);
		p = rot * p * 2.02 + vec2(13.7, 91.3);
		amp *= 0.5;
	}
	return v;
}

float cloud_field(vec2 p, vec2 wind, float warp) {
	float shape = fbm(p + wind + (warp - 0.5) * 0.55);
	float streaks = fbm(p * vec2(0.35, 2.6) + wind * 1.6);
	return shape * 0.72 + streaks * 0.28;
}

void fragment() {
	vec2 base = wpos.xz * noise_scale;
	vec2 wind = wind_dir * TIME * flow_speed;
	float warp = fbm(base * 1.9 + wind * 0.7);

	float d = cloud_field(base, wind, warp);
	float a = smoothstep(1.0 - coverage - softness, 1.0 - coverage + softness, d);
	a = clamp(a * density_boost, 0.0, 1.0);

	// 伪光照:向太阳偏移再采一次,偏移处更"厚"的一侧为暗部
	vec2 sun_off = vec2(0.30, 0.16);
	float d2 = cloud_field(base + sun_off, wind, warp);
	float shade = clamp((d2 - d) * 5.0 + 0.42, 0.0, 1.0);
	vec3 col = mix(cloud_shadow, cloud_bright, shade);

	// 远处淡出,藏住平面边缘
	float cam_d = distance(wpos, CAMERA_POSITION_WORLD);
	a *= 1.0 - smoothstep(fade_near, fade_far, cam_d);

	ALBEDO = col;
	ALPHA = a * max_alpha;
}
