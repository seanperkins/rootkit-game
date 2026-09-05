class_name Loadout extends RefCounted

## Owns the player's exploits and the auto-slot rules. Pure.
##
## A module id occupies exactly ONE slot in the whole loadout. Fusion is what
## frees one for another row — see legal_targets for why the failure this rule
## caused the first time does not recur.

## Five rows. Three made every new vector a long wait for a trigger and a
## build that could not breathe; with bare rows firing on a built-in interval
## five rows is breadth the player can actually use. Everything downstream —
## the run's gid stride, the manifest layout, the card screen's row buttons —
## derives from this constant, and the wire protocol is versioned on it.
const MAX_EXPLOITS := 5

enum Rule { NONE, RANK_UP, EMPTY_SLOT, NEW_EXPLOIT, REPLACE }

## A slot the player may drop a given module into, with what would happen.
class Target extends RefCounted:
	var exploit: int
	var slot: int
	var action: int          # Rule.RANK_UP | EMPTY_SLOT | REPLACE
	var victim: Module = null
	func _init(e: int, s: int, a: int, v: Module = null) -> void:
		exploit = e
		slot = s
		action = a
		victim = v

class Placement extends RefCounted:
	var rule: int = Rule.NONE
	var exploit_index: int = -1
	var victim: Module = null
	func _init(r: int = Rule.NONE, ei: int = -1, v: Module = null) -> void:
		rule = r
		exploit_index = ei
		victim = v

var exploits: Array = []
## Global player multipliers, absolutes not deltas. run.gd feeds this from
## PlayerStats.mults(SaveGame.multipliers()); compile_all is the ONLY runtime
## caller of Compiler.build, so a multiplier that does not pass through here
## reaches no exploit at all.
var mult: Dictionary = {}

## Starting loadout: one exploit, one VECTOR, and no trigger at all.
##
## A bare row fires on the compiler's built-in interval at
## Compiler.BARE_CADENCE, so the weapon works on the first frame and the first
## trigger card is an upgrade rather than the switch that turns the gun on.
## What still has to hold is that the rules stay TOTAL: on this board a first
## TRIGGER or PAYLOAD card lands in an empty slot by rules 1-3, and
## strands_auto_fire is what stops that first trigger being an EVENT trigger
## that leaves the player with nothing firing.
func start(packet: Module) -> void:
	var ex := Exploit.new()
	ex.place(packet)
	exploits = [ex]

func holds(id: StringName) -> int:
	for i in exploits.size():
		if exploits[i].holds(id) != null:
			return i
	return -1

## The exploit and slot holding this id, or [] when nothing does.
func _slot_holding(id: StringName) -> Array:
	for e in exploits.size():
		for sl in Exploit.SLOT_COUNT:
			var em: EquippedModule = exploits[e].at(sl)
			if em != null and em.module.id == id:
				return [e, sl]
	return []

## A module id occupies exactly ONE slot in the whole loadout.
##
## This rule was removed once and is back. What it broke the first time was the
## AUTO-SLOTTER: the rules could not place a trigger that was already held, so
## exploits two and three ended up with no trigger at all, and an exploit
## without one is inert — only the interval exploit appeared to work.
##
## Three things make it safe now:
##   - Placement is the player's decision. legal_targets offers what is legal
##     and the player chooses; a card it cannot place falls through to the
##     salvage path, rather than a row being silently left broken.
##   - strands_auto_fire still stands, so the board always keeps one row that
##     fires unconditionally, and the event triggers bootstrap off it.
##   - Fusion frees ids. That is the escape hatch the old design did not have,
##     and it is why the restriction is worth its cost: the way to use
##     `interval` twice is to fuse the row holding it.
##
## Ranks are per slot. With one slot per id that is now the same statement,
## but Compiler._fold still folds ward_* and lifesteal by MAX, because a single
## exploit can still carry them on two modules at once.
func legal_targets(m: Module) -> Array:
	var out := []
	var home := _slot_holding(m.id)
	# A fused module enters play by FUSING, never by being drawn. Once held it
	# ranks like anything else — the slot-holding branch below — but unheld it
	# has no home anywhere. Saying so here rather than leaving it to the card
	# pool is what makes it a rule instead of a coincidence.
	if m.is_fused and home.is_empty():
		return out
	for e in MAX_EXPLOITS:
		var ex: Exploit = exploits[e] if e < exploits.size() else null
		for sl in Exploit.SLOT_COUNT:
			if Exploit.slot_type(sl) != m.slot:
				continue
			if ex != null and ex.head_is_fused() and sl == 1:
				continue          # absorbed by the head, not empty
			if ex == null:
				if home.is_empty():
					out.append(Target.new(e, sl, Rule.EMPTY_SLOT))
				continue
			var occupant := ex.at(sl)
			if occupant != null and occupant.module.id == m.id:
				# Ranks are per SLOT. With uniqueness there is only ever one.
				if occupant.can_rank_up():
					out.append(Target.new(e, sl, Rule.RANK_UP))
				continue
			if not home.is_empty():
				continue          # one id, one slot: nowhere else is legal
			if ex.head_is_fused() and sl == 0:
				continue          # the fused head is not replaceable
			if occupant == null:
				if not strands_auto_fire(m, e):
					out.append(Target.new(e, sl, Rule.EMPTY_SLOT))
			elif not strands_auto_fire(m, e):
				out.append(Target.new(e, sl, Rule.REPLACE, occupant.module))
	return out

## The preference a sensible player follows, and what the auto-slotter used to
## do on its own: rank up what you have, then fill something empty, and only
## displace when there is no other home. Placement is the player's decision now,
## so this is a default rather than the rule — the level-up board offers every
## legal slot and this only orders them.
static func best_target(targets: Array) -> Target:
	var best: Target = null
	var best_score := -1
	for t in targets:
		var score := 0
		match t.action:
			Rule.RANK_UP:    score = 3
			Rule.EMPTY_SLOT: score = 2
			_:               score = 1
		if score > best_score:
			best_score = score
			best = t
	return best

func place_at(m: Module, exploit_index: int, slot_index: int) -> void:
	while exploits.size() <= exploit_index:
		exploits.append(Exploit.new())
	var ex: Exploit = exploits[exploit_index]
	var occupant := ex.at(slot_index)
	if occupant != null and occupant.module.id == m.id:
		occupant.rank += 1
	else:
		# A displaced module loses its rank: drawn again it re-enters at 1.
		ex.set_at(slot_index, EquippedModule.new(m))

## Resolves where a card would land. Rule 0 (no legal placement) returns NONE,
## and the caller offers the card as salvage — the backstop that makes the set
## total under any starting state or unlock configuration.
func resolve(m: Module) -> Placement:
	# 1 — rank-up
	var held := holds(m.id)
	if held >= 0:
		var em: EquippedModule = exploits[held].holds(m.id)
		if em.can_rank_up():
			return Placement.new(Rule.RANK_UP, held)
		return Placement.new(Rule.NONE)   # held at max rank: no legal placement

	# 2 — first exploit with an empty compatible slot
	for i in exploits.size():
		if exploits[i].has_free_slot_for(m.slot) and not strands_auto_fire(m, i):
			return Placement.new(Rule.EMPTY_SLOT, i)

	# 3 — found a new exploit, VECTOR only. Restricting this is what stops a
	# founded exploit from being permanently inert.
	if m.slot == Module.Slot.VECTOR and exploits.size() < MAX_EXPLOITS:
		return Placement.new(Rule.NEW_EXPLOIT, exploits.size())

	# 4 — displace the lowest-rank module of the same slot type, tie-broken by
	# lowest exploit index then lowest payload slot index.
	var best_ex := -1
	var best_em: EquippedModule = null
	for i in exploits.size():
		for em in _slot_members(exploits[i], m.slot):
			if em.module.is_fused or strands_auto_fire(m, i):
				continue     # a fused head is not a victim; see strands_auto_fire
			if best_em == null or em.rank < best_em.rank:
				best_em = em
				best_ex = i
	if best_em != null:
		return Placement.new(Rule.REPLACE, best_ex, best_em.module)

	return Placement.new(Rule.NONE)

func apply(m: Module, p: Placement) -> void:
	match p.rule:
		Rule.RANK_UP:
			exploits[p.exploit_index].holds(m.id).rank += 1
		Rule.EMPTY_SLOT:
			exploits[p.exploit_index].place(m)
		Rule.NEW_EXPLOIT:
			var ex := Exploit.new()
			ex.place(m)
			exploits.append(ex)
		Rule.REPLACE:
			_displace(p.exploit_index, p.victim)
			exploits[p.exploit_index].place(m)
		_:
			return

## The displaced module's rank is destroyed: drawn again, it re-enters at rank
## 1. A real penalty, and it changes what a rule-4 card's delta should show.
func _displace(ei: int, victim: Module) -> void:
	var ex: Exploit = exploits[ei]
	if ex.vector != null and ex.vector.module.id == victim.id:
		ex.vector = null
		return
	if ex.trigger != null and ex.trigger.module.id == victim.id:
		ex.trigger = null
		return
	for i in Exploit.PAYLOAD_SLOTS:
		if ex.payloads[i] != null and ex.payloads[i].module.id == victim.id:
			ex.payloads[i] = null
			return

## Every row that exactly matches a recipe, paired with what it would become.
func matched_recipes() -> Array:
	var out := []
	for i in exploits.size():
		var r := RecipeTable.match_exploit(exploits[i])
		if r != null:
			out.append([i, r])
	return out

## Two gates. All three modules must be at max rank — see Exploit.is_fully_ranked.
##
## And: fusing a row consumes its trigger, so it can take the board's last
## unconditionally-firing weapon with it — the deadlock strands_auto_fire was
## written for, arriving by a different door. A fused module that is itself
## INTERVAL-triggered replaces what it consumed; one that is not, does not.
func can_fuse(exploit_index: int, fused: Module) -> bool:
	if exploit_index < 0 or exploit_index >= exploits.size():
		return false
	var ex: Exploit = exploits[exploit_index]
	# All three at max rank. A recipe is what three finished modules become, not
	# a way to skip finishing them — without this, fusing is strictly better than
	# ranking and the fused weapon becomes an early-game shortcut.
	if not ex.is_fully_ranked():
		return false
	var lost := 1 if _fires_unconditionally(ex) else 0
	var kept := 1 if fused.trigger_kind == Module.TriggerKind.INTERVAL else 0
	return _auto_fire_count() - lost + kept >= 1

## Consumes all three. Their ids are free from this moment, which is the point:
## the way to use `interval` twice is to fuse the row holding it.
func fuse(exploit_index: int, fused: Module) -> void:
	if not can_fuse(exploit_index, fused):
		return          # never silently clear a row a caller may not fuse
	var ex: Exploit = exploits[exploit_index]
	ex.trigger = null
	for i in Exploit.PAYLOAD_SLOTS:
		ex.payloads[i] = null
	# The head goes into the VECTOR slot it occupies from now on. Assigned LAST,
	# so a refused fusion above leaves the row exactly as it was.
	ex.vector = EquippedModule.new(fused)

## A row fires WITHOUT waiting for an event when it has a vector and either no
## trigger at all (the compiler's built-in interval, paid at BARE_CADENCE), an
## INTERVAL trigger, or a fused head whose own trigger_kind is INTERVAL.
##
## The bare case is why this replaced the old "count the INTERVAL triggers"
## rule. With no starting trigger the board's only unconditional weapon is
## usually a bare row, and a census that could not see one would have called
## every board strandable and refused every event trigger on it.
static func _fires_unconditionally(ex: Exploit) -> bool:
	if ex.vector == null:
		return false
	if ex.head_is_fused():
		return ex.vector.module.trigger_kind == Module.TriggerKind.INTERVAL
	return ex.trigger == null \
		or ex.trigger.module.trigger_kind == Module.TriggerKind.INTERVAL

func _auto_fire_count() -> int:
	var n := 0
	for ex in exploits:
		if _fires_unconditionally(ex):
			n += 1
	return n

## The loadout must always retain at least one weapon that fires unconditionally.
##
## Event triggers cannot bootstrap: an ON_KILL exploit fires when it kills, and
## it kills when it fires. Leaving the player with none was observed in a
## full-run test as 6 kills in 116 seconds, with no way to recover. Refusing
## the placement is cheaper than special-casing the deadlock downstream.
##
## Asked about the RESULTING board rather than about the victim, because what
## is lost may be an ABSENCE: dropping `on_hit` into the empty trigger slot of
## the last bare row destroys nothing and still strands the player. Only an
## event TRIGGER can do it — a vector or a payload never takes a row's
## unconditional fire away, and an INTERVAL trigger supplies it.
## Public because the card screen names this refusal to the player.
func strands_auto_fire(m: Module, exploit_index: int) -> bool:
	if m.slot != Module.Slot.TRIGGER:
		return false
	if m.trigger_kind == Module.TriggerKind.INTERVAL:
		return false
	if exploit_index < 0 or exploit_index >= exploits.size():
		return false
	if not _fires_unconditionally(exploits[exploit_index]):
		return false
	return _auto_fire_count() <= 1

func _slot_members(ex: Exploit, slot: int) -> Array:
	match slot:
		Module.Slot.VECTOR:  return [ex.vector] if ex.vector != null else []
		Module.Slot.TRIGGER: return [ex.trigger] if ex.trigger != null else []
		_:
			var out := []
			for p in ex.payloads:
				if p != null: out.append(p)
			return out
	return []

func compile_all() -> Array:
	var out := []
	for ex in exploits:
		out.append(Compiler.build(ex, mult))
	return out
