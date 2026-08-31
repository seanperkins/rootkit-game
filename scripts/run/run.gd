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

## Isometric projection, applied at the RENDER and INPUT boundaries only.
## Simulation stays flat 2D: the grid, collision, steering, targeting and every
## distance in the tick are unchanged. This is a view transform, not a physics
## change, which is what keeps it cheap and reversible.
##
##   screen.x = (x - y) * K
##   screen.y = (x + y) * K / 2      <- the 2:1 squash
const ISO_K := 0.82

static func to_iso(p: Vector2) -> Vector2:
	return Vector2((p.x - p.y) * ISO_K, (p.x + p.y) * ISO_K * 0.5)

static func from_iso(s: Vector2) -> Vector2:
	var a := s.x / ISO_K
	var b := s.y / (ISO_K * 0.5)
	return Vector2((b + a) * 0.5, (b - a) * 0.5)

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

const PLAYER_RADIUS := 11.0
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
var terrain: Terrain

## Per-enemy slow, owned here rather than by the module pass that will also use
## it: terrain's SLOW zones need it first, and one mechanic with one home is
## worth more than two implementations that drift apart.
var _slow_left: PackedFloat32Array
var _slow_factor: PackedFloat32Array

## Per-enemy AI memory. Sized MAX_ENEMIES and reset on every spawn, because
## Population.spawn recycles slots and a stale phase is a live bug — an enemy
## that inherits a mid-dash timer commits to a dash it never wound up for.
var _ai_phase: PackedInt32Array
var _ai_timer: PackedFloat32Array
var _ai_aim: PackedVector2Array
## The ceiling on healing: an enemy may never be healed above what its type and
## subnet gave it at spawn.
var _spawn_hp: PackedFloat32Array
## Out of the entity grid, and therefore untouchable and harmless.
var _submerged: PackedByteArray

## Set by the zone pass each tick and read by _eff_clock_speed, so a slow zone
## affects the player without a second timer: standing in it IS the duration.
var _zone_slow_player := false
var queue: HitQueue
var loadout: Loadout
var director: SpawnDirector

var player_pos := Vector2.ZERO
## The merged base + meta player sheet. Seeded in _ready, because a declaration
## initialiser is evaluated before _ready reads the save — a player with memory
## ranks would otherwise start every run at the base 100.
var _sheet: Dictionary = PlayerStats.BASE.duplicate()
var player_health := 0.0
var player_iframe := 0.0
var alive := true
var won := false
var subnet := 1

## What the run is DOING, as one fact.
##
## This was spread across `paused`, `won` and `_advance_pending`, which between
## them could describe states that cannot exist and could not describe the one
## that now does — cleared, still alive, waiting on the player to walk. The
## director steps in FIGHTING and in no other phase, which is exactly the
## property the old triple kept getting wrong.
enum Phase { FIGHTING, CLEARED, TRANSIT }
var phase := Phase.FIGHTING
var corridor: Terrain = null
## director.spawned is per-SUBNET, because director.reset() zeroes it on every
## advance. The campaign total has to survive that.
var _spawned_before := 0

## Banking is INCREMENTAL now a run spans several subnets. SaveGame.bank()
## ACCUMULATES into the save, so handing it the running totals at every subnet
## clear would count subnet 01's kills three times over and hand out unlock
## milestones nobody earned.
var _banked := {&"salvage": 0, &"kills": 0, &"flips": 0}

var level := 1
var xp := 0
var xp_needed := _xp_for(1)
var salvage := 0
var kills := 0
var flips := 0
var pending_levels := 0
var paused := false
var pickup_radius := 0.0
var _steer_phase := 0
## Diagnostic only: how many times each exploit's vector was emitted this tick.
var _trigger_fires := {}
## Time until each exploit may fire again. INTERVAL uses its own accumulator;
## this gates the EVENT triggers, which previously had no rate limit at all —
## ON_KILL fired once per adjudicated death, so in a swarm it ran continuously
## and was bounded only by the per-tick fire budget.
## One float per exploit. A fire arms it; _step2_integrate decays it. While it is
## live, that exploit's ward_* values count toward the player's effective stats —
## as a MAX across exploits, never a sum, because the same module is legal in
## several slots and summing would buy magnitude at no uptime cost.
var _ward_left: PackedFloat32Array
var _fire_cd: PackedFloat32Array
## Transient shot visuals. BROADCAST, BEAM and CHAIN resolve straight through
## the hit queue and drew nothing at all — you saw enemies die with no sign of
## what killed them. Bounded by the fire budget: 3 exploits x 4 fires x FX_LIFE
## worth of ticks.
const FX_LIFE := 0.13
var _fx_line: Array = []      # [a, b, t, colour]
var _fx_ring: Array = []      # [centre, radius, t, colour]
var _order: PackedInt32Array
var _band_count: PackedInt32Array
const DEPTH_BANDS := 192

var thresholds: PackedFloat32Array
var enemy_types: Array
var resolved: Array = []
var _fire_acc: PackedFloat32Array
var _proj_owner: PackedInt32Array
var _proj_pierce: PackedInt32Array
var _proj_last: PackedInt32Array
## Remaining flight distance. This is the ONLY lifetime bound on a projectile.
## The old player-relative 1600-unit cull is gone: it was measured FROM THE
## PLAYER, so fleeing at a legal buffed clock_speed could cull a max-reach packet
## early and make reach silently inert exactly when you run away. Max travel is
## 832px, so projectiles now live shorter than they used to, not longer.
var _proj_dist_left: PackedFloat32Array
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
	_refresh_thresholds()
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
	# Generated from the player's start, because the spawn-safe margin is
	# measured from wherever they actually are.
	terrain = Terrain.new(ARENA_ORIGIN, ARENA_SIZE)
	terrain.generate(_rng.seed, subnet, player_pos,
		subnet < SpawnDirector.CAMPAIGN_SUBNETS)

	_buf = PackedInt32Array(); _buf.resize(1024)
	_counts = PackedInt32Array(); _counts.resize(4)
	_pos_arrays = [null, null, null, null]
	_fire_acc = PackedFloat32Array(); _fire_acc.resize(Loadout.MAX_EXPLOITS)
	_fire_cd = PackedFloat32Array(); _fire_cd.resize(Loadout.MAX_EXPLOITS)
	_ward_left = PackedFloat32Array(); _ward_left.resize(Loadout.MAX_EXPLOITS)
	_proj_owner = PackedInt32Array(); _proj_owner.resize(MAX_PROJECTILES)
	_proj_pierce = PackedInt32Array(); _proj_pierce.resize(MAX_PROJECTILES)
	_proj_last = PackedInt32Array(); _proj_last.resize(MAX_PROJECTILES)
	_proj_dist_left = PackedFloat32Array(); _proj_dist_left.resize(MAX_PROJECTILES)
	_slow_left = PackedFloat32Array(); _slow_left.resize(MAX_ENEMIES)
	_ai_phase = PackedInt32Array(); _ai_phase.resize(MAX_ENEMIES)
	_ai_timer = PackedFloat32Array(); _ai_timer.resize(MAX_ENEMIES)
	_ai_aim = PackedVector2Array(); _ai_aim.resize(MAX_ENEMIES)
	_spawn_hp = PackedFloat32Array(); _spawn_hp.resize(MAX_ENEMIES)
	_submerged = PackedByteArray(); _submerged.resize(MAX_ENEMIES)
	_slow_factor = PackedFloat32Array(); _slow_factor.resize(MAX_ENEMIES)
	_worm_id = PackedInt32Array(); _worm_id.resize(MAX_ENEMIES)
	_worm_seg = PackedInt32Array(); _worm_seg.resize(MAX_ENEMIES)
	_order = PackedInt32Array(); _order.resize(MAX_ENEMIES)
	_band_count = PackedInt32Array(); _band_count.resize(DEPTH_BANDS + 1)
	_botnet_ratio = PackedFloat32Array(); _botnet_ratio.resize(MAX_BOTNET)
	_botnet_life = PackedFloat32Array(); _botnet_life.resize(MAX_BOTNET)

	var table := ModuleTable.by_id()
	loadout = Loadout.new()
	loadout.start(table[&"packet"], table[&"interval"])
	loadout.mult = PlayerStats.mults(SaveGame.multipliers())
	_sheet = PlayerStats.sheet(SaveGame.player_sheet())
	player_health = _sheet[&"integrity"]
	pickup_radius = _sheet[&"pickup_radius"]
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

func _eff_integrity() -> float:
	return _sheet[&"integrity"]

## Max over live wards, never a sum. Loadout has no module-uniqueness rule, so
## all six payload slots can hold the same ward; summing turns that into a
## build the design explicitly rejects.
func _ward_max(key: StringName) -> float:
	var best := 0.0
	for ei in mini(_ward_left.size(), resolved.size()):
		if _ward_left[ei] > 0.0:
			best = maxf(best, float(resolved[ei].get(key)))
	return best

func _eff_armor() -> float:
	return _sheet[&"armor"] + _ward_max(&"ward_armor")

func _eff_defense() -> float:
	return _sheet[&"defense"] + _ward_max(&"ward_defense")

func _eff_clock_speed() -> float:
	var v: float = _sheet[&"clock_speed"] + _ward_max(&"ward_clock_speed")
	# Applied last, so a slow zone cuts the total rather than the base and
	# cannot be out-scaled by buying clock_speed in the shop.
	if _zone_slow_player:
		v *= Terrain.SLOW_FACTOR
	return v

func _mitigated(amount: float) -> float:
	return PlayerStats.mitigate(amount, _eff_armor(), _eff_defense())

func _recompile() -> void:
	resolved = loadout.compile_all()
	emit_signal("stats_changed")

# ---------------------------------------------------------------- the tick ---

func _physics_process(dt: float) -> void:
	if paused or not alive or won:
		return

	# The director steps in FIGHTING and nowhere else: a cleared subnet stops
	# producing, and the corridor never produces at all.
	if phase == Phase.FIGHTING:
		_step1_spawn(dt)
	_step2_integrate(dt)
	_step2c_gate()
	_step2b_zones(dt)
	_step3_rebuild()
	_step4_steer()
	_step5_fire(dt)
	_step6_detect(dt)
	_steps78_drain()
	_step9_recycle()

	_update_renderers()
	_camera.global_position = to_iso(player_pos)
	queue_redraw()

func _step1_spawn(dt: float) -> void:
	for s in director.step(dt, player_pos, SPAWN_RING):
		var ti: int = s[0]
		# The spawn ring is centred on the player and does not know about the
		# arena, so near an edge it placed enemies outside the map — invisible
		# against the void in the isometric view, and unreachable in either.
		s[1] = (s[1] as Vector2).clamp(
			ARENA_ORIGIN + Vector2(24, 24),
			ARENA_ORIGIN + ARENA_SIZE - Vector2(24, 24))
		if ti == WORM_TYPE:
			if _spawn_worm(s[1]):
				director.spawned += 1
			else:
				director.dropped += 1
			continue
		var t = enemy_types[ti]
		var hp: float = t.integrity * _hp_mult()
		var idx := enemies.spawn(field().nearest_open(s[1]), Vector2.ZERO,
			hp, ENEMY_RADIUS, ti)
		if idx < 0:
			director.dropped += 1
		else:
			_spawn_enemy_state(idx, hp)
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
		var bi := enemies.spawn(
			field().nearest_open(player_pos + Vector2(cos(a), sin(a)) * 420.0),
			Vector2.ZERO, b.integrity * _hp_mult(), 48.0, EnemyTable.ICE)
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
		var whp: float = t.integrity * _hp_mult()
		var idx := enemies.spawn(field().nearest_open(at), Vector2.ZERO,
			whp, ENEMY_RADIUS, WORM_TYPE)
		if idx < 0:
			return k > 0
		# After _spawn_enemy_state, which zeroes _worm_id.
		_spawn_enemy_state(idx, whp)
		_worm_id[idx] = id
		_worm_seg[idx] = k
	return true

func _worm_sample(id: int, steps_back: int) -> Vector2:
	var trail: PackedVector2Array = _worm_trail[id]
	var c: int = _worm_cursor[id]
	return trail[(c - steps_back + WORM_TRAIL_LEN * 2) % WORM_TRAIL_LEN]

func _step2_integrate(dt: float) -> void:
	# Polled directly so no InputMap entries are needed. WASD and arrows both.
	#
	# input_override is a WORLD direction — it is a simulation hook for headless
	# drivers, which reason in world space. Keyboard input is SCREEN-relative and
	# is unprojected below, so W moves you up the screen rather than up the world
	# axis (which under the projection points diagonally).
	var input := Vector2.ZERO
	var world_dir := Vector2.ZERO
	if input_override != null:
		world_dir = (input_override as Vector2).normalized()
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
		# Uniform SCREEN speed, not uniform world speed.
		#
		# Normalising the WORLD direction keeps world speed constant, which makes
		# on-screen speed inherit the 2:1 squash — left/right moves twice as fast
		# as up/down, which is what makes the controls feel lopsided. Because
		# to_iso(from_iso(d)) == d exactly, feeding the unprojected direction
		# through WITHOUT renormalising makes the on-screen velocity exactly
		# clock_speed in every direction.
		#
		# The trade is that world speed now varies with heading (fastest along
		# the screen vertical, where the projection compresses most). That is the
		# right way round for a game where every dodge is judged on screen.
		world_dir = from_iso(input.normalized())
	if world_dir.length_squared() > 0.0:
		player_pos = field().slide(player_pos,
			world_dir * _eff_clock_speed() * dt)
	player_pos = player_pos.clamp(ARENA_ORIGIN + Vector2(40, 40),
		ARENA_ORIGIN + ARENA_SIZE - Vector2(40, 40))
	if player_iframe > 0.0:
		player_iframe -= dt
	for wi in _ward_left.size():
		if _ward_left[wi] > 0.0:
			_ward_left[wi] -= dt

	# Heads and ordinary enemies move first so the trail is current before the
	# segments sample it this same tick.
	for i in enemies.count:
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			continue
		var t = enemy_types[enemies.type_index[i]]
		enemies.vel[i] = _behave(i, t, dt) + enemies.force[i]
		# Worms phase through terrain, HEADS INCLUDED. Segments are sampled from
		# the head's trail rather than integrated, so colliding the head alone
		# would stretch the body through the wall the head is stuck against.
		if _worm_id[i] != 0:
			enemies.pos[i] += enemies.vel[i] * dt
		else:
			# Hard rejection, not a hope. Avoidance is steering and can fail on a
			# concave wall; this is what makes "no enemy ends a tick inside rock"
			# true for every enemy on every tick regardless of how steering did.
			enemies.pos[i] = field().slide(enemies.pos[i], enemies.vel[i] * dt)
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
		# Population stores no scalar speed, so the step is the velocity's
		# length: one sqrt per live projectile per tick, bounded by
		# MAX_PROJECTILES. This is the first thing that can mark a projectile
		# dead in step 2, which is why _step6_detect needs its state guard.
		_proj_dist_left[i] -= projectiles.vel[i].length() * dt
		if _proj_dist_left[i] <= 0.0:
			projectiles.state[i] = Population.DEAD
		# Terrain stops shots. This is what makes a wall cover rather than
		# decoration, and it is the same O(1) lookup the player's movement uses.
		elif field().is_solid(projectiles.pos[i]):
			projectiles.state[i] = Population.DEAD
	for i in botnet.count:
		_botnet_life[i] -= dt
	_age_fx(dt)
	for i in shards.count:
		var d := player_pos - shards.pos[i]
		# Magnet reach. Was 6x the pickup radius (288 px), which meant shards
		# came to you from most of the screen and collection was never a
		# positioning decision.
		if d.length() < pickup_radius * 2.2:
			shards.pos[i] += d.normalized() * 300.0 * dt

func _age_fx(dt: float) -> void:
	var i := 0
	while i < _fx_line.size():
		_fx_line[i][2] -= dt
		if _fx_line[i][2] <= 0.0:
			_fx_line.remove_at(i)
		else:
			i += 1
	i = 0
	while i < _fx_ring.size():
		_fx_ring[i][2] -= dt
		if _fx_ring[i][2] <= 0.0:
			_fx_ring.remove_at(i)
		else:
			i += 1

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
		enemies.force[i] = push * 2.2 + field().avoid(here, player_pos - here)
		i += STEER_SLICES

## Event triggers respond only when off cooldown. Returns false when the
## exploit is still recovering, so callers can skip the emit.
func _try_event_fire(ei: int, r: ResolvedExploit) -> bool:
	if _fire_cd[ei] > 0.0:
		return false
	_fire_cd[ei] = r.cooldown
	_emit_vector(ei, r)
	return true

func _step5_fire(dt: float) -> void:
	queue.begin_tick()
	for ei in _fire_cd.size():
		if _fire_cd[ei] > 0.0:
			_fire_cd[ei] -= dt
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
	_trigger_fires[ei] = _trigger_fires.get(ei, 0) + 1
	# Before the match, deliberately. BEAM and CHAIN return early when they have
	# no target, and a defensive build on those vectors must still ward — it has
	# already spent its cooldown by the time it reaches here, because
	# _try_event_fire sets _fire_cd before calling this.
	if r.ward_duration > 0.0:
		_ward_left[ei] = r.ward_duration
	match r.vector_kind:
		Module.VectorKind.BROADCAST:
			_fx_ring.append([player_pos, r.radius, FX_LIFE, Color(0.5, 1.7, 1.1)])
			var n := grid.query_radius_into(player_pos, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(n, _buf.size()):
				_hit(ei, r, Grid.index_of(_buf[k]))
		Module.VectorKind.BEAM:
			var target := _nearest_enemy(r.radius)
			if target < 0:
				return
			var dir := (enemies.pos[target] - player_pos).normalized()
			_fx_line.append([player_pos, player_pos + dir * r.radius, FX_LIFE,
				Color(2.2, 1.4, 2.6)])
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
			_fx_line.append([player_pos, enemies.pos[t2], FX_LIFE, Color(1.0, 2.2, 1.6)])
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
				_fx_line.append([from, enemies.pos[picked], FX_LIFE, Color(1.0, 2.2, 1.6)])
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
				_proj_dist_left[pi] = maxf(r.travel, 1.0)

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
		# Travel expiry marks projectiles dead back in step 2, so a dead one can
		# reach this loop — it could not before, and without this guard it still
		# lands a hit on its expiry tick.
		if projectiles.state[i] != Population.ALIVE:
			continue
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
	# Triggers BEFORE the subtraction, so an on_damage_taken ward is up for the
	# hit that summoned it rather than the next one. ON_DAMAGE_TAKEN fires per
	# damage instance the player actually takes — not from a loop over
	# terminally-marked entities, which would fire it once per run, at game over.
	#
	# No recursion: the path is _try_event_fire -> _emit_vector -> _hit ->
	# queue.append, and nothing re-enters here.
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	player_health -= _mitigated(amount)
	player_iframe = IFRAMES
	if player_health <= 0.0 and alive and not won:
		_die()
	emit_signal("stats_changed")

## Extracted so the zone pass can reach it: a hazard kills exactly the way a
## swarm does, and two copies of the banking rules would drift.
func _die() -> void:
	player_health = 0.0
	alive = false
	# Salvage is lost, but kills and flips still count toward unlocks —
	# otherwise a losing run gives nothing and the meta has no reason to exist
	# after a death, which is exactly what it is for.
	_bank_progress(false)
	emit_signal("run_ended", false, 0)

## The STRONGER slow wins, never the most recent. Letting the latest write win
## means walking out of a heavy slow into a light one cancels the heavy one, so
## the weakest source in the game would become a cleanse.
## Population.spawn recycles slots, so a fresh enemy can land on an index whose
## previous occupant was slowed. A stale slow is a live bug, not a cosmetic one:
## it makes a newly spawned enemy crawl for no reason the player can see.
func _clear_ai(i: int) -> void:
	_ai_phase[i] = 0
	_ai_timer[i] = 0.0
	_ai_aim[i] = Vector2.ZERO
	_submerged[i] = 0

## Everything a freshly spawned enemy slot needs, in one place, so that adding a
## per-enemy array later cannot leave one spawn site behind — which is exactly
## how a stale-slot bug gets in.
func _spawn_enemy_state(i: int, hp: float) -> void:
	_worm_id[i] = 0
	_clear_slow(i)
	_clear_ai(i)
	_spawn_hp[i] = hp

## The desired velocity for one enemy, before separation and avoidance forces.
##
## A match in a loop that already runs, so a CHASE enemy costs one branch. The
## alternative — an object per enemy with a virtual step — would put six hundred
## allocations and six hundred virtual calls in the hot path to express six
## cases.
func _behave(i: int, t, dt: float) -> Vector2:
	var sp: float = t.speed
	if _slow_left[i] > 0.0:
		sp *= _slow_factor[i]
	var to_player := player_pos - enemies.pos[i]
	match t.behaviour:
		_:
			return to_player.normalized() * sp
	return to_player.normalized() * sp

func _clear_slow(i: int) -> void:
	_slow_left[i] = 0.0
	_slow_factor[i] = 1.0

func apply_slow(i: int, factor: float, seconds: float) -> void:
	if _slow_left[i] <= 0.0 or factor < _slow_factor[i]:
		_slow_factor[i] = factor
	_slow_left[i] = maxf(_slow_left[i], seconds)

## Zone effects, one array index per entity per tick.
func _step2b_zones(dt: float) -> void:
	_zone_slow_player = false
	var pz := field().zone_at(player_pos)
	if pz == Terrain.Kind.HAZARD:
		# Deliberately NOT through the contact-damage path: iframes exist to stop
		# a swarm chewing through you on touch, and a hazard you are standing in
		# is not a contact event. Armour and defence still apply.
		player_health -= _mitigated(Terrain.HAZARD_DPS * dt)
		if player_health <= 0.0 and alive and not won:
			_die()
	elif pz == Terrain.Kind.SLOW:
		_zone_slow_player = true
	for i in enemies.count:
		if _slow_left[i] > 0.0:
			_slow_left[i] -= dt
		match field().zone_at(enemies.pos[i]):
			Terrain.Kind.HAZARD:
				queue.append(HitQueue.Kind.DAMAGE, -1, i, enemies.generation[i],
					Terrain.HAZARD_DPS * dt)
			Terrain.Kind.SLOW:
				apply_slow(i, Terrain.SLOW_FACTOR, 0.5)
			Terrain.Kind.CORRUPTION:
				queue.append(HitQueue.Kind.CORRUPTION, -1, i,
					enemies.generation[i], Terrain.CORRUPTION_PER_SEC * dt)

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
					_try_event_fire(ei, r)

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
		salvage += 500
		if subnet < SpawnDirector.CAMPAIGN_SUBNETS:
			# CLEARED, not advanced. The advance is the player's move now: walk
			# to the gate. Safe to set inside the drain because it is a flag and
			# a bool — nothing is spawned, freed, or moved.
			phase = Phase.CLEARED
			terrain.gate_open = true
			_bank_progress(true)
		else:
			won = true
			_bank_progress(true)
			emit_signal("run_ended", true, salvage)
	_drop_shards(i)
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_KILL:
			_try_event_fire(ei, r)
	var killer := queue.killer_exploit[i]
	if killer >= 0 and killer < resolved.size():
		var lifesteal: float = resolved[killer].lifesteal
		if lifesteal > 0.0:
			player_health = minf(_eff_integrity(), player_health + lifesteal)

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
		if projectiles.state[i] != Population.ALIVE:
			# Population.despawn swap-removes the tail into slot i, so every
			# parallel array must move with it. Omitting this let a surviving
			# projectile inherit a dead one's owner exploit (wrong damage and
			# wrong lifesteal attribution) and its exhausted pierce.
			var last := projectiles.count - 1
			_proj_owner[i] = _proj_owner[last]
			_proj_pierce[i] = _proj_pierce[last]
			_proj_last[i] = _proj_last[last]
			_proj_dist_left[i] = _proj_dist_left[last]
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

# ---------------------------------------------------------------- campaign ---

func _hp_mult() -> float:
	return SpawnDirector.hp_mult(subnet, director.elapsed)

func _refresh_thresholds() -> void:
	var f := SpawnDirector.threshold_mult(subnet)
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold * f

func _bank_progress(with_salvage: bool) -> void:
	var s := (salvage - int(_banked[&"salvage"])) if with_salvage else 0
	SaveGame.bank(s, kills - int(_banked[&"kills"]), flips - int(_banked[&"flips"]))
	if with_salvage:
		_banked[&"salvage"] = salvage
	_banked[&"kills"] = kills
	_banked[&"flips"] = flips

## Carried forward: the loadout, the level, the XP, and whatever integrity the
## last subnet left. Reset: the clock, the wave table, and every live entity.
## The partial heal rewards the clear without erasing the damage a bad subnet
## did, so chip damage still accumulates across a campaign.
const SUBNET_CLEAR_HEAL := 0.30

## The terrain currently underfoot. Everything that collides or draws asks this
## rather than `terrain`, so the corridor needs no special cases anywhere.
func field() -> Terrain:
	return corridor if phase == Phase.TRANSIT else terrain

## Stepping into an open gate is the advance. Checked after movement so it reads
## the position the player actually reached this tick.
func _step2c_gate() -> void:
	var f := field()
	if not f.has_gate or not f.gate_open:
		return
	if player_pos.distance_to(f.gate_pos) > Terrain.GATE_RADIUS:
		return
	if phase == Phase.CLEARED:
		_enter_corridor()
	elif phase == Phase.TRANSIT:
		_leave_corridor()

func _enter_corridor() -> void:
	phase = Phase.TRANSIT
	corridor = Terrain.corridor()
	player_pos = corridor.corridor_entrance()
	# The clear heal lands HERE rather than on the ICE kill, so it rewards
	# leaving rather than killing — and exactly once, because the phase has
	# already changed by the time this could be reached again.
	player_health = minf(_eff_integrity(),
		player_health + _eff_integrity() * SUBNET_CLEAR_HEAL)
	for i in range(enemies.count - 1, -1, -1):
		enemies.despawn(i)
	for i in range(projectiles.count - 1, -1, -1):
		projectiles.despawn(i)
	emit_signal("stats_changed")

func _leave_corridor() -> void:
	phase = Phase.FIGHTING
	corridor = null
	_advance_subnet()

func spawned_total() -> int:
	return _spawned_before + director.spawned

func _advance_subnet() -> void:
	_spawned_before += director.spawned
	subnet += 1
	director.reset()
	_refresh_thresholds()
	# The player arrives at the arena's centre, and the arena is generated around
	# them so the spawn-safe margin lands where they actually stand. The last
	# subnet gets no gate: clearing its ICE wins outright.
	player_pos = ARENA_ORIGIN + ARENA_SIZE * 0.5
	terrain.generate(_rng.seed, subnet, player_pos,
		subnet < SpawnDirector.CAMPAIGN_SUBNETS)
	emit_signal("stats_changed")

# ------------------------------------------------------------ progression ---

## XP to clear ONE level. Level 1 seeds `xp_needed` from the same function, so
## the first level costs what the curve says it costs rather than a literal that
## drifts out of step with it.
##
## 1.8, not the 1.0 this started at: a build now matures across a whole campaign
## rather than inside one five-minute subnet, so the curve has three times the
## wall-clock to spend itself over. It was briefly 2.4, which starved the build
## badly enough that the autopiloted run died in subnet 01 every time.
const XP_SLOWDOWN := 1.8

static func _xp_for(lvl: int) -> int:
	return int(round(float(5 + 3 * (lvl - 1)) * XP_SLOWDOWN))

func _gain_xp(n: int) -> void:
	xp += n
	while xp >= xp_needed:
		xp -= xp_needed
		level += 1
		# Was 20 + 12(n-1), taken from the spec. That curve assumed 10-14
		# kills/sec; the actual weapons produce ~0.5-4, so it stalled the run at
		# level 4. Measured against real play instead of derived from a rate.
		#
		# The x1.5 on top of that measured curve is a deliberate slowdown: at
		# 5 + 3(n-1) a good build was fully assembled inside the first minute,
		# which spent every card before the run had any difficulty to spend
		# them against.
		xp_needed = _xp_for(level)
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
	# Depth order: farther up the screen draws first. Buckets rather than a
	# comparison sort — 600 entities every frame, and the band resolution is far
	# finer than the overlap it resolves.
	_depth_sort()
	for n in enemies.count:
		var i: int = _order[n]
		var t = enemy_types[enemies.type_index[i]]
		var s: float = 2.4 if enemies.type_index[i] == EnemyTable.ICE else 1.0
		mm.set_instance_transform_2d(n, Transform2D(0.0, Vector2(s, s), 0.0, to_iso(enemies.pos[i])))
		var frac: float = clampf(enemies.corruption[i] / maxf(thresholds[enemies.type_index[i]], 0.001), 0.0, 1.0)
		var shade := 1.15
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			shade = 1.15 * (0.82 - 0.07 * mini(_worm_seg[i], 4))
		mm.set_instance_color(n, t.color.lerp(Color(1.5, 0.25, 1.5), frac) * shade)
		mm.set_instance_custom_data(n, Color(float(t.glyph), 0.0, 0.0, 0.0))
	mm = _mm_proj.multimesh
	mm.visible_instance_count = projectiles.count
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(projectiles.pos[i])))
	mm = _mm_shard.multimesh
	mm.visible_instance_count = shards.count
	for i in shards.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(shards.pos[i])))
	mm = _mm_botnet.multimesh
	mm.visible_instance_count = botnet.count
	for i in botnet.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(botnet.pos[i])))

## Counting sort into screen-depth bands. O(n) with no comparisons, which is
## what makes per-entity depth ordering affordable at the enemy cap.
func _depth_sort() -> void:
	var n := enemies.count
	if n == 0:
		return
	for b in DEPTH_BANDS + 1:
		_band_count[b] = 0
	var lo := player_pos.x + player_pos.y - 1800.0
	var span := 3600.0
	for i in n:
		var key := clampi(int((enemies.pos[i].x + enemies.pos[i].y - lo) / span * DEPTH_BANDS),
			0, DEPTH_BANDS - 1)
		_band_count[key] += 1
	var acc := 0
	for b in DEPTH_BANDS:
		var c := _band_count[b]
		_band_count[b] = acc
		acc += c
	for i in n:
		var key2 := clampi(int((enemies.pos[i].x + enemies.pos[i].y - lo) / span * DEPTH_BANDS),
			0, DEPTH_BANDS - 1)
		_order[_band_count[key2]] = i
		_band_count[key2] += 1

func _draw() -> void:
	# Terrain first, so it sits under every entity.
	#
	# Drawn from `rects` rather than per-cell: the draw count is the number of
	# obstacles (a few dozen) rather than the number of solid cells (up to
	# eleven hundred). A world-space AABB under to_iso is a sheared
	# parallelogram, never a rect, so each is its four projected corners.
	for entry in field().rects:
		var tr: Rect2 = entry[0]
		var kind: int = entry[1]
		var quad := PackedVector2Array([
			to_iso(tr.position),
			to_iso(tr.position + Vector2(tr.size.x, 0)),
			to_iso(tr.position + tr.size),
			to_iso(tr.position + Vector2(0, tr.size.y))])
		match kind:
			Terrain.Kind.WALL:
				# Light enough to read as MASS against a near-black ground. At
				# 0.05 the fill was indistinguishable from the arena floor and a
				# wall registered only as its outline, which reads as a marking
				# on the ground rather than as something you cannot walk through.
				draw_colored_polygon(quad, Color(0.10, 0.21, 0.17))
				draw_polyline(quad + PackedVector2Array([quad[0]]),
					Color(0.45, 1.0, 0.72), 1.5)
			Terrain.Kind.HAZARD:
				draw_colored_polygon(quad, Color(1.0, 0.30, 0.28, 0.15))
			Terrain.Kind.SLOW:
				draw_colored_polygon(quad, Color(0.40, 0.60, 1.0, 0.13))
			Terrain.Kind.CORRUPTION:
				draw_colored_polygon(quad, Color(0.85, 0.35, 1.0, 0.15))

	# The gate: present and legible while shut, bright and pulsing once open.
	var gf := field()
	if gf.has_gate:
		var ring := PackedVector2Array()
		for k in 25:
			var ga := TAU * k / 24.0
			ring.append(to_iso(gf.gate_pos
				+ Vector2(cos(ga), sin(ga)) * Terrain.GATE_RADIUS))
		if gf.gate_open:
			var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.004)
			draw_colored_polygon(ring, Color(0.35, 1.0, 0.75, 0.18 * pulse))
			draw_polyline(ring, Color(0.55, 1.9, 1.2, pulse), 2.5)
		else:
			# Shut, but never hidden. A gate you have walked past for five
			# minutes is a promise; one that appears on the boss kill is a
			# prompt, and the promise is the better feeling.
			draw_polyline(ring, Color(0.30, 0.45, 0.40, 0.55), 1.5)

		if gf.gate_open and phase == Phase.CLEARED:
			# A BEARING, not a path. A drawn route needs pathfinding the game
			# does not have and would be wrong the moment a wall interrupts it;
			# arenas are 8-18% walls and fully connected, so a direction is
			# enough to navigate by and cannot go stale.
			var gd := (gf.gate_pos - player_pos).normalized()
			for k in 14:
				var t0 := player_pos + gd * (120.0 + 90.0 * k)
				var fade := 1.0 - float(k) / 14.0
				var ph := fmod(Time.get_ticks_msec() * 0.0012 - k * 0.08, 1.0)
				draw_line(to_iso(t0), to_iso(t0 + gd * 40.0),
					Color(0.4, 1.4, 1.0, 0.10 + 0.5 * fade * ph), 2.0)

	# Shot visuals, oldest fading out. Drawn under the ship.
	for fx in _fx_line:
		var f: float = fx[2] / FX_LIFE
		var c: Color = fx[3]
		draw_line(to_iso(fx[0]), to_iso(fx[1]), Color(c.r, c.g, c.b, f), 1.0 + 2.5 * f)
	for fx in _fx_ring:
		var f2: float = fx[2] / FX_LIFE
		var c2: Color = fx[3]
		var pts := PackedVector2Array()
		for k in 33:
			var a2 := TAU * k / 32.0
			pts.append(to_iso(fx[0] + Vector2(cos(a2), sin(a2)) * fx[1] * (1.0 - f2 * 0.25)))
		draw_polyline(pts, Color(c2.r, c2.g, c2.b, f2 * 0.85), 1.0 + 2.0 * f2)

	# The ship is drawn screen-aligned at the projected position: a glyph that
	# tilts with the ground plane reads as debris, not as the thing you steer.
	var o := to_iso(player_pos)
	var pts := PackedVector2Array([
		o + Vector2(0, -14), o + Vector2(12, 8),
		o + Vector2(0, 3), o + Vector2(-12, 8)])
	var c := Color(0.9, 1.8, 1.3) if player_iframe <= 0.0 else Color(1.9, 0.8, 0.8)
	draw_polyline(pts + PackedVector2Array([pts[0]]), c, 2.0)
	# The pickup ring lies ON the ground plane, so it projects to an ellipse.
	var ring := PackedVector2Array()
	for k in 41:
		var a := TAU * k / 40.0
		ring.append(to_iso(player_pos + Vector2(cos(a), sin(a)) * pickup_radius))
	draw_polyline(ring, Color(0.35, 0.9, 0.7, 0.22), 1.0)
