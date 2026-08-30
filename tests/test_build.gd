extends SceneTree

var failures := 0
var T := ModuleTable.by_id()

func _init() -> void:
	print("ROOTKIT — compiler / loadout\n")
	data_sweep()
	fillability_invariant()
	rank_scaling()
	cooldown_clamp()
	speed_clamp()
	int_fold_order()
	permutation_determinism()
	rule_rank_up()
	rule_empty_slot()
	rule_new_exploit_vector_only()
	rule_replace_lowest_rank()
	rule_zero_no_legal_placement()
	inert_only_transient()
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

func _mk(vector_id: StringName, trigger_id: StringName, payloads: Array = []) -> Exploit:
	var ex := Exploit.new()
	if vector_id != &"": ex.place(T[vector_id])
	if trigger_id != &"": ex.place(T[trigger_id])
	for p in payloads: ex.place(T[p])
	return ex

## Every module resolves cleanly with only known stat keys, and any module
## contributing corruption carries the corruption tag.
func data_sweep() -> void:
	var errs := []
	for m in ModuleTable.all():
		errs.append_array(Compiler.validate(m))
	_check("data sweep: 15 modules, 0 errors", errs.size(), 0)
	_check("data sweep: module count", ModuleTable.all().size(), 15)

## A 3-exploit board needs 3 distinct VECTORs and 3 distinct TRIGGERs. Fewer
## unlocked and the advertised cap is unreachable, permanently, for a new player.
func fillability_invariant() -> void:
	var v := 0; var t := 0; var p := 0
	for m in ModuleTable.starting_unlocked():
		match m.slot:
			Module.Slot.VECTOR:  v += 1
			Module.Slot.TRIGGER: t += 1
			_:                   p += 1
	_check("unlock invariant: >=3 VECTOR", v >= 3, true)
	_check("unlock invariant: >=3 TRIGGER", t >= 3, true)
	_check("unlock invariant: >=6 PAYLOAD", p >= 6, true)

## Derived from the table, not hardcoded — a balance pass should not be able to
## fail a correctness test.
func rank_scaling() -> void:
	var base: float = T[&"broadcast"].stats[&"damage"]
	var pay: float = T[&"buffer_overflow"].stats[&"damage"]
	var ex := _mk(&"broadcast", &"interval", [&"buffer_overflow"])
	_check("rank 1: base + payload", Compiler.build(ex).damage, base + pay)
	ex.payloads[0].rank = 3
	_check("rank 3: base + payload*3", Compiler.build(ex).damage, base + pay * 3.0)

## Stack every cooldown contributor at max rank and the floor must still hold.
func cooldown_clamp() -> void:
	var ex := _mk(&"broadcast", &"interval", [&"overclock"])
	ex.trigger.rank = 5
	ex.payloads[0].rank = 5
	var r := Compiler.build(ex)
	_check("cooldown clamped to MIN_COOLDOWN", r.cooldown, Compiler.MIN_COOLDOWN)
	_check("cooldown never negative", r.cooldown > 0.0, true)

func speed_clamp() -> void:
	var ex := _mk(&"packet", &"interval")
	ex.vector.rank = 5
	var r := Compiler.build(ex)
	_check("projectile speed clamped", r.projectile_speed, Compiler.MAX_PROJECTILE_SPEED)

## Fold in float, floor once at the end: two 0.5 contributions must make 1.
func int_fold_order() -> void:
	var half_a := Module.make(&"half_a", "a", Module.Slot.PAYLOAD, {&"chain_count": 0.5})
	var half_b := Module.make(&"half_b", "b", Module.Slot.PAYLOAD, {&"chain_count": 0.5})
	var ex := _mk(&"broadcast", &"interval")
	ex.place(half_a); ex.place(half_b)
	var r := Compiler.build(ex)
	_check("0.5 + 0.5 folds to 1, not 0", r.chain_count, 1)

## The real bug is acquisition order changing the fold. Values are chosen to
## expose float non-associativity: with ordinary values, commutativity makes
## this pass even if the sort is missing entirely.
func permutation_determinism() -> void:
	var big := Module.make(&"z_big", "big", Module.Slot.PAYLOAD, {&"damage": 1e16})
	var one := Module.make(&"m_one", "one", Module.Slot.PAYLOAD, {&"damage": 1.0})
	var a := Exploit.new()
	a.place(T[&"broadcast"]); a.place(T[&"interval"])
	a.payloads[0] = EquippedModule.new(big); a.payloads[1] = EquippedModule.new(one)
	var b := Exploit.new()
	b.place(T[&"broadcast"]); b.place(T[&"interval"])
	b.payloads[0] = EquippedModule.new(one); b.payloads[1] = EquippedModule.new(big)
	var ra := Compiler.build(a)
	var rb := Compiler.build(b)
	_check("permuted slot order resolves identically", ra.equals(rb), true)

func _fresh() -> Loadout:
	var l := Loadout.new()
	l.start(T[&"packet"], T[&"interval"])
	return l

func rule_rank_up() -> void:
	var l := _fresh()
	var p := l.resolve(T[&"packet"])
	_check("rule 1: held module ranks up", p.rule, Loadout.Rule.RANK_UP)
	l.apply(T[&"packet"], p)
	_check("rule 1: rank became 2", l.exploits[0].vector.rank, 2)

func rule_empty_slot() -> void:
	var l := _fresh()
	var p := l.resolve(T[&"corrupt"])
	_check("rule 2: payload takes an empty slot", p.rule, Loadout.Rule.EMPTY_SLOT)
	l.apply(T[&"corrupt"], p)
	_check("rule 2: landed in exploit 0", l.exploits[0].payloads[0].module.id, &"corrupt")

## Rule 3 founds only from a VECTOR. A TRIGGER or PAYLOAD reaching it would
## found an exploit that can never fire.
func rule_new_exploit_vector_only() -> void:
	var l := _fresh()
	l.apply(T[&"corrupt"], l.resolve(T[&"corrupt"]))
	l.apply(T[&"keylog"], l.resolve(T[&"keylog"]))
	var pv := l.resolve(T[&"broadcast"])
	_check("rule 3: VECTOR founds a new exploit", pv.rule, Loadout.Rule.NEW_EXPLOIT)
	var pp := l.resolve(T[&"buffer_overflow"])
	_check("rule 3: PAYLOAD does NOT found one", pp.rule != Loadout.Rule.NEW_EXPLOIT, true)
	_check("rule 3: PAYLOAD falls through to replace", pp.rule, Loadout.Rule.REPLACE)

func rule_replace_lowest_rank() -> void:
	var l := _fresh()
	l.apply(T[&"corrupt"], l.resolve(T[&"corrupt"]))
	l.apply(T[&"keylog"], l.resolve(T[&"keylog"]))
	l.exploits[0].payloads[0].rank = 4          # corrupt at rank 4, keylog at 1
	var p := l.resolve(T[&"buffer_overflow"])
	_check("rule 4: displaces the lowest rank", p.victim.id, &"keylog")
	l.apply(T[&"buffer_overflow"], p)
	_check("rule 4: victim is gone", l.exploits[0].holds(&"keylog"), null)
	var re := l.resolve(T[&"keylog"])
	l.apply(T[&"keylog"], re)
	var back: EquippedModule = l.exploits[re.exploit_index].holds(&"keylog")
	if back != null:
		_check("rule 4: displaced module returns at rank 1", back.rank, 1)

## A module held at max rank has no legal placement — rule 1 declines it and
## rule 2 must NOT place a duplicate, which would break id uniqueness.
func rule_zero_no_legal_placement() -> void:
	var l := _fresh()
	l.exploits[0].vector.rank = T[&"packet"].max_rank
	var p := l.resolve(T[&"packet"])
	_check("rule 0: max-rank module has no placement", p.rule, Loadout.Rule.NONE)

func inert_only_transient() -> void:
	var ex := Exploit.new()
	ex.place(T[&"broadcast"])
	_check("founded from VECTOR: inert until a trigger lands", ex.is_inert(), true)
	ex.place(T[&"interval"])
	_check("no longer inert", ex.is_inert(), false)
