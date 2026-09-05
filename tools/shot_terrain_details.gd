extends SceneTree

## Real terrain panels, including both ends of corruption recharge.
var run: Node2D
var frames := 0
var selected := -1
const NAMES := ["hazard", "slow", "corruption-charged", "corruption-empty"]

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("shot_terrain_details requires a window")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _process(_dt: float) -> bool:
	if run == null or run.terrain == null:
		return false
	frames += 1
	if frames == 5:
		run.user_paused = true
		run.input_override = Vector2.ZERO
	if frames == 5 or frames == 65 or frames == 125:
		var kind := (frames - 5) / 60 + 1
		var biggest := -1.0
		for i in run.terrain.rects.size():
			var entry: Array = run.terrain.rects[i]
			var rect: Rect2 = entry[0]
			if entry[1] == kind:
				if rect.get_area() > biggest:
					biggest = rect.get_area()
					selected = i
		if biggest < 0:
			printerr("Missing panel kind ", kind)
			quit(1)
			return true
		for i in run.terrain.arenas.size():
			if run.terrain.arenas[i].has_point(run.terrain.rects[selected][0].get_center()):
				run.terrain.current = i
				run.subnet = i + 1
		run.player_pos[0] = run.terrain.rects[selected][0].get_center() + Vector2(130, 130)
		run._snapshot_render_state()
	if frames == 185:
		run._zone_recharge[selected] = Terrain.ZONE_RECHARGE
	if frames % 60 == 0:
		var index := frames / 60 - 1
		var path := "res://.tmp/terrain-%s.png" % NAMES[index]
		var err := root.get_texture().get_image().save_png(path)
		if err != OK:
			printerr("Could not save ", path, ": ", err)
			quit(1)
			return true
		print("Saved ", path)
		if frames == 240:
			return true
	return false
