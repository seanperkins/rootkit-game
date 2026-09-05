extends "res://tools/shot_entity_designs.gd"

## Actual boss materials at five health levels, with the normal game scale.
## Test saves and window check are inherited from the entity capture tool.
func _process(_dt: float) -> bool:
	if run == null or run.terrain == null:
		return false
	frames += 1
	if frames == 5:
		run.user_paused = true
		run.input_override = Vector2.ZERO
		run.enemies.count = 0
		run.projectiles.count = 0
		for child in run.get_children():
			if child is CanvasLayer:
				child.hide()
		for name in ["Props", "ZonePanels", "Backdrop"]:
			run.get_node(name).hide()
		labels = Captions.new()
		run.add_child(labels)
		var center: Vector2 = run.player_pos[0]
		_label(center + run.from_iso(Vector2(0, -265)), "BOSS INTEGRITY / POWERED ARMOR", 22)
		var health := [1.0, 0.75, 0.5, 0.25, 0.05]
		for col in health.size():
			_label(center + run.from_iso(Vector2(-290 + col * 170, -220)),
				"%d%%" % int(health[col] * 100), 15)
		for row in 5:
			var ti: int = [EnemyTable.boss_index(run.subnet), 8, 9, 10, 11][row]
			var y := -165 + row * 95
			_label(center + run.from_iso(Vector2(-450, y + 5)), String(run.enemy_types[ti].id))
			for col in health.size():
				var at: Vector2 = center + run.from_iso(Vector2(-290 + col * 170, y))
				var idx: int = run.enemies.spawn(at, Vector2(-40, -40), 100.0 * health[col], run.ENEMY_RADIUS, ti)
				run._clear_ai(idx)
				run._spawn_hp[idx] = 100.0
		run._depth_sort()
		run._snapshot_render_state()
		# Move only the craft out of the lineup; keep the camera on this view.
		run.player_render_pos[0] = center + run.from_iso(Vector2(0, 800))
		run.set_process(false)
		run._update_renderers()
		run.queue_redraw()
		labels.queue_redraw()
	if frames == 40:
		_save("boss-integrity")
		run.queue_free()
		await process_frame
		quit()
	return false
