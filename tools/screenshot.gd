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
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)
	await process_frame
	run.level_up_offered.connect(func(cards): run.choose_card(cards[0][0], Loadout.best_target(cards[0][1])))
	# Without a handler _block_payout refuses to offer a fusion at all (it
	# would pause with nobody to unpause it); with one, an autopiloted run
	# actually exercises a fused row.
	run.fusion_offered.connect(func(_m): run.choose_fusion(0))
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
