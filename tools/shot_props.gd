extends SceneTree

## Walls as translucent objects standing over the swarm: the back edges visible
## through the faces, and enemies drawn behind them rather than on top.

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
		run.input_override = Vector2.ZERO
		run.director.elapsed = 999.0
		run.director.boss_spawned = true
		while run.enemies.count > 0:
			run.enemies.despawn(run.enemies.count - 1)
		# The biggest wall near the middle of the arena, with the swarm packed
		# ON its footprint so occlusion is actually in frame. A ring around a
		# wall proves nothing: nothing overlaps.
		var best := Rect2()
		var biggest := -1.0
		for entry in run.terrain.rects:
			if entry[1] != Terrain.Kind.WALL:
				continue
			var w: Rect2 = entry[0]
			if w.get_center().length() > 1500.0:
				continue
			var area := w.size.x * w.size.y
			if area > biggest:
				biggest = area
				best = w
		var c := best.get_center()
		run.player_pos = c + Vector2(190, 190)
		for k in 26:
			var a := TAU * k / 26.0
			run.enemies.spawn(c + Vector2(cos(a), sin(a)) * 34.0, Vector2.ZERO,
				999.0, run.ENEMY_RADIUS, k % 3)
		# And one squarely behind it, up-left, which is where "behind" is here.
		run.enemies.spawn(c - Vector2(26, 26), Vector2.ZERO, 999.0,
			run.ENEMY_RADIUS, 0)
		run._update_renderers()
	if frames == 50:
		root.get_texture().get_image().save_png("/tmp/props_1_wall.png")
		# And the gate, whose posts are the tallest boxes in the game.
		run.terrain.open_gate()
		var g = run.terrain.gate()
		run.player_pos = g.pos - g.dir * 200.0
		while run.enemies.count > 0:
			run.enemies.despawn(run.enemies.count - 1)
		for k in 24:
			var a2 := TAU * k / 24.0
			run.enemies.spawn(g.pos + Vector2(cos(a2), sin(a2)) * 110.0,
				Vector2.ZERO, 999.0, run.ENEMY_RADIUS, k % 3)
		run._update_renderers()
	if frames == 80:
		root.get_texture().get_image().save_png("/tmp/props_2_gate.png")
		print("walls %d, enemies %d" % [run.terrain.rects.size(), run.enemies.count])
		return true
	return false
