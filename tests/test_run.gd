extends SceneTree

## Plays a whole subnet headless, auto-picking cards, and asserts the run loop
## actually produces a game: enemies spawn, damage lands, levels happen, the
## boss arrives, and the tick never leaks entities.

const DT := 1.0 / 60.0
var failures := 0
var run: Node2D
var picks := 0

func _initialize() -> void:
	print("ROOTKIT — full subnet smoke test\n")
	SaveGame.use_fresh_state()
	var scene: PackedScene = load("res://scenes/main.tscn")
	run = scene.instantiate()
	root.add_child(run)
	# add_child during _initialize leaves the node outside the tree, so _ready
	# never fires. One frame brings the tree up.
	await process_frame
	run.level_up_offered.connect(_auto_pick)

	var ticks := int(SpawnDirector.SUBNET_SECONDS / DT) + 5400   # + 90s of boss
	var t := 0
	while t < ticks and run.alive and not run.won:
		run.input_override = _autopilot()
		run._physics_process(DT)
		t += 1
	var mins := t * DT

	print("  simulated %.1f s (%d ticks)" % [mins, t])
	print("  spawned %d, dropped %d" % [run.director.spawned, run.director.dropped])
	print("  kills %d  flips %d  level %d  salvage %d" % [
		run.kills, run.flips, run.level, run.salvage])
	print("  live: enemies %d  projectiles %d  shards %d  botnet %d" % [
		run.enemies.count, run.projectiles.count, run.shards.count, run.botnet.count])
	print("  card picks %d" % picks)
	print("  boss spawned: %s" % run.director.boss_spawned)
	print("  outcome: %s" % ("WON" if run.won else ("DIED" if not run.alive else "timeout")))
	print("")

	_check("enemies spawned", run.director.spawned > 200, true)
	_check("damage landed (kills > 0)", run.kills > 0, true)
	_check("player levelled up", run.level > 1, true)
	_check("cards were offered", picks > 0, true)
	_check("enemy pool within cap", run.enemies.count <= run.MAX_ENEMIES, true)
	_check("projectile pool within cap", run.projectiles.count <= run.MAX_PROJECTILES, true)
	_check("shard pool within cap", run.shards.count <= run.MAX_SHARDS, true)
	_check("no flipped enemies left in the swarm", _flipped_left(), 0)
	_check("boss spawned", run.director.boss_spawned, true)
	_check("run reached a terminal state", run.won or not run.alive, true)

	print("")
	if failures == 0: print("  PASS — all checks")
	else: print("  FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)

## Kite away from the swarm, drift toward loose shards. Not good play — just
## enough that the loop is exercised by a moving player rather than a corpse.
func _autopilot() -> Vector2:
	var flee := Vector2.ZERO
	var n := 0
	for i in run.enemies.count:
		var d: Vector2 = run.player_pos - run.enemies.pos[i]
		var dl := d.length()
		if dl < 190.0 and dl > 0.01:
			flee += d / dl * (190.0 - dl)
			n += 1
	var dir := flee.normalized() if n > 0 else Vector2.ZERO
	if n == 0 and run.shards.count > 0:
		dir = (run.shards.pos[0] - run.player_pos).normalized()
	var to_centre: Vector2 = Vector2.ZERO - run.player_pos
	if to_centre.length() > 1100.0:
		dir = (dir + to_centre.normalized() * 1.6).normalized()
	return dir

## A FLIPPED enemy must retire its slot at recycle. Freeing only DEAD leaves
## them in the swarm permanently, filling the 600-pool.
func _flipped_left() -> int:
	var n := 0
	for i in run.enemies.count:
		if run.enemies.state[i] != Population.ALIVE:
			n += 1
	return n

func _auto_pick(cards: Array) -> void:
	picks += 1
	run.choose_card(cards[0][0], cards[0][1])

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1
