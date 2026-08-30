shader_type canvas_item;

// Procedural glyph silhouettes for the MultiMesh swarm. Drawn in code, so the
// repository still ships no image assets and no font. Distinct outlines per
// enemy type are also readability: 600 identical squares tell you nothing about
// what is closing on you.
//
// INSTANCE_CUSTOM.r carries the glyph index.

varying flat float glyph;

void vertex() {
	glyph = INSTANCE_CUSTOM.r;
}

float ring(float d, float radius, float width) {
	return 1.0 - smoothstep(width * 0.5, width, abs(d - radius));
}

void fragment() {
	vec2 p = UV - vec2(0.5);
	int g = int(glyph + 0.5);
	float a;

	if (g == 0) {
		// daemon — diamond outline
		a = ring(abs(p.x) + abs(p.y), 0.34, 0.10);
	} else if (g == 1) {
		// firewall — heavy square with a centre bar
		float sq = ring(max(abs(p.x), abs(p.y)), 0.34, 0.13);
		float bar = (1.0 - smoothstep(0.03, 0.06, abs(p.y))) * step(abs(p.x), 0.20);
		a = max(sq, bar);
	} else if (g == 2) {
		// worm — chevron
		a = (1.0 - smoothstep(0.05, 0.11, abs(abs(p.x) * 1.15 - (p.y + 0.22))))
			* step(abs(p.x), 0.36);
	} else if (g == 3) {
		// ICE — hexagon, doubled
		float h = max(abs(p.x) * 0.866 + abs(p.y) * 0.5, abs(p.y));
		a = max(ring(h, 0.40, 0.09), ring(h, 0.22, 0.07));
	} else if (g == 4) {
		// packet — a plus
		float v = (1.0 - smoothstep(0.10, 0.19, abs(p.x))) * step(abs(p.y), 0.42);
		float hh = (1.0 - smoothstep(0.10, 0.19, abs(p.y))) * step(abs(p.x), 0.42);
		a = max(v, hh);
	} else {
		// data shard — solid pip
		a = 1.0 - smoothstep(0.22, 0.34, length(p));
	}

	if (a < 0.02) {
		discard;
	}
	COLOR.a *= a;
}
