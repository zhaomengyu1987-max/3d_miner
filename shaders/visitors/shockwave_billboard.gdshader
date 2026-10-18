shader_type spatial;
uniform vec4 effect_color : source_color = vec4(1.0);
uniform float effect_progress = 0.0;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// 鱼雷冲击波面片——复刻家园3 鱼雷命中红圈（UE Niagara Mesh×Shockwave 材质方案）。
// 原案：扁平圆环网格 + CameraPlane 朝向 × 圆环 sprite × 火焰 ramp；
// 本复刻：billboard 四边形（=CameraPlane 朝向，顶点数学同 expl_billboard）
// × 圆环 sprite（自带红白烘焙色，RGB 即能量）× 实例色调制（能量盘换色用）。
// 贴图为 256x320 三变体图集（上主环+下两小环），用 uv_region 取主环格。
// 每实例：COLOR.rgb=行 tint，COLOR.a=淡出（渲染器 30Hz 写入）。
uniform sampler2D tex;
uniform sampler2D ramp;                         // 可选：给定时走 lum→色温重映射（原案材质链：
                                                // 红色来自 Ramp_Fire，sprite 只当形状遮罩）
uniform float use_ramp = 0.0;                   // 行给了 ramp 时由渲染器置 1
uniform float ramp_gamma = 1.0;                 // 极径增益：>1 让白热前沿带更窄
uniform vec2 uv_region_pos = vec2(0.0, 0.0);   // 取格左上（归一化）
uniform vec2 uv_region_scale = vec2(1.0, 1.0);  // 取格尺寸
uniform float brightness = 2.0;                 // 加色亮度乘数（无 bloom 补偿）
uniform float use_alpha_mask = 0.0;             // 1=黑白盘语义：t.a 作强度蒙版（暗纹透明只亮纹发光，
                                                // 家园3 KineticIMPCore 噪点盘用法；默认 0=RGB 亮度承载）

varying vec4 v_col;

void vertex() {
	v_col = effect_color;
	vec3 lc = (inverse(MODEL_MATRIX) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
	vec3 to_c = normalize(lc);
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), to_c) + vec3(1e-5, 0.0, 0.0));
	vec3 up2 = cross(to_c, side);
	VERTEX = side * VERTEX.x + up2 * VERTEX.y;
}

void fragment() {
	vec2 uv = uv_region_pos + UV * uv_region_scale;
	vec4 t = texture(tex, uv);
	// HW3 冲击波 sprite 为"色在 RGB、黑底加色"式，亮度只取 RGB（alpha 恒 255 无效）。
	// 实测 sprite 本体 lum 集中在 0.73-1.0，亮度作热坐标会整片白热——
	// 热坐标改用**极径**：外缘=前沿白热，内缘=红热尾迹（原案 CameraPlane 环的前沿语义）
	float lum = max(t.r, max(t.g, t.b));
	float mask = mix(lum, t.a, use_alpha_mask);  // 蒙版开关：黑白盘走 alpha 通道
	float r = clamp(length(UV - vec2(0.5)) * 2.0 * ramp_gamma, 0.0, 1.0);
	vec3 col = mix(t.rgb, texture(ramp, vec2(r, 0.5)).rgb, use_ramp);
	vec3 c = col * mask * v_col.rgb * v_col.a * brightness;
	ALBEDO = c;
	EMISSION = c;
	ALPHA = mask * v_col.a;
}
