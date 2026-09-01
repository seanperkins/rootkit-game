extends SceneTree

## Pins the two rules that revision 2 and revision 3 each got wrong.
##
## Order-independence is not provable by one construction: the review found the
## revision-2 test could pass while the contradiction shipped, because it only
## built one of the two event orders. Every case here runs BOTH orders, and the
## cross-pass cases run both pass orders.

const THRESH := 10.0
var failures := 0

## _initialize, not _init: one case stands up a real run and awaits a frame, and
## an un-awaited coroutine under _init returns immediately — the suite would
## print PASS and quit before the assertion ever ran.
func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — drain / adjudication semantics\n")
	await process_frame
	case_within_pass_damage_then_corruption()
	case_within_pass_corruption_then_damage()
	case_cross_pass_death_then_corruption()
	case_cross_pass_flip_then_damage()
	case_on_hit_fires_on_surviving_target()
	case_stale_generation_rejected()
	await a_step_two_detonation_reaches_the_drain()
	environment_corruption_flips_rather_than_kills()
	execute_finishes_the_weak_and_spares_a_boss()
	print("")
	if failures == 0:
		print("  PASS — all 9 cases")
	else:
		print("  FAIL — %d case(s)" % failures)
	quit(1 if failures > 0 else 0)

func _fixture() -> Array:
	var pop := Population.new(16)
	var i := pop.spawn(Vector2.ZERO, Vector2.ZERO, 5.0, 12.0, 0)
	var q := HitQueue.new(64, 16)
	q.begin_tick()
	var th := PackedFloat32Array([THRESH])
	return [pop, q, i, th]

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

## Lethal damage and threshold corruption in the SAME pass: flip wins, and the
## result must not depend on which drained first.
func case_within_pass_damage_then_corruption() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	q.append(HitQueue.Kind.DAMAGE, 0, i, pop.generation[i], 10.0)
	q.append(HitQueue.Kind.CORRUPTION, 1, i, pop.generation[i], 10.0)
	q.drain_pass(pop, f[3])
	_check("within-pass, damage first  -> FLIPPED", q.outcome[i], HitQueue.Outcome.FLIPPED)
	_check("within-pass, damage first  -> flipper is exploit 1", q.flipper_exploit[i], 1)

func case_within_pass_corruption_then_damage() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	q.append(HitQueue.Kind.CORRUPTION, 1, i, pop.generation[i], 10.0)
	q.append(HitQueue.Kind.DAMAGE, 0, i, pop.generation[i], 10.0)
	q.drain_pass(pop, f[3])
	_check("within-pass, corruption first -> FLIPPED", q.outcome[i], HitQueue.Outcome.FLIPPED)

## Adjudicated dead in pass 1; corruption arrives in pass 2. The entity is
## CLOSED, so it stays dead. Without the closed rule this either double-resolves
## or makes the outcome depend on the pass boundary.
func case_cross_pass_death_then_corruption() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	q.append(HitQueue.Kind.DAMAGE, 0, i, pop.generation[i], 10.0)
	var r1 := q.drain_pass(pop, f[3])
	_check("cross-pass, pass 1 resolves 1 entity", r1, 1)
	_check("cross-pass, pass 1 -> DEAD", q.outcome[i], HitQueue.Outcome.DEAD)
	q.append(HitQueue.Kind.CORRUPTION, 1, i, pop.generation[i], 99.0)
	var r2 := q.drain_pass(pop, f[3])
	_check("cross-pass, pass 2 resolves nothing", r2, 0)
	_check("cross-pass, stays DEAD (closed)", q.outcome[i], HitQueue.Outcome.DEAD)

func case_cross_pass_flip_then_damage() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	q.append(HitQueue.Kind.CORRUPTION, 1, i, pop.generation[i], 10.0)
	q.drain_pass(pop, f[3])
	_check("cross-pass, pass 1 -> FLIPPED", q.outcome[i], HitQueue.Outcome.FLIPPED)
	q.append(HitQueue.Kind.DAMAGE, 0, i, pop.generation[i], 999.0)
	q.drain_pass(pop, f[3])
	_check("cross-pass, stays FLIPPED (closed)", q.outcome[i], HitQueue.Outcome.FLIPPED)

## ON_HIT must fire for a hit the target SURVIVES. Revision 3 fired it from a
## loop over terminally-marked entities, so it only fired on kills — which made
## the cascade it was budgeted for impossible.
func case_on_hit_fires_on_surviving_target() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	q.append(HitQueue.Kind.DAMAGE, 2, i, pop.generation[i], 1.0)
	q.drain_pass(pop, f[3])
	_check("on_hit fires on a surviving target", q.hit_count, 1)
	_check("on_hit attributed to owning exploit", q.hit_exploit[0], 2)
	_check("survivor not adjudicated", q.outcome[i], HitQueue.Outcome.NONE)

## An event carrying a generation the slot no longer has is dropped.
func case_stale_generation_rejected() -> void:
	var f := _fixture(); var pop: Population = f[0]; var q: HitQueue = f[1]; var i: int = f[2]
	var stale := pop.generation[i] - 1
	q.append(HitQueue.Kind.DAMAGE, 0, i, stale, 999.0)
	q.drain_pass(pop, f[3])
	_check("stale-generation event rejected", pop.integrity[i], 5.0)


## A mine inside its fuse radius must actually reduce integrity. This is an
## END-TO-END tick test on purpose: the bug it pins is not in the queue or in
## the detonation, but in the ORDER the two run in, so nothing short of a real
## _physics_process can see it.
func a_step_two_detonation_reaches_the_drain() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	# CLEARED stops _step1_spawn while leaving _step2_integrate running, which is
	# all this test needs — a live director lets a watchdog heal the probe back
	# up and flake the assertion.
	run.phase = run.Phase.CLEARED
	# CLEARED without this voids the arena on tick 1: collapse_left defaults to
	# 0.0 and is set only on the real clear transition, so _step2d_collapse
	# computes frac 0.0, calls collapse_to(0), and every cell but the gate goes —
	# the player dies and the probe is despawned before the fuse is ever measured.
	run.collapse_left = run.COLLAPSE_SECONDS
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)

	# The mine's owner must be an exploit whose RESOLVE HAS A RADIUS.
	# _detonate blasts with `r.radius`, and exploit 0 in a fresh run is
	# packet + interval — packet carries no radius at all, so a zero-radius query
	# would hit nothing and this test would fail identically before and after.
	run.loadout.place_at(ModuleTable.by_id()[&"landmine"], 1, 0)
	run.loadout.place_at(ModuleTable.by_id()[&"interval"], 1, 1)
	run._recompile()

	# Blank terrain zones under the probe. Once this fix lands, a HAZARD or
	# CORRUPTION cell under the enemy damages it through the ZONE path, and the
	# assertion would pass or fail on the terrain seed rather than on the fuse.
	run.terrain.zone.fill(0)
	run.terrain.clear_temp_zones()

	var at: Vector2 = run.player_pos + Vector2(200.0, 0.0)
	var e: int = run.enemies.spawn(at, Vector2.ZERO, 50.0, run.ENEMY_RADIUS, 0)
	# A mine 30 px away: inside MINE_TRIGGER (46) and outside the step-6
	# projectile-contact radius (PROJECTILE_RADIUS + ENEMY_RADIUS = 16), so the
	# ONLY path that can damage it is the fuse. landmine's 16 damage leaves the
	# enemy alive at 34, so no swap-remove can alias index `e`.
	var mi: int = run.projectiles.spawn(at + Vector2(30.0, 0.0), Vector2.ZERO,
		1.0, run.PROJECTILE_RADIUS, 0)
	run._proj_owner[mi] = 1
	run._proj_pierce[mi] = 0
	run._proj_last[mi] = -1
	run._proj_dist_left[mi] = 1.0
	run._mine_left[mi] = run.MINE_LIFE
	run._orbit_left[mi] = 0.0
	var before: float = run.enemies.integrity[e]
	for i in 5:
		run._physics_process(1.0 / 60.0)
	_check("a fuse-range mine reduces integrity",
		run.enemies.integrity[e] < before, true)
	run.queue_free()
	await process_frame

## Corruption from the ENVIRONMENT (source -1) must flip, not kill. -1 was both
## "no flip happened" and "the terrain did it", and the collision was invisible
## while the zone path was dead code.
func environment_corruption_flips_rather_than_kills() -> void:
	var pop := Population.new(4)
	var th := PackedFloat32Array([10.0])
	var q := HitQueue.new(8, 4)
	var i := pop.spawn(Vector2.ZERO, Vector2.ZERO, 50.0, 12.0, 0)
	q.begin_tick()
	q.append(HitQueue.Kind.CORRUPTION, -1, i, pop.generation[i], 12.0)
	q.drain_pass(pop, th)
	_check("an unowned corruption crossing flips", pop.state[i],
		Population.FLIPPED)
	_check("and records the environment as the flipper",
		q.flipper_exploit[i], -1)


## The execute marks in the same adjudication, and minibosses are exempt.
func execute_finishes_the_weak_and_spares_a_boss() -> void:
	var pop := Population.new(8)
	var th := PackedFloat32Array([999.0, 999.0])
	var max_hp := PackedFloat32Array([100.0, 100.0])
	var execute := PackedFloat32Array([0.25])       # exploit 0
	var immune := PackedByteArray([0, 1])           # type 1 is a miniboss
	var q := HitQueue.new(16, 8)

	var a := pop.spawn(Vector2.ZERO, Vector2.ZERO, 100.0, 12.0, 0)
	var b := pop.spawn(Vector2.ZERO, Vector2.ZERO, 100.0, 12.0, 1)
	q.begin_tick()
	q.append(HitQueue.Kind.DAMAGE, 0, a, pop.generation[a], 80.0)
	q.append(HitQueue.Kind.DAMAGE, 0, b, pop.generation[b], 80.0)
	q.drain_pass(pop, th, max_hp, execute, immune)
	_check("20 of 100 left is under the threshold: dead",
		pop.state[a], Population.DEAD)
	_check("a miniboss at the same fraction survives",
		pop.state[b], Population.ALIVE)
