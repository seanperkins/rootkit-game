extends SceneTree

var failures := 0
var T := ModuleTable.by_id()

func _init() -> void:
	print("ROOTKIT — compiler / loadout\n")
	data_sweep()
	fillability_invariant()
	rank_scaling()
	cooldown_clamp()
	vector_cadence_does_not_scale()
	speed_clamp()
	int_fold_order()
	permutation_determinism()
	rule_rank_up()
	rule_empty_slot()
	rule_new_exploit_vector_only()
	rule_replace_lowest_rank()
	rule_zero_no_legal_placement()
	inert_only_transient()
	ward_folds_by_max()
	rank_carve_outs()
	ward_equality()
	defensive_share()
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
	_check("data sweep: 18 modules, 0 errors", errs.size(), 0)
	_check("data sweep: module count", ModuleTable.all().size(), 18)

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

## Ranking a weapon up must not make it fire slower. A VECTOR's cooldown is its
## cadence; only reductions from payloads and triggers scale with rank.
func vector_cadence_does_not_scale() -> void:
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var ex := _mk(&"broadcast", &"interval")
	var r1 := Compiler.build(ex)
	ex.vector.rank = 5
	var r5 := Compiler.build(ex)
	_check("rank 5 vector fires at the same cadence", r5.cooldown, r1.cooldown)
	_check("and that cadence is the module's own", r1.cooldown,
		base + T[&"interval"].stats[&"cooldown"])
	_check("while its damage does scale", r5.damage > r1.damage, true)

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

## Ward magnitudes are MAX, never sum — including within a single exploit.
## Compiler._fold accumulates with +, and legal_targets offers an EMPTY_SLOT for
## payload slot 1 regardless of what slot 0 holds (loadout.gd), with ranks kept
## per SLOT rather than per module. So the same ward module in both payload slots
## of one exploit is a legal build, and summing it would buy double magnitude at
## zero uptime cost — the opposite of what a second copy should be worth.
func ward_folds_by_max() -> void:
	var mag: float = T[&"sandbox"].stats[&"ward_defense"]
	_check("one sandbox folds to its magnitude",
		Compiler.build(_mk(&"broadcast", &"interval", [&"sandbox"])).ward_defense, mag)
	_check("two sandbox in one exploit take the max",
		Compiler.build(_mk(&"broadcast", &"interval", [&"sandbox", &"sandbox"])).ward_defense, mag)

	# Two DIFFERENT wards in one exploit keep both magnitudes but share the
	# longer duration, because ward_duration is maxf-folded and the timer is
	# per-exploit. Pairing a long ward with a short one upgrades the short one's
	# uptime for free; that is priced, not accidental.
	var r := Compiler.build(_mk(&"broadcast", &"interval", [&"harden", &"sandbox"]))
	_check("mixed wards keep both magnitudes",
		r.ward_armor > 0.0 and r.ward_defense > 0.0, true)
	_check("mixed wards share the longer duration", r.ward_duration,
		maxf(T[&"harden"].stats[&"ward_duration"], T[&"sandbox"].stats[&"ward_duration"]))

	# lifesteal joins the same rule: keylog is the fifth defensive module.
	_check("two keylog take the max",
		Compiler.build(_mk(&"broadcast", &"interval", [&"keylog", &"keylog"])).lifesteal,
		float(T[&"keylog"].stats[&"lifesteal"]))

## Rank buys ward MAGNITUDE, never uptime, and never packet range. A vector's
## cadence already has this carve-out on the same principle.
func rank_carve_outs() -> void:
	var ex := _mk(&"broadcast", &"interval", [&"sandbox"])
	ex.payloads[0].rank = 5
	var r := Compiler.build(ex)
	_check("ward magnitude rank-scales", r.ward_defense,
		float(T[&"sandbox"].stats[&"ward_defense"]) * 5.0)
	_check("ward_duration does NOT rank-scale", r.ward_duration,
		float(T[&"sandbox"].stats[&"ward_duration"]))

	# travel held flat is what keeps reach meaningful: at em.rank a rank-3 packet
	# would fly 1920px and outrun every bound the design has.
	var pk := _mk(&"packet", &"interval")
	pk.vector.rank = 5
	_check("vector travel does NOT rank-scale", Compiler.build(pk).travel,
		float(T[&"packet"].stats[&"travel"]))
	_check("reach scales travel", Compiler.build(pk, {&"reach": 1.30}).travel,
		float(T[&"packet"].stats[&"travel"]) * 1.30)

## equals must cover the new fields or the permutation test passes on builds that
## differ only in a ward.
func ward_equality() -> void:
	var a := Compiler.build(_mk(&"broadcast", &"interval", [&"harden"]))
	var b := Compiler.build(_mk(&"broadcast", &"interval", [&"sandbox"]))
	_check("equals distinguishes ward-only differences", a.equals(b), false)

## Four of the fifteen unlocked modules are defensive — the three new wards plus
## keylog, which was always defensive and merely read as an anomaly.
##
## The offer pool IS the unlocked list, so 4/15 is the real dilution figure.
## legal_targets offers REPLACE for any occupied slot whose occupant is not the
## last INTERVAL trigger, so a vector is always displaceable and _offer_cards
## filters nothing out. An earlier draft claimed vectors "need a free exploit"
## and derived a much higher share from it; that claim was false.
func defensive_share() -> void:
	var defensive := 0
	for m in ModuleTable.starting_unlocked():
		if m.id in [&"harden", &"sandbox", &"nice", &"keylog"]:
			defensive += 1
	_check("four defensive modules unlocked", defensive, 4)
	_check("unlocked total", ModuleTable.starting_unlocked().size(), 15)
