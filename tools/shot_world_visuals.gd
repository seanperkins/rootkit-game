extends SceneTree

## Fixed views of all three floor identities, with moving current in each.
## Writes to .tmp/world-subnet-{1,2,3}.png. Test save paths only.
var run: Node2D
var frames := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("shot_world_visuals requires a window")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	run.external_drive = true
	root.add_child(run)

func _process(_d: float) -> bool:
	if run == null or run.terrain == null:
		return false
	frames += 1
	if frames == 5:
		run.user_paused = true
		run.input_override = Vector2.ZERO
	if frames == 5 or frames == 65 or frames == 125:
		var index := (frames - 5) / 60
		if index > 0:
			run._advance_subnet()
		run.player_pos[0] = run.terrain.arena().get_center()
		run._snapshot_render_state()
	if frames == 60 or frames == 120 or frames == 180:
		var index := frames / 60
		var path := "res://.tmp/world-subnet-%d.png" % index
		var err := root.get_texture().get_image().save_png(path)
		if err != OK:
			printerr("Could not save ", path, ": ", err)
			quit(1)
			return true
		print("Saved ", path)
		if frames == 180:
			quit()
	return false
