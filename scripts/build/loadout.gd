class_name Loadout extends RefCounted

## Owns the player's exploits and the auto-slot rules. Pure.
##
## A module id occupies exactly ONE slot in the whole loadout. Fusion is what
## frees one for another row — see legal_targets for why the failure this rule
## caused the first time does not recur.

const MAX_EXPLOITS := 3

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

## Starting loadout: one exploit, packet + interval. Without it the rules are
## not total — on an empty board a first TRIGGER or PAYLOAD card fails rules
## 1-3 and rule 4 has no module of that slot type to displace.
func start(packet: Module, interval: Module) -> void:
	var ex := Exploit.new()
	ex.place(packet)
	ex.place(interval)
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
##   - _is_last_interval still stands, so row one keeps an unconditional
##     trigger and the event triggers in rows two and three bootstrap off it.
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
				out.append(Target.new(e, sl, Rule.EMPTY_SLOT))
			elif not _is_last_interval(occupant):
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
		if exploits[i].has_free_slot_for(m.slot):
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
			if _is_last_interval(em) or em.module.is_fused:
				continue     # see _is_last_interval; a fused head is not a victim
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

## Fusing the row that holds your last INTERVAL trigger frees `interval` but
## leaves nothing firing unconditionally until you re-place it — the deadlock
## _is_last_interval was written for, arriving by a different door. A fused
## module that is itself INTERVAL-triggered replaces what it consumed.
func can_fuse(exploit_index: int, fused: Module) -> bool:
	if exploit_index < 0 or exploit_index >= exploits.size():
		return false
	if fused.trigger_kind == Module.TriggerKind.INTERVAL:
		return true
	var ex: Exploit = exploits[exploit_index]
	var lost := 1 if (ex.trigger != null
		and ex.trigger.module.trigger_kind == Module.TriggerKind.INTERVAL) else 0
	return _interval_count() - lost >= 1

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

## A fused module whose trigger_kind is INTERVAL counts as an interval trigger,
## because it is one.
func _interval_count() -> int:
	var n := 0
	for ex in exploits:
		if ex.head_is_fused():
			if ex.vector.module.trigger_kind == Module.TriggerKind.INTERVAL:
				n += 1
		elif ex.trigger != null \
				and ex.trigger.module.trigger_kind == Module.TriggerKind.INTERVAL:
			n += 1
	return n

## The loadout must always retain at least one INTERVAL trigger.
##
## Event triggers cannot bootstrap: an ON_KILL exploit fires when it kills, and
## it kills when it fires. With one exploit, rule 4 displacing `interval` for
## `on_kill` leaves the player with no weapon at all and no way to recover —
## observed in a full-run test as 6 kills in 116 seconds. Refusing the swap is
## cheaper than special-casing the deadlock everywhere downstream.
func _is_last_interval(em: EquippedModule) -> bool:
	if em.module.slot != Module.Slot.TRIGGER:
		return false
	if em.module.trigger_kind != Module.TriggerKind.INTERVAL:
		return false
	return _interval_count() <= 1

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
