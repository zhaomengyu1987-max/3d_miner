shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// EVE 磁轨炮光束复刻（rail_75mm~1000mm_fx.black 共用 blast.fx 的合成语义）。
// 数据来源：E:\EVE磁轨炮特效分析\（.black 参数实测 + BC5 LUT 解码结论）。
//
// 每实例输入（BeamRenderer 写入）：
//   COLOR.rgb        = 远档色调（武器传入）；近档颜色由 ramp 决定
//   COLOR.a          = 生命周期亮度（开火脉冲→保持→淡出，CPU 曲线）
//   INSTANCE_CUSTOM  = (随机相位, ramp行号(束类型), 远档标记, 当前束长 m)
//
// LOD 三层（D-013 定稿，对齐 ship.gd T09 阈值 1.5/3km 滞回 1.1）：
//   L0 近档(<1.5km)=EVE 全套四贴图 ｜ L1 中档(1.5-3km)=仅云图(去LUT/noise)
//   ｜ L2 远档(>3km)=零采样解析（对齐舰船 FAR ghost 低耗姿态）。
// 轴向特征全部按"离炮口的世界距离"映射（u*len）——束头推进时旧纹理锚在炮口，
// 新噪声从头端注入，即 EVE 观感里"光芒推进、沸腾注入"的成因。
// 颜色管线（用户设计决策）：贴图只作蒙版不作颜色——云图三通道=三张独立
// 蒙版（实测相关系数≈0：G 主云团 / B 热点 / R 丝缕），合成标量强度后查
// ramp 图集取真实色；不同类型光束=不同 ramp 行。

uniform sampler2D cloud_map : source_color, filter_linear_mipmap, repeat_enable; // 256² 云团（束体）
uniform sampler2D axial_lut : filter_linear, repeat_enable;    // 1024×1 RG 双噪声（blast.dds）
uniform sampler2D radial_lut : filter_linear, repeat_enable;   // 1024×1 R 截面噪声（laser.dds）
uniform sampler2D noise_map : filter_linear, repeat_enable;    // 128² RGBA 随机场
uniform sampler2D ramp_atlas : source_color, filter_linear;    // 256×5 颜色 ramp 图集（行=束类型：0磁轨/1红/2绿/3橙金/4重型磁轨蓝紫）

// —— .black 实测参数 ——
uniform float cloud_density = 0.98;    // Clouds.x
uniform float cloud_flow = 0.25;       // 云图轴向流速（uv/秒）
uniform float cloud_period = 140.0;    // 云图一个周期的世界长度 m
uniform float boil_period1 = 220.0;    // 轴噪#1 世界周期 m（LUT 已平滑，特征~16m）
uniform float boil_period2 = 90.0;     // 轴噪#2 世界周期 m（不同尺度→干涉）
uniform float boil_speed1 = 0.36;      // 轴噪流速（LUT u/秒）
uniform float boil_speed2 = -0.55;
uniform float flicker_amount = 0.33;   // Flicker.x
uniform float flicker_speed = 3.0;     // Flicker.y（Hz）
uniform float core_gain = 1.5;         // 热核线强度（EVE 观感：细亮核+雾状晕）
uniform float core_sharp = 20.0;        // 热核线截面锐度（pow 指数）
uniform float muzzle_gain = 2.4;       // 炮口端增亮倍率
uniform float muzzle_frac = 0.16;      // 炮口增亮段占束长比例（至少 muzzle_len m）
uniform float muzzle_len = 70.0;       // 炮口增亮段最小世界长度 m
uniform float tail_dim = 0.30;         // 头端相对炮口的最低亮度（LUT 无包络→解析）
uniform float head_glow = 1.7;         // 头部亮团强度（FlareIntensity 语义）
uniform float head_radius = 45.0;      // 头部亮团半径 m
uniform float head_ramp_pos = 0.85;    // 头部亮团在 ramp 上的取值位置
uniform float core_ramp_pos = 0.97;    // 热核线在 ramp 上的取值位置
uniform float output_gain = 1.6;       // 整体出射增益（加色+bloom 抬亮）

varying flat vec4 v_custom;
varying vec4 v_color;

void vertex() {
	v_color = COLOR;
	v_custom = INSTANCE_CUSTOM;
}

void fragment() {
	float u = UV.x;                // 0=炮口 → 1=束头（推进期 CPU 只画到束头）
	float v = UV.y * 2.0 - 1.0;    // 截面 -1..1
	float alpha = v_color.a;
	float len_m = max(v_custom.w, 1.0);
	float dist_m = u * len_m;      // 离炮口的世界距离
	float t = TIME + v_custom.x * 13.7;
	vec3 col;

	if (v_custom.z > 1.5) {
		// —— L2 远档（>3km，对齐舰船 FAR）：零贴图采样 ——
		float radial = pow(max(0.0, 1.0 - abs(v)), 2.0);
		float core = pow(max(0.0, 1.0 - abs(v)), 6.0) * 1.4;
		float env = mix(1.0, 0.45, u);
		col = v_color.rgb * (radial * 0.8 + core) * env * 2.2;
	} else if (v_custom.z > 0.5) {
		// —— L1 中档（1.5-3km，D-013 中间档）：仅云图采样（去 LUT/noise）——
		// 截面/沸腾全部解析化：径向 pow 包络 + sin 微沸（零采样），颜色仍走 ramp
		float radial = pow(max(0.0, 1.0 - abs(v)), 1.35);
		float core = pow(max(0.0, 1.0 - abs(v)), core_sharp) * core_gain;
		vec3 mask3 = texture(cloud_map, vec2(dist_m / cloud_period + t * cloud_flow, v * 0.5 + 0.5)).rgb;
		float strength = clamp(mask3.g * 0.70 + mask3.b * 0.65 + mask3.r * 0.20, 0.0, 1.0) * cloud_density;
		float boil = 0.75 + 0.25 * sin(dist_m * 0.03 + t * 2.2);
		float flick = 1.0 + flicker_amount * sin(TAU * t * flicker_speed * 0.16);
		float mz_len = max(muzzle_len, len_m * muzzle_frac);
		float muzzle_k = 1.0 + (muzzle_gain - 1.0) * exp(-pow(dist_m / mz_len, 2.0));
		float env = muzzle_k * mix(1.0, tail_dim, smoothstep(0.45, 1.0, u));
		float head = head_glow * exp(-pow((len_m - dist_m) / head_radius, 2.0)) * (0.6 + 0.4 * boil);
		float row_v = (clamp(v_custom.y, 0.0, 4.0) + 0.5) / 5.0;
		float val = clamp(strength * boil * radial * 1.35, 0.0, 1.0);
		vec3 aura = texture(ramp_atlas, vec2(val, row_v)).rgb;
		vec3 core_col = texture(ramp_atlas, vec2(core_ramp_pos, row_v)).rgb;
		vec3 head_col = texture(ramp_atlas, vec2(head_ramp_pos, row_v)).rgb;
		col = ((aura + core_col * core) * env + head_col * head * radial) * flick;
	} else {
		// —— L0 近档（<1.5km）：EVE 全套合成 ——
		// 截面（laser.dds 语义）：噪声化边缘 × 软包络
		float radial_n = texture(radial_lut, vec2(clamp(v * 0.5 + 0.5, 0.0, 1.0), 0.5)).r;
		float radial = pow(max(0.0, 1.0 - abs(v)), 1.35) * mix(1.0, radial_n * 2.0, 0.4);
		// 热核线：解析亮核（细而亮），雾晕的骨架
		float core = pow(max(0.0, 1.0 - abs(v)), core_sharp) * core_gain;
		// 轴向沸腾（blast.dds 语义）：两条不同尺度/速度噪声——乘积出峰、均值保底
		float u1 = dist_m / boil_period1 + t * boil_speed1;
		float u2 = dist_m / boil_period2 + t * boil_speed2;
		float n1 = texture(axial_lut, vec2(u1, 0.5)).r;
		float n2 = texture(axial_lut, vec2(u2, 0.5)).g;
		float boil = n1 * n2 * 2.2 + (n1 + n2) * 0.30;
		// 束体云图：三通道独立蒙版 → 标量强度（G 主云 0.70 / B 热点 0.65 / R 丝缕 0.20）
		float disturb = (texture(noise_map, vec2(u * 0.7 + t * 0.05, v * 0.25 + 0.5)).r - 0.5) * 0.22;
		vec3 mask3 = texture(cloud_map, vec2(dist_m / cloud_period + t * cloud_flow, v * 0.5 + 0.5 + disturb)).rgb;
		float strength = clamp(mask3.g * 0.70 + mask3.b * 0.65 + mask3.r * 0.20, 0.0, 1.0) * cloud_density;
		// 闪烁（Flicker）：平滑正弦 + 每束相位
		float flick = 1.0 + flicker_amount * sin(TAU * t * flicker_speed * 0.16);
		// 轴向包络：炮口段增亮（相对束长，保最小长度）→ 头端渐弱
		float mz_len = max(muzzle_len, len_m * muzzle_frac);
		float muzzle_k = 1.0 + (muzzle_gain - 1.0) * exp(-pow(dist_m / mz_len, 2.0));
		float env = muzzle_k * mix(1.0, tail_dim, smoothstep(0.45, 1.0, u));
		// 头部亮团：世界尺度半径，沿束推进（弹头感）
		float head = head_glow * exp(-pow((len_m - dist_m) / head_radius, 2.0)) * (0.6 + 0.4 * boil);
		// ramp 查色：束体强度 → 行=束类型（INSTANCE_CUSTOM.y）；核线/亮团取 ramp 高端
		float row_v = (clamp(v_custom.y, 0.0, 4.0) + 0.5) / 5.0;
		float val = clamp(strength * boil * radial * 1.35, 0.0, 1.0);
		vec3 aura = texture(ramp_atlas, vec2(val, row_v)).rgb;
		vec3 core_col = texture(ramp_atlas, vec2(core_ramp_pos, row_v)).rgb;
		vec3 head_col = texture(ramp_atlas, vec2(head_ramp_pos, row_v)).rgb;
		col = ((aura + core_col * core) * env + head_col * head * radial) * flick;
	}
	ALBEDO = col * alpha * output_gain;
	EMISSION = col * alpha * output_gain;
}
