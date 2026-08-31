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
		run.terrain.build_distance_field()
		# Stand just inside the collapse frontier, so the edge of the void is in
		# frame: safe ground at 0.40 of max distance against a 0.50 threshold.
		var t = run.terrain
		var ter = run.terrain
		run.player_pos = ter.gate_pos - ter.gate_dir * 300.0
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/rootkit_gate.png")
		return true
	return false
