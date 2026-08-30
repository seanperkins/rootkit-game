extends SceneTree
var run: Node2D
var frames := 0
func _initialize() -> void:
	run = load("res://scenes/main.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.level_up_offered.connect(func(cards): run.choose_card(cards[0][0], cards[0][1]))
func _process(_d: float) -> bool:
	frames += 1
	if run != null and frames > 30:
		run.input_override = Vector2(sin(frames * 0.05), cos(frames * 0.04)).normalized()
	if frames == 5400:
		var img := root.get_texture().get_image()
		img.save_png("/tmp/rootkit_shot.png")
		print("saved; enemies=%d shards=%d level=%d hp=%.0f paused=%s" % [
			run.enemies.count, run.shards.count, run.level, run.player_health, run.paused])
		return true
	return false
