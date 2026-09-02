extends Node2D

## Everything that STANDS on the floor: walls, the corridor's rails, and the
## gate's posts and lintel.
##
## Its own canvas, above every entity layer, because these are objects you walk
## behind. Sharing the run's canvas put them under the four MultiMesh pools, so
## an enemy behind a wall was drawn on top of it and the wall read as a marking
## on the ground rather than a thing in the way.
##
## They are drawn TRANSLUCENT, which is what makes that affordable. Occluding
## everything is not the same as depth-sorting against everything: a proper
## isometric renderer would order each wall against each entity by x + y, and
## that is not available here — the entities live in four MultiMeshInstance2D
## nodes that cannot interleave with per-wall draws. So a wall also covers what
## stands in FRONT of it, and the transparency is what turns that from an
## entity vanishing into an entity seen through glass.

const WALL_HEIGHT := 26.0
const POST_HEIGHT := 78.0

## Faces are see-through; edges are not. The wireframe is what carries the
## shape, and it is also what blooms under the HDR glow — dimming it to match
## the faces would take the objects out of the world's visual language.
const FACE_ALPHA := 0.6

const WALL_TOP := Color(0.10, 0.26, 0.21, FACE_ALPHA)
const WALL_NEAR := Color(0.055, 0.16, 0.13, FACE_ALPHA)
const WALL_SIDE := Color(0.03, 0.10, 0.085, FACE_ALPHA)
const WALL_EDGE := Color(0.40, 0.95, 0.70)

const RAIL_TOP := Color(0.08, 0.20, 0.17, FACE_ALPHA)
const RAIL_NEAR := Color(0.045, 0.13, 0.11, FACE_ALPHA)
const RAIL_SIDE := Color(0.025, 0.08, 0.07, FACE_ALPHA)
const RAIL_EDGE := Color(0.30, 0.72, 0.55)

## The far edges of the box — the ones no face is drawn for. Well under the near
## wireframe: at parity the box read as a wire cage with no front and no back,
## which is a different object from a solid you can see into.
const BACK_EDGE_SCALE := 0.35

## The block's own palette, warmer than the walls, because it is the one object
## on the floor you are meant to walk INTO rather than around.
const BLOCK_TOP := Color(0.28, 0.22, 0.06, FACE_ALPHA)
const BLOCK_NEAR := Color(0.18, 0.14, 0.04, FACE_ALPHA)
const BLOCK_SIDE := Color(0.11, 0.09, 0.03, FACE_ALPHA)
const BLOCK_EDGE := Color(1.6, 1.15, 0.35)
const BLOCK_SIZE := 34.0
const BLOCK_HEIGHT := 40.0
## Segments in the hold ring. Enough that a partial arc reads as a fraction.
const BLOCK_ARC := 48

## A wall standing on ground that has gone falls with it. Screen-space gravity,
## matching the floor chunks in run.gd — a wall left hanging in the air over a
## hole is the single clearest way to tell the player none of this is solid.
const PROP_GRAVITY := 900.0
const PROP_FALL_LIFE := 2.2

var target: Node2D

## rect index -> seconds since its floor went. Keyed by index into
## terrain.rects, which is stable for the life of an arena.
var _falling: Dictionary = {}

func _process(d: float) -> void:
	# The frame delta, clamped. The hitstop freezes the world for whole ticks now
	# rather than scaling a process-global clock, so a collapsing wall keeps
	# falling at display rate with nothing to divide back out.
	var udt: float = minf(d, 0.1)
	# A new subnet clears `voided`, and rect indices belong to the arena that
	# was collapsing — carrying fall timers across would drop walls the player
	# has not reached yet.
	if target != null and target.terrain != null \
			and target.terrain.voided.is_empty() and not _falling.is_empty():
		_falling.clear()
	for k in _falling:
		_falling[k] += udt
	queue_redraw()

## Every cell under a wall gone, not merely its centre: a wall spanning the
## collapse frontier should stand until the last of its footing goes, which is
## also what stops the whole row dropping in one frame.
func _floor_gone(terrain: Terrain, r: Rect2) -> bool:
	var step := Terrain.CELL
	var y := r.position.y + step * 0.5
	while y < r.end.y:
		var x := r.position.x + step * 0.5
		while x < r.end.x:
			if not terrain.is_void(Vector2(x, y)):
				return false
			x += step
		y += step
	return true

## One extruded box, drawn with the same face convention as the arena slab in
## backdrop.gd: the y = max edge is the lit near face and the x = max edge is
## the darker one turned away. Sharing that convention is what stops a wall
## looking like it is lit from a different sun than the ground it stands on.
##
## Only the two near faces and the top are filled — the far two would be showing
## the inside of the box. Their EDGES are drawn, though, which is the whole
## point of the faces being translucent: you can see the back of the shape.
func draw_box(r: Rect2, height: float, top: Color, near: Color, side: Color,
		edge: Color, drop: float = 0.0) -> void:
	var up := Vector2(0.0, -height)
	var d := Vector2(0.0, drop)
	var g00: Vector2 = target.to_iso(r.position) + d
	var g10: Vector2 = target.to_iso(Vector2(r.end.x, r.position.y)) + d
	var g11: Vector2 = target.to_iso(r.end) + d
	var g01: Vector2 = target.to_iso(Vector2(r.position.x, r.end.y)) + d
	var back := Color(edge.r, edge.g, edge.b, edge.a * BACK_EDGE_SCALE)

	# The far side first, so the near wireframe is drawn over it rather than
	# fighting it where they cross.
	draw_line(g00, g10, back, 1.0)
	draw_line(g00, g01, back, 1.0)
	draw_line(g00, g00 + up, back, 1.0)

	# Faces, then the top outline, so the top edge reads as the near silhouette.
	draw_colored_polygon(PackedVector2Array([g01, g11, g11 + up, g01 + up]), near)
	draw_colored_polygon(PackedVector2Array([g10, g11, g11 + up, g10 + up]), side)
	draw_colored_polygon(PackedVector2Array([
		g00 + up, g10 + up, g11 + up, g01 + up]), top)
	draw_polyline(PackedVector2Array([
		g00 + up, g10 + up, g11 + up, g01 + up, g00 + up]), edge, 1.5)

	# The base, where the box meets the floor, and the three near verticals.
	draw_line(g01, g11, edge, 1.0)
	draw_line(g10, g11, edge, 1.0)
	draw_line(g01, g01 + up, edge, 1.0)
	draw_line(g11, g11 + up, edge, 1.5)
	draw_line(g10, g10 + up, edge, 1.0)

func _draw() -> void:
	if target == null or target.terrain == null:
		return
	var view: Rect2 = target._visible_world_rect()
	var terrain: Terrain = target.terrain

	for ri in terrain.rects.size():
		var entry = terrain.rects[ri]
		if entry[1] != Terrain.Kind.WALL:
			continue        # zones are conditions of the floor, not objects
		var tr: Rect2 = entry[0]
		if not view.intersects(tr):
			continue
		var drop := 0.0
		if not terrain.voided.is_empty():
			if not _falling.has(ri) and _floor_gone(terrain, tr):
				_falling[ri] = 0.0
			if _falling.has(ri):
				var ft: float = _falling[ri]
				if ft >= PROP_FALL_LIFE:
					continue        # gone entirely
				drop = 0.5 * PROP_GRAVITY * ft * ft
		var fade: float = 1.0
		if _falling.has(ri):
			fade = clampf(1.0 - float(_falling[ri]) / PROP_FALL_LIFE, 0.0, 1.0)
		draw_box(tr, WALL_HEIGHT,
			Color(WALL_TOP.r, WALL_TOP.g, WALL_TOP.b, WALL_TOP.a * fade),
			Color(WALL_NEAR.r, WALL_NEAR.g, WALL_NEAR.b, WALL_NEAR.a * fade),
			Color(WALL_SIDE.r, WALL_SIDE.g, WALL_SIDE.b, WALL_SIDE.a * fade),
			Color(WALL_EDGE.r, WALL_EDGE.g, WALL_EDGE.b, WALL_EDGE.a * fade),
			drop)

	for gi in terrain.gates.size():
		var g: Terrain.Gate = terrain.gates[gi]
		var cr: Rect2 = g.corridor
		if not view.intersects(cr):
			continue
		var along := Vector2(absf(g.dir.x), absf(g.dir.y))
		var rail := (Vector2(along.y, along.x) * 22.0
			+ along * cr.size).max(Vector2(22, 22))
		draw_box(Rect2(cr.position, rail), WALL_HEIGHT,
			RAIL_TOP, RAIL_NEAR, RAIL_SIDE, RAIL_EDGE)
		draw_box(Rect2(cr.end - rail, rail), WALL_HEIGHT,
			RAIL_TOP, RAIL_NEAR, RAIL_SIDE, RAIL_EDGE)

		# The gate: two standing posts and a lintel across them. A ring lay flat
		# on the ground in a world drawn as solid objects, which is why it read
		# as a marking rather than as a doorway.
		var gside := Vector2(-g.dir.y, g.dir.x)
		var gcol := Color(0.30, 0.50, 0.44)
		var gtop := Color(0.07, 0.17, 0.15, FACE_ALPHA)
		if g.open:
			var gp := 0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.004)
			gcol = Color(0.45 * gp, 1.7 * gp, 1.1 * gp)
			gtop = Color(0.12 * gp, 0.42 * gp, 0.30 * gp, FACE_ALPHA)
		var reach: float = Terrain.CORRIDOR_HALF_WIDTH + 16.0
		for sgn in [1.0, -1.0]:
			var centre: Vector2 = g.pos + gside * reach * sgn
			draw_box(Rect2(centre - Vector2(15, 15), Vector2(30, 30)),
				POST_HEIGHT, gtop, gtop.darkened(0.3), gtop.darkened(0.5), gcol)
		var up := Vector2(0.0, -POST_HEIGHT)
		var l1: Vector2 = target.to_iso(g.pos + gside * reach) + up
		var l2: Vector2 = target.to_iso(g.pos - gside * reach) + up
		draw_line(l1, l2, gcol, 3.0)
		draw_line(l1 + Vector2(0, 8), l2 + Vector2(0, 8), gcol.darkened(0.4), 2.0)

	_draw_block()

## The capture point: a standing box, plus the hold ring drawn FLAT on the ground
## rather than on the box — the ring is the area you have to be inside, and
## putting it on the prop would read as decoration on the object instead.
func _draw_block() -> void:
	var b = target.blocks
	if b == null or not b.alive:
		return
	var r := Rect2(b.pos - Vector2(BLOCK_SIZE, BLOCK_SIZE) * 0.5,
		Vector2(BLOCK_SIZE, BLOCK_SIZE))
	draw_box(r, BLOCK_HEIGHT, BLOCK_TOP, BLOCK_NEAR, BLOCK_SIDE, BLOCK_EDGE)

	# The full circle dim, the held arc bright: the unfilled part has to be
	# visible or there is nothing for the fill to read against.
	var whole := PackedVector2Array()
	for i in BLOCK_ARC + 1:
		var a := TAU * float(i) / float(BLOCK_ARC) - PI * 0.5
		whole.append(target.to_iso(b.pos + Vector2(cos(a), sin(a)) * Blocks.RADIUS))
	draw_polyline(whole, BLOCK_EDGE.darkened(0.65), 1.0)

	var filled: int = int(round(float(BLOCK_ARC) * b.fraction()))
	if filled > 0:
		draw_polyline(whole.slice(0, filled + 1), BLOCK_EDGE, 3.0)
