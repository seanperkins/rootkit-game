extends SceneTree

## Reproducible lineup using the actual run renderer, test saves only.
## Window required. Outputs .tmp/entity-designs.png and entity-combat.png.
var run: Node2D
var frames := 0
var labels: Node2D

class Captions extends Node2D:
	var entries: Array = []
	func _draw() -> void:
		var font := ThemeDB.fallback_font
		for entry in entries:
			var size: int = entry[2]
			var width := font.get_string_size(entry[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			draw_string(font, entry[0] - Vector2(width * 0.5, 0), entry[1],
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.6, 0.85, 0.82))

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("shot_entity_designs requires a window")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _label(at: Vector2, title: String, size: int = 13) -> void:
	labels.entries.append([run.to_iso(at), title, size])

func _process(_dt: float) -> bool:
	if run == null or run.terrain == null:
		return false
	frames += 1
	if frames == 5:
		run.user_paused = true
		run.input_override = Vector2.ZERO
		run.aim_override = Vector2.RIGHT
		run.enemies.count = 0
		run.projectiles.count = 0
		for child in run.get_children():
			if child is CanvasLayer:
				child.hide()
		for name in ["Props", "ZonePanels"]:
			run.get_node(name).hide()
		labels = Captions.new()
		run.add_child(labels)
		var center: Vector2 = run.player_pos[0]
		_label(center + run.from_iso(Vector2(0, -265)), "ROOTKIT / ENTITY SYSTEMS", 24)
		for i in run.enemy_types.size():
			var offset := Vector2(-450 + (i % 7) * 150, -215 + (i / 7) * 115)
			var at: Vector2 = center + run.from_iso(offset)
			var idx: int = run.enemies.spawn(at, Vector2(-40, -40), 100, run.ENEMY_RADIUS, i)
			run._clear_ai(idx)
			run._spawn_hp[idx] = 100
			_label(at + run.from_iso(Vector2(0, 43)), String(run.enemy_types[i].id))
		_label(center + run.from_iso(Vector2(0, 40)), "INTERCEPTOR", 13)
		for i in 3:
			var at: Vector2 = center + run.from_iso(Vector2(-380 + i * 145, 85))
			var idx: int = run.projectiles.spawn(at, Vector2(-40, -40), 1, 4, 0)
			run._mine_left[idx] = 5.0 if i == 1 else 0.0
			run._orbit_left[idx] = 5.0 if i == 2 else 0.0
			_label(at + run.from_iso(Vector2(0, 30)), ["PACKET", "MINE", "ORBITER"][i])
		for i in 3:
			var at: Vector2 = center + run.from_iso(Vector2(100 + i * 170, 110))
			run._fx.append([[run.FxKind.BOLT, run.FxKind.BEAM, run.FxKind.WEDGE][i],
				at, Vector2(-90, -90) if i == 0 else Vector2(-1, -1).normalized(),
				105.0, 100.0, Color(0.6, 1.5, 1.2)])
			_label(at + run.from_iso(Vector2(0, 30)), ["ARC", "BEAM", "CONE"][i])
		run._depth_sort()
		run._snapshot_render_state()
		labels.queue_redraw()
	if frames == 45:
		_save("entity-designs")
		labels.hide()
		run.get_node("Props").show()
		run.get_node("ZonePanels").show()
		run.enemies.count = 0
		run.projectiles.count = 0
		run._fx.clear()
		for i in 75:
			var angle := i * 2.39996
			var radius := 70.0 + sqrt(float(i)) * 30.0
			var at: Vector2 = run.player_pos[0] + Vector2(cos(angle), sin(angle)) * radius
			if run.terrain.is_solid(at):
				continue
			var idx: int = run.enemies.spawn(at, (run.player_pos[0] - at).normalized() * 45.0,
				100, run.ENEMY_RADIUS, i % 8)
			run._clear_ai(idx)
			run._spawn_hp[idx] = 100
			if i % 11 == 0:
				run.enemies.corruption[idx] = run.thresholds[i % 8] * 0.85
		run._depth_sort()
		run._snapshot_render_state()
	if frames == 80:
		_save("entity-combat")
		quit()
	return false

func _save(title: String) -> void:
	var path := "res://.tmp/%s.png" % title
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("Could not save ", path, ": ", error)
		quit(1)
	else:
		print("Saved ", path)
