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

	# The whole lattice, every frame, in fixed world positions.
	#
	# It used to be clipped to a box around the player, with the start snapped to
	# the grid and THEN clamped to the arena — but the arena origin is not a
	# multiple of STEP, so near an edge the clamp won and every line jumped to a
	# different offset as the player moved. Clipping bought nothing anyway: the
	# arena is 34 vertical lines and 21 horizontal ones.
	var k := int(ceil(o.x / STEP))
	while k * STEP <= o.x + sz.x:
		var x := k * STEP
		draw_line(target.to_iso(Vector2(x, o.y)),
			target.to_iso(Vector2(x, o.y + sz.y)), LINE, 1.0)
		k += 1
	k = int(ceil(o.y / STEP))
	while k * STEP <= o.y + sz.y:
		var y := k * STEP
		draw_line(target.to_iso(Vector2(o.x, y)),
			target.to_iso(Vector2(o.x + sz.x, y)), LINE, 1.0)
		k += 1

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
