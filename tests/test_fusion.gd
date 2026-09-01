extends SceneTree

## Fusion: the fused head, the recipes, and the mechanics they run on.

const EXPECTED_CHECKS := 25

var failures := 0
var checks := 0
var T := ModuleTable.by_id()

## _initialize, not _init: the recycle case stands up a real run and awaits a
## frame, and an un-awaited coroutine under _init returns immediately — the
## suite would print PASS and quit before the assertion ever ran.
func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — fusion\n")
	await process_frame
	a_fused_row_fires_with_no_trigger()
	targeting_comes_from_the_head_only()
	split_count_folds_like_pierce()
	blast_radius_ranks_at_quarter_rate()
	execute_below_folds_by_max_and_clamps()
	homing_sums_and_clamps()
	await recycling_carries_every_parallel_array()
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

## The same helper tests/test_build.gd carries. Repeated rather than shared
## because each suite here is a standalone SceneTree script with no common base.
func _mk(vector_id: StringName, trigger_id: StringName, payloads: Array = []) -> Exploit:
	var ex := Exploit.new()
	if vector_id != &"": ex.place(T[vector_id])
	if trigger_id != &"": ex.place(T[trigger_id])
	for p in payloads: ex.place(T[p])
	return ex

## A fused module carries its own vector_kind AND trigger_kind, so the row is
## not inert with the trigger column empty — that is what absorbing it means.
func _fused_probe() -> Module:
	var m := Module.make(&"probe_fuse", "probe_fuse()", Module.Slot.VECTOR,
		{&"damage": 20.0, &"radius": 200.0, &"cooldown": 0.6}, [],
		Module.VectorKind.BROADCAST, Module.TriggerKind.ON_KILL)
	m.is_fused = true
	return m

func a_fused_row_fires_with_no_trigger() -> void:
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(_fused_probe())
	_check("a fused row is not inert", ex.is_inert(), false)
	_check("slot 0 is the fused module", ex.at(0).module.id, &"probe_fuse")
	_check("the head reads as fused", ex.head_is_fused(), true)
	_check("the trigger column is empty", ex.at(1), null)

	var r := Compiler.build(ex)
	_check("the kind comes from the head", r.vector_kind,
		Module.VectorKind.BROADCAST)
	_check("so does the trigger kind", r.trigger_kind,
		Module.TriggerKind.ON_KILL)
	_check("and the resolve is not inert", r.inert, false)

	# Scoped to THE FUSED ROW. legal_targets loops `for e in MAX_EXPLOITS` and
	# offers EMPTY_SLOT on not-yet-created exploits, so a total count here would
	# be asserting something about rows 1 and 2.
	var lo := Loadout.new()
	lo.exploits = [ex]
	var trig := 0
	var pay := 0
	for t in lo.legal_targets(T[&"on_hit"]):
		if t.exploit == 0: trig += 1
	for t in lo.legal_targets(T[&"corrupt"]):
		if t.exploit == 0: pay += 1
	_check("no trigger card targets the fused row", trig, 0)
	_check("but its payload slot is still open", pay, 1)


## targeting is read ONLY from the vector slot, exactly as the kinds are. A
## payload's default enum value folding in would silently pull every fused
## sniper back to NEAREST.
func targeting_comes_from_the_head_only() -> void:
	var m := _fused_probe()
	m.targeting = Module.Targeting.STRONGEST
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(m)
	ex.place(T[&"keylog"])              # a payload at default NEAREST
	var r := Compiler.build(ex)
	_check("the head's targeting survives the payload fold", r.targeting,
		Module.Targeting.STRONGEST)

	var plain := Exploit.new()
	plain.place(T[&"packet"]); plain.place(T[&"interval"])
	_check("an ordinary exploit defaults to NEAREST",
		Compiler.build(plain).targeting, Module.Targeting.NEAREST)
	_check("and NEAREST is enum zero", Module.Targeting.NEAREST, 0)


## Zero means one, following `burst`, so no caller special-cases a default.
## And it folds as a float and floors ONCE, like pierce: two halves make one.
func split_count_folds_like_pierce() -> void:
	var a := Module.make(&"sc_a", "a", Module.Slot.PAYLOAD, {&"split_count": 0.5})
	var b := Module.make(&"sc_b", "b", Module.Slot.TRIGGER, {&"split_count": 0.5})
	var ex := Exploit.new()
	ex.place(T[&"packet"]); ex.place(a); ex.place(b)
	var r := Compiler.build(ex)
	_check("two halves make one split", r.split_count, 1)

	var plain := Exploit.new()
	plain.place(T[&"packet"]); plain.place(T[&"interval"])
	_check("and the default is zero, meaning one emission",
		Compiler.build(plain).split_count, 0)


## blast_radius shares `radius`'s rank carve-out: a rank-5 blast covering the
## screen is a module whose whole cost was showing up five times.
func blast_radius_ranks_at_quarter_rate() -> void:
	var v := Module.make(&"br_v", "br", Module.Slot.VECTOR,
		{&"damage": 6.0, &"cooldown": 0.5, &"blast_radius": 100.0}, [],
		Module.VectorKind.PACKET)
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(v, 5)
	ex.place(T[&"interval"])
	_check("rank 5 doubles it, not quintuples it",
		Compiler.build(ex).blast_radius, 200.0)

	var r1 := Exploit.new()
	r1.vector = EquippedModule.new(v, 1)
	r1.place(T[&"interval"])
	_check("rank 1 is the base", Compiler.build(r1).blast_radius, 100.0)


## A fraction, so it folds by MAX. Two sources summing to 0.5 is not "a bit
## more execute", it is a different game.
func execute_below_folds_by_max_and_clamps() -> void:
	var a := Module.make(&"ex_a", "a", Module.Slot.VECTOR,
		{&"damage": 5.0, &"cooldown": 0.5, &"execute_below": 0.20}, [],
		Module.VectorKind.CONE)
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(a, 1)
	ex.place(T[&"interval"])
	_check("a single source is itself", Compiler.build(ex).execute_below, 0.20)

	# Rank scales it like any other stat, and the clamp is what stops rank 5
	# turning an 18% threshold into a 90% one.
	var hi := Exploit.new()
	hi.vector = EquippedModule.new(a, 5)
	hi.place(T[&"interval"])
	_check("and it clamps at a half", Compiler.build(hi).execute_below, 0.5)

	# It is a VECTOR-only stat, for the reason cooldown is.
	var bad := Module.make(&"ex_bad", "bad", Module.Slot.PAYLOAD,
		{&"execute_below": 0.2})
	_check("a payload carrying it is rejected",
		Compiler.validate(bad).size() > 0, true)


## Unclamped, homing converges on instant tracking — which is a hitscan with
## extra steps, and the turn rate exists to prevent exactly that.
func homing_sums_and_clamps() -> void:
	var v := Module.make(&"hm_v", "hm", Module.Slot.VECTOR,
		{&"damage": 6.0, &"cooldown": 0.5, &"homing": 2.0}, [],
		Module.VectorKind.PACKET)
	var ex := Exploit.new()
	ex.vector = EquippedModule.new(v, 5)
	ex.place(T[&"interval"])
	_check("it clamps at the max turn rate",
		Compiler.build(ex).homing, Compiler.MAX_HOMING)

	var bad := Module.make(&"hm_bad", "bad", Module.Slot.PAYLOAD, {&"homing": 1.0})
	_check("a payload carrying it is rejected",
		Compiler.validate(bad).size() > 0, true)


## Population.despawn swap-removes the tail into the freed slot, so every
## parallel array has to move with it. The comment above _step9_recycle says
## exactly that; the code copied four of nine. A surviving projectile inheriting
## a dead one's target homes at the wrong enemy, and one inheriting a dead one's
## fuse stops being a mine.
func recycling_carries_every_parallel_array() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.phase = run.Phase.CLEARED
	run.collapse_left = run.COLLAPSE_SECONDS
	while run.projectiles.count > 0:
		run.projectiles.despawn(run.projectiles.count - 1)

	for k in 3:
		var pi: int = run.projectiles.spawn(run.player_pos + Vector2(k * 40, 0),
			Vector2.ZERO, 1.0, run.PROJECTILE_RADIUS, 0)
		run._proj_owner[pi] = k
		run._proj_target[pi] = 100 + k
		run._proj_target_gen[pi] = 200 + k
		run._mine_left[pi] = float(k + 1)
		run._proj_reacquire[pi] = 0.0
	# Kill the MIDDLE one: the tail (index 2) swaps down into index 1.
	run.projectiles.state[1] = Population.DEAD
	run._step9_recycle()

	_check("the survivor keeps its own owner", run._proj_owner[1], 2)
	_check("and its own bound target", run._proj_target[1], 102)
	_check("and that target's generation", run._proj_target_gen[1], 202)
	_check("and its own fuse", run._mine_left[1], 3.0)
	run.queue_free()
	await process_frame
