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
		run.terrain.build_distance_field()
		run.collapse_left = run.COLLAPSE_SECONDS * 0.5
		# Stand just inside the collapse frontier, so the edge of the void is in
		# frame: safe ground at 0.40 of max distance against a 0.50 threshold.
		var t = run.terrain
		# Just INSIDE the frontier, so the edge of the void fills the frame.
		var want := int(float(t.max_dist) * 0.5) - 3
		var best := -1
		for k in t.dist_from_gate.size():
			if t.dist_from_gate[k] == want:
				best = k
				break
		if best >= 0:
			run.player_pos = t.origin + Vector2(
				float(best % t.w) + 0.5, float(best / t.w) + 0.5) * Terrain.CELL
	if frames == 60:
		root.get_texture().get_image().save_png("/tmp/rootkit_gate.png")
		return true
	return false
