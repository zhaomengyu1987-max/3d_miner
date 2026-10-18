shader_type spatial;
uniform vec4 effect_color : source_color = vec4(1.0);
uniform float effect_progress = 0.0;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// 炮口主闪——家园3 FX_MAT_Muzzle_02C 复刻：炮口 sprite × 橙 ramp × 旋涡扭曲。
// 原版用 flowmap 顺时针旋涡（未解码）；本复刻程序化 UV 旋转近似——
// 旋转角 = 圈数 × 生命进度 × (1-r)^sharp（中心转得快、外缘慢）。
// effect_progress = 生命进度 k（渲染器 custom 池写入）。
uniform sampler2D tex;
uniform sampler2D ramp;
uniform float use_ramp = 1.0;
uniform float swirl_turns = 0.0;   // 全生命累计旋涡圈数（0=不旋转；EVE artillery 云图无旋转，换 HW3 流向贴图时再开）
uniform float swirl_sharp = 1.6;   // 角度随半径衰减指数
uniform float brightness = 1.0;
varying vec4 v_col;
varying float v_k;

void vertex() {
	v_col = effect_color;
	v_k = effect_progress;
	vec3 lc = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
	vec3 to_c = normalize(lc);
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), to_c) + vec3(1e-5, 0.0, 0.0));
	vec3 up2 = cross(to_c, side);
	VERTEX = side * VERTEX.x + up2 * VERTEX.y;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float ang = swirl_turns * TAU * v_k * pow(max(0.0, 1.0 - r), swirl_sharp);
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 uv = vec2(0.5) + vec2(ca * p.x - sa * p.y, sa * p.x + ca * p.y) * 0.5;
	vec4 t = texture(tex, uv);
	// 贴图明度即透明度蒙版（用户定：黑=0 透明，不重烘贴图）
	float lum = max(max(t.r, t.g), t.b);
	// 径向软边：无论贴图内容如何，r>edge_fade 起强制圆形衰减（防方形轮廓）
	float rad_kill = smoothstep(1.0, 0.78, r);
	vec3 c = t.rgb * rad_kill;
	if (use_ramp > 0.5) {
		// lum→ramp 上色（sprite 只当形状/强度，颜色由橙 ramp 决定）
		c = texture(ramp, vec2(lum, 0.5)).rgb;
	}
	c *= v_col.rgb * v_col.a * brightness;
	ALBEDO = c;
	EMISSION = c;
	ALPHA = t.a * lum * v_col.a;
}
