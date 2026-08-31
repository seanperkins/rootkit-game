extends SceneTree

## Mini-bosses: the schedule, the four types, and each signature mechanic.

var failures := 0
var finished := {}
const CASES := ["the_schedule_fires_each_once", "the_four_exist_and_ice_is_still_last", "splitting_is_bounded_and_deferred",
	"armour_is_directional", "killing_one_offers_a_card", "afterimages_are_bounded_and_expire",
	"the_pulse_is_blocked_by_walls"]

## A whole even number of Terrain.TILE either way, which is what lets a lone
## arena be centred on the origin and still land on tile boundaries.
const ARENA := Vector2(3072, 1920)

func _initialize() -> void:
	print("ROOTKIT — mini-bosses\n")
	the_schedule_fires_each_once()
	the_four_exist_and_ice_is_still_last()
	await splitting_is_bounded_and_deferred()
	await armour_is_directional()
	await killing_one_offers_a_card()
	afterimages_are_bounded_and_expire()
	the_pulse_is_blocked_by_walls()
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

func _type_index(id: StringName) -> int:
	var all := EnemyTable.all()
	for i in all.size():
		if all[i].id == id:
			return i
	return -1

func the_schedule_fires_each_once() -> void:
	var d := SpawnDirector.new()
	var seen := []
	var t := 0.0
	while t < SpawnDirector.SUBNET_SECONDS:
		for idx in d.due_minibosses(1.0 / 60.0):
			seen.append([d.elapsed, idx])
		d.elapsed += 1.0 / 60.0
		t += 1.0 / 60.0
	_check("four mini-bosses arrive", seen.size(), SpawnDirector.MINIBOSS_TIMES.size())

	# None in the last minute: ICE owns the subnet's ending.
	var late := 0
	for row in seen:
		if float(row[0]) > SpawnDirector.SUBNET_SECONDS - 60.0:
			late += 1
	_check("none in the last minute", late, 0)

	# A single tick that crosses a boundary must not double-fire.
	var d2 := SpawnDirector.new()
	d2.elapsed = SpawnDirector.MINIBOSS_TIMES[0] - 0.001
	var first: Array = d2.due_minibosses(0.5)
	d2.elapsed += 0.5
	var again: Array = d2.due_minibosses(0.5)
	_check("the crossing fires once", first.size(), 1)
	_check("and not again on the next step", again.size(), 0)

	d2.reset()
	_check("reset rearms them", d2.miniboss_fired[0], 0)

	# A clock jumped past every boundary fires NOTHING. Tests suppress ambient
	# spawning by setting elapsed to 999, and a long frame does the same thing
	# in real play — either way, four mini-bosses landing at once is not an
	# arrival, it is an accident.
	var d3 := SpawnDirector.new()
	d3.elapsed = 999.0
	_check("a clock jumped past them all fires none",
		d3.due_minibosses(1.0 / 60.0).size(), 0)
	finished["the_schedule_fires_each_once"] = true

func the_four_exist_and_ice_is_still_last() -> void:
	var all := EnemyTable.all()
	var by_id := {}
	for k in all.size():
		by_id[all[k].id] = all[k]
	for id in SpawnDirector.MINIBOSS_IDS:
		_check("%s is in the table" % id, by_id.has(id), true)
		if by_id.has(id):
			# Between firewall and ICE: a set-piece, not a boss.
			_check("%s is tougher than a firewall" % id,
				by_id[id].integrity > by_id[&"firewall"].integrity, true)
			_check("%s is weaker than ICE" % id,
				by_id[id].integrity < by_id[&"ice"].integrity, true)
			# Flippable, unlike ICE — a corruption build should be able to turn
			# a set-piece, which is most of why that build is exciting.
			_check("%s is flippable" % id,
				by_id[id].corruption_threshold < 1e17, true)

	# These are INDICES the boss spawn, the win condition and the flip guard all
	# read. Inserting a type above them repoints them silently.
	_check("ICE is still last", all[EnemyTable.ICE].id, &"ice")
	_check("and it is the final row", EnemyTable.ICE, all.size() - 1)

	# The schedule resolves to the real types, not to daemon by fallback.
	#
	# The step has to CROSS the time, not start on it: due_minibosses wants
	# `elapsed < t and elapsed + dt >= t`, so parking the clock exactly on the
	# boundary fires nothing and the assertion below indexed an empty array.
	var d := SpawnDirector.new()
	d.elapsed = SpawnDirector.MINIBOSS_TIMES[0] - 0.05
	var fired: Array = d.due_minibosses(0.1)
	_check("the schedule fires one at its time", fired.size(), 1)
	_check("the schedule resolves a real mini-boss",
		all[fired[0]].id, SpawnDirector.MINIBOSS_IDS[0])
	finished["the_four_exist_and_ice_is_still_last"] = true

func splitting_is_bounded_and_deferred() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"fork_bomb")
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 26.0, idx)
	r._spawn_enemy_state(i, 100.0)
	var before: int = r.enemies.count

	r._on_death(i)
	# Deferred: _on_death runs inside the drain, and spawning there pulls
	# entities out from under a pass still adjudicating them.
	_check("nothing spawned during the drain", r.enemies.count, before)
	_check("a split is queued", r._pending_splits.size(), 1)

	r._step9b_splits()
	_check("two children after the tick", r.enemies.count, before + 2)
	_check("the queue is drained", r._pending_splits.size(), 0)

	# THE BOUND. Kill everything repeatedly; without a leaf check this is an
	# unbounded cascade that fills the pool.
	for gen in range(8):
		for k in range(r.enemies.count - 1, -1, -1):
			if r.enemies.type_index[k] == idx:
				r._on_death(k)
				r.enemies.despawn(k)
		r._step9b_splits()
	var alive := 0
	for k in r.enemies.count:
		if r.enemies.type_index[k] == idx:
			alive += 1
	_check("the cascade terminates", alive, 0)
	_check("and never overflowed the pool", r.enemies.count < r.MAX_ENEMIES, true)
	r.free()
	finished["splitting_is_bounded_and_deferred"] = true

func armour_is_directional() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"packet_filter")
	var i: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 200.0, 26.0, idx)
	r._spawn_enemy_state(i, 200.0)
	r.enemies.vel[i] = Vector2(-1, 0) * 40.0        # facing -x

	_check("a hit from the front is reduced",
		r._facing_scale(i, r.enemies.pos[i] + Vector2(-100, 0)) < 0.2, true)
	_check("a hit from behind is not",
		r._facing_scale(i, r.enemies.pos[i] + Vector2(100, 0)), 1.0)
	# The boundary is the HALF-PLANE, not an arbitrary cone.
	_check("a hit from the side is full",
		r._facing_scale(i, r.enemies.pos[i] + Vector2(0, 100)), 1.0)
	# A stationary one has no facing to speak of, so it is not armoured.
	r.enemies.vel[i] = Vector2.ZERO
	_check("a still one is not armoured",
		r._facing_scale(i, r.enemies.pos[i] + Vector2(-100, 0)), 1.0)

	var j: int = r.enemies.spawn(Vector2(500, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(j, 10.0)
	r.enemies.vel[j] = Vector2(-1, 0) * 40.0
	_check("an ordinary enemy has no facing armour",
		r._facing_scale(j, r.enemies.pos[j] + Vector2(-100, 0)), 1.0)
	r.free()
	finished["armour_is_directional"] = true

func killing_one_offers_a_card() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"packet_filter")
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 26.0, idx)
	r._spawn_enemy_state(i, 100.0)
	var salvage_before: int = r.salvage
	var levels_before: int = r.pending_levels
	r._on_death(i)
	_check("it pays salvage", r.salvage > salvage_before, true)
	_check("and offers a card", r.pending_levels, levels_before + 1)

	# Exactly once, even if the death dispatches twice.
	r._on_death(i)
	_check("and only once", r.pending_levels, levels_before + 1)

	# An ordinary enemy pays neither.
	var j: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(j, 10.0)
	var s2: int = r.salvage
	r._on_death(j)
	_check("an ordinary kill pays no bonus salvage", r.salvage, s2)
	r.free()
	finished["killing_one_offers_a_card"] = true

func afterimages_are_bounded_and_expire() -> void:
	var t := Terrain.new(ARENA)
	t.generate(4, Vector2.ZERO)
	t.add_temp_zone(Vector2.ZERO, 60.0, Terrain.Kind.HAZARD, 2.0)
	_check("an afterimage is felt", t.temp_zone_at(Vector2(10, 0)),
		Terrain.Kind.HAZARD)
	_check("but not far from it", t.temp_zone_at(Vector2(400, 0)), -1)

	t.step_temp_zones(2.5)
	_check("and it expires", t.temp_zone_at(Vector2(10, 0)), -1)

	# HARD CAP. A long null_ptr fight must stop producing new afterimages rather
	# than growing the list without limit.
	for k in Terrain.MAX_TEMP_ZONES + 20:
		t.add_temp_zone(Vector2(k * 5, 0), 40.0, Terrain.Kind.HAZARD, 99.0)
	_check("the overlay is capped",
		t.temp_zone_count() <= Terrain.MAX_TEMP_ZONES, true)

	# Expiry uses swap-remove; prove it does not skip an entry.
	t.clear_temp_zones()
	t.add_temp_zone(Vector2(0, 0), 50.0, Terrain.Kind.HAZARD, 0.5)
	t.add_temp_zone(Vector2(500, 0), 50.0, Terrain.Kind.HAZARD, 0.5)
	t.add_temp_zone(Vector2(1000, 0), 50.0, Terrain.Kind.HAZARD, 0.5)
	t.step_temp_zones(1.0)
	_check("every expired entry goes, none skipped", t.temp_zone_count(), 0)

	# The BAKED grid is untouched: that is what keeps it a bare array index.
	var before := t.zone.duplicate()
	t.add_temp_zone(Vector2(100, 100), 60.0, Terrain.Kind.HAZARD, 1.0)
	_check("the baked zone grid never changes", t.zone, before)
	finished["afterimages_are_bounded_and_expire"] = true

func the_pulse_is_blocked_by_walls() -> void:
	var t := Terrain.new(ARENA)
	t.generate(6, Vector2.ZERO)
	t.solid.fill(0)
	_check("open ground sees across itself",
		t.has_line_of_sight(Vector2(-300, 0), Vector2(300, 0)), true)

	for y in range(-2, 3):
		var c := t.cell_xy(Vector2(0, y * Terrain.CELL))
		t.solid[c.y * t.w + c.x] = 1
	_check("a wall between them blocks it",
		t.has_line_of_sight(Vector2(-300, 0), Vector2(300, 0)), false)
	_check("and it is symmetric",
		t.has_line_of_sight(Vector2(300, 0), Vector2(-300, 0)), false)
	_check("a point sees itself",
		t.has_line_of_sight(Vector2.ZERO, Vector2.ZERO), true)

	# It must terminate on every seed, however awkward the geometry.
	for sd in range(40):
		var u := Terrain.new(ARENA)
		u.generate(sd, Vector2.ZERO)
		u.has_line_of_sight(Vector2(-1500, -900), Vector2(1500, 900))
	_check("the walk always terminates on every seed", true, true)
	finished["the_pulse_is_blocked_by_walls"] = true
