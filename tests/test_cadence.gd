extends SceneTree

## The cadence guarantee: a vector's identity survives whatever is bolted onto it.
##
## Every cadence_mult contributor is a TRIGGER or PAYLOAD and haste is global, so
## the whole product is vector-INDEPENDENT. Therefore
##     resolved = base x max(MIN_CADENCE_FRACTION, product x haste)
## and the ratio between any two vectors is their base ratio whether or not the
## floor binds. Two data preconditions make that true, and validate() enforces
## both — the tests below pin the property AND the rules that protect it.

## A GDScript runtime error aborts its enclosing function WITHOUT failing the
## suite, so a file whose checks stop executing reports PASS while testing
## nothing. Counting them makes that loud.
const EXPECTED_CHECKS := 25

var failures := 0
var checks := 0
var T := ModuleTable.by_id()

func _init() -> void:
	print("ROOTKIT — cadence\n")
	ratio_survives_every_build()
	the_floor_preserves_ratios()
	rank_is_asymmetric()
	validate_rules_fire()
	rule_four_is_necessary()
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
	if got == want or (got is float and want is float and abs(got - want) < 1e-9):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _build(vector_id: StringName, trigger_id: StringName, payloads: Array,
		trank: int, pranks: Array, haste: float) -> float:
	var ex := Exploit.new()
	ex.place(T[vector_id]); ex.place(T[trigger_id])
	for p in payloads:
		ex.place(T[p])
	ex.trigger.rank = trank
	for i in pranks.size():
		if i < ex.payloads.size() and ex.payloads[i] != null:
			ex.payloads[i].rank = pranks[i]
	return Compiler.build(ex, {&"haste": haste}).cooldown

## THE property, across the PAYLOAD dimension. Scoping this to vector x trigger
## only is the mistake an earlier draft made: it passes on exactly the
## configuration where the claim holds and never runs where it failed.
func ratio_survives_every_build() -> void:
	var vectors := [&"packet", &"beam", &"broadcast", &"chain"]
	var payload_sets := [[], [&"overclock"], [&"overclock", &"overclock"],
		[&"buffer_overflow"], [&"overclock", &"buffer_overflow"]]
	var worst := 0.0
	var worst_at := ""
	var compared := 0

	for trig in [&"interval", &"on_hit", &"on_kill", &"on_damage_taken"]:
		for trank in [1, 3, 5]:
			for pset in payload_sets:
				for haste in [1.0, 0.85, 0.70]:
					var cds := {}
					for v in vectors:
						cds[v] = _build(v, trig, pset, trank, [5, 5], haste)
					for i in vectors.size():
						for j in range(i + 1, vectors.size()):
							var a: StringName = vectors[i]
							var b: StringName = vectors[j]
							var base_ratio: float = float(T[a].stats[&"cooldown"]) \
								/ float(T[b].stats[&"cooldown"])
							var got: float = cds[a] / cds[b]
							var err: float = abs(got / base_ratio - 1.0)
							compared += 1
							if err > worst:
								worst = err
								worst_at = "%s:%s %s r%d %s h%.2f" % [
									a, b, trig, trank, pset, haste]

	print("    compared %d vector pairs; worst relative ratio error %s" % [compared, worst])
	if worst > 0.0:
		print("    worst at: %s" % worst_at)
	# A sweep measured the true worst at 3.33e-16, so 1e-9 hides nothing real and
	# anything tighter is float noise rather than a property violation.
	_check("the ratio is the base ratio for every build", worst < 1e-9, true)
	_check("the sweep actually ran", compared > 1000, true)

## Reaching the floor is not a failure: every vector bottoms out at the same
## fraction of a DIFFERENT base, so ratios hold there too — and all four floor
## together, never some.
func the_floor_preserves_ratios() -> void:
	var floored := 0
	for v in [&"packet", &"beam", &"broadcast", &"chain"]:
		var base: float = T[v].stats[&"cooldown"]
		var cd := _build(v, &"interval", [&"overclock", &"overclock"], 5, [5, 5], 0.70)
		_check("%s floors at its own fraction" % v, cd, base * Compiler.MIN_CADENCE_FRACTION)
		if abs(cd - base * Compiler.MIN_CADENCE_FRACTION) < 1e-9:
			floored += 1
		_check("%s stays above the absolute floor" % v, cd > Compiler.MIN_COOLDOWN, true)
	_check("all four floor together, never some", floored, 4)

## Reductions compound and converge; costs accumulate linearly. Compounding a
## cost was measured as a -53%..-63% DPS trap on the option best_target scores
## highest, and applying a reduction linearly goes negative at rank 6.
func rank_is_asymmetric() -> void:
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var interval_f: float = T[&"interval"].stats[&"cadence_mult"]
	var on_kill_f: float = T[&"on_kill"].stats[&"cadence_mult"]

	_check("a reduction compounds with rank",
		_build(&"broadcast", &"interval", [], 3, [], 1.0), base * pow(interval_f, 3))
	_check("a cost accumulates with rank",
		_build(&"broadcast", &"on_kill", [], 3, [], 1.0),
		base * (1.0 + (on_kill_f - 1.0) * 3.0))

	# Scoped to the BARE vector + trigger build on purpose. With a flat-damage
	# payload the worst r5/r1 DPS ratio measured 0.484, so an unscoped bound fails.
	for v in [&"packet", &"beam", &"broadcast", &"chain"]:
		var dmg1: float = float(T[v].stats[&"damage"]) + float(T[&"on_kill"].stats[&"damage"])
		var dmg5: float = float(T[v].stats[&"damage"]) + float(T[&"on_kill"].stats[&"damage"]) * 5.0
		var dps1: float = dmg1 / _build(v, &"on_kill", [], 1, [], 1.0)
		var dps5: float = dmg5 / _build(v, &"on_kill", [], 5, [], 1.0)
		_check("%s: ranking on_kill costs at most 20%% DPS (bare build)" % v,
			dps5 >= dps1 * 0.80, true)

## Each rule was measured passing validate() while breaking something.
func validate_rules_fire() -> void:
	var bad_payload := Module.make(&"bad_cd", "bad_cd", Module.Slot.PAYLOAD,
		{&"cooldown": 0.40})
	_check("a PAYLOAD carrying cooldown is rejected",
		Compiler.validate(bad_payload).size() > 0, true)

	var bad_vector := Module.make(&"bad_v", "bad_v", Module.Slot.VECTOR,
		{&"cooldown": 0.50, &"cadence_mult": 0.85}, [], Module.VectorKind.PACKET)
	_check("a VECTOR carrying cadence_mult is rejected",
		Compiler.validate(bad_vector).size() > 0, true)

	var slow_vector := Module.make(&"slow_v", "slow_v", Module.Slot.VECTOR,
		{&"cooldown": 0.20}, [], Module.VectorKind.PACKET)
	_check("a VECTOR below the base threshold is rejected",
		Compiler.validate(slow_vector).size() > 0, true)

	# The has()-gated form let this through: vector_base 0.0, and the exploit is
	# NOT inert once a trigger lands, so it fires at a permanent 20/s.
	var no_cd := Module.make(&"no_cd_v", "no_cd_v", Module.Slot.VECTOR,
		{&"damage": 5.0}, [], Module.VectorKind.PACKET)
	_check("a VECTOR omitting cooldown is rejected",
		Compiler.validate(no_cd).size() > 0, true)

	for v in [0.0, -1.0, 1e-9]:
		var bad_mult := Module.make(&"bad_m", "bad_m", Module.Slot.PAYLOAD,
			{&"cadence_mult": v})
		_check("cadence_mult %s is rejected" % v, Compiler.validate(bad_mult).size() > 0, true)

## Rule 4's necessity, pinned by a test rather than by a comment: build the
## invalid vector directly, bypassing validate(), and watch the ratio drift.
func rule_four_is_necessary() -> void:
	var rogue := Module.make(&"rogue_v", "rogue_v", Module.Slot.VECTOR,
		{&"cooldown": 0.50, &"cadence_mult": 0.60}, [], Module.VectorKind.PACKET)
	var ex_r := Exploit.new()
	ex_r.place(rogue); ex_r.place(T[&"interval"]); ex_r.place(T[&"overclock"])
	ex_r.trigger.rank = 5; ex_r.payloads[0].rank = 1
	var rogue_cd: float = Compiler.build(ex_r, {&"haste": 0.70}).cooldown

	var stock_cd := _build(&"broadcast", &"interval", [&"overclock"], 5, [1], 0.70)
	var base_ratio: float = float(T[&"broadcast"].stats[&"cooldown"]) / 0.50
	var got: float = stock_cd / rogue_cd

	print("    rogue vector: resolved ratio %.4f against base ratio %.4f" % [got, base_ratio])
	_check("a VECTOR-carried cadence_mult DOES break the ratio",
		abs(got - base_ratio) > 1e-6, true)
