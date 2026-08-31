extends SceneTree

## Mini-bosses: the schedule, the four types, and each signature mechanic.

var failures := 0
var finished := {}
const CASES := ["the_schedule_fires_each_once", "the_four_exist_and_ice_is_still_last"]

func _initialize() -> void:
	print("ROOTKIT — mini-bosses\n")
	the_schedule_fires_each_once()
	the_four_exist_and_ice_is_still_last()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh_run() -> Node2D:
	SaveGame.use_fresh_state()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(r)
	await process_frame
	return r

func _type_index(id: StringName) -> int:
	var all := EnemyTable.all()
	for i in all.size():
		if all[i].id == id:
			return i
	return -1

func the_schedule_fires_each_once() -> void:
	var d := SpawnDirector.new()
	var seen := []
	var t := 0.0
	while t < SpawnDirector.SUBNET_SECONDS:
		for idx in d.due_minibosses(1.0 / 60.0):
			seen.append([d.elapsed, idx])
		d.elapsed += 1.0 / 60.0
		t += 1.0 / 60.0
	_check("four mini-bosses arrive", seen.size(), SpawnDirector.MINIBOSS_TIMES.size())

	# None in the last minute: ICE owns the subnet's ending.
	var late := 0
	for row in seen:
		if float(row[0]) > SpawnDirector.SUBNET_SECONDS - 60.0:
			late += 1
	_check("none in the last minute", late, 0)

	# A single tick that crosses a boundary must not double-fire.
	var d2 := SpawnDirector.new()
	d2.elapsed = SpawnDirector.MINIBOSS_TIMES[0] - 0.001
	var first: Array = d2.due_minibosses(0.5)
	d2.elapsed += 0.5
	var again: Array = d2.due_minibosses(0.5)
	_check("the crossing fires once", first.size(), 1)
	_check("and not again on the next step", again.size(), 0)

	d2.reset()
	_check("reset rearms them", d2.miniboss_fired[0], 0)
	finished["the_schedule_fires_each_once"] = true

func the_four_exist_and_ice_is_still_last() -> void:
	var all := EnemyTable.all()
	var by_id := {}
	for k in all.size():
		by_id[all[k].id] = all[k]
	for id in SpawnDirector.MINIBOSS_IDS:
		_check("%s is in the table" % id, by_id.has(id), true)
		if by_id.has(id):
			# Between firewall and ICE: a set-piece, not a boss.
			_check("%s is tougher than a firewall" % id,
				by_id[id].integrity > by_id[&"firewall"].integrity, true)
			_check("%s is weaker than ICE" % id,
				by_id[id].integrity < by_id[&"ice"].integrity, true)
			# Flippable, unlike ICE — a corruption build should be able to turn
			# a set-piece, which is most of why that build is exciting.
			_check("%s is flippable" % id,
				by_id[id].corruption_threshold < 1e17, true)

	# These are INDICES the boss spawn, the win condition and the flip guard all
	# read. Inserting a type above them repoints them silently.
	_check("ICE is still last", all[EnemyTable.ICE].id, &"ice")
	_check("and it is the final row", EnemyTable.ICE, all.size() - 1)

	# The schedule resolves to the real types, not to daemon by fallback.
	var d := SpawnDirector.new()
	var fired: Array = []
	d.elapsed = SpawnDirector.MINIBOSS_TIMES[0]
	fired = d.due_minibosses(0.1)
	_check("the schedule resolves a real mini-boss",
		all[fired[0]].id, SpawnDirector.MINIBOSS_IDS[0])
	finished["the_four_exist_and_ice_is_still_last"] = true
