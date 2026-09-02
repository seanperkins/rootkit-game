extends SceneTree
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
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.terrain == null:
		return false
	if frames == 20:
		# Clear the subnet and stand a little way off the gate, so the frame has
		# the open gate, the corridor beyond it and the HUD note all at once.
		run.terrain.open_gate()
		run.phase = run.Phase.CLEARED
		run.collapse_left = run.COLLAPSE_SECONDS * 0.5
		run.terrain.build_distance_field()
		var g = run.terrain.gate()
		run.player_pos[run.local_slot] = g.pos - g.dir * 300.0
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/rootkit_gate.png")
		return true
	return false
