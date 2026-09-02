extends SceneTree

## Real frame time DURING A COLLAPSE, with every pool at cap.
##
## fps_probe never clears a subnet, and the headless perf gate does not render
## at all, so neither of them sees the heaviest draw path in the game: a
## half-collapsed arena is several hundred void quads plus the route wash, every
## frame, on top of the usual load. A cost nothing measures is a cost that grows.

var run: Node2D
var frames := 0
var samples := PackedFloat64Array()
var last := 0

func _initialize() -> void:
	SaveGame.use_test_paths()
	SaveGame.use_fresh_state()
	run = load("res://scenes/run.tscn").instantiate()
	root.add_child(run)

func _process(_d: float) -> bool:
	if run == null or run.enemies == null or run.terrain == null:
		return false
	if frames == 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		run.input_override = Vector2.ZERO
		var t := ModuleTable.by_id()
		run.loadouts[run.local_slot].exploits[0].vector.rank = 5
		for pair in [[&"broadcast", &"on_hit"], [&"chain", &"interval"]]:
			var ex := Exploit.new()
			ex.place(t[pair[0]]); ex.place(t[pair[1]]); ex.vector.rank = 5
			run.loadouts[run.local_slot].exploits.append(ex)
		run._recompile()
		# Clear the subnet, then wind the collapse to its halfway point — the
		# most void the arena ever has on screen at once with ground still left
		# to stand on.
		var b = run.enemy_types[EnemyTable.ICE]
		var i: int = run.enemies.spawn(Vector2(200, 0), Vector2.ZERO,
			b.integrity, 48.0, EnemyTable.ICE)
		run._on_death(i)
		run.collapse_left = run.COLLAPSE_SECONDS * 0.5
		run.terrain.collapse_to(int(float(run.terrain.max_dist) * 0.5))
		_fill()
	# The void set is held still and the pools are NOT refilled inside the
	# timing window. Letting the collapse advance meant every frame despawned
	# the enemies whose ground had just gone and _fill respawned six hundred
	# into the hole — which is what the first run of this probe measured, and it
	# had nothing to do with drawing.
	run.collapse_left = run.COLLAPSE_SECONDS * 0.5
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
		var view: Rect2 = run._visible_world_rect()
		print("collapse frame time at cap (%d void runs on screen, %d route cells):" % [
			run._void_runs(view).size(), run._route_points(view).size()])
		print("  mean   %6.2f ms   (%.0f fps)" % [mean / n, 1000.0 / (mean / n)])
		print("  median %6.2f ms" % samples[n / 2])
		print("  p95    %6.2f ms" % samples[int(n * 0.95)])
		print("  worst  %6.2f ms" % samples[n - 1])
		print("  frames over 16.7 ms: %d / %d" % [_over(16.7), n])
		return true
	return false

func _over(ms: float) -> int:
	var c := 0
	for x in samples:
		if x > ms: c += 1
	return c

## Refill to cap. Measuring a tick whose pools have drained measures a lighter
## game than the one that ships.
func _fill() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 4242 + run.enemies.count
	while run.enemies.count < run.MAX_ENEMIES:
		var a := rng.randf() * TAU
		run.enemies.spawn(run.player_pos[run.local_slot] + Vector2(cos(a), sin(a))
			* rng.randf_range(60, 620), Vector2.ZERO, 999999.0, run.ENEMY_RADIUS,
			rng.randi_range(0, 2))
	while run.projectiles.count < run.MAX_PROJECTILES:
		var a2 := rng.randf() * TAU
		var pi: int = run.projectiles.spawn(run.player_pos[run.local_slot]
			+ Vector2(cos(a2), sin(a2)) * 200.0,
			Vector2(cos(a2), sin(a2)) * 300.0, 1.0, run.PROJECTILE_RADIUS, 0)
		if pi >= 0:
			run._proj_owner[pi] = 0; run._proj_pierce[pi] = 9999
			run._proj_last[pi] = -1; run._proj_dist_left[pi] = 99999.0
	while run.shards.count < run.MAX_SHARDS:
		var a3 := rng.randf() * TAU
		run.shards.spawn(run.player_pos[run.local_slot] + Vector2(cos(a3), sin(a3))
			* rng.randf_range(300, 900), Vector2.ZERO, 1.0, 4.0, 0)
