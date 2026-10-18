shader_type spatial;
uniform vec4 effect_color : source_color = vec4(1.0);
uniform float effect_progress = 0.0;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// 热能鱼雷爆炸火球——复刻 EVE Motion Particles（mpramp_explosion 方案）：
// 灰度序列图集（7x7=49 帧，行主序=爆炸一生）+ 同布局光流图（RG=0.5 基线的
// 像素运动向量）+ 色阶 LUT（EVE COLOR_RAMP：图集无颜色，颜色全靠 ramp 按
// 生命进度采样）。顶点 billboard 数学与 expl_billboard.gdshader 同款
// （StandardMaterial 的 billboard 在 MultiMesh 上不渲染——见该文件注释）。
// 每实例：effect_progress=生命进度 k（渲染器 30Hz 写入），COLOR.a=淡出。
// 变体支持（EVE a/b/c 字母变体的单池等价物，2026-09-19）：CUSTOM.y=ramp 行号
// （ramp 贴多行色阶，一行=一个变体，行内随机=同舰不同爆）、CUSTOM.z=随机
// 朝向 roll（0~1，**vertex 里旋转面片本身**——EVE textureIndex/spinVel 思路）。
// 方块 bug 教训（2026-09-19）：曾用 fragment 里旋转帧内 UV 实现 roll，旋转后
// 的角点越出 [0,1] 达 ±0.207，越界区采样邻帧内容 → 四角点亮成硬边方块
// （能量图集邻帧竖条纹=「木纹方块」）。改转面片后 UV 恒在帧内。
uniform sampler2D atlas;      // NxN 灰度/彩色序列图集
uniform sampler2D flow_map;   // 同布局光流图（数据贴图，无损导入）
uniform sampler2D ramp;       // 256xN 色阶 LUT（N=ramp_rows 时为多行变体条）
uniform float grid = 7.0;
uniform float ramp_rows = 1.0;   // >1 时 ramp 为多行变体条，按 CUSTOM.y 选行
uniform float flow_strength = 0.06;
uniform float fast_until = 0.3;   // FastAtStart：前 30% 生命
uniform float fast_share = 0.6;   // 走完 60% 动画（爆闪快、余烟慢）
uniform float brightness = 3.0;   // 加色亮度乘数（EVE FlareBrightness 思路：
                                  // 灰度烟帧×淡出后亮度易塌，按 3x 起步调）
uniform float radial_mask = 0.0;  // >0.5 时内切圆裁剪帧（满幅帧图集防方形轮廓）
uniform float use_native_color = 0.0;  // >0.5 时颜色直出图集 RGB（HW3 已带色的
                                      // flipbook 如能量环用，跳过 ramp 重上色）
uniform float use_alpha_inten = 0.0;  // >0.5 时强度只取 A（HW3 DXT5 册：RGB 是
                                      // 满幅平灰底、真形状在 alpha——max(RGB,A)
                                      // 会把灰底当能量整幅点亮成方块）

varying vec4 v_col;
varying float v_k;    // effect_progress 只在 vertex 可见，经 varying 转发
varying float v_row;  // 变体行号（单行 ramp 时恒 0）

void vertex() {
	v_col = effect_color;
	v_k = effect_progress;
	v_row = 0.0;
	float roll = 0.0;
	vec3 lc = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
	vec3 to_c = normalize(lc);
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), to_c) + vec3(1e-5, 0.0, 0.0));
	vec3 up2 = cross(to_c, side);
	// 随机朝向：旋转 billboard 基向量（面片转，UV 不动——帧内采样恒安全）
	float ang = roll * 6.2831853;
	vec3 side_r = side * cos(ang) - up2 * sin(ang);
	vec3 up_r = up2 * cos(ang) + side * sin(ang);
	VERTEX = side_r * VERTEX.x + up_r * VERTEX.y;
}

void fragment() {
	float k = clamp(v_k, 0.0, 1.0);
	// FastAtStart 分段重映射：前 fast_until 段加速推进
	float k2 = k < fast_until
			? k * (fast_share / fast_until)
			: fast_share + (k - fast_until) * ((1.0 - fast_share) / (1.0 - fast_until));
	float frame = floor(k2 * (grid * grid - 1.0));
	vec2 cell = vec2(mod(frame, grid), floor(frame / grid));
	vec2 uv_cell = (UV + cell) / grid;
	// 光流扰动：中段最强，起止为零（EVE SampleDistance/SampleOffset 思路）。
	// 越界钳制：warp 只许在**本帧格内**——越界采到邻帧内容=方块 bug 根源
	// （HW3 烟册邻帧是满幅 144 灰底，采到即亮边）
	vec2 flow = texture(flow_map, uv_cell).rg - 0.5;
	vec2 uv_warp = uv_cell + flow * flow_strength * sin(3.14159 * k);
	vec2 inset = vec2(0.004);
	uv_warp = clamp(uv_warp, (cell + inset) / grid, (cell + vec2(1.0) - inset) / grid);
	vec4 t = texture(atlas, uv_warp);
	// 强度：默认 max(RGB,A)（EVE 灰度册后段烟柱能量在 alpha）；use_alpha_inten
	// 只取 A（HW3 DXT5 册 RGB=满幅灰底）
	float inten = use_alpha_inten > 0.5
			? pow(t.a, 0.85)
			: pow(max(max(t.r, max(t.g, t.b)), t.a), 0.85);
	// 内切圆径向遮罩（可选）：满幅帧（HW3 能量云）裁成圆形，杜绝方形轮廓
	if (radial_mask > 0.5) {
		vec2 c2 = UV - 0.5;
		inten *= 1.0 - smoothstep(0.20, 0.25, dot(c2, c2));
	}
	vec3 rc = mix(texture(ramp, vec2(k2, (floor(v_row) + 0.5) / ramp_rows)).rgb,
			t.rgb, use_native_color);
	// 亮度曲线：白闪消退后（k2 0.25~0.55）提升 1.7x，补偿无 bloom 的燃烧段
	float b = brightness * mix(1.0, 1.7, smoothstep(0.25, 0.55, k2));
	// v_col.rgb=层级 tint（同池子系统栈的亮核/烟幔差分；无 tint 时为白，行为同旧版）
	vec3 c = rc * inten * v_col.rgb * v_col.a * b;
	ALBEDO = c;
	EMISSION = c * 2.0;
	ALPHA = inten * v_col.a;
}
