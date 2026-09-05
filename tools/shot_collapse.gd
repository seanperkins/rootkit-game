extends SceneTree

## The collapse walk: the lit route to the gate, and the frontier where the
## floor has already gone. Both are new; only a picture says whether they read.

var run: Node2D
var frames := 0

func _initialize() -> void:
	# --headless is the DUMMY renderer: root.get_texture() is null, save_png
	# throws, and the SCRIPT ERROR skips the `return true` that would quit — so
	# the tool spins forever with no output. Fail here, loudly, instead.
	if DisplayServer.get_name() == "headless":
		push_error("shot tools need a window — run without --headless")
		quit(1)
		return
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.terrain == null:
		return false
	if frames == 20:
		# Clear the subnet, then wind the collapse most of the way down so the
		# frontier is somewhere the camera can see it.
		var b = run.enemy_types[EnemyTable.boss_index(run.subnet)]
		var i: int = run.enemies.spawn(Vector2(200, 0), Vector2.ZERO,
			b.integrity, 48.0, EnemyTable.boss_index(run.subnet))
		run._on_death(i)
		run.collapse_left = run.COLLAPSE_SECONDS * 0.45
		run.terrain.collapse_to(int(float(run.terrain.max_dist) * 0.45))
		# Stand just inside the frontier: safe ground with the void behind.
		var far := -1
		for k in run.terrain.dist_from_gate.size():
			if run.terrain.dist_from_gate[k] == int(float(run.terrain.max_dist) * 0.42):
				far = k
				break
		if far >= 0:
			run.player_pos[run.local_slot] = run.terrain.origin + Vector2(
				float(far % run.terrain.w) + 0.5,
				float(far / run.terrain.w) + 0.5) * Terrain.CELL
		run._physics_process(1.0 / 60.0)
	if frames == 50:
		root.get_texture().get_image().save_png("/tmp/collapse_1_frontier.png")
		# And from the gate end, looking back up the lit route.
		var g = run.terrain.gate()
		run.player_pos[run.local_slot] = g.pos - g.dir * 520.0
		run._physics_process(1.0 / 60.0)
	if frames == 80:
		root.get_texture().get_image().save_png("/tmp/collapse_2_route.png")
		print("route %d cells, void runs %d, max_dist %d" % [
			run._route.size(),
			run._void_runs(Rect2(run.terrain.origin, run.terrain.size)).size(),
			run.terrain.max_dist])
		return true
	return false
