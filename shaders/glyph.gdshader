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
	} else if (g == 5) {
		// sentinel — heavy arrowhead, so a charge reads as a direction
		a = ring(max(abs(p.x) * 0.866 + p.y * 0.5, -p.y - 0.02), 0.30, 0.12);
	} else if (g == 6) {
		// tracer — a doubled chevron, reading as speed
		float c1 = (1.0 - smoothstep(0.04, 0.09, abs(abs(p.x) * 1.1 - (p.y + 0.30))))
			* step(abs(p.x), 0.32);
		float c2 = (1.0 - smoothstep(0.04, 0.09, abs(abs(p.x) * 1.1 - (p.y + 0.06))))
			* step(abs(p.x), 0.32);
		a = max(c1, c2);
	} else if (g == 7) {
		// watchdog — an eye: ring around a solid pupil
		a = max(ring(length(p), 0.36, 0.09),
			1.0 - smoothstep(0.09, 0.15, length(p)));
	} else if (g == 8) {
		// rootkit — a broken ring, so it reads as something not fully here
		float br = ring(length(p), 0.33, 0.11);
		float ang = atan(p.y, p.x) / 6.2832 + 0.5;
		a = br * step(0.34, abs(fract(ang * 4.0) - 0.5) * 2.0);
	} else if (g == 9) {
		// probe — a boxed sight, distinct from the packet plus
		a = max(ring(max(abs(p.x), abs(p.y)), 0.31, 0.09),
			1.0 - smoothstep(0.05, 0.11, length(p)));
	} else {
		// data shard — solid pip
		a = 1.0 - smoothstep(0.22, 0.34, length(p));
	}

	if (a < 0.02) {
		discard;
	}
	COLOR.a *= a;
}
