extends SceneTree
var run: Node2D
var frames := 0
func _initialize() -> void:
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
func _process(_d: float) -> bool:
	frames += 1
	if run == null or run.terrain == null:
		return false
	if frames == 20:
		# Clear the subnet and stand a little way off the gate, so the frame has
		# the open gate, the wayfinding wash and the HUD note all at once.
		run.phase = run.Phase.CLEARED
		run.terrain.gate_open = true
		run.player_pos = run.terrain.gate_pos + (Vector2.ZERO - run.terrain.gate_pos).normalized() * 170.0
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/rootkit_gate.png")
		return true
	return false
