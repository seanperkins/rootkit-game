extends SceneTree

var failures := 0
const DT := 1.0 / 60.0

func check(label: String, value: bool) -> void:
	if not value:
		failures += 1
		print("  FAIL  " + label)
	else:
		print("  ok    " + label)

func make_run(players: int = 2) -> Node2D:
	var roster := []
	for s in players:
		roster.append({"slot": s, "name": "p%d" % s, "program": ProgramTable.IDS[s], "counters": SaveGame.session_counters()})
	var desc := NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"version": "dev", "session_id": 1, "seed": 20260830, "delay": 0,
		"choice_timeout": 0, "roster": roster})
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	r.set_physics_process(false)
	r.input_override = Vector2.ZERO
	return r

func vote(r: Node2D, slot: int, pick: int) -> void:
	r._apply_choice(slot, pick, -1, int(r._offer_open[slot]["seq"]))
	for i in 90:
		if r.transfer_ticks > 0: r._step_transfer()

func start_vote(r: Node2D) -> void:
	r.phase = r.Phase.CLEARED
	r.terrain.open_gate()
	r._open_route_vote()
	# Fixed packages isolate vote mechanics from candidate sampling.
	r.route_candidates = PackedInt32Array([0, 1, 2])
	for slot in r._live_slots(): r._offer_open[slot]["contents"] = r.route_candidates.duplicate()

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await process_frame
	var hello := Protocol.decode_control(Protocol.Message.HELLO, 0, var_to_bytes({
		"protocol": SessionRules.PROTOCOL, "version": "dev", "name": "hacker",
		"program": "virus", "counters": {}, "slot": -1}))
	check("HELLO preserves the chosen program", hello.get("program", "") == "virus")
	var r := make_run(4)
	check("invalid programs fall back safely", ProgramTable.clean({}) == "operator")
	check("program preference is sanitised", SaveGame.sanitise_string_pref("program", "bad") == "operator")
	check("all four program vectors reach the build", r.loadouts[1].holds(&"spike") == 0 and r.loadouts[2].holds(&"broadcast") == 0 and r.loadouts[3].holds(&"chain") == 0)
	check("virus includes corruption and offensive tradeoff", r.resolved[r._gid(3, 0)].corruption > 0 and is_equal_approx(r.loadouts[3].mult[&"attack"], 0.8))
	check("program sheet tradeoffs apply", r._eff_integrity(1) < r._eff_integrity(0) and r._eff_integrity(2) > r._eff_integrity(0))
	var copy := make_run(4)
	check("mixed program snapshot restores", copy.restore_state(r.serialize_state(r.tick), r.tick))
	check("mixed program build remains deterministic", copy._state_hash() == r._state_hash())
	r._place_network_op()
	check("objective placement has a walkable approach", r.ops_state == 1 and r._ops_clear_line(r.player_pos[0], r.ops_pos, 24.0))
	r.ops_state = 1
	r.ops_pos = Vector2.ZERO
	r.ops_start = Vector2.ZERO
	r.ops_end = Vector2.ZERO
	r.player_pos.fill(Vector2.ZERO)
	r._step_network_ops(DT)
	check("coordinated hacking accelerates progress", is_equal_approx(r.ops_progress, DT * 2.2))
	r.slot_state[3] = r.SlotState.DEAD
	r.slot_state[2] = r.SlotState.ABSENT
	r.ops_progress = 0
	r._step_network_ops(DT)
	check("unfinished hack restores", copy.restore_state(r.serialize_state(r.tick), r.tick) and is_equal_approx(copy.ops_progress, r.ops_progress))
	check("only LIVE hackers contribute", is_equal_approx(r.ops_progress, DT * 1.4))
	r.player_pos.fill(Vector2(500, 500))
	var before: float = r.ops_progress
	r._step_network_ops(DT)
	check("unattended objectives wait", r.ops_progress == before)
	r.player_pos.fill(Vector2.ZERO)
	r.ops_progress = 11.99
	r._step_network_ops(DT)
	check("vault grants each LIVE player a rank offer", r.ops_state == 2 and r.salvage == 75 and r._offer_open[0]["kind"] == r.OfferKind.RANK_ONLY and not r._offer_open[1].is_empty())
	for i in 60:
		r._step_network_ops(DT)
	check("completion cannot pay twice", r.salvage == 75)
	r.free()
	copy.free()

	r = make_run(2)
	r._advance_subnet()
	var centre: Vector2 = r.terrain.nearest_open(r.terrain.arena().get_center())
	r.ops_pos = centre
	r.ops_state = 2
	r.ops_progress = 12.0
	r.player_pos.fill(centre)
	var enemy: int = r.enemies.spawn(centre, Vector2.ZERO, 100, 10, 0)
	r._spawn_enemy_state(enemy, 100, r.enemy_types[0].behaviour)
	r.queue.begin_tick()
	for i in 61:
		r._step_network_ops(DT)
	check("relay shares defenses with both uplinks", r.player_shield[0] == 4.0 and r.player_shield[1] == 4.0)
	check("linked relay emits combined damage through queue", r.queue.count == 1 and r.queue.amount[0] == 12.0)
	r.slot_state[1] = r.SlotState.ABSENT
	r.ops_pulse = 0
	for i in 61:
		r._step_network_ops(DT)
	check("absent player loses relay recharge", r.player_shield[1] == 4.0 and r.player_shield[0] == 6.0)
	r.free()

	r = make_run(1)
	r._advance_subnet()
	r._advance_subnet()
	r.ops_state = 1
	r.ops_start = r.terrain.nearest_open(r.terrain.arena().get_center())
	r.ops_end = r.ops_start + Vector2(100, 0)
	r.ops_pos = r.ops_start
	for i in 721:
		r.player_pos[0] = r.ops_pos
		r._step_network_ops(DT)
	check("escorted upload reaches its destination once", r.ops_state == 2 and r.ops_pos == r.ops_end and r.salvage == 75)
	r.free()

	r = make_run(2)
	copy = make_run(2)
	start_vote(r)
	start_vote(copy)
	r.choose_route(2)
	check("UI route choice is staged without simulation mutation", r.route_votes[0] == -1 and r._local_choice.x == 2)
	var seq: int = r._offer_open[0]["seq"]
	r._apply_choice(0, 3, -1, seq)
	r._apply_choice(0, 2, -1, seq - 1)
	r._apply_choice(0, 2, 0, seq)
	check("invalid and stale route records are ignored", r.route_votes[0] == -1)
	var snapshot: Dictionary = bytes_to_var(r.serialize_state(r.tick))
	var field := 0
	for entry in r.STATE_FIELDS:
		if (int(entry[2]) & r.SNAPSHOT) == 0:
			continue
		if entry[1] == "route_votes":
			snapshot["fields"][field] = PackedInt32Array([99, -1, -1, -1])
		field += 1
	var hash_before: int = r._state_hash()
	check("invalid vote snapshot rejected transactionally", not r.restore_state(var_to_bytes(snapshot), r.tick) and r._state_hash() == hash_before)
	var rng_before: int = r._route_rng.state
	vote(r, 0, 2)
	check("one voter cannot advance the party", r.subnet == 1 and r.route_pending)
	check("vote snapshot restores open ballot and cast vote", copy.restore_state(r.serialize_state(r.tick), r.tick) and copy.route_votes[0] == 2)
	vote(r, 1, 2)
	vote(copy, 1, 2)
	check("unanimous vote advances exactly once", r.subnet == 2 and not r.route_pending and r.route_active == 2)
	check("no tie consumes no route RNG", r._route_rng.state == rng_before)
	check("vote continuation after restore matches", copy._state_hash() == r._state_hash())
	check("route applies wave and corruption modifiers", is_equal_approx(r.director.rate_mult, 2.3) and is_equal_approx(r.thresholds[0], r.enemy_types[0].corruption_threshold * SpawnDirector.threshold_mult(2) * 0.75))
	start_vote(r)
	start_vote(copy)
	vote(r, 0, 0)
	vote(copy, 0, 0)
	vote(r, 1, 1)
	vote(copy, 1, 1)
	check("seeded tie picks only leaders identically", r.route_active in [0, 1] and r.route_active == copy.route_active and r._route_rng.state == copy._route_rng.state)
	r.free()
	copy.free()

	r = make_run(2)
	start_vote(r)
	vote(r, 0, 0)
	r._park(1)
	for i in 90: r._step_transfer()
	check("departure resolves an uncast ballot to option zero", r.subnet == 2 and r.route_active == 0)
	r.free()
	r = make_run(2)
	start_vote(r)
	r._park(1)
	r._return(1, r.tick)
	check("returning voter keeps the resolved ballot", r._offer_open[1].is_empty() and r.route_votes[1] == 0)
	vote(r, 0, 0)
	check("returned voter cannot hold the vote", r.subnet == 2)
	r.free()
	r = make_run(2)
	start_vote(r)
	for slot in 2:
		r._offer_open[slot]["deadline"] = r.tick
	r._resolve_deadlines()
	for i in 90: r._step_transfer()
	check("deadline auto-votes keep campaign moving", r.subnet == 2 and r.route_active == 0)
	r.free()
	r = make_run(1)
	r.route_active = 0
	r.ops_state = 1
	r.ops_pos = Vector2.ZERO
	r.player_pos[0] = Vector2.ZERO
	r.ops_alarm = 3.99
	r._step_network_ops(DT)
	check("job reinforcements respect route integrity and spawn accounting", r.enemies.count == 1 and r.director.spawned == 1 and is_equal_approx(r.enemies.integrity[0], r.enemy_types[0].integrity * r._hp_mult() * 0.85))
	r.free()
	await process_frame
	print("  PASS — all cases" if failures == 0 else "  FAIL — %d assertions" % failures)
	quit(0 if failures == 0 else 1)
