shader_type canvas_item;
render_mode unshaded;

// Keep the center and the HUD legible when integrity is critical.
// Alpha only: no screen copy or framebuffer sampling.
void fragment() {
	vec2 distance_from_center = abs(SCREEN_UV - vec2(0.5)) * 2.0;
	float edge = smoothstep(0.45, 1.0, max(distance_from_center.x, distance_from_center.y));
	COLOR.a *= edge * edge;
}
