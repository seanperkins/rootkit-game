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

## The plane has thickness. Only the two NEAR edges are drawn — in this
## projection screen-y grows with (x + y), so the near edges are y = ymax and
## x = xmax; the far two would be showing the underside of the slab.
## Each grid cell along those edges gets its own face, so the ground reads as a
## field of cubes rather than a sheet of paper.
const DEPTH := 30.0
const FACE_NEAR := Color(0.035, 0.125, 0.100)   # y = ymax, the lit side
const FACE_SIDE := Color(0.018, 0.070, 0.058)   # x = xmax, turned away
const RIB := Color(0.20, 0.62, 0.48, 0.75)

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

	_slab(o, sz)
	_wall(o, sz, 0.0, EDGE, 3.0)
	_wall(o, sz, 10.0, GLOW, 2.0)
	_wall(o, sz, 22.0, GLOW * 0.6, 1.0)

## Breakpoints along an axis: the arena ends plus every grid line between them.
## The arena origin is not a multiple of STEP, so the first and last cells are
## partial — including the ends keeps the faces flush with the wall.
func _breaks(lo: float, hi: float) -> PackedFloat32Array:
	var out := PackedFloat32Array([lo])
	var k := int(ceil(lo / STEP))
	while k * STEP < hi:
		if k * STEP > lo:
			out.append(k * STEP)
		k += 1
	out.append(hi)
	return out

func _slab(o: Vector2, sz: Vector2) -> void:
	var x0 := o.x
	var x1 := o.x + sz.x
	var y0 := o.y
	var y1 := o.y + sz.y
	var down := Vector2(0.0, DEPTH)

	# Near face: the y = y1 edge, running along x.
	var xs := _breaks(x0, x1)
	for i in xs.size() - 1:
		var a: Vector2 = target.to_iso(Vector2(xs[i], y1))
		var b: Vector2 = target.to_iso(Vector2(xs[i + 1], y1))
		draw_colored_polygon(PackedVector2Array([a, b, b + down, a + down]), FACE_NEAR)
		draw_line(a, a + down, RIB, 1.0)
	# Side face: the x = x1 edge, running along y.
	var ys := _breaks(y0, y1)
	for i in ys.size() - 1:
		var a2: Vector2 = target.to_iso(Vector2(x1, ys[i]))
		var b2: Vector2 = target.to_iso(Vector2(x1, ys[i + 1]))
		draw_colored_polygon(PackedVector2Array([a2, b2, b2 + down, a2 + down]), FACE_SIDE)
		draw_line(a2, a2 + down, RIB, 1.0)

	# The bottom rail, and the vertical at the near corner where they meet.
	var corner_l: Vector2 = target.to_iso(Vector2(x0, y1))
	var corner_n: Vector2 = target.to_iso(Vector2(x1, y1))
	var corner_r: Vector2 = target.to_iso(Vector2(x1, y0))
	draw_line(corner_l + down, corner_n + down, EDGE, 2.0)
	draw_line(corner_n + down, corner_r + down, EDGE, 2.0)
	draw_line(corner_l, corner_l + down, EDGE, 2.0)
	draw_line(corner_n, corner_n + down, EDGE, 2.0)
	draw_line(corner_r, corner_r + down, EDGE, 2.0)

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
