extends SceneTree

## travel is the ONLY lifetime bound on a projectile. The old 1600-unit test was
## measured from the PLAYER, so a fleeing player could push a legal max-reach
## packet past it and make reach silently inert exactly when you run away.
## Keeping both bounds is what broke an earlier revision of the design.

const DT := 1.0 / 60.0

## Every assertion this file is supposed to make. A GDScript runtime error aborts
## the enclosing function without failing the suite, so a file whose _check calls
## never execute reports PASS while testing nothing — the exact blindness that
## hid the save_game.gd:168 bug. Counting the checks makes that loud.
const EXPECTED_CHECKS := 8

var failures := 0
var checks := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — packet travel\n")
	await process_frame
	travel_outranges_acquisition()
	await expires_at_travel_distance()
	await player_distance_no_longer_culls()
	await expired_projectile_lands_no_hit()
	await swap_remove_carries_distance()
	print("")
	if checks != EXPECTED_CHECKS:
		print("  FAIL — ran %d checks, expected %d (a function aborted early)"
			% [checks, EXPECTED_CHECKS])
		failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	checks += 1
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
	while run.projectiles.count > 0:
		run.projectiles.despawn(run.projectiles.count - 1)
	# Silence the starting exploit. A PACKET with no target still spawns, aimed
	# at Vector2.RIGHT, so a run left armed keeps replenishing the pool and any
	# "how long did this projectile live" measurement never terminates.
	run.loadouts[run.local_slot].exploits.clear()
	run._recompile()
	return run

## Packets acquire targets within VIEW_RANGE, so a travel shorter than that would
## make them fall short of targets they are allowed to shoot at — the inert-stat
## bug in a new place.
func travel_outranges_acquisition() -> void:
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	var r := Compiler.build(ex)
	_check("base travel outranges target acquisition", r.travel > 620.0, true)
	_check("max travel stays well under the old 1600 bound",
		Compiler.build(ex, {&"reach": 1.30}).travel < 1600.0, true)

## The projectile dies at its travel distance and not before.
func expires_at_travel_distance() -> void:
	var run := await _bare_run()
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"packet"]); ex.place(t[&"interval"])
	var r := Compiler.build(ex)
	var expected_ticks: int = int(r.travel / r.projectile_speed / DT)

	var pi: int = run.projectiles.spawn(run.player_pos[run.local_slot],
		Vector2.RIGHT * r.projectile_speed, 1.0, run.PROJECTILE_RADIUS, 0)
	run._proj_owner[pi] = 0
	run._proj_pierce[pi] = 0
	run._proj_last[pi] = -1
	run._proj_dist_left[pi] = r.travel

	var lived := 0
	for tick in expected_ticks * 3:
		run._physics_process(DT)
		if run.projectiles.count == 0:
			break
		lived += 1
	_check("packet survives most of its travel", lived > expected_ticks - 5, true)
	_check("packet does not outlive its travel", lived < expected_ticks + 5, true)
	run.queue_free()
	await process_frame

## The decisive test for the cull replacement: teleport the player far beyond the
## old 1600-unit bound and the projectile must survive, because distance from the
## player is no longer what kills it.
func player_distance_no_longer_culls() -> void:
	var run := await _bare_run()
	var pi: int = run.projectiles.spawn(run.player_pos[run.local_slot], Vector2.RIGHT * 420.0,
		1.0, run.PROJECTILE_RADIUS, 0)
	run._proj_owner[pi] = 0
	run._proj_pierce[pi] = 0
	run._proj_last[pi] = -1
	run._proj_dist_left[pi] = 640.0

	run.player_pos[run.local_slot] += Vector2(3000.0, 0.0)
	run._physics_process(DT)
	_check("distance from the player no longer culls a projectile",
		run.projectiles.count, 1)
	run.queue_free()
	await process_frame

## Travel expiry marks a projectile dead in step 2, so a dead projectile reaches
## _step6_detect for the first time. Without the state guard it still lands a hit
## on its expiry tick.
func expired_projectile_lands_no_hit() -> void:
	var run := await _bare_run()
	var target: int = run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(200.0, 0.0),
		Vector2.ZERO, 99999.0, run.ENEMY_RADIUS, 0)
	var hp_before: float = run.enemies.integrity[target]

	# Stranded exactly on top of the enemy with nothing left to fly.
	var pi: int = run.projectiles.spawn(run.enemies.pos[target], Vector2.ZERO,
		1.0, run.PROJECTILE_RADIUS, 0)
	run._proj_owner[pi] = 0
	run._proj_pierce[pi] = 9999
	run._proj_last[pi] = -1
	run._proj_dist_left[pi] = 0.0

	run._physics_process(DT)
	_check("an expired projectile lands no hit",
		run.enemies.integrity[target] >= hp_before, true)
	run.queue_free()
	await process_frame

## Population.despawn swap-removes the tail into slot i, so every parallel array
## must move with it. The codebase already lost this bug once for _proj_owner.
func swap_remove_carries_distance() -> void:
	var run := await _bare_run()
	# Zero velocity so no distance is consumed and the numbers stay exact.
	var a: int = run.projectiles.spawn(run.player_pos[run.local_slot], Vector2.ZERO, 1.0,
		run.PROJECTILE_RADIUS, 0)
	run._proj_owner[a] = 0; run._proj_pierce[a] = 0; run._proj_last[a] = -1
	run._proj_dist_left[a] = 100.0
	var b: int = run.projectiles.spawn(run.player_pos[run.local_slot] + Vector2(50.0, 0.0),
		Vector2.ZERO, 1.0, run.PROJECTILE_RADIUS, 0)
	run._proj_owner[b] = 1; run._proj_pierce[b] = 0; run._proj_last[b] = -1
	run._proj_dist_left[b] = 900.0

	# Kill the head; the tail swaps down into its slot.
	run.projectiles.state[a] = Population.DEAD
	run._physics_process(DT)

	_check("one projectile survives the recycle", run.projectiles.count, 1)
	_check("the survivor kept its own remaining distance",
		run._proj_dist_left[0], 900.0)
	run.queue_free()
	await process_frame
