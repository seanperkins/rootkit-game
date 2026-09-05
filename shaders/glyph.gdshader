shader_type canvas_item;

// Procedural hardware: dark armor, a bright bevel, and a small emissive core.
// r = identity, g = screen-facing angle (zero faces up), b = stable phase,
// a = boss integrity / spawn integrity. Other glyphs ignore this channel.
// All animation is presentation-only; the four packed MultiMeshes stay intact.
varying flat vec4 design;
void vertex() { design = INSTANCE_CUSTOM; }

float box(vec2 p, vec2 b) {
	vec2 q = abs(p) - b;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}
float band(float d, float r, float w) { return abs(d - r) - w; }
float diamond(vec2 p, float r) { return (abs(p.x) + abs(p.y) - r) * 0.7071; }

void fragment() {
	// QuadMesh UVs have V increasing upward; canvas facing uses Y downward.
	vec2 uv = vec2(UV.x, 1.0 - UV.y) - vec2(0.5);
	float cs = cos(design.g), sn = sin(design.g);
	vec2 p = mat2(vec2(cs, -sn), vec2(sn, cs)) * uv;
	int g = int(design.r + 0.5);
	float hull = 1.0;
	float detail = 1.0;
	float core = 1.0;
	float pulse = 0.88 + 0.12 * sin(TIME * 3.0 + design.b * 6.2832);

	if (g == 0) { // daemon: split mandibles around an exposed processor
		hull = min(diamond(p, 0.36), box(vec2(abs(p.x) - 0.25, p.y - 0.12), vec2(0.07, 0.18)));
		hull = max(hull, -box(p - vec2(0.0, 0.30), vec2(0.10, 0.15)));
		core = box(p + vec2(0.0, 0.055), vec2(0.105, 0.035));
		detail = diamond(p, 0.19);
	} else if (g == 1) { // firewall: slab armor and three hot vent slots
		hull = max(box(p, vec2(0.34, 0.31)), diamond(p, 0.55));
		detail = box(p, vec2(0.245, 0.22));
		core = box(vec2(mod(p.x + 0.065, 0.13) - 0.065, p.y), vec2(0.025, 0.13));
		core = max(core, abs(p.x) - 0.22);
	} else if (g == 2 || g == 6) { // worm / tracer: articulated scutes / twin swept wings
		float chevron = max(abs(p.x) * 0.72 - p.y - 0.23, p.y - abs(p.x) * 0.42 - 0.04);
		hull = max(chevron, abs(p.x) - 0.33);
		if (g == 6) {
			hull = min(hull, box(vec2(abs(p.x) - 0.24, p.y - 0.18), vec2(0.045, 0.14)));
		} else {
			hull = min(hull, diamond(p - vec2(0.0, 0.23), 0.16));
		}
		core = box(p + vec2(0.0, 0.12), vec2(0.035, 0.065));
		detail = abs(p.x) * 0.6 - p.y - 0.08;
	} else if (g == 3 || g == 17) { // ICE fortress / captured botnet processor
		float h = max(abs(p.x) * 0.866 + abs(p.y) * 0.5, abs(p.y));
		hull = h - 0.35;
		detail = band(h, 0.24, 0.012);
		core = diamond(p, 0.12);
		if (g == 3) {
			hull = min(hull, box(vec2(abs(p.x) - 0.34, p.y), vec2(0.045, 0.10)));
			core = min(core, box(vec2(p.x, abs(p.y) - 0.28), vec2(0.08, 0.016)));
		} else {
			core = min(box(p, vec2(0.14, 0.025)), box(p, vec2(0.025, 0.14)));
		}
	} else if (g == 4) { // mine: four contact feet and armed center
		hull = min(length(p) - 0.24, min(box(p, vec2(0.39, 0.065)), box(p, vec2(0.065, 0.39))));
		detail = band(length(p), 0.19, 0.012);
		core = length(p) - 0.09 * pulse;
	} else if (g == 5) { // sentinel: lance nose, flared armored shoulders
		hull = max(abs(p.x) * 1.05 - p.y - 0.39, p.y - 0.23);
		hull = max(hull, abs(p.x) - 0.33);
		hull = max(hull, -box(p - vec2(0.0, 0.25), vec2(0.10, 0.11)));
		core = box(p + vec2(0.0, 0.04), vec2(0.027, 0.15));
		detail = abs(p.x) * 1.05 - p.y - 0.22;
	} else if (g == 7) { // watchdog: optical relay with two antenna pods
		hull = min(length(p * vec2(0.9, 1.3)) - 0.28,
			box(vec2(abs(p.x) - 0.32, p.y), vec2(0.05, 0.20)));
		detail = band(length(p), 0.15, 0.015);
		core = length(p) - 0.066;
	} else if (g == 8) { // rootkit: four disconnected cloaking petals
		hull = max(band(length(p), 0.25, 0.095), 0.055 - min(abs(p.x), abs(p.y)));
		core = diamond(p, 0.085);
		hull = min(hull, core);
		detail = band(length(p), 0.26, 0.014);
	} else if (g == 9) { // probe: paired rail barrels framing an optic
		hull = min(diamond(p - vec2(0.0, 0.08), 0.29),
			box(vec2(abs(p.x) - 0.21, p.y + 0.09), vec2(0.055, 0.25)));
		core = length(p - vec2(0.0, 0.035)) - 0.075;
		detail = box(vec2(abs(p.x) - 0.21, p.y + 0.13), vec2(0.02, 0.12));
	} else if (g == 10) { // fork bomb: two daughter cores inside a split shell
		hull = diamond(p, 0.46);
		hull = max(hull, 0.024 - abs(p.x));
		core = diamond(vec2(abs(p.x) - 0.15, p.y), 0.09);
		detail = diamond(p, 0.32);
	} else if (g == 11) { // packet filter: armored FRONT, exposed rear core
		hull = max(band(length(p), 0.30, 0.085), p.y - 0.08);
		hull = min(hull, box(p - vec2(0.0, 0.10), vec2(0.10, 0.16)));
		core = box(p - vec2(0.0, 0.16), vec2(0.052, 0.065));
		detail = band(length(p), 0.31, 0.012);
	} else if (g == 12) { // null pointer: empty aperture with offset corner brackets
		hull = band(max(abs(p.x), abs(p.y)), 0.27, 0.065);
		hull = max(hull, 0.075 - abs(p.x + p.y));
		core = box(vec2(abs(p.x) - 0.27, abs(p.y) - 0.27), vec2(0.045));
		detail = box(p, vec2(0.23));
	} else if (g == 13) { // kernel panic: reactor with eight radial cooling teeth
		float teeth = 0.30 + 0.065 * cos(atan(p.y, p.x) * 8.0);
		hull = length(p) - teeth;
		detail = band(length(p), 0.20, 0.016);
		core = min(box(p + vec2(0.0, 0.04), vec2(0.035, 0.10)), length(p - vec2(0.0, 0.14)) - 0.04);
	} else if (g == 14) { // packet: pointed data capsule, bright leading edge
		hull = max(box(p, vec2(0.12, 0.36)), diamond(p + vec2(0.0, 0.12), 0.34));
		core = box(p + vec2(0.0, 0.08), vec2(0.035, 0.16));
	} else if (g == 15) { // orbiter: three-edged cutter around a bearing
		float blade = 0.26 + 0.09 * cos(atan(p.y, p.x) * 3.0 + TIME * 7.0);
		hull = max(length(p) - blade, 0.10 - length(p));
		core = band(length(p), 0.15, 0.02);
	} else { // salvage crystal: separate identity from the sentinel
		hull = diamond(p * vec2(1.0, 0.75), 0.25);
		core = box(p, vec2(0.023, 0.11));
	}

	float aa = max(fwidth(hull), 0.006);
	float alpha = 1.0 - smoothstep(-aa, aa, hull);
	if (alpha < 0.01) { discard; }
	float edge = 1.0 - smoothstep(0.012, 0.04 + aa, abs(hull));
	float engraving = 1.0 - smoothstep(0.008, 0.019 + aa, abs(detail));
	float light = 1.0 - smoothstep(-aa, aa, core);
	vec3 tint = COLOR.rgb;
	vec3 armor = tint * (0.13 + 0.10 * clamp(0.5 - p.y - p.x * 0.5, 0.0, 1.0));
	vec3 col = mix(armor, tint * 0.85, edge);
	col = mix(col, tint * 0.48, engraving * (1.0 - edge));
	col = mix(col, mix(tint, vec3(1.8), 0.55) * pulse, light);
	if (g == 3 || (g >= 10 && g <= 13)) {
		// Health belongs to the hardware: six ICE facets, four fork chambers,
		// six front shield plates, four aperture corners, eight reactor teeth.
		// The original hull stays solid and faintly visible even when a plate
		// loses power, preserving both enemy identity and its contact footprint.
		float health = clamp(design.a, 0.0, 1.0);
		float around = fract(atan(p.y, p.x) / 6.283185 + 1.25);
		float cells = around * 6.0;
		if (g == 10 || g == 12) { cells = around * 4.0; }
		if (g == 11) {
			// Only the protected FRONT carries plating. The exposed rear core
			// remains a bright target as the shield's power drains.
			cells = clamp((atan(p.x, -p.y) / 3.141593 + 0.5) * 6.0, 0.0, 5.999);
		}
		if (g == 13) { cells = around * 8.0; }
		float count = (g == 10 || g == 12) ? 4.0 : (g == 13 ? 8.0 : 6.0);
		float power = clamp(health * count - floor(cells), 0.0, 1.0);
		float seam = 1.0 - smoothstep(0.02, 0.065, min(fract(cells), 1.0 - fract(cells)));
		// A broad dark seam separates neighboring armor plates, while a
		// powered plate has a lit face and bevel. One plate drains continuously.
		vec3 dead_plate = mix(vec3(0.06, 0.07, 0.08), tint * 0.18, edge);
		vec3 live_plate = mix(col, tint * 0.38, (1.0 - edge) * (1.0 - engraving) * 0.65);
		col = mix(dead_plate, live_plate, power);
		col = mix(col, vec3(0.025, 0.032, 0.04), seam * 0.88);
		// The exposed core heats up as armor fails. A slow, shallow pulse at
		// critical health reads as an unstable reactor without flashing the body.
		float stress = 1.0 - health;
		float heartbeat = 0.88 + 0.12 * sin(TIME * 4.0 + design.b * 6.2832);
		vec3 reactor = mix(mix(tint, vec3(1.8), 0.55), vec3(2.0, 0.48, 0.16), stress);
		col = mix(col, reactor * mix(1.0, heartbeat, stress), light);
	}
	COLOR = vec4(col, COLOR.a * alpha);
}
