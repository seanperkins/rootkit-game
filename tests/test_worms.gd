extends SceneTree

## Worms are chains: a steering head plus segments that follow the path it took.

const DT := 1.0 / 60.0
var failures := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	print("ROOTKIT — segmented worms\n")
	await process_frame
	await spawns_as_a_chain()
	await grows_over_the_run()
	await segments_trail_the_head()
	await head_death_decoheres()
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
	run.director.elapsed = 0.0
	run.director.boss_spawned = true
	while run.enemies.count > 0:
		run.enemies.despawn(run.enemies.count - 1)
	return run

func spawns_as_a_chain() -> void:
	var run := await _fresh()
	run._spawn_worm(run.player_pos + Vector2(300, 0))
	_check("a worm spawns as %d entities" % run.WORM_BASE_SEGMENTS,
		run.enemies.count, run.WORM_BASE_SEGMENTS)
	_check("exactly one head", _heads(run), 1)
	var ids := {}
	for i in run.enemies.count:
		ids[run._worm_id[i]] = true
	_check("all segments share one worm id", ids.size(), 1)
	run.queue_free(); await process_frame

func grows_over_the_run() -> void:
	var run := await _fresh()
	_check("length at 0s", run._worm_length(), 2)
	run.director.elapsed = 150.0
	_check("length at 150s", run._worm_length(), 4)
	run.director.elapsed = 600.0
	_check("length is capped", run._worm_length(), run.WORM_MAX_SEGMENTS)
	run.queue_free(); await process_frame

## The tail must follow where the head WENT, not point at the player.
func segments_trail_the_head() -> void:
	var run := await _fresh()
	run.director.elapsed = 300.0          # a long worm
	run.resolved = []                     # no weapons: this tests shape, not survival
	run._spawn_worm(run.player_pos + Vector2(420, 0))
	for t in 120:
		run._physics_process(DT)
	var head := -1
	var tail := -1
	var maxseg := -1
	for i in run.enemies.count:
		if run._worm_seg[i] == 0: head = i
		if run._worm_seg[i] > maxseg:
			maxseg = run._worm_seg[i]; tail = i
	_check("head and tail both alive", head >= 0 and tail >= 0, true)
	if head >= 0 and tail >= 0:
		var spread: float = run.enemies.pos[head].distance_to(run.enemies.pos[tail])
		_check("the chain is strung out, not stacked", spread > 30.0, true)
		var dh: float = run.enemies.pos[head].distance_to(run.player_pos)
		var dt2: float = run.enemies.pos[tail].distance_to(run.player_pos)
		_check("the head leads the tail toward the player", dh < dt2, true)
	run.queue_free(); await process_frame

func head_death_decoheres() -> void:
	var run := await _fresh()
	run.director.elapsed = 300.0
	run._spawn_worm(run.player_pos + Vector2(300, 0))
	for t in 30:
		run._physics_process(DT)
	var before: int = run.enemies.count
	_check("a long worm is several entities", before >= 4, true)
	for i in run.enemies.count:
		if run._worm_seg[i] == 0:
			run.enemies.state[i] = Population.DEAD
	run._step9_recycle()
	_check("killing the head removes the whole worm", run.enemies.count, 0)
	run.queue_free(); await process_frame

func _heads(run: Node2D) -> int:
	var n := 0
	for i in run.enemies.count:
		if run._worm_id[i] != 0 and run._worm_seg[i] == 0:
			n += 1
	return n
