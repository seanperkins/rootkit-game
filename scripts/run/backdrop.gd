extends Node2D

## A faint scrolling lattice so movement reads against an otherwise empty field.

const STEP := 96.0
const COLOR := Color(0.16, 0.52, 0.40, 0.85)
var target: Node2D

func _process(_d: float) -> void:
	queue_redraw()

func _draw() -> void:
	if target == null:
		return
	var c: Vector2 = target.player_pos
	var half := Vector2(900, 560)
	var x0 := floorf((c.x - half.x) / STEP) * STEP
	var y0 := floorf((c.y - half.y) / STEP) * STEP
	var x := x0
	while x < c.x + half.x:
		draw_line(Vector2(x, c.y - half.y), Vector2(x, c.y + half.y), COLOR, 1.0)
		x += STEP
	var y := y0
	while y < c.y + half.y:
		draw_line(Vector2(c.x - half.x, y), Vector2(c.x + half.x, y), COLOR, 1.0)
		y += STEP
