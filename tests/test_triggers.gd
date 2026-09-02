extends SceneTree

## Does each TriggerKind actually put damage on the board?

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — trigger firing\n")
	await process_frame
	for spec in [[&"interval", "INTERVAL"], [&"on_hit", "ON_HIT"],
			[&"on_kill", "ON_KILL"], [&"on_damage_taken", "ON_DAMAGE_TAKEN"]]:
		await fires(spec[0], spec[1])
	await rate_limited()
	print("")
	if failures == 0: print("  PASS — every trigger fires")
	else: print("  FAIL — %d trigger(s) never fired" % failures)
	quit(1 if failures > 0 else 0)

## ON_KILL had no rate limit: it fired once per adjudicated death, so in a swarm
## it ran continuously, bounded only by the per-tick fire budget. It must now
## respect the exploit's cooldown like every other trigger.
func rate_limited() -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)

	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"])
	ex.place(t[&"on_kill"])
	run.loadouts[run.local_slot].exploits.append(ex)
	run._recompile()
	var idx: int = run._gid(run.local_slot, run.loadouts[run.local_slot].exploits.size() - 1)
	var cd: float = run.resolved[idx].cooldown

	# Face +X for one tick: the ring has an enemy there, so the default packet
	# (the kill source) connects instead of relying on the initial facing.
	run.input_override = Vector2(1.0, 0.0)
	run._physics_process(DT)
	run.input_override = Vector2.ZERO

	var fires := 0
	var seconds := 4.0
	for tick in int(seconds / DT):
		# keep the field saturated so kills happen constantly
		while run.enemies.count < 40:
			var a: float = TAU * run.enemies.count / 40.0
			run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(cos(a), sin(a)) * 55.0,
				Vector2.ZERO, 1.0, run.ENEMY_RADIUS, 0)
		run._physics_process(DT)
		fires += run._trigger_fires.get(idx, 0)
		run._trigger_fires[idx] = 0

	var ceiling := int(seconds / cd) + 2
	print("  on_kill fired %d times in %.0fs (cooldown %.2fs, ceiling %d)" % [
		fires, seconds, cd, ceiling])
	_check("on_kill respects its cooldown", fires <= ceiling, true)
	_check("on_kill still fires at all", fires > 0, true)
	run.queue_free()
	await process_frame

## exploit_01 is a weak interval packet (so ON_KILL/ON_HIT have a source event to
## respond to); exploit_02 carries the trigger under test on a broadcast, and we
## measure the damage IT deals.
func fires(trigger_id: StringName, label: String) -> void:
	var run: Node2D = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.input_override = Vector2.ZERO
	run.director.elapsed = 999.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)

	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"])
	ex.place(t[trigger_id])
	ex.place(t[&"buffer_overflow"])
	run.loadouts[run.local_slot].exploits.append(ex)
	run._recompile()
	var idx: int = run._gid(run.local_slot, run.loadouts[run.local_slot].exploits.size() - 1)

	# A ring of enemies inside the broadcast radius, plus fodder for on_kill.
	for k in 12:
		var a := TAU * k / 12.0
		run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(cos(a), sin(a)) * 60.0,
			Vector2.ZERO, 40.0, run.ENEMY_RADIUS, 0)

	# Face +X for one tick so the packet row (the on_kill / on_hit source)
	# fires into the ring rather than depending on the initial facing.
	run.input_override = Vector2(1.0, 0.0)
	run._physics_process(DT)
	run.input_override = Vector2.ZERO

	var fired := 0
	for tick in 600:
		var before: int = run.queue.count
		run._physics_process(DT)
		fired += run._trigger_fires.get(idx, 0)
		run._trigger_fires[idx] = 0
		if run.enemies.count == 0:
			break
	_check("%-16s fires" % label, fired > 0, true)
	run.queue_free()
	await process_frame

func _check(label: String, got, want) -> void:
	if got == want:
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s" % label)
		failures += 1
