extends SceneTree

## Per-step breakdown of the milestone 0 tick, so optimisation targets the
## actual cost centre instead of the assumed one.

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
const TICKS := 300
const DT := 1.0 / 60.0

var enemies: Population
var projectiles: Population
var botnet: Population
var shards: Population
var grid: Grid
var player_pos := Vector2.ZERO
var _buf: PackedInt32Array
var _counts: PackedInt32Array
var _pos_arrays: Array

var t_integrate := 0.0
var t_rebuild := 0.0
var t_steer := 0.0
var t_fire := 0.0
var t_detect := 0.0

func _init() -> void:
	_buf = PackedInt32Array(); _buf.resize(2048)
	_counts = PackedInt32Array(); _counts.resize(4)
	grid = Grid.new(ARENA_ORIGIN, ARENA_SIZE, CELL,
		MAX_ENEMIES + MAX_PROJECTILES + MAX_BOTNET + MAX_SHARDS)
	enemies = Population.new(MAX_ENEMIES)
	projectiles = Population.new(MAX_PROJECTILES)
	botnet = Population.new(MAX_BOTNET)
	shards = Population.new(MAX_SHARDS)
	_pos_arrays = [null, null, null, null]

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260829
	var spread := 260.0
	for i in MAX_ENEMIES:
		var p := Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread))
		enemies.spawn(p, (Vector2.ZERO - p).normalized() * 60.0, 30.0, ENEMY_RADIUS, 0)
	for i in MAX_PROJECTILES:
		projectiles.spawn(Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread)),
			Vector2(rng.randf_range(-1,1), rng.randf_range(-1,1)).normalized() * 600.0,
			1.0, PROJECTILE_RADIUS, 0)
	for i in MAX_BOTNET:
		botnet.spawn(Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread)), Vector2.ZERO, 1.0, ENEMY_RADIUS, 0)
	for i in MAX_SHARDS:
		shards.spawn(Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread)), Vector2.ZERO, 1.0, 4.0, 0)

	for w in 30:
		_tick()
	t_integrate = 0.0; t_rebuild = 0.0; t_steer = 0.0; t_fire = 0.0; t_detect = 0.0
	for t in TICKS:
		_tick()

	var total := t_integrate + t_rebuild + t_steer + t_fire + t_detect
	print("Per-tick breakdown (mean over %d ticks, ms):" % TICKS)
	print("  integrate  %7.3f   %5.1f%%" % [t_integrate / TICKS, 100.0 * t_integrate / total])
	print("  rebuild    %7.3f   %5.1f%%" % [t_rebuild / TICKS, 100.0 * t_rebuild / total])
	print("  steer      %7.3f   %5.1f%%   (%d queries)" % [t_steer / TICKS, 100.0 * t_steer / total, enemies.count])
	print("  fire       %7.3f   %5.1f%%   (%d queries)" % [t_fire / TICKS, 100.0 * t_fire / total, 12 + botnet.count])
	print("  detect     %7.3f   %5.1f%%   (%d queries)" % [t_detect / TICKS, 100.0 * t_detect / total, projectiles.count + 1])
	print("  TOTAL      %7.3f" % (total / TICKS))
	quit()

func _tick() -> void:
	var a := Time.get_ticks_usec()
	enemies.integrate(DT)
	projectiles.integrate(DT)
	var b := Time.get_ticks_usec()
	_pos_arrays[0] = enemies.pos; _pos_arrays[1] = projectiles.pos
	_pos_arrays[2] = botnet.pos;  _pos_arrays[3] = shards.pos
	_counts[0] = enemies.count; _counts[1] = projectiles.count
	_counts[2] = botnet.count;  _counts[3] = shards.count
	grid.rebuild(_pos_arrays, _counts)
	var c := Time.get_ticks_usec()
	for i in enemies.count:
		var here := enemies.pos[i]
		var n := grid.query_radius_into(here, SEPARATION_RADIUS, _buf, Grid.M_ENEMY)
		var push := Vector2.ZERO
		var lim := mini(n, _buf.size())
		for k in lim:
			var j := Grid.index_of(_buf[k])
			if j == i: continue
			var d := here - enemies.pos[j]
			var dl := d.length()
			if dl > 0.001:
				push += d / dl * (SEPARATION_RADIUS - dl)
		enemies.force[i] = push * 4.0
	var e := Time.get_ticks_usec()
	for x in 3:
		for f in 4:
			grid.query_radius_into(player_pos, AURA_RADIUS, _buf, Grid.M_ENEMY)
	for i in botnet.count:
		grid.query_radius_into(botnet.pos[i], BOTNET_AURA, _buf, Grid.M_ENEMY)
	var f2 := Time.get_ticks_usec()
	for i in projectiles.count:
		grid.query_radius_into(projectiles.pos[i], PROJECTILE_RADIUS + ENEMY_RADIUS, _buf, Grid.M_ENEMY)
	grid.query_radius_into(player_pos, PICKUP_RADIUS, _buf, Grid.M_SHARD)
	var g := Time.get_ticks_usec()

	t_integrate += float(b - a) / 1000.0
	t_rebuild   += float(c - b) / 1000.0
	t_steer     += float(e - c) / 1000.0
	t_fire      += float(f2 - e) / 1000.0
	t_detect    += float(g - f2) / 1000.0
