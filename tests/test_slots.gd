extends SceneTree

## The level-up board: which slots a module may occupy, and what happens there.
## Placement is now the player's choice, so the rules moved from "pick one" to
## "offer every legal one" — and the invariants have to hold across all of them.

var failures := 0
var T := ModuleTable.by_id()

func _initialize() -> void:
	print("ROOTKIT — slot targeting\n")
	compatibility()
	rank_up_only_where_held()
	last_interval_protected()
	empty_exploits_offered()
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

## An equipped module can only rank up where it already sits — offering it
## anywhere else would put the same id in the loadout twice.
func rank_up_only_where_held() -> void:
	var l := _fresh()
	var ts := l.legal_targets(T[&"packet"])
	_check("held module offers exactly one target", ts.size(), 1)
	_check("that target is its own slot", _slots(ts)[0], [0, 0])
	_check("and the action is a rank-up", ts[0].action, Loadout.Rule.RANK_UP)
	l.exploits[0].vector.rank = T[&"packet"].max_rank
	_check("at max rank it offers none", l.legal_targets(T[&"packet"]).size(), 0)

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

## Not-yet-founded exploits are shown, so the board is the whole build.
func empty_exploits_offered() -> void:
	var l := _fresh()
	var ts := _slots(l.legal_targets(T[&"corrupt"]))
	_check("payload offered both slots of exploit 1", ts.has([0, 2]) and ts.has([0, 3]), true)
	_check("payload offered unfounded exploit 2", ts.has([1, 2]), true)
	_check("payload offered unfounded exploit 3", ts.has([2, 3]), true)

func placement_applies() -> void:
	var l := _fresh()
	l.place_at(T[&"corrupt"], 2, 3)
	_check("placing founds the exploit", l.exploits.size(), 3)
	_check("module landed in the chosen slot",
		l.exploits[2].payloads[1].module.id, &"corrupt")
	l.place_at(T[&"corrupt"], 2, 3)
	_check("placing again ranks up", l.exploits[2].payloads[1].rank, 2)
	l.place_at(T[&"keylog"], 2, 3)
	_check("a different module replaces at rank 1",
		l.exploits[2].payloads[1].module.id, &"keylog")
	_check("replacement resets rank", l.exploits[2].payloads[1].rank, 1)
