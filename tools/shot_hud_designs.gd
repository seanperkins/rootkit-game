extends SceneTree

## Review full builds, critical health, and co-op notices at normal game size.
var run: Node2D
var ui: CanvasLayer
var frames := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("shot_hud_designs requires a window")
		quit(1)
		return
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	run = await PerfFixture.new().party_run(self)
	for child in run.get_children():
		if child is CanvasLayer and child.has_method("bind"):
			ui = child

func _process(_dt: float) -> bool:
	if run == null or run.terrain == null:
		return false
	frames += 1
	if frames == 5:
		run.paused = true
		run.set_physics_process(false)
		run._stalled_ticks = 0
		run.director.elapsed = 127.0
		for slot in range(1, SessionRules.MAX_PLAYERS):
			run.player_pos[slot] = run.player_pos[0] + PerfFixture.PARTY_OFFSETS[slot]
		run.input_override = Vector2.ZERO
		run.level = 17
		run.salvage = 1420
		run.xp = 42
		run.xp_needed = 100
		run.player_shield[0] = 26
		var tbl := ModuleTable.by_id()
		var lo: Loadout = run.loadouts[0]
		lo.exploits.clear()
		for id in [&"packet", &"chain", &"beam", &"spike", &"broadcast"]:
			var ex := Exploit.new()
			ex.place(tbl[id])
			ex.place(tbl[&"interval"])
			ex.vector.rank = 3
			lo.exploits.append(ex)
		run._recompile()
		for i in 26:
			var angle := float(i) * 2.39996
			var at: Vector2 = run.player_pos[0] + Vector2(cos(angle), sin(angle)) * (110 + sqrt(float(i)) * 35)
			if run.terrain.is_solid(at):
				continue
			var idx: int = run.enemies.spawn(at, (run.player_pos[0] - at).normalized() * 45, 100, run.ENEMY_RADIUS, i % 8)
			run._clear_ai(idx)
			run._spawn_hp[idx] = 100
			run._enemy_target[idx] = 0
			if i % 8 == 3:
				run._ai_phase[idx] = run.CH_WINDUP
				run._ai_timer[idx] = run.CHARGE_WINDUP * 0.25
			if i % 8 == 7:
				run._ai_timer[idx] = run.RANGED_COOLDOWN * 0.10
		run._depth_sort()
		run._snapshot_render_state()
		ui._refresh()
	if frames == 100:
		_save("hud-combat")
		run.player_health[0] = run._eff_integrity(0) * 0.22
		run._vignette = 0.7
		ui._refresh()
	if frames == 160:
		_save("hud-critical")
		run.phase = run.Phase.CLEARED
		run.collapse_left = 18
		ui._refresh()
	if frames == 220:
		_save("hud-collapse")
		run._stalled_ticks = SessionRules.STALL_NOTICE + 1
		run._session.reconnecting = true
		ui._refresh()
	if frames == 280:
		_save("hud-reconnect")
		run.queue_free()
		await process_frame
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
