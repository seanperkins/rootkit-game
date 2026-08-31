extends SceneTree

## The level-up board: which slots a module may occupy, and what happens there.
## Placement is now the player's choice, so the rules moved from "pick one" to
## "offer every legal one" — and the invariants have to hold across all of them.

var failures := 0
var T := ModuleTable.by_id()

func _initialize() -> void:
	print("ROOTKIT — slot targeting\n")
	compatibility()
	rank_up_where_held_and_placeable_elsewhere()
	duplicates_allowed()
	last_interval_protected()
	empty_exploits_offered()
	one_target_per_row()
	slot_index_round_trips()
	placement_applies()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh() -> Loadout:
	var l := Loadout.new()
	l.start(T[&"packet"], T[&"interval"])
	return l

func _slots(ts: Array) -> Array:
	var out := []
	for t in ts:
		out.append([t.exploit, t.slot])
	return out

## A module may only ever be offered slots of its own type.
func compatibility() -> void:
	var l := _fresh()
	for id in [&"corrupt", &"broadcast", &"on_kill"]:
		var m: Module = T[id]
		var ok := true
		for t in l.legal_targets(m):
			if Exploit.slot_type(t.slot) != m.slot:
				ok = false
		_check("%s only offered %s slots" % [id, ["VECTOR","TRIGGER","PAYLOAD"][int(m.slot)]], ok, true)

## An equipped module ranks up in the slot that holds it AND may be placed
## again elsewhere. Three exploits each need a trigger and there are only four
## trigger modules, so forbidding duplicates made the board unbuildable.
func rank_up_where_held_and_placeable_elsewhere() -> void:
	var l := _fresh()
	var ts := l.legal_targets(T[&"packet"])
	var own: Loadout.Target = null
	for t in ts:
		if t.exploit == 0 and t.slot == 0:
			own = t
	_check("its own slot offers a rank-up", own != null and own.action == Loadout.Rule.RANK_UP, true)
	_check("other vector slots are still offered", _slots(ts).has([1, 0]), true)
	l.exploits[0].vector.rank = T[&"packet"].max_rank
	var ts2 := l.legal_targets(T[&"packet"])
	_check("at max rank its own slot drops out", _slots(ts2).has([0, 0]), false)
	_check("but it can still go elsewhere", _slots(ts2).has([1, 0]), true)

## The whole point: the same trigger in every exploit.
func duplicates_allowed() -> void:
	var l := _fresh()
	l.place_at(T[&"chain"], 1, 0)
	l.place_at(T[&"interval"], 1, 1)
	l.place_at(T[&"broadcast"], 2, 0)
	l.place_at(T[&"interval"], 2, 1)
	var n := 0
	for ex in l.exploits:
		if ex.trigger != null and ex.trigger.module.id == &"interval":
			n += 1
	_check("interval can drive all three exploits", n, 3)
	_check("and none of them is inert",
		not (l.exploits[0].is_inert() or l.exploits[1].is_inert() or l.exploits[2].is_inert()), true)
	l.exploits[1].trigger.rank = 4
	_check("ranks are per slot, not shared", l.exploits[2].trigger.rank, 1)

## Displacing the only interval trigger would leave an event-triggered loadout
## unable to fire at all, so that slot is never offered.
func last_interval_protected() -> void:
	var l := _fresh()
	for t in l.legal_targets(T[&"on_kill"]):
		if t.exploit == 0 and t.slot == 1:
			_check("last interval trigger is not offered", true, false)
			return
	_check("last interval trigger is not offered", true, true)
	# a second interval elsewhere releases the guard
	l.place_at(T[&"chain"], 1, 0)
	l.place_at(T[&"on_hit"], 1, 1)
	var has_second_interval := false
	for ex in l.exploits:
		if ex.trigger != null and ex.trigger.module.trigger_kind == Module.TriggerKind.INTERVAL:
			has_second_interval = true if ex != l.exploits[0] else has_second_interval
	_check("guard still holds with only one interval",
		_slots(l.legal_targets(T[&"on_kill"])).has([0, 1]), false)

## Not-yet-founded exploits are shown, so the board is the whole build. Any slot
## type may found one — an exploit missing its vector is inert until the vector
## arrives, which the HUD says out loud, and that is the player's call to make.
func empty_exploits_offered() -> void:
	var l := _fresh()
	var ts := _slots(l.legal_targets(T[&"corrupt"]))
	_check("payload offered the one slot of exploit 1", ts.has([0, 2]), true)
	_check("payload offered unfounded exploit 2", ts.has([1, 2]), true)
	_check("payload offered unfounded exploit 3", ts.has([2, 2]), true)

## The invariant the one-click level-up card rests on: a module's slot type
## picks its column, so a row can offer it AT MOST one home. The moment a column
## holds two slots again this fails, and the card silently starts dropping a
## legal target on the floor instead of asking which slot.
func one_target_per_row() -> void:
	var l := _fresh()
	l.place_at(T[&"chain"], 1, 0)
	l.place_at(T[&"on_hit"], 1, 1)
	l.place_at(T[&"corrupt"], 1, 2)
	for id in [&"corrupt", &"packet", &"interval", &"keylog", &"on_kill", &"broadcast"]:
		var seen := {}
		var doubled := false
		for t in l.legal_targets(T[id]):
			if seen.has(t.exploit):
				doubled = true
			seen[t.exploit] = true
		_check("'%s' offers at most one slot per row" % id, doubled, false)

## Slot index and slot type are the same bijection read in two directions; the
## card converts one to the other on every button it draws.
func slot_index_round_trips() -> void:
	for si in Exploit.SLOT_COUNT:
		_check("slot %d round-trips" % si,
			Exploit.slot_index_of(Exploit.slot_type(si)), si)

func placement_applies() -> void:
	var l := _fresh()
	l.place_at(T[&"corrupt"], 2, 2)
	_check("placing founds the exploit", l.exploits.size(), 3)
	_check("module landed in the chosen slot",
		l.exploits[2].payloads[0].module.id, &"corrupt")
	l.place_at(T[&"corrupt"], 2, 2)
	_check("placing again ranks up", l.exploits[2].payloads[0].rank, 2)
	l.place_at(T[&"keylog"], 2, 2)
	_check("a different module replaces at rank 1",
		l.exploits[2].payloads[0].module.id, &"keylog")
	_check("replacement resets rank", l.exploits[2].payloads[0].rank, 1)
