shader_type canvas_item;

// A restrained CRT pass drawn as a translucent overlay, not a post-process
// read of the screen: thin scanlines and a soft vignette, both pure
// per-pixel alpha blended over whatever is already drawn. SCREEN_UV gives
// screen-space position for free; the earlier version additionally sampled
// hint_screen_texture, which forces Godot to copy the backbuffer every
// frame — measured with tools/fps_probe.gd at 600 enemies/400 proj/1500
// shards/64 botnet: mean frame time 16.65 -> 27.79 ms (roughly doubled,
// 60fps -> 36fps) for a pass that adds no information, only darkens. This
// version needs no copy: COLOR.a alone controls how much "ink" lands on
// top of the real frame, so there is nothing here to read back.
//
// No chromatic aberration and no flicker — both cost legibility on 15-20
// minutes of small monospace text far more than they add atmosphere.
// Applied by a single always-on-top CanvasLayer
// (scripts/ui/crt_overlay.gd, an autoload) so it persists across the menu
// <-> run scene swap the same way Updater does.

uniform float scanline_strength : hint_range(0.0, 0.3) = 0.06;
uniform float scanline_count = 360.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.22;

void fragment() {
	float scan = sin(SCREEN_UV.y * scanline_count * PI) * 0.5 + 0.5;
	vec2 centred = SCREEN_UV - vec2(0.5);
	float vign = dot(centred, centred) * vignette_strength;
	COLOR = vec4(0.0, 0.0, 0.0, clamp(scanline_strength * scan + vign, 0.0, 1.0));
}
