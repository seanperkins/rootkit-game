extends SceneTree

## The terrain layer: cell lookup, generation, connectivity, zones, and the
## corridors that join one subnet's arena to the next.

var failures := 0
var checks := 0
var finished := {}

## A runtime error inside a test function aborts THAT FUNCTION and nothing else:
## GDScript prints the error, _initialize carries on, and a suite whose asserts
## never ran reports PASS with exit code 0 — a silent green.
##
## So every case marks itself done on its LAST line, and the suite fails if any
## mark is missing. Counting assertions would work too, but the count has to be
## updated every time one is added and it goes stale silently; a name that never
## arrives cannot go stale.
const CASES := [
	"cell_lookup", "density_scales_with_subnet", "generation_is_deterministic",
	"every_open_cell_is_reachable", "the_playfield_never_collapses",
	"the_start_is_clear", "zones_are_placed_in_the_open", "sliding_along_walls",
	"enemies_avoid_and_never_embed", "spawn_points_find_open_ground",
	"the_map_is_laid_out_on_whole_tiles", "arenas_never_overlap",
	"corridors_join_one_arena_to_the_next", "a_shut_gate_bars_only_its_corridor",
]

## A whole EVEN number of Terrain.TILE either way, which is what lets the arena
## be centred on the origin and still land on tile boundaries.
const SIZE := Vector2(3072, 1920)
const ORIGIN := -SIZE * 0.5

func _initialize() -> void:
	print("ROOTKIT — terrain\n")
	cell_lookup()
	density_scales_with_subnet()
	generation_is_deterministic()
	every_open_cell_is_reachable()
	the_playfield_never_collapses()
	the_start_is_clear()
	zones_are_placed_in_the_open()
	sliding_along_walls()
	enemies_avoid_and_never_embed()
	spawn_points_find_open_ground()
	the_map_is_laid_out_on_whole_tiles()
	arenas_never_overlap()
	corridors_join_one_arena_to_the_next()
	a_shut_gate_bars_only_its_corridor()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all %d assertions" % checks)
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

## One arena and therefore no gates: the cases about walls, zones and collision
## do not care how many subnets there are, and one is much the cheapest.
func _fresh() -> Terrain:
	return Terrain.new(SIZE)

## The real shape of a run: three arenas, two corridors.
func _campaign(layout_seed: int = 0) -> Terrain:
	return Terrain.new(SIZE, 3, layout_seed)

func cell_lookup() -> void:
	var t := _fresh()
	# The grid is deliberately LARGER than the arena: the corridors between
	# arenas and the rock border around the lot are cells on this same grid,
	# which is what makes walking between subnets continuous.
	_check("the grid covers the arena plus a margin either side", t.w,
		int((SIZE.x + Terrain.MARGIN * 2.0) / Terrain.CELL))
	_check("in both axes", t.h,
		int((SIZE.y + Terrain.MARGIN * 2.0) / Terrain.CELL))
	_check("and the arena rect is remembered", t.arena(), Rect2(ORIGIN, SIZE))
	_check("a lone arena has no gate", t.has_gate(), false)
	_check("and no gate object either", t.gate(), null)
	_check("a fresh field is entirely open", t.is_solid(Vector2.ZERO), false)
	_check("a fresh field has no zones", t.zone_at(Vector2.ZERO), -1)

	# Beyond the whole GRID is open, so spawn rings that fall off the edge are
	# not rejected. The margin's own cells are made solid by generate().
	_check("far outside the grid is open", t.is_solid(Vector2(-90000, -90000)), false)
	_check("outside the grid has no zone", t.zone_at(Vector2(-90000, -90000)), -1)

	t.solid[t.cell_index(Vector2(0, 0))] = 1
	_check("a written cell reads back solid", t.is_solid(Vector2(0, 0)), true)
	_check("its neighbour is untouched", t.is_solid(Vector2(64, 0)), false)
	_check("the grid origin maps to cell 0", t.cell_index(t.origin), 0)
	_check("the last cell is in range",
		t.cell_index(t.origin + t.size - Vector2(1, 1)), t.w * t.h - 1)

	# Generation walls off everything outside the arenas, so the world is bounded.
	var g := _fresh()
	g.generate(1, Vector2.ZERO)
	_check("outside the arena is rock after generation",
		g.is_solid(ORIGIN - Vector2(200, 200)), true)
	_check("inside it is not", g.is_solid(Vector2.ZERO), false)
	finished["cell_lookup"] = true

func density_scales_with_subnet() -> void:
	_check("subnet 1 is the base density", Terrain.density_for(1), Terrain.DENSITY_BASE)
	# FLAT. Later subnets get harder through enemies and HP, not by taking away
	# room to move — the ramp made late subnets feel cramped rather than hard.
	_check("subnet 3 is the same", Terrain.density_for(3), Terrain.DENSITY_BASE)
	# Subnet 0 must not underflow into a negative density.
	_check("subnet 0 clamps to the base", Terrain.density_for(0), Terrain.DENSITY_BASE)
	finished["density_scales_with_subnet"] = true

func generation_is_deterministic() -> void:
	var a := _campaign(7); a.generate(4242, Vector2.ZERO)
	var b := _campaign(7); b.generate(4242, Vector2.ZERO)
	var c := _campaign(7); c.generate(9999, Vector2.ZERO)
	_check("same seed gives the same walls", a.solid, b.solid)
	_check("same seed gives the same rects", a.rects.size(), b.rects.size())
	_check("and the same gates", a.gates[0].pos, b.gates[0].pos)
	_check("a different seed gives a different map", a.solid == c.solid, false)
	# Each arena is rolled from its own derived seed, so subnet 02 is not a
	# copy of subnet 01 sitting one corridor along.
	var ac := a.arena_cells(0)
	var bc := a.arena_cells(1)
	var same := true
	for y in range(ac.size.y):
		for x in range(ac.size.x):
			if a.solid[(ac.position.y + y) * a.w + ac.position.x + x] \
					!= a.solid[(bc.position.y + y) * a.w + bc.position.x + x]:
				same = false
	_check("and the three arenas are not copies of each other", same, false)
	finished["generation_is_deterministic"] = true

## The invariant the whole generator exists to protect. A sealed pocket is an
## unwinnable run: ICE, or the player, spawned inside one can never be reached —
## and with the campaign on one grid, an arena whose mouth was walled off would
## be filled in wholesale as a pocket.
func every_open_cell_is_reachable() -> void:
	var bad := 0
	for s in range(200):
		var t := _fresh()
		t.generate(s, Vector2.ZERO)
		if not _fully_connected(t, Vector2.ZERO):
			bad += 1
	_check("200 seeds, no unreachable open cell", bad, 0)

	var bad3 := 0
	for s in range(40):
		var t := _campaign(s)
		t.generate(s, Vector2.ZERO)
		if not _fully_connected(t, Vector2.ZERO):
			bad3 += 1
	_check("and 40 whole campaigns, all three arenas joined", bad3, 0)
	finished["every_open_cell_is_reachable"] = true

func the_playfield_never_collapses() -> void:
	var worst := 1.0
	for s in range(200):
		var t := _fresh()
		t.generate(s, Vector2.ZERO)
		worst = minf(worst, t.reachable_fraction(Vector2.ZERO))
	print("    worst reachable fraction over 200 seeds: %.3f" % worst)
	_check("the arena never shrinks to a closet",
		worst >= Terrain.REACHABLE_FLOOR, true)
	finished["the_playfield_never_collapses"] = true

func the_start_is_clear() -> void:
	var bad := 0
	for s in range(100):
		var t := _fresh()
		t.generate(s, Vector2.ZERO)
		if t.is_solid(Vector2.ZERO):
			bad += 1
		# The whole spawn-safe disc, not just its centre.
		for k in 16:
			var a := TAU * k / 16.0
			if t.is_solid(Vector2(cos(a), sin(a)) * (Terrain.WALL_MARGIN - 40.0)):
				bad += 1
	_check("the player never starts in or beside rock", bad, 0)

	# The same margin applies to every ARRIVAL, not only the start: an arena is
	# entered at its corridor mouth, and rock there is rock you walk into.
	var arrivals := 0
	for s in range(40):
		var t := _campaign(s)
		t.generate(s, Vector2.ZERO)
		for g in t.gates:
			for k in 16:
				var a := TAU * k / 16.0
				var p: Vector2 = g.end + Vector2(cos(a), sin(a)) \
					* (Terrain.WALL_MARGIN - 40.0)
				# Only the half of the disc that lies in the arena being
				# entered; behind the mouth is the corridor's own rock wall.
				if t.arenas[t.gates.find(g) + 1].has_point(p) and t.is_solid(p):
					arrivals += 1
	_check("nor arrives in or beside it", arrivals, 0)
	finished["the_start_is_clear"] = true

## An independent flood fill, written in the TEST rather than reusing the
## generator's. Reusing it would only prove the generator agrees with itself.
func _fully_connected(t: Terrain, start: Vector2) -> bool:
	var seen := {}
	var stack := [t.cell_index(start)]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if i < 0 or seen.has(i) or t.solid[i] != 0:
			continue
		seen[i] = true
		var x := i % t.w
		var y := i / t.w
		if x > 0: stack.append(i - 1)
		if x < t.w - 1: stack.append(i + 1)
		if y > 0: stack.append(i - t.w)
		if y < t.h - 1: stack.append(i + t.w)
	for i in t.solid.size():
		if t.solid[i] == 0 and not seen.has(i):
			return false
	return true

func zones_are_placed_in_the_open() -> void:
	var overlapping := 0
	for s in range(60):
		var t := _fresh()
		t.generate(s, Vector2.ZERO)
		for i in t.zone.size():
			# A zone cell may never also be a wall cell: a hazard you cannot
			# walk into is not a hazard.
			if t.zone[i] != 0 and t.solid[i] != 0:
				overlapping += 1
	_check("no zone cell is also a wall", overlapping, 0)

	var t2 := _fresh()
	t2.generate(11, Vector2.ZERO)
	var kinds := {}
	for i in t2.zone.size():
		if t2.zone[i] != 0:
			kinds[int(t2.zone[i]) - 1] = true
	_check("zones exist", kinds.size() > 0, true)
	var all_valid := true
	for k in kinds:
		if not (k in [Terrain.Kind.HAZARD, Terrain.Kind.SLOW, Terrain.Kind.CORRUPTION]):
			all_valid = false
	_check("every placed zone is a real effect kind", all_valid, true)
	_check("WALL is never written into the zone layer",
		kinds.has(Terrain.Kind.WALL), false)

	# Every arena gets its own, not just the one the player starts in.
	var t3 := _campaign(3)
	t3.generate(5, Vector2.ZERO)
	var per_arena := true
	for k in t3.arenas.size():
		var c := t3.arena_cells(k)
		var n := 0
		for y in range(c.position.y, c.end.y):
			for x in range(c.position.x, c.end.x):
				if t3.zone[y * t3.w + x] != 0:
					n += 1
		if n == 0:
			per_arena = false
	_check("every arena in the campaign has zones", per_arena, true)

	# Deterministic like everything else in the generator.
	var a := _fresh(); a.generate(77, Vector2.ZERO)
	var b := _fresh(); b.generate(77, Vector2.ZERO)
	_check("zones are deterministic", a.zone, b.zone)
	finished["zones_are_placed_in_the_open"] = true

## A 4x4 block of solid cells near the arena centre, plus the world centre of a
## cell just outside it.
##
## Derived from cell coordinates rather than from world literals: the grid's
## origin moved when the corridor margin was added, so any test that assumed
## world 0 sat on a cell boundary silently started testing something else.
func _walled() -> Terrain:
	var t := _fresh()
	var c := t.cell_xy(Vector2.ZERO)
	for y in range(c.y, c.y + 4):
		for x in range(c.x, c.x + 4):
			t.solid[y * t.w + x] = 1
	return t

func _cell_centre(t: Terrain, cx: int, cy: int) -> Vector2:
	return t.origin + Vector2(float(cx) + 0.5, float(cy) + 0.5) * Terrain.CELL

## The open cell immediately left of the wall block, level with its second row.
func _outside(t: Terrain) -> Vector2:
	var c := t.cell_xy(Vector2.ZERO)
	return _cell_centre(t, c.x - 1, c.y + 1)

func sliding_along_walls() -> void:
	var t := _walled()
	var outside := _outside(t)
	var step := Terrain.CELL      # one full cell, so it lands in the wall

	# Straight into the wall: blocked on x, and y was not requested.
	_check("a head-on step is refused", t.slide(outside, Vector2(step, 0)), outside)

	# Diagonal into the wall: x is refused, y is free, so it SLIDES rather than
	# stopping dead. This is the whole point of resolving per axis.
	_check("a diagonal step keeps its free axis",
		t.slide(outside, Vector2(step, step)), outside + Vector2(0, step))

	var open_spot := _cell_centre(t, 4, 4)
	_check("a free step is unchanged",
		t.slide(open_spot, Vector2(10, 10)), open_spot + Vector2(10, 10))

	# The end position is never inside rock, whatever is asked for.
	var bad := 0
	for k in 64:
		var a := TAU * k / 64.0
		if t.is_solid(t.slide(outside, Vector2(cos(a), sin(a)) * 90.0)):
			bad += 1
	_check("no slide ever ends inside a wall", bad, 0)
	finished["sliding_along_walls"] = true

func enemies_avoid_and_never_embed() -> void:
	var t := _walled()
	var outside := _outside(t)

	# Heading straight at the wall from the open side: a force is produced and
	# it does not point further into the rock.
	var f := t.avoid(outside, Vector2(1, 0))
	_check("a force is produced facing a wall", f.length() > 0.0, true)
	_check("and it does not point into the wall", f.x <= 0.0, true)

	_check("open ground produces no force",
		t.avoid(_cell_centre(t, 4, 4), Vector2(1, 0)), Vector2.ZERO)
	_check("a still enemy produces no force",
		t.avoid(outside, Vector2.ZERO), Vector2.ZERO)

	# Avoidance is steering and may be imperfect; rejection is what makes "no
	# enemy is ever inside rock" true regardless.
	var bad := 0
	for k in 64:
		var a := TAU * k / 64.0
		if t.is_solid(t.slide(outside, Vector2(cos(a), sin(a)) * 200.0)):
			bad += 1
	_check("a rejected step never lands in rock", bad, 0)
	finished["enemies_avoid_and_never_embed"] = true

func spawn_points_find_open_ground() -> void:
	var t := _walled()          # rock over a 4x4 block at the arena centre
	var c := t.cell_xy(Vector2.ZERO)
	var deep := _cell_centre(t, c.x + 1, c.y + 1)
	var p := t.nearest_open(deep)
	_check("a point in rock resolves to open ground", t.is_solid(p), false)
	_check("and it does not travel far", p.distance_to(deep) < 300.0, true)

	# A point already open is returned untouched — no needless displacement.
	var open_spot := _cell_centre(t, 4, 4)
	_check("an open point is unchanged", t.nearest_open(open_spot), open_spot)

	# The search is BOUNDED: a fully solid field returns the input rather than
	# looping forever. An unbounded search here is a hang on a dense seed.
	var full := _fresh()
	full.solid.fill(1)
	_check("a sealed field returns the input rather than hanging",
		full.nearest_open(Vector2(10, 10)), Vector2(10, 10))
	finished["spawn_points_find_open_ground"] = true

## The reason the arena is an even number of tiles: the backdrop draws whole
## tiles from each arena's own corner, so an edge that landed part way through
## one would leave a sliver of a different width all along that side.
func the_map_is_laid_out_on_whole_tiles() -> void:
	var bad := 0
	for s in range(24):
		var t := _campaign(s)
		for a in t.arenas:
			for v in [a.position.x - t.origin.x, a.position.y - t.origin.y,
					a.size.x, a.size.y]:
				if not is_equal_approx(fposmod(v, Terrain.TILE), 0.0):
					bad += 1
	_check("every arena edge is a whole number of tiles from the grid origin",
		bad, 0)

	var t2 := _campaign(1)
	_check("and the grid is a whole number of cells",
		is_equal_approx(float(t2.w) * Terrain.CELL, t2.size.x), true)
	_check("in both axes",
		is_equal_approx(float(t2.h) * Terrain.CELL, t2.size.y), true)
	# Cell ranges are exact, so no cell straddles an arena boundary.
	var c := t2.arena_cells(0)
	_check("an arena covers a whole number of cells across",
		float(c.size.x) * Terrain.CELL, SIZE.x)
	_check("and down", float(c.size.y) * Terrain.CELL, SIZE.y)
	finished["the_map_is_laid_out_on_whole_tiles"] = true

## Plotting all three up front is only sound if they cannot land on top of each
## other. The no-reverse rule is what guarantees it for a campaign of three.
func arenas_never_overlap() -> void:
	var bad := 0
	for s in range(200):
		var plan := Terrain.plan(SIZE, 3, s)
		for i in plan.size():
			for j in range(i + 1, plan.size()):
				if (plan[i] as Rect2).intersects(plan[j]):
					bad += 1
	_check("200 layouts, no two arenas overlap", bad, 0)
	_check("and there is one arena per subnet",
		Terrain.plan(SIZE, 3, 0).size(), 3)
	finished["arenas_never_overlap"] = true

## The point of the whole rework: the walkway out of one arena ENDS on the edge
## of the next, and the ground is continuous the whole way.
func corridors_join_one_arena_to_the_next() -> void:
	var off_edge := 0
	var not_flush := 0
	var blocked := 0
	for s in range(40):
		var t := _campaign(s)
		t.generate(s, Vector2.ZERO)
		_check_links(t, s)
		for i in t.gates.size():
			var g: Terrain.Gate = t.gates[i]
			# The gate sits on ITS arena's edge, facing the next one.
			if not t.arenas[i].grow(Terrain.CELL).has_point(g.pos):
				off_edge += 1
			if t.arenas[i].grow(-Terrain.CELL * 2.0).has_point(g.pos):
				off_edge += 1
			# The far end lands exactly on the next arena's edge — not near it,
			# and not short of it, which is what a teleport looks like.
			if not t.arenas[i + 1].grow(0.5).has_point(g.end):
				not_flush += 1
			if t.arenas[i + 1].grow(-0.5).has_point(g.end):
				not_flush += 1
			# Open ground from the mouth to the far end, on the SAME grid.
			for k in 41:
				var p: Vector2 = g.pos.lerp(g.end, float(k) / 40.0)
				if t.solid[t.cell_index(p)] != 0:
					blocked += 1
	_check("every gate sits on its own arena's edge", off_edge, 0)
	_check("and its corridor ends flush with the next arena", not_flush, 0)
	_check("with open ground the whole way", blocked, 0)
	finished["corridors_join_one_arena_to_the_next"] = true

## The corridor points AT the next arena, along one axis, with the two arenas a
## corridor's length apart.
func _check_links(t: Terrain, s: int) -> void:
	for i in t.gates.size():
		var g: Terrain.Gate = t.gates[i]
		var d: Vector2 = t.arenas[i + 1].get_center() - t.arenas[i].get_center()
		if g.dir.dot(d) <= 0.0 or absf(g.dir.x * g.dir.y) > 0.0:
			checks += 1
			failures += 1
			print("  FAIL  seed %d gate %d faces %s, next arena is %s away"
				% [s, i, g.dir, d])

## A shut gate has to bar its corridor and NOTHING else. The half-plane it used
## to be tested as barred everything outward of the gate plane — which, now that
## the next arena is out there, was an invisible wall across its floor.
func a_shut_gate_bars_only_its_corridor() -> void:
	var t := _campaign(2)
	t.generate(2, Vector2.ZERO)
	var g: Terrain.Gate = t.gates[0]
	_check("a fresh gate is closed", g.open, false)
	_check("a closed gate bars its mouth", t.is_solid(g.pos), true)
	_check("and the corridor beyond it",
		t.is_solid(g.pos + g.dir * Terrain.CORRIDOR_LENGTH * 0.5), true)
	_check("but not the arena on the far side",
		t.is_solid(g.end + g.dir * 400.0), false)
	_check("nor the arena it leaves",
		t.is_solid(g.pos - g.dir * 400.0), false)

	t.open_gate()
	_check("opening it clears the mouth", t.is_solid(g.pos), false)
	_check("and the corridor",
		t.is_solid(g.pos + g.dir * Terrain.CORRIDOR_LENGTH * 0.5), false)

	# Walking in advances `current` and shuts the way back, so the collapsing
	# ground behind is not somewhere you can stroll back into.
	t.enter_next()
	_check("entering moves the current arena on", t.current, 1)
	_check("and shuts the gate behind", g.open, false)
	_check("which bars the corridor again",
		t.is_solid(g.pos + g.dir * Terrain.CORRIDOR_LENGTH * 0.5), true)
	_check("the arena just entered is still open", t.is_solid(g.end
		+ g.dir * 400.0), false)
	_check("and its own gate is the current one", t.gate(), t.gates[1])

	t.enter_next()
	_check("the last arena has no gate", t.has_gate(), false)
	_check("and asking for one gives nothing", t.gate(), null)
	finished["a_shut_gate_bars_only_its_corridor"] = true
