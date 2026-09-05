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
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
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
	var ground_before: PackedByteArray = r.terrain.solid.duplicate()
	_kill_ice(r)
	var t: Terrain = r.terrain
	var g: Terrain.Gate = t.gate()

	# The corridor is open ground on the SAME grid, running from the arena's
	# edge to the NEXT arena's edge. No second Terrain, so no teleport.
	_check("the gate mouth is open", t.is_solid(g.pos), false)
	_check("and so is the ground beyond it",
		t.is_solid(g.pos + g.dir * 200.0), false)
	_check("out to the corridor end", t.is_solid(g.end), false)
	_check("which lands on the next arena's edge",
		t.arenas[1].grow(0.5).has_point(g.end), true)
	_check("and the floor carries on inside it",
		t.is_solid(g.end + g.dir * 200.0), false)
	_check("but not to the side of the corridor",
		t.is_solid(g.pos + g.dir * 200.0
			+ Vector2(-g.dir.y, g.dir.x) * 260.0), true)

	# Stepping into the gate does NOT relocate the player.
	r.player_pos[r.local_slot] = g.pos
	var before: Vector2 = r.player_pos[r.local_slot]
	r._physics_process(1.0 / 60.0)
	_check("touching the gate does not teleport", r.player_pos[r.local_slot], before)
	_check("and the subnet has not advanced", r.subnet, 1)

	# Nor does standing exactly ON the threshold. The advance shuts the gate,
	# and shutting it around a player still in the corridor would wall them in.
	r.player_pos[r.local_slot] = g.end
	r._physics_process(1.0 / 60.0)
	_check("stopping on the threshold does not advance", r.subnet, 1)
	_check("and does not strand the player",
		r.terrain.is_solid(r.player_pos[r.local_slot]), false)

	# The first step onto the next arena's own floor is what advances — and it
	# advances in place.
	var arrived: Vector2 = g.end + g.dir * 8.0
	r.player_pos[r.local_slot] = arrived
	r._physics_process(1.0 / 60.0)
	_check("the first step onto the next arena opens a vote", r.route_pending, true)
	r._apply_first(r.local_slot)
	_check("the route choice advances", r.subnet, 2)
	_check("and stays fighting", r.phase, r.Phase.FIGHTING)
	_check("the player is exactly where they walked to", r.player_pos[r.local_slot], arrived)
	_check("standing on the next arena", r.terrain.current, 1)
	_check("whose ground was already plotted, not rebuilt",
		r.terrain.solid, ground_before)
	_check("the gate shut behind us", g.open, false)
	_check("and bars the way back", r.terrain.is_solid(g.pos + g.dir * 200.0), true)
	_check("the build came through", r.loadouts[r.local_slot].exploits[0].equipped().size(), mods)
	_check("level carried", r.level, 9)
	_check("xp carried", r.xp, 4)
	_check("no shards followed", r.shards.count, 0)
	r.free()
	finished["walking_out_is_continuous"] = true

func the_last_subnet_just_wins() -> void:
	var r := await _fresh_run()
	r.subnet = SpawnDirector.CAMPAIGN_SUBNETS
	# Walk the whole way through, so `subnet` and the terrain's own idea of
	# where the player is stay the one fact they are supposed to be.
	r.terrain.enter_next()
	r.terrain.enter_next()
	_check("the last arena has no gate", r.terrain.has_gate(), false)
	_kill_ice(r)
	_check("its ICE wins the run outright", r.won, true)
	_check("without entering transit", r.phase, r.Phase.FIGHTING)
	r.free()
	finished["the_last_subnet_just_wins"] = true
