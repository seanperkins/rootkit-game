extends Node2D

## The lattice and the arena wall, drawn in the isometric projection.
##
## Because the projection is a view transform over a flat simulation, the world
## is still a rectangle — it simply reads as a diamond once projected, and the
## lattice reads as the ground plane it always was.

const STEP := 96.0
const LINE := Color(0.16, 0.52, 0.40, 0.85)
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

	# Clip in WORLD space to a box around the player, then project. Clipping
	# after projection would cut the lattice along screen axes and the diagonals
	# would visibly pop.
	var reach := 1100.0
	var x0 := maxf(o.x, floorf((c.x - reach) / STEP) * STEP)
	var x1 := minf(o.x + sz.x, c.x + reach)
	var y0 := maxf(o.y, floorf((c.y - reach) / STEP) * STEP)
	var y1 := minf(o.y + sz.y, c.y + reach)

	var x := x0
	while x <= x1:
		draw_line(target.to_iso(Vector2(x, y0)), target.to_iso(Vector2(x, y1)), LINE, 1.0)
		x += STEP
	var y := y0
	while y <= y1:
		draw_line(target.to_iso(Vector2(x0, y)), target.to_iso(Vector2(x1, y)), LINE, 1.0)
		y += STEP

	_wall(o, sz, 0.0, EDGE, 3.0)
	_wall(o, sz, 10.0, GLOW, 2.0)
	_wall(o, sz, 22.0, GLOW * 0.6, 1.0)

func _wall(o: Vector2, sz: Vector2, inset: float, col: Color, w: float) -> void:
	var a := o + Vector2(inset, inset)
	var b := o + Vector2(sz.x - inset, sz.y - inset)
	draw_polyline(PackedVector2Array([
		target.to_iso(Vector2(a.x, a.y)),
		target.to_iso(Vector2(b.x, a.y)),
		target.to_iso(Vector2(b.x, b.y)),
		target.to_iso(Vector2(a.x, b.y)),
		target.to_iso(Vector2(a.x, a.y)),
	]), col, w)
