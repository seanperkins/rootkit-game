class_name HitQueue extends RefCounted

## The ordered event queue and its drain. Review rounds 2 and 3 both broke here,
## so the two rules that were left undefined are stated in code:
##
## 1. SINGLE ADJUDICATION. An entity is adjudicated exactly once per tick, at
##    the end of the pass in which it first becomes marked, using every event
##    drained in that pass. It is then CLOSED: later events targeting it in
##    any later pass are discarded outright.
##
##    Without this, "corruption accumulates for the whole tick" plus per-pass
##    resolution means an enemy can resolve dead in pass 1 (drops emitted,
##    ON_KILL fired) and flip in pass 2 — or, with a naive already-resolved
##    guard, death-vs-flip silently depends on which pass an event landed in.
##    That is the queue-order bug relocated to pass granularity, not fixed.
##
## 2. PER-TRIGGER FIRING CONDITIONS, which are not the same condition:
##      ON_HIT           — per hit landed by the owning exploit on an open
##                         target, regardless of whether the target survives.
##      ON_KILL          — per adjudicated DEAD outcome, attributed to the
##                         exploit whose damage crossed integrity to zero.
##      ON_DAMAGE_TAKEN  — per damage instance the player actually takes.
##
##    Firing all three from a loop over terminally-marked entities (revision 3)
##    means ON_HIT only fires when the target dies and ON_DAMAGE_TAKEN only
##    fires when the player dies.

enum Kind { DAMAGE, CORRUPTION }
enum Outcome { NONE, DEAD, FLIPPED }

const OPEN := 0
const MARKED := 1
const CLOSED := 2

var kind: PackedInt32Array
var source_exploit: PackedInt32Array
var target: PackedInt32Array
var target_generation: PackedInt32Array
var amount: PackedFloat32Array
var count: int = 0

var _capacity: int

## Per-entity adjudication state for the current tick, indexed by entity slot.
var adjudication: PackedByteArray
var outcome: PackedInt32Array
var killer_exploit: PackedInt32Array
var flipper_exploit: PackedInt32Array

## Events that fired ON_HIT this pass: parallel exploit / target arrays.
var hit_exploit: PackedInt32Array
var hit_target: PackedInt32Array
var hit_count: int = 0

var dropped: int = 0

func _init(capacity: int, entity_capacity: int) -> void:
	_capacity = capacity
	kind.resize(capacity)
	source_exploit.resize(capacity)
	target.resize(capacity)
	target_generation.resize(capacity)
	amount.resize(capacity)
	hit_exploit.resize(capacity)
	hit_target.resize(capacity)
	adjudication.resize(entity_capacity)
	outcome.resize(entity_capacity)
	killer_exploit.resize(entity_capacity)
	flipper_exploit.resize(entity_capacity)

func begin_tick() -> void:
	count = 0
	dropped = 0
	hit_count = 0
	adjudication.fill(OPEN)
	outcome.fill(Outcome.NONE)
	killer_exploit.fill(-1)
	flipper_exploit.fill(-1)

func append(k: int, exploit: int, tgt: int, gen: int, amt: float) -> bool:
	if count >= _capacity:
		dropped += 1
		return false
	kind[count] = k
	source_exploit[count] = exploit
	target[count] = tgt
	target_generation[count] = gen
	amount[count] = amt
	count += 1
	return true

func clear_events() -> void:
	count = 0
	hit_count = 0

## Applies every queued event to `pop`, then adjudicates each entity this pass
## marked. Returns the number adjudicated. Events are consumed.
func drain_pass(pop: Population, thresholds: PackedFloat32Array) -> int:
	# --- apply -------------------------------------------------------------
	for e in count:
		var i := target[e]
		if i >= pop.count:
			continue
		if pop.generation[i] != target_generation[e]:
			continue          # stale event from a recycled slot
		if adjudication[i] == CLOSED:
			continue          # rule 1: a closed entity takes nothing further

		if kind[e] == Kind.DAMAGE:
			# A marked entity takes no further damage, but is not closed, so
			# corruption arriving later in this same pass still counts.
			if adjudication[i] == OPEN:
				pop.integrity[i] -= amount[e]
				if pop.integrity[i] <= 0.0:
					adjudication[i] = MARKED
					killer_exploit[i] = source_exploit[e]
			hit_exploit[hit_count] = source_exploit[e]
			hit_target[hit_count] = i
			hit_count += 1
		else:
			pop.corruption[i] += amount[e]
			if pop.corruption[i] >= thresholds[pop.type_index[i]]:
				if flipper_exploit[i] == -1:
					flipper_exploit[i] = source_exploit[e]
				adjudication[i] = MARKED

	# --- adjudicate --------------------------------------------------------
	var resolved := 0
	for i in pop.count:
		if adjudication[i] != MARKED:
			continue
		# Flip wins over death, decided from this pass's accumulated totals.
		if flipper_exploit[i] != -1:
			outcome[i] = Outcome.FLIPPED
			pop.state[i] = Population.FLIPPED
		else:
			outcome[i] = Outcome.DEAD
			pop.state[i] = Population.DEAD
		adjudication[i] = CLOSED
		resolved += 1

	count = 0
	return resolved
