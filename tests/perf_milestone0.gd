extends SceneTree

## MILESTONE 0 — the perf gate.
##
## The architecture replaced C++ broadphase in the physics server with a
## hand-rolled uniform grid in interpreted GDScript. That is the one bet the
## whole design rests on and nothing else tests it. This runs the real per-tick
## work at full pool capacity and reports median / p95 / p99 tick time.
##
## Budget: 8.0 ms/tick. Above that, port grid.gd and population.gd to C#.
##
## Run: godot --headless -s res://tests/perf_milestone0.gd

const ARENA_ORIGIN := Vector2(-1280, -720)
const ARENA_SIZE := Vector2(2560, 1440)
const CELL := 32.0

const MAX_ENEMIES := 600
const MAX_PROJECTILES := 400
const MAX_SHARDS := 1500
const MAX_BOTNET := 8

const ENEMY_RADIUS := 12.0
const PROJECTILE_RADIUS := 4.0
const PICKUP_RADIUS := 48.0
const SEPARATION_RADIUS := 24.0
const AURA_RADIUS := 200.0
const BOTNET_AURA := 64.0

const TICKS := 600
const DT := 1.0 / 60.0
const BUDGET_MS := 8.0

var enemies: Population
var projectiles: Population
var botnet: Population
var shards: Population
var grid: Grid
var player_pos := Vector2.ZERO

var _buf: PackedInt32Array
var _counts: PackedInt32Array
var _pos_arrays: Array

func _init() -> void:
	var capacity := MAX_ENEMIES + MAX_PROJECTILES + MAX_BOTNET + MAX_SHARDS
	_buf = PackedInt32Array()
	_buf.resize(2048)
	_counts = PackedInt32Array()
	_counts.resize(4)

	grid = Grid.new(ARENA_ORIGIN, ARENA_SIZE, CELL, capacity)
	enemies = Population.new(MAX_ENEMIES)
	projectiles = Population.new(MAX_PROJECTILES)
	botnet = Population.new(MAX_BOTNET)
	shards = Population.new(MAX_SHARDS)
	_pos_arrays = [null, null, null, null]

	_populate_worst_case()

	print("ROOTKIT — milestone 0 perf gate")
	print("  entities: %d enemies, %d projectiles, %d botnet, %d shards = %d" % [
		enemies.count, projectiles.count, botnet.count, shards.count,
		enemies.count + projectiles.count + botnet.count + shards.count])
	print("  grid: %.0f px cells over %.0fx%.0f" % [CELL, ARENA_SIZE.x, ARENA_SIZE.y])
	print("  budget: %.1f ms/tick over %d ticks" % [BUDGET_MS, TICKS])
	print("")

	var samples := _run()
	_report(samples)
	quit()

## Worst case is a dense cluster, not a spread: clustering maximises the number
## of results every proximity query returns, which is where the cost lives.
func _populate_worst_case() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260829
	var spread := 260.0
	for i in MAX_ENEMIES:
		var p := Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread))
		var v := (Vector2.ZERO - p).normalized() * 60.0
		enemies.spawn(p, v, 30.0, ENEMY_RADIUS, 0)
	for i in MAX_PROJECTILES:
		var p := Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread))
		projectiles.spawn(p, Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * 600.0,
			1.0, PROJECTILE_RADIUS, 0)
	for i in MAX_BOTNET:
		botnet.spawn(Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread)), Vector2.ZERO,
			1.0, ENEMY_RADIUS, 0)
	for i in MAX_SHARDS:
		shards.spawn(Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread)), Vector2.ZERO,
			1.0, 4.0, 0)

func _tick() -> void:
	# Step 2 — Integrate (steering forces came from step 4 of the previous tick).
	enemies.integrate(DT)
	projectiles.integrate(DT)

	# Step 3 — Rebuild grid.
	_pos_arrays[Grid.Pop.ENEMY] = enemies.pos
	_pos_arrays[Grid.Pop.PROJECTILE] = projectiles.pos
	_pos_arrays[Grid.Pop.BOTNET] = botnet.pos
	_pos_arrays[Grid.Pop.SHARD] = shards.pos
	_counts[Grid.Pop.ENEMY] = enemies.count
	_counts[Grid.Pop.PROJECTILE] = projectiles.count
	_counts[Grid.Pop.BOTNET] = botnet.count
	_counts[Grid.Pop.SHARD] = shards.count
	grid.rebuild(_pos_arrays, _counts)

	# Step 4 — Steer. One query per enemy; forces are consumed next tick.
	for i in enemies.count:
		var here := enemies.pos[i]
		var n := grid.query_radius_into(here, SEPARATION_RADIUS, _buf, Grid.M_ENEMY)
		var push := Vector2.ZERO
		var lim := mini(n, _buf.size())
		for k in lim:
			var j := Grid.index_of(_buf[k])
			if j == i:
				continue
			var d := here - enemies.pos[j]
			var dl := d.length()
			if dl > 0.001:
				push += d / dl * (SEPARATION_RADIUS - dl)
		enemies.force[i] = push * 4.0

	# Step 5 — Fire. 3 exploits, worst case 4 fires each, BROADCAST auras.
	for e in 3:
		for f in 4:
			grid.query_radius_into(player_pos, AURA_RADIUS, _buf, Grid.M_ENEMY)
	for i in botnet.count:
		grid.query_radius_into(botnet.pos[i], BOTNET_AURA, _buf, Grid.M_ENEMY)

	# Step 6 — Detect. Projectile overlap plus the player's pickup query.
	for i in projectiles.count:
		grid.query_radius_into(projectiles.pos[i], PROJECTILE_RADIUS + ENEMY_RADIUS, _buf, Grid.M_ENEMY)
	grid.query_radius_into(player_pos, PICKUP_RADIUS, _buf, Grid.M_SHARD)

func _run() -> PackedFloat64Array:
	for w in 60:            # warm-up, excluded from the sample
		_tick()
	var samples := PackedFloat64Array()
	samples.resize(TICKS)
	for t in TICKS:
		var t0 := Time.get_ticks_usec()
		_tick()
		samples[t] = float(Time.get_ticks_usec() - t0) / 1000.0
	return samples

func _report(samples: PackedFloat64Array) -> void:
	var sorted := samples.duplicate()
	sorted.sort()
	var n := sorted.size()
	var median := sorted[n / 2]
	var p95 := sorted[int(n * 0.95)]
	var p99 := sorted[int(n * 0.99)]
	var worst := sorted[n - 1]
	var mean := 0.0
	for s in samples:
		mean += s
	mean /= n

	print("  mean   %7.3f ms" % mean)
	print("  median %7.3f ms" % median)
	print("  p95    %7.3f ms" % p95)
	print("  p99    %7.3f ms" % p99)
	print("  max    %7.3f ms" % worst)
	print("")
	if p99 <= BUDGET_MS:
		print("  PASS — p99 %.3f ms is within the %.1f ms budget." % [p99, BUDGET_MS])
		print("  GDScript holds. No C# port needed.")
	else:
		print("  FAIL — p99 %.3f ms exceeds the %.1f ms budget." % [p99, BUDGET_MS])
		print("  Escape hatch: port grid.gd and population.gd to C#.")
