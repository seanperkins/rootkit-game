extends SceneTree

## flips stayed at 0 across a whole autopiloted run, which could mean the
## corruption path is broken or just that the random card picks never took it.
## This forces the build and answers the question directly.

const DT := 1.0 / 60.0

func _initialize() -> void:
	SaveGame.use_fresh_state()
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame

	var table := ModuleTable.by_id()
	var p: Loadout.Placement = run.loadouts[run.local_slot].resolve(table[&"corrupt"])
	run.loadouts[run.local_slot].apply(table[&"corrupt"], p)
	run.loadouts[run.local_slot].exploits[0].holds(&"corrupt").rank = 5
	run._recompile()

	var r: ResolvedExploit = run.resolved[0]
	print("corrupt build: dmg %.1f  corruption %.1f  tag=%s" % [
		r.damage, r.corruption, r.has_tag(&"corruption")])

	run.input_override = Vector2.ZERO
	var t := 0
	while run.enemies.count == 0 and t < 600:       # warm up until the director has spawned
		run._physics_process(DT); t += 1
	# The packet fires along facing now, so face the nearest enemy once; the
	# swarm closes from every bearing after that and the flips follow.
	var nearest := -1
	var best := INF
	for i in run.enemies.count:
		var d: float = run.enemies.pos[i].distance_squared_to(run.player_pos[run.local_slot])
		if d < best:
			best = d; nearest = i
	if nearest >= 0:
		run.input_override = (run.enemies.pos[nearest] - run.player_pos[run.local_slot]).normalized()
		run._physics_process(DT); t += 1
		run.input_override = Vector2.ZERO
	while t < 3600 and run.alive:
		run._physics_process(DT)
		t += 1

	print("after %.0fs: kills %d  flips %d  botnet %d" % [t * DT, run.kills[run.local_slot], run.flips[run.local_slot], run.botnet.count])
	var ok: bool = run.flips[run.local_slot] > 0
	print("")
	print("  PASS — corruption flips enemies into the botnet" if ok
		else "  FAIL — corruption never flipped anything")
	quit(0 if ok else 1)
