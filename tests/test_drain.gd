extends SceneTree

## Pins the two rules that revision 2 and revision 3 each got wrong.
##
## Order-independence is not provable by one construction: the review found the
## revision-2 test could pass while the contradiction shipped, because it only
## built one of the two event orders. Every case here runs BOTH orders, and the
## cross-pass cases run both pass orders.

const THRESH := 10.0
var failures := 0

func _init() -> void:
	print("ROOTKIT — drain / adjudication semantics\n")
	case_within_pass_damage_then_corruption()
	case_within_pass_corruption_then_damage()
	case_cross_pass_death_then_corruption()
	case_cross_pass_flip_then_damage()
	case_on_hit_fires_on_surviving_target()
	case_stale_generation_rejected()
	print("")
	if failures == 0:
		print("  PASS — all 6 cases")
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
