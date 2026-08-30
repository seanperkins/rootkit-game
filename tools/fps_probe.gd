extends SceneTree

## Real frame time in the actual engine loop — physics tick AND rendering — with
## every pool held at cap. The tick budget is a proxy; this is the thing that
## decides whether the architecture holds.

var run: Node2D
var frames := 0
var samples := PackedFloat64Array()
var last := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _process(_d: float) -> bool:
	if run == null or run.enemies == null:
		return false
	if frames == 0:
		# vsync pins every frame to 16.67 ms and hides all headroom
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		run.input_override = Vector2.ZERO
		run.director.elapsed = 999.0
		run.director.boss_spawned = true
		var t := ModuleTable.by_id()
		run.loadout.exploits[0].vector.rank = 5
		for pair in [[&"broadcast", &"on_hit"], [&"chain", &"interval"]]:
			var ex := Exploit.new()
			ex.place(t[pair[0]]); ex.place(t[pair[1]]); ex.vector.rank = 5
			run.loadout.exploits.append(ex)
		run._recompile()
	_fill()
	frames += 1
	var now := Time.get_ticks_usec()
	if frames > 120:
		samples.append(float(now - last) / 1000.0)
	last = now
	if frames == 620:
		samples.sort()
		var n := samples.size()
		var mean := 0.0
		for x in samples: mean += x
		print("real frame time at cap (%d enemies, %d proj, %d shards, %d botnet):" % [
			run.enemies.count, run.projectiles.count, run.shards.count, run.botnet.count])
		print("  mean   %6.2f ms   (%.0f fps)" % [mean / n, 1000.0 / (mean / n)])
		print("  median %6.2f ms" % samples[n / 2])
		print("  p95    %6.2f ms" % samples[int(n * 0.95)])
		print("  p99    %6.2f ms" % samples[int(n * 0.99)])
		print("  worst  %6.2f ms" % samples[n - 1])
		print("  frames over 16.7 ms: %d / %d" % [_over(16.7), n])
		return true
	return false

func _over(ms: float) -> int:
	var c := 0
	for x in samples:
		if x > ms: c += 1
	return c

func _fill() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 4242 + run.enemies.count
	while run.enemies.count < run.MAX_ENEMIES:
		var a := rng.randf()*TAU
		run.enemies.spawn(run.player_pos + Vector2(cos(a),sin(a))*rng.randf_range(60,620), Vector2.ZERO, 999999.0, run.ENEMY_RADIUS, rng.randi_range(0,2))
	while run.projectiles.count < run.MAX_PROJECTILES:
		var a2 := rng.randf()*TAU
		var pi: int = run.projectiles.spawn(run.player_pos + Vector2(cos(a2),sin(a2))*200.0, Vector2(cos(a2),sin(a2))*300.0, 1.0, run.PROJECTILE_RADIUS, 0)
		if pi >= 0: run._proj_owner[pi]=0; run._proj_pierce[pi]=9999; run._proj_last[pi]=-1
	while run.shards.count < run.MAX_SHARDS:
		var a3 := rng.randf()*TAU
		run.shards.spawn(run.player_pos + Vector2(cos(a3),sin(a3))*rng.randf_range(300,900), Vector2.ZERO, 1.0, 4.0, 0)
	while run.botnet.count < run.MAX_BOTNET:
		var a4 := rng.randf()*TAU
		var bi: int = run.botnet.spawn(run.player_pos + Vector2(cos(a4),sin(a4))*150.0, Vector2.ZERO, 1.0, run.ENEMY_RADIUS, 0)
		if bi >= 0: run._botnet_ratio[bi]=1.0; run._botnet_life[bi]=9999.0
