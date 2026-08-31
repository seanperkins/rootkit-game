extends SceneTree

## The terrain layer: cell lookup, generation, connectivity, zones.

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
	"the_start_is_clear", "zones_are_placed_in_the_open", "sliding_along_walls", "enemies_avoid_and_never_embed", "spawn_points_find_open_ground", "the_gate_is_always_reachable",
]

const ORIGIN := Vector2(-1600, -1000)
const SIZE := Vector2(3200, 2000)

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
	the_gate_is_always_reachable()
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

func _fresh() -> Terrain:
	return Terrain.new(ORIGIN, SIZE)

func cell_lookup() -> void:
	var t := _fresh()
	# The grid is deliberately LARGER than the arena: the corridor beyond a gate
	# is ordinary ground on this same grid, which is what makes walking out
	# continuous rather than a teleport.
	_check("the grid covers the arena plus a margin either side", t.w,
		int(ceil((SIZE.x + Terrain.MARGIN * 2.0) / Terrain.CELL)))
	_check("in both axes", t.h,
		int(ceil((SIZE.y + Terrain.MARGIN * 2.0) / Terrain.CELL)))
	_check("and the arena rect is remembered", t.arena_rect, Rect2(ORIGIN, SIZE))
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

	# Generation walls off everything outside the arena, so the world is bounded.
	var g := _fresh()
	g.generate(1, 1, Vector2.ZERO, false)
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
	var a := _fresh(); a.generate(4242, 2, Vector2.ZERO)
	var b := _fresh(); b.generate(4242, 2, Vector2.ZERO)
	var c := _fresh(); c.generate(4242, 3, Vector2.ZERO)
	_check("same seed and subnet give the same walls", a.solid, b.solid)
	_check("same seed and subnet give the same rects", a.rects.size(), b.rects.size())
	_check("a different subnet gives a different arena", a.solid == c.solid, false)
	# No "denser later" assertion any more: density is flat by design.

## The invariant the whole generator exists to protect. A sealed pocket is an
## unwinnable run: ICE, or the player, spawned inside one can never be reached.
	finished["generation_is_deterministic"] = true
func every_open_cell_is_reachable() -> void:
	var bad := 0
	for s in range(200):
		var t := _fresh()
		t.generate(s, 3, Vector2.ZERO)          # densest subnet, hardest case
		if not _fully_connected(t, Vector2.ZERO):
			bad += 1
	_check("200 seeds, no unreachable open cell", bad, 0)

	finished["every_open_cell_is_reachable"] = true
func the_playfield_never_collapses() -> void:
	var worst := 1.0
	for s in range(200):
		var t := _fresh()
		t.generate(s, 3, Vector2.ZERO)
		worst = minf(worst, t.reachable_fraction(Vector2.ZERO))
	print("    worst reachable fraction over 200 seeds: %.3f" % worst)
	_check("the arena never shrinks to a closet",
		worst >= Terrain.REACHABLE_FLOOR, true)

	finished["the_playfield_never_collapses"] = true
func the_start_is_clear() -> void:
	var bad := 0
	for s in range(100):
		var t := _fresh()
		t.generate(s, 3, Vector2.ZERO)
		if t.is_solid(Vector2.ZERO):
			bad += 1
		# The whole spawn-safe disc, not just its centre.
		for k in 16:
			var a := TAU * k / 16.0
			if t.is_solid(Vector2(cos(a), sin(a)) * (Terrain.WALL_MARGIN - 40.0)):
				bad += 1
	_check("the player never starts in or beside rock", bad, 0)

	finished["the_start_is_clear"] = true
func _solid_count(t: Terrain) -> int:
	var n := 0
	for i in t.solid.size():
		if t.solid[i] != 0:
			n += 1
	return n

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
		t.generate(s, 2, Vector2.ZERO)
		for i in t.zone.size():
			# A zone cell may never also be a wall cell: a hazard you cannot
			# walk into is not a hazard.
			if t.zone[i] != 0 and t.solid[i] != 0:
				overlapping += 1
	_check("no zone cell is also a wall", overlapping, 0)

	var t2 := _fresh()
	t2.generate(11, 2, Vector2.ZERO)
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

	# Deterministic like everything else in the generator.
	var a := _fresh(); a.generate(77, 2, Vector2.ZERO)
	var b := _fresh(); b.generate(77, 2, Vector2.ZERO)
	_check("zones are deterministic", a.zone, b.zone)
	finished["zones_are_placed_in_the_open"] = true

## A 4x4 block of solid cells near the arena centre, plus the world centre of a
## cell just outside it.
##
## Derived from cell coordinates rather than from world literals: the grid's
## origin moved when the corridor margin was added, so any test that assumed
## world 0 sat on a cell boundary silently started testing something else.
const WALL_C := 8      # cells a side is 4, anchored this far from centre

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
	var t := _walled()          # rock over world x,y in [0,128)
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

func the_gate_is_always_reachable() -> void:
	var unreachable := 0
	var off_edge := 0
	for s in range(150):
		for sn in [1, 2, 3]:
			var t := _fresh()
			t.generate(s, sn, Vector2.ZERO)
			if not t.has_gate:
				continue
			# solid[] not is_solid(): the mouth's CELL is open from generation,
			# while is_solid additionally reports the shut gate barring it.
			if t.solid[t.cell_index(t.gate_pos)] != 0 \
					or not _reaches(t, Vector2.ZERO, t.gate_pos):
				unreachable += 1
				continue
			# On the ARENA's edge — not the grid's, which is a margin away, and
			# not floating in the middle of the field.
			if t.arena_rect.grow(-Terrain.CELL * 3.0).has_point(t.gate_pos):
				off_edge += 1
			if not t.arena_rect.grow(Terrain.CELL).has_point(t.gate_pos):
				off_edge += 1
	_check("the gate is reachable on every seed and subnet", unreachable, 0)
	_check("and it always sits on an arena edge", off_edge, 0)

	# Generation can be asked for no gate at all — the last subnet has none.
	var g := _fresh()
	g.generate(5, 1, Vector2.ZERO, false)
	_check("a gateless arena reports no gate", g.has_gate, false)

	var h := _fresh()
	h.generate(5, 1, Vector2.ZERO)
	_check("a fresh gate is closed", h.gate_open, false)
	# And a closed gate is a wall: the corridor exists from the first second,
	# so without this the whole subnet could be skipped by walking out.
	_check("a closed gate bars the way", h.is_solid(h.gate_pos), true)
	_check("and bars the corridor beyond it",
		h.is_solid(h.gate_pos + h.gate_dir * 300.0), true)
	h.gate_open = true
	_check("an open one does not", h.is_solid(h.gate_pos), false)
	_check("nor beyond it", h.is_solid(h.gate_pos + h.gate_dir * 300.0), false)
	finished["the_gate_is_always_reachable"] = true

## Reuses the test's own flood fill rather than the generator's.
func _reaches(t: Terrain, from: Vector2, to: Vector2) -> bool:
	var goal := t.cell_index(to)
	var seen := {}
	var stack := [t.cell_index(from)]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if i < 0 or seen.has(i) or t.solid[i] != 0:
			continue
		seen[i] = true
		if i == goal:
			return true
		var x := i % t.w
		var y := i / t.w
		if x > 0: stack.append(i - 1)
		if x < t.w - 1: stack.append(i + 1)
		if y > 0: stack.append(i - t.w)
		if y < t.h - 1: stack.append(i + t.w)
	return false
