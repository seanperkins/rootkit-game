class_name Loadout extends RefCounted

## Owns the player's exploits and the auto-slot rules. Pure.
##
## Module ids are globally unique across the loadout — the invariant that makes
## the rank-up rule singular. assert_unique() is called after every mutation.

const MAX_EXPLOITS := 3

enum Rule { NONE, RANK_UP, EMPTY_SLOT, NEW_EXPLOIT, REPLACE }

class Placement extends RefCounted:
	var rule: int = Rule.NONE
	var exploit_index: int = -1
	var victim: Module = null
	func _init(r: int = Rule.NONE, ei: int = -1, v: Module = null) -> void:
		rule = r
		exploit_index = ei
		victim = v

var exploits: Array = []
var buffs: Dictionary = {}

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

func assert_unique() -> void:
	var seen := {}
	for ex in exploits:
		for em in ex.equipped():
			assert(not seen.has(em.module.id), "duplicate module id in loadout: %s" % em.module.id)
			seen[em.module.id] = true

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
	assert_unique()

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
		out.append(Compiler.build(ex, buffs))
	return out
