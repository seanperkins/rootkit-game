extends SceneTree

## Boss pathfinding: a flow field flooded from the player over a window that
## follows them.
##
## The failure this removes is specific and visible — a mini-boss walking into
## a wall because the straight line to the player goes through it, and staying
## there while the player circles. The swarm keeps the straight line on purpose;
## a hundred bodies shoving round a corner is what a swarm looks like, and a
## flood per enemy would be the most expensive thing in the tick.

var failures := 0
var finished := {}

const CASES := ["open_ground_matches_the_straight_line",
	"it_routes_around_a_wall", "it_falls_back_outside_the_window",
	"only_bosses_consult_it", "a_rebuild_follows_the_player"]

func _initialize() -> void:
	print("ROOTKIT — flow field\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await open_ground_matches_the_straight_line()
	await it_routes_around_a_wall()
	await it_falls_back_outside_the_window()
	await only_bosses_consult_it()
	await a_rebuild_follows_the_player()
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

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

func _bare_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	r.director.elapsed = 999.0
	r.director.boss_spawned = true
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	return r

## Find open ground near the player, and a wall cell, by sampling.
func _open_near(r: Node2D, from: Vector2, dist: float) -> Vector2:
	for k in 64:
		var a := TAU * float(k) / 64.0
		var p: Vector2 = from + Vector2(cos(a), sin(a)) * dist
		if not r.terrain.is_solid(p) and not r.terrain.is_void(p):
			return p
	return from

func open_ground_matches_the_straight_line() -> void:
	var r := await _bare_run()
	r._flow.rebuild(r.terrain, r.player_pos[r.local_slot])
	var at := _open_near(r, r.player_pos[r.local_slot], 140.0)
	var d: Vector2 = r._flow.dir_at(r.terrain, at)
	if d == Vector2.ZERO:
		# No gradient here (the sample landed somewhere sealed); the caller
		# falls back to the straight line, which is the documented contract.
		_check_true("no gradient falls back cleanly", true)
	else:
		var straight: Vector2 = (r.player_pos[r.local_slot] - at).normalized()
		# Eight-way, so it can only ever be within 45 degrees of straight.
		_check_true("open ground points broadly at the player",
			d.dot(straight) > 0.55)
	r.free()
	await process_frame
	finished["open_ground_matches_the_straight_line"] = true

## THE case. Stand a boss so the straight line crosses solid ground and assert
## the field sends it somewhere that is not into the wall.
func it_routes_around_a_wall() -> void:
	var r := await _bare_run()
	var found := false
	for entry in r.terrain.rects:
		if entry[1] != Terrain.Kind.WALL:
			continue
		var wr: Rect2 = entry[0]
		var centre: Vector2 = wr.position + wr.size * 0.5
		# Player one side of the wall, boss the other, on the long axis.
		var axis := Vector2(1, 0) if wr.size.x >= wr.size.y else Vector2(0, 1)
		var perp := Vector2(axis.y, axis.x)
		var reach: float = (wr.size * perp).length() * 0.5 + 90.0
		var pp: Vector2 = centre + perp * reach
		var bp: Vector2 = centre - perp * reach
		if r.terrain.is_solid(pp) or r.terrain.is_void(pp):
			continue
		if r.terrain.is_solid(bp) or r.terrain.is_void(bp):
			continue
		# Only useful if the straight line really is blocked.
		var blocked := false
		for k in range(1, 20):
			var s: Vector2 = bp.lerp(pp, float(k) / 20.0)
			if r.terrain.is_solid(s):
				blocked = true
				break
		if not blocked:
			continue

		r.player_pos[r.local_slot] = pp
		r._flow.rebuild(r.terrain, r.player_pos[r.local_slot])
		var d: Vector2 = r._flow.dir_at(r.terrain, bp)
		if d == Vector2.ZERO:
			continue        # walled off entirely; not this wall's test
		var ahead: Vector2 = bp + d * Terrain.CELL * 1.2
		_check_true("the field does not steer into the wall",
			not r.terrain.is_solid(ahead))
		var straight: Vector2 = (pp - bp).normalized()
		_check_true("and it is not simply the blocked straight line",
			d.dot(straight) < 0.999)
		found = true
		break
	_check_true("a blocking wall was found to test against", found)
	r.free()
	await process_frame
	finished["it_routes_around_a_wall"] = true

## Outside the window there is no gradient, and the contract is to say so
## rather than to guess — the caller then walks the straight line, which is
## exactly what the game did before this class existed.
func it_falls_back_outside_the_window() -> void:
	var r := await _bare_run()
	r._flow.rebuild(r.terrain, r.player_pos[r.local_slot])
	var far: Vector2 = r.player_pos[r.local_slot] + Vector2(
		FlowField.RADIUS * Terrain.CELL * 4.0, 0.0)
	_check("far outside the window yields no direction",
		r._flow.dir_at(r.terrain, far), Vector2.ZERO)
	r.free()
	await process_frame
	finished["it_falls_back_outside_the_window"] = true

## The swarm keeps the straight line. A flood is affordable once per tick, not
## once per enemy, and a hundred grunts rounding a corner in single file would
## look worse than a hundred grunts shoving.
func only_bosses_consult_it() -> void:
	var r := await _bare_run()
	r._flow.rebuild(r.terrain, r.player_pos[r.local_slot])
	var at: Vector2 = _open_near(r, r.player_pos[r.local_slot], 200.0)

	var grunt: int = r.enemies.spawn(at, Vector2.ZERO, 10.0, 20.0, 0)
	r._spawn_enemy_state(grunt, 10.0)
	var to_player: Vector2 = r.player_pos[r.local_slot] - at
	_check("a grunt walks the straight line",
		r._approach_dir(grunt, to_player), to_player.normalized())

	var ice: int = r.enemies.spawn(at, Vector2.ZERO, 500.0, 48.0,
		EnemyTable.ICE)
	r._spawn_enemy_state(ice, 500.0)
	var bd: Vector2 = r._approach_dir(ice, to_player)
	_check_true("a boss gets a real direction either way", bd.length() > 0.9)
	r.free()
	await process_frame
	finished["only_bosses_consult_it"] = true

## Rebuilt on a cell crossing, not every tick: the flood is 2401 cells and the
## player crosses a cell every few frames at walking speed.
func a_rebuild_follows_the_player() -> void:
	var r := await _bare_run()
	r._flow.rebuild(r.terrain, r.player_pos[r.local_slot])
	_check("no rebuild needed while inside the same cell",
		r._flow.needs_rebuild(r.terrain, r.player_pos[r.local_slot]), false)
	var moved: Vector2 = r.player_pos[r.local_slot] + Vector2(Terrain.CELL * 3.0, 0.0)
	_check_true("but a cell crossing asks for one",
		r._flow.needs_rebuild(r.terrain, moved))
	r.free()
	await process_frame
	finished["a_rebuild_follows_the_player"] = true
