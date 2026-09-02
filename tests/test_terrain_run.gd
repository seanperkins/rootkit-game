extends SceneTree

## Terrain as the RUN sees it: projectiles stopping on walls, zones applying to
## the player and the swarm, and a subnet advance producing a fresh arena.

var failures := 0
var finished := {}

const CASES := ["projectiles_die_on_walls", "hazard_zones_hurt", "slow_zones_slow", "advancing_moves_the_player_on_not_the_ground",
	"corruption_zones_have_a_flip_budget"]

func _initialize() -> void:
	print("ROOTKIT — terrain in the run\n")
	await projectiles_die_on_walls()
	await hazard_zones_hurt()
	await slow_zones_slow()
	await advancing_moves_the_player_on_not_the_ground()
	await corruption_zones_have_a_flip_budget()
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
	# Start from a KNOWN-EMPTY field. This case is about a projectile meeting a
	# wall, not about what the generator happened to roll — leaving the random
	# arena in place meant the control shot could fly into real terrain, which
	# is a test failure that says nothing about the code under test.
	t.solid.fill(0)
	# A wall directly right of the origin, two cells wide.
	var wc := t.cell_xy(Vector2(200, 0))
	for y in range(wc.y - 1, wc.y + 2):
		for x in range(wc.x, wc.x + 2):
			t.solid[y * t.w + x] = 1

	var wall_x: float = t.origin.x + float(wc.x) * Terrain.CELL
	var i: int = r.projectiles.spawn(Vector2(wall_x - 190.0, 0), Vector2(600, 0),
		1.0, 4.0, 0)
	r._proj_dist_left[i] = 2000.0
	_check("the projectile starts alive", r.projectiles.state[i], Population.ALIVE)
	for k in 20:
		r._step2_integrate(1.0 / 60.0)
	_check("it is dead once it reaches the wall",
		r.projectiles.state[i], Population.DEAD)

	var j: int = r.projectiles.spawn(Vector2(wall_x - 190.0, -600), Vector2(600, 0),
		1.0, 4.0, 0)
	r._proj_dist_left[j] = 2000.0
	for k in 20:
		r._step2_integrate(1.0 / 60.0)
	_check("one in the open is untouched", r.projectiles.state[j], Population.ALIVE)
	r.free()
	finished["projectiles_die_on_walls"] = true

func hazard_zones_hurt() -> void:
	var r := await _fresh_run()
	_paint(r.terrain, r.player_pos[r.local_slot], Terrain.Kind.HAZARD)
	var before: float = r.player_health[r.local_slot]
	for k in 60:
		r._step2b_zones(1.0 / 60.0)
	var lost: float = before - r.player_health[r.local_slot]
	# Bounded, not exact: the hazard goes through _mitigated, so armour and
	# defence from the player sheet reduce it by an amount the shop can change.
	_check("standing in a hazard costs integrity", lost > 0.0, true)
	_check("and never more than its rated output",
		lost <= Terrain.HAZARD_DPS + 0.01, true)

	var mid: float = r.player_health[r.local_slot]
	r.player_pos[r.local_slot] = Vector2(1200, 800)
	for k in 60:
		r._step2b_zones(1.0 / 60.0)
	_check("leaving the hazard stops the damage", r.player_health[r.local_slot], mid)
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

## The whole campaign is plotted before the first frame, so the advance moves
## which arena is CURRENT and nothing else. This case used to assert the
## opposite — that the arena was rebuilt — which is exactly the teleport the
## corridor replaced.
func advancing_moves_the_player_on_not_the_ground() -> void:
	var r := await _fresh_run()
	var before: PackedByteArray = r.terrain.solid.duplicate()
	var arena_before: Rect2 = r.terrain.arena()
	var was: Vector2 = r.player_pos[r.local_slot]
	r._advance_subnet()
	_check("the ground is untouched", r.terrain.solid, before)
	_check("the player is not moved", r.player_pos[r.local_slot], was)
	_check("but the current arena is the next one", r.terrain.arena() == arena_before, false)
	_check("and it is where the corridor pointed",
		r.terrain.arena(), r.terrain.arenas[1])

	# Every arena is generated, not just the one being fought in.
	var walls := PackedInt32Array()
	walls.resize(r.terrain.arenas.size())
	for k in r.terrain.arenas.size():
		var c: Rect2i = r.terrain.arena_cells(k)
		var n := 0
		for y in range(c.position.y, c.end.y):
			for x in range(c.position.x, c.end.x):
				if r.terrain.solid[y * r.terrain.w + x] != 0:
					n += 1
		walls[k] = n
	var all_built := true
	for n in walls:
		if n == 0:
			all_built = false
	_check("all three arenas have terrain in them", all_built, true)
	_check("and they are not the same arena three times",
		walls[0] == walls[1] and walls[1] == walls[2], false)
	r.free()
	finished["advancing_moves_the_player_on_not_the_ground"] = true

## A corruption zone converts ZONE_FLIP_BUDGET enemies, then lies dormant
## until ZONE_RECHARGE has passed; a swarm led across it all match is not a
## build.
func corruption_zones_have_a_flip_budget() -> void:
	var r := await _fresh_run()
	r.input_override = Vector2.ZERO
	var t: Terrain = r.terrain
	t.solid.fill(0)
	var at: Vector2 = r.player_pos[r.local_slot] + Vector2(600.0, 0.0)
	var zi: int = t.paint_zone(Rect2(at - Vector2(112.0, 112.0), Vector2(224.0, 224.0)), Terrain.Kind.CORRUPTION)
	_check("painting a zone registers a rect", zi >= 0, true)
	r._allocate_zone_state()          # a painted rect is a new rect
	_check("the run tracks one budget per rect", r._zone_flips.size(), t.rects.size())
	# Staggered starting corruption so they cross the threshold on different
	# ticks: the budget gates the zone's corruption, not an adjudication already
	# made, so a group crossing on the same tick would all flip together.
	for k in Terrain.ZONE_FLIP_BUDGET + 1:
		var e: int = r.enemies.spawn(at + Vector2(float(k) * 14.0 - 42.0, 0.0), Vector2.ZERO, 10.0, r.ENEMY_RADIUS, 0)
		r.enemies.corruption[e] = float(Terrain.ZONE_FLIP_BUDGET - k)
	# The zone step, the drain and the recycle: a FLIPPED enemy left in the
	# pool would be re-adjudicated every tick, which step 9 prevents in the
	# real tick by moving it into the botnet.
	var dt := 1.0 / 60.0
	for tick in 240:
		r.queue.begin_tick()
		r._step2b_zones(dt)
		r._steps78_drain()
		r._step9_recycle()
	_check("a zone flips its budget and no more", r.botnet.count, Terrain.ZONE_FLIP_BUDGET)
	_check("the tally says so", r._zone_flips[zi], Terrain.ZONE_FLIP_BUDGET)
	_check("and then goes dormant", r._zone_recharge[zi] > 0.0, true)
	_check("the last enemy is still an enemy", r.enemies.count, 1)
	r._zone_recharge[zi] = 0.001
	r._step2_integrate(dt)
	_check("the recharge clears the tally", r._zone_flips[zi], 0)
	for tick in 240:
		r.queue.begin_tick()
		r._step2b_zones(dt)
		r._steps78_drain()
		r._step9_recycle()
	_check("a recharged zone flips again", r.botnet.count, Terrain.ZONE_FLIP_BUDGET + 1)
	r.free()
	finished["corruption_zones_have_a_flip_budget"] = true
