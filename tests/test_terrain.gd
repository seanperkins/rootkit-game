extends SceneTree

## The terrain layer: cell lookup, generation, connectivity, zones.

var failures := 0

const ORIGIN := Vector2(-1600, -1000)
const SIZE := Vector2(3200, 2000)

func _initialize() -> void:
	print("ROOTKIT — terrain\n")
	cell_lookup()
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
