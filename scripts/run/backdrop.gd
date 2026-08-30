extends Node2D

## The lattice, and the edge of the map.
##
## The grid previously drew around the player without reference to the arena, so
## the world looked infinite and you could walk into an invisible wall. Lines
## stop at the boundary and the boundary itself is drawn.

const STEP := 96.0
const LINE := Color(0.10, 0.30, 0.24, 0.55)
const EDGE := Color(0.35, 1.00, 0.75, 0.9)
const GLOW := Color(0.12, 0.45, 0.34, 0.35)

var target: Node2D

func _process(_d: float) -> void:
	queue_redraw()

func _draw() -> void:
	if target == null:
		return
	var o: Vector2 = target.ARENA_ORIGIN
	var sz: Vector2 = target.ARENA_SIZE
	var c: Vector2 = target.player_pos
	var half := Vector2(940, 600)

	# Only draw the lattice inside the arena, and only near the player.
	var x0 := maxf(o.x, floorf((c.x - half.x) / STEP) * STEP)
	var x1 := minf(o.x + sz.x, c.x + half.x)
	var y0 := maxf(o.y, floorf((c.y - half.y) / STEP) * STEP)
	var y1 := minf(o.y + sz.y, c.y + half.y)

	var x := x0
	while x <= x1:
		draw_line(Vector2(x, y0), Vector2(x, y1), LINE, 1.0)
		x += STEP
	var y := y0
	while y <= y1:
		draw_line(Vector2(x0, y), Vector2(x1, y), LINE, 1.0)
		y += STEP

	# The wall. Doubled line plus an inner falloff band so the edge reads before
	# you are against it.
	var r := Rect2(o, sz)
	draw_rect(r, EDGE, false, 3.0)
	draw_rect(Rect2(o + Vector2(10, 10), sz - Vector2(20, 20)), GLOW, false, 2.0)
	draw_rect(Rect2(o + Vector2(22, 22), sz - Vector2(44, 44)), GLOW * 0.6, false, 1.0)
