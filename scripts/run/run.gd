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
const SPAWN_RING := 720.0

const PLAYER_MAX_HEALTH := 100.0
const PLAYER_SPEED := 220.0
const PLAYER_RADIUS := 11.0
const PICKUP_RADIUS := 48.0
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

var thresholds: PackedFloat32Array
var enemy_types: Array
var resolved: Array = []
var _fire_acc: PackedFloat32Array
var _proj_owner: PackedInt32Array
var _proj_pierce: PackedInt32Array
var _proj_last: PackedInt32Array
var _botnet_ratio: PackedFloat32Array
var _botnet_life: PackedFloat32Array
var _botnet_seq: PackedInt32Array
var _seq := 0

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
	_botnet_ratio = PackedFloat32Array(); _botnet_ratio.resize(MAX_BOTNET)
	_botnet_life = PackedFloat32Array(); _botnet_life.resize(MAX_BOTNET)
	_botnet_seq = PackedInt32Array(); _botnet_seq.resize(MAX_BOTNET)

	var table := ModuleTable.by_id()
	loadout = Loadout.new()
	loadout.start(table[&"packet"], table[&"interval"])
	loadout.buffs = SaveGame.buff_stats()
	_unlocked = SaveGame.unlocked_modules()
	_recompile()

	_build_renderers()
	_camera = Camera2D.new()
	_camera.zoom = Vector2(1.15, 1.15)
	add_child(_camera)
	_camera.make_current()

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
		var t = enemy_types[ti]
		if enemies.spawn(s[1], Vector2.ZERO, t.integrity, ENEMY_RADIUS, ti) < 0:
			director.dropped += 1
		else:
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
		var b = enemy_types[EnemyTable.ICE]
		var a := _rng.randf() * TAU
		var bi := enemies.spawn(player_pos + Vector2(cos(a), sin(a)) * 420.0,
			Vector2.ZERO, b.integrity, 48.0, EnemyTable.ICE)
		assert(bi >= 0, "boss failed to spawn into a freshly emptied pool")
		emit_signal("stats_changed")

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

	for i in enemies.count:
		var t = enemy_types[enemies.type_index[i]]
		var to := (player_pos - enemies.pos[i]).normalized()
		enemies.vel[i] = to * t.speed + enemies.force[i]
		enemies.pos[i] += enemies.vel[i] * dt
	for i in projectiles.count:
		projectiles.pos[i] += projectiles.vel[i] * dt
	for i in botnet.count:
		_botnet_life[i] -= dt
	for i in shards.count:
		var d := player_pos - shards.pos[i]
		if d.length() < PICKUP_RADIUS * 6.0:
			shards.pos[i] += d.normalized() * 340.0 * dt

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

func _step4_steer() -> void:
	for i in enemies.count:
		var here := enemies.pos[i]
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
			var hops := 0
			while hops < r.chain_count:
				var n3 := grid.query_radius_into(from, 120.0, _buf, Grid.M_ENEMY)
				var picked := -1
				for k in mini(n3, _buf.size()):
					var j := Grid.index_of(_buf[k])
					if j != t2:
						picked = j
						break
				if picked < 0:
					break
				_hit(ei, r, picked)
				from = enemies.pos[picked]
				hops += 1
		_:
			var t3 := _nearest_enemy(1400.0)
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
	var n4 := grid.query_radius_into(player_pos, PICKUP_RADIUS, _buf, Grid.M_SHARD)
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
	if player_health <= 0.0:
		player_health = 0.0
		alive = false
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

		if resolved_n == 0:
			break
		for i in enemies.count:
			if queue.outcome[i] == HitQueue.Outcome.DEAD and enemies.state[i] == Population.DEAD:
				_on_death(i)
			elif queue.outcome[i] == HitQueue.Outcome.FLIPPED and enemies.state[i] == Population.FLIPPED:
				_on_flip(i)

func _on_death(i: int) -> void:
	if enemies.type_index[i] == EnemyTable.ICE:
		won = true
		salvage += 500
		SaveGame.bank(salvage, kills, flips)
		emit_signal("run_ended", true, salvage)
	kills += 1
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
		_seq += 1
		_botnet_seq[bi] = _seq

func _drop_shards(i: int) -> void:
	var t = enemy_types[enemies.type_index[i]]
	for s in t.shard_value:
		shards.spawn(enemies.pos[i] + Vector2(_rng.randf_range(-8, 8),
			_rng.randf_range(-8, 8)), Vector2.ZERO, 1.0, 4.0, 0)

func _step9_recycle() -> void:
	var i := 0
	while i < enemies.count:
		# FLIPPED retires the enemy slot too — it became a botnet node. Freeing
		# only DEAD leaves flipped entities in the swarm forever.
		if enemies.state[i] != Population.ALIVE:
			enemies.despawn(i)
		else:
			i += 1
	i = 0
	while i < projectiles.count:
		var p := projectiles.pos[i]
		if projectiles.state[i] != Population.ALIVE \
				or p.distance_squared_to(player_pos) > 1600.0 * 1600.0:
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
			_botnet_seq[i] = _botnet_seq[botnet.count - 1]
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
		var p := loadout.resolve(m)
		pool.append([m, p])
	# Seeded so a run reproduces exactly from a bug report.
	for i in range(pool.size() - 1, 0, -1):
		var j := _card_rng.randi_range(0, i)
		var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp
	var cards := []
	for entry in pool:
		if cards.size() >= 3:
			break
		if entry[1].rule != Loadout.Rule.NONE:
			cards.append(entry)
	while cards.size() < 3:
		cards.append([null, null])      # salvage card fallback
	emit_signal("level_up_offered", cards)

func choose_card(m, p) -> void:
	if m == null:
		salvage += 50
	else:
		loadout.apply(m, p)
		_recompile()
	pending_levels -= 1
	paused = false
	if pending_levels > 0:
		_offer_cards()
	emit_signal("stats_changed")

func decline_card() -> void:
	salvage += 25
	pending_levels -= 1
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
	mm.mesh = quad
	var node := MultiMeshInstance2D.new()
	node.multimesh = mm
	node.z_index = z
	add_child(node)
	return node

func _build_renderers() -> void:
	_mm_enemy = _make_mm(20.0, 2)
	_mm_enemy.multimesh.instance_count = MAX_ENEMIES
	_mm_proj = _make_mm(7.0, 3)
	_mm_proj.multimesh.instance_count = MAX_PROJECTILES
	_mm_shard = _make_mm(5.0, 1)
	_mm_shard.multimesh.instance_count = MAX_SHARDS
	_mm_botnet = _make_mm(16.0, 2)
	_mm_botnet.multimesh.instance_count = MAX_BOTNET

func _update_renderers() -> void:
	var mm := _mm_enemy.multimesh
	mm.visible_instance_count = enemies.count
	for i in enemies.count:
		var t = enemy_types[enemies.type_index[i]]
		var s: float = 2.4 if enemies.type_index[i] == EnemyTable.ICE else 1.0
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2(s, s), 0.0, enemies.pos[i]))
		var frac: float = clampf(enemies.corruption[i] / maxf(thresholds[enemies.type_index[i]], 0.001), 0.0, 1.0)
		mm.set_instance_color(i, t.color.lerp(Color(1.0, 0.2, 1.0), frac))
	mm = _mm_proj.multimesh
	mm.visible_instance_count = projectiles.count
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, projectiles.pos[i]))
		mm.set_instance_color(i, Color(0.75, 1.0, 0.9))
	mm = _mm_shard.multimesh
	mm.visible_instance_count = shards.count
	for i in shards.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, shards.pos[i]))
		mm.set_instance_color(i, Color(0.4, 0.9, 1.0))
	mm = _mm_botnet.multimesh
	mm.visible_instance_count = botnet.count
	for i in botnet.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, botnet.pos[i]))
		mm.set_instance_color(i, Color(1.0, 0.35, 1.0))

func _draw() -> void:
	var pts := PackedVector2Array([
		player_pos + Vector2(0, -14), player_pos + Vector2(12, 8),
		player_pos + Vector2(0, 3), player_pos + Vector2(-12, 8)])
	var c := Color(0.5, 1.0, 0.7) if player_iframe <= 0.0 else Color(1.0, 0.5, 0.5)
	draw_polyline(pts + PackedVector2Array([pts[0]]), c, 2.0)
	draw_arc(player_pos, PICKUP_RADIUS, 0, TAU, 32, Color(0.3, 0.6, 0.5, 0.18), 1.0)
