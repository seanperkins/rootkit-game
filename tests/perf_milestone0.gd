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

## The gate is load-RELATIVE, not absolute. An absolute wall-clock threshold
## false-fails on a loaded machine or a slow CI runner and false-passes on a
## quiet workstation — measured here as 5.2 ms median idle vs 8.5 ms at load
## average 5.3, for identical code. So the run first times a fixed synthetic
## workload, and the budget is scaled by how much slower this machine is than
## the reference. Both numbers move together under load, so the ratio holds.
##
## Reference: Apple Silicon, Darwin 25.6, Godot 4.7 headless.
##
## DERIVED, not directly measured on an idle machine: the quiet-machine run
## measured p99 6.192 ms, the loaded run 9.31 ms with calibration 22.504 ms, so
## the load factor was 1.503x and the idle calibration would be 22.504 / 1.503.
## Re-measure this constant on a genuinely quiet machine and replace it; the
## derivation assumes the calibration loop and the tick scale identically with
## load, which is the assumption the whole normalisation rests on.
const REFERENCE_CALIBRATION_MS := 14.97
const CALIBRATION_ITERS := 400000

## Above this contention the machine cannot produce a trustworthy tail: observed
## p99 swinging 16 -> 73 ms across back-to-back runs while the median held at
## 9.6. Rather than false-fail (or false-pass on a lucky run), the gate declines
## to judge and says so.
const MAX_CONTENTION := 1.8

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

	var cal := _calibrate()
	var scale: float = cal / REFERENCE_CALIBRATION_MS
	var budget: float = BUDGET_MS * scale
	print("  calibration: %.3f ms (reference %.3f) -> machine is %.2fx" % [
		cal, REFERENCE_CALIBRATION_MS, scale])
	print("  scaled budget: %.3f ms" % budget)
	print("")

	var samples := _run()
	if scale > MAX_CONTENTION:
		_report(samples, budget, scale)
		print("")
		print("  INCONCLUSIVE — machine is %.2fx the reference; too contended to" % scale)
		print("  measure a tail. Median held at %.3f ms. Re-run on a quiet machine." % _median(samples))
		quit(0)
	_report(samples, budget, scale)
	quit(0 if _p99(samples) <= budget else 1)

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

## A fixed workload in the same interpreter doing the same kind of work the
## tick does, so it absorbs machine load identically.
func _calibrate() -> float:
	var a := Vector2(1.0, 2.0)
	var b := Vector2(3.0, 4.0)
	var acc := 0.0
	var t0 := Time.get_ticks_usec()
	for i in CALIBRATION_ITERS:
		acc += a.distance_squared_to(b)
		a.x += 0.000001
	var dt := float(Time.get_ticks_usec() - t0) / 1000.0
	if acc < 0.0:
		print("")     # keep the loop from being optimised away
	return dt

func _median(samples: PackedFloat64Array) -> float:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]

func _p99(samples: PackedFloat64Array) -> float:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[int(sorted.size() * 0.99)]

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

func _report(samples: PackedFloat64Array, budget: float, scale: float) -> void:
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
	print("  normalised p99: %.3f ms (reference-machine equivalent)" % (p99 / scale))
	print("")
	if p99 <= budget:
		print("  PASS — p99 %.3f ms is within the %.3f ms scaled budget." % [p99, budget])
		print("  GDScript holds. No C# port needed.")
	else:
		print("  FAIL — p99 %.3f ms exceeds the %.3f ms scaled budget." % [p99, budget])
		print("  Escape hatch: port grid.gd and population.gd to C#.")
