extends SceneTree

## The cascade dispatch loop in run.gd — the layer six suites did not cover.
##
## HitQueue holds "adjudicated exactly once" and test_drain proves it. But the
## queue's only consumer scanned every enemy on every pass, matching on state
## that persists for the whole tick, so an enemy resolved in pass 1 was paid
## again in every later productive pass: kills, shards, ON_KILL cascades,
## lifesteal, botnet spawns. Every existing assertion was a threshold
## (`kills > 0`, pools within cap) that inflation passes trivially.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — cascade dispatch\n")
	await process_frame
	await one_death_pays_once()
	await cascade_pays_each_corpse_once()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d case(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _fresh() -> Node2D:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0        # no ambient spawning during the probe
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	return run

func _place(run: Node2D, n: int, at: Vector2) -> void:
	var t = run.enemy_types[0]           # daemon: 10 integrity, 1 shard
	for i in n:
		run.enemies.spawn(at + Vector2(i * 14, 0), Vector2.ZERO, t.integrity,
			run.ENEMY_RADIUS, 0)

## Baseline: no cascade, so a single pass. Proves the harness itself is honest.
func one_death_pays_once() -> void:
	var run := await _fresh()
	_place(run, 1, run.player_pos + Vector2(20, 0))
	var before: int = run.kills
	for t in 90:
		run._physics_process(DT)
		if run.kills > before:
			break
	_check("one enemy, one kill", run.kills - before, 1)
	run.queue_free()
	await process_frame

## The real case: an ON_KILL exploit turns one death into more deaths in a later
## pass, which is exactly when the old loop re-paid the earlier corpse.
func cascade_pays_each_corpse_once() -> void:
	var run := await _fresh()
	var table := ModuleTable.by_id()

	# exploit_02 = broadcast + on_kill, wide and lethal: one death detonates the
	# rest in pass 2.
	var ex := Exploit.new()
	ex.place(table[&"broadcast"])
	ex.place(table[&"on_kill"])
	ex.place(table[&"buffer_overflow"])
	ex.vector.rank = 5
	ex.payloads[0].rank = 5
	run.loadout.exploits.append(ex)
	run._recompile()

	_place(run, 3, run.player_pos + Vector2(26, 0))
	var k0: int = run.kills
	var s0: int = run.shards.count + run.xp

	for t in 180:
		run._physics_process(DT)
		if run.enemies.count == 0:
			break

	_check("3 enemies produce exactly 3 kills", run.kills - k0, 3)
	_check("3 enemies produce exactly 3 shards", run.shards.count + run.xp - s0, 3)
	_check("field cleared", run.enemies.count, 0)
	run.queue_free()
	await process_frame
