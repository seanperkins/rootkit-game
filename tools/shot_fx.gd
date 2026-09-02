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
	if run == null or run.loadouts[run.local_slot] == null: return false
	if frames == 10:
		var t := ModuleTable.by_id()
		# beam, broadcast and chain all at once so every visual is in one frame
		run.loadouts[run.local_slot].place_at(t[&"beam"], 0, 0)
		run.loadouts[run.local_slot].place_at(t[&"interval"], 0, 1)
		run.loadouts[run.local_slot].place_at(t[&"broadcast"], 1, 0)
		run.loadouts[run.local_slot].place_at(t[&"interval"], 1, 1)
		run.loadouts[run.local_slot].place_at(t[&"chain"], 2, 0)
		run.loadouts[run.local_slot].place_at(t[&"interval"], 2, 1)
		run.loadouts[run.local_slot].exploits[1].vector.rank = 3
		run._recompile()
		run.director.boss_spawned = true
	if frames > 12:
		run.input_override = Vector2.ZERO
		# hold a ring of tough enemies so the shots have targets and persist
		while run.enemies.count < 26:
			var a: float = TAU * run.enemies.count / 26.0
			var d: float = 90.0 + 40.0 * (run.enemies.count % 3)
			run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(cos(a), sin(a)) * d,
				Vector2.ZERO, 9999.0, run.ENEMY_RADIUS, run.enemies.count % 3)
	# catch a frame where something has just fired
	if frames > 60 and (run._fx_line.size() > 0 or run._fx_ring.size() > 0):
		root.get_texture().get_image().save_png("/tmp/rootkit_fx.png")
		print("lines=%d rings=%d" % [run._fx_line.size(), run._fx_ring.size()])
		return true
	if frames > 400:
		print("no fx captured")
		return true
	return false
