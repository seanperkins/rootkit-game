extends SceneTree

## Wards arm a per-exploit timer when the exploit fires. While the timer is live,
## that exploit's ward_* values count toward the player's effective stats — as a
## MAX across exploits, never a sum.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — wards\n")
	await process_frame
	await arms_and_decays()
	await targetless_beam_still_wards()
	await max_across_exploits()
	await ward_moves_the_player()
	await absorbs_its_own_hit()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _bare_run() -> Node2D:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	return run

## Placed straight from the table rather than through unlocked_modules(): unlock
## state is derived from milestone counters and only gates the card OFFER pool,
## never what a build may contain. test_triggers.gd does the same.
func _with(run: Node2D, vector_id: StringName, trigger_id: StringName,
		payloads: Array) -> int:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[vector_id]); ex.place(t[trigger_id])
	for p in payloads:
		ex.place(t[p])
	run.loadouts[run.local_slot].exploits.append(ex)
	run._recompile()
	return run._gid(run.local_slot, run.loadouts[run.local_slot].exploits.size() - 1)

func arms_and_decays() -> void:
	var run := await _bare_run()
	var idx := _with(run, &"broadcast", &"interval", [&"sandbox"])
	var mag: float = run.resolved[idx].ward_defense
	var dur: float = run.resolved[idx].ward_duration

	for tick in 120:
		run._physics_process(DT)
	_check("firing arms the ward", run._eff_defense(run.local_slot), mag)

	# Stop it re-arming, then let the live timer run out. Zeroing the duration
	# rather than the timer is what makes this a decay test rather than a
	# assignment test.
	run.resolved[idx].ward_duration = 0.0
	for tick in int((dur + 1.0) / DT):
		run._physics_process(DT)
	_check("an expired ward contributes nothing", run._eff_defense(run.local_slot), 0.0)
	run.queue_free()
	await process_frame

## Wards apply at the TOP of _emit_vector, before the match, so a BEAM fired
## into empty ground still hardens. It spends its cooldown either way — _try_event_fire sets _fire_cd before calling _emit_vector — so
## the placement buys the ward, not the cadence.
func targetless_beam_still_wards() -> void:
	var run := await _bare_run()
	_with(run, &"beam", &"interval", [&"harden"])
	for tick in 120:
		run._physics_process(DT)
	_check("targetless beam still wards", run._eff_armor(run.local_slot) > 0.0, true)
	run.queue_free()
	await process_frame

## Two exploits carrying the same ward take the MAX, never the sum.
func max_across_exploits() -> void:
	var run := await _bare_run()
	var a := _with(run, &"broadcast", &"interval", [&"sandbox"])
	_with(run, &"chain", &"interval", [&"sandbox"])
	var mag: float = run.resolved[a].ward_defense
	for tick in 120:
		run._physics_process(DT)
	_check("two exploits take the max, not the sum", run._eff_defense(run.local_slot), mag)
	run.queue_free()
	await process_frame

## ward_clock_speed must actually reach the move step. bus_speed (the meta path)
## and nice (the ward path) are two different sources into the same read, and
## both need their own assertion.
func ward_moves_the_player() -> void:
	# Ranked to 5 on purpose. At rank 1 nice is +12 against a base of 220 — a
	# 5.45% change even at full uptime — which no distance assertion can
	# distinguish from noise over a short window. Rank 5 is +60, matching a
	# maxed bus_speed line, and that is measurable.
	var run := await _bare_run()
	var idx := _with(run, &"broadcast", &"interval", [&"nice"])
	var ex: Exploit = run.loadouts[run.local_slot].exploits[run.loadouts[run.local_slot].exploits.size() - 1]
	ex.payloads[0].rank = 5
	run._recompile()
	var base: float = run._sheet[run.local_slot][&"clock_speed"]

	# Open ground, so this measures the ward and not what the generator rolled.
	# The player covers about 840 units here; a wall anywhere along that line
	# stops them dead and the case fails saying nothing about wards.
	run.terrain.solid.fill(0)

	run.input_override = Vector2.RIGHT
	var start: Vector2 = run.player_pos[run.local_slot]
	for tick in 180:
		run._physics_process(DT)
	var warded: float = run.player_pos[run.local_slot].distance_to(start)

	_check("nice r5 raises effective clock speed", run._eff_clock_speed(run.local_slot), base + 60.0)
	# The ward is down for the first cooldown, so the average sits between the
	# base and the warded speed rather than at either end.
	_check("nice moves the player farther than base speed",
		warded > base * 3.0 * 1.05, true)
	run.queue_free()
	await process_frame

## The reorder's whole point: ON_DAMAGE_TAKEN triggers fire BEFORE the damage is
## subtracted, so the ward is up for the hit that summoned it rather than the
## next one.
func absorbs_its_own_hit() -> void:
	var run := await _bare_run()
	_with(run, &"broadcast", &"on_damage_taken", [&"harden"])
	var before: float = run.player_health[run.local_slot]
	run._damage_player(run.local_slot, 10.0)
	var loss: float = before - run.player_health[run.local_slot]
	_check("a ward reduces its own triggering hit", loss < 10.0, true)
	_check("the hit is not fully negated", loss > 0.0, true)
	run.queue_free()
	await process_frame
