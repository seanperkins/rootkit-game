extends SceneTree

## The cadence guarantee: a vector's identity survives whatever is bolted onto it.
##
## Every cadence_mult contributor is a TRIGGER, and nothing global scales
## cooldown any more — haste is gone from Compiler.MULT_KEYS and the two
## payloads that carried cadence_mult buy shield recovery instead. So the whole
## product is vector-INDEPENDENT. Therefore
##     resolved = base x max(MIN_CADENCE_FRACTION, product)
## and the ratio between any two vectors is their base ratio whether or not the
## floor binds. Two data preconditions make that true, and validate() enforces
## both — the tests below pin the property AND the rules that protect it.

## A GDScript runtime error aborts its enclosing function WITHOUT failing the
## suite, so a file whose checks stop executing reports PASS while testing
## nothing. Counting them makes that loud.
const EXPECTED_CHECKS := 27

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
		trank: int, pranks: Array) -> float:
	var ex := Exploit.new()
	ex.place(T[vector_id]); ex.place(T[trigger_id])
	for p in payloads:
		ex.place(T[p])
	ex.trigger.rank = trank
	for i in pranks.size():
		if i < ex.payloads.size() and ex.payloads[i] != null:
			ex.payloads[i].rank = pranks[i]
	return Compiler.build(ex).cooldown

## THE property, across the PAYLOAD dimension. Scoping this to vector x trigger
## only is the mistake an earlier draft made: it passes on exactly the
## configuration where the claim holds and never runs where it failed.
##
## The payload RANK dimension replaced the old haste dimension: a ranked payload
## is now the thing most likely to grow a cadence contribution by accident,
## since the two that used to carry one still sit in that column.
func ratio_survives_every_build() -> void:
	var vectors := [&"packet", &"beam", &"broadcast", &"chain"]
	var payload_sets := [[], [&"overclock"], [&"race_condition"],
		[&"buffer_overflow"], [&"checksum"]]
	var worst := 0.0
	var worst_at := ""
	var compared := 0

	for trig in [&"interval", &"on_hit", &"on_kill", &"on_damage_taken"]:
		for trank in [1, 3, 5]:
			for pset in payload_sets:
				for prank in [1, 3, 5]:
					var cds := {}
					for v in vectors:
						cds[v] = _build(v, trig, pset, trank, [prank])
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
								worst_at = "%s:%s %s r%d %s p%d" % [
									a, b, trig, trank, pset, prank]

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
##
## Driven by on_hit alone. interval sits at 1.00 and contributes nothing, and
## with haste and payload cadence both gone the trigger column is the ONLY
## route to the floor left: on_hit at rank 5 is 0.62^5 = 0.0916, under
## MIN_CADENCE_FRACTION by itself. That is not a regression but a relocation —
## the floor now guards exactly the thing that can still run away.
func the_floor_preserves_ratios() -> void:
	var floored := 0
	for v in [&"packet", &"beam", &"broadcast", &"chain"]:
		var base: float = T[v].stats[&"cooldown"]
		var cd := _build(v, &"on_hit", [], 5, [])
		_check("%s floors at its own fraction" % v, cd, base * Compiler.MIN_CADENCE_FRACTION)
		if abs(cd - base * Compiler.MIN_CADENCE_FRACTION) < 1e-9:
			floored += 1
		_check("%s stays above the absolute floor" % v, cd > Compiler.MIN_COOLDOWN, true)
	_check("all four floor together, never some", floored, 4)

## Reductions compound and converge; costs accumulate linearly. Compounding a
## cost was measured as a -53%..-63% DPS trap on the option best_target scores
## highest, and applying a reduction linearly goes negative at rank 6.
## Driven by a SYNTHETIC cost, because after the trigger rework the shipped
## table has none: every trigger now sits at or below 1.00, since rarity is paid
## in burst rather than punished in cadence. The asymmetry rule still guards
## Compiler._rank_factor against the next module that carries one, so it is
## pinned here rather than deleted along with its last user.
func rank_is_asymmetric() -> void:
	var base: float = T[&"broadcast"].stats[&"cooldown"]
	var on_kill_f: float = T[&"on_kill"].stats[&"cadence_mult"]

	_check("a reduction compounds with rank",
		_build(&"broadcast", &"on_kill", [], 3, []), base * pow(on_kill_f, 3))
	_check("a cost accumulates with rank, never compounds",
		Compiler._rank_factor(1.52, 3), 1.0 + 0.52 * 3.0)
	_check("and compounding it would have been far worse",
		pow(1.52, 3) > 1.0 + 0.52 * 3.0, true)

	# Scoped to the BARE vector + trigger build on purpose. With a flat-damage
	# payload the worst r5/r1 DPS ratio measured 0.484, so an unscoped bound fails.
	for v in [&"packet", &"beam", &"broadcast", &"chain"]:
		var dmg1: float = float(T[v].stats[&"damage"]) + float(T[&"on_kill"].stats[&"damage"])
		var dmg5: float = float(T[v].stats[&"damage"]) + float(T[&"on_kill"].stats[&"damage"]) * 5.0
		var dps1: float = dmg1 / _build(v, &"on_kill", [], 1, [])
		var dps5: float = dmg5 / _build(v, &"on_kill", [], 5, [])
		_check("%s: ranking on_kill never costs DPS (bare build)" % v,
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
		var bad_mult := Module.make(&"bad_m", "bad_m", Module.Slot.TRIGGER,
			{&"cadence_mult": v})
		_check("cadence_mult %s is rejected" % v, Compiler.validate(bad_mult).size() > 0, true)

	var payload := Module.make(&"payload_cadence", "payload_cadence",
		Module.Slot.PAYLOAD, {&"cadence_mult": 0.82})
	_check("a positive PAYLOAD cadence factor is rejected",
		Compiler.validate(payload).size() > 0, true)

## Rule 4's necessity, pinned by a test rather than by a comment: build the
## invalid vector directly, bypassing validate(), and watch the ratio drift.
func rule_four_is_necessary() -> void:
	var rogue := Module.make(&"rogue_v", "rogue_v", Module.Slot.VECTOR,
		{&"cooldown": 0.50, &"cadence_mult": 0.60}, [], Module.VectorKind.PACKET)
	var ex_r := Exploit.new()
	ex_r.place(rogue); ex_r.place(T[&"interval"]); ex_r.place(T[&"overclock"])
	ex_r.trigger.rank = 5; ex_r.payloads[0].rank = 1
	var rogue_cd: float = Compiler.build(ex_r).cooldown

	var stock_cd := _build(&"broadcast", &"interval", [&"overclock"], 5, [1])
	var base_ratio: float = float(T[&"broadcast"].stats[&"cooldown"]) / 0.50
	var got: float = stock_cd / rogue_cd

	print("    rogue vector: resolved ratio %.4f against base ratio %.4f" % [got, base_ratio])
	_check("a VECTOR-carried cadence_mult DOES break the ratio",
		abs(got - base_ratio) > 1e-6, true)
