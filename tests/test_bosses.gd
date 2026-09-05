extends SceneTree

var failures := 0
var completed := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		print("  FAIL  ", label)
		failures += 1

func _initialize() -> void:
	SaveGame.use_test_paths()
	await process_frame
	await sentinel()
	await worm()
	await root_cause()
	await recovery()
	check("all cases completed", completed == 4)
	print("  PASS — boss behavior and recovery" if failures == 0 else "  FAIL — %d assertions" % failures)
	quit(0 if failures == 0 else 1)

func fresh(number: int, players: int = 1) -> Node2D:
	SaveGame.use_fresh_state()
	var rows := []
	for s in players: rows.append({"slot": s, "name": "boss%d" % s, "counters": {}})
	var desc := NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"session_id": 1, "seed": 42, "delay": 0, "choice_timeout": 0, "roster": rows})
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	g.external_drive = true
	g.input_override = Vector2.ZERO
	g.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.SOLO if players == 1 else NetworkSession.Role.HOST))
	root.add_child(g)
	await process_frame
	while g.subnet < number: g._advance_subnet()
	g.director.elapsed = SpawnDirector.SUBNET_SECONDS
	g._step1_spawn(0)
	g._arriving.fill(0)
	g._refresh_live_cache()
	return g

func hit(g: Node2D, index: int, amount: float, kind: int = HitQueue.Kind.DAMAGE) -> void:
	g.queue.begin_tick()
	g.queue.append(kind, -1, index, g.enemies.generation[index], amount)
	g._steps78_drain()

func sentinel() -> void:
	for seed_value in [20260830, 1, 42, 12345, 987654]:
		var terrain := Terrain.new(Vector2(8256, 4992), 1, seed_value, 1)
		terrain.generate(seed_value, Vector2.ZERO)
		for point in terrain.spire_points:
			check("capture anchors stay safe and reachable across seeds", terrain.spawn_is_safe(point, 12, 0) and not CampaignNavigation.path(terrain, terrain.spawner_pos(0, 0), point).is_empty())
	var g := await fresh(1, 4)
	var hp: float = g.enemies.integrity[0]
	check("four safe objectives", g.terrain.spire_points.size() == 4 and g.terrain.generation_error.is_empty())
	g._step3_rebuild()
	check("shield excludes core from grid", g._no_grid[0] != 0)
	hit(g, 0, hp * 2)
	check("direct damage cannot bypass capture", g.enemies.integrity[0] == hp)
	hit(g, 0, 1e20, HitQueue.Kind.CORRUPTION)
	check("direct corruption cannot bypass capture", g.enemies.corruption[0] == 0)
	var cell: int = g.terrain.cell_index(g.enemies.pos[0])
	g.terrain.zone[cell] = Terrain.Kind.HAZARD + 1
	g.queue.begin_tick()
	g._step2b_zones(1)
	g._steps78_drain()
	check("zone damage cannot bypass capture", g.enemies.integrity[0] == hp)
	g.terrain.zone[cell] = 0
	for s in 4: g.player_pos[s] = g.terrain.spire_points[0]
	g._step2f_boss(1)
	check("four occupants do not quadruple capture", g._spire_progress[0] == 1)
	for s in 4: g.player_pos[s] = Vector2.ZERO
	g._step2f_boss(1)
	check("vacated progress drains", g._spire_progress[0] == 0)
	for s in 4: g.player_pos[s] = g.terrain.spire_points[s]
	g._step2f_boss(g.SENTINEL_CAPTURE_TIME)
	check("parallel capture latches all spires", g._sentinel_spires_left == 0 and g.phase == g.Phase.FIGHTING)
	check("shield lasts to next world step", g._boss_shielded(0))
	g._step2f_boss(SessionRules.TICK_DT)
	check("core exposed exactly once", not g._boss_shielded(0))
	for s in 4: g.player_pos[s] = Vector2.ZERO
	g._step2f_boss(20)
	check("captured progress never drains", g._spire_progress[0] == g.SENTINEL_CAPTURE_TIME)
	hit(g, 0, hp + 1)
	check("core death starts collapse and opens pad", g.phase == g.Phase.CLEARED and g.terrain.gate().open)
	g.free()
	completed += 1

func worm() -> void:
	var g := await fresh(2)
	check("eight real starting segments", g.enemies.count == 8)
	check("head has distinct scaled HP", is_equal_approx(g._spawn_hp[0], g.WORM_HEAD_INTEGRITY_BASE * g._hp_mult()) and g._spawn_hp[0] > g._spawn_hp[1] * 6)
	hit(g, 2, 100000)
	g._step9_recycle()
	check("body death does not clear", g.enemies.count == 7 and g.phase == g.Phase.FIGHTING)
	g._step2f_boss(g.WORM_REGEN_INTERVAL)
	check("landed damage prevents regen", g._worm_regens_left == 4 and g.enemies.count == 7)
	hit(g, 0, 0)
	g._step2f_boss(g.WORM_REGEN_INTERVAL)
	check("zero damage does not prevent regrowth", g._worm_regens_left == 3 and g.enemies.count == 8)
	var indices := {}
	for i in g.enemies.count: indices[g._worm_seg[i]] = true
	check("regrowth uses maximum surviving index plus one", indices.has(8) and not indices.has(2) and indices.size() == 8)
	g._step2f_boss(g.WORM_REGEN_INTERVAL)
	g._step2f_boss(g.WORM_REGEN_INTERVAL)
	check("regrowth reaches ten total, including head", g.enemies.count == 10 and g._worm_regens_left == 1)
	g.enemies.integrity[0] -= 100
	var before: float = g.enemies.integrity[0]
	g._step2f_boss(g.WORM_REGEN_INTERVAL)
	check("at cap regens head instead of adding body", g.enemies.count == 10 and g.enemies.integrity[0] > before and g._worm_regens_left == 0)
	g.enemies.integrity[0] -= 10
	before = g.enemies.integrity[0]
	g._step2f_boss(1000)
	check("budget exhaustion is permanent", g.enemies.integrity[0] == before)
	hit(g, 0, 100000)
	g._step9_recycle()
	check("head death cascades bodies and banks once", g.enemies.count == 0 and g.phase == g.Phase.CLEARED and g.salvage == 500)
	g.free()
	completed += 1

func root_cause() -> void:
	var g := await fresh(3)
	g.feel.drain_sfx()
	g.enemies.integrity[0] = g._spawn_hp[0] * 0.2
	g.enemies.vel[0] = Vector2(123, 456)
	g._submerged[0] = 1
	g._target_slot = 0
	g._root_cause_behave(0, 46, Vector2(100, 0), SessionRules.TICK_DT)
	check("phase jumps directly to charge", g._root_cause_phase == 2 and g._submerged[0] == 0 and g.enemies.vel[0] == Vector2.ZERO)
	check("one phase cue for a double threshold crossing", Array(g.feel.drain_sfx()).count("root_phase") == 1)
	var warning: Vector2 = g._ai_aim[0]
	var velocity: Vector2 = g._charge(0, 46, Vector2(0, 100), g.CHARGE_WINDUP + 0.01, true)
	check("boss launch follows original warning", velocity.normalized().is_equal_approx(warning))
	g._ai_phase[0] = g.CH_APPROACH
	g._charge(0, 46, Vector2(100, 0), 0)
	velocity = g._charge(0, 46, Vector2(0, 100), g.CHARGE_WINDUP + 0.01)
	check("ordinary chargers retain late targeting", velocity.normalized().is_equal_approx(Vector2.DOWN))
	g.enemies.integrity[0] = g._spawn_hp[0] * 0.5
	g._root_cause_behave(0, 46, Vector2(400, 0), 0)
	g._root_cause_behave(0, 46, Vector2(400, 0), 1.7)
	check("barrage has a pre-volley warning", g._ai_phase[0] == 1 and g.hostiles.count == 0)
	g._root_cause_behave(0, 46, Vector2(400, 0), 0.31)
	check("barrage creates three different trajectories", g.hostiles.count == 3 and not g.hostiles.vel[0].is_equal_approx(g.hostiles.vel[1]))
	hit(g, 0, 100000)
	check("final head kill wins without another vote", g.won and not g.route_pending)
	g.free()
	completed += 1

func recovery() -> void:
	for number in range(1, 4):
		var h := MultiplayerHarness.new()
		await h.setup(self, 2, 0, 42)
		for g in h.runs:
			while g.subnet < number: g._advance_subnet()
			g.director.elapsed = SpawnDirector.SUBNET_SECONDS
			g._step1_spawn(0)
			g._arriving.fill(0)
			if number == 1: g.player_pos[0] = g.terrain.spire_points[0]
			if number == 3: g.enemies.integrity[0] = g._spawn_hp[0] * 0.5
		for t in 30: h.step(func(_t): return [Vector2.ZERO, Vector2.ZERO])
		var host: Node2D = h.runs[0]
		var peer: Node2D = h.runs[1]
		check("boss %d peers agree" % number, host._state_hash() == peer._state_hash())
		var snapshot: PackedByteArray = host.serialize_state(host.tick)
		peer._worm_regen_timer = 1.0
		check("boss %d recovery accepted" % number, peer.restore_state(snapshot, host.tick))
		check("boss %d recovered hash" % number, host._state_hash() == peer._state_hash())
		for t in range(30, 60): h.step(func(_t): return [Vector2.ZERO, Vector2.ZERO])
		check("boss %d stays in sync after restore" % number, host._state_hash() == peer._state_hash())
		var raw: Dictionary = bytes_to_var(snapshot)
		var field_index := 0
		for entry in host.STATE_FIELDS:
			if (entry[2] & host.SNAPSHOT) == 0: continue
			if entry[1] == "_sentinel_spires_left": raw.fields[field_index] = 5
			field_index += 1
		var before: int = peer._state_hash()
		check("invalid boss state rejected", not peer.restore_state(var_to_bytes(raw), host.tick))
		check("rejection is transactional", peer._state_hash() == before)
		h.teardown()
	completed += 1
