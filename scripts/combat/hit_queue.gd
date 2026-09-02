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

## Events refused because the queue was full, counted for the life of the queue —
## never reset per tick, only when the run constructs a fresh HitQueue. A silent
## overflow would desync one peer from the rest with no evidence; a nonzero
## `dropped` is that evidence, and the capacity is sized so it stays zero.
var dropped: int = 0

## Hit events drained this TICK, across every drain_pass — a per-tick
## diagnostic for the perf gate's load pin. `count` and `hit_count` are both
## zeroed by the drain, so nothing else can read the tick's hits after it.
var drained_events: int = 0

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

## The strongest execute threshold contributed to each entity this pass, and
## which exploit contributed it. Reset per PASS, like hit_count — an execute is
## decided from the damage of the pass that marks the entity, nothing earlier.
var execute_best: PackedFloat32Array
var execute_by: PackedInt32Array

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
	execute_best.resize(entity_capacity)
	execute_by.resize(entity_capacity)

func begin_tick() -> void:
	count = 0
	drained_events = 0
	hit_count = 0
	adjudication.fill(OPEN)
	outcome.fill(Outcome.NONE)
	killer_exploit.fill(-1)
	# -2, not -1. -1 is a legal SOURCE — the terrain corruption zones and the
	# botnet auras append with it — so using it for "unset" made an unowned
	# corruption crossing read back as unflipped and adjudicate DEAD. _on_flip
	# has carried a default for exactly this case since it was written; it was
	# simply unreachable.
	#
	# killer_exploit deliberately KEEPS -1: its only reader is the lifesteal
	# guard `killer >= 0`, where "unset" and "the environment did it" must both
	# mean no lifesteal. The asymmetry is intentional.
	flipper_exploit.fill(-2)

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

## Applies every queued event to `pop`, then adjudicates each entity this pass
## marked. Returns the number adjudicated. Events are consumed.
## `max_hp`, `execute` and `immune_type` are optional so every existing caller
## keeps working. `execute` is indexed by EXPLOIT and `immune_type` by enemy
## TYPE, not by entity: the exemption is a property of what a thing is.
func drain_pass(pop: Population, thresholds: PackedFloat32Array,
		max_hp: PackedFloat32Array = PackedFloat32Array(),
		execute: PackedFloat32Array = PackedFloat32Array(),
		immune_type: PackedByteArray = PackedByteArray()) -> int:
	# hit_count is PER PASS. It was reset only in begin_tick while the arrays
	# are sized for a single pass's events, so eight passes could drive the
	# write index to 7200 + 7*1800 = 19800 into a 7200-element array — an
	# out-of-bounds write aborting the drain mid-tick at max density.
	hit_count = 0
	execute_best.fill(0.0)
	execute_by.fill(-1)
	# Gated on a threshold actually being SET, not merely on the arrays being
	# passed: run.gd sizes `execute` to resolved.size() (>= 1) and `max_hp` to
	# MAX_ENEMIES, so a bare size check is true for every build in the game.
	var executes := false
	for x in execute:
		if x > 0.0:
			executes = true
			break
	executes = executes and max_hp.size() > 0

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
			if executes:
				var se := source_exploit[e]
				if se >= 0 and se < execute.size() and execute[se] > execute_best[i]:
					execute_best[i] = execute[se]
					execute_by[i] = se
		else:
			pop.corruption[i] += amount[e]
			if pop.corruption[i] >= thresholds[pop.type_index[i]]:
				if flipper_exploit[i] == -2:
					flipper_exploit[i] = source_exploit[e]
				adjudication[i] = MARKED

	# --- adjudicate --------------------------------------------------------
	var resolved := 0
	for i in pop.count:
		# The execute marks in the SAME adjudication that would otherwise have
		# left the entity alive. A second pass over the survivors would break
		# "adjudicated exactly once per tick".
		if executes and adjudication[i] == OPEN and execute_best[i] > 0.0 \
				and pop.integrity[i] > 0.0 \
				and pop.integrity[i] < max_hp[i] * execute_best[i] \
				and not _immune(immune_type, pop.type_index[i]):
			adjudication[i] = MARKED
			killer_exploit[i] = execute_by[i]
		if adjudication[i] != MARKED:
			continue
		# Flip wins over death, decided from this pass's accumulated totals.
		if flipper_exploit[i] != -2:
			outcome[i] = Outcome.FLIPPED
			pop.state[i] = Population.FLIPPED
		else:
			outcome[i] = Outcome.DEAD
			pop.state[i] = Population.DEAD
		adjudication[i] = CLOSED
		resolved += 1

	drained_events += count
	count = 0
	return resolved


## Minibosses are exempt. A threshold that deletes fork_bomb, packet_filter,
## null_ptr and kernel_panic off the bottom of their health bars removes the
## four fights the run is built around.
static func _immune(immune_type: PackedByteArray, ti: int) -> bool:
	return ti >= 0 and ti < immune_type.size() and immune_type[ti] != 0
