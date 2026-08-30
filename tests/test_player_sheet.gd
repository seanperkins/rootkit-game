extends SceneTree

## run.gd declares player_health and pickup_radius as declaration initialisers,
## which Godot evaluates BEFORE _ready() reads the save. Miss the re-seed and
## every run starts at the base value regardless of what the player bought —
## 1,950 salvage per line that silently does nothing, which is the exact bug
## class this whole feature is named after.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	print("ROOTKIT — player sheet\n")
	await process_frame
	await integrity_seeded()
	await pickup_radius_seeded()
	await clock_speed_from_meta()
	print("")
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-5):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _clear_buffs() -> void:
	for name in ["cpu_cycles", "cooling", "memory", "firewall",
			"encryption", "bus_speed", "addressing", "bandwidth"]:
		SaveGame.load_state()["buffs"][name] = 0

func integrity_seeded() -> void:
	_clear_buffs()
	SaveGame.load_state()["buffs"]["memory"] = 10
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	_check("memory r10 starts the run at 180", run.player_health, 180.0)
	_check("effective max integrity is 180", run._eff_integrity(), 180.0)
	run.queue_free()
	await process_frame
	_clear_buffs()

func pickup_radius_seeded() -> void:
	_clear_buffs()
	SaveGame.load_state()["buffs"]["bandwidth"] = 10
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	_check("bandwidth r10 gives pickup radius 90", run.pickup_radius, 90.0)
	run.queue_free()
	await process_frame
	_clear_buffs()

## bus_speed feeds clock_speed through player_sheet(), a DIFFERENT source from
## the ward path. Both terminate at the same line in the move step, and both
## need their own assertion.
func clock_speed_from_meta() -> void:
	_clear_buffs()
	var slow: float = await _distance_travelled()
	SaveGame.load_state()["buffs"]["bus_speed"] = 10
	var fast: float = await _distance_travelled()
	_check("bus_speed r10 moves the player farther", fast > slow * 1.2, true)
	_clear_buffs()

func _distance_travelled() -> float:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	run.input_override = Vector2.RIGHT
	var start: Vector2 = run.player_pos
	for tick in 60:
		run._physics_process(DT)
	var moved: float = run.player_pos.distance_to(start)
	run.queue_free()
	await process_frame
	return moved
