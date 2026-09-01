extends SceneTree

## Fusion: the fused head, the recipes, and the mechanics they run on.

const EXPECTED_CHECKS := 60

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
	the_recipes_are_present_and_valid()
	an_exact_triple_matches_and_one_module_off_does_not()
	fusing_frees_the_ids_and_keeps_the_metronome()
	a_refused_fusion_leaves_the_row_untouched()
	fusing_may_not_orphan_the_loadout()
	a_fused_module_is_drawable_only_once_held()
	fusion_demands_three_finished_modules()
	fusing_is_never_a_downgrade()
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

## Fusion needs all three at max rank, so every fusion fixture goes through this.
func _maxed(ex: Exploit) -> Exploit:
	for em in ex.equipped():
		em.rank = em.module.max_rank
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


## The table is data, and every number in it has to survive the same validator
## the module table does. A fused module is a VECTOR, so the cooldown floor and
## the cadence_mult ban both apply to it.
func the_recipes_are_present_and_valid() -> void:
	var rs: Array = RecipeTable.all()
	_check("twenty recipes", rs.size(), 20)
	_check("syn_flood is deliberately near the cooldown floor",
		float(RecipeTable.by_fused_id()[&"syn_flood"].fused.stats[&"cooldown"]), 0.42)

	var ids := {}
	var triples := {}
	var mods := ModuleTable.by_id()
	var errs := 0
	var min_cd := Compiler.MIN_COOLDOWN / Compiler.MIN_CADENCE_FRACTION
	for r in rs:
		ids[r.fused.id] = true
		triples["%s|%s|%s" % [r.vector_id, r.trigger_id, r.payload_id]] = true
		errs += Compiler.validate(r.fused).size()
		if not (mods.has(r.vector_id) and mods.has(r.trigger_id)
				and mods.has(r.payload_id)):
			errs += 1
		if float(r.fused.stats.get(&"cooldown", 0.0)) < min_cd:
			errs += 1
	_check("every fused id is distinct", ids.size(), 20)
	_check("every triple is distinct", triples.size(), 20)
	_check("and every one of them validates", errs, 0)

	# Coverage is the property that makes no card a dead end for a recipe hunter.
	var vs := {}; var ts := {}; var ps := {}
	for r in rs:
		vs[r.vector_id] = true; ts[r.trigger_id] = true; ps[r.payload_id] = true
	_check("every trigger has a fusion path", ts.size(), 7)
	_check("every payload has one too", ps.size(), 14)
	_check("every vector has one too", vs.size(), 14)

func an_exact_triple_matches_and_one_module_off_does_not() -> void:
	var ex := Exploit.new()
	ex.place(T[&"snipe"]); ex.place(T[&"on_kill"]); ex.place(T[&"bitmask"])
	var r: RecipeTable.Recipe = RecipeTable.match_exploit(ex)
	_check("the triple matches", r != null and r.fused.id == &"zero_day", true)

	var off := Exploit.new()
	off.place(T[&"packet"]); off.place(T[&"on_kill"]); off.place(T[&"bitmask"])
	_check("one module off matches nothing",
		RecipeTable.match_exploit(off), null)

	var partial := Exploit.new()
	partial.place(T[&"snipe"]); partial.place(T[&"on_kill"])
	_check("and an incomplete row matches nothing",
		RecipeTable.match_exploit(partial), null)


## Fusing frees all three ids — that is the whole reason uniqueness is
## affordable. And it may not orphan the loadout: the row holding the last
## interval cannot fuse into something that fires on a condition.
func fusing_frees_the_ids_and_keeps_the_metronome() -> void:
	var lo := Loadout.new()
	lo.exploits = [_maxed(_mk(&"snipe", &"on_kill", [&"bitmask"])),
		_mk(&"packet", &"interval", [])]

	var matches: Array = lo.matched_recipes()
	_check("the row matches one recipe", matches.size(), 1)
	_check("and it is row 0", matches[0][0], 0)

	var rec: RecipeTable.Recipe = matches[0][1]
	_check("fusing row 0 is allowed: row 1 still has interval",
		lo.can_fuse(0, rec.fused), true)
	lo.fuse(0, rec.fused)

	_check("the row is now the fused module", lo.exploits[0].vector.module.id,
		&"zero_day")
	_check("and the head reads as fused", lo.exploits[0].head_is_fused(), true)
	_check("its trigger column is empty", lo.exploits[0].trigger, null)
	_check("and its payload slot is open", lo.exploits[0].at(2), null)
	# Placeable SOMEWHERE — on_kill's home is a not-yet-created row, since row 1
	# holds the last interval and is protected from replacement.
	_check("snipe is placeable again",
		lo.legal_targets(T[&"snipe"]).is_empty(), false)
	_check("on_kill is placeable again",
		lo.legal_targets(T[&"on_kill"]).is_empty(), false)
	_check("bitmask is placeable again",
		lo.legal_targets(T[&"bitmask"]).is_empty(), false)

## The refusal must be inert, not partial. fuse() assigns the head LAST for this
## reason; without the guard it would clear the trigger and payload first and
## leave a row it then refused to complete.
func a_refused_fusion_leaves_the_row_untouched() -> void:
	var lo := Loadout.new()
	lo.exploits = [_maxed(_mk(&"packet", &"interval", [&"fork_bomb"]))]
	var conditional: Module = RecipeTable.by_fused_id()[&"zero_day"].fused
	lo.fuse(0, conditional)
	_check("the vector is untouched", lo.exploits[0].vector.module.id, &"packet")
	_check("the trigger too", lo.exploits[0].trigger.module.id, &"interval")
	_check("and the payload", lo.exploits[0].payloads[0].module.id, &"fork_bomb")

func fusing_may_not_orphan_the_loadout() -> void:
	var lo := Loadout.new()
	# The ONLY interval in the loadout, in the row that would fuse.
	lo.exploits = [_maxed(_mk(&"packet", &"interval", [&"fork_bomb"]))]
	var rec: RecipeTable.Recipe = lo.matched_recipes()[0][1]
	_check("frag_packet is INTERVAL-triggered, so this is allowed",
		lo.can_fuse(0, rec.fused), true)

	var conditional: Module = RecipeTable.by_fused_id()[&"zero_day"].fused
	_check("but fusing the last interval into an ON_KILL weapon is refused",
		lo.can_fuse(0, conditional), false)


## A fused module ranks 1->5 like anything else, so it has to be drawable — but
## only as a rank-up, and only once you hold it. ModuleTable never lists it.
func a_fused_module_is_drawable_only_once_held() -> void:
	for m in ModuleTable.all():
		if m.is_fused:
			_check("ModuleTable lists no fused module", m.id, &"<none>")
	_check("the table is clean", true, true)

	var lo := Loadout.new()
	var zero_day: Module = RecipeTable.by_fused_id()[&"zero_day"].fused
	lo.exploits = [_mk(&"packet", &"interval", [])]
	_check("not held: no legal target anywhere",
		lo.legal_targets(zero_day).is_empty(), true)

	lo.exploits.append(Exploit.new())
	lo.exploits[1].vector = EquippedModule.new(zero_day)
	var t := lo.legal_targets(zero_day)
	_check("held: exactly one target, the rank-up", t.size(), 1)
	_check("and it is a rank-up", t[0].action, Loadout.Rule.RANK_UP)


## A recipe is what three FINISHED modules become. Without this gate, fusing is
## strictly better than ranking and the fused weapon is an early-game shortcut
## rather than the payoff for having maxed a specific triple.
func fusion_demands_three_finished_modules() -> void:
	var lo := Loadout.new()
	lo.exploits = [_mk(&"packet", &"interval", [&"fork_bomb"])]
	var rec: RecipeTable.Recipe = lo.matched_recipes()[0][1]
	_check("a rank-1 triple matches the recipe but cannot fuse",
		lo.can_fuse(0, rec.fused), false)

	# One short is still short.
	for em in lo.exploits[0].equipped():
		em.rank = em.module.max_rank
	lo.exploits[0].payloads[0].rank = 4
	_check("and one module short of max is still refused",
		lo.can_fuse(0, rec.fused), false)

	lo.exploits[0].payloads[0].rank = T[&"fork_bomb"].max_rank
	_check("all three maxed: allowed", lo.can_fuse(0, rec.fused), true)


## Fusion consumes three MAXED modules and returns a rank-1 one, so if the fused
## module is weaker than the triple it ate, the correct play is never to fuse and
## the whole feature is a trap. Measured at rank 1 — the moment of the trade.
##
## The triple's rate is taken with its cadence floored at its VECTOR's base
## cooldown. An event trigger compounds a large cadence bonus (on_hit at rank 5
## is 0.62^5 = 0.09x) but cannot sustainably out-fire its own events, so the
## uncapped number is theoretical. Compare like with like.
func fusing_is_never_a_downgrade() -> void:
	var worse := []
	var best_gain := 0.0
	for rec in RecipeTable.all():
		var tx := Exploit.new()
		tx.vector = EquippedModule.new(T[rec.vector_id], 5)
		tx.trigger = EquippedModule.new(T[rec.trigger_id], 5)
		tx.payloads[0] = EquippedModule.new(T[rec.payload_id], 5)
		var tr := Compiler.build(tx)
		var vbase: float = float(T[rec.vector_id].stats.get(&"cooldown", 1.0))
		var tdps: float = (tr.damage + tr.corruption) / maxf(tr.cooldown, vbase)

		var fx := Exploit.new()
		fx.vector = EquippedModule.new(rec.fused, 1)
		var f1 := Compiler.build(fx)
		var fdps: float = (f1.damage + f1.corruption) / maxf(f1.cooldown, 0.001)
		# 2% slack: the values are snapped to 0.5 damage, not solved exactly.
		if fdps < tdps * 0.98:
			worse.append(rec.fused.id)

		var fx5 := Exploit.new()
		fx5.vector = EquippedModule.new(rec.fused, 5)
		var f5 := Compiler.build(fx5)
		best_gain = maxf(best_gain,
			((f5.damage + f5.corruption) / maxf(f5.cooldown, 0.001)) / maxf(tdps, 0.001))
	_check("no recipe is a downgrade at the moment of fusing", worse, [])
	# And ranking it is worth doing: the payoff is the five ranks, not the fuse.
	_check("a maxed fused module beats its triple several times over",
		best_gain > 3.0, true)
