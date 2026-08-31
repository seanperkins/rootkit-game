extends SceneTree

## Terrain as the RUN sees it: projectiles stopping on walls, zones applying to
## the player and the swarm, and a subnet advance producing a fresh arena.

var failures := 0
var finished := {}

const CASES := ["projectiles_die_on_walls", "hazard_zones_hurt", "slow_zones_slow", "advancing_regenerates_the_arena"]

func _initialize() -> void:
	print("ROOTKIT — terrain in the run\n")
	await projectiles_die_on_walls()
	await hazard_zones_hurt()
	await slow_zones_slow()
	await advancing_regenerates_the_arena()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

## Paint a zone over a block of cells around a point.
func _paint(t: Terrain, at: Vector2, kind: int) -> void:
	for y in range(-3, 4):
		for x in range(-3, 4):
			var c := t.cell_xy(at + Vector2(x, y) * Terrain.CELL)
			if t.in_bounds(c):
				t.zone[c.y * t.w + c.x] = kind + 1

func projectiles_die_on_walls() -> void:
	var r := await _fresh_run()
	var t: Terrain = r.terrain
	# A wall directly right of the origin, at world x in [192, 256).
	for y in range(-1, 2):
		for x in range(0, 2):
			var c := t.cell_xy(Vector2(200 + x * Terrain.CELL, y * Terrain.CELL))
			t.solid[c.y * t.w + c.x] = 1

	var i: int = r.projectiles.spawn(Vector2(0, 0), Vector2(600, 0), 1.0, 4.0, 0)
	r._proj_dist_left[i] = 2000.0
	_check("the projectile starts alive", r.projectiles.state[i], Population.ALIVE)
	for k in 20:
		r._step2_integrate(1.0 / 60.0)
	_check("it is dead once it reaches the wall",
		r.projectiles.state[i], Population.DEAD)

	var j: int = r.projectiles.spawn(Vector2(0, -600), Vector2(600, 0), 1.0, 4.0, 0)
	r._proj_dist_left[j] = 2000.0
	for k in 20:
		r._step2_integrate(1.0 / 60.0)
	_check("one in the open is untouched", r.projectiles.state[j], Population.ALIVE)
	r.free()
	finished["projectiles_die_on_walls"] = true

func hazard_zones_hurt() -> void:
	var r := await _fresh_run()
	_paint(r.terrain, r.player_pos, Terrain.Kind.HAZARD)
	var before: float = r.player_health
	for k in 60:
		r._step2b_zones(1.0 / 60.0)
	var lost: float = before - r.player_health
	# Bounded, not exact: the hazard goes through _mitigated, so armour and
	# defence from the player sheet reduce it by an amount the shop can change.
	_check("standing in a hazard costs integrity", lost > 0.0, true)
	_check("and never more than its rated output",
		lost <= Terrain.HAZARD_DPS + 0.01, true)

	var mid: float = r.player_health
	r.player_pos = Vector2(1200, 800)
	for k in 60:
		r._step2b_zones(1.0 / 60.0)
	_check("leaving the hazard stops the damage", r.player_health, mid)
	r.free()
	finished["hazard_zones_hurt"] = true

func slow_zones_slow() -> void:
	var r := await _fresh_run()
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 12.0, 0)
	_paint(r.terrain, Vector2(300, 0), Terrain.Kind.SLOW)
	r._step2b_zones(1.0 / 60.0)
	_check("an enemy in a slow zone is slowed", r._slow_left[i] > 0.0, true)
	# _slow_factor is a PackedFloat32Array, so 0.6 comes back as 0.60000002.
	_check("and by the zone's factor",
		is_equal_approx(r._slow_factor[i], Terrain.SLOW_FACTOR), true)

	r.enemies.pos[i] = Vector2(-1200, -800)
	for k in 120:
		r._step2b_zones(1.0 / 60.0)
	_check("the slow expires outside the zone", r._slow_left[i] <= 0.0, true)

	# Refreshing takes the STRONGER slow, never the most recent — the same rule
	# ward magnitudes fold by, and for the same reason.
	r.apply_slow(i, 0.5, 1.0)
	r.apply_slow(i, 0.9, 1.0)
	_check("a weaker slow does not overwrite a stronger one", r._slow_factor[i], 0.5)
	r.free()
	finished["slow_zones_slow"] = true

func advancing_regenerates_the_arena() -> void:
	var r := await _fresh_run()
	var before: PackedByteArray = r.terrain.solid.duplicate()
	r._advance_subnet()
	_check("the arena is rebuilt for the new subnet", r.terrain.solid == before, false)
	_check("and the player is not left standing in rock",
		r.terrain.is_solid(r.player_pos), false)

	var n_before := 0
	for i in before.size():
		if before[i] != 0: n_before += 1
	var n_after := 0
	for i in r.terrain.solid.size():
		if r.terrain.solid[i] != 0: n_after += 1
	_check("subnet 02 is denser than subnet 01", n_after > n_before, true)
	r.free()
	finished["advancing_regenerates_the_arena"] = true
