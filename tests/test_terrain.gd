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
	"the_start_is_clear", "zones_are_placed_in_the_open", "sliding_along_walls", "enemies_avoid_and_never_embed", "spawn_points_find_open_ground",
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
	_check("grid width covers the arena", t.w, 100)
	_check("grid height covers the arena", t.h, 63)
	_check("a fresh field is entirely open", t.is_solid(Vector2.ZERO), false)
	_check("a fresh field has no zones", t.zone_at(Vector2.ZERO), -1)

	# Outside the arena is OPEN. Enemies spawn on a ring around the player that
	# can fall outside the bounds; solid-outside would reject all of those.
	_check("far outside the arena is open", t.is_solid(Vector2(-9000, -9000)), false)
	_check("outside the arena has no zone", t.zone_at(Vector2(-9000, -9000)), -1)

	# Writing a cell directly is how later tasks bake; prove the mapping first.
	t.solid[t.cell_index(Vector2(0, 0))] = 1
	_check("a written cell reads back solid", t.is_solid(Vector2(0, 0)), true)
	_check("its neighbour is untouched", t.is_solid(Vector2(64, 0)), false)
	_check("the arena origin maps to cell 0", t.cell_index(ORIGIN), 0)
	_check("the last cell is in range",
		t.cell_index(ORIGIN + SIZE - Vector2(1, 1)), t.w * t.h - 1)

	finished["cell_lookup"] = true
func density_scales_with_subnet() -> void:
	_check("subnet 1 is the base density", Terrain.density_for(1), Terrain.DENSITY_BASE)
	_check("subnet 3 is two steps up", Terrain.density_for(3),
		Terrain.DENSITY_BASE + 2.0 * Terrain.DENSITY_PER_SUBNET)
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
	_check("a later subnet is denser", _solid_count(c) > _solid_count(a), true)

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

## A wall over world x,y in [0,128), so its open side is negative on both axes.
	finished["zones_are_placed_in_the_open"] = true
func _walled() -> Terrain:
	var t := _fresh()
	for y in range(4):
		for x in range(4):
			var c := t.cell_xy(Vector2(x * Terrain.CELL, y * Terrain.CELL))
			t.solid[c.y * t.w + c.x] = 1
	return t

func sliding_along_walls() -> void:
	var t := _walled()
	var outside := Vector2(-20, 40)          # left of the wall, level with it

	# Straight into the wall: blocked on x, and y was not requested, so nothing.
	_check("a head-on step is refused", t.slide(outside, Vector2(30, 0)), outside)

	# Diagonal into the wall: x is refused, y is free, so it SLIDES rather than
	# stopping dead. This is the whole point of resolving per axis.
	_check("a diagonal step keeps its free axis",
		t.slide(outside, Vector2(30, 30)), outside + Vector2(0, 30))

	_check("a free step is unchanged",
		t.slide(Vector2(-400, -400), Vector2(10, 10)), Vector2(-390, -390))

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

	# Heading straight at the wall from the open side: the avoidance force must
	# push AWAY from it, i.e. have a negative x component.
	var f := t.avoid(Vector2(-20, 40), Vector2(1, 0))
	_check("a force is produced facing a wall", f.length() > 0.0, true)
	_check("and it does not point into the wall", f.x <= 0.0, true)

	# Nothing ahead, no force. An avoidance force in open ground would bend
	# every enemy's path for no reason.
	_check("open ground produces no force",
		t.avoid(Vector2(-800, -800), Vector2(1, 0)), Vector2.ZERO)
	_check("a still enemy produces no force",
		t.avoid(Vector2(-20, 40), Vector2.ZERO), Vector2.ZERO)

	# The guarantee that matters. Avoidance is steering and may be imperfect;
	# rejection is what makes "no enemy is ever inside rock" true regardless.
	var bad := 0
	for k in 64:
		var a := TAU * k / 64.0
		if t.is_solid(t.slide(Vector2(-20, 40), Vector2(cos(a), sin(a)) * 200.0)):
			bad += 1
	_check("a rejected step never lands in rock", bad, 0)
	finished["enemies_avoid_and_never_embed"] = true

func spawn_points_find_open_ground() -> void:
	var t := _walled()          # rock over world x,y in [0,128)
	var p := t.nearest_open(Vector2(64, 64))
	_check("a point in rock resolves to open ground", t.is_solid(p), false)
	_check("and it does not travel far",
		p.distance_to(Vector2(64, 64)) < 300.0, true)

	# A point already open is returned untouched — no needless displacement.
	_check("an open point is unchanged",
		t.nearest_open(Vector2(-500, -500)), Vector2(-500, -500))

	# The search is BOUNDED: a fully solid field returns the input rather than
	# looping forever. An unbounded search here is a hang on a dense seed.
	var full := _fresh()
	full.solid.fill(1)
	_check("a sealed field returns the input rather than hanging",
		full.nearest_open(Vector2(10, 10)), Vector2(10, 10))
	finished["spawn_points_find_open_ground"] = true
