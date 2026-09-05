extends Control

## Screen-space instrument backing. Reads the run; owns no gameplay state.
var run: Node2D
var tally_height := 104.0
var alert := false
var _plate_style: StyleBoxFlat
const INK := Color(0.015, 0.035, 0.045, 0.98)
const EDGE := Color(0.20, 0.42, 0.45, 0.85)
const MINT := Color(0.45, 0.95, 0.77)

func _ready() -> void:
	_plate_style = TerminalStyle.panel_style(EDGE, INK)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _plate(rect: Rect2, accent: Color) -> void:
	draw_style_box(_plate_style, rect)
	draw_line(rect.position, rect.position + Vector2(30, 0), accent, 2.0)
	draw_line(rect.end - Vector2(30, 0), rect.end, accent, 2.0)

func _gauge(rect: Rect2, fraction: float, tint: Color, segments: int) -> void:
	draw_rect(rect, Color(0.08, 0.14, 0.17))
	var width := (rect.size.x - float(segments - 1) * 2.0) / segments
	for i in segments:
		var amount := clampf(fraction * segments - i, 0.0, 1.0)
		if amount > 0.0:
			draw_rect(Rect2(rect.position + Vector2(i * (width + 2.0), 0),
				Vector2(width * amount, rect.size.y)), tint)

func _draw() -> void:
	if run == null:
		return
	var slot: int = run.local_slot
	var health: float = clampf(run.player_health[slot] / maxf(run._eff_integrity(slot), 1), 0, 1)
	var tint := Color(1.0, 0.42, 0.32) if health < 0.3 else MINT
	_plate(Rect2(16, 16, 292, 132), tint)
	_plate(Rect2(size.x * 0.5 - 170, 16, 340, 108 if alert else 83), Color(0.43, 0.75, 1.0))
	_plate(Rect2(size.x - 292, 16, 276, tally_height), Color(0.85, 0.70, 0.35))
	_gauge(Rect2(30, 79, 264, 8), health, tint, 20)
	_gauge(Rect2(30, 133, 264, 3), float(run.xp) / maxf(run.xp_needed, 1), Color(0.40, 0.65, 1.0), 1)
