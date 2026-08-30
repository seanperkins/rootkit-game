extends Node2D

## The run. Owns the 9-step tick from the spec and every population in it.

const ARENA_ORIGIN := Vector2(-1600, -1000)
const ARENA_SIZE := Vector2(3200, 2000)
const CELL := 32.0

const MAX_ENEMIES := 600
const MAX_PROJECTILES := 400
const MAX_SHARDS := 1500
const MAX_BOTNET := 64

const ENEMY_RADIUS := 12.0
const PROJECTILE_RADIUS := 4.0
const SEPARATION_RADIUS := 26.0
## Separation only matters where the player can see it. The viewport covers
## roughly 640 px from the player at this zoom, so enemies beyond this keep
## their steering force from the last time they were in range and cost nothing.
## This is the single largest item in the tick and most of it was invisible.
const STEER_RANGE_SQ := 820.0 * 820.0
const STEER_SLICES := 2
## Half the viewport diagonal at zoom 1.15, plus a small margin. Nothing targets
## or is targeted beyond what the player can see.
const VIEW_RANGE := 620.0

## Worms are a chain: a head that steers, and segments that follow the path the
## head actually took rather than beelining at the player. Segments are real
## enemies — individually killable, individually dangerous — but they do not
## steer, and they decohere when their head dies.
const WORM_TYPE := 2
const WORM_TRAIL_LEN := 96
const WORM_SEG_STEPS := 8       # ticks of head history between segments
const WORM_BASE_SEGMENTS := 2   # head + 1 at the start of a run
const WORM_MAX_SEGMENTS := 6
const WORM_GROWTH_SECONDS := 70.0
const SPAWN_RING := 720.0

const PLAYER_MAX_HEALTH := 100.0
const PLAYER_SPEED := 220.0
const PLAYER_RADIUS := 11.0
const PICKUP_RADIUS := 30.0
const IFRAMES := 0.5

const FIRE_BUDGET := 4
const CASCADE_PASSES := 8
const EVENT_BUDGET := 7200      # 3 exploits x 4 fires x 600 enemies, derived
const BOTNET_BASE_CAP := 8
const BOTNET_BASE_LIFETIME := 12.0
const BOTNET_BASE_RATIO := 0.6

signal level_up_offered(cards: Array)
signal run_ended(won: bool, salvage: int)
signal stats_changed()

var enemies: Population
var projectiles: Population
var shards: Population
var botnet: Population
var grid: Grid
var queue: HitQueue
var loadout: Loadout
var director: SpawnDirector

var player_pos := Vector2.ZERO
var player_health := PLAYER_MAX_HEALTH
var player_iframe := 0.0
var alive := true
var won := false

var level := 1
var xp := 0
var xp_needed := 5
var salvage := 0
var kills := 0
var flips := 0
var pending_levels := 0
var paused := false
var pickup_radius := PICKUP_RADIUS
var _steer_phase := 0

var thresholds: PackedFloat32Array
var enemy_types: Array
var resolved: Array = []
var _fire_acc: PackedFloat32Array
var _proj_owner: PackedInt32Array
var _proj_pierce: PackedInt32Array
var _proj_last: PackedInt32Array
var _worm_id: PackedInt32Array
var _worm_seg: PackedInt32Array
var _worm_trail := {}          # worm id -> PackedVector2Array ring buffer
var _worm_cursor := {}         # worm id -> write index
var _next_worm_id := 1
var _botnet_ratio: PackedFloat32Array
var _botnet_life: PackedFloat32Array

var _buf: PackedInt32Array
var _counts: PackedInt32Array
var _pos_arrays: Array
var _unlocked: Array = []
## Headless tests drive the player through this instead of the keyboard.
var input_override = null
var _rng := RandomNumberGenerator.new()
var _card_rng := RandomNumberGenerator.new()

var _mm_enemy: MultiMeshInstance2D
var _mm_proj: MultiMeshInstance2D
var _mm_shard: MultiMeshInstance2D
var _mm_botnet: MultiMeshInstance2D
var _camera: Camera2D

func _ready() -> void:
	_rng.seed = 20260830
	_card_rng.seed = 20260830
	enemy_types = EnemyTable.all()
	thresholds = PackedFloat32Array()
	thresholds.resize(enemy_types.size())
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold

	grid = Grid.new(ARENA_ORIGIN, ARENA_SIZE, CELL,
		MAX_ENEMIES + MAX_PROJECTILES + MAX_SHARDS + MAX_BOTNET + 1)
	enemies = Population.new(MAX_ENEMIES)
	projectiles = Population.new(MAX_PROJECTILES)
	shards = Population.new(MAX_SHARDS)
	botnet = Population.new(MAX_BOTNET)
	queue = HitQueue.new(EVENT_BUDGET, MAX_ENEMIES)
	director = SpawnDirector.new()

	_buf = PackedInt32Array(); _buf.resize(1024)
	_counts = PackedInt32Array(); _counts.resize(4)
	_pos_arrays = [null, null, null, null]
	_fire_acc = PackedFloat32Array(); _fire_acc.resize(Loadout.MAX_EXPLOITS)
	_proj_owner = PackedInt32Array(); _proj_owner.resize(MAX_PROJECTILES)
	_proj_pierce = PackedInt32Array(); _proj_pierce.resize(MAX_PROJECTILES)
	_proj_last = PackedInt32Array(); _proj_last.resize(MAX_PROJECTILES)
	_worm_id = PackedInt32Array(); _worm_id.resize(MAX_ENEMIES)
	_worm_seg = PackedInt32Array(); _worm_seg.resize(MAX_ENEMIES)
	_botnet_ratio = PackedFloat32Array(); _botnet_ratio.resize(MAX_BOTNET)
	_botnet_life = PackedFloat32Array(); _botnet_life.resize(MAX_BOTNET)

	var table := ModuleTable.by_id()
	loadout = Loadout.new()
	loadout.start(table[&"packet"], table[&"interval"])
	loadout.buffs = SaveGame.buff_stats()
	pickup_radius = PICKUP_RADIUS + SaveGame.pickup_bonus()
	_unlocked = SaveGame.unlocked_modules()
	_recompile()

	_build_renderers()
	_camera = Camera2D.new()
	_camera.zoom = Vector2(1.15, 1.15)
	add_child(_camera)
	_camera.make_current()

	_build_environment()

	var ui := CanvasLayer.new()
	ui.set_script(load("res://scripts/run/ui.gd"))
	add_child(ui)
	ui.bind(self)

func _recompile() -> void:
	resolved = loadout.compile_all()
	emit_signal("stats_changed")

# ---------------------------------------------------------------- the tick ---

func _physics_process(dt: float) -> void:
	if paused or not alive or won:
		return

	_step1_spawn(dt)
	_step2_integrate(dt)
	_step3_rebuild()
	_step4_steer()
	_step5_fire(dt)
	_step6_detect(dt)
	_steps78_drain()
	_step9_recycle()

	_update_renderers()
	_camera.global_position = player_pos
	queue_redraw()

func _step1_spawn(dt: float) -> void:
	for s in director.step(dt, player_pos, SPAWN_RING):
		var ti: int = s[0]
		if ti == WORM_TYPE:
			if _spawn_worm(s[1]):
				director.spawned += 1
			else:
				director.dropped += 1
			continue
		var t = enemy_types[ti]
		var idx := enemies.spawn(s[1], Vector2.ZERO, t.integrity, ENEMY_RADIUS, ti)
		if idx < 0:
			director.dropped += 1
		else:
			_worm_id[idx] = 0
			director.spawned += 1
	if director.should_spawn_boss():
		director.boss_spawned = true
		# The network purges its own processes to make room for ICE. Mechanically
		# this is what makes the boss the fight rather than one target buried in
		# a few hundred leftovers that spawning already stopped replacing.
		# Despawn immediately rather than marking DEAD: recycle is step 9, so a
		# marked-but-not-freed pool is still full here and the boss spawn
		# silently returns -1 while boss_spawned is set, so it never retries.
		while enemies.count > 0:
			enemies.despawn(enemies.count - 1)
		_worm_trail.clear()
		_worm_cursor.clear()
		var b = enemy_types[EnemyTable.ICE]
		var a := _rng.randf() * TAU
		var bi := enemies.spawn(player_pos + Vector2(cos(a), sin(a)) * 420.0,
			Vector2.ZERO, b.integrity, 48.0, EnemyTable.ICE)
		assert(bi >= 0, "boss failed to spawn into a freshly emptied pool")
		emit_signal("stats_changed")

## Longer worms later in the run: two segments at the start, up to six by the
## time ICE arrives.
func _worm_length() -> int:
	return mini(WORM_MAX_SEGMENTS,
		WORM_BASE_SEGMENTS + int(director.elapsed / WORM_GROWTH_SECONDS))

func _spawn_worm(at: Vector2) -> bool:
	var t = enemy_types[WORM_TYPE]
	var n := _worm_length()
	if enemies.count + n > MAX_ENEMIES:
		return false
	var id := _next_worm_id
	_next_worm_id += 1
	var trail := PackedVector2Array()
	trail.resize(WORM_TRAIL_LEN)
	trail.fill(at)
	_worm_trail[id] = trail
	_worm_cursor[id] = 0
	for k in n:
		var idx := enemies.spawn(at, Vector2.ZERO, t.integrity, ENEMY_RADIUS, WORM_TYPE)
		if idx < 0:
			return k > 0
		_worm_id[idx] = id
		_worm_seg[idx] = k
	return true

func _worm_sample(id: int, steps_back: int) -> Vector2:
	var trail: PackedVector2Array = _worm_trail[id]
	var c: int = _worm_cursor[id]
	return trail[(c - steps_back + WORM_TRAIL_LEN * 2) % WORM_TRAIL_LEN]

func _step2_integrate(dt: float) -> void:
	# Polled directly so no InputMap entries are needed. WASD and arrows both.
	var input := Vector2.ZERO
	if input_override != null:
		input = input_override
	else:
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
			input.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
			input.x += 1.0
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
			input.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
			input.y += 1.0
	if input.length_squared() > 0.0:
		player_pos += input.normalized() * PLAYER_SPEED * dt
	player_pos = player_pos.clamp(ARENA_ORIGIN + Vector2(40, 40),
		ARENA_ORIGIN + ARENA_SIZE - Vector2(40, 40))
	if player_iframe > 0.0:
		player_iframe -= dt

	# Heads and ordinary enemies move first so the trail is current before the
	# segments sample it this same tick.
	for i in enemies.count:
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			continue
		var t = enemy_types[enemies.type_index[i]]
		var to := (player_pos - enemies.pos[i]).normalized()
		enemies.vel[i] = to * t.speed + enemies.force[i]
		enemies.pos[i] += enemies.vel[i] * dt
		if _worm_id[i] != 0:
			var id := _worm_id[i]
			var c: int = (_worm_cursor[id] + 1) % WORM_TRAIL_LEN
			_worm_cursor[id] = c
			var trail: PackedVector2Array = _worm_trail[id]
			trail[c] = enemies.pos[i]
			_worm_trail[id] = trail
	for i in enemies.count:
		var wid := _worm_id[i]
		if wid == 0 or _worm_seg[i] == 0:
			continue
		if not _worm_trail.has(wid):
			continue
		var prev := enemies.pos[i]
		enemies.pos[i] = _worm_sample(wid, _worm_seg[i] * WORM_SEG_STEPS)
		enemies.vel[i] = (enemies.pos[i] - prev) / maxf(dt, 0.0001)
	for i in projectiles.count:
		projectiles.pos[i] += projectiles.vel[i] * dt
	for i in botnet.count:
		_botnet_life[i] -= dt
	for i in shards.count:
		var d := player_pos - shards.pos[i]
		# Magnet reach. Was 6x the pickup radius (288 px), which meant shards
		# came to you from most of the screen and collection was never a
		# positioning decision.
		if d.length() < pickup_radius * 2.2:
			shards.pos[i] += d.normalized() * 300.0 * dt

func _step3_rebuild() -> void:
	_pos_arrays[Grid.Pop.ENEMY] = enemies.pos
	_pos_arrays[Grid.Pop.PROJECTILE] = projectiles.pos
	_pos_arrays[Grid.Pop.BOTNET] = botnet.pos
	_pos_arrays[Grid.Pop.SHARD] = shards.pos
	_counts[Grid.Pop.ENEMY] = enemies.count
	_counts[Grid.Pop.PROJECTILE] = projectiles.count
	_counts[Grid.Pop.BOTNET] = botnet.count
	_counts[Grid.Pop.SHARD] = shards.count
	grid.rebuild(_pos_arrays, _counts)

## Steering is time-sliced across STEER_SLICES ticks: each tick recomputes one
## slice and every other enemy keeps the force it was last given. At 60 Hz a
## force is at most 2 ticks (33 ms) stale, which is invisible on a separation
## nudge, and it was the largest single item in the tick by a wide margin.
func _step4_steer() -> void:
	_steer_phase = (_steer_phase + 1) % STEER_SLICES
	var i := _steer_phase
	while i < enemies.count:
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			i += STEER_SLICES
			continue
		var here := enemies.pos[i]
		if here.distance_squared_to(player_pos) > STEER_RANGE_SQ:
			enemies.force[i] = Vector2.ZERO
			i += STEER_SLICES
			continue
		var n := grid.query_radius_into(here, SEPARATION_RADIUS, _buf, Grid.M_ENEMY)
		var push := Vector2.ZERO
		for k in mini(n, _buf.size()):
			var j := Grid.index_of(_buf[k])
			if j == i:
				continue
			var d := here - enemies.pos[j]
			var dl := d.length()
			if dl > 0.001:
				push += d / dl * (SEPARATION_RADIUS - dl)
		enemies.force[i] = push * 2.2
		i += STEER_SLICES

func _step5_fire(dt: float) -> void:
	queue.begin_tick()
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if r.inert:
			continue
		if r.trigger_kind != Module.TriggerKind.INTERVAL:
			continue
		_fire_acc[ei] += dt
		var fires := 0
		# Bank the remainder rather than zeroing: zeroing quantises the period to
		# tick multiples, so a cooldown of 0.051 fires at 0.0667 — a 24% DPS loss
		# that makes +cooling purchases do nothing until they cross a boundary.
		while _fire_acc[ei] >= r.cooldown and fires < FIRE_BUDGET:
			_fire_acc[ei] -= r.cooldown
			_emit_vector(ei, r)
			fires += 1
		_fire_acc[ei] = minf(_fire_acc[ei], r.cooldown * FIRE_BUDGET)

func _emit_vector(ei: int, r: ResolvedExploit) -> void:
	match r.vector_kind:
		Module.VectorKind.BROADCAST:
			var n := grid.query_radius_into(player_pos, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(n, _buf.size()):
				_hit(ei, r, Grid.index_of(_buf[k]))
		Module.VectorKind.BEAM:
			var target := _nearest_enemy(r.radius)
			if target < 0:
				return
			var dir := (enemies.pos[target] - player_pos).normalized()
			var n2 := grid.query_radius_into(player_pos + dir * r.radius * 0.5,
				r.radius * 0.5, _buf, Grid.M_ENEMY)
			var struck := 0
			for k in mini(n2, _buf.size()):
				if struck > r.pierce:
					break
				_hit(ei, r, Grid.index_of(_buf[k]))
				struck += 1
		Module.VectorKind.CHAIN:
			var t2 := _nearest_enemy(r.radius)
			if t2 < 0:
				return
			_hit(ei, r, t2)
			var from := enemies.pos[t2]
			var visited := [t2]
			var hops := 0
			while hops < r.chain_count:
				var n3 := grid.query_radius_into(from, 120.0, _buf, Grid.M_ENEMY)
				var picked := -1
				for k in mini(n3, _buf.size()):
					var j := Grid.index_of(_buf[k])
					# Excluding only the ORIGINAL target let every hop re-select
					# the enemy it had just jumped from — that enemy sits at
					# distance 0 from the query point. chain_count scaled nothing
					# but repeat hits on one target.
					if not (j in visited):
						picked = j
						break
				if picked < 0:
					break
				_hit(ei, r, picked)
				visited.append(picked)
				from = enemies.pos[picked]
				hops += 1
		_:
			# The viewport covers ~1113x626 world units at this zoom, so the
			# corner is ~640 away. Targeting at 1400 let packets fire at enemies
			# well off-screen — and made every shot walk the entire grid.
			var t3 := _nearest_enemy(VIEW_RANGE)
			var dir2 := Vector2.RIGHT if t3 < 0 else (enemies.pos[t3] - player_pos).normalized()
			var pi := projectiles.spawn(player_pos, dir2 * maxf(r.projectile_speed, 120.0),
				1.0, PROJECTILE_RADIUS, 0)
			if pi >= 0:
				_proj_owner[pi] = ei
				_proj_pierce[pi] = r.pierce
				_proj_last[pi] = -1

func _hit(ei: int, r: ResolvedExploit, target: int) -> void:
	if target < 0 or target >= enemies.count:
		return
	queue.append(HitQueue.Kind.DAMAGE, ei, target, enemies.generation[target], r.damage)
	if r.corruption > 0.0 and r.has_tag(&"corruption"):
		queue.append(HitQueue.Kind.CORRUPTION, ei, target, enemies.generation[target], r.corruption)

func _nearest_enemy(within: float) -> int:
	var n := grid.query_radius_into(player_pos, within, _buf, Grid.M_ENEMY)
	var best := -1
	var bd := INF
	for k in mini(n, _buf.size()):
		var j := Grid.index_of(_buf[k])
		var d := enemies.pos[j].distance_squared_to(player_pos)
		if d < bd:
			bd = d
			best = j
	return best

func _step6_detect(dt: float) -> void:
	# Projectiles. _proj_last is the hit memory: without it a stateless overlap
	# test re-hits the same enemy every tick it overlaps, so damage would scale
	# INVERSELY with projectile speed and pierce would have no meaning.
	for i in projectiles.count:
		var n := grid.query_radius_into(projectiles.pos[i],
			PROJECTILE_RADIUS + ENEMY_RADIUS, _buf, Grid.M_ENEMY)
		for k in mini(n, _buf.size()):
			var j := Grid.index_of(_buf[k])
			if j == _proj_last[i]:
				continue
			var ei := _proj_owner[i]
			if ei < resolved.size():
				_hit(ei, resolved[ei], j)
			_proj_last[i] = j
			_proj_pierce[i] -= 1
			if _proj_pierce[i] < 0:
				projectiles.state[i] = Population.DEAD
			break

	# Botnet auras.
	for i in botnet.count:
		var n2 := grid.query_radius_into(botnet.pos[i], 70.0, _buf, Grid.M_ENEMY)
		for k in mini(n2, _buf.size()):
			var j := Grid.index_of(_buf[k])
			queue.append(HitQueue.Kind.DAMAGE, -1, j, enemies.generation[j],
				_botnet_ratio[i] * dt)

	# Player contact. Enemies are not physics bodies, so this is a grid query —
	# an Area2D cannot overlap a packed array.
	if player_iframe <= 0.0:
		var n3 := grid.query_radius_into(player_pos, PLAYER_RADIUS + ENEMY_RADIUS,
			_buf, Grid.M_ENEMY)
		if n3 > 0:
			var t = enemy_types[enemies.type_index[Grid.index_of(_buf[0])]]
			_damage_player(t.contact_damage)

	# Pickups.
	var n4 := grid.query_radius_into(player_pos, pickup_radius, _buf, Grid.M_SHARD)
	for k in mini(n4, _buf.size()):
		shards.state[Grid.index_of(_buf[k])] = Population.DEAD
		_gain_xp(1)

func _damage_player(amount: float) -> void:
	player_health -= amount
	player_iframe = IFRAMES
	# ON_DAMAGE_TAKEN fires per damage instance the player actually takes — not
	# from a loop over terminally-marked entities, which would fire it once per
	# run, at game over.
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_emit_vector(ei, r)
	if player_health <= 0.0 and alive and not won:
		player_health = 0.0
		alive = false
		# Salvage is lost, but kills and flips still count toward unlocks —
		# otherwise a losing run gives nothing and the meta has no reason to
		# exist after a death, which is exactly what it is for.
		SaveGame.bank(0, kills, flips)
		emit_signal("run_ended", false, 0)
	emit_signal("stats_changed")

func _steps78_drain() -> void:
	for pass_i in CASCADE_PASSES:
		if queue.count == 0 and queue.hit_count == 0:
			break
		var hits_before := queue.hit_count
		var resolved_n := queue.drain_pass(enemies, thresholds)

		# ON_HIT fires per hit on an OPEN target, regardless of outcome. Gating
		# it on death makes the cascade the fire budget exists for impossible.
		# Fires on ANY hit the player landed, not only the owning exploit's.
		# Self-attribution makes ON_HIT depend on its own output, which cannot
		# bootstrap. Fired once per pass, not once per hit, so a 300-enemy aura
		# cannot turn one tick into N**8 events.
		if queue.hit_count > hits_before:
			for ei in resolved.size():
				var r: ResolvedExploit = resolved[ei]
				if not r.inert and r.trigger_kind == Module.TriggerKind.ON_HIT:
					_emit_vector(ei, r)

		# Break only when nothing resolved AND nothing new is queued. Breaking on
		# resolved_n alone discarded the events ON_HIT had just appended one line
		# above, so ON_HIT contributed nothing in any tick whose pass killed
		# nothing — the ordinary case the trigger exists for.
		if resolved_n == 0 and queue.count == 0:
			break

		# Consume each verdict as it is dispatched. outcome[] persists for the
		# whole tick and enemies.state[] until step 9, so an enemy resolved in
		# pass 1 matched again in every later pass: kills, shards, ON_KILL
		# cascades, lifesteal and botnet spawns all multiplied by cascade depth.
		# HitQueue held "adjudicated exactly once"; this loop, its only consumer,
		# broke it.
		if resolved_n > 0:
			for i in enemies.count:
				var o := queue.outcome[i]
				if o == HitQueue.Outcome.NONE:
					continue
				queue.outcome[i] = HitQueue.Outcome.NONE
				if o == HitQueue.Outcome.DEAD and enemies.state[i] == Population.DEAD:
					_on_death(i)
				elif o == HitQueue.Outcome.FLIPPED and enemies.state[i] == Population.FLIPPED:
					_on_flip(i)

func _on_death(i: int) -> void:
	kills += 1
	if enemies.type_index[i] == EnemyTable.ICE and not won:
		# kills is incremented FIRST: banking before it meant the kill that ends
		# a winning run was never persisted, so entering the boss at 399 kills
		# won, displayed 400, and saved 399 — silently missing the beam unlock.
		# The `not won` guard keeps a second dispatch from re-banking the run.
		won = true
		salvage += 500
		SaveGame.bank(salvage, kills, flips)
		emit_signal("run_ended", true, salvage)
	_drop_shards(i)
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_KILL:
			_emit_vector(ei, r)
	var killer := queue.killer_exploit[i]
	if killer >= 0 and killer < resolved.size():
		var lifesteal: float = resolved[killer].lifesteal
		if lifesteal > 0.0:
			player_health = minf(PLAYER_MAX_HEALTH, player_health + lifesteal)

## A flipped enemy drops the same shards a killed one does, so a corruption
## build does not starve its own level-ups in proportion to how well it works.
func _on_flip(i: int) -> void:
	flips += 1
	_drop_shards(i)
	var cap := BOTNET_BASE_CAP
	for r in resolved:
		cap += r.botnet_cap
	if botnet.count >= mini(cap, MAX_BOTNET):
		return
	var src := queue.flipper_exploit[i]
	var corr := 6.0
	if src >= 0 and src < resolved.size():
		corr = maxf(resolved[src].corruption, 1.0)
	var bi := botnet.spawn(enemies.pos[i], Vector2.ZERO, 1.0, ENEMY_RADIUS, 0)
	if bi >= 0:
		_botnet_ratio[bi] = BOTNET_BASE_RATIO * corr
		_botnet_life[bi] = BOTNET_BASE_LIFETIME

func _drop_shards(i: int) -> void:
	var t = enemy_types[enemies.type_index[i]]
	for s in t.shard_value:
		shards.spawn(enemies.pos[i] + Vector2(_rng.randf_range(-8, 8),
			_rng.randf_range(-8, 8)), Vector2.ZERO, 1.0, 4.0, 0)

func _step9_recycle() -> void:
	# A dead head takes its remaining segments with it: a headless chain has no
	# path to follow and would drift as a line of stragglers.
	var orphaned := {}
	for i in enemies.count:
		if enemies.state[i] != Population.ALIVE and _worm_id[i] != 0 and _worm_seg[i] == 0:
			orphaned[_worm_id[i]] = true
	if not orphaned.is_empty():
		for i in enemies.count:
			if orphaned.has(_worm_id[i]):
				enemies.state[i] = Population.DEAD
		for id in orphaned:
			_worm_trail.erase(id)
			_worm_cursor.erase(id)

	var i := 0
	while i < enemies.count:
		# FLIPPED retires the enemy slot too — it became a botnet node. Freeing
		# only DEAD leaves flipped entities in the swarm forever.
		if enemies.state[i] != Population.ALIVE:
			var last := enemies.count - 1
			_worm_id[i] = _worm_id[last]
			_worm_seg[i] = _worm_seg[last]
			enemies.despawn(i)
		else:
			i += 1
	i = 0
	while i < projectiles.count:
		var p := projectiles.pos[i]
		if projectiles.state[i] != Population.ALIVE \
				or p.distance_squared_to(player_pos) > 1600.0 * 1600.0:
			# Population.despawn swap-removes the tail into slot i, so every
			# parallel array must move with it. Omitting this let a surviving
			# projectile inherit a dead one's owner exploit (wrong damage and
			# wrong lifesteal attribution) and its exhausted pierce.
			var last := projectiles.count - 1
			_proj_owner[i] = _proj_owner[last]
			_proj_pierce[i] = _proj_pierce[last]
			_proj_last[i] = _proj_last[last]
			projectiles.despawn(i)
		else:
			i += 1
	i = 0
	while i < shards.count:
		if shards.state[i] != Population.ALIVE:
			shards.despawn(i)
		else:
			i += 1
	i = 0
	while i < botnet.count:
		if _botnet_life[i] <= 0.0:
			_botnet_life[i] = _botnet_life[botnet.count - 1]
			_botnet_ratio[i] = _botnet_ratio[botnet.count - 1]
			botnet.despawn(i)
		else:
			i += 1

# ------------------------------------------------------------ progression ---

func _gain_xp(n: int) -> void:
	xp += n
	while xp >= xp_needed:
		xp -= xp_needed
		level += 1
		# Was 20 + 12(n-1), taken from the spec. That curve assumed 10-14
		# kills/sec; the actual weapons produce ~0.5-4, so it stalled the run at
		# level 4. Measured against real play instead of derived from a rate.
		xp_needed = 5 + 3 * (level - 1)
		pending_levels += 1
	if pending_levels > 0 and not paused:
		_offer_cards()
	emit_signal("stats_changed")

## Multiple thresholds crossed in one tick queue; screens show in sequence.
func _offer_cards() -> void:
	paused = true
	var pool := []
	for m in _unlocked:
		var targets := loadout.legal_targets(m)
		if targets.is_empty():
			continue          # nothing legal: not worth a card slot
		pool.append([m, targets])
	# Seeded so a run reproduces exactly from a bug report.
	for i in range(pool.size() - 1, 0, -1):
		var j := _card_rng.randi_range(0, i)
		var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp
	var cards := []
	for entry in pool:
		if cards.size() >= 3:
			break
		cards.append(entry)
	while cards.size() < 3:
		cards.append([null, []])        # salvage card fallback
	emit_signal("level_up_offered", cards)

func choose_card(m, target) -> void:
	if m == null:
		salvage += 50
	else:
		loadout.place_at(m, target.exploit, target.slot)
		_recompile()
	pending_levels = maxi(0, pending_levels - 1)
	paused = false
	if pending_levels > 0:
		_offer_cards()
	emit_signal("stats_changed")

func decline_card() -> void:
	salvage += 25
	pending_levels = maxi(0, pending_levels - 1)
	paused = false
	if pending_levels > 0:
		_offer_cards()
	emit_signal("stats_changed")

func time_left() -> float:
	return maxf(0.0, SpawnDirector.SUBNET_SECONDS - director.elapsed)

# --------------------------------------------------------------- rendering ---

func _make_mm(size: float, z: int) -> MultiMeshInstance2D:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true      # carries the glyph index
	mm.mesh = quad
	var node := MultiMeshInstance2D.new()
	node.multimesh = mm
	node.z_index = z
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/glyph.gdshader")
	node.material = mat
	add_child(node)
	return node

## Neon on black. Glow comes from WorldEnvironment with HDR 2D rather than a
## CanvasLayer shader — one full-screen pass cannot do a separable blur without
## a BackBufferCopy, and this path is both cheaper and idiomatic.
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.016, 0.031, 0.027)
	env.glow_enabled = true
	env.glow_intensity = 1.6
	env.glow_bloom = 0.55
	env.glow_strength = 1.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 0.4
	for i in 4:
		env.set("glow_levels/%d" % (i + 2), 1.0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var grid_lines := Node2D.new()
	grid_lines.set_script(load("res://scripts/run/backdrop.gd"))
	grid_lines.z_index = -10
	add_child(grid_lines)
	grid_lines.set("target", self)

## Only enemies need per-frame colour (the corruption lerp) and per-frame glyph
## (type varies by slot). Projectiles, shards and botnet nodes are one colour and
## one glyph for the life of the pool, and MultiMesh instance buffers persist —
## so those are written once here instead of ~4000 setter calls every frame.
func _prime_constant_instances(node: MultiMeshInstance2D, glyph: float, c: Color) -> void:
	var mm := node.multimesh
	for i in mm.instance_count:
		mm.set_instance_color(i, c)
		mm.set_instance_custom_data(i, Color(glyph, 0.0, 0.0, 0.0))

func _build_renderers() -> void:
	_mm_enemy = _make_mm(30.0, 2)
	_mm_enemy.multimesh.instance_count = MAX_ENEMIES
	_mm_proj = _make_mm(13.0, 3)
	_mm_proj.multimesh.instance_count = MAX_PROJECTILES
	_mm_shard = _make_mm(9.0, 1)
	_mm_shard.multimesh.instance_count = MAX_SHARDS
	_mm_botnet = _make_mm(26.0, 2)
	_mm_botnet.multimesh.instance_count = MAX_BOTNET

	_prime_constant_instances(_mm_proj, 4.0, Color(1.1, 1.7, 1.4))
	_prime_constant_instances(_mm_shard, 5.0, Color(0.5, 1.3, 1.7))
	_prime_constant_instances(_mm_botnet, 3.0, Color(1.6, 0.5, 1.6))

func _update_renderers() -> void:
	var mm := _mm_enemy.multimesh
	mm.visible_instance_count = enemies.count
	for i in enemies.count:
		var t = enemy_types[enemies.type_index[i]]
		var s: float = 2.4 if enemies.type_index[i] == EnemyTable.ICE else 1.0
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2(s, s), 0.0, enemies.pos[i]))
		var frac: float = clampf(enemies.corruption[i] / maxf(thresholds[enemies.type_index[i]], 0.001), 0.0, 1.0)
		var shade := 1.15
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			shade = 1.15 * (0.82 - 0.07 * mini(_worm_seg[i], 4))
		mm.set_instance_color(i, t.color.lerp(Color(1.5, 0.25, 1.5), frac) * shade)
		mm.set_instance_custom_data(i, Color(float(t.glyph), 0.0, 0.0, 0.0))
	mm = _mm_proj.multimesh
	mm.visible_instance_count = projectiles.count
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, projectiles.pos[i]))
	mm = _mm_shard.multimesh
	mm.visible_instance_count = shards.count
	for i in shards.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, shards.pos[i]))
	mm = _mm_botnet.multimesh
	mm.visible_instance_count = botnet.count
	for i in botnet.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, botnet.pos[i]))

func _draw() -> void:
	var pts := PackedVector2Array([
		player_pos + Vector2(0, -14), player_pos + Vector2(12, 8),
		player_pos + Vector2(0, 3), player_pos + Vector2(-12, 8)])
	var c := Color(0.9, 1.8, 1.3) if player_iframe <= 0.0 else Color(1.9, 0.8, 0.8)
	draw_polyline(pts + PackedVector2Array([pts[0]]), c, 2.0)
	draw_arc(player_pos, pickup_radius, 0, TAU, 40, Color(0.35, 0.9, 0.7, 0.22), 1.0)
