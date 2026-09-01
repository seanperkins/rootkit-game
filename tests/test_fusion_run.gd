extends SceneTree

## Fusion through the REAL tick, end to end.
##
## Every other fusion assertion lives in a unit suite: the recipe table matches,
## the loadout fuses, the screen has buttons. None of them proves a run can
## REACH a fusion by playing, or that the fused weapon does anything afterwards.
##
## Task 0 of this feature existed because mine blasts were green in every suite
## and dealt zero damage in the actual game — the queue was cleared between the
## detonation and the drain. This suite is that lesson applied to fusion itself:
## it drives run._physics_process rather than a model of it, and the last check
## is simply "did an enemy lose integrity".
##
## The one thing it fakes is walking: it pins the player onto the block rather
## than steering there, because reaching it is the player's job, not the engine's.

const DT := 1.0 / 60.0
var fails := 0

func _ck(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		fails += 1

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — fusion through the real tick\n")
	await process_frame

	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO

	# Build a real maxed recipe row: packet + interval + fork_bomb -> frag_packet.
	# frag_packet is INTERVAL-triggered, so it fires unconditionally and this
	# probe does not depend on a kill to see it work.
	var mods := ModuleTable.by_id()
	run.loadout.exploits[0].vector = EquippedModule.new(mods[&"packet"], 5)
	run.loadout.exploits[0].trigger = EquippedModule.new(mods[&"interval"], 5)
	run.loadout.exploits[0].payloads[0] = EquippedModule.new(mods[&"fork_bomb"], 5)
	run._recompile()
	_ck("the row matches a recipe", run.loadout.matched_recipes().size(), 1)
	_ck("and it can fuse", run.loadout.can_fuse(0,
		run.loadout.matched_recipes()[0][1].fused), true)

	# A real fusion screen, taken the way the player takes it.
	var ui: CanvasLayer = null
	for c in run.get_children():
		if c is CanvasLayer and c.has_method("bind"):
			ui = c
	_ck("the run has a HUD", ui != null, true)

	# Force a block to completion by standing in it, through the REAL tick.
	run.blocks.elapsed = Blocks.FIRST_SPAWN
	run.blocks.next_at = 0.0
	var ticks := 0
	while not run.blocks.alive and ticks < 240:
		run._physics_process(DT)
		ticks += 1
	_ck("a block spawned during real ticks", run.blocks.alive, true)

	# Teleport the player onto it and hold. This is the only thing the probe
	# fakes — walking there is the player's job, not the engine's.
	run.player_pos = run.blocks.pos
	var held := 0
	while run.blocks.alive and held < 1200 and not run.paused:
		run.player_pos = run.blocks.pos
		run._physics_process(DT)
		held += 1
	_ck("holding it completed the block", run.blocks.alive, false)
	_ck("and the run paused for the fusion screen", run.paused, true)
	_ck("the screen is showing", ui.fusion_buttons().size() > 0, true)

	# Press the button, exactly as the keyboard would.
	ui.fusion_buttons()[0].emit_signal("pressed")
	await process_frame
	_ck("the row fused", run.loadout.exploits[0].head_is_fused(), true)
	_ck("into frag_packet", run.loadout.exploits[0].vector.module.id,
		&"frag_packet")
	_ck("and the run resumed", run.paused, false)
	_ck("the fused row is not inert", run.resolved[0].inert, false)
	_ck("it carries the recipe's blast", run.resolved[0].blast_radius > 0.0, true)

	# The three ids are free: each is placeable again.
	_ck("packet is placeable again",
		run.loadout.legal_targets(mods[&"packet"]).is_empty(), false)
	_ck("fork_bomb is placeable again",
		run.loadout.legal_targets(mods[&"fork_bomb"]).is_empty(), false)

	# Does the fused weapon actually KILL anything? Put an enemy in front of it
	# and run the real tick. This is the question Task 0 was written about.
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	run.terrain.zone.fill(0)
	var at: Vector2 = run.player_pos + Vector2(120.0, 0.0)
	var e: int = run.enemies.spawn(at, Vector2.ZERO, 400.0, run.ENEMY_RADIUS, 0)
	var before: float = run.enemies.integrity[e]
	for i in 180:
		if run.enemies.count == 0:
			break
		run._physics_process(DT)
	var after: float = run.enemies.integrity[e] if run.enemies.count > 0 else 0.0
	print("  .. integrity %.1f -> %.1f" % [before, after])
	_ck("the fused weapon damages an enemy", after < before, true)

	print("")
	if fails == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % fails)
	quit(1 if fails > 0 else 0)
