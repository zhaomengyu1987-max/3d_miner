shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_front, shadows_disabled;

// 矿石悬停描边：屏幕空间恒定宽度（默认 1px），与矿石大小/距离/相机缩放无关。
// 做法：背面壳(cull_front)沿视空间法线在裁剪空间偏移固定像素数，
// 只在轮廓边缘露出，形成恒定像素宽的环。
uniform vec4 line_color : source_color = vec4(0.45, 0.86, 1.0, 1.0);
uniform float width_px = 1.0;

void vertex() {
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_nrm = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec4 clip_pos = PROJECTION_MATRIX * view_pos;
	vec2 n2 = view_nrm.xy;
	float len = length(n2);
	if (len > 1e-5) {
		// 全屏 NDC 跨度 2.0 对应 VIEWPORT_SIZE 像素 → 1 像素的 NDC 步长
		vec2 px_ndc = 2.0 / VIEWPORT_SIZE;
		clip_pos.xy += (n2 / len) * width_px * px_ndc * clip_pos.w;
	}
	POSITION = clip_pos;
}

void fragment() {
	ALBEDO = line_color.rgb;
}
