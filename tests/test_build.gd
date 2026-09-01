extends SceneTree

## Every assertion this file is supposed to make. A GDScript runtime error aborts
## the enclosing function WITHOUT failing the suite — verified: a missing property
## access here printed a SCRIPT ERROR and the suite still reported "PASS — all
## cases" while four checks never ran. Counting them makes that loud.
const EXPECTED_CHECKS := 81

var failures := 0
var checks := 0
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
	cadence_mult_defaults_to_one()
	rank_factor_is_asymmetric()
	cadence_mult_folds_by_product()
	new_keys_fold_by_their_rule()
	the_new_modules_are_present_and_valid()
	triggers_earn_their_keep()
	ward_folds_by_max()
	rank_carve_outs()
	ward_equality()
	uniqueness_is_loadout_wide()
	defensive_share()
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
	_check("data sweep: module count", ModuleTable.all().size(), 35)

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
## cadence; cadence FACTORS from payloads and triggers still scale with rank, but
## the two directions scale differently — a reduction compounds, a cost
## accumulates linearly. See Compiler._rank_factor.
func vector_cadence_does_not_scale() -> void:
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var ex := _mk(&"broadcast", &"interval")
	var r1 := Compiler.build(ex)
	ex.vector.rank = 5
	var r5 := Compiler.build(ex)
	_check("rank 5 vector fires at the same cadence", r5.cooldown, r1.cooldown)
	_check("and that cadence is the module's own", r1.cooldown,
		base * T[&"interval"].stats[&"cadence_mult"])
	_check("while its damage does scale", r5.damage > r1.damage, true)

## Stack every cadence contributor at max rank and the PROPORTIONAL floor holds.
## The absolute MIN_COOLDOWN no longer binds for any legal build — that is the
## point of the change, so it is asserted here. The haste is heavier than the
## old 0.70 because the second payload slot used to supply a second overclock;
## what is being pinned is the floor, not any particular route down to it.
func cooldown_clamp() -> void:
	var ex := _mk(&"broadcast", &"interval", [&"overclock"])
	ex.trigger.rank = 5
	ex.payloads[0].rank = 5
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var r := Compiler.build(ex, {&"haste": 0.20})
	_check("floored at the vector's own fraction", r.cooldown,
		base * Compiler.MIN_CADENCE_FRACTION)
	_check("above the absolute floor", r.cooldown > Compiler.MIN_COOLDOWN, true)
	_check("cooldown never negative", r.cooldown > 0.0, true)

func speed_clamp() -> void:
	var ex := _mk(&"packet", &"interval")
	ex.vector.rank = 5
	var r := Compiler.build(ex)
	_check("projectile speed clamped", r.projectile_speed, Compiler.MAX_PROJECTILE_SPEED)

## Fold in float, floor once at the end: two 0.5 contributions must make 1. The
## halves sit in different COLUMNS now — one payload slot means an exploit can
## no longer hold two payloads — which tests the same arithmetic against the
## same single floor at the end of build().
func int_fold_order() -> void:
	var half_a := Module.make(&"half_a", "a", Module.Slot.TRIGGER, {&"chain_count": 0.5})
	var half_b := Module.make(&"half_b", "b", Module.Slot.PAYLOAD, {&"chain_count": 0.5})
	var ex := Exploit.new()
	ex.place(T[&"broadcast"]); ex.place(half_a); ex.place(half_b)
	var r := Compiler.build(ex)
	_check("0.5 + 0.5 folds to 1, not 0", r.chain_count, 1)

## The real bug is acquisition order changing the fold. The two-payload
## permutation this used to run died with the second payload slot, but the
## invariant it guarded did not: build() walks slots by ROLE — vector, payload,
## trigger — so the order the player happened to acquire them in cannot reach
## the arithmetic. Values are chosen to expose float non-associativity; with
## ordinary ones commutativity hides a fold that follows insertion order.
func permutation_determinism() -> void:
	var big := Module.make(&"z_big", "big", Module.Slot.PAYLOAD, {&"damage": 1e16})
	var one := Module.make(&"m_one", "one", Module.Slot.TRIGGER, {&"damage": 1.0})
	var a := Exploit.new()
	a.place(T[&"broadcast"]); a.place(one); a.place(big)
	var b := Exploit.new()
	b.place(big); b.place(one); b.place(T[&"broadcast"])
	var ra := Compiler.build(a)
	var rb := Compiler.build(b)
	_check("acquisition order resolves identically", ra.equals(rb), true)

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
## Compiler._fold accumulates with +, and one exploit still folds ward_* from
## two modules at once: the PAYLOAD column and the TRIGGER column land in the
## same ResolvedExploit. Summing would buy double magnitude at zero uptime cost,
## the opposite of what a second source should be worth.
##
## The second source is synthetic because no shipped TRIGGER carries a ward. It
## used to be the second payload slot — that slot is gone, the rule is not, and
## writing it this way keeps the test honest: passing `[&"sandbox", &"sandbox"]`
## to _mk now silently places one module, which would pass by doing nothing.
func ward_folds_by_max() -> void:
	var mag: float = T[&"sandbox"].stats[&"ward_defense"]
	_check("one sandbox folds to its magnitude",
		Compiler.build(_mk(&"broadcast", &"interval", [&"sandbox"])).ward_defense, mag)

	var t_def := Module.make(&"t_def", "t_def", Module.Slot.TRIGGER,
		{&"ward_defense": mag})
	var doubled := _mk(&"broadcast", &"interval", [&"sandbox"])
	doubled.place(t_def)
	_check("two ward_defense sources in one exploit take the max",
		Compiler.build(doubled).ward_defense, mag)

	# Two DIFFERENT wards in one exploit keep both magnitudes but share the
	# longer duration, because ward_duration is maxf-folded and the timer is
	# per-exploit. Pairing a long ward with a short one upgrades the short one's
	# uptime for free; that is priced, not accidental.
	var t_arm := Module.make(&"t_arm", "t_arm", Module.Slot.TRIGGER,
		T[&"harden"].stats.duplicate())
	var mixed := _mk(&"broadcast", &"interval", [&"sandbox"])
	mixed.place(t_arm)
	var r := Compiler.build(mixed)
	_check("mixed wards keep both magnitudes",
		r.ward_armor > 0.0 and r.ward_defense > 0.0, true)
	_check("mixed wards share the longer duration", r.ward_duration,
		maxf(T[&"harden"].stats[&"ward_duration"], T[&"sandbox"].stats[&"ward_duration"]))

	# lifesteal joins the same rule: keylog is the fifth defensive module.
	var t_steal := Module.make(&"t_steal", "t_steal", Module.Slot.TRIGGER,
		{&"lifesteal": T[&"keylog"].stats[&"lifesteal"]})
	var steal := _mk(&"broadcast", &"interval", [&"keylog"])
	steal.place(t_steal)
	_check("two lifesteal sources take the max", Compiler.build(steal).lifesteal,
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
	_check("unlocked total", ModuleTable.starting_unlocked().size(), 21)

## cadence_mult is the only STAT_KEY that does not default to zero, because it
## accumulates by product rather than by sum. Anything that resets fields
## generically, or assumes a zero default, breaks quietly on it — so the default
## is pinned by a test rather than by a comment.
func cadence_mult_defaults_to_one() -> void:
	var r := ResolvedExploit.new()
	_check("cadence_mult defaults to 1.0", r.cadence_mult, 1.0)
	_check("cadence_mult is a legal stat key", &"cadence_mult" in Module.STAT_KEYS, true)
	# 23: the module set added knockback, slow_amount, slow_duration, shield and
	# orbit_count, and the trigger rework added burst. Pinned because STAT_KEYS
	# is a CLOSED set whose every member must be a field on ResolvedExploit — a
	# key added without its field makes _fold write into nothing at all.
	_check("STAT_KEYS is 23", Module.STAT_KEYS.size(), 23)
	var zero_defaults := 0
	for k in Module.STAT_KEYS:
		if float(r.get(k)) == 0.0:
			zero_defaults += 1
	# cadence_mult is still the only one that does not, and burst was
	# deliberately kept a zero-default (0 reads as one emission) so it stays
	# that way.
	_check("every OTHER stat key defaults to zero", zero_defaults, 22)

## Rank scales the two directions differently, because each is the rule the other
## breaks under. Compounding a COST makes ranking on_kill a -53%..-63% DPS trap;
## applying a REDUCTION linearly goes negative — overclock (0.82) crosses at
## rank 6, one above max_rank.
func rank_factor_is_asymmetric() -> void:
	_check("a reduction compounds", Compiler._rank_factor(0.85, 5), pow(0.85, 5))
	_check("a cost accumulates", Compiler._rank_factor(1.52, 5), 1.0 + 0.52 * 5.0)
	_check("1.0 is fixed under both branches", Compiler._rank_factor(1.0, 5), 1.0)
	_check("rank 0 is neutral", Compiler._rank_factor(0.85, 0), 1.0)
	_check("a reduction stays positive far past max_rank",
		Compiler._rank_factor(0.85, 10) > 0.0, true)

## Synthetic modules, because nothing in the shipped table carries the key twice.
## The second factor rides the TRIGGER column: an exploit holds one payload now,
## and a VECTOR may not carry cadence_mult at all — validate() rejects it — so
## the trigger is the only other place a second factor can legally come from.
## Synthetic rather than `interval`, which carries a 0.85 of its own that would
## fold into the very product being asserted.
func cadence_mult_folds_by_product() -> void:
	var a := Module.make(&"synth_a", "synth_a", Module.Slot.PAYLOAD, {&"cadence_mult": 0.5})
	var b := Module.make(&"synth_b", "synth_b", Module.Slot.TRIGGER, {&"cadence_mult": 0.5})
	var ex := Exploit.new()
	ex.place(T[&"broadcast"]); ex.place(a); ex.place(b)
	_check("two factors multiply, never add", Compiler.build(ex).cadence_mult, 0.25)

## The five keys added with the module set, and the rule each folds by.
func new_keys_fold_by_their_rule() -> void:
	var a := Module.make(&"k_a", "a", Module.Slot.PAYLOAD,
		{&"knockback": 40.0, &"shield": 10.0, &"orbit_count": 0.5})
	var b := Module.make(&"k_b", "b", Module.Slot.TRIGGER,
		{&"knockback": 30.0, &"shield": 25.0, &"orbit_count": 0.5})
	var ex := Exploit.new()
	ex.place(T[&"broadcast"]); ex.place(a); ex.place(b)
	var r := Compiler.build(ex)
	_check("knockback sums", r.knockback, 70.0)
	# Defensive: MAX, not sum. The same module is legal in many slots, and
	# summing a defensive magnitude buys it at no uptime cost.
	_check("shield takes the max", r.shield, 25.0)
	# Floored ONCE at the end, like pierce: 0.5 + 0.5 must be 1, not 0 + 0.
	_check("orbit_count sums then floors once", r.orbit_count, 1)

	var s1 := Module.make(&"s_1", "s1", Module.Slot.PAYLOAD,
		{&"slow_amount": 0.5, &"slow_duration": 1.0}, [&"slow"])
	var s2 := Module.make(&"s_2", "s2", Module.Slot.TRIGGER,
		{&"slow_amount": 0.3, &"slow_duration": 3.0}, [&"slow"])
	var ex2 := Exploit.new()
	ex2.place(T[&"broadcast"]); ex2.place(s1); ex2.place(s2)
	var r2 := Compiler.build(ex2)
	_check("slow_amount takes the max", r2.slow_amount, 0.5)
	_check("slow_duration takes the max", r2.slow_duration, 3.0)

	# The tag rule, mirroring the corruption one.
	var untagged := Module.make(&"s_bad", "bad", Module.Slot.PAYLOAD,
		{&"slow_amount": 0.5})
	_check("slow without its tag is rejected",
		Compiler.validate(untagged).size() > 0, true)

func the_new_modules_are_present_and_valid() -> void:
	var all := ModuleTable.all()
	var by_id := {}
	for m in all:
		by_id[m.id] = m
	var missing := 0
	for id in [&"spike", &"flood", &"snipe", &"landmine", &"cascade",
			&"bounce", &"mirror", &"throttle", &"airgap", &"checksum",
			&"on_low_integrity", &"on_flip", &"on_level_up",
			&"bitmask", &"race_condition", &"heap_spray", &"tarpit"]:
		if not by_id.has(id):
			missing += 1
	_check("all seventeen new modules are in the table", missing, 0)
	_check("the table is 35 modules", all.size(), 35)

	var errs := 0
	for m in all:
		errs += Compiler.validate(m).size()
	_check("every module validates", errs, 0)

	# A card pool that doubled would halve the odds of drawing what a build
	# needs, which makes builds mushier rather than richer.
	_check("about half the new breadth is locked",
		ModuleTable.LOCKED.size() >= 10, true)
	_check("so the starting pool stays close to today's",
		ModuleTable.starting_unlocked().size() <= 26, true)

	# Every locked module must have a milestone, or it can never be earned.
	var unearnable := 0
	for id in ModuleTable.LOCKED:
		SaveGame.use_fresh_state()
		if SaveGame.is_unlocked(id):
			continue                     # already open at zero progress
		var d := SaveGame.load_state()
		d["kills"] = 100000
		d["flips"] = 100000
		if not SaveGame._milestone_met(id, d):
			unearnable += 1
	_check("every locked module is reachable by playing", unearnable, 0)

## The trigger rework. interval used to be BOTH faster than every event trigger
## and unconditional, so no build could ever prefer one — the ordering below is
## the fix, and it is worth pinning because a single number regresses it.
func triggers_earn_their_keep() -> void:
	var by_id := ModuleTable.by_id()
	var interval: float = by_id[&"interval"].stats[&"cadence_mult"]
	_check("interval is the baseline, not a bonus", interval, 1.00)

	# The frequent triggers beat the metronome on RATE when their condition is
	# hot. That is the whole point: a conditional trigger has to be able to win.
	for id in [&"on_hit", &"on_kill", &"on_flip"]:
		_check("%s out-paces interval when hot" % id,
			float(by_id[id].stats[&"cadence_mult"]) < interval, true)

	# The rare ones are paid in emissions instead, so rarity buys a moment.
	for id in [&"on_damage_taken", &"on_low_integrity", &"on_level_up"]:
		_check("%s bursts" % id, float(by_id[id].stats.get(&"burst", 0.0)) > 1.0, true)
	# And the frequent ones are NOT, or they would win on both axes at once.
	for id in [&"on_hit", &"on_kill", &"on_flip"]:
		_check("%s does not burst" % id, by_id[id].stats.has(&"burst"), false)

	# on_flip pays in the resource its own build runs on, which is what stops it
	# being on_kill with extra steps.
	_check("on_flip pays in corruption",
		by_id[&"on_flip"].stats.has(&"corruption"), true)
	_check("and carries the tag that makes it count",
		by_id[&"on_flip"].has_tag(&"corruption"), true)

	# burst is meaningless outside a trigger.
	var bad := Module.make(&"b_bad", "bad", Module.Slot.PAYLOAD, {&"burst": 3.0})
	_check("a payload carrying burst is rejected",
		Compiler.validate(bad).size() > 0, true)


## One id, one slot. The old rule let a module occupy any number of slots; that
## existed because three exploits each need a TRIGGER and the auto-slotter could
## not place a held one. Placement is the player's decision now, and fusion is
## the escape hatch that frees an id for another row.
func uniqueness_is_loadout_wide() -> void:
	var lo := Loadout.new()
	lo.exploits = [_mk(&"packet", &"interval", [&"keylog"]),
		_mk(&"chain", &"on_kill", []), _mk(&"spike", &"on_hit", [])]

	# Held in row 0: the ONLY target is that slot, and only to rank it.
	var t := lo.legal_targets(T[&"packet"])
	_check("a held id offers exactly one target", t.size(), 1)
	_check("and that target is the slot holding it", t[0].exploit, 0)
	_check("as a rank-up", t[0].action, Loadout.Rule.RANK_UP)

	# 3 = the two empty payload slots in rows 1 and 2, plus a REPLACE over
	# keylog in row 0. Naming the number rather than "both slots", which reads
	# as 2 and invites a wrong fix to the count.
	var u := lo.legal_targets(T[&"corrupt"])
	_check("an unheld payload reaches three slots", u.size(), 3)

	# At max rank, a held id has no target at all — the salvage path.
	lo.exploits[0].vector.rank = T[&"packet"].max_rank
	_check("a maxed held id has no legal target",
		lo.legal_targets(T[&"packet"]).size(), 0)
