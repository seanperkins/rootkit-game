shader_type canvas_item;
render_mode unshaded;

// Etched data buses: a slow current runs along cached line geometry. This
// touches only line pixels; no noise texture, screen read, or full-floor quad.
uniform float phase = 0.0;
uniform int subnet = 0;
varying vec2 board_position;
varying float distance_along;

void vertex() {
	board_position = VERTEX;
	distance_along = (VERTEX.x * 0.25 + VERTEX.y * 2.0) / 420.0;
}

void fragment() {
	float cycle = fract(distance_along - TIME * 0.22 + phase);
	float current = smoothstep(0.80, 0.90, cycle) * (1.0 - smoothstep(0.94, 1.0, cycle));
	// Edge: flowing packets. Memory: a broad address scan. Core: a slow
	// synchronized heartbeat. These shade cached trace pixels only.
	if (subnet == 1) {
		float sweep = fract(board_position.y / 1100.0 - TIME * 0.10 + phase);
		current = smoothstep(0.65, 0.82, sweep) * (1.0 - smoothstep(0.85, 1.0, sweep));
	} else if (subnet == 2) {
		current = pow(0.5 + 0.5 * sin(TIME * 1.4 + phase), 4.0) * 0.75;
	}
	COLOR.rgb *= 0.50 + current * 0.65;
}
