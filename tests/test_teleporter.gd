extends SceneTree

var failures := 0
const DT := 1.0 / 60.0

func check(label: String, passed: bool) -> void:
	if not passed: failures += 1
	print("  %s %s" % ["ok  " if passed else "FAIL", label])

func make_run(players: int = 4) -> Node2D:
	var roster := []
	for s in players: roster.append({"slot": s, "name": "p%d" % s, "counters": {}})
	var desc := NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"version": "dev", "session_id": 1, "seed": 20260830, "delay": 0,
		"choice_timeout": 0, "roster": roster})
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.external_drive = true
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	r.set_physics_process(false)
	r.input_override = Vector2.ZERO
	return r

func drive(r: Node2D, choices: Dictionary = {}) -> void:
	for s in r._live_slots():
		var pick: int = choices.get(s, -1)
		var seq: int = r._offer_open[s].get("seq", -1)
		r.lockstep.submit(s, r.lockstep.executed, Vector2.ZERO, pick, -1, seq)
	r._physics_process(DT)

func gather(r: Node2D) -> void:
	r.phase = r.Phase.CLEARED
	r.terrain.open_gate()
	r.terrain.build_distance_field()
	r.collapse_left = r.COLLAPSE_SECONDS
	for s in r._live_slots():
		r.player_pos[s] = r.terrain.teleporter_pos() + Vector2(-20 if s % 2 == 0 else 20, -20 if s < 2 else 20)
	r.player_prev_pos = r.player_pos.duplicate()
	r.player_render_pos = r.player_pos.duplicate()

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await process_frame
	var r := make_run()
	var copy := make_run()
	check("single allocation is larger than the old arena", r.terrain.arenas.size() == 1 and r.terrain.arena().get_area() > 7104.0 * 4416.0)
	check("single grid is smaller than the old three-arena minimum", r.terrain.solid.size() < 3 * int(7104 * 4416 / (32 * 32)))
	gather(r)
	r.player_pos[3] += Vector2(200, 0)
	drive(r)
	check("three gathered teammates cannot start a four-player vote", not r.route_pending)
	gather(r)
	drive(r)
	check("all four footprints fit the pad and open one ballot", r.route_pending and r.teleporter_gathered() == 4)
	var old_ground: Terrain = r.terrain
	var collapse: float = r.collapse_left
	var cards: PackedInt32Array = r.route_candidates.duplicate()
	check("three candidates are distinct valid routes", r._valid_route_candidates(cards))
	drive(r, {0: 0, 1: 1})
	check("voting freezes collapse but consumes input", r.collapse_left == collapse and r.route_votes[0] == 0 and r.route_votes[1] == 1)
	check("mid-vote restore succeeds", copy.restore_state(r.serialize_state(r.tick), r.tick))
	drive(r, {2: 0, 3: 1})
	drive(copy, {2: 0, 3: 1})
	check("tie is restored identically and picks a leader", r.route_selected in [cards[0], cards[1]] and copy._state_hash() == r._state_hash())
	check("charge precedes generation", r.terrain == old_ground and r.subnet == 1 and r.transfer_ticks > 36)
	for i in 53:
		drive(r)
		drive(copy)
	check("both peers materialize the same new world", r.subnet == 2 and r.terrain != old_ground and r._state_hash() == copy._state_hash() and r.terrain.solid == copy.terrain.solid)
	for s in 4:
		check("arrival %d is safe and resets interpolation" % s, r.terrain.spawn_is_safe(r.player_pos[s], r.PLAYER_RADIUS, 0) and r.player_pos[s] == r.player_prev_pos[s] and r.player_vel[s] == Vector2.ZERO)
	check("post-transfer restore rebuilds geometry", copy.restore_state(r.serialize_state(r.tick), r.tick) and copy._state_hash() == r._state_hash())
	for i in 36: drive(r)
	check("transfer completes without changing XP or replaying salvage", r.transfer_ticks == 0 and r.level == 1 and r.salvage == 0)
	# The second transfer follows the same input path and the terminal boss
	# wins without constructing a fourth destination.
	gather(r)
	drive(r)
	drive(r, {0: 2, 1: 2, 2: 2, 3: 2})
	for i in 54: drive(r)
	check("second transfer enters the final subnet", r.subnet == 3 and not r.terrain.has_gate())
	check("final-subnet arrival snapshot reconstructs without a gate", copy.restore_state(r.serialize_state(r.tick), r.tick) and copy._state_hash() == r._state_hash())
	for i in 36: drive(r)
	var boss: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, 10, 48, EnemyTable.boss_index(r.subnet))
	r._spawn_enemy_state(boss, 10)
	r._on_death(boss)
	check("final boss wins directly with no fourth vote", r.won and not r.route_pending and r.transfer_ticks == 0 and r.subnet == 3)
	r.free()
	copy.free()

	# Exercise every route's real destination, fresh and recovered geometry.
	for route in RouteTable.NAMES.size():
		r = make_run(1)
		copy = make_run(1)
		r.route_active = route
		r._advance_subnet()
		check("route %d creates safe arrivals" % route, r.terrain.generation_error.is_empty() and r.terrain.validate_spawners(r.PLAYER_RADIUS).is_empty())
		check("route %d restores collision and zones" % route, copy.restore_state(r.serialize_state(r.tick), r.tick) and copy.terrain.solid == r.terrain.solid and copy.terrain.zone == r.terrain.zone and copy.terrain.rects == r.terrain.rects and copy._state_hash() == r._state_hash())
		var baseline: Terrain = r._make_subnet_terrain(2, -1)
		if route == 3:
			check("HOT adds exactly 300 exposed cells", r.terrain.zone.count(1 + Terrain.Kind.HAZARD) + r.terrain.zone.count(1 + Terrain.Kind.SLOW) + r.terrain.zone.count(1 + Terrain.Kind.CORRUPTION) == baseline.zone.count(1 + Terrain.Kind.HAZARD) + baseline.zone.count(1 + Terrain.Kind.SLOW) + baseline.zone.count(1 + Terrain.Kind.CORRUPTION) + 300)
		if route == 6:
			check("COMPACT removes at least a third of open ground", r.terrain.solid.count(0) < baseline.solid.count(0) * 0.67)
		if route == 4:
			r._step1_spawn(2.0)
			check("behavior route produces tracers in opening wave", r.enemies.type_index.slice(0, r.enemies.count).has(EnemyTable.index_of(&"tracer")))
		if route == 5:
			r.director.elapsed = 55.0 - DT * 1.5
			r._step1_spawn(DT)
			check("early route fires its real miniboss at 55s", r.director.miniboss_fired[0] == 1)
			r.director.elapsed = 80.0 - DT * 1.5
			var before: int = r.enemies.type_index.slice(0, r.enemies.count).count(r._fork_bomb_index)
			r._step1_spawn(DT)
			check("original miniboss time cannot duplicate it", r.enemies.type_index.slice(0, r.enemies.count).count(r._fork_bomb_index) == before)
		r.free()
		copy.free()

	r = make_run(2)
	copy = make_run(2)
	check("archive is hidden and impassable before its job", not r.terrain.room_unlocked and r.terrain.is_solid(r.terrain.room_rect.get_center()))
	r.ops_state = 1
	r.ops_pos = Vector2.ZERO
	r.ops_progress = 11.99
	r.player_pos.fill(Vector2.ZERO)
	r._step_network_ops(DT)
	check("job completion opens the room and its connecting passage", r.terrain.room_unlocked and not r.terrain.is_solid(r.terrain.room_rect.get_center()) and not r.terrain.is_solid(r.terrain.room_link.get_center()))
	check("revealed room restores before resuming simulation", copy.restore_state(r.serialize_state(r.tick), r.tick) and copy.terrain.solid == r.terrain.solid and copy._state_hash() == r._state_hash())
	var salvage: int = r.salvage
	r.player_pos[0] = r.terrain.room_rect.get_center()
	r._step_network_ops(DT)
	r._step_network_ops(DT)
	check("archive pays the party once", r.room_claimed and r.salvage == salvage + 100)
	check("claimed archive survives recovery", copy.restore_state(r.serialize_state(r.tick), r.tick) and copy.room_claimed)
	r.phase = r.Phase.CLEARED
	r.terrain.open_gate()
	r.terrain.build_distance_field()
	r.collapse_left = 0.1
	r._step2d_collapse(1.0)
	check("revealed archive collapses and cannot shelter a player forever", r.terrain.is_void(r.terrain.room_rect.get_center()) and r.slot_state[0] == r.SlotState.DEAD)
	r.free()
	copy.free()

	r = make_run(3)
	gather(r)
	drive(r)
	var rng_before: int = r._route_rng.state
	drive(r, {0: 0, 1: 1, 2: 2})
	check("three-way tie draws one of the three leaders", r.route_candidates.has(r.route_selected) and r._route_rng.state != rng_before and r.transfer_ticks > 36)
	r.free()

	r = make_run(1)
	gather(r)
	r._step2c_gate()
	r._die(0)
	check("last LIVE loss cancels voting without advancement", not r.route_pending and r.transfer_ticks == 0 and r.subnet == 1)
	r.free()
	await process_frame
	print("  PASS — all cases" if failures == 0 else "  FAIL — %d assertions" % failures)
	quit(0 if failures == 0 else 1)
