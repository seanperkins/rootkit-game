extends SceneTree

## Gates: the subnet advance as something the player walks rather than something
## that happens to them.

var failures := 0
var finished := {}

const CASES := ["ice_opens_the_gate", "walking_in_starts_transit",
	"the_far_end_is_a_new_subnet", "the_last_subnet_just_wins"]

func _initialize() -> void:
	print("ROOTKIT — gates\n")
	await ice_opens_the_gate()
	await walking_in_starts_transit()
	await the_far_end_is_a_new_subnet()
	await the_last_subnet_just_wins()
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

func walking_in_starts_transit() -> void:
	var r := await _fresh_run()
	_kill_ice(r)
	r.player_health = r._eff_integrity() * 0.2

	# Standing away from it does nothing.
	r.player_pos = r.terrain.gate_pos + Vector2(0, 900)
	r._physics_process(1.0 / 60.0)
	_check("standing away from the gate stays cleared", r.phase, r.Phase.CLEARED)

	r.player_pos = r.terrain.gate_pos
	r._physics_process(1.0 / 60.0)
	_check("stepping into the gate begins transit", r.phase, r.Phase.TRANSIT)
	_check("the corridor is the field in transit", r.field(), r.corridor)
	_check("the corridor has no enemies", r.enemies.count, 0)
	_check("the heal landed on entry",
		r.player_health > r._eff_integrity() * 0.2 + 1.0, true)

	# And it lands ONCE, not per tick.
	var after: float = r.player_health
	for k in 30:
		r._physics_process(1.0 / 60.0)
	_check("and only once", r.player_health <= after + 0.01, true)
	_check("nothing spawns in the corridor", r.enemies.count, 0)
	r.free()
	finished["walking_in_starts_transit"] = true

func the_far_end_is_a_new_subnet() -> void:
	var r := await _fresh_run()
	r.loadout.place_at(ModuleTable.by_id()[&"corrupt"], 0, 2)
	r._recompile()
	r.level = 9
	r.xp = 4
	var mods: int = r.loadout.exploits[0].equipped().size()
	var arena_before: PackedByteArray = r.terrain.solid.duplicate()

	_kill_ice(r)
	r.player_pos = r.terrain.gate_pos
	r._physics_process(1.0 / 60.0)
	_check("in transit", r.phase, r.Phase.TRANSIT)

	r.player_pos = r.corridor.gate_pos
	r._physics_process(1.0 / 60.0)
	_check("the far end returns to fighting", r.phase, r.Phase.FIGHTING)
	_check("on the next subnet", r.subnet, 2)
	_check("with a new arena", r.terrain.solid == arena_before, false)
	_check("the gate shut behind us", r.terrain.gate_open, false)
	_check("the build came through", r.loadout.exploits[0].equipped().size(), mods)
	_check("corrupt is still slotted",
		r.loadout.exploits[0].payloads[0].module.id, &"corrupt")
	_check("level carried", r.level, 9)
	_check("xp carried", r.xp, 4)
	_check("and the player is not standing in rock",
		r.terrain.is_solid(r.player_pos), false)
	_check("the wave clock restarted", r.director.elapsed, 0.0)
	r.free()
	finished["the_far_end_is_a_new_subnet"] = true

func the_last_subnet_just_wins() -> void:
	var r := await _fresh_run()
	r.subnet = SpawnDirector.CAMPAIGN_SUBNETS
	r.terrain.generate(1, r.subnet, r.player_pos, false)
	_check("the last arena has no gate", r.terrain.has_gate, false)
	_kill_ice(r)
	_check("its ICE wins the run outright", r.won, true)
	_check("without entering transit", r.phase, r.Phase.FIGHTING)
	r.free()
	finished["the_last_subnet_just_wins"] = true
