shader_type canvas_item;

// A restrained CRT pass: thin scanlines and a soft vignette, tuned to read
// as "old terminal" without hurting the small monospace text this game is
// mostly made of. No chromatic aberration and no flicker — both cost
// legibility over a 15-20 minute run far more than they add atmosphere.
// Applied by a single always-on-top CanvasLayer (scripts/ui/crt_overlay.gd,
// an autoload) so it persists across the menu <-> run scene swap the same
// way Updater does. Code only: no image asset, matching the project-wide
// rule shaders/glyph.gdshader already states for enemy glyphs.

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;
uniform float scanline_strength : hint_range(0.0, 0.3) = 0.06;
uniform float scanline_count = 360.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.28;

void fragment() {
	vec3 color = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;

	float scan = sin(SCREEN_UV.y * scanline_count * PI) * 0.5 + 0.5;
	color *= 1.0 - scanline_strength * scan;

	vec2 centred = SCREEN_UV - vec2(0.5);
	float vign = 1.0 - dot(centred, centred) * vignette_strength;
	color *= vign;

	COLOR = vec4(color, 1.0);
}
