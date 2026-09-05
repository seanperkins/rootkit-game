extends SceneTree

## Gates: the subnet advance as something the player walks rather than something
## that happens to them.

var failures := 0
var finished := {}

const CASES := ["ice_opens_the_gate", "walking_out_is_continuous",
	"the_last_subnet_just_wins"]

func _initialize() -> void:
	print("ROOTKIT — gates\n")
	await ice_opens_the_gate()
	await walking_out_is_continuous()
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
	var b = r.enemy_types[EnemyTable.boss_index(r.subnet)]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.boss_index(r.subnet))
	r._on_death(i)
	# The boss kill arms a hitstop that freezes the world for a few ticks. These
	# cases step the tick directly to assert gate-walking mechanics, so drain it.
	r.hitstop_ticks = 0

func ice_opens_the_gate() -> void:
	var r := await _fresh_run()
	_check("a run starts fighting", r.phase, r.Phase.FIGHTING)
	_check("and its gate is shut", r.terrain.gate().open, false)
	_kill_ice(r)
	_check("killing ICE clears the subnet", r.phase, r.Phase.CLEARED)
	_check("which opens the gate", r.terrain.gate().open, true)
	_check("but does not win the run", r.won, false)
	_check("and does not advance the subnet on its own", r.subnet, 1)

	# Spawning halts. The director must not step at all in CLEARED.
	var before: int = r.spawned_total()
	var elapsed_before: float = r.director.elapsed
	# Away from the gate, so lingering is what is being measured.
	r.player_pos[r.local_slot] = r.terrain.gate().pos - r.terrain.gate().dir * 900.0
	for k in 600:
		r._physics_process(1.0 / 60.0)
	_check("no spawns while cleared", r.spawned_total(), before)
	_check("and the wave clock is halted", r.director.elapsed, elapsed_before)
	_check("lingering does not advance anything", r.subnet, 1)
	_check("and the gate stays open", r.terrain.gate().open, true)
	r.free()
	finished["ice_opens_the_gate"] = true

func walking_out_is_continuous() -> void:
	var r := await _fresh_run()
	r.loadouts[r.local_slot].place_at(ModuleTable.by_id()[&"corrupt"], 0, 2)
	r._recompile()
	r.level = 9
	r.xp = 4
	var mods: int = r.loadouts[r.local_slot].exploits[0].equipped().size()
	_kill_ice(r)
	var t: Terrain = r.terrain
	var g: Terrain.Gate = t.gate()

	_check("only this subnet is allocated", t.arenas.size(), 1)
	_check("the transfer pad has no bridge", g.corridor.has_area(), false)
	r.player_pos[r.local_slot] = g.pos + Vector2(100, 0)
	r._step2c_gate()
	_check("outside the pad does not open a vote", r.route_pending, false)
	r.player_pos[r.local_slot] = g.pos
	r._step2c_gate()
	_check("entering the pad opens the vote", r.route_pending, true)
	_check("the destination does not exist yet", r.terrain, t)
	r._apply_first(r.local_slot)
	_check("a choice starts the charge animation", r.transfer_ticks, 90)
	for k in 90: r._step_transfer()
	_check("the transfer advances", r.subnet, 2)
	_check("and stays fighting", r.phase, r.Phase.FIGHTING)
	_check("arrival uses the reserved spawn", r.player_pos[r.local_slot], r.terrain.spawner_pos(0, r.local_slot))
	_check("the old terrain is replaced", r.terrain != t, true)
	_check("interpolation starts at arrival", r.player_prev_pos[r.local_slot], r.player_pos[r.local_slot])
	_check("the build came through", r.loadouts[r.local_slot].exploits[0].equipped().size(), mods)
	_check("level carried", r.level, 9)
	_check("xp carried", r.xp, 4)
	_check("no shards followed", r.shards.count, 0)
	r.free()
	finished["walking_out_is_continuous"] = true

func the_last_subnet_just_wins() -> void:
	var r := await _fresh_run()
	r._advance_subnet()
	r._advance_subnet()
	_check("the last arena has no gate", r.terrain.has_gate(), false)
	_kill_ice(r)
	_check("its ICE wins the run outright", r.won, true)
	_check("without entering transit", r.phase, r.Phase.FIGHTING)
	r.free()
	finished["the_last_subnet_just_wins"] = true
