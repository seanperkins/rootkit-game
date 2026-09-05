extends SceneTree

var failures := 0

func verify(label: String, passed: bool) -> void:
	print("  %s %s" % ["ok" if passed else "FAIL", label])
	if not passed: failures += 1

func tap_key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame

func tap_pad(button: JoyButton) -> void:
	for down in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = button
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame

func click_button(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame

func snap(name: String, frames: int = 12) -> void:
	for i in frames: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.tmp/teleporter-" + name + ".png")

func aim_camera(r: Node2D, point: Vector2) -> void:
	for s in r._live_slots():
		r.player_pos[s] = point + Vector2(-20 if s % 2 == 0 else 20, -20 if s < 2 else 20)
	r.player_prev_pos = r.player_pos.duplicate()
	r.player_render_pos = r.player_pos.duplicate()
	r._camera.position = r.to_iso(point)

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Windowed rendering required")
		quit(1)
		return
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	await process_frame
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.external_drive = true
	var roster := []
	for s in 4: roster.append({"slot": s, "name": "p%d" % s, "counters": {}})
	var desc := NetworkSession.validate_descriptor({"protocol": SessionRules.PROTOCOL,
		"version": "dev", "session_id": 1, "seed": 20260830, "delay": 0,
		"choice_timeout": 1800, "roster": roster})
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	r.set_physics_process(false)
	aim_camera(r, r.terrain.teleporter_pos())
	await snap("offline")
	r.phase = r.Phase.CLEARED
	r.terrain.open_gate()
	r.collapse_left = r.COLLAPSE_SECONDS
	await snap("online", 90)
	r._step2c_gate()
	await snap("vote")
	var ui: CanvasLayer
	for child in r.get_children():
		if child is CanvasLayer: ui = child
	await tap_key(KEY_RIGHT)
	await tap_key(KEY_ENTER)
	verify("keyboard stages route 2", r._local_choice.x == 1 and r.route_votes[0] == -1)
	await tap_pad(JOY_BUTTON_DPAD_RIGHT)
	await tap_pad(JOY_BUTTON_A)
	verify("controller stages route 3", r._local_choice.x == 2 and r.route_votes[0] == -1)
	await click_button(ui._nav[0][0])
	verify("mouse stages route 1", r._local_choice.x == 0 and r.route_votes[0] == -1)
	# The next consumed tick applies that staged local ballot.
	for s in range(1, 4): r.lockstep.submit(s, r.lockstep.executed, Vector2.ZERO, -1, -1, -1)
	r._physics_process(1.0 / 60.0)
	verify("device choice commits through lockstep", r.route_votes[0] == 0 and r.route_pending)
	await snap("waiting")
	verify("submitted ballot remains visible and disabled", ui._cards.size() == 3 and ui._nav[0][0].disabled)
	for s in range(1, 4): r._apply_choice(s, 0, -1, r._offer_open[s]["seq"])
	for i in 38: r._step_transfer()
	await snap("charge")
	for i in 16: r._step_transfer()
	r._camera.position = r.to_iso(r.player_pos[0])
	await snap("arrival")
	for i in 36: r._step_transfer()
	r.terrain.unlock_room()
	aim_camera(r, r.terrain.room_rect.get_center() + Vector2(-140, 60))
	await snap("archive")
	r.free()
	await process_frame
	quit(0 if failures == 0 else 1)
