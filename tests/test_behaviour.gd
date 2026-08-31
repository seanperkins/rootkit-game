extends SceneTree

## Per-type enemy behaviour, driven directly rather than through a played run.

var failures := 0
var finished := {}

const CASES := ["chase_is_unchanged_and_state_resets", "spawning_clears_ai_state",
	"charger_commits_to_its_dash", "flanker_leads_the_player",
	"player_velocity_is_tracked", "support_heals_but_never_past_spawn",
	"ambusher_is_untouchable_while_under", "ranged_shoots_and_its_shots_bite", "the_new_enemies_are_wired"]

func _initialize() -> void:
	print("ROOTKIT — enemy behaviour\n")
	await chase_is_unchanged_and_state_resets()
	await spawning_clears_ai_state()
	await charger_commits_to_its_dash()
	await flanker_leads_the_player()
	await player_velocity_is_tracked()
	await support_heals_but_never_past_spawn()
	await ambusher_is_untouchable_while_under()
	await ranged_shoots_and_its_shots_bite()
	await the_new_enemies_are_wired()
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

func chase_is_unchanged_and_state_resets() -> void:
	var r := await _fresh_run()
	# A plain daemon still walks straight at the player.
	var i: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._clear_ai(i)
	var v: Vector2 = r._behave(i, r.enemy_types[0], 1.0 / 60.0)
	_check("chase heads at the player", v.normalized().is_equal_approx(
		(r.player_pos - r.enemies.pos[i]).normalized()), true)
	_check("at the type's speed",
		is_equal_approx(v.length(), r.enemy_types[0].speed), true)

	# A recycled slot must not inherit the previous occupant's AI state. This is
	# the bug class the worm arrays already had to be defended against.
	r._ai_phase[i] = 3
	r._ai_timer[i] = 9.9
	r._ai_aim[i] = Vector2(1, 1)
	r._submerged[i] = 1
	r._clear_ai(i)
	_check("phase resets", r._ai_phase[i], 0)
	_check("timer resets", r._ai_timer[i], 0.0)
	_check("aim resets", r._ai_aim[i], Vector2.ZERO)
	_check("submersion resets", r._submerged[i], 0)
	r.free()
	finished["chase_is_unchanged_and_state_resets"] = true

func spawning_clears_ai_state() -> void:
	var r := await _fresh_run()
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._ai_phase[i] = 2
	r._submerged[i] = 1
	r.enemies.despawn(i)
	var j: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(j, 10.0)
	_check("the recycled slot starts clean", r._ai_phase[j], 0)
	_check("and is not submerged", r._submerged[j], 0)
	_check("and records its spawn HP", r._spawn_hp[j], 10.0)
	r.free()
	finished["spawning_clears_ai_state"] = true

func charger_commits_to_its_dash() -> void:
	var r := await _fresh_run()
	var t := EnemyTable.EnemyType.new(&"t_charge", 0, Color.WHITE, 40.0, 80.0,
		20.0, 10.0, 1, EnemyTable.Behaviour.CHARGER)
	r.player_pos = Vector2.ZERO
	var i: int = r.enemies.spawn(Vector2(600, 0), Vector2.ZERO, 40.0, 12.0, 0)
	r._spawn_enemy_state(i, 40.0)

	var v: Vector2 = r._behave(i, t, 1.0 / 60.0)
	_check("far off it approaches", r._ai_phase[i], r.CH_APPROACH)
	_check("moving toward the player",
		v.dot(r.player_pos - r.enemies.pos[i]) > 0.0, true)

	# Inside charge range: winds up, and stands still while it does.
	r.enemies.pos[i] = r.player_pos + Vector2(200, 0)
	v = r._behave(i, t, 1.0 / 60.0)
	_check("in range it winds up", r._ai_phase[i], r.CH_WINDUP)
	_check("and holds still to telegraph it", v, Vector2.ZERO)

	for k in 60:
		r._behave(i, t, 1.0 / 60.0)
	_check("then it dashes", r._ai_phase[i], r.CH_DASH)
	var locked: Vector2 = r._ai_aim[i]
	_check("with a locked aim", locked.length() > 0.0, true)

	# THE POINT: the aim does not track the player mid-dash. A dash that follows
	# you is undodgeable; one that commits is a timing puzzle.
	r.player_pos += Vector2(0, 600)
	v = r._behave(i, t, 1.0 / 60.0)
	_check("the dash does not re-aim", r._ai_aim[i], locked)
	_check("and travels along the locked aim",
		v.normalized().is_equal_approx(locked), true)
	_check("faster than it walks", v.length() > t.speed, true)

	# 20 ticks, not 60: the dash has ~0.18 s left, and recovery only lasts 0.8 s,
	# so a full second would run the whole cycle back round to APPROACH.
	for k in 20:
		r._behave(i, t, 1.0 / 60.0)
	_check("then it recovers", r._ai_phase[i], r.CH_RECOVER)
	v = r._behave(i, t, 1.0 / 60.0)
	_check("sluggishly", v.length() < t.speed, true)
	r.free()
	finished["charger_commits_to_its_dash"] = true

func flanker_leads_the_player() -> void:
	var r := await _fresh_run()
	var t := EnemyTable.EnemyType.new(&"t_flank", 0, Color.WHITE, 12.0, 110.0,
		12.0, 6.0, 1, EnemyTable.Behaviour.FLANKER)
	r.player_pos = Vector2.ZERO
	var i: int = r.enemies.spawn(Vector2(0, -500), Vector2.ZERO, 12.0, 12.0, 0)
	r._spawn_enemy_state(i, 12.0)

	# Player running hard along +x: the flanker must steer ahead of them.
	r.player_vel = Vector2(220, 0)
	var v: Vector2 = r._behave(i, t, 1.0 / 60.0)
	_check("it leads a moving player", v.x > 0.0, true)

	# Standing still, it degenerates to a chase rather than orbiting forever.
	r.player_vel = Vector2.ZERO
	var w: Vector2 = r._behave(i, t, 1.0 / 60.0)
	var straight: Vector2 = (r.player_pos - r.enemies.pos[i]).normalized()
	_check("and closes on a still one", w.normalized().dot(straight) > 0.6, true)
	_check("at its own speed", is_equal_approx(w.length(), t.speed), true)
	r.free()
	finished["flanker_leads_the_player"] = true

func player_velocity_is_tracked() -> void:
	var r := await _fresh_run()
	var before: Vector2 = r.player_pos
	r.input_override = Vector2(1, 0)
	r._step2_integrate(1.0 / 60.0)
	_check("moving right gives a positive x velocity", r.player_vel.x > 0.0, true)
	_check("and it matches the step actually taken",
		r.player_vel.is_equal_approx((r.player_pos - before) * 60.0), true)
	r.input_override = Vector2.ZERO
	r._step2_integrate(1.0 / 60.0)
	_check("standing still gives zero", r.player_vel, Vector2.ZERO)
	r.free()
	finished["player_velocity_is_tracked"] = true

func support_heals_but_never_past_spawn() -> void:
	var r := await _fresh_run()
	var t := EnemyTable.EnemyType.new(&"t_supp", 0, Color.WHITE, 60.0, 40.0,
		30.0, 2.0, 3, EnemyTable.Behaviour.SUPPORT)
	r.player_pos = Vector2.ZERO
	var sp: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 60.0, 12.0, 0)
	r._spawn_enemy_state(sp, 60.0)
	var hurt: int = r.enemies.spawn(Vector2(430, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(hurt, 30.0)          # spawned at 30, currently on 10
	r._step3_rebuild()

	r._behave(sp, t, 1.0)
	_check("a nearby wounded enemy is healed", r.enemies.integrity[hurt] > 10.0, true)
	_check("but never above its spawn HP",
		r.enemies.integrity[hurt] <= r._spawn_hp[hurt], true)

	r.enemies.integrity[hurt] = r._spawn_hp[hurt]
	r._behave(sp, t, 1.0)
	_check("healing a full enemy changes nothing",
		r.enemies.integrity[hurt], r._spawn_hp[hurt])

	# It keeps its distance rather than closing.
	r.enemies.pos[sp] = r.player_pos + Vector2(80, 0)
	var v: Vector2 = r._behave(sp, t, 1.0 / 60.0)
	_check("too close, it backs away", v.x > 0.0, true)
	r.enemies.pos[sp] = r.player_pos + Vector2(900, 0)
	v = r._behave(sp, t, 1.0 / 60.0)
	_check("too far, it closes", v.x < 0.0, true)
	r.free()
	finished["support_heals_but_never_past_spawn"] = true

func ambusher_is_untouchable_while_under() -> void:
	var r := await _fresh_run()
	var t := EnemyTable.EnemyType.new(&"t_amb", 0, Color.WHITE, 30.0, 90.0,
		20.0, 14.0, 2, EnemyTable.Behaviour.AMBUSHER)
	r.player_pos = Vector2.ZERO
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 30.0, 12.0, 0)
	r._spawn_enemy_state(i, 30.0, EnemyTable.Behaviour.AMBUSHER)

	var v: Vector2 = r._behave(i, t, 1.0 / 60.0)
	_check("it begins submerged", r._submerged[i], 1)
	_check("and travels faster while under", v.length() > t.speed, true)

	# Submerged means OUT OF THE GRID, which is the whole implementation of
	# untouchable: every hit path and the contact check read the grid.
	r._step3_rebuild()
	var n: int = r.grid.query_radius_into(r.enemies.pos[i], 60.0, r._buf, Grid.M_ENEMY)
	_check("a submerged enemy is not in the grid", n, 0)

	for k in 130:
		r._behave(i, t, 1.0 / 60.0)
	_check("it surfaces after its run", r._ai_phase[i], r.AM_SURFACING)
	_check("still untouchable during the tell", r._submerged[i], 1)
	_check("and stationary, so the tell can be read",
		r._behave(i, t, 1.0 / 60.0), Vector2.ZERO)

	for k in 60:
		r._behave(i, t, 1.0 / 60.0)
	_check("then it is active", r._ai_phase[i], r.AM_ACTIVE)
	_check("and targetable again", r._submerged[i], 0)
	r._step3_rebuild()
	var n2: int = r.grid.query_radius_into(r.enemies.pos[i], 60.0, r._buf, Grid.M_ENEMY)
	_check("back in the grid", n2 > 0, true)
	r.free()
	finished["ambusher_is_untouchable_while_under"] = true

func ranged_shoots_and_its_shots_bite() -> void:
	var r := await _fresh_run()
	var t := EnemyTable.EnemyType.new(&"t_rng", 0, Color.WHITE, 14.0, 55.0,
		14.0, 4.0, 2, EnemyTable.Behaviour.RANGED)
	r.player_pos = Vector2.ZERO
	var i: int = r.enemies.spawn(Vector2(420, 0), Vector2.ZERO, 14.0, 12.0, 0)
	r._spawn_enemy_state(i, 14.0, EnemyTable.Behaviour.RANGED)

	_check("no shots to begin with", r.hostiles.count, 0)
	for k in 120:
		r._behave(i, t, 1.0 / 60.0)
	_check("it fires on its cadence", r.hostiles.count > 0, true)

	# A hostile shot is NOT in the entity grid: the only thing it can hit is the
	# player, so it costs one distance test rather than a grid insert.
	r._step3_rebuild()
	var n: int = r.grid.query_radius_into(r.hostiles.pos[0], 80.0, r._buf, Grid.M_ALL)
	var found := false
	for k in mini(n, r._buf.size()):
		if Grid.tag_of(r._buf[k]) == Grid.Pop.PROJECTILE:
			found = true
	_check("hostile shots stay out of the grid", found, false)

	# It damages the player on contact. Cleared first: at a 1.6 s cadence those
	# 120 ticks produced more than one shot, and counting leftovers would make
	# this assertion about the cadence rather than about the hit.
	while r.hostiles.count > 0:
		r.hostiles.despawn(0)
	var one: int = r.hostiles.spawn(r.player_pos, Vector2(1, 0), 1.0, 4.0, 0)
	r._hostile_life[one] = 4.0
	var hp: float = r.player_health
	r.player_iframe = 0.0
	r._step6b_hostiles(1.0 / 60.0)
	_check("a hostile shot hurts", r.player_health < hp, true)
	_check("and is spent", r.hostiles.count, 0)

	# Terrain stops them, which is what makes walls cover.
	while r.hostiles.count > 0:
		r.hostiles.despawn(0)
	r.player_pos = Vector2(4000, 4000)          # far away, so terrain is what kills it
	var j: int = r.hostiles.spawn(Vector2(0, 0), Vector2(300, 0), 1.0, 4.0, 0)
	r._hostile_life[j] = 4.0
	var c: Vector2i = r.terrain.cell_xy(Vector2(6, 0))
	r.terrain.solid[c.y * r.terrain.w + c.x] = 1
	r._step6b_hostiles(1.0 / 60.0)
	_check("a hostile shot dies on rock", r.hostiles.count, 0)
	r.free()
	finished["ranged_shoots_and_its_shots_bite"] = true

func the_new_enemies_are_wired() -> void:
	var r := await _fresh_run()
	var all := EnemyTable.all()
	var by_id := {}
	for k in all.size():
		by_id[all[k].id] = all[k]
	var want := {
		&"sentinel": EnemyTable.Behaviour.CHARGER,
		&"tracer": EnemyTable.Behaviour.FLANKER,
		&"watchdog": EnemyTable.Behaviour.SUPPORT,
		&"rootkit": EnemyTable.Behaviour.AMBUSHER,
		&"probe": EnemyTable.Behaviour.RANGED,
	}
	for id in want:
		_check("%s is in the table" % id, by_id.has(id), true)
		if by_id.has(id):
			_check("%s has its behaviour" % id, by_id[id].behaviour, want[id])

	# These are INDICES into the table, read by the boss spawn, the win
	# condition, the flip guard and the worm train. Inserting a type above them
	# repoints them silently, which is the kind of bug that looks like physics.
	_check("ICE is still where the code thinks it is",
		all[EnemyTable.ICE].id, &"ice")
	_check("and so is the worm type", all[r.WORM_TYPE].id, &"worm")

	# Every new type is scheduled, or it will never be seen.
	var scheduled := {}
	for wv in SpawnDirector.new().waves:
		scheduled[wv.type_index] = true
	for id in want:
		var idx := -1
		for k in all.size():
			if all[k].id == id:
				idx = k
		_check("%s is scheduled in a wave" % id, scheduled.has(idx), true)
	r.free()
	finished["the_new_enemies_are_wired"] = true
