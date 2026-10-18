shader_type spatial;
uniform vec4 effect_color : source_color = vec4(1.0);
uniform float effect_progress = 0.0;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// 爆炸面片 billboard（点状正对相机）：StandardMaterial 的 billboard 在
// MultiMesh 实例上渲染不出生代（用户实测全员隐身）——改自定义 shader，
// 与光束渲染器同路（局部空间旋转朝向相机，实例变换负责缩放/定位）。
// 每实例：COLOR.rgb=色调 COLOR.a=淡出。
uniform sampler2D tex;
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
	vec4 t = texture(tex, UV);
	vec3 c = t.rgb * v_col.rgb * v_col.a;
	ALBEDO = c;
	EMISSION = c * 2.0;
	ALPHA = t.a * v_col.a;
}
