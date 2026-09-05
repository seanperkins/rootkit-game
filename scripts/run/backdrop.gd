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
			mat.set_shader_parameter("subnet", maxi(_terrain.subnet_number - 1, i))
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
					patch.draw.connect(_draw_circuits.bind(patch, bounds, maxi(_terrain.subnet_number - 1, i), Vector2i(x, y)))
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
			_arena(target.terrain.arenas[i], maxi(target.terrain.subnet_number - 1, i))

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
	# Patches are only a rendering budget, not visible placement cells. Scatter
	# small clusters across their edges so the board has uneven open areas.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str("circuits:", index, ":", sector_offset, ":", _terrain.spawner_pos(0, 0)))
	var clusters := PackedVector2Array()
	for k in rng.randi_range(2, 4):
		clusters.append(arena.position + arena.size * Vector2(rng.randf(), rng.randf()))
	var count := maxi(1, int(arena.get_area() / (SECTOR * SECTOR) * 0.55) + rng.randi_range(-2, 2))
	var placed := PackedVector2Array()
	var radii := PackedFloat32Array()
	var outer: Rect2 = _terrain.arenas[0 if _terrain.subnet_number > 0 else index]
	for attempt in count * 12:
		if placed.size() >= count: break
		var centre := arena.position + arena.size * Vector2(rng.randf(), rng.randf())
		if rng.randf() < 0.7:
			centre = clusters[rng.randi_range(0, clusters.size() - 1)] + arena.size * Vector2(rng.randf_range(-0.28, 0.28), rng.randf_range(-0.28, 0.28))
		var scale := Vector2(rng.randf_range(0.65, 1.20), rng.randf_range(0.60, 1.10))
		var radius := 175.0 * maxf(scale.x, scale.y)
		if not outer.grow(-radius).has_point(centre): continue
		var crowded := false
		for k in placed.size():
			if centre.distance_to(placed[k]) < (radius + radii[k]) * 0.75:
				crowded = true
				break
		if crowded: continue
		placed.append(centre)
		radii.append(radius)
		var local_traces := PackedVector2Array()
		var local_etching := PackedVector2Array()
		_circuit_motif(local_traces, local_etching, index, rng)
		var axis: Vector2 = [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP][rng.randi_range(0, 3)]
		if rng.randf() < 0.5: scale.x = -scale.x
		var transform := Transform2D(axis * scale.x, Vector2(-axis.y, axis.x) * scale.y, centre)
		for point in local_traces: traces.append(target.to_iso(transform * point))
		for point in local_etching: etching.append(target.to_iso(transform * point))
	layer.set_meta(&"circuit_geometry", [index, traces, etching])
	_draw_circuit_lines(layer, traces, etching, index)

## Order within a device is deliberate; device size, routing and placement vary.
## Build in local board coordinates, then orient/project the whole component.
func _circuit_motif(traces: PackedVector2Array, etching: PackedVector2Array,
		index: int, rng: RandomNumberGenerator) -> void:
	match index % 3:
		0:
			var half := Vector2(rng.randf_range(80, 135), rng.randf_range(50, 105))
			var bend := rng.randf_range(-half.x * 0.45, half.x * 0.15)
			var route := [Vector2(-half.x, -half.y), Vector2(bend, -half.y),
				Vector2(bend + 32, -half.y + 32), Vector2(bend + 32, half.y), half]
			_path(traces, route)
			if rng.randf() < 0.65:
				var parallel := []
				for point in route: parallel.append(point + Vector2(-9, 10))
				_path(etching, parallel)
			if rng.randf() < 0.55:
				var tap := Vector2(bend + 32, half.y * 0.25)
				var end := Vector2(half.x, tap.y - 28)
				_path(etching, [tap, tap + Vector2(28, -28), end])
				_socket(etching, end, Vector2(10, 10))
			_socket(etching, route[0], Vector2(12, 16))
			_socket(etching, route[-1], Vector2(14, 12))
		1:
			var rows := rng.randi_range(2, 4)
			var pitch := rng.randf_range(38, 56)
			var width := rng.randf_range(90, 156)
			var top := -float(rows - 1) * pitch * 0.5
			for row in rows:
				var p := Vector2(0, top + row * pitch)
				_socket(etching, p, Vector2(width, 24))
				_path(traces, [p + Vector2(-width * 0.5 + 12, 0), p + Vector2(width * 0.5 - 12, 0)])
				_path(etching, [p + Vector2(-width * 0.5 - 20, -14), p + Vector2(-width * 0.5, 0)])
			_path(traces, [Vector2(width * 0.5 + 24, top - 20),
				Vector2(width * 0.5 + 24, -top + 26), Vector2(rng.randf_range(-40, 20), -top + 26)])
		2:
			var half := Vector2(rng.randf_range(40, 65), rng.randf_range(40, 65))
			_socket(etching, Vector2.ZERO, half * 2)
			if rng.randf() < 0.75: _socket(etching, Vector2.ZERO, half * 2 - Vector2(20, 20))
			var reach := rng.randf_range(30, 58)
			_path(traces, [Vector2(-half.x - reach, -half.y - 36),
				Vector2(-20, -half.y - 36), Vector2(-20, -half.y)])
			_path(traces, [Vector2(20, half.y), Vector2(20, half.y + reach),
				Vector2(half.x + 34, half.y + reach)])
			var pins := rng.randi_range(2, 4)
			for pin in pins:
				var offset := (float(pin) - float(pins - 1) * 0.5) * 18
				_path(etching, [Vector2(-half.x - 22, offset), Vector2(-half.x, offset)])
				_path(etching, [Vector2(half.x, offset), Vector2(half.x + 22, offset)])

func _draw_circuit_lines(layer: Node2D, traces: PackedVector2Array,
		etching: PackedVector2Array, index: int) -> void:
	var hue: Color = CIRCUIT_HUES[index % CIRCUIT_HUES.size()]
	if not etching.is_empty():
		layer.draw_multiline(etching, hue * Color(0.60, 0.60, 0.60, 1.0), 1.0)
	if not traces.is_empty():
		layer.draw_multiline(traces, hue, 1.5)

func _path(out: PackedVector2Array, points: Array) -> void:
	for i in points.size() - 1:
		out.append(points[i])
		out.append(points[i + 1])

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
