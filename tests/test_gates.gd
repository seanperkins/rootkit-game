extends SceneTree

## Gates: the subnet advance as something the player walks rather than something
## that happens to them.

var failures := 0
var finished := {}

const CASES := ["ice_opens_the_gate"]

func _initialize() -> void:
	print("ROOTKIT — gates\n")
	await ice_opens_the_gate()
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

func _kill_ice(r: Node2D) -> void:
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)

func ice_opens_the_gate() -> void:
	var r := await _fresh_run()
	_check("a run starts fighting", r.phase, r.Phase.FIGHTING)
	_check("and its gate is shut", r.terrain.gate_open, false)
	_kill_ice(r)
	_check("killing ICE clears the subnet", r.phase, r.Phase.CLEARED)
	_check("which opens the gate", r.terrain.gate_open, true)
	_check("but does not win the run", r.won, false)
	_check("and does not advance the subnet on its own", r.subnet, 1)

	# Spawning halts. The director must not step at all in CLEARED.
	var before: int = r.spawned_total()
	var elapsed_before: float = r.director.elapsed
	# Away from the gate, so lingering is what is being measured.
	r.player_pos = r.terrain.gate_pos + Vector2(0, 900)
	for k in 600:
		r._physics_process(1.0 / 60.0)
	_check("no spawns while cleared", r.spawned_total(), before)
	_check("and the wave clock is halted", r.director.elapsed, elapsed_before)
	_check("lingering does not advance anything", r.subnet, 1)
	_check("and the gate stays open", r.terrain.gate_open, true)
	r.free()
	finished["ice_opens_the_gate"] = true
