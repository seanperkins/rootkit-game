extends SceneTree

func snap(name: String) -> void:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.tmp/" + name + ".png")

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	await process_frame
	var menu: Control = load("res://scenes/main.tscn").instantiate()
	root.add_child(menu)
	await snap("expansion-programs")
	menu.free()
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	var desc := NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"version": "dev", "session_id": 1, "seed": 20260830, "delay": 0,
		"choice_timeout": 1800, "roster": [{"slot": 0, "program": "virus", "name": "ghost", "counters": {}}, {"slot": 1, "program": "bulwark", "name": "shield", "counters": {}}]})
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	r.set_physics_process(false)
	r._advance_subnet()
	var centre: Vector2 = r.terrain.nearest_open(r.terrain.arena().get_center())
	r.player_pos[0] = centre
	r.player_pos[1] = centre + Vector2(50, 40)
	r.player_prev_pos = r.player_pos.duplicate()
	r.player_render_pos = r.player_pos.duplicate()
	r._place_network_op()
	if r.ops_state == 0:
		printerr("Could not place review relay")
		quit(1)
		return
	r.player_pos[0] = r.ops_pos - Vector2(60, 0)
	r.player_pos[1] = r.ops_pos - Vector2(40, 20)
	r.player_prev_pos = r.player_pos.duplicate()
	r.player_render_pos = r.player_pos.duplicate()
	r.ops_state = 2
	r.ops_progress = 12.0
	r.director.elapsed = 45.0
	r.route_active = 2
	r._step_network_ops(1.0)
	await snap("expansion-relay")
	r.phase = r.Phase.CLEARED
	r.terrain.open_gate()
	r._open_route_vote()
	await snap("expansion-routes")
	r.free()
	await process_frame
	quit(0)
