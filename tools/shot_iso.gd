extends SceneTree
var run: Node2D
var frames := 0
func _initialize() -> void:
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.enemies == null: return false
	if frames == 5:
		run.level_up_offered.connect(func(c): run.choose_card(c[0][0], Loadout.best_target(c[0][1])))
		# Do NOT jump elapsed: every wave would dump its whole backlog in one
		# tick, since spawns are derived from elapsed rather than accumulated.
		run.player_pos = Vector2(1180, 640)     # near corner, so the slab faces are in frame
	if frames > 20:
		# kite, so the player survives long enough to photograph
		var flee := Vector2.ZERO
		for i in run.enemies.count:
			var d: Vector2 = run.player_pos - run.enemies.pos[i]
			var dl := d.length()
			if dl < 200.0 and dl > 0.01:
				flee += d / dl * (200.0 - dl)
		run.input_override = flee.normalized() if flee.length() > 0.01 else Vector2(0.4, 0.3)
	if frames == 1500:
		root.get_texture().get_image().save_png("/tmp/rootkit_iso.png")
		print("enemies=%d shards=%d lvl=%d" % [run.enemies.count, run.shards.count, run.level])
		return true
	return false
