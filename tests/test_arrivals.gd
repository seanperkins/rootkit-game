extends SceneTree

## Mini-bosses and ICE teleport in, and are untouchable while they do.
##
## "Out of the grid" covers hits, targeting and contact — but NOT the three
## passes that walk enemies.count directly. Two of those were named wrongly in
## an early draft of the spec (_step4_steer only writes force; _step6b_hostiles
## iterates hostiles, not enemies), so the cases below assert the OUTCOMES —
## position unchanged, no shot spawned, player_health unchanged, no corruption —
## rather than that a particular function was skipped.

const DT := 1.0 / 60.0
var failures := 0
var finished := {}

const CASES := ["an_arrival_is_out_of_the_grid", "an_arrival_does_not_move",
	"a_pulse_arrival_cannot_touch_the_player", "hazard_and_corruption_are_held_off",
	"it_becomes_live_when_the_timer_ends", "the_timer_survives_recycle_compaction",
	"the_timer_survives_collapse_compaction"]

func _initialize() -> void:
	print("ROOTKIT — arrivals\n")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	await an_arrival_is_out_of_the_grid()
	await an_arrival_does_not_move()
	await a_pulse_arrival_cannot_touch_the_player()
	await hazard_and_corruption_are_held_off()
	await it_becomes_live_when_the_timer_ends()
	await the_timer_survives_recycle_compaction()
	await the_timer_survives_collapse_compaction()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-4):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

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

func _type_index(r: Node2D, id: StringName) -> int:
	for k in r.enemy_types.size():
		if r.enemy_types[k].id == id:
			return k
	return 0

## Spawn one enemy of `id` at `at`, already arriving.
func _arriving_at(r: Node2D, id: StringName, at: Vector2) -> int:
	var ti := _type_index(r, id)
	var i: int = r.enemies.spawn(at, Vector2.ZERO, 500.0, 26.0, ti)
	r._spawn_enemy_state(i, 500.0, r.enemy_types[ti].behaviour)
	r._arriving[i] = r.ARRIVAL_TOTAL
	return i

func an_arrival_is_out_of_the_grid() -> void:
	var r := await _bare_run()
	var i := _arriving_at(r, &"kernel_panic", r.player_pos[r.local_slot] + Vector2(120, 0))
	r._step3_rebuild()
	_check("the union marks it skipped", r._no_grid[i], 1)
	# Nothing the player fires can find it.
	_check("and it cannot be targeted",
		r._pick_target(4000.0, Module.Targeting.NEAREST, r.player_pos[r.local_slot]), -1)
	r._arriving[i] = 0.0
	r._step3_rebuild()
	_check("once live it is targetable again",
		r._pick_target(4000.0, Module.Targeting.NEAREST, r.player_pos[r.local_slot]), i)
	# The union must be REBUILT, not OR-ed: an incremental union never clears.
	_check("and the union cleared", r._no_grid[i], 0)
	r.free()
	await process_frame
	finished["an_arrival_is_out_of_the_grid"] = true

## _behave lives in _step2_integrate, not _step4_steer. ICE is CHASE, so an
## ungated arrival would walk off its own telegraph.
func an_arrival_does_not_move() -> void:
	var r := await _bare_run()
	var i := _arriving_at(r, &"sentinel_array", r.player_pos[r.local_slot] + Vector2(400, 0))
	var before: Vector2 = r.enemies.pos[i]
	for k in 20:
		r._physics_process(DT)
	_check("an arriving boss holds its position", r.enemies.pos[i], before)
	_check("and its velocity stays zero", r.enemies.vel[i], Vector2.ZERO)
	_check("while the timer runs down", r._arriving[i] < r.ARRIVAL_TOTAL, true)
	r.free()
	await process_frame
	finished["an_arrival_does_not_move"] = true

## _pulse calls _damage_player DIRECTLY on a line-of-sight check, with no grid
## involved at all — so "out of the grid" does not cover it and only gating
## _behave does. kernel_panic is both a mini-boss and the pulsing type.
func a_pulse_arrival_cannot_touch_the_player() -> void:
	var r := await _bare_run()
	_arriving_at(r, &"kernel_panic", r.player_pos[r.local_slot] + Vector2(60, 0))
	var hp: float = r.player_health[r.local_slot]
	for k in 40:
		r._physics_process(DT)
	_check("the player is untouched through the entrance",
		r.player_health[r.local_slot], hp)
	_check("and no hostile shot was spawned", r.hostiles.count, 0)
	r.free()
	await process_frame
	finished["a_pulse_arrival_cannot_touch_the_player"] = true

## _step2b_zones walks enemies.count by index and never consulted the skip. On
## clean terrain this case passes regardless, so the tiles are planted first.
func hazard_and_corruption_are_held_off() -> void:
	var r := await _bare_run()
	var at: Vector2 = r.player_pos[r.local_slot] + Vector2(200, 0)
	r.terrain.add_temp_zone(at, 90.0, Terrain.Kind.HAZARD, 99.0)
	var i := _arriving_at(r, &"sentinel_array", at)
	var hp: float = r.enemies.integrity[i]
	var corr: float = r.enemies.corruption[i]
	for k in 30:
		r._physics_process(DT)
	_check("a hazard tile does not damage an arrival",
		r.enemies.integrity[i], hp)
	_check("and corruption does not accumulate",
		r.enemies.corruption[i], corr)
	_check("so it cannot flip mid-entrance",
		r.enemies.state[i], Population.ALIVE)
	r.free()
	await process_frame
	finished["hazard_and_corruption_are_held_off"] = true

func it_becomes_live_when_the_timer_ends() -> void:
	var r := await _bare_run()
	var i := _arriving_at(r, &"kernel_panic", r.player_pos[r.local_slot] + Vector2(150, 0))
	var ticks := int(r.ARRIVAL_TOTAL / DT) + 4
	for k in ticks:
		r._physics_process(DT)
	_check("the arrival finished", r.is_arriving(i), false)
	r._step3_rebuild()
	_check("and it rejoins the grid", r._no_grid[i], 0)
	r.free()
	await process_frame
	finished["it_becomes_live_when_the_timer_ends"] = true

## Population.despawn swap-removes the tail into the freed slot, and a mini-boss
## spawns AT the tail. Without relocation its timer is left behind — it
## materialises instantly and hittable — while the enemy that inherits the slot
## goes invulnerable and invisible.
func the_timer_survives_recycle_compaction() -> void:
	var r := await _bare_run()
	var grunt: int = r.enemies.spawn(r.player_pos[r.local_slot] + Vector2(80, 0),
		Vector2.ZERO, 10.0, 20.0, 0)
	r._spawn_enemy_state(grunt, 10.0)
	var boss := _arriving_at(r, &"kernel_panic", r.player_pos[r.local_slot] + Vector2(300, 0))
	_check("the boss is at the tail", boss, r.enemies.count - 1)

	# Kill the LOWER-indexed enemy so the tail compacts down over it.
	r.enemies.integrity[grunt] = 0.0
	r.enemies.state[grunt] = Population.DEAD
	r._step9_recycle()
	_check("the pool compacted", r.enemies.count, 1)
	_check("the arrival timer followed the boss", r._arriving[0] > 0.0, true)
	_check("and it is still the boss in that slot",
		r.enemy_types[r.enemies.type_index[0]].id, &"kernel_panic")
	r.free()
	await process_frame
	finished["the_timer_survives_recycle_compaction"] = true

## The SECOND despawn site. _step2d_collapse's is_void predicate is conditional,
## so reverse iteration does not make it tail-only — and it relocated nothing at
## all before this pass.
## The SECOND despawn site, and any future third.
##
## _step9_recycle is covered above by driving it. _step2d_collapse cannot be
## driven the same way — collapse_to() rebuilds `voided` wholesale on every
## call, so a hand-marked cell never survives to the despawn — and a test that
## voided the whole arena would remove the boss too and prove nothing.
##
## So this asserts the rule rather than one instance of it: EVERY
## `enemies.despawn(...)` in run.gd is immediately preceded by a
## `_relocate_enemy(...)`. That is the invariant a third despawn site would
## break, and it is exactly how _step2d_collapse came to relocate nothing at all
## while the recycle site had relocated eight arrays for months.
func the_timer_survives_collapse_compaction() -> void:
	var f := FileAccess.open("res://scripts/run/run.gd", FileAccess.READ)
	_check("run.gd is readable", f != null, true)
	if f == null:
		finished["the_timer_survives_collapse_compaction"] = true
		return
	var lines := f.get_as_text().split("\n")
	f.close()

	var sites := 0
	var unguarded := []
	for i in lines.size():
		if not lines[i].contains("enemies.despawn("):
			continue
		# A tail-down FULL drain — `for k in range(enemies.count - 1, -1, -1)`
		# with no predicate, or a `while enemies.count > 0` purge — removes the
		# tail every time, so relocation there is a self-assignment. Only a
		# despawn that can take a MIDDLE slot needs the guard, which is exactly
		# what makes _step2d_collapse's conditional predicate different from
		# these.
		var tail_drain := lines[i].contains("enemies.count - 1")
		for back in range(1, 4):
			if i - back < 0:
				break
			var prev := lines[i - back]
			if prev.contains("while enemies.count > 0"):
				tail_drain = true
				break
			if prev.contains("range(enemies.count - 1, -1, -1)") \
					and not prev.contains("if "):
				# Unconditional only: _step2d_collapse iterates the same way but
				# despawns on an is_void predicate, so it is NOT a tail drain.
				var has_predicate := false
				for fwd in range(1, back):
					if lines[i - back + fwd].strip_edges().begins_with("if "):
						has_predicate = true
				tail_drain = not has_predicate
				break
		if tail_drain:
			continue
		sites += 1
		var guarded := false
		for back in range(1, 6):
			if i - back < 0:
				break
			if lines[i - back].contains("_relocate_enemy("):
				guarded = true
				break
		if not guarded:
			unguarded.append("run.gd:%d" % (i + 1))

	_check("there are middle-of-pool despawn sites to check", sites >= 2, true)
	_check("every one of them relocates first", unguarded, [])
	finished["the_timer_survives_collapse_compaction"] = true
