extends Node2D

## The lattice and the arena walls, drawn in the isometric projection.
##
## Because the projection is a view transform over a flat simulation, an arena
## is still a rectangle — it simply reads as a diamond once projected, and the
## lattice reads as the ground plane it always was.

## The lattice cell. Terrain snaps every arena edge and every corridor to it, so
## a tile is never cut part way through by the edge of the world — which is what
## made the ground read as a background image the arena stopped on top of.
const STEP := Terrain.TILE
const LINE := Color(0.07, 0.18, 0.17, 0.60)
const EDGE := Color(0.35, 1.00, 0.75, 0.9)
const GLOW := Color(0.12, 0.45, 0.34, 0.35)

## The plane has thickness. Only the two NEAR edges are drawn — in this
## projection screen-y grows with (x + y), so the near edges are y = ymax and
## x = xmax; the far two would be showing the underside of the slab.
## Each tile along those edges gets its own face, so the ground reads as a
## field of cubes rather than a sheet of paper.
const DEPTH := 30.0
const FACE_NEAR := Color(0.035, 0.125, 0.100)   # y = ymax, the lit side
const FACE_SIDE := Color(0.018, 0.070, 0.058)   # x = xmax, turned away
const RIB := Color(0.20, 0.62, 0.48, 0.75)

var target: Node2D

## Cached canvas commands, not a viewport texture: zoom/resizing stays crisp.
## Three arena roots, all BELOW the run's opaque collapse mask. Small cached
## patches let the renderer reject offscreen circuitry before submitting it.
const CIRCUIT_SHADER := preload("res://shaders/circuit.gdshader")
const CIRCUIT_HUES := [Color(0.22, 0.62, 0.44), Color(0.25, 0.50, 0.68),
	Color(0.52, 0.40, 0.64)]
const SECTOR := STEP * 3.0
const PATCH_SECTORS := 4
var _terrain: Terrain
var _visible_mask := -1
var _circuits: Array[Node2D] = []

func _process(_d: float) -> void:
	if target == null or target.terrain == null:
		return
	if _terrain != target.terrain:
		_terrain = target.terrain
		_visible_mask = -1
		for layer in _circuits:
			layer.queue_free()
		_circuits.clear()
		for i in _terrain.arenas.size():
			var layer := Node2D.new()
			layer.name = "Circuits%d" % i
			var mat := ShaderMaterial.new()
			mat.shader = CIRCUIT_SHADER
			mat.set_shader_parameter("phase", float(i) * 0.31)
			mat.set_shader_parameter("subnet", i)
			layer.material = mat
			add_child(layer)
			_circuits.append(layer)
			var arena: Rect2 = _terrain.arenas[i]
			var nx := int(arena.size.x / SECTOR)
			var ny := int(arena.size.y / SECTOR)
			for y in range(0, ny, PATCH_SECTORS):
				for x in range(0, nx, PATCH_SECTORS):
					var patch := Node2D.new()
					patch.use_parent_material = true
					var bounds := Rect2(arena.position + Vector2(x, y) * SECTOR,
						Vector2(mini(PATCH_SECTORS, nx - x), mini(PATCH_SECTORS, ny - y)) * SECTOR)
					patch.draw.connect(_draw_circuits.bind(patch, bounds, i, Vector2i(x, y)))
					layer.add_child(patch)
	# Density lowers decorative contrast smoothly; simulation never reads it.
	var quiet := 1.0 - 0.28 * clampf(float(target.enemies.count) / 400.0, 0.0, 1.0)
	modulate = modulate.lerp(Color(quiet, quiet, quiet), minf(_d * 2.0, 1.0))
	var view: Rect2 = target._visible_world_rect()
	var mask := 0
	for i in _terrain.arenas.size():
		var shown := view.intersects(_terrain.arenas[i])
		_circuits[i].visible = shown
		if shown:
			mask |= 1 << i
	# Camera motion changes the canvas transform, not the geometry. Only an
	# arena entering/leaving the view invalidates these static commands.
	if mask != _visible_mask:
		_visible_mask = mask
		queue_redraw()

func _draw() -> void:
	if target == null or target.terrain == null:
		return
	# Culled per ARENA. The map is a whole campaign now, and drawing all three
	# lattices every frame is two arenas' worth of lines nobody can see; one
	# rect test each keeps the cost where it was when there was only one.
	for i in target.terrain.arenas.size():
		if _visible_mask & (1 << i):
			_arena(target.terrain.arenas[i], i)

func _arena(r: Rect2, index: int) -> void:
	var o: Vector2 = r.position
	var sz: Vector2 = r.size
	var hue: Color = CIRCUIT_HUES[index % CIRCUIT_HUES.size()]
	var grid_colour := LINE.lerp(Color(hue.r, hue.g, hue.b, LINE.a), 0.12)
	var ground := PackedVector2Array([target.to_iso(r.position),
		target.to_iso(Vector2(r.end.x, r.position.y)), target.to_iso(r.end),
		target.to_iso(Vector2(r.position.x, r.end.y))])
	draw_colored_polygon(ground, Color(hue.r * 0.040, hue.g * 0.040, hue.b * 0.050))

	# The whole lattice for this arena, cached in fixed world positions.
	#
	# It used to be clipped to a box around the player, with the start snapped to
	# the grid and THEN clamped to the arena — but the arena origin was not a
	# multiple of STEP, so near an edge the clamp won and every line jumped to a
	# different offset as the player moved. Both ends are whole tiles now, so the
	# loop simply walks them.
	var nx := int(round(sz.x / STEP))
	var ny := int(round(sz.y / STEP))
	for k in range(nx + 1):
		var x := o.x + float(k) * STEP
		draw_line(target.to_iso(Vector2(x, o.y)),
			target.to_iso(Vector2(x, o.y + sz.y)), grid_colour, 1.0)
	for k in range(ny + 1):
		var y := o.y + float(k) * STEP
		draw_line(target.to_iso(Vector2(o.x, y)),
			target.to_iso(Vector2(o.x + sz.x, y)), grid_colour, 1.0)

	_slab(o, sz, nx, ny)
	_wall(o, sz, 0.0, EDGE, 3.0)
	_wall(o, sz, 10.0, GLOW, 2.0)
	_wall(o, sz, 22.0, GLOW * 0.6, 1.0)

## Sparse etched circuitry gives the three subnets different structures:
## routing branches, parallel memory banks, and nested core sockets. These
## are floor markings, never new obstacles. No simulation RNG is consumed.
## Each patch uses two cached multiline commands;
## the shader animates only their narrow pixels, with no screen-sized pass.
func _draw_circuits(layer: Node2D, arena: Rect2, index: int,
		sector_offset := Vector2i.ZERO) -> void:
	# Showing a previously hidden canvas can request another draw. Keep the
	# geometry too, so revisiting an arena (or an A/B flip) never regenerates
	# thousands of points in GDScript during a frame.
	var cached: Array = layer.get_meta(&"circuit_geometry", [])
	if not cached.is_empty() and cached[0] == index:
		_draw_circuit_lines(layer, cached[1], cached[2], index)
		return
	var traces := PackedVector2Array()
	var etching := PackedVector2Array()
	var nx := int(arena.size.x / SECTOR)
	var ny := int(arena.size.y / SECTOR)
	for y in ny:
		for x in nx:
			# Stable variation, including blank sectors for visual breathing room.
			var key := absi(hash(Vector3i(x + sector_offset.x, y + sector_offset.y, index)))
			if key % 5 == 0:
				continue
			var o := arena.position + Vector2(x, y) * SECTOR
			var c := o + Vector2.ONE * SECTOR * 0.5
			match index % 3:
				0:
					var turn := 40.0 + float(key % 3) * 24.0
					_path(traces, [o + Vector2(24, 48), o + Vector2(turn, 48),
						o + Vector2(turn + 48, 96), o + Vector2(turn + 48, 216),
						o + Vector2(252, 216)])
					_path(etching, [o + Vector2(24, 60), o + Vector2(turn - 6, 60),
						o + Vector2(turn + 36, 102), o + Vector2(turn + 36, 228),
						o + Vector2(252, 228)])
					_socket(etching, o + Vector2(24, 54), Vector2(12, 18))
					_socket(etching, o + Vector2(252, 222), Vector2(12, 18))
				1:
					for row in 3:
						var p := o + Vector2(64, 56 + row * 60)
						_socket(etching, p + Vector2(68, 16), Vector2(136, 32))
						_path(traces, [p + Vector2(12, 16), p + Vector2(112, 16)])
						_path(etching, [p + Vector2(-20, 16), p,
							p + Vector2(0, -8)])
					_path(traces, [o + Vector2(228, 40), o + Vector2(228, 236),
						o + Vector2(152, 236)])
				2:
					_socket(etching, c, Vector2(116, 116))
					_socket(etching, c, Vector2(92, 92))
					_path(traces, [c + Vector2(-100, -104), c + Vector2(-24, -104),
						c + Vector2(-24, -58)])
					_path(traces, [c + Vector2(24, 58), c + Vector2(24, 104),
						c + Vector2(100, 104)])
					for pin in 3:
						var offset := -24.0 + float(pin) * 24.0
						_path(etching, [c + Vector2(-82, offset), c + Vector2(-58, offset)])
						_path(etching, [c + Vector2(58, offset), c + Vector2(82, offset)])
	layer.set_meta(&"circuit_geometry", [index, traces, etching])
	_draw_circuit_lines(layer, traces, etching, index)

func _draw_circuit_lines(layer: Node2D, traces: PackedVector2Array,
		etching: PackedVector2Array, index: int) -> void:
	var hue: Color = CIRCUIT_HUES[index % CIRCUIT_HUES.size()]
	if not etching.is_empty():
		layer.draw_multiline(etching, hue * Color(0.60, 0.60, 0.60, 1.0), 1.0)
	if not traces.is_empty():
		layer.draw_multiline(traces, hue, 1.5)

func _path(out: PackedVector2Array, points: Array) -> void:
	for i in points.size() - 1:
		out.append(target.to_iso(points[i]))
		out.append(target.to_iso(points[i + 1]))

func _socket(out: PackedVector2Array, centre: Vector2, size: Vector2) -> void:
	var a := centre - size * 0.5
	var b := centre + size * 0.5
	_path(out, [a, Vector2(b.x, a.y), b, Vector2(a.x, b.y), a])

func _slab(o: Vector2, sz: Vector2, nx: int, ny: int) -> void:
	var x0 := o.x
	var x1 := o.x + sz.x
	var y0 := o.y
	var y1 := o.y + sz.y
	var down := Vector2(0.0, DEPTH)

	# Near face: the y = y1 edge, running along x. One face per whole tile —
	# there are no partial tiles any more, so the last one is flush with the
	# wall rather than a sliver of a different width.
	for i in nx:
		var a: Vector2 = target.to_iso(Vector2(x0 + float(i) * STEP, y1))
		var b: Vector2 = target.to_iso(Vector2(x0 + float(i + 1) * STEP, y1))
		draw_colored_polygon(PackedVector2Array([a, b, b + down, a + down]), FACE_NEAR)
		draw_line(a, a + down, RIB, 1.0)
	# Side face: the x = x1 edge, running along y.
	for i in ny:
		var a2: Vector2 = target.to_iso(Vector2(x1, y0 + float(i) * STEP))
		var b2: Vector2 = target.to_iso(Vector2(x1, y0 + float(i + 1) * STEP))
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
