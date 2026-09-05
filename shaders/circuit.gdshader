shader_type canvas_item;
render_mode unshaded;

// Etched data buses: a slow current runs along cached line geometry. This
// touches only line pixels; no noise texture, screen read, or full-floor quad.
uniform float phase = 0.0;
varying float distance_along;

void vertex() {
	distance_along = (VERTEX.x * 0.25 + VERTEX.y * 2.0) / 420.0;
}

void fragment() {
	float cycle = fract(distance_along - TIME * 0.22 + phase);
	float current = smoothstep(0.80, 0.90, cycle) * (1.0 - smoothstep(0.94, 1.0, cycle));
	COLOR.rgb *= 0.55 + current * 0.65;
}
