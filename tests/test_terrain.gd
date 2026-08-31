extends SceneTree

## The terrain layer: cell lookup, generation, connectivity, zones.

var failures := 0

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
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
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

func density_scales_with_subnet() -> void:
	_check("subnet 1 is the base density", Terrain.density_for(1), Terrain.DENSITY_BASE)
	_check("subnet 3 is two steps up", Terrain.density_for(3),
		Terrain.DENSITY_BASE + 2.0 * Terrain.DENSITY_PER_SUBNET)
	# Subnet 0 must not underflow into a negative density.
	_check("subnet 0 clamps to the base", Terrain.density_for(0), Terrain.DENSITY_BASE)

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
func every_open_cell_is_reachable() -> void:
	var bad := 0
	for s in range(200):
		var t := _fresh()
		t.generate(s, 3, Vector2.ZERO)          # densest subnet, hardest case
		if not _fully_connected(t, Vector2.ZERO):
			bad += 1
	_check("200 seeds, no unreachable open cell", bad, 0)

func the_playfield_never_collapses() -> void:
	var worst := 1.0
	for s in range(200):
		var t := _fresh()
		t.generate(s, 3, Vector2.ZERO)
		worst = minf(worst, t.reachable_fraction(Vector2.ZERO))
	print("    worst reachable fraction over 200 seeds: %.3f" % worst)
	_check("the arena never shrinks to a closet",
		worst >= Terrain.REACHABLE_FLOOR, true)

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
	for k in kinds:
		_check("zone kind %d is a real effect kind" % k,
			k in [Terrain.Kind.HAZARD, Terrain.Kind.SLOW, Terrain.Kind.CORRUPTION], true)
	_check("WALL is never written into the zone layer",
		kinds.has(Terrain.Kind.WALL), false)

	# Deterministic like everything else in the generator.
	var a := _fresh(); a.generate(77, 2, Vector2.ZERO)
	var b := _fresh(); b.generate(77, 2, Vector2.ZERO)
	_check("zones are deterministic", a.zone, b.zone)
